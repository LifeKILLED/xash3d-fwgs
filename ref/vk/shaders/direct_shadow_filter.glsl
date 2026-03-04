#include "utils.glsl"
#include "brdf.h"
#include "denoiser_config.glsl"

#define GLSL
#include "ray_interop.h"
#undef GLSL

#ifndef FILTER_RADIUS
#define FILTER_RADIUS 8
#endif

#ifndef REQUIRED_MATCHES
#define REQUIRED_MATCHES 3
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

#ifndef INPUT_IS_SHADOW_VALUE
#define INPUT_IS_SHADOW_VALUE 0
#endif

#ifndef SHADOW_FILTER_USE_SHARED_PINGPONG
#define SHADOW_FILTER_USE_SHARED_PINGPONG 0
#endif

#ifndef SHADOW_SHARED_PINGPONG_SOURCE
#define SHADOW_SHARED_PINGPONG_SOURCE restir_shadows_h
#endif

#ifndef SHADOW_SHARED_PINGPONG_OUTPUT
#define SHADOW_SHARED_PINGPONG_OUTPUT out_restir_shadows_h
#endif

#ifndef SHADOW_FILTER_OUTPUT_IRRADIANCE
#define SHADOW_FILTER_OUTPUT_IRRADIANCE 0
#endif

#ifndef SHADOW_FILTER_IRRADIANCE_SOURCE
#define SHADOW_FILTER_IRRADIANCE_SOURCE diffuse_direct_reconstructed
#endif

#ifndef SHADOW_FILTER_OUTPUT_TEXTURE
#define SHADOW_FILTER_OUTPUT_TEXTURE out_direct_shadowed
#endif

#ifndef SHADOW_FILTER_BYPASS_RAW_IRRADIANCE
#define SHADOW_FILTER_BYPASS_RAW_IRRADIANCE 1
#endif

#if SHADOW_FILTER_USE_SHARED_PINGPONG
    #ifdef HORIZONTAL
        #ifdef OUTPUT_SHADOW
            #undef OUTPUT_SHADOW
        #endif
        #define OUTPUT_SHADOW SHADOW_SHARED_PINGPONG_OUTPUT
    #else
        #ifdef INPUT_SOURCE
            #undef INPUT_SOURCE
        #endif
        #define INPUT_SOURCE SHADOW_SHARED_PINGPONG_SOURCE
        #undef INPUT_IS_SHADOW_VALUE
        #define INPUT_IS_SHADOW_VALUE 1
    #endif
#endif

#ifndef SHADOW_VALUE_CHANNEL
#define SHADOW_VALUE_CHANNEL r
#endif

#ifndef SHADOW_MASK_SEED_CHANNEL
#define SHADOW_MASK_SEED_CHANNEL g
#endif

#ifndef LIGHT_ID_THRESHOLD
#define LIGHT_ID_THRESHOLD 0.01
#endif

#ifndef SHADOW_OUTPUT_ALPHA
#define SHADOW_OUTPUT_ALPHA 1.0
#endif

#ifndef SHADOW_FILTER_OUTPUT_MASK
#define SHADOW_FILTER_OUTPUT_MASK 0
#endif

#ifndef SHADOW_FILTER_PACK_MASK_IN_OUTPUT
#define SHADOW_FILTER_PACK_MASK_IN_OUTPUT 0
#endif

#ifndef SHADOW_FILTER_MASK_USE_PINGPONG_INPUT
#define SHADOW_FILTER_MASK_USE_PINGPONG_INPUT 0
#endif

#ifndef SHADOW_FILTER_MASK_TEXTURE
#define SHADOW_FILTER_MASK_TEXTURE out_shadow_transition_mask
#endif

#ifndef SHADOW_FILTER_MASK_LUMA_WEIGHT_SCALE
#define SHADOW_FILTER_MASK_LUMA_WEIGHT_SCALE 1.0
#endif

#ifndef SHADOW_FILTER_MASK_EDGE_SCALE
#define SHADOW_FILTER_MASK_EDGE_SCALE 6.0
#endif

#ifndef SHADOW_FILTER_MASK_LOCAL_RADIUS
#define SHADOW_FILTER_MASK_LOCAL_RADIUS 2
#endif

#ifndef FILTER_START_RADIUS
#define FILTER_START_RADIUS 1
#endif

#ifndef FILTER_POSITIVE_FIRST
#define FILTER_POSITIVE_FIRST 1
#endif

#ifndef PENUMBRA_LINE_CAP
#define PENUMBRA_LINE_CAP 16
#endif

