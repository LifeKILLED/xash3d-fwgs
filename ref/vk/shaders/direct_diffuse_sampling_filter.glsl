#include "denoiser_config.glsl"
#include "utils.glsl"

#define GLSL
#include "ray_interop.h"
#undef GLSL

#ifndef OUTPUT_IRRADIANCE
#define OUTPUT_IRRADIANCE out_diffuse_direct_sampling_filtered
#endif

#ifndef INPUT_IRRADIANCE
#define INPUT_IRRADIANCE diffuse_direct
#endif

#ifndef LIGHT_ID_SOURCE
#define LIGHT_ID_SOURCE diffuse_direct_lightdir
#endif

#ifndef LIGHT_ID_PACKED_SOURCE
#define LIGHT_ID_PACKED_SOURCE diffuse_lightid_packed2x2
#endif

#ifndef FILTER_KERNEL_RADIUS
#define FILTER_KERNEL_RADIUS 2
#endif

#ifndef FILTER_MAX_OFFSETS
#define FILTER_MAX_OFFSETS 8
#endif

#if FILTER_MAX_OFFSETS < 1
#undef FILTER_MAX_OFFSETS
#define FILTER_MAX_OFFSETS 1
#endif

#ifndef LIGHT_ID_THRESHOLD
#define LIGHT_ID_THRESHOLD 0.01
#endif

#ifndef SHADING_NORMAL_DOT_THRESHOLD
#define SHADING_NORMAL_DOT_THRESHOLD 0.95
#endif

layout(local_size_x = 8, local_size_y = 8) in;

layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D OUTPUT_IRRADIANCE;
layout(set = 0, binding = 1, rgba16f) uniform readonly image2D INPUT_IRRADIANCE;
layout(set = 0, binding = 2, rgba16f) uniform readonly image2D LIGHT_ID_SOURCE;
layout(set = 0, binding = 3, rgba32f) uniform readonly image2D position_t;
layout(set = 0, binding = 4, rgba16f) uniform readonly image2D normals_gs;
layout(set = 0, binding = 5) uniform UBO { UniformBuffer ubo; } ubo;
layout(set = 0, binding = 6, rgba16f) uniform readonly image2D LIGHT_ID_PACKED_SOURCE;

#define PACKED_TILE_W 10
#define PACKED_TILE_H 10
shared vec4 s_tile_light_id_packed[PACKED_TILE_H][PACKED_TILE_W];

float position_gate(vec3 delta_pos, vec3 geom_norm, float inv_center_dist, float world_texel_size) {
    return positionEdgeStopWithWorldTexel(
        delta_pos, geom_norm, inv_center_dist, DENOISER_POSITION_PLANE_THRESHOLD, world_texel_size);
}

