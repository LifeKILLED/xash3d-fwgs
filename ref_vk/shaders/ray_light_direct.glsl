#extension GL_EXT_control_flow_attributes : require
#extension GL_EXT_ray_tracing: require

#include "utils.glsl"
#include "noise.glsl"

#define GLSL
#include "ray_interop.h"
#undef GLSL

layout(set = 0, binding = 10, rgba32f) uniform readonly image2D first_position_t;
layout(set = 0, binding = 11, rgba32f) uniform readonly image2D position_t;
layout(set = 0, binding = 12, rgba16f) uniform readonly image2D normals_gs;
layout(set = 0, binding = 13, rgba8) uniform readonly image2D material_rmxx;
layout(set = 0, binding = 14, rgba8) uniform readonly image2D base_color_a;

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
	const vec4 n = imageLoad(normals_gs, uv);
	geometry_normal = normalDecode(n.xy);
	shading_normal = normalDecode(n.zw);
}

#if REUSE_SCREEN_LIGHTING

vec3 OriginWorldPosition(mat4 inv_view) {
	return (inv_view * vec4(0, 0, 0, 1)).xyz;
}


vec3 ScreenToWorldDirection(vec2 uv, mat4 inv_view, mat4 inv_proj) {
	vec4 target    = inv_proj * vec4(uv.x, uv.y, 1, 1);
	vec3 direction = (inv_view * vec4(normalize(target.xyz), 0)).xyz;
	return normalize(direction);
}


vec3 WorldPositionFromDirection(vec3 origin, vec3 direction, float depth) {
	return origin + normalize(direction) * depth;
}

vec3 FarPlaneDirectedVector(vec2 uv, vec3 forward, mat4 inv_view, mat4 inv_proj) {
	vec3 dir = ScreenToWorldDirection(uv, inv_view, inv_proj);
	float plane_length = dot(forward, dir);
	return dir / max(0.001, plane_length);
}

vec2 WorldPositionToUV(vec3 position, mat4 proj, mat4 view) {
	vec4 clip_space = proj * (view * vec4(position, 1.));
	return clip_space.xy / clip_space.w;
}

ivec2 UVToPix(vec2 uv, ivec2 res) {
	vec2 screen_uv = uv * 0.5 + vec2(0.5);
	return ivec2(screen_uv.x * float(res.x), screen_uv.y * float(res.y));
}

#endif // REUSE_SCREEN_LIGHTING

void main() {
	const vec2 uv = (gl_LaunchIDEXT.xy + .5) / gl_LaunchSizeEXT.xy * 2. - 1.;
	const ivec2 pix = ivec2(gl_LaunchIDEXT.xy);
	
	rand01_state = ubo.random_seed + gl_LaunchIDEXT.x * 1833 +  gl_LaunchIDEXT.y * 31337;

	// FIXME incorrect for reflection/refraction
	const vec4 target    = ubo.inv_proj * vec4(uv.x, uv.y, 1, 1);
	const vec3 direction = normalize((ubo.inv_view * vec4(target.xyz, 0)).xyz);

	const vec4 material_data = imageLoad(material_rmxx, pix);

	MaterialProperties material;
	
#ifdef GRAY_MATERIAL
	material.baseColor = vec3(0.1);
#else
	material.baseColor = imageLoad(base_color_a, pix).rgb;
#endif
	material.emissive = vec3(0.f);
	material.metalness = material_data.g;
	material.roughness = material_data.r;

	const vec3 pos = imageLoad(position_t, pix).xyz;

	vec3 diffuse = vec3(0.), specular = vec3(0.);

#if REUSE_SCREEN_LIGHTING

	// Try to use SSR and put this UV to output texture if all is OK
	uint lighting_is_reused = 0;
	const ivec2 res = ivec2(imageSize(first_position_t));
	const vec2 first_uv = WorldPositionToUV(pos, inverse(ubo.inv_proj), inverse(ubo.inv_view));
	const ivec2 first_pix = UVToPix(first_uv, res);

	if (any(greaterThanEqual(first_pix, ivec2(0))) && any(lessThan(first_pix, res))) {
	
		const vec3 first_pos = imageLoad(first_position_t, first_pix).xyz;
		const vec3 origin = (ubo.inv_view * vec4(0, 0, 0, 1)).xyz;

		// Can we see this texel from camera?
		const float frunsum_theshold = 0.25;
		if (dot(direction, pos - origin) > frunsum_theshold ) {

			const float nessesary_depth = length(origin - pos);
			const float current_depth = length(origin - first_pos);

			if (abs(nessesary_depth - current_depth) < 1.) {
				lighting_is_reused = 1;
				diffuse = vec3(first_uv, -100.); // -100 it's SSR marker
			}
		}
	}

	if (lighting_is_reused == 0) {
#else
	{
#endif // REUSE_SCREEN_LIGHTING

		vec3 geometry_normal, shading_normal;
		readNormals(pix, geometry_normal, shading_normal);

		const vec3 throughput = vec3(1.);

#if PRIMARY_VIEW
		const vec3 V = -direction;
#else
		const vec3 primary_pos = imageLoad(first_position_t, pix).xyz;
		const vec3 V = normalize(primary_pos - pos);
#endif

		computeLighting(pos + geometry_normal * .001, shading_normal, throughput, V, material, diffuse, specular);

	}

#if GLOBAL_ILLUMINATION
#if LIGHT_POINT
	imageStore(out_image_light_point_indirect, pix, vec4(specular + diffuse, 0.));
#else
	imageStore(out_image_light_poly_indirect, pix, vec4(specular + diffuse, 0.));
#endif
#elif REFLECTIONS
#if LIGHT_POINT
	imageStore(out_image_light_point_reflection, pix, vec4(specular + diffuse, 0.));
#else
	imageStore(out_image_light_poly_reflection, pix, vec4(specular + diffuse, 0.));
#endif
#else
#if LIGHT_POINT
	imageStore(out_image_light_point_diffuse, pix, vec4(diffuse, 0.));
	imageStore(out_image_light_point_specular, pix, vec4(specular, 0.));
#else
	imageStore(out_image_light_poly_diffuse, pix, vec4(diffuse, 0.));
	imageStore(out_image_light_poly_specular, pix, vec4(specular, 0.));
#endif
#endif
}
