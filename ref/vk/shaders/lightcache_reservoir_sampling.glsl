// RGB cache experiment has no legacy RIS reservoir encoding.
#if 0
// Address the diffuse light cache at the receiving surface of each RIS pass.
// Current-frame cache reservoirs are already shadow-tested by the cache update.
#define LIGHTCACHE_GEOMETRY_BINDING 90
#include "lightcache_geometry.glsl"
#ifdef RIS_LIGHTCACHE_UV_IMAGE
layout(set = 0, binding = 93, rgba32f) uniform readonly image2D RIS_LIGHTCACHE_UV_IMAGE;
#endif
layout(set = 0, binding = 94, rgba32f) uniform readonly image2D temporal_lightcache_state;
#if LIGHT_POINT
layout(set = 0, binding = 95, rgba32f) uniform readonly image2D temporal_lightcache_point_reservoir;
layout(set = 0, binding = 96, rgba32f) uniform readonly image2D temporal_lightcache_point_random;
layout(set = 0, binding = 97, rgba32f) uniform readonly image2D temporal_lightcache_point_visibility;
#define RIS_LC_RESERVOIR temporal_lightcache_point_reservoir
#define RIS_LC_RANDOM temporal_lightcache_point_random
#define RIS_LC_VISIBILITY temporal_lightcache_point_visibility
#else
layout(set = 0, binding = 95, rgba32f) uniform readonly image2D temporal_lightcache_poly_reservoir;
layout(set = 0, binding = 96, rgba32f) uniform readonly image2D temporal_lightcache_poly_random;
layout(set = 0, binding = 97, rgba32f) uniform readonly image2D temporal_lightcache_poly_visibility;
#define RIS_LC_RESERVOIR temporal_lightcache_poly_reservoir
#define RIS_LC_RANDOM temporal_lightcache_poly_random
#define RIS_LC_VISIBILITY temporal_lightcache_poly_visibility
#endif

