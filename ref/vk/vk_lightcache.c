// Stable, material-independent geometry for the direct diffuse light cache.
#include "vk_lightcache.h"
#include "lightcache_layout.h"
#include "vk_core.h"
#include "vk_lightmap.h"
#include "vk_math.h"
#include "vk_mapents.h"
#include <stdlib.h>
#include "vulkan/VResource.h"
#include "xash3d_mathlib.h"
#include <stddef.h>
#include <math.h>
#include <string.h>

#define LC_SIDE 1024
#define LC_MAX_PROBES (LC_SIDE * LC_SIDE)
#define LC_MAX_BRUSHES 512

typedef struct {
	vec3_t position;
	uint32_t brush;
	vec3_t normal;
	uint32_t island;
	uint32_t first, width, height, local_index;
	uint32_t lm_s, lm_t, lm_width, lm_height;
} lc_probe_t;

// std430 layout, mirrored in lightcache_geometry.glsl. Zero lookup means invalid.
typedef struct {
	uint32_t count, epoch, reserved[2];
	uint32_t lookup[LC_SIDE * LC_SIDE];
	matrix4x4 transforms[LC_MAX_BRUSHES];
	lc_probe_t probes[LC_MAX_PROBES];
} lc_data_t;

typedef char lc_probe_size_must_match_std430[(sizeof(lc_probe_t) == 64) ? 1 : -1];
typedef char lc_probe_offset_must_match_std430[(offsetof(lc_data_t, probes) == 4227088) ? 1 : -1];
#define LC_ASSERT_OFFSET(type, member, expected) \
	typedef char lc_##type##_##member##_offset[(offsetof(type, member) == (expected)) ? 1 : -1]
LC_ASSERT_OFFSET(lc_probe_t, position, 0);
LC_ASSERT_OFFSET(lc_probe_t, brush, 12);
LC_ASSERT_OFFSET(lc_probe_t, normal, 16);
LC_ASSERT_OFFSET(lc_probe_t, island, 28);
LC_ASSERT_OFFSET(lc_probe_t, first, 32);
LC_ASSERT_OFFSET(lc_probe_t, width, 36);
LC_ASSERT_OFFSET(lc_probe_t, height, 40);
LC_ASSERT_OFFSET(lc_probe_t, local_index, 44);
LC_ASSERT_OFFSET(lc_probe_t, lm_s, 48);
LC_ASSERT_OFFSET(lc_probe_t, lm_t, 52);
LC_ASSERT_OFFSET(lc_probe_t, lm_width, 56);
LC_ASSERT_OFFSET(lc_probe_t, lm_height, 60);
LC_ASSERT_OFFSET(lc_data_t, lookup, 16);
LC_ASSERT_OFFSET(lc_data_t, transforms, 4194320);
#undef LC_ASSERT_OFFSET

static struct {
	lc_data_t *data;
	const model_t *models[LC_MAX_BRUSHES];
	uint32_t model_count, island_count, epoch;
	qboolean dirty;
	vk_buffer_t buffer;
	Producer producer;
} lc;

static void lcUploadRange(uint32_t offset, uint32_t size)
{
	if (!size) return;
	vk_buffer_locked_t lock = R_VkBufferLock(&lc.buffer, (vk_buffer_lock_t){offset, size});
	ASSERT(lock.ptr);
	memcpy(lock.ptr, (const byte *)lc.data + offset, size);
	R_VkBufferUnlock(lock);
}

static void lcProduce(Producer *producer, vk_combuf_t *combuf, const FrameContext *ctx)
{
	(void)producer; (void)ctx;
	// Update even brushes absent from the draw list: cache addresses cover the
	// whole lightmap, rather than just the camera's visible surfaces.
	for (uint32_t i = 1; globals.entities && i < globals.max_entities; ++i) {
		const cl_entity_t *ent = globals.entities + i;
		if (!ent->model || ent->model->type != mod_brush) continue;
		matrix4x4 transform;
		Matrix4x4_CreateFromEntity(transform, ent->angles, ent->origin, 1.0f);
		RT_LightCacheTransform(ent->model, transform);
	}
	for (uint32_t i = 0; i < lc.model_count; ++i) {
		for (int j = 0; j < g_map_entities.func_any_count; ++j) {
			const xvk_mapent_func_any_t *patch = g_map_entities.func_any + j;
			if (!patch->origin_patched || Q_strcmp(lc.models[i]->name, patch->model)) continue;
			matrix4x4 transform;
			Matrix4x4_LoadIdentity(transform);
			for (int k = 0; k < 3; ++k) transform[k][3] = patch->origin[k];
			RT_LightCacheTransform(lc.models[i], transform);
			break;
		}
	}
	if (lc.dirty) {
		lcUploadRange(0, offsetof(lc_data_t, probes) + lc.data->count * sizeof(lc_probe_t));
		lc.dirty = false;
	} else {
		lcUploadRange(offsetof(lc_data_t, transforms), lc.model_count * sizeof(matrix4x4));
	}
	R_VkBufferStagingCommit(&lc.buffer, combuf);
}

