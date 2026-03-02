#include "utils.glsl"
#include "denoiser_config.glsl"

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

#ifndef FILTER_KERNEL_RADIUS
#define FILTER_KERNEL_RADIUS 3
#endif

#ifndef LIGHT_ID_THRESHOLD
#define LIGHT_ID_THRESHOLD 0.01
#endif

#ifndef SHADING_NORMAL_DOT_THRESHOLD
#define SHADING_NORMAL_DOT_THRESHOLD 0.95
#endif

#ifndef POSITION_PLANE_THRESHOLD
#define POSITION_PLANE_THRESHOLD 0.010
#endif

#ifndef POSITION_DIST2_THRESHOLD
#define POSITION_DIST2_THRESHOLD 0.0004
#endif

layout(local_size_x = 8, local_size_y = 8) in;

layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D OUTPUT_IRRADIANCE;
layout(set = 0, binding = 1, rgba16f) uniform readonly image2D INPUT_IRRADIANCE;
layout(set = 0, binding = 2, rgba16f) uniform readonly image2D LIGHT_ID_SOURCE;
layout(set = 0, binding = 3, rgba32f) uniform readonly image2D position_t;
layout(set = 0, binding = 4, rgba16f) uniform readonly image2D normals_gs;
layout(set = 0, binding = 5) uniform UBO { UniformBuffer ubo; } ubo;

float position_gate(vec3 delta_pos, vec3 geom_norm, float inv_center_dist) {
    float n_plane_dist = abs(dot(delta_pos, geom_norm)) * inv_center_dist;
    float n_dist2 = dot(delta_pos, delta_pos) * (inv_center_dist * inv_center_dist);
    float w_plane = step(n_plane_dist, POSITION_PLANE_THRESHOLD);
    float w_dist = step(n_dist2, POSITION_DIST2_THRESHOLD);
    return max(w_plane, w_dist);
}

float shadow_sign_from_irradiance(vec3 irradiance) {
    return any(lessThan(irradiance, vec3(0.0))) ? -1.0 : 1.0;
}

void main() {
    ivec2 pix = ivec2(gl_GlobalInvocationID.xy);
    ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
    if (any(greaterThanEqual(pix, res))) return;

    vec4 center = imageLoad(INPUT_IRRADIANCE, pix);
    if (DENOISER_ENABLE_DIFFUSE_SAMPLING_FILTER == 0) {
        imageStore(OUTPUT_IRRADIANCE, pix, center);
        return;
    }

    float center_light_id = imageLoad(LIGHT_ID_SOURCE, pix).w;
    vec4 center_norm = imageLoad(normals_gs, pix);
    vec3 center_geom = normalDecode(center_norm.xy);
    vec3 center_shading = normalDecode(center_norm.zw);
    vec3 center_pos = imageLoad(position_t, pix).xyz;
    float inv_center_dist = 1.0 / max(length(center_pos), 1.0);
    float center_sign = shadow_sign_from_irradiance(center.rgb);

    vec3 sum_abs = vec3(0.0);
    float count = 0.0;

    for (int y = -FILTER_KERNEL_RADIUS; y <= FILTER_KERNEL_RADIUS; y++) {
        for (int x = -FILTER_KERNEL_RADIUS; x <= FILTER_KERNEL_RADIUS; x++) {
            ivec2 q = pix + ivec2(x, y);
            if (any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, res))) continue;

            float sample_light_id = imageLoad(LIGHT_ID_SOURCE, q).w;
            if (abs(sample_light_id - center_light_id) > LIGHT_ID_THRESHOLD) continue;

            vec4 norm = imageLoad(normals_gs, q);
            vec3 shading = normalDecode(norm.zw);
            if (dot(center_shading, shading) < SHADING_NORMAL_DOT_THRESHOLD) continue;

            vec3 pos = imageLoad(position_t, q).xyz;
            if (position_gate(pos - center_pos, center_geom, inv_center_dist) == 0.0) continue;

            vec3 irradiance_abs = abs(imageLoad(INPUT_IRRADIANCE, q).rgb);
            sum_abs += irradiance_abs;
            count += 1.0;
        }
    }

    vec3 filtered_abs = (count > 0.0) ? (sum_abs / count) : abs(center.rgb);
    vec3 filtered_signed = filtered_abs * center_sign;
    imageStore(OUTPUT_IRRADIANCE, pix, vec4(filtered_signed, center.a));
}
