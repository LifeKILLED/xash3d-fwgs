#ifndef BOUNCE_PATH_LIGHT_RIS_COMMON_GLSL_INCLUDED
#define BOUNCE_PATH_LIGHT_RIS_COMMON_GLSL_INCLUDED

// Fresh paths rebuild every visible local RIS slot. Historical paths rebuild exactly
// one scheduled point/poly slot; the remaining slots reuse their cached samples.

#ifndef BOUNCE_PATH_LIGHT_SLOT_BASE
#error BOUNCE_PATH_LIGHT_SLOT_BASE must be defined
#endif
#ifndef BOUNCE_PATH_OUT_FRESH_RESERVOIR
#error BOUNCE_PATH_OUT_FRESH_RESERVOIR must be defined
#endif
#ifndef BOUNCE_PATH_OUT_FRESH_RANDOM
#error BOUNCE_PATH_OUT_FRESH_RANDOM must be defined
#endif
#ifndef BOUNCE_PATH_OUT_FRESH_LIGHT
#error BOUNCE_PATH_OUT_FRESH_LIGHT must be defined
#endif
#ifndef BOUNCE_PATH_OUT_HISTORY_RESERVOIR
#error BOUNCE_PATH_OUT_HISTORY_RESERVOIR must be defined
#endif
#ifndef BOUNCE_PATH_OUT_HISTORY_RANDOM
#error BOUNCE_PATH_OUT_HISTORY_RANDOM must be defined
#endif
#ifndef BOUNCE_PATH_OUT_HISTORY_LIGHT
#error BOUNCE_PATH_OUT_HISTORY_LIGHT must be defined
#endif
#ifndef BOUNCE_PATH_PREV_TEMPORAL_RESERVOIR
#error BOUNCE_PATH_PREV_TEMPORAL_RESERVOIR must be defined
#endif
#ifndef BOUNCE_PATH_PREV_TEMPORAL_RANDOM
#error BOUNCE_PATH_PREV_TEMPORAL_RANDOM must be defined
#endif

#define RIS_SIMPLIFIED_RESAMPLING 1
#define RIS_INIT_PASS 1
#define RIS_UNIFIED_PASS 1
#define RIS_INIT_HALF_RES 0
#define RIS_CUSTOM_TEMPORAL_HISTORY 1
#define RIS_LOAD_TEMPORAL_REFERENCE_POSITION(pix_) vec3(0.0)
#define RIS_PIXEL_IN_BOUNDS(pix_) bouncePathAtlasPixelInBounds(pix_)

bool risFindTemporalHistoryPixel(
	ivec2 pix,
	ivec2 surface_pix,
	vec3 prev_position,
	vec3 geometry_normal,
	out ivec2 history_pix)
{
	history_pix = ivec2(-1);
	return false;
}

#include "bounce_path_common.glsl"
#include "light_ris.glsl"

RisTemporalReservoir bouncePathDecodeLocalReservoir(
	vec4 encoded,
	vec4 random_count,
	out bool regir_source)
{
	regir_source = random_count.w < 0.0;
	RisTemporalReservoir reservoir = risDecodeTemporalReservoir(encoded);
	if (!risTemporalReservoirValid(reservoir)) {
		regir_source = false;
		return risInvalidTemporalReservoir();
	}
	reservoir.sample_random = clamp(random_count.xyz, vec3(0.0), vec3(1.0));
	reservoir.sample_count = abs(random_count.w);
	if (!risTemporalReservoirValid(reservoir)) {
		regir_source = false;
		return risInvalidTemporalReservoir();
	}
	return reservoir;
}

float bouncePathEncodeLocalSampleCount(float sample_count, bool regir_source)
{
	const float encoded_count = max(sample_count, 0.0);
	return regir_source ? -encoded_count : encoded_count;
}

void bouncePathStoreFreshLocalReservoir(
	ivec2 pix,
	RisTemporalReservoir reservoir,
	bool regir_source,
	vec3 diffuse)
{
	imageStore(BOUNCE_PATH_OUT_FRESH_RESERVOIR, pix, risEncodeTemporalReservoir(reservoir));
	imageStore(BOUNCE_PATH_OUT_FRESH_RANDOM, pix,
		risTemporalReservoirValid(reservoir)
			? vec4(
				clamp(reservoir.sample_random, vec3(0.0), vec3(1.0)),
				bouncePathEncodeLocalSampleCount(reservoir.sample_count, regir_source))
			: vec4(0.0));
	imageStore(BOUNCE_PATH_OUT_FRESH_LIGHT, pix, vec4(max(diffuse, vec3(0.0)), 0.0));
}

