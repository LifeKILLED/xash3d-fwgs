#include "debug.glsl"
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
#define AGGRESSIVE_DENOISE 1         // 0 = off, 1 = on
#define VARIANCE_RELAX_EDGE 1.5      // relax edge stopping on noisy pixels
#define VARIANCE_FLATTEN_KERNEL 0.75 // flatten spatial kernel on noisy pixels

// Variance is stored in normalized form: var / (mean^2 + eps).
#define VARIANCE_MIN 0.0
#define VARIANCE_MAX 0.25

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
layout(set = 0, binding = 1, rgba16f) uniform writeonly image2D out_atrous_variance;
#else // !VARIANCE_PASS
layout(set = 0, binding = 2, rgba16f) uniform writeonly image2D OUTPUT_RADIANCE;
layout(set = 0, binding = 3, rgba16f) uniform readonly image2D atrous_variance;
layout(set = 0, binding = 4, rgba32f) uniform readonly image2D POSITION_T;
layout(set = 0, binding = 5, rgba16f) uniform readonly image2D NORMALS_GS;
layout(set = 0, binding = 6, rgba8) uniform readonly image2D MATERIAL_RMXX;
#endif // !VARIANCE_PASS

layout(set = 0, binding = 7) uniform UBO { UniformBuffer ubo; } ubo;

//---------------------------------------------------------
// UTIL
//---------------------------------------------------------
float safeLum(vec3 c) { return max(luminance(c), 1e-4); }

float wNormal(vec3 a, vec3 b, float relax)
{
    float nd = max(dot(a, b), 0.0);
    float threshold = mix(0.2, 0.05, clamp(relax - 1.0, 0.0, 1.0));
    return smoothstep(threshold, 1.0, nd);
}

float wPosition(vec3 centerPos, vec3 samplePos, vec3 geomNorm, float stepScale, float relax)
{
    // Scale-invariant metric: robust when engine units are not meters.
    vec3 d = samplePos - centerPos;
    float centerDist = max(length(centerPos), 1.0);

    // Distance from sample point to plane that passes through centerPos with geomNorm normal.
    float planeDist = abs(dot(d, geomNorm));
    float nPlaneDist = planeDist / centerDist;
    float sigmaPlane = max(0.0015 * stepScale * relax, 1e-4);
    float wPlane = exp(-nPlaneDist / sigmaPlane);

    // Keep base distance gating for depth discontinuities, but allow plane-consistent samples.
    float nEuclidDist = length(d) / centerDist;
    float sigmaEuclid = max(0.0025 * stepScale * relax, 1e-4);
    float wEuclid = exp(-nEuclidDist / sigmaEuclid);

    return max(wPlane, wEuclid);
}

float wRoughness(float a, float b, float relax)
{
    float d = abs(a - b);
    return 1.0 / (1.0 + d * (12.0 / relax));
}

float wVariance(float a, float b)
{
    float d = abs(a - b) / max(max(a, b), 1e-4);
    return 1.0 / (1.0 + d * 6.0);
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

    float m1 = 0.0;
    float m2 = 0.0;
    float w = 0.0;

    // Keep variance pass compact and cache-friendly: fixed 3x3 footprint.
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
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

    imageStore(out_atrous_variance, p, vec4(variance));
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

    vec4 normalsEncoded = imageLoad(NORMALS_GS, p);
    vec3 geomNorm = normalDecode(normalsEncoded.xy);
    vec3 N0 = normalDecode(normalsEncoded.zw);
    vec3 P0 = imageLoad(POSITION_T, p).xyz;
    float R0 = imageLoad(MATERIAL_RMXX, p).x;
    float V0 = imageLoad(atrous_variance, p).r;

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

    vec3 sumC = vec3(0.0);
    float sumW = 0.0;

    for (int i = 0; i < 9; i++)
    {
        ivec2 q = clamp(p + KERNEL3[i] * step, ivec2(0), res - 1);

        vec3 c = imageLoad(IN_RADIANCE, q).rgb;
        vec3 N1 = normalDecode(imageLoad(NORMALS_GS, q).zw);
        vec3 P1 = imageLoad(POSITION_T, q).xyz;
        float R1 = imageLoad(MATERIAL_RMXX, q).x;
        float V1 = imageLoad(atrous_variance, q).r;

        float spatialW = mix(KERNEL3_W[i], 1.0, kernelFlatten);
        float w =
              spatialW
            * wNormal(N0, N1, relax)
            * wPosition(P0, P1, geomNorm, stepScale, relax)
            * wRoughness(R0, R1, relax)
            * wVariance(V0, V1);

        sumC += c * w;
        sumW += w;
    }

    vec3 outC = (sumW > EPS) ? (sumC / sumW) : centerC;
    imageStore(OUTPUT_RADIANCE, p, vec4(outC, 1.0));
}

#endif // !VARIANCE_PASS