#ifndef PENUMBRA_BINARY_EPS
#define PENUMBRA_BINARY_EPS 0.10
#endif

#ifndef PENUMBRA_MIN_CONTRAST
#define PENUMBRA_MIN_CONTRAST 0.005
#endif

#ifndef PENUMBRA_MIN_SPAN
#define PENUMBRA_MIN_SPAN 1
#endif

#ifndef PENUMBRA_DETECT_WINDOW
#define PENUMBRA_DETECT_WINDOW 5
#endif

#ifndef PENUMBRA_SMOOTH_RANGE_EPS
#define PENUMBRA_SMOOTH_RANGE_EPS 0.02
#endif

#ifndef PENUMBRA_SMOOTH_SLOPE_EPS
#define PENUMBRA_SMOOTH_SLOPE_EPS 0.003
#endif

#ifndef PENUMBRA_USE_CATMULL_ROM
#define PENUMBRA_USE_CATMULL_ROM 0
#endif

#ifndef PENUMBRA_CATMULL_ROM_BLEND
#define PENUMBRA_CATMULL_ROM_BLEND 0.65
#endif

#ifndef PENUMBRA_MIN_VALID_SAMPLES
#define PENUMBRA_MIN_VALID_SAMPLES 3
#endif

#ifndef PENUMBRA_MIN_COVERAGE
#define PENUMBRA_MIN_COVERAGE 0.20
#endif

#ifndef PENUMBRA_MAX_OFFSET_GAP
#define PENUMBRA_MAX_OFFSET_GAP 6
#endif

#ifndef PENUMBRA_MONO_EPS
#define PENUMBRA_MONO_EPS 0.005
#endif

#ifndef PENUMBRA_MIN_MONO_CONF
#define PENUMBRA_MIN_MONO_CONF 0.35
#endif

#ifndef SHADOW_AGGRESSIVE_LINE_BLUR
#define SHADOW_AGGRESSIVE_LINE_BLUR 1
#endif

#ifndef SHADOW_AGGRESSIVE_BLUR_STRENGTH
#define SHADOW_AGGRESSIVE_BLUR_STRENGTH 0.96
#endif

#ifndef SHADOW_AGGRESSIVE_BLUR_BOX_BLEND
#define SHADOW_AGGRESSIVE_BLUR_BOX_BLEND 0.90
#endif

#ifndef SHADOW_SHARP_EDGE_PRESERVE
#define SHADOW_SHARP_EDGE_PRESERVE 1
#endif

#ifndef SHADOW_SHARP_EDGE_LOW
#define SHADOW_SHARP_EDGE_LOW 0.30
#endif

#ifndef SHADOW_SHARP_EDGE_HIGH
#define SHADOW_SHARP_EDGE_HIGH 0.70
#endif

#ifndef SHADOW_SHARP_EDGE_REDUCE
#define SHADOW_SHARP_EDGE_REDUCE 0.90
#endif

#ifndef SHADOW_SHARP_EDGE_SHARPEN
#define SHADOW_SHARP_EDGE_SHARPEN 0.85
#endif

#ifndef SHADOW_SHARP_CURVATURE_WEIGHT
#define SHADOW_SHARP_CURVATURE_WEIGHT 0.6
#endif

#ifndef SHADOW_SOFTNESS_FLOOR
#define SHADOW_SOFTNESS_FLOOR 0.35
#endif

#ifndef SHADOW_MIN_INV_CENTER_DIST
#define SHADOW_MIN_INV_CENTER_DIST 0.06
#endif

#ifndef SHADOW_HARD_EDGE_ENABLE
#define SHADOW_HARD_EDGE_ENABLE 1
#endif

#ifndef SHADOW_HARD_EDGE_CONTRAST_MIN
#define SHADOW_HARD_EDGE_CONTRAST_MIN 0.75
#endif

#ifndef SHADOW_HARD_EDGE_SIDE_VAR_MAX
#define SHADOW_HARD_EDGE_SIDE_VAR_MAX 0.08
#endif

#ifndef SHADOW_HARD_EDGE_MAX_BLUR
#define SHADOW_HARD_EDGE_MAX_BLUR 0.08
#endif

#ifndef SHADOW_FORCE_FULL_OCCLUSION_SINGLE_SOURCE
#define SHADOW_FORCE_FULL_OCCLUSION_SINGLE_SOURCE 1
#endif

#ifndef SHADOW_FORCE_REQUIRE_ALL_SOURCE_SAMPLES_SHADOWED
#define SHADOW_FORCE_REQUIRE_ALL_SOURCE_SAMPLES_SHADOWED 1
#endif

