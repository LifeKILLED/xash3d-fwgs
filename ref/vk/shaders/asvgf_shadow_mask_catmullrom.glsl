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

#ifndef ASVGF_SHADOW_POSTFILTER_ENABLE
#define ASVGF_SHADOW_POSTFILTER_ENABLE 1
#endif

#ifndef ASVGF_SHADOW_ANISO_ENABLE
#define ASVGF_SHADOW_ANISO_ENABLE 1
#endif

#ifndef ASVGF_SHADOW_ANISO_MIN_SCALE
#define ASVGF_SHADOW_ANISO_MIN_SCALE 0.15
#endif

#ifndef ASVGF_SHADOW_ANISO_GRAZE_STRENGTH
#define ASVGF_SHADOW_ANISO_GRAZE_STRENGTH 1.5
#endif

#ifndef ASVGF_SHADOW_DIAGONAL_ENABLE
#define ASVGF_SHADOW_DIAGONAL_ENABLE DENOISER_ASVGF_SHADOW_CATMULL_DIAGONAL_ENABLE
#endif

#ifndef ASVGF_SHADOW_DETAIL_KEEP_BLEND
#define ASVGF_SHADOW_DETAIL_KEEP_BLEND 0.12
#endif

#ifndef ASVGF_SHADOW_MIN_FILTER_WEIGHT
#define ASVGF_SHADOW_MIN_FILTER_WEIGHT 0.22
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

float planeScreenAxisFootprint(
    ivec2 pix,
    ivec2 res,
    vec3 center_pos,
    vec3 plane_normal,
    vec3 cam_pos,
    ivec2 axis)
{
    ivec2 p1 = clamp(pix + axis, ivec2(0), res - 1);
    vec3 dir0 = reconstructWorldRayDirFromInvMatrices(pix, res, ubo.ubo.inv_proj, ubo.ubo.inv_view);
    vec3 dir1 = reconstructWorldRayDirFromInvMatrices(p1, res, ubo.ubo.inv_proj, ubo.ubo.inv_view);

    float plane_const = dot(plane_normal, center_pos - cam_pos);
    float d0 = dot(plane_normal, dir0);
    float d1 = dot(plane_normal, dir1);
    if (abs(d0) < 1e-6 || abs(d1) < 1e-6) return 1e6;

    float t0 = plane_const / d0;
    float t1 = plane_const / d1;
    if (t0 <= 0.0 || t1 <= 0.0) return 1e6;

    vec3 w0 = cam_pos + dir0 * t0;
    vec3 w1 = cam_pos + dir1 * t1;
    return max(length(w1 - w0), 1e-6);
}

float projectedAnisoRadiusScale(
    ivec2 pix,
    ivec2 res,
    vec3 center_pos,
    vec3 plane_normal,
    vec3 cam_pos)
{
#if ASVGF_SHADOW_ANISO_ENABLE
    ivec2 axis_a = ivec2(1, 0);
    ivec2 axis_b = ivec2(0, 1);
#if ASVGF_SHADOW_DIAGONAL_ENABLE
    axis_a = ivec2(1, 1);
    axis_b = ivec2(1, -1);
#endif
    float footprint_a = planeScreenAxisFootprint(pix, res, center_pos, plane_normal, cam_pos, axis_a);
    float footprint_b = planeScreenAxisFootprint(pix, res, center_pos, plane_normal, cam_pos, axis_b);
    float footprint_min = min(footprint_a, footprint_b);
#if FILTER_HORIZONTAL
    float footprint_pass = footprint_a;
#else
    float footprint_pass = footprint_b;
#endif

    float axis_scale = footprint_min / max(footprint_pass, 1e-6);
    axis_scale = clamp(axis_scale, ASVGF_SHADOW_ANISO_MIN_SCALE, 1.0);

    vec3 V = normalize(cam_pos - center_pos);
    float ndotv = clamp(abs(dot(plane_normal, V)), 0.0, 1.0);
    float grazing = 1.0 - ndotv;
    float grazing_mix = clamp(grazing * ASVGF_SHADOW_ANISO_GRAZE_STRENGTH, 0.0, 1.0);
    return mix(1.0, axis_scale, grazing_mix);
#else
    return 1.0;
#endif
}

void main() {
    ivec2 pix = ivec2(gl_GlobalInvocationID.xy);
    ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
    if (any(greaterThanEqual(pix, res))) return;

    vec3 center_mask = loadMaskSafe(pix, res);
#if !ASVGF_SHADOW_POSTFILTER_ENABLE
    imageStore(OUTPUT_MASK, pix, vec4(center_mask, 1.0));
    return;
#endif
    vec3 p0 = imageLoad(position_t, pix).xyz;
    vec3 g0 = normalDecode(imageLoad(normals_gs, pix).xy);
    float inv_center_dist = 1.0 / max(length(p0), 1.0);
    vec3 cam_pos = (ubo.ubo.inv_view * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
    float world_texel_size = estimateWorldTexelSizeFromCenter(
        pix, res, cam_pos, p0, ubo.ubo.inv_proj, ubo.ubo.inv_view, DENOISER_POSITION_TEXEL_SIZE_MARGIN);
    float aniso_scale = projectedAnisoRadiusScale(pix, res, p0, g0, cam_pos);
    int effective_radius_i = clamp(
        int(floor(float(DENOISER_ASVGF_SHADOW_CATMULL_RADIUS) * aniso_scale + 0.5)),
        1,
        DENOISER_ASVGF_SHADOW_CATMULL_RADIUS);
    float effective_radius = float(effective_radius_i);

#if FILTER_HORIZONTAL
    ivec2 axis = ivec2(1, 0);
#else
    ivec2 axis = ivec2(0, 1);
#endif
#if ASVGF_SHADOW_DIAGONAL_ENABLE
#if FILTER_HORIZONTAL
    axis = ivec2(1, 1);
#else
    axis = ivec2(1, -1);
#endif
#endif

    vec3 sum = vec3(0.0);
    float wsum = 0.0;

    for (int d = -DENOISER_ASVGF_SHADOW_CATMULL_RADIUS; d <= DENOISER_ASVGF_SHADOW_CATMULL_RADIUS; ++d) {
        if (abs(d) > effective_radius_i) continue;
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

        float x = (abs(float(d)) / max(effective_radius, 1.0)) * 2.0;
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
        float smooth_detail_keep = mix(1.0, detail_keep, ASVGF_SHADOW_DETAIL_KEEP_BLEND);
        w *= max(smooth_detail_keep, ASVGF_SHADOW_MIN_FILTER_WEIGHT);

        vec3 sample_mask = s1;
        sum += sample_mask * w;
        wsum += w;
    }

    vec3 out_mask = (wsum > 1e-6) ? (sum / wsum) : center_mask;
    imageStore(OUTPUT_MASK, pix, vec4(out_mask, 1.0));
}
