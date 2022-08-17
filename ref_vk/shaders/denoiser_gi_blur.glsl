
#ifndef KERNEL_SIZE
#define KERNEL_SIZE 3
#endif

#ifndef OFFSET
#define OFFSET 8
#endif

#ifndef DEPTH_THRESHOLD
#define DEPTH_THRESHOLD 25.0
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


void main() {
	ivec2 res = ivec2(imageSize(src_gi_sh1));
	ivec2 pix = ivec2(gl_GlobalInvocationID);

	if (any(greaterThanEqual(pix, res))) {
		return;
	}

	const float depth = imageLoad(src_gi_sh2, pix).z;

	vec4 gi_sh1 = vec4(0.);
	vec2 gi_sh2 = vec2(0.);

	float weight_sum = 0.;
	for (int x = -KERNEL_SIZE; x <= KERNEL_SIZE; ++x) {
		for (int y = -KERNEL_SIZE; y <= KERNEL_SIZE; ++y) {
			const ivec2 p = pix + ivec2(x, y) * OFFSET;
			if (any(greaterThanEqual(p, res)) || any(lessThan(p, ivec2(0)))) {
				continue;
			}

			const vec4 current_gi_sh1 = imageLoad(src_gi_sh1, p);
			const vec4 current_gi_sh2 = imageLoad(src_gi_sh2, p);

			const float depth_current = current_gi_sh1.z;
			const float depth_offset = abs(depth - depth_current);
			const float gi_depth_factor = 1. - smoothstep(0., DEPTH_THRESHOLD, depth_offset);

			const float sigma = KERNEL_SIZE / 2.;
			const float weight = normpdf(x, sigma) * normpdf(y, sigma) * gi_depth_factor;

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
	imageStore(out_gi_sh2, pix, vec4(gi_sh2, depth, 0.));
}
