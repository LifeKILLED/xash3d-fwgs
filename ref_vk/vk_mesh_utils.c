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


#define VK_NORMALS_SMOOTH_VERTICES_MAX 65536
#define VK_NORMALS_SMOOTH_LINKED_MAX 4096
#define POSITIONS_EQUAL_THRESHOLD 0.01f
#define UV_EQUAL_THRESHOLD 0.0025f


typedef struct vk_normals_smooth_vertex_s {
	vk_vertex_t* vertex;
	qboolean already_smoothed;
	int compare_hash;
} vk_normals_smooth_vertex_t;


typedef struct vk_normals_smooth_s {
	vk_normals_smooth_vertex_t vertices[VK_NORMALS_SMOOTH_VERTICES_MAX];
	uint vertices_count;

	uint linked[VK_NORMALS_SMOOTH_LINKED_MAX];
	uint linked_count;

	qboolean split_by_uv_seams;
	float angle_dot_treshold;
} vk_normals_smooth_t;

static vk_normals_smooth_t g_normals_smooth;

#ifndef Vector2Length
#define Vector2Length(a) ( sqrt( a[0] * a[0] + a[1] * a[1] ) )
#endif

#ifndef Vector2Scale
#define Vector2Scale(in, scale, out) out[0] = in[0] * scale; out[1] = in[1] * scale
#endif

static qboolean isPositionsEqual(vec3_t a, vec3_t b)
{
	vec3_t c;
	VectorSubtract(a, b, c);
	return DotProduct(c, c) < (POSITIONS_EQUAL_THRESHOLD * POSITIONS_EQUAL_THRESHOLD);
}

static qboolean isUVEqual(vec2_t a, vec2_t b)
{
	vec2_t c;
	Vector2Subtract(a, b, c);
	float dot = c[0]*c[0]+c[1]*c[1];
	return dot < (UV_EQUAL_THRESHOLD * UV_EQUAL_THRESHOLD);
}

static void invertIfTexCoordYIsNegative(vec3_t pos, vec2_t uv)
{
	if (uv[1] < 0.0)
	{
		VectorScale(pos, -1.0, pos);
		uv[0] *= -1.0;
		uv[1] *= -1.0;
	}
}

#define InvertIfTexCoordXIsNegative(pos, uv) \
	if (uv[0] < 0.0) { \
		VectorScale(pos, -1.0, pos); \
		uv[0] *= -1.0; \
		uv[1] *= -1.0; \
	}

static int checkTexcoordsIsPositive(vec3_t binormal, vec3_t dir, vec2_t uv)
{
	if (uv[0] == 0.0)
		return 0; // can't check

	float coplanar = DotProduct(binormal, dir);

	if ( uv[0] > 0.0 && coplanar >= 0.0 ||
		 uv[0] < 0.0 && coplanar <= 0.0 )
	{
		return -1;
	}

	return 1;
}

static void useVectorAsTangent(vec3_t start, vec3_t end, vec2_t uv_offset, vec_t *tangent)
{
	VectorSubtract(end, start, tangent);
	if (uv_offset[1] < 0.0)
	{
		VectorScale(tangent, -1.0, tangent);
	}
	VectorNormalize(tangent);
}


