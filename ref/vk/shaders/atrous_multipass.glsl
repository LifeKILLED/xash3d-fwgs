#include "debug.glsl"
#include "denoiser_config.glsl"
#include "utils.glsl"
#include "color_spaces.glsl"
#include "brdf.h"

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
#ifndef AGGRESSIVE_DENOISE
#define AGGRESSIVE_DENOISE 0
#endif
#ifndef VARIANCE_RELAX_EDGE
#define VARIANCE_RELAX_EDGE 0.0
#endif
#ifndef VARIANCE_FLATTEN_KERNEL
#define VARIANCE_FLATTEN_KERNEL 0.0
#endif

// Variance is stored in normalized form: var / (mean^2 + eps).
#define VARIANCE_MIN 0.0
#define VARIANCE_MAX 0.25
#define VARIANCE_RADIUS 2

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

#ifndef GEOMETRY_NORMAL_DOT_THRESHOLD
#define GEOMETRY_NORMAL_DOT_THRESHOLD 0.75
#endif

#ifndef ATROUS_FLAT_GEOM_DOT_THRESHOLD
#define ATROUS_FLAT_GEOM_DOT_THRESHOLD 0.985
#endif

#ifndef ATROUS_SHADING_GATE_FLAT_RELAX
#define ATROUS_SHADING_GATE_FLAT_RELAX 0.6
#endif

#ifndef ATROUS_NORMAL_GATE_SOFTNESS
#define ATROUS_NORMAL_GATE_SOFTNESS 0.05
#endif

#ifndef ATROUS_NORMAL_GATE_MIN_WEIGHT
#define ATROUS_NORMAL_GATE_MIN_WEIGHT 0.0
#endif

#ifndef ATROUS_MAX_STEP
#define ATROUS_MAX_STEP 1024
#endif

#ifndef ATROUS_POSITION_STEP_GROWTH
#define ATROUS_POSITION_STEP_GROWTH 0.35
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
#define ATROUS_MASK_SOURCE diffuse_shadow_mask
#endif

#ifndef ATROUS_MASK_CHANNEL
#define ATROUS_MASK_CHANNEL 0
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

#ifndef ATROUS_MASK_DIFF_MIN
#define ATROUS_MASK_DIFF_MIN 0.01
#endif

#ifndef ATROUS_MASK_DIFF_MAX
#define ATROUS_MASK_DIFF_MAX 0.30
#endif

#ifndef ATROUS_MASK_GATE_STRENGTH
#define ATROUS_MASK_GATE_STRENGTH 1.0
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
#ifndef ATROUS_USE_HONEST_KERNEL
#define ATROUS_USE_HONEST_KERNEL 1
#endif

#ifndef ATROUS_KERNEL_RADIUS
#if ATROUS_USE_HONEST_KERNEL
#define ATROUS_KERNEL_RADIUS 2
#else
#define ATROUS_KERNEL_RADIUS 1
#endif
#endif

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

const float KERNEL5_1D[5] = float[5](1, 4, 6, 4, 1);

float spatialKernelWeight(ivec2 k, float kernelFlatten)
{
#if ATROUS_USE_HONEST_KERNEL && ATROUS_KERNEL_RADIUS == 2
    float wx = KERNEL5_1D[k.x + 2];
    float wy = KERNEL5_1D[k.y + 2];
    float base = wx * wy;
#elif ATROUS_KERNEL_RADIUS == 1
    int idx = (k.y + 1) * 3 + (k.x + 1);
    float base = KERNEL3_W[idx];
#else
    float dist2 = dot(vec2(k), vec2(k));
    float base = 1.0 / (1.0 + 0.35 * dist2);
#endif
    return mix(base, 1.0, kernelFlatten);
}

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

float wNormalThreshold(vec3 a, vec3 b, float dotThreshold, float relax)
{
    float nd = max(dot(a, b), 0.0);
    float soft = ATROUS_NORMAL_GATE_SOFTNESS * max(relax, 1.0);
    float t0 = clamp(dotThreshold - soft, 0.0, 1.0);
    float t1 = clamp(dotThreshold + soft * 0.5, t0 + 1e-4, 1.0);
    float w = smoothstep(t0, t1, nd);
    return mix(ATROUS_NORMAL_GATE_MIN_WEIGHT, 1.0, w);
}

