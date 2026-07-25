#include "rt_decals.h"

#include "r_decals.h"
#include "r_textures.h"
#include "rt_kusochki.h"
#include "vk_materials.h"
#include "vk_render.h"
#include "vulkan/VBuffer.h"
#include "vulkan/VResource.h"

#include "shaders/ray_interop.h"

#include "protocol.h"
#include "xash3d_mathlib.h"

#include <stddef.h>
#include <string.h>

STATIC_ASSERT(sizeof(struct RtDecal) == 64, "RtDecal must match std430 layout");
STATIC_ASSERT(offsetof(struct RtDecal, base_color) == 16, "RtDecal.base_color offset must match std430");
STATIC_ASSERT(offsetof(struct RtDecal, projection_u) == 32, "RtDecal.projection_u offset must match std430");
STATIC_ASSERT(offsetof(struct RtDecal, projection_v) == 48, "RtDecal.projection_v offset must match std430");

#define MAX_RT_DECAL_HEADS 32768

static struct {
	vk_buffer_t decals_buffer;
	vk_buffer_t heads_buffer;
	Producer producer;
	msurface_t *kusok_surfaces[MAX_RT_DECAL_HEADS];
	qboolean initialized;
} g_rt_decals;

void RT_DecalsClearKusochki(void) {
	memset(g_rt_decals.kusok_surfaces, 0, sizeof(g_rt_decals.kusok_surfaces));
}

void RT_DecalsSetKusochki(uint32_t offset, const vk_render_geometry_t *geometries, int count) {
	for (int i = 0; i < count; ++i)
		g_rt_decals.kusok_surfaces[offset + i] = geometries[i].surf_deprecate;
}

void RT_DecalsFreeKusochki(uint32_t offset, int count) {
	memset(g_rt_decals.kusok_surfaces + offset, 0, sizeof(*g_rt_decals.kusok_surfaces) * count);
}

static void fillRtDecalHeads(uint32_t *heads) {
	for (int i = 0; i < MAX_RT_DECAL_HEADS; ++i) {
		const msurface_t *const surface = g_rt_decals.kusok_surfaces[i];
		heads[i] = surface && surface->pdecals
			? R_GetDecalId(surface->pdecals)
			: RT_DECAL_INVALID_ID;
	}
}

static void fillRtDecal(struct RtDecal *out, const decal_t *decal) {
	const msurface_t *const surface = decal->psurface;
	vec3_t basis_u, basis_v;
	VectorNormalize2(surface->texinfo->vecs[0], basis_u);
	VectorNormalize2(surface->texinfo->vecs[1], basis_v);

	int width = R_TexturesGetParm(PARM_TEX_SRC_WIDTH, decal->texture);
	int height = R_TexturesGetParm(PARM_TEX_SRC_HEIGHT, decal->texture);
	if (width <= 0) width = 1;
	if (height <= 0) height = 1;
	VectorScale(basis_u, decal->scale / width, basis_u);
	VectorScale(basis_v, decal->scale / height, basis_v);

	const r_vk_material_t material = R_VkMaterialGetForTexture(decal->texture);
	*out = (struct RtDecal) {
		.next_decal_id = decal->pnext ? R_GetDecalId(decal->pnext) : RT_DECAL_INVALID_ID,
		.tex_base_color = material.tex_base_color,
		.roughness = material.roughness,
		.metalness = material.metalness,
		.projection_u = { basis_u[0], basis_u[1], basis_u[2], 0.5f - decal->dx },
		.projection_v = { basis_v[0], basis_v[1], basis_v[2], 0.5f - decal->dy },
	};
	Vector4Copy(material.base_color, out->base_color);
}

static void uploadRtDecals(void) {
	const vk_buffer_locked_t decals_lock = R_VkBufferLock(&g_rt_decals.decals_buffer, (vk_buffer_lock_t) {
		.offset = 0,
		.size = g_rt_decals.decals_buffer.size,
	});
	if (decals_lock.ptr) {
		struct RtDecal *const out = decals_lock.ptr;
		int decals_count;
		const decal_t *const decals = R_GetDecalPool(&decals_count);

		for (int i = 0; i < MAX_RENDER_DECALS; ++i)
			out[i].next_decal_id = RT_DECAL_INVALID_ID;
		for (int i = 0; i < decals_count; ++i) {
			if (decals[i].psurface)
				fillRtDecal(out + i, decals + i);
		}
		R_VkBufferUnlock(decals_lock);
	}

	const vk_buffer_locked_t heads_lock = R_VkBufferLock(&g_rt_decals.heads_buffer, (vk_buffer_lock_t) {
		.offset = 0,
		.size = g_rt_decals.heads_buffer.size,
	});
	if (heads_lock.ptr) {
		fillRtDecalHeads(heads_lock.ptr);
		R_VkBufferUnlock(heads_lock);
	}
}

static void produceRtDecals(struct Producer *producer, struct vk_combuf_s *combuf, const FrameContext *ctx) {
	(void)producer;
	(void)ctx;
	uploadRtDecals();
	R_VkBufferStagingCommit(&g_rt_decals.decals_buffer, combuf);
	R_VkBufferStagingCommit(&g_rt_decals.heads_buffer, combuf);
}

qboolean RT_DecalsInit(void) {
	if (!VK_BufferCreate("rt decals", &g_rt_decals.decals_buffer, sizeof(struct RtDecal) * MAX_RENDER_DECALS,
		VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
		VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
		return false;
	}
	if (!VK_BufferCreate("rt decal heads", &g_rt_decals.heads_buffer, sizeof(uint32_t) * MAX_RT_DECAL_HEADS,
		VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
		VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
		VK_BufferDestroy(&g_rt_decals.decals_buffer);
		return false;
	}

	g_rt_decals.producer = (Producer) {
		.name = "rt_decals",
		.produce = produceRtDecals,
	};

	R_VkBufferRegisterAsResource((r_vkbuffer_register_as_resource_t){
		.name = "rt_decals",
		.type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
		.buffer = &g_rt_decals.decals_buffer,
		.offset = 0,
		.size = g_rt_decals.decals_buffer.size,
		.producer = &g_rt_decals.producer,
	});
	R_VkBufferRegisterAsResource((r_vkbuffer_register_as_resource_t){
		.name = "rt_decal_heads",
		.type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
		.buffer = &g_rt_decals.heads_buffer,
		.offset = 0,
		.size = g_rt_decals.heads_buffer.size,
		.producer = &g_rt_decals.producer,
	});

	g_rt_decals.initialized = true;
	return true;
}

void RT_DecalsShutdown(void) {
	if (g_rt_decals.initialized) {
		VK_BufferDestroy(&g_rt_decals.heads_buffer);
		VK_BufferDestroy(&g_rt_decals.decals_buffer);
	}
	memset(&g_rt_decals, 0, sizeof(g_rt_decals));
}
