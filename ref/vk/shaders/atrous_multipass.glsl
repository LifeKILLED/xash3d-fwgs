#include "debug.glsl"
#include "utils.glsl"
#include "color_spaces.glsl"
#include "brdf.h"
#include "denoiser_config.glsl"

#define GLSL
#include "ray_interop.h"
#undef GLSL

#define EPS 1e-6

//---------------------------------------------------------
// CONFIG
//---------------------------------------------------------
#ifndef ATROUS_STEP
#define ATROUS_STEP 1
#endif

//---------------------------------------------------------
// AGGRESSIVE DENOISE CONFIG
//---------------------------------------------------------
#define AGGRESSIVE_DENOISE 1         // 0 = off, 1 = on
#define VARIANCE_RELAX_EDGE 1.5      // relax edge stopping on noisy pixels
#define VARIANCE_FLATTEN_KERNEL 0.0  // keep Gaussian kernel shape (avoid boxy/square blur)

// Variance is stored in normalized form: var / (mean^2 + eps).
#define VARIANCE_MIN 0.0
#define VARIANCE_MAX 0.25
#define VARIANCE_RADIUS 2

#ifndef POSITION_PLANE_THRESHOLD
#define POSITION_PLANE_THRESHOLD 0.010
#endif

#ifndef POSITION_DIST2_THRESHOLD
#define POSITION_DIST2_THRESHOLD 0.0004
#endif

#ifndef ROUGHNESS_DIFF_THRESHOLD
#define ROUGHNESS_DIFF_THRESHOLD 0.12
#endif

#ifndef VARIANCE_REL_DIFF_THRESHOLD
#define VARIANCE_REL_DIFF_THRESHOLD 0.80
#endif

#ifndef ATROUS_BLACK_LUMA_THRESHOLD
#define ATROUS_BLACK_LUMA_THRESHOLD 1e-4
#endif

#ifndef ATROUS_ENABLE_VARIANCE_NEIGHBOR_GATE
#define ATROUS_ENABLE_VARIANCE_NEIGHBOR_GATE 0
#endif

#ifndef SHADING_NORMAL_DOT_THRESHOLD
#define SHADING_NORMAL_DOT_THRESHOLD 0.95
#endif

#ifndef ATROUS_MAX_STEP
#define ATROUS_MAX_STEP 1024
#endif

#ifndef ATROUS_VARIANCE_OUTPUT
#define ATROUS_VARIANCE_OUTPUT out_atrous_variance
#endif

#ifndef ATROUS_VARIANCE_SOURCE
#define ATROUS_VARIANCE_SOURCE atrous_variance
#endif

#ifndef ATROUS_MASK_GATE_ENABLE
#define ATROUS_MASK_GATE_ENABLE 0
#endif

#ifndef ATROUS_MASK_SOURCE
#define ATROUS_MASK_SOURCE diffuse_shadow_mask_debug
#endif

#ifndef ATROUS_MASK_SIGMA
#define ATROUS_MASK_SIGMA 0.08
#endif

#ifndef ATROUS_MASK_SOFT_EDGE
#define ATROUS_MASK_SOFT_EDGE 0.10
#endif

#ifndef ATROUS_MASK_FADE_RANGE
#define ATROUS_MASK_FADE_RANGE 0.10
#endif

#ifndef ATROUS_LUMA_GATE_ENABLE
#define ATROUS_LUMA_GATE_ENABLE 0
#endif

#ifndef ATROUS_LUMA_THR_MIN
#define ATROUS_LUMA_THR_MIN 0.05
#endif

#ifndef ATROUS_LUMA_THR_AT_HALF_VAR
#define ATROUS_LUMA_THR_AT_HALF_VAR 1.0
#endif

#ifndef ATROUS_LUMA_SOFTNESS_MULT
#define ATROUS_LUMA_SOFTNESS_MULT 2.0
#endif

#ifndef ATROUS_LUMA_STRICT_VAR_CUTOFF
#define ATROUS_LUMA_STRICT_VAR_CUTOFF 0.08
#endif

