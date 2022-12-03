#include "vk_studio.h"
#include "vk_common.h"
#include "vk_textures.h"
#include "vk_render.h"
#include "vk_geometry.h"
#include "camera.h"

#include "xash3d_mathlib.h"
#include "const.h"
#include "r_studioint.h"
#include "triangleapi.h"
#include "studio.h"
#include "pm_local.h"
#include "cl_tent.h"
#include "pmtrace.h"
#include "protocol.h"
#include "enginefeatures.h"
#include "pm_movevars.h"

#include <memory.h>
#include <stdlib.h>



#define MAX_SMOOTHING_NORMALS_POOL 65536
#define MAX_SMOOTHING_NORMALS_LINKED 4096
#define SMOOTHING_NORMALS_POS_MULTIPLIER 1000.0f

// structure for linking smoothing points
typedef struct vk_normals_smooth_vertex_s {
	vk_vertex_t* vertex;
	qboolean already_smoothed;
	int ipos[3];
	int iuv[2];
} vk_normals_smooth_vertex_t;

// TODO: maybe use dynamic memory? but now is fast and simple
typedef struct vk_normals_smooth_s {
	vk_normals_smooth_vertex_t vertices[MAX_SMOOTHING_NORMALS_POOL];
	uint vertices_count;

	uint linked[MAX_SMOOTHING_NORMALS_LINKED];
	uint linked_count;

	qboolean split_by_uv_seams;
	float angle_dot_treshold;
} vk_normals_smooth_t;

static vk_normals_smooth_t g_normals_smooth;

void VK_NormalsSmooth_Start(float angle_dot_treshold, qboolean split_by_uv_seams) {
	g_normals_smooth.vertices_count = 0;
	g_normals_smooth.split_by_uv_seams = split_by_uv_seams;
	g_normals_smooth.angle_dot_treshold = angle_dot_treshold;
}

void VK_NormalsSmooth_AddVertex(vk_vertex_t *vertex) {
	if (g_normals_smooth.vertices_count < MAX_SMOOTHING_NORMALS_POOL) {
		vk_normals_smooth_vertex_t* vert = g_normals_smooth.vertices + g_normals_smooth.vertices_count++;
		vert->vertex = vertex;
		vert->already_smoothed = false;
		vert->ipos[0] = (int)(vertex->pos[0] * SMOOTHING_NORMALS_POS_MULTIPLIER);
		vert->ipos[1] = (int)(vertex->pos[1] * SMOOTHING_NORMALS_POS_MULTIPLIER);
		vert->ipos[2] = (int)(vertex->pos[2] * SMOOTHING_NORMALS_POS_MULTIPLIER);

		if (g_normals_smooth.split_by_uv_seams) {
			vert->iuv[0] = (int)(vertex->gl_tc[0] * SMOOTHING_NORMALS_POS_MULTIPLIER);
			vert->iuv[1] = (int)(vertex->gl_tc[1] * SMOOTHING_NORMALS_POS_MULTIPLIER);
		} else {
			vert->iuv[0] = 0;
			vert->iuv[1] = 0;
		}
	}
}

void VK_NormalsSmooth_Apply() {
	if (g_normals_smooth.vertices_count == 0)
		return;

	uint vertices_count_minus_one = g_normals_smooth.vertices_count - 1;
	for (int v = 0; v < vertices_count_minus_one; ++v) {
		vk_normals_smooth_vertex_t* vert = g_normals_smooth.vertices + v;
		
		if (vert->already_smoothed || g_normals_smooth.linked_count >= MAX_SMOOTHING_NORMALS_LINKED)
			continue;

		g_normals_smooth.linked_count = 0;

		// add current vertex
		g_normals_smooth.linked[g_normals_smooth.linked_count++] = v;
		vert->already_smoothed = true;

		for (int l = v + 1; l < g_normals_smooth.vertices_count; ++l) {
			vk_normals_smooth_vertex_t* linked_vert = g_normals_smooth.vertices + l;

			if (linked_vert->already_smoothed || g_normals_smooth.linked_count >= MAX_SMOOTHING_NORMALS_LINKED)
				continue;

			if (vert->ipos[0] == linked_vert->ipos[0] &&
				vert->ipos[1] == linked_vert->ipos[1] &&
				vert->ipos[2] == linked_vert->ipos[2] &&
				vert->iuv[0] == linked_vert->iuv[0] &&
				vert->iuv[1] == linked_vert->iuv[1] &&
				DotProduct(vert->vertex->normal, linked_vert->vertex->normal) > g_normals_smooth.angle_dot_treshold)
			{
				// add second vertex
				g_normals_smooth.linked[g_normals_smooth.linked_count++] = l;
				linked_vert->already_smoothed = true;
			}
		}

		if (g_normals_smooth.linked_count > 1) {
			vec3_t normal = { 0., 0., 0. };
			for (int v = 0; v < g_normals_smooth.linked_count; ++v) {
				vk_normals_smooth_vertex_t* linked_vert = g_normals_smooth.vertices + g_normals_smooth.linked[v];
				VectorAdd(normal, linked_vert->vertex->normal, normal);
			}

			VectorNormalize(normal);

			for (int v = 0; v < g_normals_smooth.linked_count; ++v) {
				vk_normals_smooth_vertex_t* linked_vert = g_normals_smooth.vertices + g_normals_smooth.linked[v];
				VectorCopy(normal, linked_vert->vertex->normal);
			}
		}
	}
}

