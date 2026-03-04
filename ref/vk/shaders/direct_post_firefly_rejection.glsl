#include "utils.glsl"

#define GLSL
#include "ray_interop.h"
#undef GLSL

#ifndef FIREFLY_REJECTION_ENABLE
#define FIREFLY_REJECTION_ENABLE 1
#endif

#ifndef FIREFLY_RATIO_SOFT_START
#define FIREFLY_RATIO_SOFT_START 1.6
#endif

#ifndef FIREFLY_RATIO_SOFT_END
#define FIREFLY_RATIO_SOFT_END 3.5
#endif

#ifndef FIREFLY_LUMA_SOFT_START
#define FIREFLY_LUMA_SOFT_START 1.5
#endif

#ifndef FIREFLY_LUMA_SOFT_END
#define FIREFLY_LUMA_SOFT_END 2.5
#endif

#ifndef FIREFLY_DROP_BRIGHTEST_MIN_LUMA
#define FIREFLY_DROP_BRIGHTEST_MIN_LUMA 2.0
#endif

#ifndef FIREFLY_CLAMP_MIN_ABS_LUMA
#define FIREFLY_CLAMP_MIN_ABS_LUMA 1.0
#endif

#ifndef FIREFLY_DROPED_NEIGHBOR_SCALE
#define FIREFLY_DROPED_NEIGHBOR_SCALE 0.25
#endif

#ifndef FIREFLY_MIN_REF_FROM_CENTER
#define FIREFLY_MIN_REF_FROM_CENTER 0.0
#endif

#ifndef FIREFLY_MAX_RATIO
#define FIREFLY_MAX_RATIO 1e9
#endif

layout(local_size_x = 8, local_size_y = 8) in;

layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D OUTPUT_DIRECT;
layout(set = 0, binding = 1, rgba16f) uniform readonly image2D INPUT_DIRECT;
layout(set = 0, binding = 2) uniform UBO { UniformBuffer ubo; } ubo;

float luma(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

float neighborLumaWithoutBrightest(ivec2 p, ivec2 res, float center_luma) {
    float sum_luma = 0.0;
    float sum_w = 0.0;
    float max_luma = -1.0;
    float max_w = 0.0;
    for (int oy = -1; oy <= 1; ++oy) {
        for (int ox = -1; ox <= 1; ++ox) {
            if (ox == 0 && oy == 0) {
                continue;
            }
            ivec2 q = p + ivec2(ox, oy);
            if (any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, res))) {
                continue;
            }
            vec3 c = max(imageLoad(INPUT_DIRECT, q).rgb, vec3(0.0));
            const float l = luma(c);
            const float w = 1.0;
            sum_luma += l * w;
            sum_w += w;
            if (l > max_luma) {
                max_luma = l;
                max_w = w;
            }
        }
    }

    if (sum_w <= 0.0) {
        return center_luma;
    }

    if (max_luma >= FIREFLY_DROP_BRIGHTEST_MIN_LUMA) {
        // Scale brightest neighbor weight (and its contribution) instead of dimming all.
        const float brightest_scale = clamp(FIREFLY_DROPED_NEIGHBOR_SCALE, 0.0, 1.0);
        const float removed_weight = max_w * (1.0 - brightest_scale);
        const float filtered_sum =
            sum_luma - max(max_luma, 0.0) * removed_weight;
        const float filtered_w = sum_w - removed_weight;
        if (filtered_w > 0.0) {
            return max(filtered_sum / filtered_w, 0.0);
        }
    }
    return max(sum_luma / sum_w, 0.0);
}

void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
    if (any(greaterThanEqual(p, res))) {
        return;
    }

    vec4 center = imageLoad(INPUT_DIRECT, p);

#if !FIREFLY_REJECTION_ENABLE
    imageStore(OUTPUT_DIRECT, p, center);
    return;
#endif

    vec3 center_rgb = max(center.rgb, vec3(0.0));
    float center_luma = luma(center_rgb);
    if (center_luma < FIREFLY_CLAMP_MIN_ABS_LUMA) {
        imageStore(OUTPUT_DIRECT, p, vec4(center_rgb, center.a));
        return;
    }
    float neigh_ref = max(neighborLumaWithoutBrightest(p, res, center_luma), 1e-6);
    neigh_ref = max(neigh_ref, center_luma * max(FIREFLY_MIN_REF_FROM_CENTER, 0.0));

    float ratio = center_luma / neigh_ref;
    ratio = min(ratio, max(FIREFLY_MAX_RATIO, 1.0));
    float start = max(FIREFLY_RATIO_SOFT_START, 1.0);
    float end = max(FIREFLY_RATIO_SOFT_END, start + 1e-4);

    // Very aggressive in bright ranges, but softly fades out in deep dark regions.
    float t_ratio = smoothstep(start, end, ratio);
    float t_luma = smoothstep(
        max(FIREFLY_LUMA_SOFT_START, 0.0),
        max(FIREFLY_LUMA_SOFT_END, FIREFLY_LUMA_SOFT_START + 1e-4),
        center_luma
    );
    float t = t_ratio * t_luma;
    float target_luma = mix(center_luma, neigh_ref, t);

    float scale = (center_luma > 1e-6) ? (target_luma / center_luma) : 1.0;
    vec3 out_rgb = center_rgb * scale;
    imageStore(OUTPUT_DIRECT, p, vec4(out_rgb, center.a));
}
