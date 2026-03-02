#include "utils.glsl"
#include "brdf.h"
#include "denoiser_config.glsl"

#define GLSL
#include "ray_interop.h"
#undef GLSL

#ifndef FILTER_RADIUS
#define FILTER_RADIUS 8
#endif

#ifndef REQUIRED_MATCHES
#define REQUIRED_MATCHES 3
#endif

#ifndef POSITION_PLANE_THRESHOLD
#define POSITION_PLANE_THRESHOLD 0.010
#endif

#ifndef POSITION_DIST2_THRESHOLD
#define POSITION_DIST2_THRESHOLD 0.0004
#endif

#ifndef POSITION_T
#define POSITION_T position_t
#endif

#ifndef NORMALS_GS
#define NORMALS_GS normals_gs
#endif

#ifndef INPUT_IS_SHADOW_VALUE
#define INPUT_IS_SHADOW_VALUE 0
#endif

#ifndef SHADOW_FILTER_USE_SHARED_PINGPONG
#define SHADOW_FILTER_USE_SHARED_PINGPONG 0
#endif

#ifndef SHADOW_SHARED_PINGPONG_SOURCE
#define SHADOW_SHARED_PINGPONG_SOURCE restir_shadows_h
#endif

#ifndef SHADOW_SHARED_PINGPONG_OUTPUT
#define SHADOW_SHARED_PINGPONG_OUTPUT out_restir_shadows_h
#endif

#ifndef SHADOW_FILTER_OUTPUT_IRRADIANCE
#define SHADOW_FILTER_OUTPUT_IRRADIANCE 0
#endif

#ifndef SHADOW_FILTER_IRRADIANCE_SOURCE
#define SHADOW_FILTER_IRRADIANCE_SOURCE diffuse_direct_reconstructed
#endif

#ifndef SHADOW_FILTER_OUTPUT_TEXTURE
#define SHADOW_FILTER_OUTPUT_TEXTURE out_direct_shadowed
#endif

#ifndef SHADOW_FILTER_APPLY_ABS
#define SHADOW_FILTER_APPLY_ABS 1
#endif

#ifndef SHADOW_FILTER_BYPASS_RAW_IRRADIANCE
#define SHADOW_FILTER_BYPASS_RAW_IRRADIANCE 1
#endif

#if SHADOW_FILTER_USE_SHARED_PINGPONG
    #ifdef HORIZONTAL
        #ifdef OUTPUT_SHADOW
            #undef OUTPUT_SHADOW
        #endif
        #define OUTPUT_SHADOW SHADOW_SHARED_PINGPONG_OUTPUT
    #else
        #ifdef INPUT_SOURCE
            #undef INPUT_SOURCE
        #endif
        #define INPUT_SOURCE SHADOW_SHARED_PINGPONG_SOURCE
        #undef INPUT_IS_SHADOW_VALUE
        #define INPUT_IS_SHADOW_VALUE 1
    #endif
#endif

#ifndef SHADOW_VALUE_CHANNEL
#define SHADOW_VALUE_CHANNEL r
#endif

#ifndef SHADOW_THRESHOLD
#define SHADOW_THRESHOLD 0.0
#endif

#ifndef LIGHT_ID_THRESHOLD
#define LIGHT_ID_THRESHOLD 0.01
#endif

#ifndef SHADOW_OUTPUT_ALPHA
#define SHADOW_OUTPUT_ALPHA 1.0
#endif

#ifndef FILTER_START_RADIUS
#define FILTER_START_RADIUS 1
#endif

#ifndef FILTER_POSITIVE_FIRST
#define FILTER_POSITIVE_FIRST 1
#endif

layout(local_size_x = 8, local_size_y = 8) in;

layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D OUTPUT_SHADOW;
layout(set = 0, binding = 1, rgba16f) uniform readonly image2D INPUT_SOURCE;
layout(set = 0, binding = 2, rgba16f) uniform readonly image2D LIGHT_ID_SOURCE;
layout(set = 0, binding = 3, rgba32f) uniform readonly image2D POSITION_T;
layout(set = 0, binding = 4, rgba16f) uniform readonly image2D NORMALS_GS;
layout(set = 0, binding = 5) uniform UBO { UniformBuffer ubo; } ubo;

#if SHADOW_FILTER_OUTPUT_IRRADIANCE
layout(set = 0, binding = 6, rgba16f) uniform readonly image2D SHADOW_FILTER_IRRADIANCE_SOURCE;
layout(set = 0, binding = 7, rgba16f) uniform writeonly image2D SHADOW_FILTER_OUTPUT_TEXTURE;
#endif

