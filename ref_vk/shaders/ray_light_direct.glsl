#extension GL_EXT_control_flow_attributes : require
#extension GL_EXT_ray_tracing: require

#include "utils.glsl"
#include "noise.glsl"
#include "denoiser_tools.glsl"
#include "color_spaces.glsl"

#define EMISSIVE_TRESHOLD 0.1

#define GLSL
#include "ray_interop.h"
#undef GLSL

layout(set = 0, binding = 10, rgba32f) uniform readonly image2D src_first_position_t;
layout(set = 0, binding = 11, rgba32f) uniform readonly image2D src_position_t;
layout(set = 0, binding = 12, rgba16f) uniform readonly image2D src_normals_gs;
layout(set = 0, binding = 13, rgba8) uniform readonly image2D src_material_rmxx;
layout(set = 0, binding = 14, rgba8) uniform readonly image2D src_base_color_a;

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
	const vec2 uv_src = (gl_LaunchIDEXT.xy + .5) / gl_LaunchSizeEXT.xy * 2. - 1.;
	const ivec2 pix_src = ivec2(gl_LaunchIDEXT.xy);
	const ivec2 res = ivec2(gl_LaunchSizeEXT.xy);
	rand01_state = ubo.random_seed + gl_LaunchIDEXT.x * 1833 +  gl_LaunchIDEXT.y * 31337;

//#ifdef LIGHTS_REJECTION_X4
//	const ivec2 pattern_4x_res = ivec2(gl_LaunchSizeEXT.xy) / 2;
//	const ivec2 pix_segment_id = ivec2(step(pattern_4x_res.x, pix_src.x), step(pattern_4x_res.y, pix_src.y));
//	const uint pattern_texel_id = ((pix_segment_id.x + pix_segment_id.y * 2) /*+ rand01_state*/) % 4;
//#elif
	const ivec2 pix = pix_src;
	const uint pattern_texel_id = ((pix.x % 2 + (pix.y % 2) * 2)) % 4;
	const vec2 uv = uv_src;
//#endif


	// FIXME incorrect for reflection/refraction
	const vec4 target    = ubo.inv_proj * vec4(uv.x, uv.y, 1, 1);
	const vec3 direction = normalize((ubo.inv_view * vec4(target.xyz, 0)).xyz);

	vec3 diffuse = vec3(0.), specular = vec3(0.);


	const vec4 material_data = imageLoad(src_material_rmxx, pix);
	const vec3 base_color = SRGBtoLINEAR(imageLoad(src_base_color_a, pix).rgb);

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
	material.metalness = material_data.g;
	material.roughness = material_data.r;
#endif
	material.emissive = vec3(0.f);	

	vec3 geometry_normal, shading_normal;
	readNormals(pix, geometry_normal, shading_normal);

	const vec3 pos = imageLoad(src_position_t, pix).xyz + geometry_normal * 0.1;



#ifdef REUSE_SCREEN_LIGHTING

	// Try to use SSR and put this UV to output texture if all is OK
	uint lighting_is_reused = 0;
	const vec3 origin = (ubo.inv_view * vec4(0, 0, 0, 1)).xyz;

	// can we see it in reflection?
	if (dot(direction, pos - origin) > .0) {
		const ivec2 res = ivec2(imageSize(src_first_position_t));
		const vec2 first_uv = WorldPositionToUV(pos, inverse(ubo.inv_proj), inverse(ubo.inv_view));
		const ivec2 first_pix = UVToPix(first_uv, res);

		if (any(greaterThanEqual(first_pix, ivec2(0))) && any(lessThan(first_pix, res))) {
	
			const vec3 first_pos = imageLoad(src_first_position_t, first_pix).xyz;

			const float nessesary_depth = length(origin - pos);
			const float current_depth = length(origin - first_pos);

			if (abs(nessesary_depth - current_depth) < 2.) {
				lighting_is_reused = 1;
				diffuse = vec3(first_uv, -100.); // -100 it's SSR marker
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

#if PRIMARY_VIEW
		const vec3 V = -direction;
#else
		const vec3 primary_pos = imageLoad(src_first_position_t, pix).xyz;
		const vec3 V = normalize(primary_pos - pos);
#endif

//#if PRIMARY_VIEW // TEST!!! ONLY FIRST BOUNCE PROCESSING!!!

	//const vec3 emissive = imageLoad(src_emissive, pix).rgb;
	//if (any(lessThan(emissive, vec3(EMISSIVE_TRESHOLD)))) {
//#ifdef LIGHT_POLYGON
		const vec3 throughput = vec3(1.);
		computeLighting(pos + geometry_normal * .001, shading_normal, throughput, V, material, pattern_texel_id, diffuse, specular);
//#else
//		diffuse = vec3(0.0);
//		specular = vec3(0.0);
//#endif
	//}

//#if (LIGHT_POLYGON) && (PRIMARY_VIEW)
	//diffuse = vec3(0.);
	//specular = vec3(0.);
//#endif

//#endif


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

		//diffuse = clamp(diffuse, 0., 5.);
		//specular = clamp(specular, 0., 5.);
	}

	//diffuse += vec3(0., 0.2, 0.);

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
		imageStore(out_image_light_poly_reflection, pix_src, vec4(diffuse + specular, 0.));
	#endif
#else // direct lighting
	#if LIGHT_POINT
		imageStore(out_image_light_point_diffuse, pix, vec4(diffuse, 0.));
		imageStore(out_image_light_point_specular, pix, vec4(specular, 0.));
	#else
		imageStore(out_image_light_poly_diffuse, pix_src, vec4(diffuse, 0.));
		imageStore(out_image_light_poly_specular, pix_src, vec4(specular, 0.));
	#endif
#endif
}