// require positions, texcoords and normals. if texcoords is mirrored, w is -1 (need to inverse binormal)
void VK_CalculateTangent(vec4_t *out, vk_vertex_t* center, vk_vertex_t* point_a, vk_vertex_t* point_b)
{
	vec3_t edge1, edge2, tangent, binormal, binormal_calculated;
	vec2_t deltaUV1, deltaUV2;
	VectorSubtract(point_a->pos, center->pos, edge1);
	VectorSubtract(point_b->pos, center->pos, edge2);
	Vector2Subtract(point_a->gl_tc, center->gl_tc, deltaUV1);
	Vector2Subtract(point_b->gl_tc, center->gl_tc, deltaUV2);
	float f = 1.0f / (deltaUV1[0] * deltaUV2[1] - deltaUV2[0] * deltaUV1[1]);
	tangent[0] = f * (deltaUV2[1] * edge1[0] - deltaUV1[1] * edge2[0]);
	tangent[1] = f * (deltaUV2[1] * edge1[1] - deltaUV1[1] * edge2[1]);
	tangent[2] = f * (deltaUV2[1] * edge1[2] - deltaUV1[1] * edge2[2]);
	binormal[0] = f * (-deltaUV2[0] * edge1[0] + deltaUV1[0] * edge2[0]);
	binormal[1] = f * (-deltaUV2[0] * edge1[1] + deltaUV1[0] * edge2[1]);
	binormal[2] = f * (-deltaUV2[0] * edge1[2] + deltaUV1[0] * edge2[2]);
	VectorNormalize( tangent );
	VectorNormalize( binormal );
	CrossProduct( center->normal, tangent, binormal_calculated );
	(*out)[0] = tangent[0];
	(*out)[1] = tangent[1];
	(*out)[2] = tangent[2];
	(*out)[3] = DotProduct( binormal, binormal_calculated );
}
//
//// require positions, texcoords and normals. if texcoords is mirrored, w is -1 (need to inverse binormal)
//void VK_CalculateTangent(vec4_t *out, vk_vertex_t* center, vk_vertex_t* point_a, vk_vertex_t* point_b)
//{
//	vec3_t a, b, ab, tangent, binormal;
//	vec2_t a_UV, b_UV, ab_UV;
//	vec_t *near_pos, *far_pos, *near_uv, *far_uv;
//	vec_t *positive_pos, *negative_pos, *positive_uv, *negative_uv;
//
//	//VectorSubtract(point_a->pos, center->pos, a);
//	//VectorSubtract(point_b->pos, center->pos, b);
//	//VectorSubtract(b, a, ab);
//
//	Vector2Subtract(point_a->gl_tc, center->gl_tc, a_UV);
//	Vector2Subtract(point_b->gl_tc, center->gl_tc, b_UV);
//	Vector2Subtract(b_UV, a_UV, ab_UV);
//	
//	if ( fabs(a_UV[0]) < 0.001 )
//	{
//		useVectorAsTangent( center->pos, point_a->pos, a_UV, &tangent[0] );
//	}
//	else if( fabs(b_UV[0]) < 0.001 )
//	{
//		useVectorAsTangent( center->pos, point_b->pos, a_UV, &tangent[0] );
//	}
//	else if( fabs(ab_UV[0]) < 0.001 )
//	{
//		useVectorAsTangent( point_a->pos, point_b->pos, ab_UV, &tangent[0] );
//	}
//	else if ( ( a[0] == b[0] && a[1] == b[1] && a[2] == b[1] ) ||
//			( a_UV[0] == b_UV[0] && a_UV[1] == b_UV[1] ))
//	{
//		// collapse, use fallback value, but normal maps will look incorrect
//		CrossProduct(center->normal, a, tangent);
//		VectorNormalize(tangent);
//	}
//	else
//	{
//		//// complex tangent searching by texcoords
//		//if ( ( a_UV[0] > 0.0 && b_UV[0] > 0.0 ) || ( a_UV[0] < 0.0 && b_UV[0] < 0.0 ) )
//		//{
//		//	if (a_UV[0] > 0.0 )
//		//	{
//		//		VectorScale(b, -1.0, b);
//		//		//Vector2Scale(b_UV, -1.0, b_UV);
//		//	}
//		//	else
//		//	{
//		//		VectorScale(a, -1.0, a);
//		//		//Vector2Scale(a_UV, -1.0, a_UV);
//		//	}
//		//	positive_pos = &a[0];
//		//	positive_uv = &a_UV[0];
//		//	negative_pos = &b[0];
//		//	negative_uv = &b_UV[0];
//		//}
//		//else if (b_UV[0] > 0.0)
//		//{
//		//	positive_pos = &b[0];
//		//	positive_uv = &b_UV[0];
//		//	negative_pos = &a[0];
//		//	negative_uv = &a_UV[0];
//		//}
//		//else
//		//{
//		//	positive_pos = &a[0];
//		//	positive_uv = &a_UV[0];
//		//	negative_pos = &b[0];
//		//	negative_uv = &b_UV[0];
//		//}
//
//		//float 
//
//		// move points to the right side of the texture coordinate system
//		InvertIfTexCoordXIsNegative(a, a_UV)
//		InvertIfTexCoordXIsNegative(b, b_UV)
//
//		// the vector of these points is directed to the vertical texcoords axis
//		if (a_UV[0] < b_UV[0])
//		{
//			near_pos = &a[0];
//			far_pos = &b[0];
//			near_uv = &a_UV[0];
//			far_uv = &b_UV[0];
//		}
//		else
//		{
//			near_pos = &b[0];
//			far_pos = &a[0];
//			near_uv = &b_UV[0];
//			far_uv = &a_UV[0];
//		}
//
//		// build a path to the vertical texcoord axis, this is tangent
//		float to_tangent_axis_proportion = far_uv[0] / ( far_uv[0] - near_uv[0] );
//		VectorSubtract( near_pos, far_pos, tangent );
//		VectorScale( tangent, to_tangent_axis_proportion, tangent );
//		VectorAdd( tangent, far_pos, tangent );
//
//		// zero length check
//		if ( tangent[0] == 0.0 && tangent[1] == 0.0 && tangent[2] == 0.0 )
//		{
//			tangent[2] = 1.0; // fallback to wrong but correct value
//		}
//		else
//		{
//			// inverse tangent if we came to the negative texture coordinate area
//			float tangent_axis_y = (near_pos[1] - far_pos[1]) * to_tangent_axis_proportion + far_pos[1];
//			if (tangent_axis_y < 0.0)
//			{
//				VectorScale( tangent, -1.0, tangent );
//			}
//			VectorNormalize(tangent);
//		}
//	}
//
//	// binormal
//	CrossProduct(center->normal, tangent, binormal);
//	VectorNormalize(binormal);
//
//	// correct tangent
//	CrossProduct(binormal, center->normal, tangent);
//	VectorNormalize(tangent);
//
//	// inverse binormal if texcoords are mirrored
//	int binormal_scale = checkTexcoordsIsPositive( binormal, a, a_UV );
//	if (binormal_scale == 0) binormal_scale = checkTexcoordsIsPositive( binormal, b, b_UV );
//	if (binormal_scale == 0) binormal_scale = checkTexcoordsIsPositive( binormal, ab, ab_UV );
//	if (binormal_scale == 0) binormal_scale = 1;
//
//	(*out)[0] = tangent[0];
//	(*out)[1] = tangent[1];
//	(*out)[2] = tangent[2];
//	(*out)[3] = (float)binormal_scale;
//}