#ifndef ATROUS_LUMA_STRICT_THR
#define ATROUS_LUMA_STRICT_THR 0.02
#endif

#ifndef ATROUS_LUMA_FULL_MIX_VAR
#define ATROUS_LUMA_FULL_MIX_VAR 0.55
#endif

#ifndef ATROUS_LUMA_REL_EPS
#define ATROUS_LUMA_REL_EPS 0.03
#endif

#ifndef ATROUS_LUMA_MIN_WEIGHT
#define ATROUS_LUMA_MIN_WEIGHT 0.08
#endif

#ifndef ATROUS_LUMA_BLEND
#define ATROUS_LUMA_BLEND 0.35
#endif

#ifndef ATROUS_LUMA_MIN_WEIGHT_GLOBAL
#define ATROUS_LUMA_MIN_WEIGHT_GLOBAL 0.25
#endif

//---------------------------------------------------------
// KERNEL
//---------------------------------------------------------
const ivec2 KERNEL3[9] = ivec2[9](
    ivec2(-1,-1), ivec2(0,-1), ivec2(1,-1),
    ivec2(-1, 0), ivec2(0, 0), ivec2(1, 0),
    ivec2(-1, 1), ivec2(0, 1), ivec2(1, 1)
);

const float KERNEL3_W[9] = float[9](
    1, 2, 1,
    2, 4, 2,
    1, 2, 1
);

//---------------------------------------------------------
// IO
//---------------------------------------------------------
layout(local_size_x = 8, local_size_y = 8) in;

layout(set = 0, binding = 0, rgba16f) uniform readonly image2D IN_RADIANCE;

#ifdef VARIANCE_PASS
layout(set = 0, binding = 1, rgba16f) uniform writeonly image2D ATROUS_VARIANCE_OUTPUT;
#else // !VARIANCE_PASS
layout(set = 0, binding = 2, rgba16f) uniform writeonly image2D OUTPUT_RADIANCE;
layout(set = 0, binding = 3, rgba16f) uniform readonly image2D ATROUS_VARIANCE_SOURCE;
layout(set = 0, binding = 4, rgba32f) uniform readonly image2D POSITION_T;
layout(set = 0, binding = 5, rgba16f) uniform readonly image2D NORMALS_GS;
layout(set = 0, binding = 6, rgba8) uniform readonly image2D MATERIAL_RMXX;
#if ATROUS_MASK_GATE_ENABLE
layout(set = 0, binding = 8, rgba16f) uniform readonly image2D ATROUS_MASK_SOURCE;
#endif
#endif // !VARIANCE_PASS

layout(set = 0, binding = 7) uniform UBO { UniformBuffer ubo; } ubo;

//---------------------------------------------------------
// UTIL
//---------------------------------------------------------
float safeLum(vec3 c) { return max(luminance(c), 1e-4); }

float wNormalThreshold(vec3 a, vec3 b, float dotThreshold)
{
    float nd = max(dot(a, b), 0.0);
    return step(dotThreshold, nd);
}

float wPositionGate(vec3 d, vec3 geomNorm, float invCenterDist, float planeThreshold, float dist2Threshold)
{
    return positionEdgeStopWithThresholds(d, geomNorm, invCenterDist, planeThreshold, dist2Threshold);
}

float wRoughness(float a, float b, float relax)
{
    return step(abs(a - b), ROUGHNESS_DIFF_THRESHOLD * relax);
}

float wVariance(float a, float b)
{
    float d = abs(a - b) / max(max(a, b), 1e-4);
    return step(d, VARIANCE_REL_DIFF_THRESHOLD);
}

