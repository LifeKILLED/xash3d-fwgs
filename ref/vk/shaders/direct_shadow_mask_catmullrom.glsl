#include "utils.glsl"
#include "denoiser_config.glsl"

#define GLSL
#include "ray_interop.h"
#undef GLSL

#ifndef SHADOW_MASK_FILTER_ENABLE
#define SHADOW_MASK_FILTER_ENABLE DENOISER_ENABLE_SHADOW_MASK_CATMULL_ROM
#endif

#ifndef SHADOW_MASK_FILTER_RADIUS
#define SHADOW_MASK_FILTER_RADIUS DENOISER_SHADOW_MASK_CATMULL_RADIUS
#endif

#ifndef SHADOW_MASK_ACTIVE_THRESHOLD
#define SHADOW_MASK_ACTIVE_THRESHOLD 0.02
#endif

#ifndef SHADOW_MASK_DENSITY_BOOST_MIN
#define SHADOW_MASK_DENSITY_BOOST_MIN 0.85
#endif

#ifndef SHADOW_MASK_DENSITY_BOOST_MAX
#define SHADOW_MASK_DENSITY_BOOST_MAX 1.35
#endif

#ifndef SHADOW_MASK_SPARSE_WIDE_SIGMA_SCALE
#define SHADOW_MASK_SPARSE_WIDE_SIGMA_SCALE 2.2
#endif

#ifndef SHADOW_MASK_SPARSE_WIDE_BLEND
#define SHADOW_MASK_SPARSE_WIDE_BLEND 0.95
#endif

#ifndef SHADOW_MASK_SPARSE_WIDE_POWER
#define SHADOW_MASK_SPARSE_WIDE_POWER 1.6
#endif

#ifndef SHADOW_MASK_DETAIL_PRESERVE_STRENGTH
#define SHADOW_MASK_DETAIL_PRESERVE_STRENGTH 0.90
#endif

#ifndef SHADOW_MASK_DETAIL_CENTER_PULL
#define SHADOW_MASK_DETAIL_CENTER_PULL 0.55
#endif

#ifndef SHADOW_MASK_DETAIL_BRIGHT_START
#define SHADOW_MASK_DETAIL_BRIGHT_START 0.45
#endif

#ifndef SHADOW_MASK_DETAIL_BRIGHT_END
#define SHADOW_MASK_DETAIL_BRIGHT_END 0.80
#endif

#ifndef SHADOW_MASK_DETAIL_DENSE_START
#define SHADOW_MASK_DETAIL_DENSE_START 0.45
#endif

#ifndef SHADOW_MASK_DETAIL_DENSE_END
#define SHADOW_MASK_DETAIL_DENSE_END 0.75
#endif

#ifndef SHADOW_MASK_POSITION_PLANE_THRESHOLD
#define SHADOW_MASK_POSITION_PLANE_THRESHOLD 0.010
#endif

#ifndef SHADOW_MASK_POSITION_DIST2_THRESHOLD
#define SHADOW_MASK_POSITION_DIST2_THRESHOLD 0.0004
#endif

#ifndef POSITION_T
#define POSITION_T position_t
#endif

#ifndef NORMALS_GS
#define NORMALS_GS normals_gs
#endif

layout(local_size_x = 8, local_size_y = 8) in;

layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D OUTPUT_MASK;
layout(set = 0, binding = 1, rgba16f) uniform readonly image2D INPUT_MASK;
layout(set = 0, binding = 2, rgba32f) uniform readonly image2D POSITION_T;
layout(set = 0, binding = 3, rgba16f) uniform readonly image2D NORMALS_GS;
layout(set = 0, binding = 4) uniform UBO { UniformBuffer ubo; } ubo;

float position_gate(vec3 d, vec3 geom_norm, float inv_center_dist) {
    float n_plane_dist = abs(dot(d, geom_norm)) * inv_center_dist;
    float n_dist2 = dot(d, d) * (inv_center_dist * inv_center_dist);
    float w_plane = step(n_plane_dist, SHADOW_MASK_POSITION_PLANE_THRESHOLD);
    float w_dist = step(n_dist2, SHADOW_MASK_POSITION_DIST2_THRESHOLD);
    return max(w_plane, w_dist);
}

