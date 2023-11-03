#include "utils.glsl"
#include "noise.glsl"
#include "lk_dnsr_utils.glsl"
#include "color_spaces.glsl"

#define GLSL
#include "ray_interop.h"
#undef GLSL

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 10, rgba32f) uniform readonly image2D SRC_FIRST_POSITION;
layout(set = 0, binding = 11, rgba32f) uniform readonly image2D SRC_POSITION;
layout(set = 0, binding = 12, rgba16f) uniform readonly image2D SRC_NORMALS;
layout(set = 0, binding = 13, rgba8) uniform readonly image2D SRC_MATERIAL;
layout(set = 0, binding = 14, rgba8) uniform readonly image2D SRC_BASE_COLOR;

#if OUT_SEPARATELY
	layout(set=0, binding=20, rgba16f) uniform writeonly image2D OUT_DIFFUSE;
	layout(set=0, binding=21, rgba16f) uniform writeonly image2D OUT_SPECULAR;
#else
	layout(set=0, binding=20, rgba16f) uniform writeonly image2D OUT_LIGHTING;
#endif

layout(set = 0, binding = 1) uniform accelerationStructureEXT tlas;
layout(set = 0, binding = 2) uniform UBO { UniformBuffer ubo; } ubo;

#include "ray_kusochki.glsl"

#undef SHADER_OFFSET_HIT_SHADOW_BASE
#define SHADER_OFFSET_HIT_SHADOW_BASE 0
#undef SHADER_OFFSET_MISS_SHADOW
#define SHADER_OFFSET_MISS_SHADOW 0
#undef PAYLOAD_LOCATION_SHADOW
#define PAYLOAD_LOCATION_SHADOW 0

#define BINDING_LIGHTS 7
#define BINDING_LIGHT_CLUSTERS 8
#include "lk_dnsr_light.glsl"

void readNormals(ivec2 uv, out vec3 geometry_normal, out vec3 shading_normal) {
	const vec4 n = FIX_NAN(imageLoad(SRC_NORMALS, uv));
	geometry_normal = normalDecode(n.xy);
	shading_normal = normalDecode(n.zw);
}

void main() {
	const ivec2 pix = ivec2(gl_GlobalInvocationID);
	const ivec2 res = ivec2(imageSize(SRC_MATERIAL));
	rand01_state = ubo.ubo.random_seed + pix.x * 1833 + pix.y * 31337;
	
	// FIXME incorrect for reflection/refraction
	const ivec3 pix_src = CheckerboardToPix(pix, res);
	const vec2 uv = PixToUV(pix_src.xy, res);
	const vec4 target    = ubo.ubo.inv_proj * vec4(uv.x, uv.y, 1, 1);
	const vec3 direction = normalize((ubo.ubo.inv_view * vec4(target.xyz, 0)).xyz);

	vec3 diffuse = vec3(0.), specular = vec3(0.);


	const vec4 material_data = FIX_NAN(imageLoad(SRC_MATERIAL, pix));
	const vec3 base_color_a = SRGBtoLINEAR(FIX_NAN(imageLoad(SRC_BASE_COLOR, pix)).rgb);

	MaterialProperties material;
	
#ifdef GRAY_MATERIAL
	material.baseColor = vec3(1.);
#else
	material.baseColor = base_color_a;
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

	const vec3 pos = FIX_NAN(imageLoad(SRC_POSITION, pix)).xyz + geometry_normal * 0.1;


	/*
#if REUSE_SCREEN_LIGHTING

	// Try to use SSR and put this UV to output texture if all is OK
	uint lighting_is_reused = 0;
	const vec3 origin = (ubo.ubo.inv_view * vec4(0, 0, 0, 1)).xyz;

	// can we see it in reflection?
	if (dot(direction, pos - origin) > .0) {
		const ivec2 res = ivec2(imageSize(SRC_FIRST_POSITION));
		const vec2 first_uv = WorldPositionToUV(pos, inverse(ubo.ubo.inv_proj), inverse(ubo.ubo.inv_view));
		const ivec2 first_pix = UVToPix(first_uv, res);

		if (any(greaterThanEqual(first_pix, ivec2(0))) && any(lessThan(first_pix, res))) {
	
			const vec3 first_pos = FIX_NAN(imageLoad(SRC_FIRST_POSITION, first_pix)).xyz;

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
		material.baseColor = base_color_a; // mix lighting with base color if it's not SSR
	#endif
#else*/
	{
//#endif // REUSE_SCREEN_LIGHTING

#if PRIMARY_VIEW
		const vec3 V = -direction;
#else
		const vec3 primary_pos = FIX_NAN(imageLoad(SRC_FIRST_POSITION, pix)).xyz;
		const vec3 V = normalize(primary_pos - pos);
#endif

		const vec3 throughput = vec3(1.);
		computeLighting(pos + geometry_normal * .001, shading_normal, throughput, -direction, material, diffuse, specular);

		diffuse = max(vec3(0.),normalize(V));
		specular = vec3(0.);

	// NightFox's corrections for compensation of difference between baked and realtime lightings
//#if LIGHT_POINT
//		diffuse *= 0.25;
//		specular *= 0.25;
//#else
//		diffuse *= 0.04;
//		specular *= 0.04;
//#endif

	}

#if OUT_SEPARATELY
	imageStore(OUT_DIFFUSE, pix, vec4(diffuse, 0.));
	imageStore(OUT_SPECULAR, pix, vec4(specular, 0.));
#else
	imageStore(OUT_LIGHTING, pix, vec4(diffuse + specular, 0.));
#endif
}
