#extension GL_EXT_control_flow_attributes : require
#extension GL_EXT_ray_tracing: require

#include "utils.glsl"
#include "noise.glsl"
#include "denoiser_tools.glsl"
#include "color_spaces.glsl"
#include "denoiser_tools.glsl"

#define EMISSIVE_TRESHOLD 0.1

#define FOUR_SAMPLES_PER_TEXEL 1

//#define REMOVE_SPECULAR 1

// minimal random weight of light
#define PROBABILITY_EPS 0.02

// same to LIGHTS_WEIGHTS_DOWNSAMPLE_RES in lights choose shader
#define LIGHTS_WEIGHTS_DOWNSAMPLE_RES 2

// 1.5 * 1.5
#define MAGNITUDE_SQR_TRESHOLD 2.25

#define GLSL
#include "ray_interop.h"
#undef GLSL

layout(set = 0, binding = 10, rgba32f) uniform readonly image2D src_first_position_t;
layout(set = 0, binding = 11, rgba32f) uniform readonly image2D src_position_t;
layout(set = 0, binding = 12, rgba16f) uniform readonly image2D src_normals_gs;
layout(set = 0, binding = 13, rgba8) uniform readonly image2D src_material_rmxx;
layout(set = 0, binding = 14, rgba8) uniform readonly image2D src_base_color_a;
layout(set = 0, binding = 15, rgba8) uniform readonly image2D src_first_material_rmxx;
layout(set = 0, binding = 16, rgba16f) uniform readonly image2D src_poly_light_chosen;

#define X(index, name, format) layout(set=0,binding=index,format) uniform writeonly image2D out_image_##name;
OUTPUTS(X)
#undef X

layout(set = 0, binding = 1) uniform accelerationStructureEXT tlas;
layout(set = 0, binding = 2) uniform UBO { UniformBuffer ubo; };

#include "ray_kusochki.glsl"

#define RAY_TRACE
#define RAY_TRACE2
#undef SHADER_OFFSET_HIT_SHADOW_BASE
#define SHADER_OFFSET_HIT_SHADOW_BASE 0
#undef SHADER_OFFSET_MISS_SHADOW
#define SHADER_OFFSET_MISS_SHADOW 0
#undef PAYLOAD_LOCATION_SHADOW
#define PAYLOAD_LOCATION_SHADOW 0

#define BINDING_LIGHTS 7
#define BINDING_LIGHT_CLUSTERS 8
#include "light.glsl"

void readNormals(ivec2 uv, out vec3 geometry_normal, out vec3 shading_normal) {
	const vec4 n = imageLoad(src_normals_gs, uv);
	geometry_normal = normalDecode(n.xy);
	shading_normal = normalDecode(n.zw);
}

