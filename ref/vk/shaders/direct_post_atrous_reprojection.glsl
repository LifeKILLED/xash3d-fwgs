#include "utils.glsl"
#include "denoiser_config.glsl"

#define GLSL
#include "ray_interop.h"
#undef GLSL

#ifndef POST_ATROUS_REPROJECTION_ENABLE
#define POST_ATROUS_REPROJECTION_ENABLE 1
#endif

#ifndef POST_ATROUS_HISTORY_RELATIVE_THRESHOLD
#define POST_ATROUS_HISTORY_RELATIVE_THRESHOLD 0.15
#endif

#ifndef POST_ATROUS_HISTORY_ABSOLUTE_THRESHOLD
#define POST_ATROUS_HISTORY_ABSOLUTE_THRESHOLD 0.03
#endif

#ifndef POST_ATROUS_TREND_MIX
#define POST_ATROUS_TREND_MIX 0.6
#endif

#ifndef POST_ATROUS_HISTORY_SOFT_ZONE
#define POST_ATROUS_HISTORY_SOFT_ZONE 0.5
#endif

#ifndef POST_ATROUS_MAX_HISTORY
#define POST_ATROUS_MAX_HISTORY 12.0
#endif

#ifndef POST_ATROUS_HISTORY_STRICTNESS
#define POST_ATROUS_HISTORY_STRICTNESS 2.5
#endif

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D POST_ATROUS_OUTPUT_FILTERED;
layout(set = 0, binding = 1, rgba16f) uniform readonly image2D POST_ATROUS_INPUT_FILTERED;
layout(set = 0, binding = 2, rgba16f) uniform readonly image2D reprojection_uv;
layout(set = 0, binding = 3, rgba32f) uniform readonly image2D POST_ATROUS_PREV_TEMPORAL_LUMA;
layout(set = 0, binding = 4, rgba32f) uniform writeonly image2D POST_ATROUS_OUTPUT_TEMPORAL_LUMA;
layout(set = 0, binding = 5, rgba16f) uniform readonly image2D POST_ATROUS_PREV_TEMPORAL_RADIANCE;
layout(set = 0, binding = 6, rgba16f) uniform writeonly image2D POST_ATROUS_OUTPUT_TEMPORAL_RADIANCE;
layout(set = 0, binding = 7) uniform UBO { UniformBuffer ubo; } ubo;

