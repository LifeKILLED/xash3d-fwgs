#include "vk_light.h"
#include "vulkan/VBuffer.h"
#include "vk_mapents.h"
#include "r_textures.h"
#include "vk_lightmap.h"
#include "vk_common.h"
#include "vk_cvar.h"
#include "shaders/ray_interop.h"
#include "std/bitarray.h"
#include "std/profiler.h"
#include "vulkan/VStaging.h"
#include "r_speeds.h"
#include "vk_logs.h"
#include "vk_framectl.h"
#include "vulkan/VResource.h"

#include "mod_local.h"
#include "xash3d_mathlib.h"

#include <stdio.h>
#include <string.h>
#include <ctype.h> // isalnum...
#include <math.h>
#include <float.h>

#include "camera.h"
#include "pm_defs.h"
#include "pmtrace.h"

#define MODULE_NAME "light"
#define LOG_MODULE light

#define PROFILER_SCOPES(X) \
	X(finalize , "RT_LightsFrameEnd"); \
	X(emissive_surface, "VK_LightsAddEmissiveSurface"); \
	X(static_lights, "add static lights"); \
	X(dlights, "add dlights"); \
	//X(canSurfaceLightAffectAABB, "canSurfaceLightAffectAABB"); \

#define SCOPE_DECLARE(scope, name) APROF_SCOPE_DECLARE(scope)
PROFILER_SCOPES(SCOPE_DECLARE)
#undef SCOPE_DECLARE

typedef struct {
	uint8_t num_point_lights;
	uint8_t num_polygons;

	uint8_t point_lights[MAX_VISIBLE_POINT_LIGHTS];
	uint8_t polygons[MAX_VISIBLE_SURFACE_LIGHTS];

	struct {
		uint8_t point_lights;
		uint8_t polygons;
	} num_static;

	uint32_t frame_sequence;
} vk_lights_cell_t;

typedef struct {
	vec3_t emissive;
	qboolean set;
} vk_emissive_texture_t;

typedef struct {
	vec4_t plane;
	vec3_t center;
	float area;

	vec3_t emissive;

	struct {
		int offset, count; // reference g_light.polygon_vertices
	} vertices;

	// uint32_t kusok_index;
} rt_light_polygon_t;

#define LIGHT_MERGE_MAX_RECTS 1024
#define LIGHT_MERGE_MAX_BVH_NODES (LIGHT_MERGE_MAX_RECTS * 2)
#define LIGHT_MERGE_MAX_NEIGHBORS 256
#define LIGHT_MERGE_MAX_SOURCE_VERTICES 8
#define LIGHT_MERGE_POS_EPSILON 2.0f
#define LIGHT_MERGE_LINE_EPSILON 2.0f
#define LIGHT_MERGE_COLOR_EPSILON 0.01f
#define LIGHT_MERGE_NORMAL_COMPONENT_EPSILON 0.01f
#define LIGHT_MERGE_AABB_EPSILON LIGHT_MERGE_POS_EPSILON

typedef struct {
	int src_poly_index;
	vec3_t vertices[4];
	vec3_t emissive;
	vec4_t plane;
	vec3_t center;
	float area;
	float mins[3];
	float maxs[3];
} rt_light_merge_rect_t;

typedef struct {
	float mins[3];
	float maxs[3];
	int left;
	int right;
	int begin;
	int count;
} rt_light_merge_bvh_node_t;

typedef struct {
	int num_rects;
	rt_light_merge_rect_t rects[LIGHT_MERGE_MAX_RECTS];
	int rect_taken[LIGHT_MERGE_MAX_RECTS];

	int rect_indices[LIGHT_MERGE_MAX_RECTS];

	int num_bvh_nodes;
	rt_light_merge_bvh_node_t bvh_nodes[LIGHT_MERGE_MAX_BVH_NODES];
	int bvh_root;

	int merged_num_polygons;
	int merged_num_vertices;
	rt_light_polygon_t merged_polygons[MAX_SURFACE_LIGHTS];
	vec3_t merged_vertices[MAX_SURFACE_LIGHTS * 7];
	int source_to_merged[MAX_SURFACE_LIGHTS];

	int neighbors[LIGHT_MERGE_MAX_NEIGHBORS];
	int working_group[LIGHT_MERGE_MAX_NEIGHBORS];
	int isolated_self_only_count;

	qboolean prev_frame_merge_was_enabled;
} rt_light_merge_state_t;

enum {
	LightFlag_Environment = 0x1,
	LightFlag_Flashlight = 0x2,
};

typedef struct {
	vec3_t origin;
	vec3_t color;
	vec3_t dir;
	float stopdot;
	float stopdot2_or_costheta;
	float radius;
	int flags;

	int lightstyle;
	vec3_t base_color;
} vk_point_light_t;

static struct {
	struct {
		vk_emissive_texture_t emissive_textures[MAX_TEXTURES];
	} map;

	struct {
		int min_cell[3];
		int size[3];
		int cells;
	} grid;

	vk_lights_cell_t cells[MAX_LIGHT_CLUSTERS];

	vk_buffer_t buffer;

	int num_polygons;
	rt_light_polygon_t polygons[MAX_SURFACE_LIGHTS];
	qboolean polygon_rect_candidate[MAX_SURFACE_LIGHTS];

	int num_point_lights;
	vk_point_light_t point_lights[MAX_POINT_LIGHTS];

	int num_polygon_vertices;
	vec3_t polygon_vertices[MAX_SURFACE_LIGHTS * 7];

	struct {
		int point_lights;
		int polygons;
		int polygon_vertices;
	} num_static;

	bit_array_t visited_cells;

	// TODO depend on producer->produce(ctx.frame_sequence)
	uint32_t frame_sequence;
	Producer producer;

	struct {
		int dirty_cells;
		int dirty_cells_size;
		int ranges_uploaded;
		int dynamic_polygons, dynamic_points;
		int dlights, elights;
	} stats;

	rt_light_merge_state_t merge;
} g_lights_;

static struct {
	qboolean enabled;
	char name_filter[256];
	qboolean print_stats_once;
	qboolean dump_all_sources_once;
} debug_dump_lights;

static void debugDumpLights( void ) {
	debug_dump_lights.enabled = true;
	if (gEngine.Cmd_Argc() > 1) {
		Q_strncpy(debug_dump_lights.name_filter, gEngine.Cmd_Argv(1), sizeof(debug_dump_lights.name_filter));
	} else {
		debug_dump_lights.name_filter[0] = '\0';
	}
}

static void debugPrintLightsStats( void ) {
	debug_dump_lights.print_stats_once = true;
}

static void debugDumpAllLightSources( void ) {
	debug_dump_lights.dump_all_sources_once = true;
}

static void lightsProduce(struct Producer* p, struct vk_combuf_s *combuf, const FrameContext *ctx);