void main() {
	const ivec2 pix = ivec2(gl_LaunchIDEXT.xy);
	const ivec2 res = ivec2(gl_LaunchSizeEXT.xy);
	rand01_state = ubo.random_seed + gl_LaunchIDEXT.x * 1833 +  gl_LaunchIDEXT.y * 31337;

	vec3 geometry_normal, shading_normal;
	readNormals(pix, geometry_normal, shading_normal);

	const vec3 origin = (ubo.inv_view * vec4(0, 0, 0, 1)).xyz;
	const vec3 position = imageLoad(src_position_t, pix).xyz + geometry_normal * 0.1;
	const vec3 primary_position = imageLoad(src_first_position_t, pix).xyz;
	const vec3 direction = normalize(primary_position - origin);

#if PRIMARY_VIEW
	const vec3 V = normalize(origin - primary_position);
#else
	const vec3 V = normalize(primary_position - position);
#endif

	ivec3 pix_src = CheckerboardToPix(pix, res);
	int is_transparent_texel = pix_src.b;
	const vec2 uv = PixToUV(pix_src.xy, res);

	vec3 diffuse = vec3(0.), specular = vec3(0.);

	const vec4 material_rmxx = imageLoad(src_material_rmxx, pix);
	const vec3 base_color = SRGBtoLINEAR(imageLoad(src_base_color_a, pix).rgb);
	const vec4 first_material_rmxx = imageLoad(src_first_material_rmxx, pix);

#ifdef REFLECTIONS
#ifndef LIGHT_POINT
	// in large roughness reflection swapped by gi, skip calculations for poly lights
	if (first_material_rmxx.r > .6) {
		imageStore(out_image_light_poly_reflection, pix, vec4(0.));
	}
#endif
#endif

	MaterialProperties material;
	
#ifdef GRAY_MATERIAL
	material.baseColor = vec3(1.);
#else
	material.baseColor = base_color;
#endif
#ifdef GLOBAL_ILLUMINATION
	material.metalness = 0.;
	material.roughness = 1.;
#else
	material.metalness = material_rmxx.g;
	material.roughness = material_rmxx.r;
#endif
	material.emissive = vec3(0.f);	


#ifdef LIGHTS_WEIGHTS_DOWNSAMPLE_RES
	const ivec2 downsampled_pix = (pix / LIGHTS_WEIGHTS_DOWNSAMPLE_RES) * LIGHTS_WEIGHTS_DOWNSAMPLE_RES;
	ivec2 choose_pix = downsampled_pix;

	{
		float better_normal_dot = -1.;
		vec4 better_position_magnitude_sqr = vec4(1000.);
		vec4 choose_positions_magnitudes[4];
		const ivec2 choose_pix_neighboors[4] = {	downsampled_pix,
													downsampled_pix + ivec2(1, 0) * LIGHTS_WEIGHTS_DOWNSAMPLE_RES,
													downsampled_pix + ivec2(1, 1) * LIGHTS_WEIGHTS_DOWNSAMPLE_RES,
													downsampled_pix + ivec2(0, 1) * LIGHTS_WEIGHTS_DOWNSAMPLE_RES	};

		for(int i = 0; i < 4; i++) {
			const ivec2 p = choose_pix_neighboors[i];

			if (any(greaterThanEqual(p, res)))
				continue;

			choose_positions_magnitudes[i] = imageLoad(src_position_t, p);

			const vec3 offset = choose_positions_magnitudes[i].xyz - position;
			const float magnitude_sqr = dot(offset, offset);
			choose_positions_magnitudes[i].w = magnitude_sqr;

			if (magnitude_sqr < better_position_magnitude_sqr.w)
				better_position_magnitude_sqr = choose_positions_magnitudes[i];
		}

		const float magnitude_sqr_treshold = better_position_magnitude_sqr.w * MAGNITUDE_SQR_TRESHOLD;

		for(int i = 0; i < 4; i++) {
			const ivec2 p = choose_pix_neighboors[i];

			if (any(greaterThanEqual(p, res)))
				continue;

			if (choose_positions_magnitudes[i].w > magnitude_sqr_treshold)
				continue;

			const vec3 current_normal = normalDecode(imageLoad(src_normals_gs, p).zw);
			const float current_normal_dot = dot(shading_normal, current_normal);

			if (current_normal_dot < better_normal_dot)
				continue;

			better_normal_dot = current_normal_dot;
			choose_pix = p;
		}
	}
#else // ifndef LIGHTS_WEIGHTS_DOWNSAMPLE_RES
	const ivec2 choose_pix = pix;
#endif // ifndef LIGHTS_WEIGHTS_DOWNSAMPLE_RES

	const vec4 indices_vec = imageLoad(src_poly_light_chosen, choose_pix);
	float indices_probability[4] = { indices_vec.x, indices_vec.y, indices_vec.z, indices_vec.w };

	const SampleContext ctx = buildSampleContext( position + geometry_normal*.001, shading_normal, V );

	float samples_count = 0.;
	for (int i = 0; i < 4; i++) {
		const int index = int(indices_probability[i]);
		const float probability = indices_probability[i] - float(index);

		if (index < 0 || index >= lights.num_polygons || probability < PROBABILITY_EPS) continue;

		const PolygonLight poly = lights.polygons[index];

		vec3 current_diffuse, current_specular;
		sampleSinglePolygonLight( position + geometry_normal * .001,
									shading_normal, V, ctx, material, poly, current_diffuse, current_specular);

		const float probability_weight = 1. / probability;
		diffuse += current_diffuse;
		specular += current_specular;
		samples_count += 1.;
	}

	if (samples_count > 0.) {
		diffuse *= 0.04 / samples_count;
		specular *= 0.04 / samples_count;
	}

#if GLOBAL_ILLUMINATION
//	#if LIGHT_POINT
//		imageStore(out_image_light_point_indirect, pix, vec4(specular + diffuse, 0.));
//	#else
		imageStore(out_image_light_poly_indirect, pix, vec4(specular + diffuse, 0.));
//	#endif
#elif REFLECTIONS
//	#if LIGHT_POINT
//		imageStore(out_image_light_point_reflection, pix, vec4(diffuse + specular, 0.));
//	#else
		imageStore(out_image_light_poly_reflection, pix, vec4(diffuse + specular, 0.));
//	#endif
#else // direct lighting
//	#if LIGHT_POINT
//		imageStore(out_image_light_point_diffuse, pix, vec4(diffuse, 0.));
//		imageStore(out_image_light_point_specular, pix, vec4(specular, 0.));
//	#else
		imageStore(out_image_light_poly_diffuse, pix, vec4(diffuse, 0.));
		imageStore(out_image_light_poly_specular, pix, vec4(specular, 0.));
//	#endif
#endif
}