float wMask(ivec2 p, ivec2 q)
{
#if ATROUS_MASK_GATE_ENABLE && !defined(VARIANCE_PASS)
    float m0 = clamp(imageLoad(ATROUS_MASK_SOURCE, p).r, 0.0, 1.0);
    float m1 = clamp(imageLoad(ATROUS_MASK_SOURCE, q).r, 0.0, 1.0);
    float dm = abs(m1 - m0);
    float inner = max(ATROUS_MASK_SOFT_EDGE, 0.0);
    float outer = inner + max(ATROUS_MASK_FADE_RANGE, 1e-4);
    float w_plateau = 1.0 - smoothstep(inner, outer, dm);
    float w_exp = exp(-dm / max(ATROUS_MASK_SIGMA, 1e-5));
    return max(w_plateau, w_exp * 0.35);
#else
    return 1.0;
#endif
}

float varianceToLumaThreshold(float v)
{
    float nv = clamp(v, 0.0, 1.0);
    if (nv <= 0.5) {
        float t = nv * 2.0;
        return mix(ATROUS_LUMA_THR_MIN, ATROUS_LUMA_THR_AT_HALF_VAR, t);
    }

    float t = clamp((nv - 0.5) * 2.0, 0.0, 0.9999);
    return ATROUS_LUMA_THR_AT_HALF_VAR / max(1.0 - t, 1e-4);
}

float wLuminance(float lumCenter, float lumSample, float varianceCenter)
{
#if ATROUS_LUMA_GATE_ENABLE
    float nv = clamp(varianceCenter, 0.0, 1.0);
    float thr = varianceToLumaThreshold(varianceCenter);
    if (nv <= ATROUS_LUMA_STRICT_VAR_CUTOFF) {
        // Extra hard gate for stable pixels to preserve fine light/shadow detail.
        thr = min(thr, ATROUS_LUMA_STRICT_THR);
    }

    float lmax = max(max(lumCenter, lumSample), ATROUS_LUMA_REL_EPS);
    float d = abs(lumSample - lumCenter) / lmax;
    float soft = max(thr * ATROUS_LUMA_SOFTNESS_MULT, thr + 1e-4);
    float w = 1.0 - smoothstep(thr, soft, d);

    // For noisy centers, avoid hard rejection and let neighborhood denoise.
    float noisy_mix = smoothstep(ATROUS_LUMA_STRICT_VAR_CUTOFF, ATROUS_LUMA_FULL_MIX_VAR, nv);
    float min_w = ATROUS_LUMA_MIN_WEIGHT * noisy_mix;
    w = max(w, min_w);
    w = mix(w, 1.0, smoothstep(ATROUS_LUMA_FULL_MIX_VAR, 1.0, nv));

    // Make luminance gate a soft modulator instead of hard stop.
    w = max(w, ATROUS_LUMA_MIN_WEIGHT_GLOBAL);
    w = mix(1.0, w, ATROUS_LUMA_BLEND);
    return clamp(w, 0.0, 1.0);
#else
    return 1.0;
#endif
}

//---------------------------------------------------------
// VARIANCE PASS
//---------------------------------------------------------
#ifdef VARIANCE_PASS

void main()
{
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
    if (any(greaterThanEqual(p, res))) return;

    vec3 centerColor = imageLoad(IN_RADIANCE, p).rgb;
    if (luminance(max(centerColor, vec3(0.0))) <= ATROUS_BLACK_LUMA_THRESHOLD) {
        imageStore(ATROUS_VARIANCE_OUTPUT, p, vec4(1.0));
        return;
    }

    float m1 = 0.0;
    float m2 = 0.0;
    float w = 0.0;

    // 5x5 moments for more stable variance.
    // Single path for all invocations to avoid warp divergence on borders.
    for (int y = -VARIANCE_RADIUS; y <= VARIANCE_RADIUS; y++) {
        for (int x = -VARIANCE_RADIUS; x <= VARIANCE_RADIUS; x++) {
            ivec2 q = clamp(p + ivec2(x, y), ivec2(0), res - 1);
            float L = safeLum(imageLoad(IN_RADIANCE, q).rgb);
            m1 += L;
            m2 += L * L;
            w += 1.0;
        }
    }

    m1 /= w;
    m2 /= w;

    float variance = max(m2 - m1 * m1, 0.0);
    variance /= max(m1 * m1, 1e-3);
    variance = clamp(variance, 0.0, 1.0);

    imageStore(ATROUS_VARIANCE_OUTPUT, p, vec4(variance));
}