#ifndef SHADOW_FORCE_FULL_OCCLUSION_UNIT_THRESHOLD
#define SHADOW_FORCE_FULL_OCCLUSION_UNIT_THRESHOLD 0.02
#endif

layout(local_size_x = 8, local_size_y = 8) in;

layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D OUTPUT_SHADOW;
layout(set = 0, binding = 1, rgba16f) uniform readonly image2D INPUT_SOURCE;
layout(set = 0, binding = 2, rgba16f) uniform readonly image2D LIGHT_ID_SOURCE;
layout(set = 0, binding = 3, rgba32f) uniform readonly image2D POSITION_T;
layout(set = 0, binding = 4, rgba16f) uniform readonly image2D NORMALS_GS;
layout(set = 0, binding = 5) uniform UBO { UniformBuffer ubo; } ubo;

#if SHADOW_FILTER_OUTPUT_IRRADIANCE
layout(set = 0, binding = 6, rgba16f) uniform readonly image2D SHADOW_FILTER_IRRADIANCE_SOURCE;
layout(set = 0, binding = 7, rgba16f) uniform writeonly image2D SHADOW_FILTER_OUTPUT_TEXTURE;
#endif

#if SHADOW_FILTER_OUTPUT_MASK
layout(set = 0, binding = 8, rgba16f) uniform writeonly image2D SHADOW_FILTER_MASK_TEXTURE;
#endif

float position_gate(vec3 delta_pos, vec3 geom_norm, float inv_center_dist) {
    return positionEdgeStopWithThresholds(
        delta_pos, geom_norm, inv_center_dist, POSITION_PLANE_THRESHOLD, POSITION_DIST2_THRESHOLD);
}

float load_shadow_value(ivec2 pix) {
    return clamp(imageLoad(INPUT_SOURCE, pix).SHADOW_VALUE_CHANNEL, 0.0, 1.0);
}

float load_shadow_mask_seed(ivec2 pix) {
    return max(imageLoad(INPUT_SOURCE, pix).SHADOW_MASK_SEED_CHANNEL, 0.0);
}

float load_shadow_unit(ivec2 pix) {
    return load_shadow_value(pix);
}

bool is_binary_zero(float v) {
    return v <= PENUMBRA_BINARY_EPS;
}

bool is_binary_one(float v) {
    return v >= (1.0 - PENUMBRA_BINARY_EPS);
}

int penumbra_window_half() {
    return max(PENUMBRA_DETECT_WINDOW / 2, 1);
}

bool is_penumbra_window(float line_values[PENUMBRA_LINE_CAP], int line_count, int idx) {
    int penumbra_half_window = penumbra_window_half();
    if (idx < penumbra_half_window || idx >= (line_count - penumbra_half_window)) return false;

    int from = idx - penumbra_half_window;
    int to = idx + penumbra_half_window;
    int sample_count = to - from + 1;
    if (sample_count < 3) return false;

    float vmin = 1.0;
    float vmax = 0.0;
    int binary_zeros = 0;
    int binary_ones = 0;
    int non_binary = 0;

    for (int i = from; i <= to; i++) {
        float v = line_values[i];
        vmin = min(vmin, v);
        vmax = max(vmax, v);

        if (is_binary_zero(v)) {
            binary_zeros++;
        } else if (is_binary_one(v)) {
            binary_ones++;
        } else {
            non_binary++;
        }
    }

    if (non_binary == 0) {
        return (binary_zeros > 0) && (binary_ones > 0);
    }

    float range = vmax - vmin;
    if (range < PENUMBRA_SMOOTH_RANGE_EPS) return false;

    float left_sum = 0.0;
    float right_sum = 0.0;
    float left_count = 0.0;
    float right_count = 0.0;
    for (int i = from; i < idx; i++) {
        left_sum += line_values[i];
        left_count += 1.0;
    }
    for (int i = idx + 1; i <= to; i++) {
        right_sum += line_values[i];
        right_count += 1.0;
    }

    if (left_count <= 0.0 || right_count <= 0.0) return false;
    float left_mean = left_sum / left_count;
    float right_mean = right_sum / right_count;
    return abs(right_mean - left_mean) >= PENUMBRA_SMOOTH_SLOPE_EPS;
}