qboolean RT_LightCacheInit(void)
{
	lc.data = Mem_Calloc(vk_core.pool, sizeof(*lc.data));
	lc.producer = (Producer){.name = "lightcache_geometry", .produce = lcProduce};
	if (!VK_BufferCreate("light cache geometry", &lc.buffer, sizeof(lc_data_t),
		VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
		VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
		Mem_Free(lc.data); lc.data = NULL;
		return false;
	}
	R_VkBufferRegisterAsResource((r_vkbuffer_register_as_resource_t){
		.name = "lightcache_geometry", .type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
		.buffer = &lc.buffer, .size = sizeof(lc_data_t), .producer = &lc.producer,
	});
	RT_LightCacheClear();
	return true;
}

void RT_LightCacheShutdown(void)
{
	VK_BufferDestroy(&lc.buffer);
	if (lc.data) Mem_Free(lc.data);
	memset(&lc, 0, sizeof(lc));
}

void RT_LightCacheClear(void)
{
	if (!lc.data) return;
	memset(lc.data, 0, offsetof(lc_data_t, probes));
	lc.data->epoch = ++lc.epoch;
	lc.model_count = lc.island_count = 0;
	lc.dirty = true;
}

static uint32_t lcBrush(const model_t *model)
{
	for (uint32_t i = 0; i < lc.model_count; ++i)
		if (lc.models[i] == model) return i;
	ASSERT(lc.model_count < LC_MAX_BRUSHES);
	uint32_t index = lc.model_count++;
	lc.models[index] = model;
	Matrix4x4_LoadIdentity(lc.data->transforms[index]);
	return index;
}

void RT_LightCacheTransform(const model_t *model, const matrix4x4 transform)
{
	if (!lc.data) return;
	for (uint32_t i = 0; i < lc.model_count; ++i) {
		if (lc.models[i] != model) continue;
		Matrix4x4_ToArrayFloatGL(transform, (float *)lc.data->transforms[i]);
		return;
	}
}

static const float *lcVertex(const model_t *model, const msurface_t *surf, int index)
{
	int edge = model->surfedges[surf->firstedge + index];
	uint32_t vertex = FBitSet(model->flags, MODEL_QBSP2) ?
		model->edges32[abs(edge)].v[edge <= 0] : model->edges16[abs(edge)].v[edge <= 0];
	return model->vertexes[vertex].position;
}

// Clamp rectangular lightmap samples to the actual convex BSP face. In
// particular, a one-probe triangular island must never sample outside its face.
static void lcClampToFace(const model_t *model, const msurface_t *surf, vec3_t point)
{
	vec3_t center = {0}, nearest;
	for (int i = 0; i < surf->numedges; ++i)
		VectorAdd(center, lcVertex(model, surf, i), center);
	VectorScale(center, 1.0f / surf->numedges, center);
	float best = 1e30f;
	qboolean inside = true;
	for (int i = 0; i < surf->numedges; ++i) {
		const float *a = lcVertex(model, surf, i);
		const float *b = lcVertex(model, surf, (i + 1) % surf->numedges);
		vec3_t edge, delta, to_center, cp, cc, candidate;
		VectorSubtract(b, a, edge);
		VectorSubtract(point, a, delta);
		VectorSubtract(center, a, to_center);
		CrossProduct(edge, delta, cp);
		CrossProduct(edge, to_center, cc);
		if (DotProduct(cp, cc) < -0.001f) inside = false;
		float length2 = DotProduct(edge, edge);
		float t = length2 > 0 ? bound(0, DotProduct(delta, edge) / length2, 1) : 0;
		VectorMA(a, t, edge, candidate);
		VectorSubtract(point, candidate, delta);
		float d2 = DotProduct(delta, delta);
		if (d2 < best) { best = d2; VectorCopy(candidate, nearest); }
	}
	if (!inside) {
		// Keep the shadow-ray origin just inside the polygon at shared edges.
		VectorLerp(nearest, 0.001f, center, point);
	}
}

void RT_LightCacheAddSurface(const model_t *model, const msurface_t *surf)
{
	if (!lc.data || surf->lightmaptexturenum != 0 || surf->numedges < 3) return;
	const mextrasurf_t *info = surf->info;
	int step = gEngine.Mod_SampleSizeForFace(surf);
	int sw = info->lightextents[0] / step + 1, sh = info->lightextents[1] / step + 1;
	// Allocate each island independently: ceil preserves one-texel islands.
	uint32_t w = lcIslandExtent(sw), h = lcIslandExtent(sh);
	ASSERT(lc.data->count + w * h <= LC_MAX_PROBES);
	uint32_t first = lc.data->count, brush = lcBrush(model), island = ++lc.island_count;
	vec3_t uxv, vxn, nxu;
	CrossProduct(info->lmvecs[0], info->lmvecs[1], uxv);
	CrossProduct(info->lmvecs[1], surf->plane->normal, vxn);
	CrossProduct(surf->plane->normal, info->lmvecs[0], nxu);
	float determinant = DotProduct(info->lmvecs[0], vxn);
	if (fabsf(determinant) < 1e-8f) return;
	for (uint32_t y = 0; y < h; ++y) for (uint32_t x = 0; x < w; ++x) {
		lc_probe_t *probe = &lc.data->probes[lc.data->count++];
		float s = info->lightmapmins[0] + lcSampleCoordinate(x, sw) * step - info->lmvecs[0][3];
		float t = info->lightmapmins[1] + lcSampleCoordinate(y, sh) * step - info->lmvecs[1][3];
		for (int k = 0; k < 3; ++k)
			probe->position[k] = (vxn[k] * s + nxu[k] * t + uxv[k] * surf->plane->dist) / determinant;
		lcClampToFace(model, surf, probe->position);
		VectorScale(surf->plane->normal, FBitSet(surf->flags, SURF_PLANEBACK) ? -1 : 1, probe->normal);
		probe->brush = brush; probe->island = island;
		probe->first = first; probe->width = w; probe->height = h; probe->local_index = y * w + x;
		probe->lm_s = surf->light_s; probe->lm_t = surf->light_t;
		probe->lm_width = sw; probe->lm_height = sh;
	}
	for (int y = 0; y < sh; ++y) for (int x = 0; x < sw; ++x)
		lc.data->lookup[(surf->light_t + y) * LC_SIDE + surf->light_s + x] = lcIslandIndex(first, w, x, y) + 1;
	lc.dirty = true;
}
