
#include "noise.glsl"
#include "brdf.h"
#include "utils.glsl"
#include "denoiser_tools.glsl"

// used in multi-pass filtering as 1, 2, 4 and more step sizes
#ifndef SVGF_STEP_SIZE 
	#define SVGF_STEP_SIZE 1
#endif

#define DRIVEN_BY_NORMALS 1
//#define DRIVEN_BY_DEPTH 1
#define DRIVEN_BY_VARIANCE 1

#define PHI_COLOR 10.
#define KERNEL_SIZE 1
#define DEPTH_FACTOR 10.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba16f) uniform image2D src_color_filtered;

layout(set = 0, binding = 1, rgba16f) uniform readonly image2D src_color_noisy;
layout(set = 0, binding = 2, rgba16f) uniform readonly image2D src_variance;
layout(set = 0, binding = 3, rgba16f) uniform readonly image2D src_normals_gs;
layout(set = 0, binding = 4, rgba32f) uniform readonly image2D src_position_depth; // for depth
layout(set = 0, binding = 5, rgba8) uniform readonly image2D src_material_rmxx;
//#ifdef DRIVEN_BY_RAY_LENGTH
//	layout(set = 0, binding = 5, rgba32f) uniform readonly image2D src_refl_position_t; // for reflection ray length
//#endif

// Normal-weighting function (4.4.1)
float normalWeight(vec3 normal0, vec3 normal1) {
	const float exponent = 64.0;
	return pow(max(0.0, dot(normal0, normal1)), exponent);
}

// Depth-weighting function (4.4.2)
float depthWeight(float depth0, float depth1, vec2 grad, vec2 offset) {
	// paper uses eps = 0.005 for a normalized depth buffer
	// ours is not but 0.1 seems to work fine
	const float eps = 0.1;
	return exp((-abs(depth0 - depth1)) / (abs(dot(grad, offset)) + eps));
}

// Self-made depth gradient for compute shader (is it fine on edges?)
vec2 depthGradient(float src_depth, ivec2 pix, ivec2 res) {
	vec4 depth_samples = vec4(src_depth);
	if ((pix.x + 1) < res.x) depth_samples.x = imageLoad(src_position_depth, pix + ivec2(1, 0)).w;
	if ((pix.x - 1) >= 0) depth_samples.y = imageLoad(src_position_depth, pix - ivec2(1, 0)).w;
	if ((pix.y + 1) < res.y) depth_samples.z = imageLoad(src_position_depth, pix + ivec2(0, 1)).w;
	if ((pix.y - 1) >= 0) depth_samples.w = imageLoad(src_position_depth, pix - ivec2(0, 1)).w;
	return (depth_samples.xz - depth_samples.yw) / 2.;
}

// Luminance-weighting function (4.4.3)
float luminanceWeight(float lum0, float lum1, float variance) {
  const float strictness = 30.0;
  const float eps = 0.05;
  return exp((-abs(lum0 - lum1)) / (strictness * variance + eps));
}


void readNormals(ivec2 uv, out vec3 geometry_normal, out vec3 shading_normal) {
	const vec4 n = imageLoad(src_normals_gs, uv);
	geometry_normal = normalDecode(n.xy);
	shading_normal = normalDecode(n.zw);
}



float depth_edge_stopping_weight(float center_depth, float sample_depth, float phi)
{
    return exp(-abs(center_depth - sample_depth) / phi);
}

float luma_edge_stopping_weight(float center_luma, float sample_luma, float phi)
{
    return abs(center_luma - sample_luma) / phi;
}


// The next function implements the filtering method described in the two papers
// linked below.
//
// "Progressive Spatiotemporal Variance-Guided Filtering"
// https://pdfs.semanticscholar.org/a81a/4eed7f303f7e7f3ca1914ccab66351ce662b.pdf
//
// "Edge-Avoiding ?-Trous Wavelet Transform for fast Global Illumination Filtering"
// https://jo.dreggn.org/home/2010_atrous.pdf
//