// require positions, texcoords and normals. if texcoords is mirrored, w is -1 (need to inverse binormal)
//void VK_CalculateTangent(vec4_t *out, vk_vertex_t* center, vk_vertex_t* point_a, vk_vertex_t* point_b)
//{
//	vec3_t a, b, ab, tangent, binormal;
//	vec2_t a_UV, b_UV, ab_UV;
//	vec_t *near_pos, *far_pos, *near_uv, *far_uv;
//
//	VectorSubtract(point_a->pos, center->pos, a);
//	VectorSubtract(point_b->pos, center->pos, b);
//	VectorSubtract(b, a, ab);
//
//	Vector2Subtract(point_a->gl_tc, center->gl_tc, a_UV);
//	Vector2Subtract(point_b->gl_tc, center->gl_tc, b_UV);
//	Vector2Subtract(b_UV, a_UV, ab_UV);
//	
//	if (fabs(a_UV[0]) < 0.001 )
//	{
//		// use a vector as tangent
//		VectorCopy(a, tangent);
//		if (a_UV[1] < 0.0)
//			VectorScale(tangent, -1.0, tangent);
//	}
//	else if(fabs(b_UV[0]) < 0.001 )
//	{
//		// use b vector as tangent
//		VectorCopy(b, tangent);
//		if (b_UV[1] < 0.0)
//			VectorScale(tangent, -1.0, tangent);
//	}
//	else if(fabs(ab_UV[0]) < 0.001 )
//	{
//		// use ab vector as tangent
//		VectorCopy(ab, tangent);
//		if (ab_UV[1] < 0.0)
//			VectorScale(tangent, -1.0, tangent);
//	}
//	else if ( ( a[0] == b[0] && a[1] == b[1] && a[2] == b[1] ) ||
//			( a_UV[0] == b_UV[0] && a_UV[1] == b_UV[1] ))
//	{
//		// collapse, use fallback value, but normal maps will look incorrect
//		CrossProduct(center->normal, ab, tangent);
//	}
//	else
//	{
//		// complex tangent searching by texcoords
//
//		// move points to the right side of the texture coordinate system
//		InvertIfTexCoordXIsNegative(a, a_UV)
//		InvertIfTexCoordXIsNegative(b, b_UV)
//
//		// the vector of these points is directed to the vertical texcoords axis
//		if (a_UV[0] < b_UV[0])
//		{
//			near_pos = &a[0];
//			far_pos = &b[0];
//			near_uv = &a_UV[0];
//			far_uv = &b_UV[0];
//		}
//		else
//		{
//			near_pos = &b[0];
//			far_pos = &a[0];
//			near_uv = &b_UV[0];
//			far_uv = &a_UV[0];
//		}
//
//		// build a path to the vertical texcoord axis, this is tangent
//		float to_tangent_axis_proportion = far_uv[0] / ( far_uv[0] - near_uv[0] );
//		VectorSubtract( near_pos, far_pos, tangent );
//		VectorScale( tangent, to_tangent_axis_proportion, tangent );
//		VectorAdd( tangent, far_pos , tangent );
//
//		// zero length check
//		if ( tangent[0] == 0.0 && tangent[1] == 0.0 && tangent[2] == 0.0 )
//		{
//			tangent[2] = 1.0; // fallback to wrong but correct value
//		}
//		else
//		{
//			// inverse tangent if we came to the negative texture coordinate area
//			float tangent_axis_y = (near_pos[1] - far_pos[1]) * to_tangent_axis_proportion + far_pos[1];
//			if (tangent_axis_y < 0.0)
//			{
//				VectorScale( tangent, -1.0, tangent );
//			}
//			//VectorNormalize(tangent);
//		}
//	}
//
//	// binormal
//	CrossProduct(center->normal, tangent, binormal);
//	//VectorNormalize(binormal);
//
//	// correct tangent
//	CrossProduct(binormal, center->normal, tangent);
//	VectorNormalize(tangent);
//
//	// inverse binormal if texcoords are mirrored
//	int binormal_scale = checkTexcoordsIsPositive( binormal, a, a_UV );
//	if (binormal_scale == 0) binormal_scale = checkTexcoordsIsPositive( binormal, b, b_UV );
//	if (binormal_scale == 0) binormal_scale = checkTexcoordsIsPositive( binormal, ab, ab_UV );
//	if (binormal_scale == 0) binormal_scale = 1;
//
//	(*out)[0] = tangent[0];
//	(*out)[1] = tangent[1];
//	(*out)[2] = tangent[2];
//	(*out)[3] = (float)binormal_scale;
//}