RisTemporalReservoir risSeedLightcacheReservoirUV(
    vec4 uv, ivec2 pix, int lobe, float target_scale,
    vec3 P, vec3 geometry_N, vec3 N, vec3 V, MaterialProperties material)
{
    RisTemporalReservoir result = risInvalidTemporalReservoir();
    if (uv.z <= 0.0) return result;
    uint encoded = lightcacheLookup(uv.xy);
    if (encoded == 0u || !lightcacheInCapacity(encoded - 1u, ubo.ubo.res)) return result;
    // Preserve the fractional hit UV. Dither over one source-lightmap texel
    // (one texel wide, centered at zero), not one packed cache/screen pixel.
    // Resolve the island before jitter so atlas boundaries cannot change it.
    const vec2 dither = vec2(
        risTemporalRandom01(pix, 0x6c636a78u),
        risTemporalRandom01(pix, 0x6c636a79u)) - vec2(0.5);
    const vec2 sample_uv = uv.xy + dither / 1024.0;
    // Convert LM UV to a 2x2 footprint in the island-local cache texel grid.
    // Packing into the screen-sized storage image happens only after lookup.
    ivec2 taps[4];
    if (!lightcacheReservoirFootprint(encoded - 1u, sample_uv, ubo.ubo.res, taps)) return result;
    for (int tap = 0; tap < 4; ++tap) {
        // Outside taps are rejected, never replaced by a clamped edge texel.
        if (any(lessThan(taps[tap], ivec2(0)))) continue;
        vec4 state = imageLoad(temporal_lightcache_state, taps[tap]);
        if (state.x != float(lightcache_geometry.info.y) ||
            any(notEqual(state.yz, vec2(ubo.ubo.res))) ||
            state.w != float(ubo.ubo.frame_counter)) continue;
        RisTemporalReservoir source = risDecodeTemporalReservoir(imageLoad(RIS_LC_RESERVOIR, taps[tap]));
        vec4 random_count = imageLoad(RIS_LC_RANDOM, taps[tap]);
        source.sample_random = random_count.xyz;
        source.sample_count = random_count.w;
        if (!risTemporalReservoirValid(source) || !RIS_RESOLVE_RESERVOIR_LIGHT_ID(source)) continue;
        RIS_LIGHT_SAMPLE light;
        vec2 lobes = vec2(0.0);
        const bool evaluated = RIS_LOAD_LIGHT(source.light_id, light) &&
            risEvaluateUnifiedResamplingTarget(light, source.sample_random,
                P, geometry_N, N, V, material, false, lobes);
        float target = risUnifiedTargetWeight(lobes * target_scale, material, lobe);
        // Confidence scales BOTH mass and M, preserving W = mass/(M*target).
        // Scaling mass alone would dim the cache seed rather than just make
        // it easier for fresh candidates to replace. Keep zero proposals in M.
        float penalized_target = risUnifiedTargetWeight(
            lobes * vec2(0.3, 0.1) * target_scale, material, lobe);
        float cache_confidence = target > RIS_WEIGHT_EPSILON
            ? penalized_target / target
            : risUnifiedTargetWeight(vec2(0.3, 0.1), material, lobe);
        result.sample_count += cache_confidence;
        if (!evaluated) continue;
        float visibility = clamp(imageLoad(RIS_LC_VISIBILITY, taps[tap]).x, 0.0, 1.0);
        // Preserve the normalized source estimator W while resetting M to one.
        // Importing its whole temporal mass would overwhelm fresh candidates.
        // All valid neighbors enter equally, without bilinear attenuation.
        float inv_pdf = source.weight_sum /
            max(source.sample_count * source.mixed_weight, RIS_WEIGHT_EPSILON) /
            max(target_scale, RIS_WEIGHT_EPSILON);
        float mass = target * inv_pdf * visibility * cache_confidence;
        if (!(mass > RIS_WEIGHT_EPSILON) || isnan(mass) || isinf(mass)) continue;
        float total_mass = result.weight_sum + mass;
        if (result.weight_sum == 0.0 ||
            risTemporalRandom01(pix, 0x6c630000u + uint(lobe) * 4u + uint(tap)) * total_mass < mass) {
            result.light_id = source.light_id;
            result.light_hash = source.light_hash;
            result.sample_random = source.sample_random;
            result.mixed_weight = target;
#if RIS_DIRECT_DIFFUSE_REGIR_REVERT
            result.regir_inv_source_pdf = inv_pdf * visibility;
#endif
        }
        result.weight_sum = total_mass;
    }
    return result;
}
#undef RIS_LC_RESERVOIR
#undef RIS_LC_RANDOM
#undef RIS_LC_VISIBILITY

#ifdef RIS_LIGHTCACHE_UV_IMAGE
RisTemporalReservoir risSeedLightcacheReservoir(
    ivec2 surface_pix, ivec2 pix, int lobe, float target_scale,
    vec3 P, vec3 geometry_N, vec3 N, vec3 V, MaterialProperties material)
{
    return risSeedLightcacheReservoirUV(imageLoad(RIS_LIGHTCACHE_UV_IMAGE, surface_pix),
        pix, lobe, target_scale, P, geometry_N, N, V, material);
}
#endif

#else
RisTemporalReservoir risSeedLightcacheReservoirUV(
    vec4 uv, ivec2 pix, int lobe, float target_scale,
    vec3 P, vec3 geometry_N, vec3 N, vec3 V, MaterialProperties material)
{ return risInvalidTemporalReservoir(); }
#ifdef RIS_LIGHTCACHE_UV_IMAGE
RisTemporalReservoir risSeedLightcacheReservoir(
    ivec2 surface_pix, ivec2 pix, int lobe, float target_scale,
    vec3 P, vec3 geometry_N, vec3 N, vec3 V, MaterialProperties material)
{ return risInvalidTemporalReservoir(); }
#endif
#endif
