#ifndef TRACE_POST_PIPELINE_GLSL_INCLUDED
#define TRACE_POST_PIPELINE_GLSL_INCLUDED

#include "trace_post_pipeline_common.glsl"

const uint kTracePostRayFlags =
	gl_RayFlagsCullFrontFacingTrianglesEXT |
	gl_RayFlagsNoOpaqueEXT;

#if TRACE_POST_LEGACY
void tracePostLegacyPipeline(
	vec3 origin,
	vec3 direction,
	float ray_length,
	inout TracePostRtLegacyPayload payload)
{
	payload.count = 0u;
	traceRayEXT(
		tlas,
		kTracePostRayFlags,
		GEOMETRY_BIT_BLEND,
		0,
		0,
		0,
		origin,
		0.0,
		direction,
		ray_length + 16.0,
		PAYLOAD_LOCATION_TRACE_POST);
}

void tracePostRtSortLegacy(inout TracePostRtLegacyPayload payload)
{
	for (uint i = 0u; i < payload.count; ++i) {
		uint min_i = i;
		for (uint j = i + 1u; j < payload.count; ++j) {
			if (payload.depths[min_i] > payload.depths[j]) {
				min_i = j;
			}
		}
		if (min_i != i) {
			const uvec2 hit = payload.hits[min_i];
			payload.hits[min_i] = payload.hits[i];
			payload.hits[i] = hit;
			const uint bary = payload.barycentrics[min_i];
			payload.barycentrics[min_i] = payload.barycentrics[i];
			payload.barycentrics[i] = bary;
			const float depth = payload.depths[min_i];
			payload.depths[min_i] = payload.depths[i];
			payload.depths[i] = depth;
		}
	}
}

vec4 tracePostCompositeLegacyPipeline(
	inout TracePostRtLegacyPayload payload,
	float ray_length)
{
	tracePostRtSortLegacy(payload);

	vec3 emissive = vec3(0.0);
	float revealage = 1.0;
	for (uint i = 0u; i < payload.count; ++i) {
		const uvec2 hit = payload.hits[i];
		const float hit_t = payload.depths[i];
		Kusok kusok;
		ModelHeader model;
		TracePostRtGeometry geometry;
		tracePostRtReadHit(hit, payload.barycentrics[i], kusok, model, geometry);
		const vec4 texture_color = LINEARtoSRGB(
			texture(textures[nonuniformEXT(kusok.material.tex_base_color)], geometry.uv));
		const vec4 mm_color = model.color * kusok.material.base_color;
		float alpha = mm_color.a * texture_color.a * geometry.vertex_color_srgb.a;
		vec3 color = mm_color.rgb * texture_color.rgb * geometry.vertex_color_srgb.rgb * alpha;

		const float engage_dist = 20.0;
		const float full_dist = 40.0;
		const float soft_overshoot = 16.0 * smoothstep(engage_dist, full_dist, hit_t);
		const float overshoot = hit_t - ray_length;
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

#endif
