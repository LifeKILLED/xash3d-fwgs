#include "utils.glsl"

#define GLSL
#include "ray_interop.h"
#undef GLSL

#ifndef SPATIAL_RADIUS
#define SPATIAL_RADIUS 1
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

layout(local_size_x = 8, local_size_y = 8) in;

layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D OUTPUT_DIRECT;
layout(set = 0, binding = 1, rgba16f) uniform readonly image2D INPUT_DIRECT;
layout(set = 0, binding = 2, rgba16f) uniform readonly image2D INPUT_LIGHTDIR;
layout(set = 0, binding = 3, rgba32f) uniform readonly image2D POSITION_T;
layout(set = 0, binding = 4, rgba16f) uniform readonly image2D NORMALS_GS;
layout(set = 0, binding = 5, rgba8) uniform readonly image2D MATERIAL_RMXX;
layout(set = 0, binding = 6) uniform UBO { UniformBuffer ubo; } ubo;

float normalGate(vec3 a, vec3 b, float threshold) {
    return step(threshold, max(dot(a, b), 0.0));
}

float positionGate(vec3 d, vec3 geomNorm, float invCenterDist) {
    float nPlaneDist = abs(dot(d, geomNorm)) * invCenterDist;
    float nDist2 = dot(d, d) * (invCenterDist * invCenterDist);
    return step(nPlaneDist, POSITION_PLANE_THRESHOLD) * step(nDist2, POSITION_DIST2_THRESHOLD);
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

    vec3 sumC = centerColor.rgb;
    float sumA = centerColor.a;
    float sumW = 1.0;

    for (int y = -SPATIAL_RADIUS; y <= SPATIAL_RADIUS; y++) {
        for (int x = -SPATIAL_RADIUS; x <= SPATIAL_RADIUS; x++) {
            if (x == 0 && y == 0) continue;

            ivec2 q = clamp(p + ivec2(x, y), ivec2(0), res - 1);

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
                wl = step(SPATIAL_LIGHTDIR_DOT_THRESHOLD, dot(normalize(L0), normalize(L1)));
            }
            if (wl == 0.0) continue;

            vec4 c = imageLoad(INPUT_DIRECT, q);

            float confW = max(SPATIAL_CONFIDENCE_MIN, c.a * SPATIAL_CONFIDENCE_SCALE);
            float spatialW = (x == 0 || y == 0) ? 2.0 : 1.0;
            float w = wn * wp * wr * wl * confW * spatialW;

            sumC += c.rgb * w;
            sumA += c.a * w;
            sumW += w;
        }
    }

    vec3 outC = sumC / max(sumW, 1e-6);
    float outA = sumA / max(sumW, 1e-6);
    imageStore(OUTPUT_DIRECT, p, vec4(outC, outA));
}
