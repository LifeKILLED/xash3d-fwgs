#include "debug.glsl"
#include "denoiser_config.glsl"
#include "utils.glsl"
#include "color_spaces.glsl"
#include "brdf.glsl"

#define GLSL
#include "ray_interop.h"
#undef GLSL

// ============================================================
// Compile-time direction selection
// ============================================================
// Define exactly ONE of these when compiling:
//
//   #define HORIZONTAL
//   #define VERTICAL
//
// ============================================================

#if defined(HORIZONTAL)
    #define OUT_RADIANCE out_radiance_temp
#elif defined(VERTICAL)
    #define IN_RADIANCE  radiance_temp
#else
    #error "Define HORIZONTAL or VERTICAL"
#endif

// ============================================================
// Tunable parameters (provided externally)
// ============================================================
// #define R_BASE 4           // radius in fully lit or fully shadowed areas
// #define R_PENUMBRA 12      // radius in penumbra
// #define SIGMA_N 0.02       // normal similarity
// #define SIGMA_P 100.0      // position similarity
// #define SIGMA_R 0.2        // roughness similarity

#ifndef FILTER_MASK_GATE_ENABLE
#define FILTER_MASK_GATE_ENABLE 1
#endif

#ifndef FILTER_SHADOW_MASK_SOURCE
#define FILTER_SHADOW_MASK_SOURCE asvgf_shadow_mask_normalized
#endif

#ifndef FILTER_SHADOW_MASK_CHANNEL
#define FILTER_SHADOW_MASK_CHANNEL 0
#endif

#ifndef FILTER_NORMAL_DOT_THRESHOLD
#define FILTER_NORMAL_DOT_THRESHOLD 0.99
#endif

#ifndef FILTER_ROUGHNESS_THRESHOLD
#define FILTER_ROUGHNESS_THRESHOLD 0.20
#endif

#ifndef ATROUS_MASK_DIFF_MIN
#define ATROUS_MASK_DIFF_MIN 0.01
#endif

#ifndef ATROUS_MASK_DIFF_MAX
#define ATROUS_MASK_DIFF_MAX 0.30
#endif

#ifndef ATROUS_MASK_GATE_STRENGTH
#define ATROUS_MASK_GATE_STRENGTH 1.0
#endif

layout(local_size_x = 16, local_size_y = 8) in;

// ============================================================
// Images
// ============================================================

layout(set = 0, binding = 0, rgba16f) uniform readonly image2D IN_RADIANCE;

layout(set = 0, binding = 1, rgba32f) uniform readonly image2D POSITION_T;
layout(set = 0, binding = 2, rgba16f) uniform readonly image2D NORMALS_GS;
layout(set = 0, binding = 3, rgba8)   uniform readonly image2D MATERIAL_RMXX;

layout(set = 0, binding = 4, rgba16f) uniform writeonly image2D OUT_RADIANCE;

layout(set = 0, binding = 5) uniform UBO { UniformBuffer ubo; } ubo;
layout(set = 0, binding = 6, rgba16f) uniform readonly image2D FILTER_SHADOW_MASK_SOURCE;

// ============================================================
// Utilities
// ============================================================

ivec2 clampedPix(ivec2 c, ivec2 res) {
    return clamp(c, ivec2(0), res - ivec2(1));
}

float computeGeomGrad(vec3 N0, vec3 P0, vec3 Nx, vec3 Ny, vec3 Px, vec3 Py) {
    float dp2 = dot(Px - P0, Px - P0) + dot(Py - P0, Py - P0);
    float dn = 1.0 - max(dot(N0, Nx), dot(N0, Ny));
    return clamp(dp2 * 0.05 + dn, 0.0, 1.0);
}

float computeVariance(vec3 c, vec3 cx, vec3 cy) {
    vec3 d = c - 0.5 * (cx + cy);
    float v = dot(d, d);
    return clamp(v * 0.5, 0.0, 1.0);
}

float shadowMaskGate(ivec2 p, ivec2 q)
{
#if FILTER_MASK_GATE_ENABLE
    float m0 = imageLoad(FILTER_SHADOW_MASK_SOURCE, p)[FILTER_SHADOW_MASK_CHANNEL];
    float m1 = imageLoad(FILTER_SHADOW_MASK_SOURCE, q)[FILTER_SHADOW_MASK_CHANNEL];
    float dm = abs(m1 - m0);
    float t = (dm - ATROUS_MASK_DIFF_MIN) / max(ATROUS_MASK_DIFF_MAX - ATROUS_MASK_DIFF_MIN, 1e-4);
    float raw_w = 1.0 - clamp(t, 0.0, 1.0);
    return mix(1.0, raw_w, clamp(ATROUS_MASK_GATE_STRENGTH, 0.0, 1.0));
#else
    return 1.0;
#endif
}

// ============================================================
// Main
// ============================================================