float postArousLuma(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

float postArousPackLumaPair(float luma_int, float luma_frac) {
    float i = floor(max(luma_int, 0.0) * 1000.0 + 0.5);
    float f = clamp(max(luma_frac, 0.0) * 0.1, 0.0, 0.999999);
    return i + f;
}

vec2 postArousUnpackLumaPair(float packed) {
    float p = max(packed, 0.0);
    float luma_int = floor(p) * 0.001;
    float luma_frac = fract(p) * 10.0;
    return vec2(luma_int, luma_frac);
}

bool postArousInBounds(ivec2 p, ivec2 res) {
    return all(greaterThanEqual(p, ivec2(0))) && all(lessThan(p, res));
}

void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
    if (!postArousInBounds(p, res)) return;

    vec3 curr = max(imageLoad(POST_ATROUS_INPUT_FILTERED, p).rgb, vec3(0.0));
    float curr_luma = postArousLuma(curr);

    if (POST_ATROUS_REPROJECTION_ENABLE == 0 || DENOISER_ENABLE_REPROJECTION == 0) {
        imageStore(POST_ATROUS_OUTPUT_FILTERED, p, vec4(curr, 1.0));
        imageStore(POST_ATROUS_OUTPUT_TEMPORAL_LUMA, p, vec4(curr_luma));
        imageStore(POST_ATROUS_OUTPUT_TEMPORAL_RADIANCE, p, vec4(curr, 1.0));
        return;
    }

    vec2 prev_uv = imageLoad(reprojection_uv, p).xy;
    bool uv_valid = all(greaterThanEqual(prev_uv, vec2(0.0))) && all(lessThan(prev_uv, vec2(res)));
    ivec2 q = ivec2(floor(prev_uv + vec2(0.5)));

    vec3 out_c = curr;
    vec4 out_luma_hist = vec4(postArousPackLumaPair(curr_luma, curr_luma));
    vec4 out_radiance_hist = vec4(curr, 1.0);

    if (uv_valid && postArousInBounds(q, res)) {
        vec4 packed_hist_luma = max(imageLoad(POST_ATROUS_PREV_TEMPORAL_LUMA, q), vec4(0.0));
        vec4 hist_radiance = max(imageLoad(POST_ATROUS_PREV_TEMPORAL_RADIANCE, q), vec4(0.0));
        float prev_hist_len = clamp(hist_radiance.a, 1.0, POST_ATROUS_MAX_HISTORY);
        float history_t = (POST_ATROUS_MAX_HISTORY > 1.0) ? clamp((prev_hist_len - 1.0) / (POST_ATROUS_MAX_HISTORY - 1.0), 0.0, 1.0) : 1.0;
        float strictness = mix(1.0, POST_ATROUS_HISTORY_STRICTNESS, history_t);

        float hist_luma[8];
        vec2 p0 = postArousUnpackLumaPair(packed_hist_luma.x);
        vec2 p1 = postArousUnpackLumaPair(packed_hist_luma.y);
        vec2 p2 = postArousUnpackLumaPair(packed_hist_luma.z);
        vec2 p3 = postArousUnpackLumaPair(packed_hist_luma.w);
        hist_luma[0] = p0.x;
        hist_luma[1] = p0.y;
        hist_luma[2] = p1.x;
        hist_luma[3] = p1.y;
        hist_luma[4] = p2.x;
        hist_luma[5] = p2.y;
        hist_luma[6] = p3.x;
        hist_luma[7] = p3.y;

        float hmin = hist_luma[0];
        float hmax = hist_luma[0];
        float hsum = 0.0;
        for (int i = 0; i < 8; ++i) {
            hmin = min(hmin, hist_luma[i]);
            hmax = max(hmax, hist_luma[i]);
            hsum += hist_luma[i];
        }
        float hcenter_avg = hsum * (1.0 / 8.0);

        const float xm = 3.5;
        const float xvar = 42.0;
        float cov = 0.0;
        for (int i = 0; i < 8; ++i) {
            cov += (float(i) - xm) * (hist_luma[i] - hcenter_avg);
        }
        float slope = cov / xvar;
        float intercept = hcenter_avg - slope * xm;
        float trend_curr = max(intercept + slope * (-1.0), 0.0);

        float max_dev = 0.0;
        for (int i = 0; i < 8; ++i) {
            float trend_i = intercept + slope * float(i);
            max_dev = max(max_dev, abs(hist_luma[i] - trend_i));
        }

        float base_band = max(POST_ATROUS_HISTORY_ABSOLUTE_THRESHOLD, (hmax - hmin) * POST_ATROUS_HISTORY_RELATIVE_THRESHOLD);
        float band = max(max(base_band / max(strictness, 1.0), max_dev), 1e-5);
        float deviation = abs(curr_luma - trend_curr);
        float accept_curr = smoothstep(band, band * 2.0, deviation);

        float trend_0 = intercept + slope * 0.0;
        float dev_curr_signed = curr_luma - trend_curr;
        float dev_0_signed = hist_luma[0] - trend_0;
        float strong_dev = band * 1.35;
        bool trend_break =
            (abs(dev_curr_signed) >= strong_dev) &&
            (abs(dev_0_signed) >= strong_dev) &&
            ((dev_curr_signed * dev_0_signed) > 0.0);
        if (trend_break) {
            accept_curr = 1.0;
        }

        float hcenter = mix(hcenter_avg, trend_curr, clamp(POST_ATROUS_TREND_MIX, 0.0, 1.0));
        float target_luma = mix(hcenter, curr_luma, accept_curr);

        float cand_hist_len = min(prev_hist_len + 1.0, POST_ATROUS_MAX_HISTORY);
        float history_keep = 1.0 - smoothstep(band, band * 2.0, deviation);
        if (trend_break) {
            history_keep = 0.0;
        }
        float out_hist_len = cand_hist_len * history_keep;
        float alpha_hist = 1.0 / max(out_hist_len, 1.0);
        vec3 filtered_curr = (curr_luma > 1e-6) ? (curr * (target_luma / curr_luma)) : vec3(target_luma);
        filtered_curr = max(filtered_curr, vec3(0.0));
        out_c = mix(hist_radiance.rgb, filtered_curr, mix(alpha_hist, 1.0, accept_curr));
        out_c = max(out_c, vec3(0.0));

        float mixed_luma = postArousLuma(out_c);
        float hist_next[8];
        hist_next[0] = mixed_luma;
        hist_next[1] = hist_luma[0];
        hist_next[2] = hist_luma[1];
        hist_next[3] = hist_luma[2];
        hist_next[4] = hist_luma[3];
        hist_next[5] = hist_luma[4];
        hist_next[6] = hist_luma[5];
        hist_next[7] = hist_luma[6];

        out_luma_hist = vec4(
            postArousPackLumaPair(hist_next[0], hist_next[1]),
            postArousPackLumaPair(hist_next[2], hist_next[3]),
            postArousPackLumaPair(hist_next[4], hist_next[5]),
            postArousPackLumaPair(hist_next[6], hist_next[7]));
        out_radiance_hist = vec4(out_c, out_hist_len);
    }

    imageStore(POST_ATROUS_OUTPUT_FILTERED, p, vec4(out_c, 1.0));
    imageStore(POST_ATROUS_OUTPUT_TEMPORAL_LUMA, p, out_luma_hist);
    imageStore(POST_ATROUS_OUTPUT_TEMPORAL_RADIANCE, p, out_radiance_hist);
}
