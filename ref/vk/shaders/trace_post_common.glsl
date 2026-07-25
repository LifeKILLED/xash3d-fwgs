#ifndef TRACE_POST_COMMON_GLSL_INCLUDED
#define TRACE_POST_COMMON_GLSL_INCLUDED

#include "utils.glsl"
#include "color_spaces.glsl"
#include "ray_kusochki.glsl"

#define TRACE_POST_MAX_ENTRIES 8
#define PAYLOAD_LOCATION_TRACE_POST 3

struct TracePostHit {
	uint kusok_index;
	uint primitive_index;
	uint bary_packed;
	uint model_index;
};

struct TracePostMiniGeometry {
	vec2 uv;
	vec4 vertex_color_srgb;
};

struct TracePostLegacyPayload {
	uint count;
	float ray_length;
	TracePostHit hits[TRACE_POST_MAX_ENTRIES];
	float depths[TRACE_POST_MAX_ENTRIES];
};

TracePostHit tracePostMakeHit(uint kusok_index, uint primitive_index, vec2 bary, uint model_index)
{
	TracePostHit hit;
	hit.kusok_index = kusok_index;
	hit.primitive_index = primitive_index;
	hit.bary_packed = packHalf2x16(bary);
	hit.model_index = model_index;
	return hit;
}

TracePostMiniGeometry tracePostReadMiniGeometry(TracePostHit hit)
{
	const Kusok kusok = getKusok(hit.kusok_index);
	const uint first_index_offset = kusok.index_offset + hit.primitive_index * 3u;
	const uint vi1 = uint(getIndex(first_index_offset + 0u)) + kusok.vertex_offset;
	const uint vi2 = uint(getIndex(first_index_offset + 1u)) + kusok.vertex_offset;
	const uint vi3 = uint(getIndex(first_index_offset + 2u)) + kusok.vertex_offset;
	const vec2 bary = unpackHalf2x16(hit.bary_packed);

	TracePostMiniGeometry geom;
	geom.uv = baryMix(GET_VERTEX(vi1).gl_tc, GET_VERTEX(vi2).gl_tc, GET_VERTEX(vi3).gl_tc, bary);
	geom.vertex_color_srgb = baryMix(
		unpackUnorm4x8(GET_VERTEX(vi1).color),
		unpackUnorm4x8(GET_VERTEX(vi2).color),
		unpackUnorm4x8(GET_VERTEX(vi3).color),
		bary);
	return geom;
}

void tracePostSortLegacy(inout TracePostLegacyPayload payload)
{
	for (uint i = 0u; i < payload.count; ++i) {
		uint min_i = i;
		for (uint j = i + 1u; j < payload.count; ++j) {
			if (payload.depths[min_i] > payload.depths[j]) {
				min_i = j;
			}
		}
		if (min_i != i) {
			TracePostHit hit = payload.hits[min_i];
			payload.hits[min_i] = payload.hits[i];
			payload.hits[i] = hit;

			float depth = payload.depths[min_i];
			payload.depths[min_i] = payload.depths[i];
			payload.depths[i] = depth;
		}
	}
}

vec4 tracePostCompositeLegacy(inout TracePostLegacyPayload payload)
{
	tracePostSortLegacy(payload);

	vec3 emissive = vec3(0.0);
	float revealage = 1.0;
	for (uint i = 0u; i < payload.count; ++i) {
		const TracePostHit hit = payload.hits[i];
		const TracePostMiniGeometry geom = tracePostReadMiniGeometry(hit);
		const Kusok kusok = getKusok(hit.kusok_index);
		const ModelHeader model = getModelHeader(hit.model_index);
		const vec4 texture_color = LINEARtoSRGB(
			texture(textures[nonuniformEXT(kusok.material.tex_base_color)], geom.uv));
		const vec4 mm_color = model.color * kusok.material.base_color;
		float alpha = mm_color.a * texture_color.a * geom.vertex_color_srgb.a;
		vec3 color = mm_color.rgb * texture_color.rgb * geom.vertex_color_srgb.rgb * alpha;

		const float engage_dist = 20.0;
		const float full_dist = 40.0;
		const float soft_overshoot = 16.0 * smoothstep(engage_dist, full_dist, payload.depths[i]);
		const float overshoot = payload.depths[i] - payload.ray_length;
		color *= smoothstep(soft_overshoot, 0.0, overshoot);

		if (model.mode == MATERIAL_MODE_BLEND_GLOW || model.mode == MATERIAL_MODE_BLEND_ADD) {
			alpha = 0.0;
		} else if (model.mode != MATERIAL_MODE_BLEND_MIX) {
			color = vec3(1.0, 0.0, 1.0);
		}

		emissive += color * revealage;
		revealage *= 1.0 - alpha;
	}

	return vec4(emissive, revealage);
}

#endif