// Fast positive kernel approximation (no exp): 1 / (1 + x^2 * k).
float spatial_weight(float x, float inv_sigma2) {
    return 1.0 / (1.0 + x * x * inv_sigma2);
}

void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
    if (any(greaterThanEqual(p, res))) return;

    vec4 src = imageLoad(INPUT_MASK, p);

    if (SHADOW_MASK_FILTER_ENABLE == 0) {
        imageStore(OUTPUT_MASK, p, src);
        return;
    }

    // Keep the mask pass fast and stable.
    const int maxRadius = 16;
    int radius = clamp(SHADOW_MASK_FILTER_RADIUS, 1, maxRadius);

    vec3 p0 = imageLoad(POSITION_T, p).xyz;
    vec3 g0 = normalDecode(imageLoad(NORMALS_GS, p).xy);
    float inv_center_dist = 1.0 / max(length(p0), 1.0);

    // radius/2 gives wide-but-cheap kernel for sparse inpainting-like propagation.
    float sigma = max(float(radius) * 0.5, 1.0);
    float inv_sigma2 = 1.0 / (sigma * sigma);

    float sum = 0.0;
    float wsum = 0.0;
    float sum_wide = 0.0;
    float wsum_wide = 0.0;
    float occ = 0.0;
    float occ_wsum = 0.0;

    for (int o = -maxRadius; o <= maxRadius; o++) {
        if (abs(o) > radius) continue;

        ivec2 q = p;
#ifdef HORIZONTAL
        q.x += o;
#else
        q.y += o;
#endif
        if (any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, res))) continue;

        vec3 p1 = imageLoad(POSITION_T, q).xyz;
        if (position_gate(p1 - p0, g0, inv_center_dist) == 0.0) continue;

        float of = float(o);
        float w = spatial_weight(of, inv_sigma2);
        float wide_sigma = sigma * SHADOW_MASK_SPARSE_WIDE_SIGMA_SCALE;
        float w_wide = spatial_weight(of, 1.0 / max(wide_sigma * wide_sigma, 1e-6));

        float v = clamp(imageLoad(INPUT_MASK, q).r, 0.0, 1.0);
        sum += w * v;
        wsum += w;
        sum_wide += w_wide * v;
        wsum_wide += w_wide;
        occ += w * step(SHADOW_MASK_ACTIVE_THRESHOLD, v);
        occ_wsum += w;
    }

    float base = (wsum > 1e-6) ? (sum / wsum) : clamp(src.r, 0.0, 1.0);
    float base_wide = (wsum_wide > 1e-6) ? (sum_wide / wsum_wide) : base;
    float density = clamp(occ / max(occ_wsum, 1e-6), 0.0, 1.0);
    float sparse = 1.0 - density;
    float sparse_mix = SHADOW_MASK_SPARSE_WIDE_BLEND * pow(clamp(sparse, 0.0, 1.0), SHADOW_MASK_SPARSE_WIDE_POWER);
    float center_mask = clamp(src.r, 0.0, 1.0);
    float bright_factor = smoothstep(SHADOW_MASK_DETAIL_BRIGHT_START, SHADOW_MASK_DETAIL_BRIGHT_END, center_mask);
    float dense_factor = smoothstep(SHADOW_MASK_DETAIL_DENSE_START, SHADOW_MASK_DETAIL_DENSE_END, density);
    float detail_keep = clamp(bright_factor * dense_factor, 0.0, 1.0);

    sparse_mix *= (1.0 - SHADOW_MASK_DETAIL_PRESERVE_STRENGTH * detail_keep);
    float filtered = mix(base, base_wide, clamp(sparse_mix, 0.0, 1.0));
    filtered = mix(filtered, center_mask, SHADOW_MASK_DETAIL_CENTER_PULL * detail_keep);
    float boost = mix(SHADOW_MASK_DENSITY_BOOST_MIN, SHADOW_MASK_DENSITY_BOOST_MAX, density);
    float out_mask = clamp(filtered * boost, 0.0, 1.0);

    // Same payload format for both passes: R=mask, G=density, B=reserved, A=1.
    imageStore(OUTPUT_MASK, p, vec4(out_mask, density, 0.0, 1.0));
}
