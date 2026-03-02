#include "utils.glsl"
#include "brdf.h"

#define GLSL
#include "ray_interop.h"
#undef GLSL

#ifndef SPATIAL_RADIUS
#define SPATIAL_RADIUS 4.0
#endif

#ifndef SPATIAL_SAMPLES
#define SPATIAL_SAMPLES 16
#endif

#ifndef POSITION_PLANE_THRESHOLD
#define POSITION_PLANE_THRESHOLD 0.010
#endif

#ifndef POSITION_DIST2_THRESHOLD
#define POSITION_DIST2_THRESHOLD 0.0004
#endif

#ifndef ROUGHNESS_DIFF_THRESHOLD
#define ROUGHNESS_DIFF_THRESHOLD 0.12
#endif

#ifndef SHADING_NORMAL_DOT_THRESHOLD
#define SHADING_NORMAL_DOT_THRESHOLD 0.95
#endif

#ifndef SPATIAL_LIGHTDIR_DOT_THRESHOLD
#define SPATIAL_LIGHTDIR_DOT_THRESHOLD 0.92
#endif

#ifndef SPATIAL_CONFIDENCE_MIN
#define SPATIAL_CONFIDENCE_MIN 0.1
#endif

#ifndef SPATIAL_CONFIDENCE_SCALE
#define SPATIAL_CONFIDENCE_SCALE 1.0
#endif

#ifndef SPATIAL_FIREFLY_CLAMP
#define SPATIAL_FIREFLY_CLAMP 3.0
#endif

#ifndef SPATIAL_FIREFLY_BIAS
#define SPATIAL_FIREFLY_BIAS 0.01
#endif

layout(local_size_x = 8, local_size_y = 8) in;

layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D OUTPUT_DIRECT;
layout(set = 0, binding = 1, rgba16f) uniform readonly image2D INPUT_DIRECT;
layout(set = 0, binding = 2, rgba16f) uniform readonly image2D INPUT_LIGHTDIR;
layout(set = 0, binding = 3, rgba32f) uniform readonly image2D POSITION_T;
layout(set = 0, binding = 4, rgba16f) uniform readonly image2D NORMALS_GS;
layout(set = 0, binding = 5, rgba8) uniform readonly image2D MATERIAL_RMXX;
layout(set = 0, binding = 6) uniform UBO { UniformBuffer ubo; } ubo;

const vec3 POISSON[16] = vec3[](
    vec3( 0.000000000,  0.000000000, 0.128544338),
    vec3(-0.797630122,  0.623220526, 0.044399352),
    vec3(-0.282518518,  0.028872056, 0.111670655),
    vec3( 0.520033692,  0.179071984, 0.089961024),
    vec3( 0.857848520,  0.407217906, 0.037285218),
    vec3( 0.260589372, -0.961425346, 0.016540041),
    vec3(-0.197658008,  0.629159807, 0.063970742),
    vec3(-0.246892394, -0.927460750, 0.018080349),
    vec3(-0.099761954, -0.393746506, 0.098064610),
    vec3(-0.676933518, -0.107831894, 0.062739748),
    vec3( 0.289867508,  0.968136196, 0.014606041),
    vec3( 0.836644372, -0.218037444, 0.036161873),
    vec3(-0.499614432, -0.472562398, 0.061649521),
    vec3( 0.947539128, -0.810473276, 0.006911358),
    vec3( 0.310520506,  0.532561108, 0.060446005),
    vec3( 0.567593882, -0.598135228, 0.034960177)
);

float normalGate(vec3 a, vec3 b, float threshold) {
    return step(threshold, max(dot(a, b), 0.0));
}

float positionGate(vec3 d, vec3 geomNorm, float invCenterDist) {
    float nPlaneDist = abs(dot(d, geomNorm)) * invCenterDist;
    float nDist2 = dot(d, d) * (invCenterDist * invCenterDist);
    float wPlane = step(nPlaneDist, POSITION_PLANE_THRESHOLD);
    float wDist = step(nDist2, POSITION_DIST2_THRESHOLD);
    return max(wPlane, wDist);
}