void bouncePathStoreHistoryLocalReservoir(
	ivec2 pix,
	RisTemporalReservoir reservoir,
	bool regir_source,
	vec3 diffuse)
{
	imageStore(BOUNCE_PATH_OUT_HISTORY_RESERVOIR, pix, risEncodeTemporalReservoir(reservoir));
	imageStore(BOUNCE_PATH_OUT_HISTORY_RANDOM, pix,
		risTemporalReservoirValid(reservoir)
			? vec4(
				clamp(reservoir.sample_random, vec3(0.0), vec3(1.0)),
				bouncePathEncodeLocalSampleCount(reservoir.sample_count, regir_source))
			: vec4(0.0));
	imageStore(BOUNCE_PATH_OUT_HISTORY_LIGHT, pix, vec4(max(diffuse, vec3(0.0)), 0.0));
}

#if !RIS_REGIR_ONLY
float bouncePathInvDiscreteLightPdf(uint cluster_index)
{
	const uint cluster_light_count = risLightCount(cluster_index);
	uint eligible_light_count = 0u;
	for (uint i = 0u; i < cluster_light_count; ++i) {
		RisLightSample light;
		if (risLoadLightSample(risLightId(cluster_index, i), light)) {
			eligible_light_count += 1u;
		}
	}
	return float(eligible_light_count);
}
#endif

void bouncePathAddAlwaysSampledLights(
	BouncePathSurface surface,
	uint cluster_index,
	bool ris_active,
	inout vec3 diffuse)
{
#if LIGHT_POINT
	vec3 always_diffuse;
	vec3 always_specular;
	vec3 flashlight_diffuse;
	vec3 flashlight_specular;
	computePointAlwaysSampledLights(
		surface.P,
		surface.transport_N,
		surface.V,
		surface.material,
		cluster_index,
		ris_active,
		always_diffuse,
		always_specular,
		flashlight_diffuse,
		flashlight_specular);
	diffuse += always_diffuse + flashlight_diffuse;
#endif
}

bool bouncePathBuildVisibleLocalReservoir(
	BouncePathSurface surface,
	ivec2 random_pix,
	uint path_seed,
	uint lane,
	out RisTemporalReservoir reservoir,
	out bool regir_source,
	out vec3 diffuse)
{
	reservoir = risInvalidTemporalReservoir();
	regir_source = false;
	diffuse = vec3(0.0);
	if (!surface.contributes || !surface.hit) {
		return false;
	}

	uint cluster_index = 0u;
	bool ris_active = (ubo.ubo.debug_flags & DEBUG_FLAG_WHITE_FURNACE) == 0;
#if !RIS_REGIR_ONLY
	const bool cluster_valid = computeLightingRISState(surface.P, true, cluster_index, ris_active);
	if (!cluster_valid) {
		return false;
	}
#endif

	rand01_state = xxhash32(uvec4(
		path_seed,
		lane,
		uint(random_pix.x),
		uint(random_pix.y) ^ uint(BOUNCE_PATH_LIGHT_SLOT_BASE)));

	if (ris_active && (ubo.ubo.renderer_flags & RENDERER_FLAG_DISABLE_REGIR) == 0u) {
		bool regir_accepted = false;
		reservoir = RIS_MERGE_REGIR_VISIBLE_CANDIDATES(
			surface.P,
			surface.transport_N,
			surface.V,
			surface.material,
			random_pix,
			reservoir,
			regir_accepted);
		regir_source = regir_accepted;
#if !RIS_REGIR_ONLY
		if (!regir_accepted) {
			reservoir = risMergeVisibleCandidates(
				cluster_index,
				surface.P,
				surface.transport_N,
				surface.V,
				surface.material,
				random_pix,
				reservoir);
		}
#endif
	}

	// ReGIR's onion_candidate.inv_source_pdf is already folded into weight_sum.
	// No cluster-dependent PDF is applied when evaluating or rotating the cache.
#if RIS_REGIR_ONLY
	const float source_inv_pdf = 1.0;
#else
	const float source_inv_pdf = regir_source
		? 1.0
		: bouncePathInvDiscreteLightPdf(cluster_index);
#endif
	vec3 selected_specular;
	const bool shaded = risShadeUnifiedReservoir(
		reservoir,
		source_inv_pdf,
		surface.P,
		surface.transport_N,
		surface.V,
		surface.material,
		diffuse,
		selected_specular);
	bouncePathAddAlwaysSampledLights(surface, cluster_index, ris_active, diffuse);
	return shaded || any(greaterThan(diffuse, vec3(0.0)));
}