void VK_NormalsSmooth_Start(float angle_dot_treshold, qboolean split_by_uv_seams)
{
	g_normals_smooth.vertices_count = 0;
	g_normals_smooth.angle_dot_treshold = angle_dot_treshold;
	g_normals_smooth.split_by_uv_seams = split_by_uv_seams;
}

void VK_NormalsSmooth_AddVertex(vk_vertex_t *vertex)
{
	if (g_normals_smooth.vertices_count >= VK_NORMALS_SMOOTH_VERTICES_MAX)
		return;

	vk_normals_smooth_vertex_t* vert = g_normals_smooth.vertices + g_normals_smooth.vertices_count++;

	vert->vertex = vertex;
	vert->already_smoothed = false;

	// for quick checking positions in bruteforce pass
	vert->compare_hash = 0;
	vert->compare_hash += (int)(vertex->pos[0] / POSITIONS_EQUAL_THRESHOLD);
	vert->compare_hash += (int)(vertex->pos[1] / POSITIONS_EQUAL_THRESHOLD);
	vert->compare_hash += (int)(vertex->pos[2] / POSITIONS_EQUAL_THRESHOLD);

	if (g_normals_smooth.split_by_uv_seams) {
		vert->compare_hash += (int)(vertex->gl_tc[0] / UV_EQUAL_THRESHOLD);
		vert->compare_hash += (int)(vertex->gl_tc[1] / UV_EQUAL_THRESHOLD);
	}
}