void main() {
    const ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
    const ivec2 pix = ivec2(gl_GlobalInvocationID.xy);

    if (any(greaterThanEqual(pix, res)))
        return;

    float R0 = imageLoad(MATERIAL_RMXX, pix).x;

#if MIRROR_FIX
    if (R0 < 0.02) {
        imageStore(OUT_RADIANCE, pix, imageLoad(IN_RADIANCE, pix));
        return;
    }
#endif

    // ========================================================
    // Center G-buffer
    // ========================================================

    vec3 P0 = imageLoad(POSITION_T, pix).xyz;
    vec4 n0enc = imageLoad(NORMALS_GS, pix);
    vec3 G0 = normalDecode(n0enc.xy);
    vec3 N0 = normalDecode(n0enc.zw);
    vec3 camPos = (ubo.ubo.inv_view * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
    float invCenterDist = 1.0 / max(length(P0), 1.0);
    float worldTexelSize = estimateWorldTexelSizeFromCenter(
        pix, res, camPos, P0, ubo.ubo.inv_proj, ubo.ubo.inv_view, DENOISER_POSITION_TEXEL_SIZE_MARGIN);

    // ========================================================
    // Gradient neighborhood (always X/Y, independent of pass)
    // ========================================================

    ivec2 px = clampedPix(pix + ivec2(1, 0), res);
    ivec2 py = clampedPix(pix + ivec2(0, 1), res);

    vec3 Px = imageLoad(POSITION_T, px).xyz;
    vec3 Py = imageLoad(POSITION_T, py).xyz;

    vec3 Nx = normalDecode(imageLoad(NORMALS_GS, px).zw);
    vec3 Ny = normalDecode(imageLoad(NORMALS_GS, py).zw);

    vec3 c0 = imageLoad(IN_RADIANCE, pix).xyz;
    vec3 cx = imageLoad(IN_RADIANCE, px).xyz;
    vec3 cy = imageLoad(IN_RADIANCE, py).xyz;

    float gradLum  = clamp(abs(luminance(cx) - luminance(c0))
                         + abs(luminance(cy) - luminance(c0)), 0.0, 1.0);

    float gradGeom = computeGeomGrad(N0, P0, Nx, Ny, Px, Py);
    float var = computeVariance(c0, cx, cy);

    float grad = clamp(0.60 * gradLum + 0.30 * gradGeom + 0.10 * var, 0.0, 1.0);

    // ========================================================
    // Adaptive radius
    // ========================================================

    float radius = mix(float(R_PENUMBRA), float(R_BASE),
                       smoothstep(0.0, 0.8, grad));
    int R = int(radius);

    // ========================================================
    // Directional offset
    // ========================================================

#ifdef HORIZONTAL
    ivec2 offset = ivec2(1, 0);
#else
    ivec2 offset = ivec2(0, 1);
#endif

    // ========================================================
    // Separable bilateral accumulation
    // ========================================================

    vec3 diffAcc = vec3(0.0);
    float wSum   = 0.0;

    float invRoughnessThr = 1.0 / max(FILTER_ROUGHNESS_THRESHOLD, 1e-4);

    for (int i = -R; i <= R; ++i) {
        ivec2 c = clampedPix(pix + offset * i, res);
        if (all(equal(c, pix))) {
            vec3 d0 = imageLoad(IN_RADIANCE, pix).xyz;
            diffAcc += d0;
            wSum += 1.0;
            continue;
        }

        vec3 P  = imageLoad(POSITION_T, c).xyz;
        float wPos = positionEdgeStopWithWorldTexel(
            P - P0, G0, invCenterDist, DENOISER_POSITION_PLANE_THRESHOLD, worldTexelSize);
        if (wPos == 0.0) {
            continue;
        }

        vec3 N  = normalDecode(imageLoad(NORMALS_GS, c).zw);
        float nd = max(dot(N, N0), 0.0);
        float wN = clamp((nd - FILTER_NORMAL_DOT_THRESHOLD) / max(1.0 - FILTER_NORMAL_DOT_THRESHOLD, 1e-4), 0.0, 1.0);
        if (wN <= 0.0) {
            continue;
        }

        float Rr = imageLoad(MATERIAL_RMXX, c).x;
        float wR = 1.0 - clamp(abs(Rr - R0) * invRoughnessThr, 0.0, 1.0);
        if (wR <= 0.0) {
            continue;
        }

        float wM = shadowMaskGate(pix, c);
        if (wM <= 0.0) {
            continue;
        }

        float w = wPos * wN * wR * wM;

    #ifdef SPECULAR_FIX
        float tight = mix(0.25, 1.0, R0);
    #else
        float tight = 1.0;
    #endif

        vec3 d = imageLoad(IN_RADIANCE, c).xyz;

        diffAcc += d * w * tight;
        wSum    += w * tight;
    }

    diffAcc /= max(wSum, 1e-5);

    imageStore(OUT_RADIANCE, pix, vec4(diffAcc, 1.0));
}
