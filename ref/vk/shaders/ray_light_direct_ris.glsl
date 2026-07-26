#include "utils.glsl"
#include "noise.glsl"

#include "ray_kusochki.glsl"
#include "color_spaces.glsl"

#ifndef RIS_INIT_PASS
#ifndef RIS_APPLY_PASS
#define RIS_APPLY_PASS 1
#endif
#endif

#include "light_ris.glsl"

void main() {
#ifdef RAY_QUERY
	const ivec2 pix = ivec2(gl_GlobalInvocationID.xy);
	const ivec2 res = ubo.ubo.res;
	const bool in_bounds = !any(greaterThanEqual(pix, res));
	const vec2 uv = in_bounds ? ((vec2(pix) + vec2(0.5)) / vec2(res) * 2.0 - 1.0) : vec2(0.0);
#else
#error RIS direct lighting currently expects RAY_QUERY compute dispatch.
#endif

	rand01_state = ubo.ubo.random_seed + uint(pix.x) * 1833u + uint(pix.y) * 31337u;

	const vec4 target = ubo.ubo.inv_proj * vec4(uv.x, uv.y, 1.0, 1.0);
	const vec3 direction = normalize((ubo.ubo.inv_view * vec4(target.xyz, 0.0)).xyz);

	MaterialProperties material;
	material.base_color = vec3(0.0);
	material.metalness = 0.0;
	material.roughness = 1.0;

	vec4 pos_t = vec4(0.0);
	vec3 geometry_normal = vec3(0.0, 0.0, 1.0);
	vec3 shading_normal = vec3(0.0, 0.0, 1.0);
	bool surface_active = false;

	if (in_bounds) {
		const vec4 material_data = imageLoad(material_rmxx, pix);
		material.base_color = SRGBtoLINEAR(imageLoad(base_color_a, pix).rgb);
		material.metalness = material_data.g;
		material.roughness = material_data.r;

#ifdef BRDF_COMPARE
		g_mat_gltf2 = pix.x > ubo.ubo.res.x / 2;
#endif

		pos_t = imageLoad(position_t, pix);
		if (pos_t.w > 0.0) {
			const vec4 packed_normal = imageLoad(normals_gs, pix);
			geometry_normal = normalDecode(packed_normal.xy);
			shading_normal = normalDecode(packed_normal.zw);
			surface_active = true;
		}
	}

	vec3 diffuse = vec3(0.0);
	vec3 specular = vec3(0.0);
	vec3 flashlight_diffuse = vec3(0.0);
	vec3 flashlight_specular = vec3(0.0);

	const vec3 P = surface_active ? pos_t.xyz + geometry_normal * 0.001 : vec3(0.0);
	computeLightingRISUnified(P, geometry_normal, shading_normal, -direction, material, pix, surface_active,
		diffuse, specular, flashlight_diffuse, flashlight_specular);

	DEBUG_VALIDATE_RANGE_VEC3("direct_ris.diffuse", diffuse, 0.0, 1e6);
	DEBUG_VALIDATE_RANGE_VEC3("direct_ris.specular", specular, 0.0, 1e6);

	if (in_bounds) {
#if LIGHT_POINT
		imageStore(out_light_point_diffuse, pix, vec4(diffuse, 0.0));
		imageStore(out_light_point_specular, pix, vec4(specular, 0.0));
		imageStore(out_light_point_flashlight_diffuse, pix, vec4(flashlight_diffuse, 0.0));
		imageStore(out_light_point_flashlight_specular, pix, vec4(flashlight_specular, 0.0));
#endif

#if LIGHT_POLYGON
		imageStore(out_light_poly_diffuse, pix, vec4(diffuse, 0.0));
		imageStore(out_light_poly_specular, pix, vec4(specular, 0.0));
#endif
	}
}