void VK_NormalsSmooth_Apply()
{
	if (g_normals_smooth.vertices_count == 0)
		return;

	const qboolean split_by_uv = g_normals_smooth.split_by_uv_seams;

	for (int v = 0; v < g_normals_smooth.vertices_count; ++v)
	{
		vk_normals_smooth_vertex_t* vert = g_normals_smooth.vertices + v;
		
		if (vert->already_smoothed)
			continue;

		g_normals_smooth.linked_count = 0;

		// add current vertex
		g_normals_smooth.linked[g_normals_smooth.linked_count++] = v;
		vert->already_smoothed = true;

		for (int l = v + 1; l < g_normals_smooth.vertices_count; ++l)
		{
			vk_normals_smooth_vertex_t* linked_vert = g_normals_smooth.vertices + l;

			if (linked_vert->already_smoothed || g_normals_smooth.linked_count >= VK_NORMALS_SMOOTH_LINKED_MAX)
				continue;

			if ( vert->compare_hash == linked_vert->compare_hash &&
				 isPositionsEqual( vert->vertex->pos, linked_vert->vertex->pos ) &&
				 ( split_by_uv && isUVEqual( vert->vertex->gl_tc, linked_vert->vertex->gl_tc )) )
			{
				// compare with all connected normals to compensate the priority of the first
				for (int c = 0; c < g_normals_smooth.linked_count; c++)
				{
					vk_normals_smooth_vertex_t* compare_vert = g_normals_smooth.vertices + c;

					if (DotProduct(compare_vert->vertex->normal, linked_vert->vertex->normal) > g_normals_smooth.angle_dot_treshold)
					{
						// add second vertex
						g_normals_smooth.linked[g_normals_smooth.linked_count++] = l;
						linked_vert->already_smoothed = true;
						break;
					}
				}
			}
		}

		if (g_normals_smooth.linked_count > 1)
		{
			vec3_t normal = { 0., 0., 0. };
			for (int v = 0; v < g_normals_smooth.linked_count; ++v)
			{
				vk_normals_smooth_vertex_t* linked_vert = g_normals_smooth.vertices + g_normals_smooth.linked[v];
				VectorAdd(normal, linked_vert->vertex->normal, normal);
			}

			VectorNormalize(normal);

			for (int v = 0; v < g_normals_smooth.linked_count; ++v)
			{
				vk_normals_smooth_vertex_t* linked_vert = g_normals_smooth.vertices + g_normals_smooth.linked[v];
				VectorCopy(normal, linked_vert->vertex->normal);
			}
		}

		// TODO: recalculate tangents here
	}
}

