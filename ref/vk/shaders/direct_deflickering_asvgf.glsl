#include "utils.glsl"
#include "denoiser_config.glsl"

#define GLSL
#include "ray_interop.h"
#undef GLSL

#ifndef DEFLICKER_ASVGF_ENABLE
#define DEFLICKER_ASVGF_ENABLE 1
#endif

#ifndef DEFLICKER_ASVGF_HISTORY_RELATIVE_THRESHOLD
#define DEFLICKER_ASVGF_HISTORY_RELATIVE_THRESHOLD 0.15
#endif

#ifndef DEFLICKER_ASVGF_HISTORY_ABSOLUTE_THRESHOLD
#define DEFLICKER_ASVGF_HISTORY_ABSOLUTE_THRESHOLD 0.03
#endif

#ifndef DEFLICKER_ASVGF_TREND_MIX
#define DEFLICKER_ASVGF_TREND_MIX 0.6
#endif

#ifndef DEFLICKER_ASVGF_HISTORY_SOFT_ZONE
#define DEFLICKER_ASVGF_HISTORY_SOFT_ZONE 0.5
#endif

#ifndef DEFLICKER_ASVGF_MAX_HISTORY
#define DEFLICKER_ASVGF_MAX_HISTORY 12.0
#endif

#ifndef DEFLICKER_ASVGF_HISTORY_STRICTNESS
#define DEFLICKER_ASVGF_HISTORY_STRICTNESS 2.5
#endif

#ifndef DEFLICKER_ASVGF_CLAMP_SIGMA
#define DEFLICKER_ASVGF_CLAMP_SIGMA 1.5
#endif

#ifndef DEFLICKER_ASVGF_CLAMP_EXPAND
#define DEFLICKER_ASVGF_CLAMP_EXPAND 0.025
#endif

#ifndef DEFLICKER_ASVGF_ANTILAG_STRENGTH
#define DEFLICKER_ASVGF_ANTILAG_STRENGTH 0.75
#endif

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D DEFLICKER_ASVGF_OUTPUT_FILTERED;
layout(set = 0, binding = 1, rgba16f) uniform readonly image2D DEFLICKER_ASVGF_INPUT_FILTERED;
layout(set = 0, binding = 2, rgba16f) uniform readonly image2D reprojection_uv;
layout(set = 0, binding = 3, rgba32f) uniform readonly image2D DEFLICKER_ASVGF_PREV_TEMPORAL_LUMA;
layout(set = 0, binding = 4, rgba32f) uniform writeonly image2D DEFLICKER_ASVGF_OUTPUT_TEMPORAL_LUMA;
layout(set = 0, binding = 5, rgba16f) uniform readonly image2D DEFLICKER_ASVGF_PREV_TEMPORAL_RADIANCE;
layout(set = 0, binding = 6, rgba16f) uniform writeonly image2D DEFLICKER_ASVGF_OUTPUT_TEMPORAL_RADIANCE;
layout(set = 0, binding = 7) uniform UBO { UniformBuffer ubo; } ubo;

float deflickerAsvgfLuma(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

float deflickerAsvgfPackLumaPair(float luma_int, float luma_frac) {
    float i = floor(max(luma_int, 0.0) * 1000.0 + 0.5);
    float f = clamp(max(luma_frac, 0.0) * 0.1, 0.0, 0.999999);
    return i + f;
}

vec2 deflickerAsvgfUnpackLumaPair(float packed) {
    float p = max(packed, 0.0);
    float luma_int = floor(p) * 0.001;
    float luma_frac = fract(p) * 10.0;
    return vec2(luma_int, luma_frac);
}

bool deflickerAsvgfInBounds(ivec2 p, ivec2 res) {
    return all(greaterThanEqual(p, ivec2(0))) && all(lessThan(p, res));
}

void deflickerAsvgfNeighborhoodStats(ivec2 p, ivec2 res, out float mean_luma, out float sigma_luma, out float min_luma, out float max_luma) {
    float sum = 0.0;
    float sum_sq = 0.0;
    min_luma = 1e20;
    max_luma = 0.0;
    int n = 0;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            ivec2 tap = clamp(p + ivec2(dx, dy), ivec2(0), res - ivec2(1));
            float l = deflickerAsvgfLuma(max(imageLoad(DEFLICKER_ASVGF_INPUT_FILTERED, tap).rgb, vec3(0.0)));
            sum += l;
            sum_sq += l * l;
            min_luma = min(min_luma, l);
            max_luma = max(max_luma, l);
            n++;
        }
    }
    mean_luma = sum / float(n);
    float var = max(sum_sq / float(n) - mean_luma * mean_luma, 0.0);
    sigma_luma = sqrt(var);
}