bool bouncePathShadeCachedLocalReservoir(
	BouncePathSurface surface,
	RisTemporalReservoir reservoir,
	bool regir_source,
	out RisTemporalReservoir updated_reservoir,
	out vec3 diffuse)
{
	updated_reservoir = reservoir;
	diffuse = vec3(0.0);
	if (!surface.contributes || !surface.hit) {
		return false;
	}

	uint cluster_index = 0u;
	bool ris_active = (ubo.ubo.debug_flags & DEBUG_FLAG_WHITE_FURNACE) == 0;
#if !RIS_REGIR_ONLY
	if (!computeLightingRISState(surface.P, true, cluster_index, ris_active)) {
		return false;
	}
#endif

	bool shaded = false;
	if (risTemporalReservoirValid(updated_reservoir)) {
		vec3 selected_specular;
		shaded = risShadeUnifiedReservoir(
			updated_reservoir,
#if RIS_REGIR_ONLY
			1.0,
#else
			regir_source ? 1.0 : bouncePathInvDiscreteLightPdf(cluster_index),
#endif
			surface.P,
			surface.transport_N,
			surface.V,
			surface.material,
			diffuse,
			selected_specular);
	}
	bouncePathAddAlwaysSampledLights(surface, cluster_index, ris_active, diffuse);
	return shaded || any(greaterThan(diffuse, vec3(0.0)));
}

void main()
{
	const ivec2 local_pix = ivec2(gl_GlobalInvocationID.xy);
	if (!bouncePathLocalPixelInBounds(local_pix)) {
		return;
	}

	const vec4 fresh_meta = imageLoad(bounce_path_fresh_meta, local_pix);
	const uint fresh_length = bouncePathLengthFromMeta(fresh_meta);
	const uint fresh_seed = bouncePathUnpackSeed(fresh_meta.xy);

	const vec4 history_ref = imageLoad(bounce_path_history_ref, local_pix);
	const bool history_valid = bouncePathHistoryRefValid(history_ref);
	const ivec2 history_local_pix = bouncePathHistoryLocalPixel(history_ref);
	const uint refresh_slot = bouncePathRefreshSlot(history_ref);
	vec4 history_meta = vec4(0.0);
	uint history_length = 0u;
	uint history_seed = 0u;
	if (history_valid) {
		history_meta = imageLoad(prev_temporal_bounce_path_meta, history_local_pix);
		history_length = bouncePathLengthFromMeta(history_meta);
		history_seed = bouncePathUnpackSeed(history_meta.xy);
	}

	for (uint lane = 0u; lane < BOUNCE_PATH_MAX_VERTICES; ++lane) {
		const ivec2 output_pix = bouncePathAtlasPixel(local_pix, lane);
		bouncePathStoreFreshLocalReservoir(output_pix, risInvalidTemporalReservoir(), false, vec3(0.0));
		bouncePathStoreHistoryLocalReservoir(output_pix, risInvalidTemporalReservoir(), false, vec3(0.0));

		if (lane < fresh_length) {
			const BouncePathSurface fresh_surface = bouncePathLoadFreshSurface(local_pix, lane);
			RisTemporalReservoir fresh_reservoir;
			bool fresh_regir_source;
			vec3 fresh_diffuse;
			bouncePathBuildVisibleLocalReservoir(
				fresh_surface,
				output_pix,
				fresh_seed,
				lane,
				fresh_reservoir,
				fresh_regir_source,
				fresh_diffuse);
			bouncePathStoreFreshLocalReservoir(
				output_pix,
				fresh_reservoir,
				fresh_regir_source,
				fresh_diffuse);
		}

		if (!history_valid || lane >= history_length) {
			continue;
		}

		const ivec2 history_atlas_pix = bouncePathAtlasPixel(history_local_pix, lane);
		const BouncePathSurface history_surface = bouncePathLoadHistorySurface(history_local_pix, lane);
		bool history_regir_source;
		RisTemporalReservoir history_reservoir = bouncePathDecodeLocalReservoir(
			imageLoad(BOUNCE_PATH_PREV_TEMPORAL_RESERVOIR, history_atlas_pix),
			imageLoad(BOUNCE_PATH_PREV_TEMPORAL_RANDOM, history_atlas_pix),
			history_regir_source);
		vec3 history_diffuse = vec3(0.0);

		const bool scheduled_refresh = refresh_slot == BOUNCE_PATH_LIGHT_SLOT_BASE + lane;
		if (scheduled_refresh) {
			// Only one point/poly lane is fully rebuilt per historical path and frame.
			bouncePathBuildVisibleLocalReservoir(
				history_surface,
				output_pix,
				history_seed ^ 0x68737472u,
				lane,
				history_reservoir,
				history_regir_source,
				history_diffuse);
		} else {
			RisTemporalReservoir updated_reservoir;
			bouncePathShadeCachedLocalReservoir(
				history_surface,
				history_reservoir,
				history_regir_source,
				updated_reservoir,
				history_diffuse);
			history_reservoir = updated_reservoir;
		}

		bouncePathStoreHistoryLocalReservoir(
			output_pix,
			history_reservoir,
			history_regir_source,
			history_diffuse);
	}
}

#endif // BOUNCE_PATH_LIGHT_RIS_COMMON_GLSL_INCLUDED