float wPositionGate(vec3 d, vec3 geomNorm, float invCenterDist, float planeThreshold, float worldTexelSize)
{
    return positionEdgeStopWithWorldTexel(d, geomNorm, invCenterDist, planeThreshold, worldTexelSize);
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
    vec4 s0 = imageLoad(ATROUS_MASK_SOURCE, p);
    vec4 s1 = imageLoad(ATROUS_MASK_SOURCE, q);
    float m0 = s0[ATROUS_MASK_CHANNEL];
    float m1 = s1[ATROUS_MASK_CHANNEL];
    float dm = abs(m1 - m0);
    float t = (dm - ATROUS_MASK_DIFF_MIN) / max(ATROUS_MASK_DIFF_MAX - ATROUS_MASK_DIFF_MIN, 1e-4);
    float raw_w = 1.0 - clamp(t, 0.0, 1.0);
    return mix(1.0, raw_w, clamp(ATROUS_MASK_GATE_STRENGTH, 0.0, 1.0));
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
    float thr = mix(ATROUS_LUMA_THR_MIN, ATROUS_LUMA_THR_AT_HALF_VAR, nv);
    float thr_soft = max(thr * ATROUS_LUMA_SOFTNESS_MULT, thr + 1e-4);
    float lmax = max(max(lumCenter, lumSample), ATROUS_LUMA_REL_EPS);
    float d = abs(lumSample - lumCenter) / lmax;
    float t = (d - thr) / max(thr_soft - thr, 1e-4);
    float w = 1.0 - clamp(t, 0.0, 1.0);
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

    if (DENOISER_ENABLE_ATROUS == 0) {
        imageStore(ATROUS_VARIANCE_OUTPUT, p, vec4(1.0));
        return;
    }

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
    int stepWidth = ATROUS_STEP;
    float stepScale = float(ATROUS_STEP);
    float gateStepScale = mix(1.0, stepScale, clamp(ATROUS_POSITION_STEP_GROWTH, 0.0, 1.0));
    float kernelRadiusScale = float(max(ATROUS_KERNEL_RADIUS, 1));
    float maxSampleRadiusScale = kernelRadiusScale * max(stepScale, 1.0);
    float invCenterDist = 1.0 / max(length(P0), 1.0);
    vec3 camPos = (ubo.ubo.inv_view * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
    float worldTexelSize = estimateWorldTexelSizeFromCenter(
        p, res, camPos, P0, ubo.ubo.inv_proj, ubo.ubo.inv_view, DENOISER_POSITION_TEXEL_SIZE_MARGIN * gateStepScale);
    float planeThreshold = DENOISER_POSITION_PLANE_THRESHOLD * gateStepScale * relax;
    float worldTexelThreshold = worldTexelSize * maxSampleRadiusScale * relax;

    vec3 sumC = vec3(0.0);
    float sumW = 0.0;

    for (int oy = -ATROUS_KERNEL_RADIUS; oy <= ATROUS_KERNEL_RADIUS; oy++) {
        for (int ox = -ATROUS_KERNEL_RADIUS; ox <= ATROUS_KERNEL_RADIUS; ox++) {
        ivec2 k = ivec2(ox, oy);
        ivec2 q = clamp(p + k * stepWidth, ivec2(0), res - 1);

        vec4 normalsQ = imageLoad(NORMALS_GS, q);
        vec3 G1 = normalDecode(normalsQ.xy);
        float wnGeom = wNormalThreshold(geomNorm, G1, GEOMETRY_NORMAL_DOT_THRESHOLD, 0.0);
        if (wnGeom <= 1e-4) {
            continue;
        }
        vec3 N1 = normalDecode(normalsQ.zw);
        float wnShadingRaw = wNormalThreshold(N0, N1, SHADING_NORMAL_DOT_THRESHOLD, relax);
        float flatSurface = step(ATROUS_FLAT_GEOM_DOT_THRESHOLD, max(dot(geomNorm, G1), 0.0));
        float wnShading = mix(wnShadingRaw, 1.0, flatSurface * clamp(ATROUS_SHADING_GATE_FLAT_RELAX, 0.0, 1.0));
        if (wnShading <= 1e-4) {
            continue;
        }

        vec3 P1 = imageLoad(POSITION_T, q).xyz;
        float wPos = wPositionGate(P1 - P0, geomNorm, invCenterDist, planeThreshold, worldTexelThreshold);
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

        float spatialW = spatialKernelWeight(k, kernelFlatten);
        float wM = wMask(p, q);
        float w = spatialW * wnShading * wnGeom * wPos * wR * wV * wM;
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
    }

    vec3 outC = (sumW > EPS) ? (sumC / sumW) : centerC;
#if DENOISER_DEBUG_ATROUS_OUTPUT_SHADOW_MASK
#if ATROUS_MASK_GATE_ENABLE
    vec4 mask_src = imageLoad(ATROUS_MASK_SOURCE, p);
    float mask_v = mask_src[ATROUS_MASK_CHANNEL];
    outC = vec3(mask_v);
#else
    outC = vec3(1.0);
#endif
#endif
    imageStore(OUTPUT_RADIANCE, p, vec4(outC, 1.0));
}

#endif // !VARIANCE_PASS
