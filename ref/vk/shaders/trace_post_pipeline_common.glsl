#ifndef TRACE_POST_PIPELINE_COMMON_GLSL_INCLUDED
#define TRACE_POST_PIPELINE_COMMON_GLSL_INCLUDED

#include "utils.glsl"
#include "color_spaces.glsl"
#include "ray_kusochki.glsl"
#include "trace_post_pipeline_payload.glsl"

struct TracePostRtGeometry {
	vec2 uv;
	vec4 vertex_color_srgb;
};

void tracePostRtReadHit(
	uvec2 hit,
	uint bary_packed,
	out Kusok kusok,
	out ModelHeader model,
	out TracePostRtGeometry geometry)
{
	kusok = getKusok(tracePostRtKusokIndex(hit.x));
	model = getModelHeader(tracePostRtModelIndex(hit.x));
	const uint first_index_offset = kusok.index_offset + hit.y * 3u;
	const uint vi1 = uint(getIndex(first_index_offset + 0u)) + kusok.vertex_offset;
	const uint vi2 = uint(getIndex(first_index_offset + 1u)) + kusok.vertex_offset;
	const uint vi3 = uint(getIndex(first_index_offset + 2u)) + kusok.vertex_offset;
	const vec2 bary = unpackHalf2x16(bary_packed);

	geometry.uv = baryMix(GET_VERTEX(vi1).gl_tc, GET_VERTEX(vi2).gl_tc, GET_VERTEX(vi3).gl_tc, bary);
	geometry.vertex_color_srgb = baryMix(
		unpackUnorm4x8(GET_VERTEX(vi1).color),
		unpackUnorm4x8(GET_VERTEX(vi2).color),
		unpackUnorm4x8(GET_VERTEX(vi3).color),
		bary);
}

#endif