float position_gate(vec3 delta_pos, vec3 geom_norm, float inv_center_dist) {
    float n_plane_dist = abs(dot(delta_pos, geom_norm)) * inv_center_dist;
    float n_dist2 = dot(delta_pos, delta_pos) * (inv_center_dist * inv_center_dist);
    float w_plane = step(n_plane_dist, POSITION_PLANE_THRESHOLD);
    float w_dist = step(n_dist2, POSITION_DIST2_THRESHOLD);
    return max(w_plane, w_dist);
}

float shadow_from_radiance(vec3 radiance) {
    return (luminance(radiance) < SHADOW_THRESHOLD) ? -1.0 : 1.0;
}

float load_shadow_value(ivec2 pix) {
#if INPUT_IS_SHADOW_VALUE
    return clamp(imageLoad(INPUT_SOURCE, pix).SHADOW_VALUE_CHANNEL, -1.0, 1.0);
#else
    return shadow_from_radiance(imageLoad(INPUT_SOURCE, pix).rgb);
#endif
}

void store_shadowed_irradiance(ivec2 pix, float shadow_value) {
#if SHADOW_FILTER_OUTPUT_IRRADIANCE
    vec4 irradiance = imageLoad(SHADOW_FILTER_IRRADIANCE_SOURCE, pix);
#if SHADOW_FILTER_APPLY_ABS
    vec3 rgb = abs(irradiance.rgb);
#else
    vec3 rgb = irradiance.rgb;
#endif
    imageStore(SHADOW_FILTER_OUTPUT_TEXTURE, pix, vec4(rgb * shadow_value, irradiance.a));
#endif
}

void store_bypass_irradiance(ivec2 pix) {
#if SHADOW_FILTER_OUTPUT_IRRADIANCE
    vec4 irradiance = imageLoad(SHADOW_FILTER_IRRADIANCE_SOURCE, pix);
#if SHADOW_FILTER_BYPASS_RAW_IRRADIANCE
    imageStore(SHADOW_FILTER_OUTPUT_TEXTURE, pix, irradiance);
#else
    float shadow_value = load_shadow_value(pix);
    store_shadowed_irradiance(pix, shadow_value);
#endif
#endif
}

void main() {
    ivec2 pix = ivec2(gl_GlobalInvocationID.xy);
    ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
    if (any(greaterThanEqual(pix, res))) return;

    float center_shadow = load_shadow_value(pix);
    if (DENOISER_ENABLE_SHADOWS_FILTERING == 0) {
        imageStore(OUTPUT_SHADOW, pix, vec4(center_shadow, center_shadow, center_shadow, SHADOW_OUTPUT_ALPHA));
        store_bypass_irradiance(pix);
        return;
    }

    vec3 p0 = imageLoad(POSITION_T, pix).xyz;
    vec3 g0 = normalDecode(imageLoad(NORMALS_GS, pix).xy);
    float inv_center_dist = 1.0 / max(length(p0), 1.0);

    float light_id0 = imageLoad(LIGHT_ID_SOURCE, pix).w;

    float sum = center_shadow;
    float count = 1.0;
    int matches = 0;

    for (int s = FILTER_START_RADIUS; s <= FILTER_RADIUS; s++) {
        for (int side_iter = 0; side_iter < 2; side_iter++) {
            int side =
#if FILTER_POSITIVE_FIRST
                ((side_iter == 0) ? 1 : -1); // +1, -1, +2, -2, ...
#else
                ((side_iter == 0) ? -1 : 1); // -1, +1, -2, +2, ...
#endif
            ivec2 sample_pix = pix;
#ifdef HORIZONTAL
            sample_pix.x += side * s;
#else
            sample_pix.y += side * s;
#endif
            if (any(lessThan(sample_pix, ivec2(0))) || any(greaterThanEqual(sample_pix, res))) continue;

            float light_id1 = imageLoad(LIGHT_ID_SOURCE, sample_pix).w;
            if (abs(light_id1 - light_id0) > LIGHT_ID_THRESHOLD) continue;

            vec3 p1 = imageLoad(POSITION_T, sample_pix).xyz;
            if (position_gate(p1 - p0, g0, inv_center_dist) == 0.0) continue;

            float shadow_sample = load_shadow_value(sample_pix);
            sum += shadow_sample;
            count += 1.0;
            matches++;
            if (matches >= REQUIRED_MATCHES) break;
        }
        if (matches >= REQUIRED_MATCHES) break;
    }

    float out_shadow = clamp(sum / max(count, 1.0), -1.0, 1.0);
    imageStore(OUTPUT_SHADOW, pix, vec4(out_shadow, out_shadow, out_shadow, SHADOW_OUTPUT_ALPHA));
    store_shadowed_irradiance(pix, out_shadow);
}
