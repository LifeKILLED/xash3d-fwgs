#ifndef LIGHTCACHE_SAMPLING_GLSL
#define LIGHTCACHE_SAMPLING_GLSL
#define LIGHTCACHE_GEOMETRY_BINDING 90
#include "lightcache_geometry.glsl"
#include "spherical_harmonics.glsl"
layout(set = 0, binding = 91, rgba16f) uniform readonly image2D temporal_lightcache_shy;
layout(set = 0, binding = 92, rgba16f) uniform readonly image2D temporal_lightcache_cocg;

bool lightcacheSampleSH(vec2 uv, out SH sh) {
    sh.shY = vec4(0); sh.CoCg = vec2(0);
    uint encoded = lightcacheLookup(uv);
    if (encoded == 0u || !lightcacheInCapacity(encoded - 1u, ubo.ubo.res)) return false;
    ivec2 taps[4]; vec4 weights;
    if (!lightcacheBilinearFootprint(encoded - 1u, uv, ubo.ubo.res, taps, weights)) return false;
    for (int i = 0; i < 4; ++i) {
        SH sample_sh;
        sample_sh.shY = imageLoad(temporal_lightcache_shy, taps[i]);
        sample_sh.CoCg = imageLoad(temporal_lightcache_cocg, taps[i]).xy;
        accumulate_SH(sh, sample_sh, weights[i]);
    }
    return true;
}

vec3 lightcacheSampleLighting(vec4 uv, vec3 N, vec3 V, float metalness) {
    if (uv.z <= 0.0) return vec3(0);
    SH sh;
    if (!lightcacheSampleSH(uv.xy, sh)) return vec3(0);
    return mix(project_SH_irradiance(sh, N),
        project_SH_irradiance(sh, reflect(-V, N)), metalness);
}
#endif
