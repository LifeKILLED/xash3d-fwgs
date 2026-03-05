#include "denoiser_config.glsl"
#include "utils.glsl"

#define GLSL
#include "ray_interop.h"
#undef GLSL

#ifndef INPUT_MASK
#define INPUT_MASK asvgf_shadow_mask_normalized
#endif

#ifndef OUTPUT_MASK
#define OUTPUT_MASK out_asvgf_shadow_mask_normalized
#endif

#ifndef FILTER_HORIZONTAL
#define FILTER_HORIZONTAL 1
#endif

layout(local_size_x = 8, local_size_y = 8) in;

layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D OUTPUT_MASK;
layout(set = 0, binding = 1, rgba16f) uniform readonly image2D INPUT_MASK;
layout(set = 0, binding = 2, rgba32f) uniform readonly image2D position_t;
layout(set = 0, binding = 3, rgba16f) uniform readonly image2D normals_gs;
layout(set = 0, binding = 4) uniform UBO { UniformBuffer ubo; } ubo;

#ifndef ASVGF_SHADOW_BLACK_FIREFLY_BRIGHT_MIN
#define ASVGF_SHADOW_BLACK_FIREFLY_BRIGHT_MIN 0.7
#endif

#ifndef ASVGF_SHADOW_BLACK_FIREFLY_DROP_THRESHOLD
#define ASVGF_SHADOW_BLACK_FIREFLY_DROP_THRESHOLD 0.35
#endif

float catmullRomWeight(float x) {
    float a = abs(x);
    if (a < 1.0) {
        return 1.5 * a * a * a - 2.5 * a * a + 1.0;
    }
    if (a < 2.0) {
        return -0.5 * a * a * a + 2.5 * a * a - 4.0 * a + 2.0;
    }
    return 0.0;
}

float luminance709(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

vec3 loadMaskSafe(ivec2 p, ivec2 res) {
    ivec2 q = clamp(p, ivec2(0), res - 1);
    vec3 m = imageLoad(INPUT_MASK, q).rgb;
    bvec3 bad = bvec3(isnan(m.x) || isinf(m.x), isnan(m.y) || isinf(m.y), isnan(m.z) || isinf(m.z));
    return vec3(bad.x ? 1.0 : m.x, bad.y ? 1.0 : m.y, bad.z ? 1.0 : m.z);
}

void main() {
    ivec2 pix = ivec2(gl_GlobalInvocationID.xy);
    ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
    if (any(greaterThanEqual(pix, res))) return;

    vec3 center_mask = loadMaskSafe(pix, res);
    vec3 p0 = imageLoad(position_t, pix).xyz;
    vec3 g0 = normalDecode(imageLoad(normals_gs, pix).xy);
    float inv_center_dist = 1.0 / max(length(p0), 1.0);
    vec3 cam_pos = (ubo.ubo.inv_view * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
    float world_texel_size = estimateWorldTexelSizeFromCenter(
        pix, res, cam_pos, p0, ubo.ubo.inv_proj, ubo.ubo.inv_view, DENOISER_POSITION_TEXEL_SIZE_MARGIN);

#if FILTER_HORIZONTAL
    ivec2 axis = ivec2(1, 0);
#else
    ivec2 axis = ivec2(0, 1);
#endif

    // Black-firefly fix: if center is an isolated dark outlier in bright neighborhood, pull it to neighbor mean.
    vec3 nbr_sum = vec3(0.0);
    float nbr_count = 0.0;
    const ivec2 cross4[4] = ivec2[](ivec2(1, 0), ivec2(-1, 0), ivec2(0, 1), ivec2(0, -1));
    for (int i = 0; i < 4; ++i) {
        ivec2 qf = pix + cross4[i];
        if (any(lessThan(qf, ivec2(0))) || any(greaterThanEqual(qf, res))) continue;

        vec3 pf = imageLoad(position_t, qf).xyz;
        float wf = positionEdgeStopWithWorldTexel(
            pf - p0,
            g0,
            inv_center_dist,
            DENOISER_POSITION_PLANE_THRESHOLD,
            world_texel_size
        );
        if (wf == 0.0) continue;

        nbr_sum += loadMaskSafe(qf, res);
        nbr_count += 1.0;
    }
    if (nbr_count >= 3.0) {
        vec3 nbr_mean = nbr_sum / nbr_count;
        bvec3 dark_outlier = lessThan(
            center_mask,
            nbr_mean - vec3(ASVGF_SHADOW_BLACK_FIREFLY_DROP_THRESHOLD)
        );
        bvec3 bright_context = greaterThan(
            nbr_mean,
            vec3(ASVGF_SHADOW_BLACK_FIREFLY_BRIGHT_MIN)
        );
        bvec3 fix = bvec3(
            dark_outlier.x && bright_context.x,
            dark_outlier.y && bright_context.y,
            dark_outlier.z && bright_context.z
        );
        center_mask = vec3(fix.x ? nbr_mean.x : center_mask.x, fix.y ? nbr_mean.y : center_mask.y, fix.z ? nbr_mean.z : center_mask.z);
    }

    vec3 sum = vec3(0.0);
    float wsum = 0.0;
    const float radius = float(DENOISER_ASVGF_SHADOW_CATMULL_RADIUS);

    for (int d = -DENOISER_ASVGF_SHADOW_CATMULL_RADIUS; d <= DENOISER_ASVGF_SHADOW_CATMULL_RADIUS; ++d) {
        ivec2 q = pix + axis * d;
        if (any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, res))) continue;

        vec3 p1 = imageLoad(position_t, q).xyz;
        float wp = positionEdgeStopWithWorldTexel(
            p1 - p0,
            g0,
            inv_center_dist,
            DENOISER_POSITION_PLANE_THRESHOLD,
            world_texel_size
        );
        if (wp == 0.0) continue;

        float x = (abs(float(d)) / max(radius, 1.0)) * 2.0;
        float w = catmullRomWeight(x);
        if (w <= 0.0) continue;

        // Detail preserve: use minimal local gradient from 3 adjacent gradients around q.
        vec3 s0 = loadMaskSafe(q - axis, res);
        vec3 s1 = loadMaskSafe(q, res);
        vec3 s2 = loadMaskSafe(q + axis, res);
        vec3 s3 = loadMaskSafe(q + axis * 2, res);
        float g01 = luminance709(abs(s1 - s0));
        float g12 = luminance709(abs(s2 - s1));
        float g23 = luminance709(abs(s3 - s2));
        float min_grad = min(g01, min(g12, g23));
        float detail_keep = 1.0 - clamp(min_grad * DENOISER_ASVGF_SHADOW_CATMULL_DETAIL_PRESERVE, 0.0, 1.0);
        w *= detail_keep;

        vec3 sample_mask = s1;
        sum += sample_mask * w;
        wsum += w;
    }

    vec3 out_mask = (wsum > 1e-6) ? (sum / wsum) : center_mask;
    imageStore(OUTPUT_MASK, pix, vec4(out_mask, 1.0));
}