qboolean VK_LightsInit( void ) {
	PROFILER_SCOPES(APROF_SCOPE_INIT);

	gEngine.Cmd_AddCommand("rt_debug_lights_dump", debugDumpLights, "Dump all light sources for next frame");
	gEngine.Cmd_AddCommand("rt_debug_lights_stats", debugPrintLightsStats, "Dump light sources statistics for next frame");
	gEngine.Cmd_AddCommand("rt_debug_lights_dump_all", debugDumpAllLightSources, "Dump all light sources with vertices for next frame");

	const int buffer_size = sizeof(struct LightsMetadata) + sizeof(struct LightCluster) * MAX_LIGHT_CLUSTERS;

	if (!VK_BufferCreate("rt lights buffer", &g_lights_.buffer, buffer_size,
		VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
		VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
		// FIXME complain, handle
		return false;
	}

	g_lights_.producer = (Producer) {
		.name = "lights",
		.frame_sequence_tag = 0,
		.produce = lightsProduce,
	};

	R_VkBufferRegisterAsResource((r_vkbuffer_register_as_resource_t){
		.name = "lights",
		.type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
		.buffer = &g_lights_.buffer,
		.offset = 0,
		.size = sizeof(struct LightsMetadata),
		.producer = &g_lights_.producer,
	});

	R_VkBufferRegisterAsResource((r_vkbuffer_register_as_resource_t){
		.name = "light_grid",
		.type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
		.buffer = &g_lights_.buffer,
		.offset = sizeof(struct LightsMetadata),
		.size = sizeof(struct LightCluster) * MAX_LIGHT_CLUSTERS,
		.producer = &g_lights_.producer,
	});

	R_SPEEDS_COUNTER(g_lights_.stats.dirty_cells, "dirty_cells", kSpeedsMetricCount);
	R_SPEEDS_COUNTER(g_lights_.stats.dirty_cells_size, "dirty_cells_size", kSpeedsMetricBytes);
	R_SPEEDS_COUNTER(g_lights_.stats.ranges_uploaded, "ranges_uploaded", kSpeedsMetricCount);
	R_SPEEDS_COUNTER(g_lights_.num_polygons, "polygons", kSpeedsMetricCount);
	R_SPEEDS_COUNTER(g_lights_.num_point_lights, "points", kSpeedsMetricCount);
	R_SPEEDS_COUNTER(g_lights_.stats.dynamic_polygons, "polygons_dynamic", kSpeedsMetricCount);
	R_SPEEDS_COUNTER(g_lights_.stats.dynamic_points, "points_dynamic", kSpeedsMetricCount);
	R_SPEEDS_COUNTER(g_lights_.stats.dlights, "dlights", kSpeedsMetricCount);
	R_SPEEDS_COUNTER(g_lights_.stats.elights, "elights", kSpeedsMetricCount);

	return true;
}

void VK_LightsShutdown( void ) {
	VK_BufferDestroy(&g_lights_.buffer);

	gEngine.Cmd_RemoveCommand("vk_lights_dump");
	gEngine.Cmd_RemoveCommand("rt_debug_lights_stats");
	gEngine.Cmd_RemoveCommand("rt_debug_lights_dump_all");
	bitArrayDestroy(&g_lights_.visited_cells);
}

typedef struct {
	int num;
	int leafs[];
} vk_light_leaf_set_t;

typedef struct {
	vk_light_leaf_set_t *potentially_visible_leafs;
} vk_surface_metadata_t;

static struct {
	// Worldmodel surfaces
	int num_surfaces;
	vk_surface_metadata_t *surfaces;

	// Used for accumulating potentially visible leafs
	struct {
		int count;

		// This buffer space is used for two things:
		// As a growing array of u16 leaf indexes (low 16 bits)
		// As a bit field for marking added leafs (highest {31st} bit)
		uint32_t leafs[MAX_MAP_LEAFS];

		byte visbytes[(MAX_MAP_LEAFS+7)/8];
	} accum;

} g_lights_bsp = {0};

static qboolean loadRadData( const model_t *map, const char *fmt, ... ) {
	fs_offset_t size;
	char *data;
	byte *buffer;
	char filename[1024];

	va_list argptr;
	va_start( argptr, fmt );
	vsnprintf( filename, sizeof filename, fmt, argptr );
	va_end( argptr );

	buffer = gEngine.fsapi->LoadFile( filename, &size, false);

	if (!buffer) {
		DEBUG("Couldn't load RAD data from file %s", filename);
		return false;
	}

	DEBUG("Loading RAD data from file %s", filename);

	data = (char*)buffer;
	for (;;) {
		string name;
		float r=0, g=0, b=0, scale=0;
		int num;
		char* line_end;

		while (*data != '\0' && isspace(*data)) ++data;
		if (*data == '\0')
			break;

		line_end = Q_strchr(data, '\n');
		if (line_end) *line_end = '\0';

		name[0] = '\0';
		num = sscanf(data, "%s %f %f %f %f", name, &r, &g, &b, &scale);
		//DEBUG("raw rad entry (%d): %s %f %f %f %f", num, name, r, g, b, scale);
		if (Q_strstr(name, "//") != NULL) {
			num = 0;
		}

		if (num == 2) {
			r = g = b;
		} else if (num == 5) {
			scale /= 255.f;
			r *= scale;
			g *= scale;
			b *= scale;
		} else if (num == 4) {
			// Ok, rgb only, no scaling
		} else {
			DEBUG( "skipping rad entry %s", name[0] ? name : "(empty)" );
			num = 0;
		}

		if (num != 0) {
			DEBUG("rad entry (%d): %s %f %f %f (%f)", num, name, r, g, b, scale);

			{
				const char *wad_name = NULL;
				char *texture_name = Q_strchr(name, '/');
				int tex_id;
				const qboolean enabled = (r != 0 || g != 0 || b != 0);

				if (!texture_name) {
					texture_name = name;
				} else {
					// name is now just a wad name
					texture_name[0] = '\0';
					wad_name = name;

					texture_name += 1;
				}

				// FIXME replace this with findTexturesNamedLike from vk_materials.c
				// It has slightly different logic, though, and is a bit scary to change

				// Try bsp texture first
				tex_id = R_TextureFindByNameF("#%s:%s.mip", map->name, texture_name);

				// Try wad texture if bsp is not there
				if (!tex_id && wad_name) {
					tex_id = R_TextureFindByNameF("%s.wad/%s.mip", wad_name, texture_name);
				}

				if (!tex_id) {
					const char *wad = g_map_entities.wadlist;
					for (; *wad;) {
						const char *const wad_end = Q_strchr(wad, ';');
						tex_id = R_TextureFindByNameF("%.*s/%s.mip", wad_end - wad, wad, texture_name);
						if (tex_id)
							break;
						wad = wad_end + 1;
					}
				}

				if (tex_id) {
					vk_emissive_texture_t *const etex = g_lights_.map.emissive_textures + tex_id;
					ASSERT(tex_id < MAX_TEXTURES);

					etex->emissive[0] = r;
					etex->emissive[1] = g;
					etex->emissive[2] = b;
					etex->set = enabled;

					// See DIRECT_SCALE in qrad/lightmap.c
					VectorScale(etex->emissive, 0.1f, etex->emissive);

					DEBUG("  texture(%s?, %d) set emissive(%f, %f, %f)", texture_name, tex_id, etex->emissive[0], etex->emissive[1], etex->emissive[2]);

					if (!enabled)
						DEBUG("rad entry %s disabled due to zero intensity", name);
				}
			}
		}

		if (!line_end)
			break;

		data = line_end + 1;
	}

	Mem_Free(buffer);
	return true;
}

static void leafAccumPrepare( void ) {
	memset(&g_lights_bsp.accum, 0, sizeof(g_lights_bsp.accum));
}

#define LEAF_ADDED_BIT 0x8000000ul

static qboolean leafAccumAdd( uint16_t leaf_index ) {
	// Check whether this leaf was already added
	if (g_lights_bsp.accum.leafs[leaf_index] & LEAF_ADDED_BIT)
		return false;

	g_lights_bsp.accum.leafs[leaf_index] |= LEAF_ADDED_BIT;

	g_lights_bsp.accum.leafs[g_lights_bsp.accum.count++] |= leaf_index;
	return true;
}

static void leafAccumFinalize( void ) {
	for (int i = 0; i < g_lights_bsp.accum.count; ++i)
		g_lights_bsp.accum.leafs[i] &= 0xffffu;
}

static int leafAccumAddPotentiallyVisibleFromLeaf(const model_t *const map, const mleaf_t *leaf, qboolean print_debug) {
	int pvs_leaf_index = 0;
	int leafs_added = 0;
	ASSERT(leaf->compressed_vis);
	const byte *pvs = leaf->compressed_vis;
	for (;pvs_leaf_index < map->numleafs; ++pvs) {
		uint8_t bits = pvs[0];

		// PVS is RLE encoded
		if (bits == 0) {
			const int skip = pvs[1];
			pvs_leaf_index += skip * 8;
			++pvs;
			continue;
		}

		for (int k = 0; k < 8; ++k, ++pvs_leaf_index, bits >>= 1) {
			if ((bits&1) == 0)
				continue;

			if (leafAccumAdd( pvs_leaf_index + 1 )) {
				leafs_added++;
				if (print_debug)
					DEBUG(" .%d", pvs_leaf_index + 1);
			}
		}
	}

	return leafs_added;
}

static vk_light_leaf_set_t *getMapLeafsAffectedByMapSurface( const msurface_t *surf ) {
	const model_t *const map = WORLDMODEL;
	const int surf_index = surf - map->surfaces;
	vk_surface_metadata_t * const smeta = g_lights_bsp.surfaces + surf_index;
	const qboolean verbose_debug = false;

	if (surf_index < 0 || surf_index >= g_lights_bsp.num_surfaces) {
		ERR("FIXME not implemented: attempting to add non-static polygon light");
		return NULL;
	}

	ASSERT(surf_index >= 0);
	ASSERT(surf_index < g_lights_bsp.num_surfaces);

	// Check if PVL hasn't been collected yet
	if (!smeta->potentially_visible_leafs) {
		int leafs_direct = 0, leafs_pvs = 0;
		leafAccumPrepare();

		// Enumerate all the map leafs and pick ones that have this surface referenced
		if (verbose_debug)
			DEBUG("Collecting visible leafs for surface %d:", surf_index);
		for (int i = 1; i <= map->numleafs; ++i) {
			const mleaf_t *leaf = map->leafs + i;
			//if (verbose_debug) DEBUG("    leaf %d(c%d)/%d:", i, leaf->cluster, map->numleafs);
			for (int j = 0; j < leaf->nummarksurfaces; ++j) {
				const msurface_t *leaf_surf = leaf->firstmarksurface[j];
				if (leaf_surf != surf) {
					/* if (verbose_debug) { */
					/* 	const int leaf_surf_index = leaf_surf - map->surfaces; */
					/* 	DEBUG(" !%d", leaf_surf_index); */
					/* } */
					continue;
				}

				// FIXME split direct leafs marking from pvs propagation
				leafs_direct++;
				if (leafAccumAdd( i )) {
					if (verbose_debug) DEBUG(" %d", i);
				} else {
					// This leaf was already added earlier by PVS
					// but it really should be counted as direct
					--leafs_pvs;
				}

				// Get all PVS leafs
				leafs_pvs += leafAccumAddPotentiallyVisibleFromLeaf(map, leaf, verbose_debug);
			}

			//if (verbose_debug) DEBUG("\n");
		}
		if (verbose_debug)
			DEBUG(" (sum=%d, direct=%d, pvs=%d)", g_lights_bsp.accum.count, leafs_direct, leafs_pvs);

		leafAccumFinalize();

		smeta->potentially_visible_leafs = (vk_light_leaf_set_t*)Mem_Malloc(vk_core.pool, sizeof(smeta->potentially_visible_leafs[0]) + sizeof(int) * g_lights_bsp.accum.count);
		smeta->potentially_visible_leafs->num = g_lights_bsp.accum.count;

		for (int i = 0; i < g_lights_bsp.accum.count; ++i) {
			smeta->potentially_visible_leafs->leafs[i] = g_lights_bsp.accum.leafs[i];
		}
	}

	return smeta->potentially_visible_leafs;
}

int RT_LightCellIndex( const int light_cell[3] ) {
	if (light_cell[0] < 0 || light_cell[1] < 0 || light_cell[2] < 0
		|| (light_cell[0] >= g_lights_.grid.size[0])
		|| (light_cell[1] >= g_lights_.grid.size[1])
		|| (light_cell[2] >= g_lights_.grid.size[2]))
		return -1;

	return light_cell[0] + light_cell[1] * g_lights_.grid.size[0] + light_cell[2] * g_lights_.grid.size[0] * g_lights_.grid.size[1];
}

static vk_light_leaf_set_t *getMapLeafsAffectedByMovingSurface( const msurface_t *surf, const matrix3x4 *transform_row ) {
	const model_t *const map = WORLDMODEL;
	const mextrasurf_t *const extra = surf->info;

	// This is a very conservative way to construct a bounding sphere. It's not great.
	const vec3_t bbox_center = {
		(extra->mins[0] + extra->maxs[0]) / 2.f,
		(extra->mins[1] + extra->maxs[1]) / 2.f,
		(extra->mins[2] + extra->maxs[2]) / 2.f,
	};

	const vec3_t bbox_size = {
		extra->maxs[0] - extra->mins[0],
		extra->maxs[1] - extra->mins[1],
		extra->maxs[2] - extra->mins[2],
	};

	int leafs_direct = 0, leafs_pvs = 0;

	const float radius = .5f * VectorLength(bbox_size);
	vec3_t origin;

	Matrix3x4_VectorTransform(*transform_row, bbox_center, origin);

	if (debug_dump_lights.enabled) {
		DEBUG("\torigin = %f, %f, %f, R = %f",
			origin[0], origin[1], origin[2], radius
		);
	}

	leafAccumPrepare();

	// TODO it's possible to somehow more efficiently traverse the bsp and collect only the affected leafs
	// (origin + radius will accidentally touch leafs that are really should not be affected)
	gEngine.R_FatPVS(origin, radius, g_lights_bsp.accum.visbytes, /*merge*/ false, /*fullvis*/ false);
	if (debug_dump_lights.enabled)
		DEBUG("Collecting visible leafs for moving surface %p: %f,%f,%f %f: ", surf,
			origin[0], origin[1], origin[2], radius);

	for (int i = 0; i <= map->numleafs; ++i) {
		if( !CHECKVISBIT( g_lights_bsp.accum.visbytes, i ))
			continue;

		leafs_direct++;

		if (leafAccumAdd( i + 1 )) {
			if (debug_dump_lights.enabled)
				DEBUG(" %d", i + 1);
		} else {
			// This leaf was already added earlier by PVS
			// but it really should be counted as direct
			leafs_pvs--;
		}
	}

	if (debug_dump_lights.enabled)
		DEBUG(" (sum=%d, direct=%d, pvs=%d)", g_lights_bsp.accum.count, leafs_direct, leafs_pvs);

	leafAccumFinalize();

	// ...... oh no
	return (vk_light_leaf_set_t*)&g_lights_bsp.accum.count;
}

static void prepareSurfacesLeafVisibilityCache( const struct model_s *map ) {
	if (g_lights_bsp.surfaces != NULL) {
		for (int i = 0; i < g_lights_bsp.num_surfaces; ++i) {
			vk_surface_metadata_t *smeta = g_lights_bsp.surfaces + i;
			if (smeta->potentially_visible_leafs)
				Mem_Free(smeta->potentially_visible_leafs);
		}
		Mem_Free(g_lights_bsp.surfaces);
	}

	g_lights_bsp.num_surfaces = map->numsurfaces;
	g_lights_bsp.surfaces = Mem_Malloc(vk_core.pool, g_lights_bsp.num_surfaces * sizeof(vk_surface_metadata_t));
	for (int i = 0; i < g_lights_bsp.num_surfaces; ++i)
		g_lights_bsp.surfaces[i].potentially_visible_leafs = NULL;
}

void RT_LightsNewMap( const struct model_s *map ) {
	// 1. Determine map bounding box (and optimal grid size?)
		// map->mins, maxs
	vec3_t map_size, min_cell, max_cell;
	VectorSubtract(map->maxs, map->mins, map_size);

	VectorDivide(map->mins, LIGHT_GRID_CELL_SIZE, min_cell);
	min_cell[0] = floorf(min_cell[0]);
	min_cell[1] = floorf(min_cell[1]);
	min_cell[2] = floorf(min_cell[2]);
	VectorCopy(min_cell, g_lights_.grid.min_cell);

	VectorDivide(map->maxs, LIGHT_GRID_CELL_SIZE, max_cell);
	max_cell[0] = ceilf(max_cell[0]);
	max_cell[1] = ceilf(max_cell[1]);
	max_cell[2] = ceilf(max_cell[2]);

	VectorSubtract(max_cell, min_cell, g_lights_.grid.size);
	g_lights_.grid.cells = g_lights_.grid.size[0] * g_lights_.grid.size[1] * g_lights_.grid.size[2];

	ASSERT(g_lights_.grid.cells < MAX_LIGHT_CLUSTERS);

	DEBUG("Map mins:(%f, %f, %f), maxs:(%f, %f, %f), size:(%f, %f, %f), min_cell:(%f, %f, %f) cells:(%d, %d, %d); total: %d",
		map->mins[0], map->mins[1], map->mins[2],
		map->maxs[0], map->maxs[1], map->maxs[2],
		map_size[0], map_size[1], map_size[2],
		min_cell[0], min_cell[1], min_cell[2],
		g_lights_.grid.size[0],
		g_lights_.grid.size[1],
		g_lights_.grid.size[2],
		g_lights_.grid.cells
	);

	bitArrayDestroy(&g_lights_.visited_cells);
	g_lights_.visited_cells = bitArrayCreate(g_lights_.grid.cells);

	prepareSurfacesLeafVisibilityCache( map );
}

static qboolean addSurfaceLightToCell( int cell_index, int polygon_light_index ) {
	vk_lights_cell_t *const cluster = g_lights_.cells + cell_index;

	if (cluster->num_polygons == MAX_VISIBLE_SURFACE_LIGHTS) {
		return false;
	}

	if (debug_dump_lights.enabled) {
		DEBUG("    adding polygon light %d to cell %d (count=%d)", polygon_light_index, cell_index, cluster->num_polygons+1);
	}

	cluster->polygons[cluster->num_polygons++] = polygon_light_index;
	if (cluster->frame_sequence != g_lights_.frame_sequence) {
		++g_lights_.stats.dirty_cells;
		cluster->frame_sequence = g_lights_.frame_sequence;
	}
	return true;
}

static qboolean addLightToCell( int cell_index, int light_index ) {
	vk_lights_cell_t *const cluster = g_lights_.cells + cell_index;

	if (cluster->num_point_lights == MAX_VISIBLE_POINT_LIGHTS)
		return false;

	if (debug_dump_lights.enabled) {
		DEBUG("    adding point light %d to cell %d (count=%d)", light_index, cell_index, cluster->num_point_lights+1);
	}

	cluster->point_lights[cluster->num_point_lights++] = light_index;

	if (cluster->frame_sequence != g_lights_.frame_sequence) {
		++g_lights_.stats.dirty_cells;
		cluster->frame_sequence = g_lights_.frame_sequence;
	}
	return true;
}

/*
static qboolean canSurfaceLightAffectAABB(const model_t *mod, const msurface_t *surf, const vec3_t emissive, const float minmax[6]) {
	//APROF_SCOPE_BEGIN_EARLY(canSurfaceLightAffectAABB); // DO NOT DO THIS. We have like 600k of these calls per frame :feelsbadman:
	qboolean retval = true;
	// FIXME transform surface
	// this here only works for static map model

	// Use bbox center for normal culling estimation
	const vec3_t bbox_center = {
		(minmax[0] + minmax[3]) / 2.f,
		(minmax[1] + minmax[4]) / 2.f,
		(minmax[2] + minmax[5]) / 2.f,
	};

	float bbox_plane_dist = PlaneDiff(bbox_center, surf->plane);
	if( FBitSet( surf->flags, SURF_PLANEBACK ))
		bbox_plane_dist = -bbox_plane_dist;

	if (bbox_plane_dist < 0.f) {
		// Fast conservative estimate by max distance from bbox center
		// TODO is enumerating all points or finding a closest one is better/faster?
		const float size_x = minmax[0] - minmax[3];
		const float size_y = minmax[1] - minmax[4];
		const float size_z = minmax[2] - minmax[5];
		const float plane_dist_guard_sqr = (size_x * size_x + size_y * size_y + size_z * size_z) * .25f;

		// Check whether this bbox is completely behind the surface
		if (bbox_plane_dist*bbox_plane_dist > plane_dist_guard_sqr)
			retval = false;
	}

	//APROF_SCOPE_END(canSurfaceLightAffectAABB);

	return retval;
}
*/

static void addLightIndexToLeaf( const mleaf_t *leaf, int index ) {
	const int min_x = floorf(leaf->minmaxs[0] / LIGHT_GRID_CELL_SIZE);
	const int min_y = floorf(leaf->minmaxs[1] / LIGHT_GRID_CELL_SIZE);
	const int min_z = floorf(leaf->minmaxs[2] / LIGHT_GRID_CELL_SIZE);

	const int max_x = ceilf(leaf->minmaxs[3] / LIGHT_GRID_CELL_SIZE);
	const int max_y = ceilf(leaf->minmaxs[4] / LIGHT_GRID_CELL_SIZE);
	const int max_z = ceilf(leaf->minmaxs[5] / LIGHT_GRID_CELL_SIZE);

	if (debug_dump_lights.enabled) {
		DEBUG("  adding leaf %d min=(%d, %d, %d), max=(%d, %d, %d) total=%d",
			leaf->cluster,
			min_x, min_y, min_z,
			max_x, max_y, max_z,
			(max_x - min_x) * (max_y - min_y) * (max_z - min_z)
		);
	}

	for (int x = min_x; x < max_x; ++x)
	for (int y = min_y; y < max_y; ++y)
	for (int z = min_z; z < max_z; ++z) {
		const int cell[3] = {
			x - g_lights_.grid.min_cell[0],
			y - g_lights_.grid.min_cell[1],
			z - g_lights_.grid.min_cell[2]
		};

		const int cell_index = RT_LightCellIndex( cell );
		if (cell_index < 0)
			continue;

		if (bitArrayCheckOrSet(&g_lights_.visited_cells, cell_index)) {
			if (!addLightToCell(cell_index, index)) {
				ERROR_THROTTLED(10, "Cluster %d,%d,%d(%d) ran out of light slots",
					cell[0], cell[1],  cell[2], cell_index);
			}
		}
	}
}

static void addPointLightToAllClusters( int index ) {
	const model_t* const world = WORLDMODEL;

	// FIXME there's certainly a better way to do this: just enumerate
	// all clusters, not all leafs

	bitArrayClear(&g_lights_.visited_cells);
	for (int i = 1; i <= world->numleafs; ++i) {
		const mleaf_t *const leaf = world->leafs + i;
		addLightIndexToLeaf( leaf, index );
	}
}

static void addPointLightToClusters( int index ) {
	const model_t* const world = WORLDMODEL;

	if (!world->visdata) {
		addPointLightToAllClusters( index );
		return;
	}

	vk_point_light_t *const light = g_lights_.point_lights + index;
	const mleaf_t* leaf = gEngine.Mod_PointInLeaf(light->origin, world->nodes);
	const vk_light_leaf_set_t *const leafs = (vk_light_leaf_set_t*)&g_lights_bsp.accum.count;

	leafAccumPrepare();
	leafAccumAddPotentiallyVisibleFromLeaf( world, leaf, false);
	leafAccumFinalize();

	bitArrayClear(&g_lights_.visited_cells);
	for (int i = 0; i < leafs->num; ++i) {
		const mleaf_t *const leaf = world->leafs + leafs->leafs[i];
		addLightIndexToLeaf( leaf, index );
	}
}

static int addPointLight( const vec3_t origin, const vec3_t color, float radius, int lightstyle, float hack_attenuation ) {
	const int index = g_lights_.num_point_lights;
	vk_point_light_t *const plight = g_lights_.point_lights + index;

	if (g_lights_.num_point_lights >= MAX_POINT_LIGHTS) {
		ERROR_THROTTLED(10, "Too many lights, MAX_POINT_LIGHTS=%d", MAX_POINT_LIGHTS);
		return -1;
	}

	if (debug_dump_lights.enabled) {
		DEBUG("point light %d: origin=(%f %f %f) R=%f color=(%f %f %f)", index,
			origin[0], origin[1], origin[2], radius,
			color[0], color[1], color[2]);
	}

	*plight = (vk_point_light_t){0};
	VectorCopy(origin, plight->origin);
	plight->radius = radius;

	VectorScale(color, hack_attenuation, plight->base_color);
	VectorCopy(plight->base_color, plight->color);
	plight->lightstyle = lightstyle;

	// Omnidirectional light
	plight->stopdot = plight->stopdot2_or_costheta = -1.f;
	VectorSet(plight->dir, 0, 0, 0);

	addPointLightToClusters( index );
	g_lights_.num_point_lights++;
	return index;
}

static int addSpotLight( const vk_light_entity_t *le, float radius, float solid_angle, int lightstyle, float hack_attenuation, qboolean all_clusters, qboolean is_flashlight ) {
	const int index = g_lights_.num_point_lights;
	vk_point_light_t *const plight = g_lights_.point_lights + index;

	if (g_lights_.num_point_lights >= MAX_POINT_LIGHTS) {
		ERROR_THROTTLED(10, "Too many lights, MAX_POINT_LIGHTS=%d", MAX_POINT_LIGHTS);
		return -1;
	}

	if (debug_dump_lights.enabled) {
		DEBUG("%s light %d: origin=(%f %f %f) color=(%f %f %f) dir=(%f %f %f)",
			le->type == LightTypeEnvironment ? "environment" : "spot",
			index,
			le->origin[0], le->origin[1], le->origin[2],
			le->color[0], le->color[1], le->color[2],
			le->dir[0], le->dir[1], le->dir[2]);
	}

	*plight = (vk_point_light_t){0};
	VectorCopy(le->origin, plight->origin);
	plight->radius = radius;

	VectorCopy(plight->base_color, plight->color);
	plight->lightstyle = lightstyle;

	VectorCopy(le->dir, plight->dir);
	plight->stopdot = le->stopdot;

	if (le->type == LightTypeEnvironment) {
		// Baseline values
		const float kSunSolidAngle = 6.794e-5; // Wikipedia
		const float kSunCosTheta = 1. - kSunSolidAngle / (2 * M_PI);

		const float cos_theta_max = Q_min(kSunCosTheta, 1. - solid_angle / (2 * M_PI));

		// Make sure that the brightness is preserved
		// light.glsl will multiply color by one_over_pdf for future MIS reasons
		hack_attenuation /= (1. - cos_theta_max) / (1. - kSunCosTheta);

		plight->flags = LightFlag_Environment;
		plight->stopdot2_or_costheta = cos_theta_max;
	} else {
		plight->stopdot2_or_costheta = le->stopdot2;

		if (is_flashlight) {
			plight->flags |= LightFlag_Flashlight;
		}
	}

	VectorScale(le->color, hack_attenuation, plight->base_color);

	if (all_clusters)
		addPointLightToAllClusters( index );
	else
		addPointLightToClusters( index );

	g_lights_.num_point_lights++;
	return index;
}

void RT_LightAddFlashlight(const struct cl_entity_s *ent, qboolean local_player ) {
	// parameters
	const float hack_attenuation = 0.1f / 25.f;
	float radius = 1.0;
	// TODO: better tune it
	const float _cone = 10.0;
	const float _cone2 = 30.0;
	const vec3_t light_color = {255, 255, 192};
	float light_intensity = 300;

	vec3_t color;
	vec3_t origin;
	vec3_t angles;
	vk_light_entity_t le = { .type = LightTypeSpot };

	float thirdperson_offset = 25;
	vec3_t forward, view_ofs;
	vec3_t vecSrc, vecEnd;
	pmtrace_t *trace;
	if( local_player )
	{
		// local player case
		// position
		if (gEngine.EngineGetParm(PARM_THIRDPERSON, 0)) { // thirdperson
			AngleVectors( g_camera.viewangles, forward, NULL, NULL );
			view_ofs[0] = view_ofs[1] = 0.0f;
			if( ent->curstate.usehull == 1 ) {
				view_ofs[2] = 12.0f; // VEC_DUCK_VIEW;
			} else {
				view_ofs[2] = 28.0f; // DEFAULT_VIEWHEIGHT
			}
			VectorAdd( ent->origin, view_ofs, vecSrc );
			VectorMA( vecSrc, thirdperson_offset, forward, vecEnd );
			trace = gEngine.EV_VisTraceLine( vecSrc, vecEnd, PM_STUDIO_BOX );
			VectorCopy( trace->endpos, origin );
			VectorCopy( forward, le.dir);
		} else { // firstperson
			// based on https://github.com/SNMetamorph/PrimeXT/blob/0869b1abbddd13c1229769d8cd71941610be0bf3/client/flashlight.cpp#L35
			origin[0] = g_camera.vieworg[0] + (g_camera.vright[0] * (-4.0f)) + (g_camera.vforward[0] * 14.0); // forward-back
			origin[1] = g_camera.vieworg[1] + (g_camera.vright[1] * (-4.0f)) + (g_camera.vforward[1] * 14.0); // left-right
			origin[2] = g_camera.vieworg[2] + (g_camera.vright[2] * (-4.0f)) + (g_camera.vforward[2] * 14.0); // up-down
			origin[2] += 2.0f;
			VectorCopy(g_camera.vforward, le.dir);
		}
	}
	else // non-local player case
	{
		thirdperson_offset = 10;
		radius = 10;
		light_intensity = 60;

		VectorCopy( ent->angles, angles );
		// NOTE: pitch divided by 3.0 twice. So we need apply 3^2 = 9
		angles[PITCH] = ent->curstate.angles[PITCH] * 9.0f;
		angles[YAW] = ent->angles[YAW];
		angles[ROLL] = 0.0f; // roll not used

		AngleVectors( angles, angles, NULL, NULL );
		view_ofs[0] = view_ofs[1] = 0.0f;
		if( ent->curstate.usehull == 1 ) {
			view_ofs[2] = 12.0f; // VEC_DUCK_VIEW;
		} else {
			view_ofs[2] = 28.0f; // DEFAULT_VIEWHEIGHT
		}
		VectorAdd( ent->origin, view_ofs, vecSrc );
		VectorMA( vecSrc, thirdperson_offset, angles, vecEnd );
		trace = gEngine.EV_VisTraceLine( vecSrc, vecEnd, PM_STUDIO_BOX );
		VectorCopy( trace->endpos, origin );
		VectorCopy( angles, le.dir );
	}

	VectorCopy(origin, le.origin);

	// prepare colors by parseEntPropRgbav
	VectorScale(light_color, light_intensity / 255.0f, color);

	// convert colors by weirdGoldsrcLightScaling
	float l1 = Q_max(color[0], Q_max(color[1], color[2]));
	l1 = l1 * l1 / 10;
	VectorScale(color, l1, le.color);

	// convert stopdots by parseStopDot
	le.stopdot = cosf(_cone * M_PI / 180.f);
	le.stopdot2 = cosf(_cone2 * M_PI / 180.f);

	/*
	DEBUG("flashlight: origin=(%f %f %f) color=(%f %f %f) dir=(%f %f %f)",
		le.origin[0], le.origin[1], le.origin[2],
		le.color[0], le.color[1], le.color[2],
		le.dir[0], le.dir[1], le.dir[2]);
	*/

	const float solid_angle_unused = 0.;
	addSpotLight(&le, radius, 0, solid_angle_unused, hack_attenuation, false, true);
}

static float sphereSolidAngleFromDistDiv2Pi(float r, float d) {
	return 1. - sqrt(d*d - r*r)/d;
}

static qboolean addDlight( const dlight_t *dlight ) {
	const float k_light_radius = 2.f;
	const float k_threshold = 2.f;
	float max_comp;
	vec3_t color;
	float scaler;

	max_comp = Q_max(dlight->color.r, Q_max(dlight->color.g, dlight->color.b));
	if (max_comp < k_threshold || dlight->radius <= k_light_radius)
		return false;

	scaler = k_threshold / (max_comp * sphereSolidAngleFromDistDiv2Pi(k_light_radius, dlight->radius));

	// These constants are empirical. There's no known math reason behind them
	scaler /= 25.;

	VectorSet(
		color,
		dlight->color.r * scaler,
		dlight->color.g * scaler,
		dlight->color.b * scaler);

	addPointLight(dlight->origin, color, k_light_radius, -1, 1.f);
	return true;
}

static void processStaticPointLights( void ) {
	APROF_SCOPE_BEGIN_EARLY(static_lights);
	const model_t* const world = WORLDMODEL;
	ASSERT(world);

	g_lights_.num_point_lights = 0;
	for (int i = 0; i < g_map_entities.num_lights; ++i) {
		const vk_light_entity_t *le = g_map_entities.lights + i;
		const float default_radius = 2.f; // TODO tune
		const float radius = le->radius > 0.f ? le->radius : default_radius;

		// Expects skybox to be loaded already.
		const float solid_angle = le->solid_angle > 0.f ? le->solid_angle : R_TexturesGetSkyboxInfo().sun_solid_angle;

		// These constants are empirical. There's no known math reason behind them
		const float hack_attenuation = (le->type == LightTypeEnvironment)
			? 700.f // FIXME why?
			: .1f / 25.f; // FIXME why?

		int index;
		switch (le->type) {
			case LightTypePoint:
				index = addPointLight(le->origin, le->color, radius, le->style, hack_attenuation);
				break;

			case LightTypeEnvironment:
			case LightTypeSpot:
				index = addSpotLight(le, radius, solid_angle, le->style, hack_attenuation, i == g_map_entities.single_environment_index, false);
				break;

			default:
				ASSERT(!"Unexpected light type");
				continue;
		}

		if (index < 0)
			break;
	}
	APROF_SCOPE_END(static_lights);
}

void RT_LightsLoadBegin( const struct model_s *map ) {
	// Load RAD data based on map name
	{
		int name_len = Q_strlen(map->name);

		// Strip ".bsp" suffix
		if (name_len > 4 && 0 == Q_stricmp(map->name + name_len - 4, ".bsp"))
			name_len -= 4;

		memset(g_lights_.map.emissive_textures, 0, sizeof(g_lights_.map.emissive_textures));
		const qboolean loaded = loadRadData( map, "maps/lights.rad" ) | loadRadData( map, "%.*s.rad", name_len, map->name );
		if (!loaded) {
			ERR("No RAD files loaded. The map will be completely black");
		}
	}

	// Clear static lights counts
	{
		g_lights_.num_polygons = g_lights_.num_static.polygons = 0;
		g_lights_.num_point_lights = g_lights_.num_static.point_lights = 0;
		g_lights_.num_polygon_vertices = g_lights_.num_static.polygon_vertices = 0;
		memset(g_lights_.polygon_rect_candidate, 0, sizeof(g_lights_.polygon_rect_candidate));

		for (int i = 0; i < g_lights_.grid.cells; ++i) {
			vk_lights_cell_t *const cell = g_lights_.cells + i;
			cell->num_point_lights = cell->num_static.point_lights = 0;
			cell->num_polygons = cell->num_static.polygons = 0;
			cell->frame_sequence = g_lights_.frame_sequence;
		}
	}

	processStaticPointLights();
}

void RT_LightsLoadEnd( void ) {
	//debug_dump_lights.enabled = true;

	// Fix static counts
	{
		g_lights_.num_static.polygons = g_lights_.num_polygons;
		g_lights_.num_static.point_lights = g_lights_.num_point_lights;
		g_lights_.num_static.polygon_vertices = g_lights_.num_polygon_vertices;

		for (int i = 0; i < g_lights_.grid.cells; ++i) {
			vk_lights_cell_t *const cell = g_lights_.cells + i;
			cell->num_static.point_lights = cell->num_point_lights;
			cell->num_static.polygons = cell->num_polygons;
		}
	}

	g_lights_.stats.dirty_cells = g_lights_.grid.cells;
}

qboolean RT_GetEmissiveForTexture( vec3_t out, int texture_id ) {
	ASSERT(texture_id >= 0);
	ASSERT(texture_id < MAX_TEXTURES);

	vk_emissive_texture_t *const etex = g_lights_.map.emissive_textures + texture_id;
	if (etex->set) {
		VectorCopy(etex->emissive, out);
		return true;
	} else {
		VectorClear(out);
		return false;
	}
}

static void addPolygonLightIndexToLeaf(const mleaf_t* leaf, int poly_index) {
	const int min_x = floorf(leaf->minmaxs[0] / LIGHT_GRID_CELL_SIZE);
	const int min_y = floorf(leaf->minmaxs[1] / LIGHT_GRID_CELL_SIZE);
	const int min_z = floorf(leaf->minmaxs[2] / LIGHT_GRID_CELL_SIZE);

	const int max_x = floorf(leaf->minmaxs[3] / LIGHT_GRID_CELL_SIZE) + 1;
	const int max_y = floorf(leaf->minmaxs[4] / LIGHT_GRID_CELL_SIZE) + 1;
	const int max_z = floorf(leaf->minmaxs[5] / LIGHT_GRID_CELL_SIZE) + 1;

	const qboolean not_visible = false; //TODO static_map && !canSurfaceLightAffectAABB(world, geom->surf, esurf->emissive, leaf->minmaxs);

	if (debug_dump_lights.enabled) {
		DEBUG("  adding leaf %d min=(%d, %d, %d), max=(%d, %d, %d) total=%d",
			leaf->cluster,
			min_x, min_y, min_z,
			max_x, max_y, max_z,
			(max_x - min_x) * (max_y - min_y) * (max_z - min_z)
		);
	}

	if (not_visible)
		return;

	for (int x = min_x; x < max_x; ++x)
	for (int y = min_y; y < max_y; ++y)
	for (int z = min_z; z < max_z; ++z) {
		const int cell[3] = {
			x - g_lights_.grid.min_cell[0],
			y - g_lights_.grid.min_cell[1],
			z - g_lights_.grid.min_cell[2]
		};

		const int cell_index = RT_LightCellIndex( cell );
		if (cell_index < 0)
			continue;

		if (bitArrayCheckOrSet(&g_lights_.visited_cells, cell_index)) {
			/*
			const float minmaxs[6] = {
				x * LIGHT_GRID_CELL_SIZE,
				y * LIGHT_GRID_CELL_SIZE,
				z * LIGHT_GRID_CELL_SIZE,
				(x+1) * LIGHT_GRID_CELL_SIZE,
				(y+1) * LIGHT_GRID_CELL_SIZE,
				(z+1) * LIGHT_GRID_CELL_SIZE,
			};

			TODO if (static_map && !canSurfaceLightAffectAABB(world, geom->surf, esurf->emissive, minmaxs)) */
			/* 	continue; */

			if (!addSurfaceLightToCell(cell_index, poly_index)) {
				ERROR_THROTTLED(10, "Cluster %d,%d,%d(%d) ran out of polygon light slots",
					cell[0], cell[1],  cell[2], cell_index);
			}
		}
	}
}

static void addPolygonLightToAllClusters( int poly_index ) {
	const model_t* const world = WORLDMODEL;

	// FIXME there's certainly a better way to do this: just enumerate
	// all clusters, not all leafs

	bitArrayClear(&g_lights_.visited_cells);
	for (int i = 1; i <= world->numleafs; ++i) {
		const mleaf_t *const leaf = world->leafs + i;
		addPolygonLightIndexToLeaf( leaf, poly_index );
	}
}

static void addPolygonLeafSetToClusters(const vk_light_leaf_set_t *leafs, int poly_index) {
	const model_t* const world = WORLDMODEL;

	// FIXME this shouldn't happen in prod
	if (!leafs)
		return;

	bitArrayClear(&g_lights_.visited_cells);

	// Iterate through each visible/potentially affected leaf to get a range of grid cells
	for (int i = 0; i < leafs->num; ++i) {
		const mleaf_t *const leaf = world->leafs + leafs->leafs[i];
		addPolygonLightIndexToLeaf(leaf, poly_index);
	}
}

int RT_LightAddPolygon(const rt_light_add_polygon_t *addpoly) {
	// FIXME We're adding lights directly from vk_brush.c w/o knowing whether current frame is
	// ray traced. If not, this will break.
	if (addpoly->dynamic && !vk_frame.rtx_enabled)
		return -1;

	if (g_lights_.num_polygons == MAX_SURFACE_LIGHTS) {
		ERROR_THROTTLED(10, "Max number of polygon lights %d reached", MAX_SURFACE_LIGHTS);
		return -1;
	}

	ASSERT(addpoly->num_vertices > 2);
	ASSERT(addpoly->num_vertices < 8);
	ASSERT(g_lights_.num_polygon_vertices + addpoly->num_vertices <= COUNTOF(g_lights_.polygon_vertices));

	{
		APROF_SCOPE_DECLARE_BEGIN(add_polygon, __FUNCTION__);
		rt_light_polygon_t *const poly = g_lights_.polygons + g_lights_.num_polygons;
		vec3_t *vertices = g_lights_.polygon_vertices + g_lights_.num_polygon_vertices;
		vec3_t normal;

		poly->vertices.offset = g_lights_.num_polygon_vertices;
		poly->vertices.count = addpoly->num_vertices;

		{
			// These constants are empirical. There's no known math reason behind them
			const float hack_attenuation_poly = 1.f / 25.f;
			VectorScale(addpoly->emissive, hack_attenuation_poly, poly->emissive);
		}

		VectorSet(poly->center, 0, 0, 0);
		VectorSet(normal, 0, 0, 0);

		for (int i = 0; i < addpoly->num_vertices; ++i) {
			if (addpoly->transform_row)
				Matrix3x4_VectorTransform(*addpoly->transform_row, addpoly->vertices[i], vertices[i]);
			else
				VectorCopy(addpoly->vertices[i], vertices[i]);
			VectorAdd(vertices[i], poly->center, poly->center);

			if (i > 1) {
				vec3_t e[2], lnormal;
				VectorSubtract(vertices[i-0], vertices[0], e[0]);
				VectorSubtract(vertices[i-1], vertices[0], e[1]);
				CrossProduct(e[0], e[1], lnormal);
				VectorAdd(lnormal, normal, normal);
			}
		}

		poly->area = VectorLength(normal);
		if (poly->area <= 0) {
			ERR("%s: Polygon light has zero area", __FUNCTION__);
			return -1;
		}

		VectorM(1.f / poly->area, normal, poly->plane);
		poly->plane[3] = -DotProduct(vertices[0], poly->plane);

		VectorM(1.f / poly->vertices.count, poly->center, poly->center);

		if (!addpoly->dynamic || debug_dump_lights.enabled) {
			DEBUG("added polygon light index=%d color=(%f, %f, %f) center=(%f, %f, %f) plane=(%f, %f, %f, %f) area=%f num_vertices=%d",
				g_lights_.num_polygons,
				poly->emissive[0],
				poly->emissive[1],
				poly->emissive[2],
				poly->center[0],
				poly->center[1],
				poly->center[2],
				poly->plane[0],
				poly->plane[1],
				poly->plane[2],
				poly->plane[3],
				poly->area,
				poly->vertices.count
			);
		}

		const model_t* const world = WORLDMODEL;
		if (world->visdata) {
			const vk_light_leaf_set_t *const leafs = addpoly->dynamic
				? getMapLeafsAffectedByMovingSurface( addpoly->surface, addpoly->transform_row )
				: getMapLeafsAffectedByMapSurface( addpoly->surface );
			addPolygonLeafSetToClusters(leafs, g_lights_.num_polygons);
		} else {
			addPolygonLightToAllClusters( g_lights_.num_polygons );
		}

		// Candidate for merge; final rectangle validation runs later after collinear cleanup.
		g_lights_.polygon_rect_candidate[g_lights_.num_polygons] = (addpoly->num_vertices >= 4);
		g_lights_.num_polygon_vertices += addpoly->num_vertices;
		APROF_SCOPE_END(add_polygon);
		return g_lights_.num_polygons++;
	}
}

void RT_LightsFrameBegin( void ) {
	g_lights_.num_polygons = g_lights_.num_static.polygons;
	g_lights_.num_point_lights = g_lights_.num_static.point_lights;
	g_lights_.num_polygon_vertices = g_lights_.num_static.polygon_vertices;

	for (int i = 0; i < g_lights_.grid.cells; ++i) {
		vk_lights_cell_t *const cell = g_lights_.cells + i;
		cell->num_polygons = cell->num_static.polygons;
		cell->num_point_lights = cell->num_static.point_lights;
	}
}

static void lightMergeResetState(rt_light_merge_state_t *state) {
	state->num_rects = 0;
	state->num_bvh_nodes = 0;
	state->bvh_root = -1;
	state->merged_num_polygons = 0;
	state->merged_num_vertices = 0;
	state->isolated_self_only_count = 0;

	for (int i = 0; i < MAX_SURFACE_LIGHTS; ++i) {
		state->source_to_merged[i] = -1;
	}
}

static void lightMergeCalcBounds4(const vec3_t *vertices, float mins[3], float maxs[3]) {
	VectorCopy(vertices[0], mins);
	VectorCopy(vertices[0], maxs);
	for (int i = 1; i < 4; ++i) {
		for (int k = 0; k < 3; ++k) {
			mins[k] = Q_min(mins[k], vertices[i][k]);
			maxs[k] = Q_max(maxs[k], vertices[i][k]);
		}
	}
}

static void lightMergeFinalizeRect(rt_light_merge_rect_t *rect) {
	vec3_t normal;
	VectorSet(rect->center, 0, 0, 0);
	VectorSet(normal, 0, 0, 0);

	for (int i = 0; i < 4; ++i) {
		VectorAdd(rect->vertices[i], rect->center, rect->center);
		if (i > 1) {
			vec3_t e[2], lnormal;
			VectorSubtract(rect->vertices[i], rect->vertices[0], e[0]);
			VectorSubtract(rect->vertices[i - 1], rect->vertices[0], e[1]);
			CrossProduct(e[0], e[1], lnormal);
			VectorAdd(lnormal, normal, normal);
		}
	}

	VectorM(1.f / 4.f, rect->center, rect->center);

	rect->area = VectorLength(normal);
	if (rect->area <= 0.f) {
		VectorSet(rect->plane, 0, 0, 1);
		rect->plane[3] = 0.f;
		rect->area = 1.f;
	} else {
		VectorM(1.f / rect->area, normal, rect->plane);
		// Use polygon centroid for stable plane origin.
		rect->plane[3] = -DotProduct(rect->center, rect->plane);
	}

	lightMergeCalcBounds4((const vec3_t*)rect->vertices, rect->mins, rect->maxs);
	for (int i = 0; i < 3; ++i) {
		rect->mins[i] -= LIGHT_MERGE_AABB_EPSILON;
		rect->maxs[i] += LIGHT_MERGE_AABB_EPSILON;
	}
}

static qboolean lightMergeColorMatch(const vec3_t a, const vec3_t b) {
	return fabsf(a[0] - b[0]) <= LIGHT_MERGE_COLOR_EPSILON
		&& fabsf(a[1] - b[1]) <= LIGHT_MERGE_COLOR_EPSILON
		&& fabsf(a[2] - b[2]) <= LIGHT_MERGE_COLOR_EPSILON;
}

static qboolean lightMergeRectCompatible(const rt_light_merge_rect_t *a, const rt_light_merge_rect_t *b) {
	if (!lightMergeColorMatch(a->emissive, b->emissive))
		return false;

	if (fabsf(a->plane[0] - b->plane[0]) > LIGHT_MERGE_NORMAL_COMPONENT_EPSILON)
		return false;
	if (fabsf(a->plane[1] - b->plane[1]) > LIGHT_MERGE_NORMAL_COMPONENT_EPSILON)
		return false;
	if (fabsf(a->plane[2] - b->plane[2]) > LIGHT_MERGE_NORMAL_COMPONENT_EPSILON)
		return false;

	for (int i = 0; i < 3; ++i) {
		if (a->maxs[i] + LIGHT_MERGE_POS_EPSILON < b->mins[i])
			return false;
		if (b->maxs[i] + LIGHT_MERGE_POS_EPSILON < a->mins[i])
			return false;
	}

	return true;
}

static qboolean lightMergePointNear(const vec3_t a, const vec3_t b, float eps) {
	const float dx = a[0] - b[0];
	const float dy = a[1] - b[1];
	const float dz = a[2] - b[2];
	return (dx * dx + dy * dy + dz * dz) <= (eps * eps);
}

static qboolean lightMergePointOnSegment(const vec3_t p, const vec3_t a, const vec3_t b, float eps) {
	vec3_t ab;
	vec3_t ap;
	vec3_t cross;
	VectorSubtract(b, a, ab);
	VectorSubtract(p, a, ap);

	const float ab_len2 = DotProduct(ab, ab);
	if (ab_len2 <= eps * eps)
		return lightMergePointNear(p, a, eps);

	CrossProduct(ap, ab, cross);
	const float cross_len2 = DotProduct(cross, cross);
	if (cross_len2 > (eps * eps) * ab_len2)
		return false;

	const float t = DotProduct(ap, ab) / ab_len2;
	return t >= -0.01f && t <= 1.01f;
}

static int lightMergeAppendUniquePoint(vec3_t *points, int count, const vec3_t point, float eps) {
	for (int i = 0; i < count; ++i) {
		if (lightMergePointNear(points[i], point, eps))
			return count;
	}

	VectorCopy(point, points[count]);
	return count + 1;
}

static int lightMergeCompactVertices(vec3_t *vertices, int count, float eps) {
	if (count <= 0)
		return 0;
	if (count > LIGHT_MERGE_MAX_SOURCE_VERTICES)
		count = LIGHT_MERGE_MAX_SOURCE_VERTICES;

	vec3_t compact[LIGHT_MERGE_MAX_SOURCE_VERTICES];
	int compact_count = 0;

	for (int i = 0; i < count; ++i) {
		if (compact_count >= LIGHT_MERGE_MAX_SOURCE_VERTICES)
			break;
		if (compact_count == 0 || !lightMergePointNear(compact[compact_count - 1], vertices[i], eps)) {
			VectorCopy(vertices[i], compact[compact_count++]);
		}
	}

	if (compact_count > 1 && lightMergePointNear(compact[0], compact[compact_count - 1], eps))
		compact_count--;

	for (int i = 0; i < compact_count; ++i)
		VectorCopy(compact[i], vertices[i]);

	return compact_count;
}

static int lightMergeRemoveCollinearVertices(vec3_t *vertices, int count, float eps) {
	qboolean changed;
	do {
		changed = false;
		for (int i = 0; i < count; ++i) {
			if (count <= 3)
				return count;

			const int prev = (i - 1 + count) % count;
			const int next = (i + 1) % count;
			if (!lightMergePointOnSegment(vertices[i], vertices[prev], vertices[next], eps))
				continue;

			for (int j = i; j < count - 1; ++j) {
				VectorCopy(vertices[j + 1], vertices[j]);
			}
			count--;
			changed = true;
			break;
		}
	} while (changed);

	return count;
}

static qboolean lightMergeExtractRectFromPolygon(const rt_light_polygon_t *src, int src_poly_index, rt_light_merge_rect_t *out) {
	if (!src || !out)
		return false;

	if (src->vertices.count < 4 || src->vertices.count > LIGHT_MERGE_MAX_SOURCE_VERTICES)
		return false;
	if (src->vertices.offset < 0)
		return false;
	if (src->vertices.offset + src->vertices.count > g_lights_.num_polygon_vertices)
		return false;
	if (src->vertices.offset + src->vertices.count > (int)COUNTOF(g_lights_.polygon_vertices))
		return false;

	vec3_t vertices[LIGHT_MERGE_MAX_SOURCE_VERTICES];
	for (int i = 0; i < src->vertices.count; ++i) {
		VectorCopy(g_lights_.polygon_vertices[src->vertices.offset + i], vertices[i]);
	}

	int count = lightMergeCompactVertices(vertices, src->vertices.count, LIGHT_MERGE_POS_EPSILON);
	count = lightMergeRemoveCollinearVertices(vertices, count, LIGHT_MERGE_LINE_EPSILON);
	if (count != 4)
		return false;

	*out = (rt_light_merge_rect_t){0};
	out->src_poly_index = src_poly_index;
	VectorCopy(src->emissive, out->emissive);
	for (int i = 0; i < 4; ++i) {
		VectorCopy(vertices[i], out->vertices[i]);
	}
	lightMergeFinalizeRect(out);
	return true;
}

static int lightMergeProjectAxisForRect(const rt_light_merge_rect_t *rect, int axis, vec3_t out) {
	vec3_t candidate;
	for (int i = 0; i < 4; ++i) {
		const int j = (i + axis) & 3;
		VectorSubtract(rect->vertices[(j + 1) & 3], rect->vertices[j], candidate);
		if (VectorLength(candidate) > LIGHT_MERGE_POS_EPSILON) {
			VectorNormalize(candidate);
			VectorCopy(candidate, out);
			return 1;
		}
	}

	return 0;
}

static qboolean lightMergeTryCombineRectangles(
	const rt_light_merge_rect_t *a,
	const rt_light_merge_rect_t *b,
	rt_light_merge_rect_t *out) {
	if (!lightMergeRectCompatible(a, b))
		return false;

	vec3_t shared_points[16];
	int shared = 0;
	for (int i = 0; i < 4; ++i) {
		const vec3_t p = { a->vertices[i][0], a->vertices[i][1], a->vertices[i][2] };
		for (int e = 0; e < 4; ++e) {
			const int e_next = (e + 1) & 3;
			if (lightMergePointOnSegment(p, b->vertices[e], b->vertices[e_next], LIGHT_MERGE_LINE_EPSILON)) {
				shared = lightMergeAppendUniquePoint(shared_points, shared, p, LIGHT_MERGE_POS_EPSILON);
				break;
			}
		}
	}
	for (int i = 0; i < 4; ++i) {
		const vec3_t p = { b->vertices[i][0], b->vertices[i][1], b->vertices[i][2] };
		for (int e = 0; e < 4; ++e) {
			const int e_next = (e + 1) & 3;
			if (lightMergePointOnSegment(p, a->vertices[e], a->vertices[e_next], LIGHT_MERGE_LINE_EPSILON)) {
				shared = lightMergeAppendUniquePoint(shared_points, shared, p, LIGHT_MERGE_POS_EPSILON);
				break;
			}
		}
	}

	if (shared < 2)
		return false;

	vec3_t points[8];
	int points_count = 0;
	for (int i = 0; i < 4; ++i)
		points_count = lightMergeAppendUniquePoint(points, points_count, a->vertices[i], LIGHT_MERGE_POS_EPSILON);
	for (int i = 0; i < 4; ++i)
		points_count = lightMergeAppendUniquePoint(points, points_count, b->vertices[i], LIGHT_MERGE_POS_EPSILON);

	if (points_count < 4)
		return false;

	vec3_t u;
	vec3_t v;
	if (!lightMergeProjectAxisForRect(a, 0, u))
		return false;
	CrossProduct(a->plane, u, v);
	if (VectorLength(v) <= LIGHT_MERGE_POS_EPSILON)
		return false;
	VectorNormalize(v);

	vec3_t plane_origin;
	VectorM(-a->plane[3], a->plane, plane_origin);

	float min_u = FLT_MAX;
	float max_u = -FLT_MAX;
	float min_v = FLT_MAX;
	float max_v = -FLT_MAX;

	for (int i = 0; i < points_count; ++i) {
		vec3_t rel;
		VectorSubtract(points[i], plane_origin, rel);
		const float pu = DotProduct(rel, u);
		const float pv = DotProduct(rel, v);
		min_u = Q_min(min_u, pu);
		max_u = Q_max(max_u, pu);
		min_v = Q_min(min_v, pv);
		max_v = Q_max(max_v, pv);
	}

	*out = *a;

	VectorCopy(plane_origin, out->vertices[0]);
	VectorMA(out->vertices[0], min_u, u, out->vertices[0]);
	VectorMA(out->vertices[0], min_v, v, out->vertices[0]);

	VectorCopy(plane_origin, out->vertices[1]);
	VectorMA(out->vertices[1], max_u, u, out->vertices[1]);
	VectorMA(out->vertices[1], min_v, v, out->vertices[1]);

	VectorCopy(plane_origin, out->vertices[2]);
	VectorMA(out->vertices[2], max_u, u, out->vertices[2]);
	VectorMA(out->vertices[2], max_v, v, out->vertices[2]);

	VectorCopy(plane_origin, out->vertices[3]);
	VectorMA(out->vertices[3], min_u, u, out->vertices[3]);
	VectorMA(out->vertices[3], max_v, v, out->vertices[3]);

	vec3_t e01;
	vec3_t e12;
	vec3_t winding_n;
	VectorSubtract(out->vertices[1], out->vertices[0], e01);
	VectorSubtract(out->vertices[2], out->vertices[1], e12);
	CrossProduct(e01, e12, winding_n);
	if (DotProduct(winding_n, a->plane) < 0.f) {
		vec3_t tmp;
		VectorCopy(out->vertices[1], tmp);
		VectorCopy(out->vertices[3], out->vertices[1]);
		VectorCopy(tmp, out->vertices[3]);
	}

	lightMergeFinalizeRect(out);
	return true;
}

static void lightMergeBuildNodeBounds(rt_light_merge_state_t *state, int begin, int count, float mins[3], float maxs[3]) {
	const rt_light_merge_rect_t *const first = &state->rects[state->rect_indices[begin]];
	VectorCopy(first->mins, mins);
	VectorCopy(first->maxs, maxs);

	for (int i = 1; i < count; ++i) {
		const rt_light_merge_rect_t *const rect = &state->rects[state->rect_indices[begin + i]];
		for (int k = 0; k < 3; ++k) {
			mins[k] = Q_min(mins[k], rect->mins[k]);
			maxs[k] = Q_max(maxs[k], rect->maxs[k]);
		}
	}
}

static float lightMergeRectCenterAxis(const rt_light_merge_state_t *state, int rect_index, int axis) {
	const rt_light_merge_rect_t *const rect = &state->rects[rect_index];
	return (rect->mins[axis] + rect->maxs[axis]) * 0.5f;
}

static void lightMergeSortIndices(rt_light_merge_state_t *state, int begin, int count, int axis) {
	for (int i = begin + 1; i < begin + count; ++i) {
		const int key = state->rect_indices[i];
		const float key_center = lightMergeRectCenterAxis(state, key, axis);
		int j = i - 1;
		while (j >= begin && lightMergeRectCenterAxis(state, state->rect_indices[j], axis) > key_center) {
			state->rect_indices[j + 1] = state->rect_indices[j];
			--j;
		}
		state->rect_indices[j + 1] = key;
	}
}

static int lightMergeBuildBvh(rt_light_merge_state_t *state, int begin, int count) {
	if (count <= 0 || state->num_bvh_nodes >= LIGHT_MERGE_MAX_BVH_NODES)
		return -1;

	const int node_index = state->num_bvh_nodes++;
	rt_light_merge_bvh_node_t *const node = &state->bvh_nodes[node_index];

	lightMergeBuildNodeBounds(state, begin, count, node->mins, node->maxs);
	node->left = -1;
	node->right = -1;
	node->begin = begin;
	node->count = count;

	if (count <= 4)
		return node_index;

	const float extents[3] = {
		node->maxs[0] - node->mins[0],
		node->maxs[1] - node->mins[1],
		node->maxs[2] - node->mins[2],
	};
	int axis = 0;
	if (extents[1] > extents[axis]) axis = 1;
	if (extents[2] > extents[axis]) axis = 2;

	lightMergeSortIndices(state, begin, count, axis);

	const int left_count = count / 2;
	const int right_count = count - left_count;
	node->left = lightMergeBuildBvh(state, begin, left_count);
	node->right = lightMergeBuildBvh(state, begin + left_count, right_count);
	node->begin = 0;
	node->count = 0;

	return node_index;
}

static qboolean lightMergeAabbIntersect(const float mins_a[3], const float maxs_a[3], const float mins_b[3], const float maxs_b[3]) {
	for (int i = 0; i < 3; ++i) {
		if (maxs_a[i] < mins_b[i] || maxs_b[i] < mins_a[i])
			return false;
	}
	return true;
}

static int lightMergeFindNeighbors(rt_light_merge_state_t *state, const rt_light_merge_rect_t *rect, int self_rect_index) {
	if (state->bvh_root < 0)
		return 0;

	float query_mins[3];
	float query_maxs[3];
	for (int i = 0; i < 3; ++i) {
		query_mins[i] = rect->mins[i] - LIGHT_MERGE_POS_EPSILON;
		query_maxs[i] = rect->maxs[i] + LIGHT_MERGE_POS_EPSILON;
	}

	int stack[LIGHT_MERGE_MAX_BVH_NODES];
	int top = 0;
	stack[top++] = state->bvh_root;

	int neighbors_count = 0;
	while (top > 0) {
		const int node_index = stack[--top];
		if (node_index < 0)
			continue;

		const rt_light_merge_bvh_node_t *const node = &state->bvh_nodes[node_index];
		if (!lightMergeAabbIntersect(query_mins, query_maxs, node->mins, node->maxs))
			continue;

		if (node->left < 0 && node->right < 0) {
			for (int i = 0; i < node->count; ++i) {
				const int rect_index = state->rect_indices[node->begin + i];
				if (rect_index == self_rect_index || state->rect_taken[rect_index])
					continue;

				if (neighbors_count >= LIGHT_MERGE_MAX_NEIGHBORS)
					return neighbors_count;
				state->neighbors[neighbors_count++] = rect_index;
			}
			continue;
		}

		if (node->left >= 0 && top < LIGHT_MERGE_MAX_BVH_NODES)
			stack[top++] = node->left;
		if (node->right >= 0 && top < LIGHT_MERGE_MAX_BVH_NODES)
			stack[top++] = node->right;
	}

	return neighbors_count;
}

static int lightMergeCountOverlapsSelfOnlyAware(rt_light_merge_state_t *state, const rt_light_merge_rect_t *rect, int self_rect_index) {
	if (state->bvh_root < 0)
		return 0;

	float query_mins[3];
	float query_maxs[3];
	for (int i = 0; i < 3; ++i) {
		query_mins[i] = rect->mins[i] - LIGHT_MERGE_POS_EPSILON;
		query_maxs[i] = rect->maxs[i] + LIGHT_MERGE_POS_EPSILON;
	}

	int stack[LIGHT_MERGE_MAX_BVH_NODES];
	int top = 0;
	stack[top++] = state->bvh_root;

	int overlaps_count = 0;
	while (top > 0) {
		const int node_index = stack[--top];
		if (node_index < 0)
			continue;

		const rt_light_merge_bvh_node_t *const node = &state->bvh_nodes[node_index];
		if (!lightMergeAabbIntersect(query_mins, query_maxs, node->mins, node->maxs))
			continue;

		if (node->left < 0 && node->right < 0) {
			for (int i = 0; i < node->count; ++i) {
				const int rect_index = state->rect_indices[node->begin + i];
				if (rect_index != self_rect_index && state->rect_taken[rect_index])
					continue;
				overlaps_count++;
			}
			continue;
		}

		if (node->left >= 0 && top < LIGHT_MERGE_MAX_BVH_NODES)
			stack[top++] = node->left;
		if (node->right >= 0 && top < LIGHT_MERGE_MAX_BVH_NODES)
			stack[top++] = node->right;
	}

	return overlaps_count;
}

static int lightMergeAppendRectAsPolygon(rt_light_merge_state_t *state, const rt_light_merge_rect_t *rect) {
	if (state->merged_num_polygons >= MAX_SURFACE_LIGHTS) {
		ERROR_THROTTLED(10, "Max number of merged polygon lights %d reached", MAX_SURFACE_LIGHTS);
		return -1;
	}

	if (state->merged_num_vertices + 4 > COUNTOF(state->merged_vertices)) {
		ERROR_THROTTLED(10, "Max number of merged polygon vertices %d reached", (int)COUNTOF(state->merged_vertices));
		return -1;
	}

	const int index = state->merged_num_polygons++;
	rt_light_polygon_t *const poly = &state->merged_polygons[index];
	*poly = (rt_light_polygon_t){0};
	Vector4Copy(rect->plane, poly->plane);
	VectorCopy(rect->center, poly->center);
	poly->area = rect->area;
	VectorCopy(rect->emissive, poly->emissive);
	poly->vertices.offset = state->merged_num_vertices;
	poly->vertices.count = 4;

	for (int i = 0; i < 4; ++i)
		VectorCopy(rect->vertices[i], state->merged_vertices[state->merged_num_vertices + i]);
	state->merged_num_vertices += 4;

	return index;
}

static int lightMergeAppendSourcePolygon(rt_light_merge_state_t *state, int source_poly_index) {
	const rt_light_polygon_t *const src = g_lights_.polygons + source_poly_index;

	if (state->merged_num_polygons >= MAX_SURFACE_LIGHTS) {
		ERROR_THROTTLED(10, "Max number of merged polygon lights %d reached", MAX_SURFACE_LIGHTS);
		return -1;
	}

	if (state->merged_num_vertices + src->vertices.count > COUNTOF(state->merged_vertices)) {
		ERROR_THROTTLED(10, "Max number of merged polygon vertices %d reached", (int)COUNTOF(state->merged_vertices));
		return -1;
	}

	const int index = state->merged_num_polygons++;
	rt_light_polygon_t *const dst = &state->merged_polygons[index];
	*dst = *src;
	dst->vertices.offset = state->merged_num_vertices;

	for (int i = 0; i < src->vertices.count; ++i) {
		VectorCopy(g_lights_.polygon_vertices[src->vertices.offset + i], state->merged_vertices[state->merged_num_vertices + i]);
	}
	state->merged_num_vertices += src->vertices.count;
	return index;
}

static void lightMergeCollectRectangles(rt_light_merge_state_t *state) {
	for (int i = 0; i < g_lights_.num_polygons; ++i) {
		const rt_light_polygon_t *const src = g_lights_.polygons + i;
		if (!g_lights_.polygon_rect_candidate[i])
			continue;

		if (state->num_rects >= LIGHT_MERGE_MAX_RECTS)
			break;

		rt_light_merge_rect_t *const rect = &state->rects[state->num_rects];
		if (!lightMergeExtractRectFromPolygon(src, i, rect))
			continue;

		state->rect_indices[state->num_rects] = state->num_rects;
		state->rect_taken[state->num_rects] = 0;
		state->num_rects++;
	}
}

static void lightMergeBuildMergedPolygons(void) {
	rt_light_merge_state_t *const state = &g_lights_.merge;
	lightMergeResetState(state);

	lightMergeCollectRectangles(state);

	if (state->num_rects > 0) {
		state->num_bvh_nodes = 0;
		state->bvh_root = lightMergeBuildBvh(state, 0, state->num_rects);
	}

	for (int i = 0; i < state->num_rects; ++i) {
		if (state->rect_taken[i])
			continue;

		if (lightMergeCountOverlapsSelfOnlyAware(state, &state->rects[i], i) <= 1) {
			// This source overlaps only with itself in BVH, no merge candidates nearby.
			state->rect_taken[i] = 1;
			state->isolated_self_only_count++;
			continue;
		}

		rt_light_merge_rect_t current = state->rects[i];
		int group_count = 0;
		state->working_group[group_count++] = i;
		state->rect_taken[i] = 1;

		while (1) {
			qboolean merged_this_pass = false;
			const int neighbors_count = lightMergeFindNeighbors(state, &current, i);
			for (int n = 0; n < neighbors_count; ++n) {
				const int neighbor_index = state->neighbors[n];
				if (state->rect_taken[neighbor_index])
					continue;

				rt_light_merge_rect_t combined;
				if (!lightMergeTryCombineRectangles(&current, &state->rects[neighbor_index], &combined))
					continue;

				current = combined;
				state->rect_taken[neighbor_index] = 1;
				if (group_count < LIGHT_MERGE_MAX_NEIGHBORS)
					state->working_group[group_count++] = neighbor_index;
				merged_this_pass = true;
				// Restart from the beginning of neighbor scan after any successful merge.
				break;
			}

			if (!merged_this_pass)
				break;
		}

		const int merged_index = lightMergeAppendRectAsPolygon(state, &current);
		if (merged_index < 0)
			continue;

		for (int g = 0; g < group_count; ++g) {
			const int src_poly_index = state->rects[state->working_group[g]].src_poly_index;
			state->source_to_merged[src_poly_index] = merged_index;
		}
	}

	for (int i = 0; i < g_lights_.num_polygons; ++i) {
		if (state->source_to_merged[i] >= 0)
			continue;

		const int merged_index = lightMergeAppendSourcePolygon(state, i);
		if (merged_index < 0)
			break;
		state->source_to_merged[i] = merged_index;
	}
}

static void lightMergeBuildBypassPolygons(struct LightsMetadata *metadata) {
	rt_light_merge_state_t *const state = &g_lights_.merge;
	state->merged_num_polygons = g_lights_.num_polygons;
	state->merged_num_vertices = g_lights_.num_polygon_vertices;

	for (int i = 0; i < MAX_SURFACE_LIGHTS; ++i)
		state->source_to_merged[i] = -1;

	for (int i = 0; i < g_lights_.num_polygons; ++i)
		state->source_to_merged[i] = i;

	ASSERT(g_lights_.num_polygons <= MAX_EMISSIVE_KUSOCHKI);
	metadata->num_polygons = g_lights_.num_polygons;
	for (int i = 0; i < g_lights_.num_polygons; ++i) {
		const rt_light_polygon_t *const src_poly = g_lights_.polygons + i;
		struct PolygonLight *const dst_poly = metadata->polygons + i;

		Vector4Copy(src_poly->plane, dst_poly->plane);
		VectorCopy(src_poly->center, dst_poly->center);
		dst_poly->area = src_poly->area;
		VectorCopy(src_poly->emissive, dst_poly->emissive);

		ASSERT(src_poly->vertices.count > 2);
		ASSERT(src_poly->vertices.offset < 0xffffu);
		ASSERT(src_poly->vertices.count < 0xffffu);
		ASSERT(src_poly->vertices.offset + src_poly->vertices.count < COUNTOF(metadata->polygon_vertices));
		dst_poly->vertices_count_offset = (src_poly->vertices.count << 16) | (src_poly->vertices.offset);
	}

	ASSERT(g_lights_.num_polygon_vertices <= COUNTOF(metadata->polygon_vertices));
	for (int i = 0; i < g_lights_.num_polygon_vertices; ++i) {
		VectorCopy(g_lights_.polygon_vertices[i], metadata->polygon_vertices[i]);
	}
}

static void lightMergePrintFirstEnableStats(void) {
	rt_light_merge_state_t *const state = &g_lights_.merge;

	int total_lights = g_lights_.num_polygons;
	int is_merge_candidate[MAX_SURFACE_LIGHTS] = {0};
	int merge_candidates = 0;
	for (int i = 0; i < g_lights_.num_polygons; ++i) {
		rt_light_merge_rect_t tmp;
		if (g_lights_.polygon_rect_candidate[i] && lightMergeExtractRectFromPolygon(g_lights_.polygons + i, i, &tmp)) {
			is_merge_candidate[i] = 1;
			merge_candidates++;
		}
	}

	int skipped_lights = total_lights - merge_candidates;

	int merged_groups_total = 0;
	int merged_groups_success = 0;
	int unmerged_candidates = 0;
	int merged_old_lights = 0;
	int final_total_lights = state->merged_num_polygons;
	int reduced_lights = total_lights - final_total_lights;

	if (merge_candidates > 0) {
		int merged_index_counts[MAX_SURFACE_LIGHTS] = {0};
		for (int i = 0; i < g_lights_.num_polygons; ++i) {
			if (!is_merge_candidate[i])
				continue;

			const int merged_index = state->source_to_merged[i];
			if (merged_index >= 0 && merged_index < MAX_SURFACE_LIGHTS)
				merged_index_counts[merged_index]++;
		}

		for (int i = 0; i < MAX_SURFACE_LIGHTS; ++i) {
			const int c = merged_index_counts[i];
			if (c <= 0)
				continue;
			merged_groups_total++;
			if (c == 1)
				unmerged_candidates++;
			if (c > 1) {
				merged_groups_success++;
				merged_old_lights += c;
			}
		}
	}

	const float merged_percent = total_lights > 0 ? (100.f * (float)merged_old_lights / (float)total_lights) : 0.f;

	INFO("rt_merge_kusochki_lights stats: skipped=%d merged_old=%d remaining_unmerged=%d isolated_self_only=%d merged_groups=%d merged_groups_total=%d total_before=%d total_after=%d reduced=%d merged_percent=%.2f%%",
		skipped_lights,
		merged_old_lights,
		unmerged_candidates,
		state->isolated_self_only_count,
		merged_groups_success,
		merged_groups_total,
		total_lights,
		final_total_lights,
		reduced_lights,
		merged_percent);
}

static void lightPrintPolygonStatsOnce(float merge_time_ms) {
	if (!debug_dump_lights.print_stats_once)
		return;

	const int total_lights = g_lights_.num_polygons;
	const int merged_success = Q_max(0, total_lights - g_lights_.merge.merged_num_polygons);
	const int merged_failed = Q_max(0, total_lights - merged_success);
	const float remaining_percent_total = total_lights > 0
		? (100.f * (float)merged_failed / (float)total_lights)
		: 0.f;
	const float remaining_percent_from_initial = remaining_percent_total;

	INFO("lights stats: total=%d merged_success=%d merged_failed=%d isolated_self_only=%d remaining_percent_total=%.2f%% remaining_percent_from_initial=%.2f%% time_ms=%.3f",
		total_lights,
		merged_success,
		merged_failed,
		g_lights_.merge.isolated_self_only_count,
		remaining_percent_total,
		remaining_percent_from_initial,
		merge_time_ms);

	debug_dump_lights.print_stats_once = false;
}

static void lightDumpAllSourcesOnce(void) {
	if (!debug_dump_lights.dump_all_sources_once)
		return;

	INFO("lights dump begin: point=%d polygon=%d polygon_merged=%d",
		g_lights_.num_point_lights, g_lights_.num_polygons, g_lights_.merge.merged_num_polygons);

	for (int i = 0; i < g_lights_.num_point_lights; ++i) {
		const vk_point_light_t *const l = &g_lights_.point_lights[i];
		INFO("point[%d]: origin=(%.3f %.3f %.3f) color=(%.3f %.3f %.3f) dir=(%.3f %.3f %.3f) radius=%.3f",
			i,
			l->origin[0], l->origin[1], l->origin[2],
			l->color[0], l->color[1], l->color[2],
			l->dir[0], l->dir[1], l->dir[2],
			l->radius);
	}

	for (int i = 0; i < g_lights_.num_polygons; ++i) {
		const rt_light_polygon_t *const p = &g_lights_.polygons[i];
		const int merged_index = (i >= 0 && i < MAX_SURFACE_LIGHTS) ? g_lights_.merge.source_to_merged[i] : -1;

		INFO("poly[%d]: merged=%d vertices=%d offset=%d emissive=(%.3f %.3f %.3f) normal=(%.5f %.5f %.5f) area=%.5f",
			i, merged_index, p->vertices.count, p->vertices.offset,
			p->emissive[0], p->emissive[1], p->emissive[2],
			p->plane[0], p->plane[1], p->plane[2], p->area);

		for (int v = 0; v < p->vertices.count; ++v) {
			const int index = p->vertices.offset + v;
			if (index < 0 || index >= g_lights_.num_polygon_vertices || index >= (int)COUNTOF(g_lights_.polygon_vertices)) {
				INFO("poly[%d].v[%d]: OOB index=%d", i, v, index);
				continue;
			}
			const vec3_t *const vert = &g_lights_.polygon_vertices[index];
			INFO("poly[%d].v[%d]=(%.3f %.3f %.3f)", i, v, (*vert)[0], (*vert)[1], (*vert)[2]);
		}
	}

	INFO("lights dump end");
	debug_dump_lights.dump_all_sources_once = false;
}

static void uploadGridRange( int begin, int end ) {
	const int count = end - begin;
	ASSERT( count > 0 );

	const int size = count * sizeof(struct LightCluster);
	const vk_buffer_locked_t locked = R_VkBufferLock(&g_lights_.buffer,
		(vk_buffer_lock_t) {
			.offset = sizeof(struct LightsMetadata) + begin * sizeof(struct LightCluster),
			.size = size,
	} );

	ASSERT(locked.ptr);

	struct LightCluster *const grid = locked.ptr;
	memset(grid, 0, size);

	for (int i = 0; i < count; ++i) {
		const vk_lights_cell_t *const src = g_lights_.cells + i + begin;
		struct LightCluster *const dst = grid + i;

		dst->num_point_lights = src->num_point_lights;
		memcpy(dst->point_lights, src->point_lights, sizeof(uint8_t) * src->num_point_lights);

		int remapped_polygons = 0;
		for (int p = 0; p < src->num_polygons; ++p) {
			const int source_poly = src->polygons[p];
			if (source_poly < 0 || source_poly >= MAX_SURFACE_LIGHTS)
				continue;

			const int merged_poly = g_lights_.merge.source_to_merged[source_poly];
			if (merged_poly < 0 || merged_poly > UINT8_MAX)
				continue;

			qboolean duplicate = false;
			for (int d = 0; d < remapped_polygons; ++d) {
				if (dst->polygons[d] == merged_poly) {
					duplicate = true;
					break;
				}
			}

			if (!duplicate && remapped_polygons < MAX_VISIBLE_SURFACE_LIGHTS) {
				dst->polygons[remapped_polygons++] = merged_poly;
			}
		}
		dst->num_polygons = remapped_polygons;
	}

	R_VkBufferUnlock( locked );

	g_lights_.stats.ranges_uploaded++;
}

static void uploadGrid( void ) {
	ASSERT(g_lights_.grid.cells <= MAX_LIGHT_CLUSTERS);

	int begin = -1;
	for (int i = 0; i < g_lights_.grid.cells; ++i) {
		const vk_lights_cell_t *const cell = g_lights_.cells + i;

		const qboolean dirty = cell->frame_sequence == g_lights_.frame_sequence;
		if (dirty && begin < 0)
			begin = i;

		if (!dirty && begin >= 0) {
			uploadGridRange(begin, i);
			begin = -1;
		}
	}

	if (begin >= 0)
		uploadGridRange(begin, g_lights_.grid.cells);
}

static void uploadPolygonLights( struct LightsMetadata *metadata ) {
	float merge_time_ms = 0.f;
	if (CVAR_TO_BOOL(rt_merge_kusochki_lights)) {
		const uint64_t merge_begin_ns = aprof_time_now_ns();
		lightMergeBuildMergedPolygons();
		const uint64_t merge_end_ns = aprof_time_now_ns();
		merge_time_ms = (float)(merge_end_ns - merge_begin_ns) / 1000000.f;

		const int merged_success = g_lights_.num_polygons - g_lights_.merge.merged_num_polygons;
		if (merged_success <= 0) {
			debug_dump_lights.dump_all_sources_once = true;
		}

		if (!g_lights_.merge.prev_frame_merge_was_enabled) {
			lightMergePrintFirstEnableStats();
		}
		g_lights_.merge.prev_frame_merge_was_enabled = true;
	} else {
		g_lights_.merge.prev_frame_merge_was_enabled = false;
		lightMergeBuildBypassPolygons(metadata);
		lightPrintPolygonStatsOnce(0.f);
		lightDumpAllSourcesOnce();
		return;
	}

	ASSERT(g_lights_.merge.merged_num_polygons <= MAX_EMISSIVE_KUSOCHKI);
	metadata->num_polygons = g_lights_.merge.merged_num_polygons;
	for (int i = 0; i < g_lights_.merge.merged_num_polygons; ++i) {
		const rt_light_polygon_t *const src_poly = g_lights_.merge.merged_polygons + i;
		struct PolygonLight *const dst_poly = metadata->polygons + i;

		Vector4Copy(src_poly->plane, dst_poly->plane);
		VectorCopy(src_poly->center, dst_poly->center);
		dst_poly->area = src_poly->area;
		VectorCopy(src_poly->emissive, dst_poly->emissive);

		// TODO DEBUG_ASSERT
		ASSERT(src_poly->vertices.count > 2);
		ASSERT(src_poly->vertices.offset < 0xffffu);
		ASSERT(src_poly->vertices.count < 0xffffu);

		ASSERT(src_poly->vertices.offset + src_poly->vertices.count < COUNTOF(metadata->polygon_vertices));

		dst_poly->vertices_count_offset = (src_poly->vertices.count << 16) | (src_poly->vertices.offset);
	}

	ASSERT(g_lights_.merge.merged_num_vertices <= COUNTOF(metadata->polygon_vertices));
	for (int i = 0; i < g_lights_.merge.merged_num_vertices; ++i) {
		VectorCopy(g_lights_.merge.merged_vertices[i], metadata->polygon_vertices[i]);
	}

	lightPrintPolygonStatsOnce(merge_time_ms);
	lightDumpAllSourcesOnce();
}

static void uploadPointLights( struct LightsMetadata *metadata ) {
	metadata->num_point_lights = g_lights_.num_point_lights;
	for (int i = 0; i < g_lights_.num_point_lights; ++i) {
		vk_point_light_t *const src = g_lights_.point_lights + i;
		struct PointLight *const dst = metadata->point_lights + i;

		VectorCopy(src->origin, dst->origin_r2);
		dst->origin_r2[3] = src->radius * src->radius;

		VectorCopy(src->color, dst->color_stopdot);
		dst->color_stopdot[3] = src->stopdot;

		VectorNegate(src->dir, dst->dir_stopdot2);
		dst->dir_stopdot2[3] = src->stopdot2_or_costheta;

		dst->environment = !!(src->flags & LightFlag_Environment);
		dst->flashlight = !!(src->flags & LightFlag_Flashlight);
	}
}

static void VK_LightsUpload( struct vk_combuf_s *combuf ) {
	APROF_SCOPE_DECLARE_BEGIN(upload, __FUNCTION__);
	const vk_buffer_locked_t locked = R_VkBufferLock(&g_lights_.buffer,
		(vk_buffer_lock_t) {
			.offset = 0,
			.size = sizeof(struct LightsMetadata),
	} );

	ASSERT(locked.ptr);

	struct LightsMetadata *metadata = locked.ptr;
	memset(metadata, 0, sizeof(*metadata));

	VectorCopy(g_lights_.grid.min_cell, metadata->grid_min_cell);
	VectorCopy(g_lights_.grid.size, metadata->grid_size);

	uploadPolygonLights( metadata );
	uploadPointLights( metadata );

	R_VkBufferUnlock( locked );

	uploadGrid();

	g_lights_.frame_sequence++;

	APROF_SCOPE_END(upload);

	R_VkBufferStagingCommit(&g_lights_.buffer, combuf);
}

static void RT_LightsFrameEnd( void ) {
	APROF_SCOPE_BEGIN_EARLY(finalize);
	if (g_lights_.num_polygons > UINT8_MAX) {
		ERROR_THROTTLED(10, "Too many emissive surfaces found: %d; some areas will be dark", g_lights_.num_polygons);
		g_lights_.num_polygons = UINT8_MAX;
	}

	for (int i = 0; i < MAX_ELIGHTS; ++i) {
		const dlight_t *dlight = globals.elights + i;
		if (!dlight)
			continue;

		if (addDlight(dlight))
			++g_lights_.stats.elights;
	}

	for (int i = 0; i < g_lights_.num_point_lights; ++i) {
		vk_point_light_t *const light = g_lights_.point_lights + i;
		if (light->lightstyle < 0 || light->lightstyle >= MAX_LIGHTSTYLES)
			continue;

		{
			const float scale = g_lightmap.lightstylevalue[light->lightstyle] / 255.f;
			VectorScale(light->base_color, scale, light->color);
		}
	}

	APROF_SCOPE_BEGIN(dlights);
	for (int i = 0; i < MAX_DLIGHTS; ++i) {
		const dlight_t *dlight = globals.dlights + i;
		if( !dlight || dlight->die < gp_cl->time || !dlight->radius )
			continue;

		if (addDlight(dlight))
			++g_lights_.stats.dlights;
	}
	APROF_SCOPE_END(dlights);

	if (debug_dump_lights.enabled) {
#if 0
		// Print light grid stats
		DEBUG("Emissive surfaces found: %d", g_lights_.num_polygons);

		{
			#define GROUPSIZE 4
			int histogram[1 + (MAX_VISIBLE_SURFACE_LIGHTS + GROUPSIZE - 1) / GROUPSIZE] = {0};
			for (int i = 0; i < g_lights_.grid.cells; ++i) {
				const vk_lights_cell_t *cluster = g_lights_.cells + i;
				const int hist_index = cluster->num_polygons ? 1 + cluster->num_polygons / GROUPSIZE : 0;
				histogram[hist_index]++;
			}

			DEBUG("Built %d light clusters. Stats:", g_lights_.grid.cells);
			DEBUG("  0: %d", histogram[0]);
			for (int i = 1; i < ARRAYSIZE(histogram); ++i)
				DEBUG("  %d-%d: %d",
					(i - 1) * GROUPSIZE,
					i * GROUPSIZE - 1,
					histogram[i]);
		}

		{
			int num_clusters_with_lights_in_range = 0;
			for (int i = 0; i < g_lights_.grid.cells; ++i) {
				const vk_lights_cell_t *cluster = g_lights_.cells + i;
				if (cluster->num_polygons > 0) {
					DEBUG(" cluster %d: polygons=%d", i, cluster->num_polygons);
				}

				for (int j = 0; j < cluster->num_polygons; ++j) {
					const int index = cluster->polygons[j];
					if (index >= vk_rtx_light_begin->value && index < vk_rtx_light_end->value) {
						++num_clusters_with_lights_in_range;
					}
				}
			}

			DEBUG("Clusters with filtered lights: %d", num_clusters_with_lights_in_range);
		}
#endif
	}

	g_lights_.stats.dirty_cells_size = g_lights_.stats.dirty_cells * sizeof(struct LightCluster);
	g_lights_.stats.dynamic_points = g_lights_.num_point_lights - g_lights_.num_static.point_lights;
	g_lights_.stats.dynamic_polygons = g_lights_.num_polygons - g_lights_.num_static.polygons;

	debug_dump_lights.enabled = false;
	APROF_SCOPE_END(finalize);
}

static void lightsProduce(struct Producer* p, struct vk_combuf_s *combuf, const FrameContext *ctx) {
	ASSERT(p->frame_sequence_tag != ctx->frame_sequence);
	RT_LightsFrameEnd();
	VK_LightsUpload(combuf);
	// TODO frame begin
}

char *RT_LightPrintCellInfo(char *p, char *const end, vec3_t pos) {
	const int cell_raw[3] = {
		floor(pos[0] / LIGHT_GRID_CELL_SIZE),
		floor(pos[1] / LIGHT_GRID_CELL_SIZE),
		floor(pos[2] / LIGHT_GRID_CELL_SIZE),
	};
	const int light_cell[3] = {
		cell_raw[0] - g_lights_.grid.min_cell[0],
		cell_raw[1] - g_lights_.grid.min_cell[1],
		cell_raw[2] - g_lights_.grid.min_cell[2],
	};
	const int cell_index = RT_LightCellIndex( light_cell );

	const vk_lights_cell_t *cell = (cell_index >= 0 && cell_index < MAX_LIGHT_CLUSTERS) ? g_lights_.cells + cell_index : NULL;
	p += Q_snprintf(p, end - p,
		"light raw=(%d, %d, %d) cell=(%d, %d, %d) index=%d poly=%d point=%d\n",
		cell_raw[0],
		cell_raw[1],
		cell_raw[2],
		light_cell[0],
		light_cell[1],
		light_cell[2],
		cell_index,
		cell ? cell->num_polygons : -1,
		cell ? cell->num_point_lights : -1);

	if (cell && cell->num_polygons > 0) {
		p += Q_snprintf(p, end - p, "poly:");
		for (int i = 0; i < cell->num_polygons; ++i) {
			p += Q_snprintf(p, end - p, " %d", cell->polygons[i]);
		}
		p += Q_snprintf(p, end - p, "\n");
	}

	if (cell && cell->num_point_lights > 0) {
		p += Q_snprintf(p, end - p, "point:");
		for (int i = 0; i < cell->num_point_lights; ++i) {
			p += Q_snprintf(p, end - p, " %d", cell->point_lights[i]);
		}
		p += Q_snprintf(p, end - p, "\n");
	}

	return p;
}