void main()
{
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
    if (any(greaterThanEqual(p, res))) return;

    vec4 centerColor = imageLoad(INPUT_DIRECT, p);
    vec4 centerL = imageLoad(INPUT_LIGHTDIR, p);

    vec4 n0enc = imageLoad(NORMALS_GS, p);
    vec3 G0 = normalDecode(n0enc.xy);
    vec3 N0 = normalDecode(n0enc.zw);
    vec3 P0 = imageLoad(POSITION_T, p).xyz;
    float R0 = imageLoad(MATERIAL_RMXX, p).x;

    float invCenterDist = 1.0 / max(length(P0), 1.0);
    vec3 L0 = centerL.xyz;
    float l0Len2 = dot(L0, L0);
    float invL0Len = inversesqrt(max(l0Len2, 1e-8));
    vec3 L0n = L0 * invL0Len;
    float centerLum = luminance(centerColor.rgb);
    float fireflyMaxLum = centerLum * SPATIAL_FIREFLY_CLAMP + SPATIAL_FIREFLY_BIAS;

    vec3 sumC = centerColor.rgb;
    float sumA = centerColor.a;
    float sumW = 1.0;

    // Keep fixed Poisson orientation to avoid temporal shimmer from pattern rotation.
    vec2 axisX = vec2(SPATIAL_RADIUS, 0.0);
    vec2 axisY = vec2(-axisX.y, axisX.x);

    for (int i = 0; i < SPATIAL_SAMPLES; i++) {
        vec2 offset = POISSON[i].x * axisX + POISSON[i].y * axisY;
        ivec2 q = clamp(ivec2(vec2(p) + vec2(0.5) + offset), ivec2(0), res - 1);
        if (all(equal(q, p))) continue;

        vec3 N1 = normalDecode(imageLoad(NORMALS_GS, q).zw);
        float wn = normalGate(N0, N1, SHADING_NORMAL_DOT_THRESHOLD);
        if (wn == 0.0) continue;

        vec3 P1 = imageLoad(POSITION_T, q).xyz;
        float wp = positionGate(P1 - P0, G0, invCenterDist);
        if (wp == 0.0) continue;

        float R1 = imageLoad(MATERIAL_RMXX, q).x;
        float wr = step(abs(R0 - R1), ROUGHNESS_DIFF_THRESHOLD);
        if (wr == 0.0) continue;

        vec4 lq = imageLoad(INPUT_LIGHTDIR, q);
        vec3 L1 = lq.xyz;
        float wl = 1.0;
        float l1Len2 = dot(L1, L1);
        if (l0Len2 > 1e-6 && l1Len2 > 1e-6) {
            float invL1Len = inversesqrt(max(l1Len2, 1e-8));
            wl = step(SPATIAL_LIGHTDIR_DOT_THRESHOLD, dot(L0n, L1 * invL1Len));
        }
        if (wl == 0.0) continue;

        vec4 c = imageLoad(INPUT_DIRECT, q);
        float lum = luminance(c.rgb);
        if (lum > fireflyMaxLum && lum > 1e-6) {
            c.rgb *= fireflyMaxLum / lum;
        }
        float confW = max(SPATIAL_CONFIDENCE_MIN, c.a * SPATIAL_CONFIDENCE_SCALE);
        float spatialW = POISSON[i].z;
        float w = wn * wp * wr * wl * confW * spatialW;

        sumC += c.rgb * w;
        sumA += c.a * w;
        sumW += w;
    }

    vec3 outC = sumC / max(sumW, 1e-6);
    float outA = sumA / max(sumW, 1e-6);
    imageStore(OUTPUT_DIRECT, p, vec4(outC, outA));
}