void main() {
	ivec2 res = ivec2(imageSize(src_color_noisy));
	ivec2 pix = ivec2(gl_GlobalInvocationID);

	if (any(greaterThanEqual(pix, res))) {
		return;
	}
	
	const vec4 center_irradiance = imageLoad(src_color_noisy, pix);
	const float center_luminance = luminance(center_irradiance.rgb);
	const float reproject_variance = imageLoad(src_variance, pix).r;
	const vec4 material_rmxx = imageLoad(src_material_rmxx, pix);
	//const vec3 center_irradiance = imageLoad(src_color_noisy, pix).rgb;
	const float depth = imageLoad(src_position_depth, pix).w;
	const vec2 depth_offset = vec2(1.);
	//const float reproject_variance = 1.0; // need to calculate in reprojection
	//const float phi = PHI_COLOR * sqrt(max(0.0, 0.0001 + reproject_variance));

	vec3 geometry_normal, shading_normal;
	readNormals(pix, geometry_normal, shading_normal);

	int texel_flags = int(material_rmxx.b + 0.01);
	ivec3 pix_no_checker = CheckerboardToPix(pix, res);
	int is_transparent_texel = pix_no_checker.z;

	// depth-gradient estimation from screen-space derivatives
//	const vec2 depth_gradient = depthGradient(depth, pix, res);

	const float kernel[2][2] = {
        { 1.0 / 4.0, 1.0 / 8.0  },
        { 1.0 / 8.0, 1.0 / 16.0 }
    };

//	float variance = 0.; // default value
//	{
//		const float sigma = KERNEL_SIZE / 2.;
//		vec2 sigma_variance = vec2(0.0, 0.0);
//		float weight_sum = 0.;
//		for (int x = -KERNEL_SIZE; x <= KERNEL_SIZE; ++x) {
//			for (int y = -KERNEL_SIZE; y <= KERNEL_SIZE; ++y) {
//				const ivec2 p = pix + ivec2(x, y) * SVGF_STEP_SIZE;
//				if (any(greaterThanEqual(p, res)) || any(lessThan(p, ivec2(0)))) {
//					continue;
//				}
//
//				float weight = kernel[abs(x)][abs(y)];
//				//const float weight = normpdf(x, sigma) * normpdf(y, sigma);
//				//const float weight = 1.;
//
//				const vec3 current_irradiance = imageLoad(src_color_noisy, p).rgb;
//				float current_luminance = luminance(current_irradiance);
//				sigma_variance += vec2(current_luminance, current_luminance * current_luminance ) * weight;
//				weight_sum += weight;
//			}
//		}
//
//		if (weight_sum > 0.) {
//			sigma_variance /= weight_sum;
//			variance = max(0.0, sigma_variance.y - sigma_variance.x * sigma_variance.x);
//		}
//	}

	vec3 irradiance = vec3(0.);
	float weight_sum = 0.;
	const float sigma = KERNEL_SIZE / 2.;
	for (int x = -KERNEL_SIZE; x <= KERNEL_SIZE; ++x) {
		for (int y = -KERNEL_SIZE; y <= KERNEL_SIZE; ++y) {
			const ivec2 offset = ivec2(x, y) * SVGF_STEP_SIZE;
			const ivec2 p = texel_flags > 0 ? (pix + offset) : // transparent or refract, use checkerboard coords
							PixToCheckerboard(pix_no_checker.xy + offset, res, is_transparent_texel).xy;
			if (any(greaterThanEqual(p, res)) || any(lessThan(p, ivec2(0)))) {
				continue;
			}

			const vec3 current_irradiance = imageLoad(src_color_noisy, p).rgb;
			const float depth_current = imageLoad(src_position_depth, p).w;

			//float weight = normpdf(x, sigma) * normpdf(y, sigma);
			float weight = kernel[abs(x)][abs(y)];

			// combine the weights from above
		#ifdef DRIVEN_BY_NORMALS
			vec3 current_geometry_normal, current_shading_normal;
			readNormals(p, current_geometry_normal, current_shading_normal);
			weight *= normalWeight(shading_normal, current_shading_normal);
		#endif

		#ifdef DRIVEN_BY_DEPTH
			weight *= depth_edge_stopping_weight(depth, depth_current, DEPTH_FACTOR);
//			weight *= depthWeight(depth, depth_current, depth_gradient, depth_offset);
		#endif
//
		#ifdef DRIVEN_BY_VARIANCE
			const float current_luminance = luminance(current_irradiance);
			//weight *= luma_edge_stopping_weight(center_luminance, current_luminance, phi);
			weight *= luminanceWeight(center_luminance, current_luminance, reproject_variance);
		#endif
//
//		#ifdef DRIVEN_BY_RAY_LENGTH
//			//// TODO: release this for specular
//			//const vec4 current_refl_ray_length = depth_current + imageLoad(src_refl_position_t, p).w;
//			//weight *= rayLengthWeight(current_refl_ray_length, refl_ray_length); // is not implemented now
//		#endif

			//weight = max(0., weight) * filterKernel[(x + 1) + (y + 1) * 3];
			weight = max(0., weight);

			//float weightDepth = abs(curDepth - depth.x) / (depth.y * length(float2(xx, yy)) + 1.0e-2);
			//float weightNormal = pow(max(0, dot(curNormal, normal)), 128.0);

			//float w = exp(-weightDepth) * weightNormal;

			// add to total irradiance
			irradiance += current_irradiance * weight;
			weight_sum += weight;
		}
	}

	if (weight_sum > 0.) {
		irradiance /= weight_sum;
	}

	imageStore(src_color_filtered, pix, vec4(irradiance, center_irradiance.w));
}


