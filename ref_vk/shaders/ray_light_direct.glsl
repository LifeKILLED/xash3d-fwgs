#extension GL_EXT_control_flow_attributes : require
#extension GL_EXT_ray_tracing: require

#include "utils.glsl"
#include "noise.glsl"
#include "denoiser_tools.glsl"
#include "color_spaces.glsl"
#include "denoiser_tools.glsl"

#define EMISSIVE_TRESHOLD 0.1

#define GLSL
#include "ray_interop.h"
#undef GLSL

layout(set = 0, binding = 10, rgba32f) uniform readonly image2D src_first_position_t;
layout(set = 0, binding = 11, rgba32f) uniform readonly image2D src_position_t;
layout(set = 0, binding = 12, rgba16f) uniform readonly image2D src_normals_gs;
layout(set = 0, binding = 13, rgba8) uniform readonly image2D src_material_rmxx;
layout(set = 0, binding = 14, rgba8) uniform readonly image2D src_base_color_a;
layout(set = 0, binding = 15, rgba16f) uniform readonly image2D src_motion_offsets_uvs;

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

#ifdef REFLECTIONS
#ifndef LIGHT_POINT
	// in large roughness reflection swapped by gi, skip calculations for poly lights
	if (material_rmxx.r > .6) {
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


#ifdef REUSE_SCREEN_LIGHTING

	// Try to use SSR and put this UV to output texture if all is OK
	uint lighting_is_reused = 0;
	const float nessesary_depth = length(origin - position);

	// can we see it in reflection?
	if (dot(direction, position - origin) > .0) {
		const vec2 reuse_uv_src = WorldPositionToUV(position, inverse(ubo.inv_proj), inverse(ubo.inv_view));
		const ivec2 reuse_pix_src = UVToPix(reuse_uv_src, res);

		if (any(greaterThanEqual(reuse_pix_src, ivec2(0))) && any(lessThan(reuse_pix_src, res))) {

			ivec3 reuse_pix = PixToCheckerboard(reuse_pix_src, res, is_transparent_texel);
			
			const vec3 first_position = imageLoad(src_first_position_t, reuse_pix.xy).xyz;
			const float current_depth = length(origin - first_position);

			if (abs(nessesary_depth - current_depth) < 2.) {
				lighting_is_reused = 1;
				vec2 reuse_uv = PixToUV(reuse_pix.xy, res);
				diffuse = vec3(reuse_uv, -100.); // -100 it's SSR marker
			}
		}
	}

	if (lighting_is_reused != 1) {

	#if REFLECTIONS
		material.baseColor = base_color; // mix lighting with base color if it's not SSR
	#endif
#else
	{
#endif // REUSE_SCREEN_LIGHTING

		const vec3 throughput = vec3(1.);
		computeLighting(position + geometry_normal * .001, shading_normal, throughput, V, material, diffuse, specular);


		// add more samples where we are not found correct reprojecting
#ifdef ADD_SAMPLES_FOR_NOT_REPROJECTED
		const vec4 motion_offsets_uvs = imageLoad(src_motion_offsets_uvs, pix);
#ifdef REFLECTIONS
		if (motion_offsets_uvs.z < -99.) { // parallax reprojection for reflections
#else
		if (motion_offsets_uvs.x < -99.) { // simple reprojecting for diffuse and gi
#endif
			const float min_samples = 1 + ADD_SAMPLES_FOR_NOT_REPROJECTED;
			vec3 diffuse_additional, specular_additional;
			for(int i = 0; i < ADD_SAMPLES_FOR_NOT_REPROJECTED; ++i) {
				rand01_state += 1; // we need a new random seed for sampling more lights
				diffuse_additional = vec3(.0);
				specular_additional = vec3(.0);
				computeLighting(position + geometry_normal * .001, shading_normal, throughput, V, material, diffuse_additional, specular_additional);
				diffuse += diffuse_additional;
				specular += specular_additional;
			}
			diffuse /= min_samples;
			specular /= min_samples;
		}
#endif

		// correction for avoiding difference in sampling algorythms
#if LIGHT_POINT
		diffuse *= 0.25;
		specular *= 0.25;
#else
		diffuse *= 0.04;

		specular *= 0.04;
#endif

#ifdef IRRADIANCE_MULTIPLIER
	diffuse *= IRRADIANCE_MULTIPLIER;
	specular *= IRRADIANCE_MULTIPLIER;
#endif

	}

#if GLOBAL_ILLUMINATION
	#if LIGHT_POINT
		imageStore(out_image_light_point_indirect, pix, vec4(specular + diffuse, 0.));
	#else
		imageStore(out_image_light_poly_indirect, pix, vec4(specular + diffuse, 0.));
	#endif
#elif REFLECTIONS
	#if LIGHT_POINT
		imageStore(out_image_light_point_reflection, pix, vec4(diffuse + specular, 0.));
	#else
		imageStore(out_image_light_poly_reflection, pix, vec4(diffuse + specular, 0.));
	#endif
#else // direct lighting
	#if LIGHT_POINT
		imageStore(out_image_light_point_diffuse, pix, vec4(diffuse, 0.));
		imageStore(out_image_light_point_specular, pix, vec4(specular, 0.));
	#else
		imageStore(out_image_light_poly_diffuse, pix, vec4(diffuse, 0.));
		imageStore(out_image_light_poly_specular, pix, vec4(specular, 0.));
	#endif
#endif
}
