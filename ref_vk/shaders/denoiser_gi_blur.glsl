

#ifndef OFFSET
#define OFFSET
#endif

#ifndef DEPTH_THRESHOLD
#define DEPTH_THRESHOLD 1.
#endif

#include "noise.glsl"
#include "brdf.h"
#include "utils.glsl"
#include "denoiser_tools.glsl"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba16f) uniform image2D out_gi_sh1;
layout(set = 0, binding = 1, rgba16f) uniform image2D out_gi_sh2;

layout(set = 0, binding = 2, rgba16f) uniform readonly image2D src_gi_sh1;
layout(set = 0, binding = 3, rgba16f) uniform readonly image2D src_gi_sh2;
layout(set = 0, binding = 4, rgba8) uniform readonly image2D src_material_rmxx;
layout(set = 0, binding = 5, rgba32f) uniform readonly image2D src_position_t;


void main() {
	ivec2 res = ivec2(imageSize(src_gi_sh1));
	ivec2 pix = ivec2(gl_GlobalInvocationID);

	if (any(greaterThanEqual(pix, res))) {
		return;
	}

	const vec4 gi_sh2_src = imageLoad(src_gi_sh2, pix);
	const float depth = imageLoad(src_position_t, pix).w;
	const float metalness_factor = imageLoad(src_material_rmxx, pix).y > .5 ? 1. : 0.;

	vec4 gi_sh1 = vec4(0.);
	vec2 gi_sh2 = vec2(0.);

	float weight_sum = 0.;
	for (int x = -2; x <= 2; ++x) {
		for (int y = -4; y <= 4; ++y) {
			const ivec2 p = pix + ivec2(x, y) * OFFSET;
			if (any(greaterThanEqual(p, res)) || any(lessThan(p, ivec2(0)))) {
				continue;
			}

			// metal surfaces have gi after 2 bounce, diffuse after 1, don't mix them
			const float current_metalness = imageLoad(src_material_rmxx, p).y;
			if (abs(metalness_factor - current_metalness) > .5)
				continue;

			const vec4 current_gi_sh1 = imageLoad(src_gi_sh1, p);
			const vec4 current_gi_sh2 = imageLoad(src_gi_sh2, p);

			const float depth_current = imageLoad(src_position_t, p).w;
			const float depth_offset = abs(depth - depth_current) / max(0.001, depth);
			const float gi_depth_factor = 1. - smoothstep(0., DEPTH_THRESHOLD, depth_offset);

			float weight = gi_depth_factor; // square blur for more efficient light spreading

			//const float sigma = KERNEL_SIZE / 2.;
			//const float weight = normpdf(x, sigma) * normpdf(y, sigma) * gi_depth_factor;

			gi_sh1 += current_gi_sh1 * weight;
			gi_sh2 += current_gi_sh2.xy * weight;
			weight_sum += weight;
		}
	}

	if (weight_sum > 0.) {
		gi_sh1 /= weight_sum;
		gi_sh2 /= weight_sum;
	}

	imageStore(out_gi_sh1, pix, gi_sh1);
	imageStore(out_gi_sh2, pix, vec4(gi_sh2, gi_sh2_src.zw));
}
