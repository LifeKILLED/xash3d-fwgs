#include "utils.glsl"
#include "brdf.h"
#include "denoiser_config.glsl"

#define GLSL
#include "ray_interop.h"
#undef GLSL

#ifndef FILTER_RADIUS
#define FILTER_RADIUS 5
#endif

#ifndef REQUIRED_MATCHES
#define REQUIRED_MATCHES 4
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

layout(local_size_x = 8, local_size_y = 8) in;

layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D OUTPUT_SHADOW;
layout(set = 0, binding = 1, rgba16f) uniform readonly image2D INPUT_SOURCE;
layout(set = 0, binding = 2, rgba16f) uniform readonly image2D LIGHT_ID_SOURCE;
layout(set = 0, binding = 3, rgba32f) uniform readonly image2D POSITION_T;
layout(set = 0, binding = 4, rgba16f) uniform readonly image2D NORMALS_GS;
layout(set = 0, binding = 5) uniform UBO { UniformBuffer ubo; } ubo;

float positionGate(vec3 d, vec3 geomNorm, float invCenterDist) {
    float nPlaneDist = abs(dot(d, geomNorm)) * invCenterDist;
    float nDist2 = dot(d, d) * (invCenterDist * invCenterDist);
    float wPlane = step(nPlaneDist, POSITION_PLANE_THRESHOLD);
    float wDist = step(nDist2, POSITION_DIST2_THRESHOLD);
    return max(wPlane, wDist);
}

float shadowFromRadiance(vec3 r) {
    return (luminance(r) < 0.0) ? -1.0 : 1.0;
}

void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
    if (any(greaterThanEqual(p, res))) return;

    vec3 P0 = imageLoad(POSITION_T, p).xyz;
    vec3 G0 = normalDecode(imageLoad(NORMALS_GS, p).xy);
    float invCenterDist = 1.0 / max(length(P0), 1.0);

    float lightId0 = imageLoad(LIGHT_ID_SOURCE, p).w;
    float centerShadow = shadowFromRadiance(imageLoad(INPUT_SOURCE, p).rgb);

    if (DENOISER_ENABLE_SHADOWS_FILTERING == 0) {
        imageStore(OUTPUT_SHADOW, p, vec4(centerShadow, centerShadow, centerShadow, 1.0));
        return;
    }

    float sum = centerShadow;
    float count = 1.0;
    int matches = 0;

    for (int side = -1; side <= 1; side += 2) {
        for (int s = 1; s <= FILTER_RADIUS; s++) {
            ivec2 q = p;
#ifdef HORIZONTAL
            q.x += side * s;
#else
            q.y += side * s;
#endif
            if (any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, res))) continue;

            float lightId1 = imageLoad(LIGHT_ID_SOURCE, q).w;
            if (abs(lightId1 - lightId0) > 0.01) continue;

            vec3 P1 = imageLoad(POSITION_T, q).xyz;
            if (positionGate(P1 - P0, G0, invCenterDist) == 0.0) continue;

            float sh = shadowFromRadiance(imageLoad(INPUT_SOURCE, q).rgb);
            sum += sh;
            count += 1.0;
            matches++;
            if (matches >= REQUIRED_MATCHES) break;
        }
        if (matches >= REQUIRED_MATCHES) break;
    }

    float outShadow = clamp(sum / max(count, 1.0), -1.0, 1.0);
    imageStore(OUTPUT_SHADOW, p, vec4(outShadow, outShadow, outShadow, 1.0));
}