float catmull_rom_1d(float p0, float p1, float p2, float p3, float t) {
    float t2 = t * t;
    float t3 = t2 * t;
    return 0.5 * (
        (2.0 * p1) +
        (-p0 + p2) * t +
        (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 +
        (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
    );
}

int max_line_offset_gap(int line_offsets[PENUMBRA_LINE_CAP], int line_count) {
    if (line_count < 2) return FILTER_RADIUS * 2 + 1;
    int max_gap = 1;
    for (int i = 1; i < line_count; i++) {
        max_gap = max(max_gap, line_offsets[i] - line_offsets[i - 1]);
    }
    return max_gap;
}

float penumbra_monotonic_confidence(float line_values[PENUMBRA_LINE_CAP], int grad_start, int grad_end) {
    if (grad_end <= grad_start) return 0.0;

    float grad_dir = line_values[grad_end] - line_values[grad_start];
    if (abs(grad_dir) <= PENUMBRA_MONO_EPS) return 0.0;
    float dir_sign = sign(grad_dir);

    float good = 0.0;
    float total = 0.0;
    for (int i = grad_start + 1; i <= grad_end; i++) {
        float d = line_values[i] - line_values[i - 1];
        if (abs(d) <= PENUMBRA_MONO_EPS) {
            good += 1.0;
            total += 1.0;
            continue;
        }
        good += (sign(d) == dir_sign) ? 1.0 : 0.0;
        total += 1.0;
    }

    if (total <= 0.0) return 0.0;
    return clamp(good / total, 0.0, 1.0);
}

float compute_aggressive_line_blur(float line_values[PENUMBRA_LINE_CAP], int line_count, int center_idx) {
    if (line_count <= 0) return 0.0;
    if (line_count == 1) return line_values[0];

    float box_sum = 0.0;
    float box_w = 0.0;
    float tent_sum = 0.0;
    float tent_w = 0.0;
    for (int i = 0; i < line_count; i++) {
        float v = line_values[i];
        box_sum += v;
        box_w += 1.0;

        float d = abs(float(i - center_idx));
        float w = 1.0 / (1.0 + d); // Wide kernel for strong noise suppression.
        tent_sum += v * w;
        tent_w += w;
    }

    float box_blur = box_sum / max(box_w, 1.0);
    float tent_blur = tent_sum / max(tent_w, 1.0);
    return clamp(mix(tent_blur, box_blur, SHADOW_AGGRESSIVE_BLUR_BOX_BLEND), 0.0, 1.0);
}

float compute_sharp_edge_confidence(float line_values[PENUMBRA_LINE_CAP], int line_count, int center_idx) {
    if (line_count < 3) return 0.0;
    int clamped_center = clamp(center_idx, 1, line_count - 2);

    float l = line_values[clamped_center - 1];
    float c = line_values[clamped_center];
    float r = line_values[clamped_center + 1];

    float edge_local = max(abs(c - l), abs(r - c));

    float left_sum = 0.0;
    float right_sum = 0.0;
    float left_w = 0.0;
    float right_w = 0.0;
    for (int i = max(0, clamped_center - 2); i < clamped_center; i++) {
        left_sum += line_values[i];
        left_w += 1.0;
    }
    for (int i = clamped_center + 1; i <= min(line_count - 1, clamped_center + 2); i++) {
        right_sum += line_values[i];
        right_w += 1.0;
    }

    float left_mean = (left_w > 0.0) ? (left_sum / left_w) : l;
    float right_mean = (right_w > 0.0) ? (right_sum / right_w) : r;
    float edge_mean = abs(right_mean - left_mean);
    float edge_curvature = abs(l - 2.0 * c + r) * SHADOW_SHARP_CURVATURE_WEIGHT;

    float edge = max(max(edge_local, edge_mean), edge_curvature);

    int local_binary = 0;
    local_binary += (is_binary_zero(l) || is_binary_one(l)) ? 1 : 0;
    local_binary += (is_binary_zero(c) || is_binary_one(c)) ? 1 : 0;
    local_binary += (is_binary_zero(r) || is_binary_one(r)) ? 1 : 0;
    float binary_boost = (local_binary >= 2) ? 0.15 : 0.0;

    float base_conf = smoothstep(SHADOW_SHARP_EDGE_LOW, SHADOW_SHARP_EDGE_HIGH, edge + binary_boost);
    float sharpened = base_conf * base_conf * (3.0 - 2.0 * base_conf);
    return clamp(mix(base_conf, sharpened, SHADOW_SHARP_EDGE_SHARPEN), 0.0, 1.0);
}

bool is_hard_binary_edge(float line_values[PENUMBRA_LINE_CAP], int line_count, int center_idx) {
    if (line_count < 5) return false;
    int cidx = clamp(center_idx, 2, line_count - 3);

    float l2 = line_values[cidx - 2];
    float l1 = line_values[cidx - 1];
    float c  = line_values[cidx];
    float r1 = line_values[cidx + 1];
    float r2 = line_values[cidx + 2];

    int binary_count = 0;
    binary_count += (is_binary_zero(l2) || is_binary_one(l2)) ? 1 : 0;
    binary_count += (is_binary_zero(l1) || is_binary_one(l1)) ? 1 : 0;
    binary_count += (is_binary_zero(c)  || is_binary_one(c))  ? 1 : 0;
    binary_count += (is_binary_zero(r1) || is_binary_one(r1)) ? 1 : 0;
    binary_count += (is_binary_zero(r2) || is_binary_one(r2)) ? 1 : 0;
    if (binary_count < 4) return false;

    float left_mean = 0.5 * (l2 + l1);
    float right_mean = 0.5 * (r1 + r2);
    float contrast = abs(right_mean - left_mean);
    if (contrast < SHADOW_HARD_EDGE_CONTRAST_MIN) return false;

    float left_var = abs(l2 - l1);
    float right_var = abs(r1 - r2);
    if (left_var > SHADOW_HARD_EDGE_SIDE_VAR_MAX || right_var > SHADOW_HARD_EDGE_SIDE_VAR_MAX) return false;

    return true;
}

void store_shadowed_irradiance(ivec2 pix, float shadow_value) {
#if SHADOW_FILTER_OUTPUT_IRRADIANCE
    vec4 irradiance = imageLoad(SHADOW_FILTER_IRRADIANCE_SOURCE, pix);
    vec3 rgb = irradiance.rgb;
    float shadow_weight = clamp(shadow_value, 0.0, 1.0);
    imageStore(SHADOW_FILTER_OUTPUT_TEXTURE, pix, vec4(rgb * shadow_weight, irradiance.a));
#endif
}

void store_bypass_irradiance(ivec2 pix) {
#if SHADOW_FILTER_OUTPUT_IRRADIANCE
    vec4 irradiance = imageLoad(SHADOW_FILTER_IRRADIANCE_SOURCE, pix);
#if SHADOW_FILTER_BYPASS_RAW_IRRADIANCE
    imageStore(SHADOW_FILTER_OUTPUT_TEXTURE, pix, irradiance);
#else
    float shadow_value = load_shadow_value(pix);
    store_shadowed_irradiance(pix, shadow_value);
#endif
#endif
}

float load_mask_luma(ivec2 pix) {
#if SHADOW_FILTER_OUTPUT_IRRADIANCE
    return luminance(abs(imageLoad(SHADOW_FILTER_IRRADIANCE_SOURCE, pix).rgb));
#elif INPUT_IS_SHADOW_VALUE
    return 1.0;
#else
    return luminance(abs(imageLoad(INPUT_SOURCE, pix).rgb));
#endif
}

vec3 build_shadow_transition_mask_payload(
    ivec2 pix,
    ivec2 res,
    float line_values[PENUMBRA_LINE_CAP],
    int line_offsets[PENUMBRA_LINE_CAP],
    int line_count,
    int center_line_idx,
    float out_shadow_unit)
{
    if (line_count <= 0 || center_line_idx < 0 || center_line_idx >= line_count) {
        float seed = load_shadow_mask_seed(pix);
        return vec3(seed, out_shadow_unit, out_shadow_unit);
    }

    float weighted_shadow_sum = 0.0;
    float weighted_sum = 0.0;
    float weighted_seed_sum = 0.0;
    for (int i = 0; i < line_count; i++) {
        ivec2 q = pix;
#ifdef HORIZONTAL
        q.x += line_offsets[i];
#else
        q.y += line_offsets[i];
#endif
        if (any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, res))) continue;
        float wl = 1.0 + SHADOW_FILTER_MASK_LUMA_WEIGHT_SCALE * load_mask_luma(q);
        weighted_shadow_sum += line_values[i] * wl;
        weighted_seed_sum += load_shadow_mask_seed(q) * wl;
        weighted_sum += wl;
    }
    float weighted_shadow = (weighted_sum > 0.0) ? (weighted_shadow_sum / weighted_sum) : out_shadow_unit;
    float weighted_seed = (weighted_sum > 0.0) ? (weighted_seed_sum / weighted_sum) : load_shadow_mask_seed(pix);

    int l0 = max(0, center_line_idx - SHADOW_FILTER_MASK_LOCAL_RADIUS);
    int l1 = center_line_idx - 1;
    int r0 = center_line_idx + 1;
    int r1 = min(line_count - 1, center_line_idx + SHADOW_FILTER_MASK_LOCAL_RADIUS);

    float left_sum = 0.0, left_w = 0.0;
    float right_sum = 0.0, right_w = 0.0;
    for (int i = l0; i <= l1; i++) {
        ivec2 q = pix;
#ifdef HORIZONTAL
        q.x += line_offsets[i];
#else
        q.y += line_offsets[i];
#endif
        if (any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, res))) continue;
        float wl = 1.0 + SHADOW_FILTER_MASK_LUMA_WEIGHT_SCALE * load_mask_luma(q);
        left_sum += line_values[i] * wl;
        left_w += wl;
    }
    for (int i = r0; i <= r1; i++) {
        ivec2 q = pix;
#ifdef HORIZONTAL
        q.x += line_offsets[i];
#else
        q.y += line_offsets[i];
#endif
        if (any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, res))) continue;
        float wl = 1.0 + SHADOW_FILTER_MASK_LUMA_WEIGHT_SCALE * load_mask_luma(q);
        right_sum += line_values[i] * wl;
        right_w += wl;
    }

    float left_mean = (left_w > 0.0) ? (left_sum / left_w) : weighted_shadow;
    float right_mean = (right_w > 0.0) ? (right_sum / right_w) : weighted_shadow;
    return vec3(weighted_seed, weighted_shadow, out_shadow_unit);
}