void main() {
    ivec2 pix = ivec2(gl_GlobalInvocationID.xy);
    ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
    bool in_bounds = all(lessThan(pix, res));

    const ivec2 packed_res = (res + ivec2(1)) / 2;
    const ivec2 wg_base = ivec2(gl_WorkGroupID.xy) * ivec2(8, 8);
    const ivec2 packed_min = ivec2(
        int(floor(float(wg_base.x - FILTER_KERNEL_RADIUS) * 0.5)),
        int(floor(float(wg_base.y - FILTER_KERNEL_RADIUS) * 0.5))
    );
    const int local_idx = int(gl_LocalInvocationIndex);
    const int tile_count = PACKED_TILE_W * PACKED_TILE_H;
    for (int idx = local_idx; idx < tile_count; idx += 64) {
        int tx = idx % PACKED_TILE_W;
        int ty = idx / PACKED_TILE_W;
        ivec2 src = clamp(packed_min + ivec2(tx, ty), ivec2(0), packed_res - ivec2(1));
        s_tile_light_id_packed[ty][tx] = imageLoad(LIGHT_ID_PACKED_SOURCE, src);
    }

    barrier();

    if (!in_bounds) return;

    vec4 center = imageLoad(INPUT_IRRADIANCE, pix);
    if (DENOISER_ENABLE_DIFFUSE_SAMPLING_FILTER == 0) {
        imageStore(OUTPUT_IRRADIANCE, pix, center);
        return;
    }

    float center_light_id = imageLoad(LIGHT_ID_SOURCE, pix).w;
    vec4 center_norm = imageLoad(normals_gs, pix);
    vec3 center_shading = normalDecode(center_norm.zw);
    ivec2 matched_offsets[FILTER_MAX_OFFSETS];
    int matched_count = 0;

    matched_offsets[matched_count++] = ivec2(0, 0);

    const int spiral_limit = ((FILTER_KERNEL_RADIUS * 2 + 1) * (FILTER_KERNEL_RADIUS * 2 + 1)) - 1;
    const ivec2 spiral_dirs[4] = ivec2[](
        ivec2(1, 0),
        ivec2(0, 1),
        ivec2(-1, 0),
        ivec2(0, -1)
    );

    ivec2 offset = ivec2(0, 0);
    int dir = 0;
    int segment_len = 1;
    int segment_step = 0;
    int segments_done = 0;

    for (int visited = 0; visited < spiral_limit && matched_count < FILTER_MAX_OFFSETS; visited++) {
        if (segment_step == segment_len) {
            dir = (dir + 1) & 3;
            segment_step = 0;
            segments_done++;
            if ((segments_done & 1) == 0) {
                segment_len++;
            }
        }

        offset += spiral_dirs[dir];
        segment_step++;

        if (abs(offset.x) > FILTER_KERNEL_RADIUS || abs(offset.y) > FILTER_KERNEL_RADIUS) {
            continue;
        }

        ivec2 q = pix + offset;
        if (any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, res))) {
            continue;
        }

        ivec2 packed_q = ivec2(
            int(floor(float(q.x) * 0.5)),
            int(floor(float(q.y) * 0.5))
        );
        ivec2 packed_local = packed_q - packed_min;
        vec4 packed_ids;
        if (all(greaterThanEqual(packed_local, ivec2(0))) && packed_local.x < PACKED_TILE_W && packed_local.y < PACKED_TILE_H) {
            packed_ids = s_tile_light_id_packed[packed_local.y][packed_local.x];
        } else {
            packed_ids = imageLoad(LIGHT_ID_PACKED_SOURCE, clamp(packed_q, ivec2(0), packed_res - ivec2(1)));
        }

        vec4 packed_match = max(vec4(0.0), vec4(1.0) - abs(vec4(center_light_id) - packed_ids));
        if (dot(packed_match, vec4(1.0)) <= 0.0) {
            continue;
        }

        float sample_light_id = imageLoad(LIGHT_ID_SOURCE, q).w;
        if (abs(sample_light_id - center_light_id) > LIGHT_ID_THRESHOLD) {
            continue;
        }

        matched_offsets[matched_count++] = offset;
    }

    // Hot path: no compatible neighbors found, keep center sample.
    if (matched_count == 1) {
        imageStore(OUTPUT_IRRADIANCE, pix, vec4(center.rgb, clamp(center.a, 0.0, 1.0)));
        return;
    }

    vec3 center_geom = normalDecode(center_norm.xy);
    vec3 center_pos = imageLoad(position_t, pix).xyz;
    float inv_center_dist = 1.0 / max(length(center_pos), 1.0);
    vec3 cam_pos = (ubo.ubo.inv_view * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
    float world_texel_size = estimateWorldTexelSizeFromCenter(
        pix, res, cam_pos, center_pos, ubo.ubo.inv_proj, ubo.ubo.inv_view, DENOISER_POSITION_TEXEL_SIZE_MARGIN);

    vec3 sum_rgb = center.rgb;
    float count = 1.0;

    for (int i = 1; i < matched_count; i++) {
        ivec2 q = pix + matched_offsets[i];

        vec4 norm = imageLoad(normals_gs, q);
        vec3 shading = normalDecode(norm.zw);
        if (dot(center_shading, shading) < SHADING_NORMAL_DOT_THRESHOLD) continue;

        vec3 pos = imageLoad(position_t, q).xyz;
        if (position_gate(pos - center_pos, center_geom, inv_center_dist, world_texel_size) == 0.0) continue;

        vec3 sample_rgb = imageLoad(INPUT_IRRADIANCE, q).rgb;
        sum_rgb += sample_rgb;
        count += 1.0;
    }

    vec3 filtered = (count > 0.0) ? (sum_rgb / count) : center.rgb;
    imageStore(OUTPUT_IRRADIANCE, pix, vec4(filtered, clamp(center.a, 0.0, 1.0)));
}