void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
    if (!deflickerAsvgfInBounds(p, res)) return;

    vec3 curr = max(imageLoad(DEFLICKER_ASVGF_INPUT_FILTERED, p).rgb, vec3(0.0));
    float curr_luma = deflickerAsvgfLuma(curr);

    if (DEFLICKER_ASVGF_ENABLE == 0 || DENOISER_ENABLE_REPROJECTION == 0) {
        imageStore(DEFLICKER_ASVGF_OUTPUT_FILTERED, p, vec4(curr, 1.0));
        imageStore(DEFLICKER_ASVGF_OUTPUT_TEMPORAL_LUMA, p, vec4(curr_luma));
        imageStore(DEFLICKER_ASVGF_OUTPUT_TEMPORAL_RADIANCE, p, vec4(curr, 1.0));
        return;
    }

    vec2 prev_uv = imageLoad(reprojection_uv, p).xy;
    bool uv_valid = all(greaterThanEqual(prev_uv, vec2(0.0))) && all(lessThan(prev_uv, vec2(res)));
    ivec2 q = ivec2(floor(prev_uv + vec2(0.5)));

    vec3 out_c = curr;
    vec4 out_luma_hist = vec4(deflickerAsvgfPackLumaPair(curr_luma, curr_luma));
    vec4 out_radiance_hist = vec4(curr, 1.0);

    if (uv_valid && deflickerAsvgfInBounds(q, res)) {
        vec4 packed_hist_luma = max(imageLoad(DEFLICKER_ASVGF_PREV_TEMPORAL_LUMA, q), vec4(0.0));
        vec4 hist_radiance = max(imageLoad(DEFLICKER_ASVGF_PREV_TEMPORAL_RADIANCE, q), vec4(0.0));
        float prev_hist_len = clamp(hist_radiance.a, 1.0, DEFLICKER_ASVGF_MAX_HISTORY);
        float history_t = (DEFLICKER_ASVGF_MAX_HISTORY > 1.0) ? clamp((prev_hist_len - 1.0) / (DEFLICKER_ASVGF_MAX_HISTORY - 1.0), 0.0, 1.0) : 1.0;
        float strictness = mix(1.0, DEFLICKER_ASVGF_HISTORY_STRICTNESS, history_t);

        float hist_luma[8];
        vec2 p0 = deflickerAsvgfUnpackLumaPair(packed_hist_luma.x);
        vec2 p1 = deflickerAsvgfUnpackLumaPair(packed_hist_luma.y);
        vec2 p2 = deflickerAsvgfUnpackLumaPair(packed_hist_luma.z);
        vec2 p3 = deflickerAsvgfUnpackLumaPair(packed_hist_luma.w);
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

        float base_band = max(DEFLICKER_ASVGF_HISTORY_ABSOLUTE_THRESHOLD, (hmax - hmin) * DEFLICKER_ASVGF_HISTORY_RELATIVE_THRESHOLD);
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

        float mean_luma = curr_luma;
        float sigma_luma = 0.0;
        float min_luma = curr_luma;
        float max_luma = curr_luma;
        deflickerAsvgfNeighborhoodStats(p, res, mean_luma, sigma_luma, min_luma, max_luma);

        float sigma_band = max(DEFLICKER_ASVGF_CLAMP_SIGMA * sigma_luma, DEFLICKER_ASVGF_HISTORY_ABSOLUTE_THRESHOLD);
        float clamp_lo = min_luma - DEFLICKER_ASVGF_CLAMP_EXPAND;
        float clamp_hi = max_luma + DEFLICKER_ASVGF_CLAMP_EXPAND;
        clamp_lo = max(clamp_lo, mean_luma - sigma_band);
        clamp_hi = min(clamp_hi, mean_luma + sigma_band);
        if (clamp_lo > clamp_hi) {
            float c = 0.5 * (clamp_lo + clamp_hi);
            clamp_lo = c;
            clamp_hi = c;
        }

        float hcenter = mix(hcenter_avg, trend_curr, clamp(DEFLICKER_ASVGF_TREND_MIX, 0.0, 1.0));
        float target_luma = mix(hcenter, curr_luma, accept_curr);
        target_luma = clamp(target_luma, clamp_lo, clamp_hi);

        float cand_hist_len = min(prev_hist_len + 1.0, DEFLICKER_ASVGF_MAX_HISTORY);
        float soft_zone = mix(1.0, 2.0, clamp(DEFLICKER_ASVGF_HISTORY_SOFT_ZONE, 0.0, 1.0));
        float history_keep = 1.0 - smoothstep(band, band * soft_zone, deviation);
        history_keep *= (1.0 - DEFLICKER_ASVGF_ANTILAG_STRENGTH * accept_curr);
        if (trend_break) history_keep *= 0.35;
        history_keep = clamp(history_keep, 0.0, 1.0);
        float out_hist_len = cand_hist_len * history_keep;
        float alpha_hist = 1.0 / max(out_hist_len, 1.0);
        vec3 filtered_curr = (curr_luma > 1e-6) ? (curr * (target_luma / curr_luma)) : vec3(target_luma);
        filtered_curr = max(filtered_curr, vec3(0.0));
        vec3 clamped_hist = hist_radiance.rgb;
        float hist_luma_curr = deflickerAsvgfLuma(clamped_hist);
        float clamped_hist_luma = clamp(hist_luma_curr, clamp_lo, clamp_hi);
        if (hist_luma_curr > 1e-6) {
            clamped_hist *= clamped_hist_luma / hist_luma_curr;
        } else {
            clamped_hist = vec3(clamped_hist_luma);
        }
        clamped_hist = max(clamped_hist, vec3(0.0));

        float variance_reactivity = smoothstep(0.0, max(0.03, sigma_band), abs(curr_luma - mean_luma));
        float reactive = max(accept_curr, variance_reactivity);
        float blend_alpha = mix(alpha_hist, 1.0, reactive);
        out_c = mix(clamped_hist, filtered_curr, blend_alpha);
        out_c = max(out_c, vec3(0.0));

        float mixed_luma = deflickerAsvgfLuma(out_c);
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
            deflickerAsvgfPackLumaPair(hist_next[0], hist_next[1]),
            deflickerAsvgfPackLumaPair(hist_next[2], hist_next[3]),
            deflickerAsvgfPackLumaPair(hist_next[4], hist_next[5]),
            deflickerAsvgfPackLumaPair(hist_next[6], hist_next[7]));
        out_radiance_hist = vec4(out_c, out_hist_len);
    }

    imageStore(DEFLICKER_ASVGF_OUTPUT_FILTERED, p, vec4(out_c, 1.0));
    imageStore(DEFLICKER_ASVGF_OUTPUT_TEMPORAL_LUMA, p, out_luma_hist);
    imageStore(DEFLICKER_ASVGF_OUTPUT_TEMPORAL_RADIANCE, p, out_radiance_hist);
}