vec3 merge_shadow_mask_payload_with_pingpong(ivec2 pix, vec3 payload) {
#if SHADOW_FILTER_MASK_USE_PINGPONG_INPUT
    vec4 prev = imageLoad(INPUT_SOURCE, pix);
    payload.x = 0.5 * (payload.x + prev.g);
    payload.y = 0.5 * (payload.y + prev.b);
    payload.z = 0.5 * (payload.z + prev.a);
#endif
    return payload;
}

void store_shadow_transition_mask_debug(ivec2 pix, vec3 payload) {
#if SHADOW_FILTER_OUTPUT_MASK
    // Debug payload:
    // R = blurred shadow-energy mask, G = weighted visibility, B = filtered visibility.
    imageStore(SHADOW_FILTER_MASK_TEXTURE, pix, vec4(payload, 1.0));
#endif
}

void main() {
    ivec2 pix = ivec2(gl_GlobalInvocationID.xy);
    ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
    if (any(greaterThanEqual(pix, res))) return;

    float center_shadow = load_shadow_value(pix);
    float center_shadow_unit = center_shadow;
    float center_seed = load_shadow_mask_seed(pix);
    if (DENOISER_ENABLE_SHADOWS_FILTERING == 0) {
        vec3 center_payload = vec3(center_seed, center_shadow_unit, center_shadow_unit);
#if SHADOW_FILTER_PACK_MASK_IN_OUTPUT
        imageStore(OUTPUT_SHADOW, pix, vec4(center_shadow, center_payload));
#else
        imageStore(OUTPUT_SHADOW, pix, vec4(center_shadow, center_shadow, center_shadow, SHADOW_OUTPUT_ALPHA));
#endif
        store_shadow_transition_mask_debug(pix, center_payload);
        store_shadowed_irradiance(pix, center_shadow);
        return;
    }

    vec3 p0 = imageLoad(POSITION_T, pix).xyz;
    vec3 g0 = normalDecode(imageLoad(NORMALS_GS, pix).xy);
    float inv_center_dist = max(1.0 / max(length(p0), 1.0), SHADOW_MIN_INV_CENTER_DIST);

    float light_id0 = imageLoad(LIGHT_ID_SOURCE, pix).w;

    const int line_search_left = -(PENUMBRA_LINE_CAP / 2);
    const int line_search_right = line_search_left + PENUMBRA_LINE_CAP - 1;
    const int search_from = max(-FILTER_RADIUS, line_search_left);
    const int search_to = min(FILTER_RADIUS, line_search_right);

    float line_values[PENUMBRA_LINE_CAP];
    int line_offsets[PENUMBRA_LINE_CAP];
    int line_count = 0;
    int center_line_idx = -1;

    for (int offset = search_from; offset <= search_to; offset++) {
        if (line_count >= PENUMBRA_LINE_CAP) break;

        if (offset == 0) {
            line_offsets[line_count] = 0;
            line_values[line_count] = center_shadow_unit;
            center_line_idx = line_count;
            line_count++;
            continue;
        }

        ivec2 sample_pix = pix;
#ifdef HORIZONTAL
        sample_pix.x += offset;
#else
        sample_pix.y += offset;
#endif
        if (any(lessThan(sample_pix, ivec2(0))) || any(greaterThanEqual(sample_pix, res))) continue;

        float light_id1 = imageLoad(LIGHT_ID_SOURCE, sample_pix).w;
        if (abs(light_id1 - light_id0) > LIGHT_ID_THRESHOLD) continue;

        vec3 p1 = imageLoad(POSITION_T, sample_pix).xyz;
        if (position_gate(p1 - p0, g0, inv_center_dist) == 0.0) continue;

        line_offsets[line_count] = offset;
        line_values[line_count] = load_shadow_unit(sample_pix);
        line_count++;
    }

    if (center_line_idx < 0) {
        vec3 center_payload = vec3(center_seed, center_shadow_unit, center_shadow_unit);
#if SHADOW_FILTER_PACK_MASK_IN_OUTPUT
        imageStore(OUTPUT_SHADOW, pix, vec4(center_shadow, center_payload));
#else
        imageStore(OUTPUT_SHADOW, pix, vec4(center_shadow, center_shadow, center_shadow, SHADOW_OUTPUT_ALPHA));
#endif
        store_shadow_transition_mask_debug(pix, center_payload);
        store_shadowed_irradiance(pix, center_shadow);
        return;
    }

#if SHADOW_FORCE_FULL_OCCLUSION_SINGLE_SOURCE
    bool all_samples_shadowed = true;
    const float full_shadow_thr = clamp(SHADOW_FORCE_FULL_OCCLUSION_UNIT_THRESHOLD, 0.0, 1.0);
    for (int i = 0; i < line_count; i++) {
        float v = line_values[i];
        if (v > full_shadow_thr) {
            all_samples_shadowed = false;
            break;
        }
    }

    bool force_condition = false;
#if SHADOW_FORCE_REQUIRE_ALL_SOURCE_SAMPLES_SHADOWED
    force_condition = (line_count > 0) && all_samples_shadowed;
#endif
    // Low-support safety: if we found too few valid source samples and center is dark, keep full occlusion.
    if (!force_condition && line_count < REQUIRED_MATCHES && center_shadow_unit <= full_shadow_thr) {
        force_condition = true;
    }

    if (force_condition) {
        // Full occlusion for this light-source neighborhood.
        // Shadow value domain is [0, 1], where 0 means fully shadowed.
        const float forced_shadow = 0.0;
        vec3 forced_payload = vec3(0.0, 0.0, 0.0);
#if SHADOW_FILTER_PACK_MASK_IN_OUTPUT
        imageStore(OUTPUT_SHADOW, pix, vec4(forced_shadow, forced_payload));
#else
        imageStore(OUTPUT_SHADOW, pix, vec4(forced_shadow, forced_shadow, forced_shadow, SHADOW_OUTPUT_ALPHA));
#endif
        store_shadow_transition_mask_debug(pix, forced_payload);
        store_shadowed_irradiance(pix, forced_shadow);
        return;
    }
#endif

    float out_shadow_unit = center_shadow_unit;

#if SHADOW_AGGRESSIVE_LINE_BLUR
    float aggressive_line_blur = compute_aggressive_line_blur(line_values, line_count, center_line_idx);
    float aggressive_strength = SHADOW_AGGRESSIVE_BLUR_STRENGTH;
    bool hard_binary_edge = false;
#if SHADOW_SHARP_EDGE_PRESERVE
    float sharp_edge_conf = compute_sharp_edge_confidence(line_values, line_count, center_line_idx);
    aggressive_strength *= (1.0 - SHADOW_SHARP_EDGE_REDUCE * sharp_edge_conf);
#endif
#if SHADOW_HARD_EDGE_ENABLE
    hard_binary_edge = is_hard_binary_edge(line_values, line_count, center_line_idx);
#endif
    float min_soft_strength = SHADOW_AGGRESSIVE_BLUR_STRENGTH * SHADOW_SOFTNESS_FLOOR;
    aggressive_strength = max(aggressive_strength, min_soft_strength);
#if SHADOW_HARD_EDGE_ENABLE
    if (hard_binary_edge) {
        aggressive_strength = min(aggressive_strength, SHADOW_HARD_EDGE_MAX_BLUR);
    }
#endif
    out_shadow_unit = mix(center_shadow_unit, aggressive_line_blur, aggressive_strength);
#endif

    float expected_support = float(max(search_to - search_from + 1, 1));
    float support_coverage = float(line_count) / expected_support;
    float coverage_conf = smoothstep(PENUMBRA_MIN_COVERAGE, 1.0, support_coverage);
    int line_max_gap = max_line_offset_gap(line_offsets, line_count);
    float gap_conf = 1.0 - smoothstep(float(PENUMBRA_MAX_OFFSET_GAP), float(PENUMBRA_MAX_OFFSET_GAP + 2), float(line_max_gap));
    float support_conf = clamp(min(coverage_conf, gap_conf), 0.0, 1.0);

    int window_half = penumbra_window_half();
    bool can_check_penumbra = (line_count >= (window_half * 2 + 1))
        && (line_count >= PENUMBRA_MIN_VALID_SAMPLES)
        && (center_line_idx >= window_half)
        && (center_line_idx < (line_count - window_half))
        && (support_conf > 0.0);
    if (can_check_penumbra && is_penumbra_window(line_values, line_count, center_line_idx)) {
        int grad_start = center_line_idx;
        int grad_end = center_line_idx;

        for (int i = center_line_idx - 1; i >= window_half; i--) {
            if (!is_penumbra_window(line_values, line_count, i)) break;
            grad_start = i;
        }
        for (int i = center_line_idx + 1; i < (line_count - window_half); i++) {
            if (!is_penumbra_window(line_values, line_count, i)) break;
            grad_end = i;
        }

        if ((grad_end - grad_start) >= PENUMBRA_MIN_SPAN) {
            float left_plateau = 0.0;
            float left_count = 0.0;
            for (int i = 0; i < grad_start; i++) {
                left_plateau += line_values[i];
                left_count += 1.0;
            }
            left_plateau = (left_count > 0.0) ? (left_plateau / left_count) : line_values[grad_start];

            float right_plateau = 0.0;
            float right_count = 0.0;
            for (int i = grad_end + 1; i < line_count; i++) {
                right_plateau += line_values[i];
                right_count += 1.0;
            }
            right_plateau = (right_count > 0.0) ? (right_plateau / right_count) : line_values[grad_end];

            float contrast = abs(right_plateau - left_plateau);
            if (contrast >= PENUMBRA_MIN_CONTRAST) {
                float mono_conf = penumbra_monotonic_confidence(line_values, grad_start, grad_end);
                if (mono_conf >= PENUMBRA_MIN_MONO_CONF) {
                    float left_offset = float(line_offsets[grad_start]);
                    float right_offset = float(line_offsets[grad_end]);
                    float center_offset = float(line_offsets[center_line_idx]);
                    float t = 0.0;

                    if (abs(right_offset - left_offset) > 1e-4) {
                        t = clamp((center_offset - left_offset) / (right_offset - left_offset), 0.0, 1.0);
                    } else {
                        t = float(center_line_idx - grad_start) / float(max(grad_end - grad_start, 1));
                    }

                    float reconstructed = mix(left_plateau, right_plateau, t);
#if PENUMBRA_USE_CATMULL_ROM
                    float catmull_blend = PENUMBRA_CATMULL_ROM_BLEND * support_conf * mono_conf;
                    float p0 = left_plateau;
                    float p1 = line_values[grad_start];
                    float p2 = line_values[grad_end];
                    float p3 = right_plateau;
                    float catmull_value = catmull_rom_1d(p0, p1, p2, p3, t);
                    float minv = min(min(p0, p1), min(p2, p3));
                    float maxv = max(max(p0, p1), max(p2, p3));
                    catmull_value = clamp(catmull_value, minv, maxv);
                    reconstructed = mix(reconstructed, catmull_value, catmull_blend);
#endif
                    out_shadow_unit = clamp(reconstructed, 0.0, 1.0);
                }
            }
        }
    }

    float out_shadow = clamp(out_shadow_unit, 0.0, 1.0);
    vec3 mask_payload = build_shadow_transition_mask_payload(
        pix, res, line_values, line_offsets, line_count, center_line_idx, out_shadow_unit);
    mask_payload = merge_shadow_mask_payload_with_pingpong(pix, mask_payload);

#if SHADOW_FILTER_PACK_MASK_IN_OUTPUT
    imageStore(OUTPUT_SHADOW, pix, vec4(out_shadow, mask_payload));
#else
    imageStore(OUTPUT_SHADOW, pix, vec4(out_shadow, out_shadow, out_shadow, SHADOW_OUTPUT_ALPHA));
#endif
    store_shadow_transition_mask_debug(pix, mask_payload);
    store_shadowed_irradiance(pix, out_shadow);
}
