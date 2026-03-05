#include "denoiser_config.glsl"
#include "utils.glsl"

#define STABILIZE_RESERVOIRS_KERNEL 1

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D OUTPUT_MASK;
layout(set = 0, binding = 1, rgba16f) uniform readonly image2D INPUT_MASK;
layout(set = 0, binding = 2) uniform UBO { UniformBuffer ubo; } ubo;
layout(set = 0, binding = 3, rgba32f) uniform readonly image2D position_t;
layout(set = 0, binding = 4, rgba16f) uniform readonly image2D normals_gs;

void main() {
    const ivec2 pix = ivec2(gl_GlobalInvocationID.xy);
    const ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
    if (any(greaterThanEqual(pix, res))) {
        return;
    }

#if !DENOISER_ENABLE_STABILIZE_RESERVOIRS
    imageStore(OUTPUT_MASK, pix, imageLoad(INPUT_MASK, pix));
    return;
#endif

    if (ATROUS_STEP > STABILIZE_RESERVOIRS_KERNEL) {
        imageStore(OUTPUT_MASK, pix, imageLoad(INPUT_MASK, pix));
        return;
    }

    vec2 sum = vec2(0.0);
    float weight_sum = 0.0;
    const float center_w = 0.25;
    const float neighbor_w = 1.0;
    const vec3 p0 = imageLoad(position_t, pix).xyz;
    const vec3 g0 = normalDecode(imageLoad(normals_gs, pix).xy);
    const float inv_center_dist = 1.0 / max(length(p0), 1.0);
    const vec3 cam_pos = (ubo.ubo.inv_view * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
    const float world_texel_size = estimateWorldTexelSizeFromCenter(
        pix, res, cam_pos, p0, ubo.ubo.inv_proj, ubo.ubo.inv_view, DENOISER_POSITION_TEXEL_SIZE_MARGIN);
    for (int oy = -STABILIZE_RESERVOIRS_KERNEL; oy <= STABILIZE_RESERVOIRS_KERNEL; ++oy) {
        for (int ox = -STABILIZE_RESERVOIRS_KERNEL; ox <= STABILIZE_RESERVOIRS_KERNEL; ++ox) {
            const ivec2 q = pix + ivec2(ox, oy) * ATROUS_STEP;
            if (any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, res))) {
                continue;
            }

            const bool is_center = (ox == 0 && oy == 0);
            const float w = is_center ? center_w : neighbor_w;
            if (!is_center) {
                const vec3 p1 = imageLoad(position_t, q).xyz;
                const float wp = positionEdgeStopWithWorldTexel(
                    p1 - p0,
                    g0,
                    inv_center_dist,
                    DENOISER_POSITION_PLANE_THRESHOLD,
                    world_texel_size);
                if (wp == 0.0) {
                    continue;
                }
            }
            const vec2 v = imageLoad(INPUT_MASK, q).rg;
            sum += v * w;
            weight_sum += w;
        }
    }

    const vec2 center = imageLoad(INPUT_MASK, pix).rg;
    const vec2 filtered = (weight_sum > 0.0) ? (sum / weight_sum) : center;
    imageStore(OUTPUT_MASK, pix, vec4(filtered, 0.0, 0.0));
}