#else // !VARIANCE_PASS

//---------------------------------------------------------
// A-TROUS PASS
//---------------------------------------------------------

void main()
{
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
    if (any(greaterThanEqual(p, res))) return;

    vec3 centerC = imageLoad(IN_RADIANCE, p).rgb;

    if ((DENOISER_ENABLE_ATROUS == 0) || (ATROUS_STEP > ATROUS_MAX_STEP)) {
        imageStore(OUTPUT_RADIANCE, p, vec4(centerC, 1.0));
        return;
    }

    vec4 normalsEncoded = imageLoad(NORMALS_GS, p);
    vec3 geomNorm = normalDecode(normalsEncoded.xy);
    vec3 N0 = normalDecode(normalsEncoded.zw);
    vec3 P0 = imageLoad(POSITION_T, p).xyz;
    float R0 = imageLoad(MATERIAL_RMXX, p).x;
    float V0 = imageLoad(ATROUS_VARIANCE_SOURCE, p).r;
    float L0 = safeLum(centerC);

    float v = clamp((V0 - VARIANCE_MIN) / (VARIANCE_MAX - VARIANCE_MIN), 0.0, 1.0);

#if AGGRESSIVE_DENOISE
    float relax = 1.0 + v * VARIANCE_RELAX_EDGE;
    float kernelFlatten = clamp(v * VARIANCE_FLATTEN_KERNEL, 0.0, 1.0);
#else
    float relax = 1.0;
    float kernelFlatten = 0.0;
#endif
    int step = ATROUS_STEP;
    float stepScale = float(ATROUS_STEP);
    float invCenterDist = 1.0 / max(length(P0), 1.0);
    float planeThreshold = POSITION_PLANE_THRESHOLD * stepScale * relax;
    float dist2Threshold = POSITION_DIST2_THRESHOLD * stepScale * stepScale * relax * relax;

    vec3 sumC = vec3(0.0);
    float sumW = 0.0;

    for (int i = 0; i < 9; i++)
    {
        ivec2 q = clamp(p + KERNEL3[i] * step, ivec2(0), res - 1);

        vec3 N1 = normalDecode(imageLoad(NORMALS_GS, q).zw);
        float wnShading = wNormalThreshold(N0, N1, SHADING_NORMAL_DOT_THRESHOLD);
        if (wnShading == 0.0) {
            continue;
        }

        vec3 P1 = imageLoad(POSITION_T, q).xyz;
        float wPos = wPositionGate(P1 - P0, geomNorm, invCenterDist, planeThreshold, dist2Threshold);
        if (wPos == 0.0) {
            continue;
        }

        float R1 = imageLoad(MATERIAL_RMXX, q).x;
        float wR = wRoughness(R0, R1, relax);
        if (wR == 0.0) {
            continue;
        }

        float V1 = imageLoad(ATROUS_VARIANCE_SOURCE, q).r;
#if ATROUS_ENABLE_VARIANCE_NEIGHBOR_GATE
        float wV = wVariance(V0, V1);
        if (wV == 0.0) {
            continue;
        }
#else
        float wV = 1.0;
#endif

        float spatialW = mix(KERNEL3_W[i], 1.0, kernelFlatten);
        float wM = wMask(p, q);
        float w = spatialW * wnShading * wPos * wR * wV * wM;
        vec3 c = imageLoad(IN_RADIANCE, q).rgb;
        float L1 = safeLum(c);
        float wL = wLuminance(L0, L1, V0);
        if (wL == 0.0) {
            continue;
        }

        float wf = w * wL;
        sumC += c * wf;
        sumW += wf;
    }

    vec3 outC = (sumW > EPS) ? (sumC / sumW) : centerC;
    imageStore(OUTPUT_RADIANCE, p, vec4(outC, 1.0));
}

#endif // !VARIANCE_PASS
