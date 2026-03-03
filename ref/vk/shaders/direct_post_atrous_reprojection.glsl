#include "utils.glsl"
#include "denoiser_config.glsl"

#define GLSL
#include "ray_interop.h"
#undef GLSL

#ifndef POST_ATROUS_REPROJECTION_ENABLE
#define POST_ATROUS_REPROJECTION_ENABLE 1
#endif

#ifndef POST_ATROUS_LUMA_RESET_THRESHOLD
#define POST_ATROUS_LUMA_RESET_THRESHOLD 0.05
#endif

#ifndef POST_ATROUS_LUMA_RESET_FADE_END
#define POST_ATROUS_LUMA_RESET_FADE_END 0.20
#endif

#ifndef POST_ATROUS_MAX_HISTORY
#define POST_ATROUS_MAX_HISTORY 4.0
#endif

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D POST_ATROUS_OUTPUT_FILTERED;
layout(set = 0, binding = 1, rgba16f) uniform readonly image2D POST_ATROUS_INPUT_FILTERED;
layout(set = 0, binding = 2, rgba16f) uniform readonly image2D reprojection_uv;
layout(set = 0, binding = 3, rgba32f) uniform readonly image2D POST_ATROUS_PREV_TEMPORAL;
layout(set = 0, binding = 4, rgba32f) uniform writeonly image2D POST_ATROUS_OUTPUT_TEMPORAL;
layout(set = 0, binding = 5) uniform UBO { UniformBuffer ubo; } ubo;

float postArousLuma(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

bool postArousInBounds(ivec2 p, ivec2 res) {
    return all(greaterThanEqual(p, ivec2(0))) && all(lessThan(p, res));
}

void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
    if (!postArousInBounds(p, res)) return;

    vec3 curr = max(imageLoad(POST_ATROUS_INPUT_FILTERED, p).rgb, vec3(0.0));

    if (POST_ATROUS_REPROJECTION_ENABLE == 0 || DENOISER_ENABLE_REPROJECTION == 0) {
        imageStore(POST_ATROUS_OUTPUT_FILTERED, p, vec4(curr, 1.0));
        imageStore(POST_ATROUS_OUTPUT_TEMPORAL, p, vec4(curr, 1.0));
        return;
    }

    vec2 prev_uv = imageLoad(reprojection_uv, p).xy;
    ivec2 q = ivec2(floor(prev_uv + vec2(0.5)));

    vec3 out_c = curr;
    float out_hist = 1.0;

    if (postArousInBounds(q, res)) {
        vec4 prev = imageLoad(POST_ATROUS_PREV_TEMPORAL, q);
        vec3 prev_c = max(prev.rgb, vec3(0.0));
        float prev_hist = max(prev.a, 1.0);

        float dl = abs(postArousLuma(curr) - postArousLuma(prev_c));
        float reset_blend = smoothstep(
            POST_ATROUS_LUMA_RESET_THRESHOLD,
            max(POST_ATROUS_LUMA_RESET_FADE_END, POST_ATROUS_LUMA_RESET_THRESHOLD + 1e-4),
            dl);
        float keep = 1.0 - reset_blend;

        float cand_hist = min(prev_hist + 1.0, POST_ATROUS_MAX_HISTORY);
        out_hist = mix(1.0, cand_hist, keep);

        float alpha_hist = 1.0 / max(cand_hist, 1.0);
        vec3 accum = mix(prev_c, curr, alpha_hist);
        out_c = mix(curr, accum, keep);
    }

    imageStore(POST_ATROUS_OUTPUT_FILTERED, p, vec4(out_c, 1.0));
    imageStore(POST_ATROUS_OUTPUT_TEMPORAL, p, vec4(out_c, out_hist));
}
