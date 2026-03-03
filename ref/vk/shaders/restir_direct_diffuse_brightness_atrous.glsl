#include "denoiser_config.glsl"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba32f) uniform writeonly image2D OUTPUT_MASK;
layout(set = 0, binding = 1, rgba32f) uniform readonly image2D INPUT_MASK;
layout(set = 0, binding = 2) uniform UBO { UniformBuffer ubo; } ubo;

const ivec2 KERNEL3[9] = ivec2[9](
    ivec2(-1,-1), ivec2(0,-1), ivec2(1,-1),
    ivec2(-1, 0), ivec2(0, 0), ivec2(1, 0),
    ivec2(-1, 1), ivec2(0, 1), ivec2(1, 1)
);

const float KERNEL3_W[9] = float[9](
    1.0, 2.0, 1.0,
    2.0, 4.0, 2.0,
    1.0, 2.0, 1.0
);

void main() {
    const ivec2 pix = ivec2(gl_GlobalInvocationID.xy);
    const ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
    if (any(greaterThanEqual(pix, res))) {
        return;
    }

#if !DENOISER_STABILIZE_DIFFUSE_RESERVOIRS
    imageStore(OUTPUT_MASK, pix, imageLoad(INPUT_MASK, pix));
    return;
#endif

    if (ATROUS_STEP > DENOISER_STABILIZE_DIFFUSE_RESERVOIRS_KERNEL) {
        imageStore(OUTPUT_MASK, pix, imageLoad(INPUT_MASK, pix));
        return;
    }

    float sum = 0.0;
    float weight_sum = 0.0;
    for (int i = 0; i < 9; ++i) {
        const ivec2 q = clamp(pix + KERNEL3[i] * ATROUS_STEP, ivec2(0), res - ivec2(1));
        const float w = KERNEL3_W[i];
        const float v = imageLoad(INPUT_MASK, q).r;
        sum += v * w;
        weight_sum += w;
    }

    const float filtered = (weight_sum > 0.0) ? (sum / weight_sum) : imageLoad(INPUT_MASK, pix).r;
    imageStore(OUTPUT_MASK, pix, vec4(filtered, 0.0, 0.0, 0.0));
}
