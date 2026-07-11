#include "utils.glsl"
#include "noise.glsl"

#include "ray_kusochki.glsl"
#include "color_spaces.glsl"

#include "light_ris.glsl"

void main() {
#ifdef RAY_QUERY
	const ivec2 ris_pix = ivec2(gl_GlobalInvocationID.xy);
	if (risInitWorkgroupOutsideBounds()) {
		return;
	}
	ivec2 pix;
	const bool surface_selected = risSelectReservoirSurfacePixel(ris_pix, pix);
	const ivec2 res = ubo.ubo.res;
	const bool in_bounds = surface_selected;
	const vec2 uv = in_bounds ? ((vec2(pix) + vec2(0.5)) / vec2(res) * 2.0 - 1.0) : vec2(0.0);
#else
#error RIS direct lighting init currently expects RAY_QUERY compute dispatch.
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
				surface_active = surface_selected;
		}
	}

	const vec3 P = surface_active ? pos_t.xyz + geometry_normal * 0.001 : vec3(0.0);
	computeLightingRISInit(P, geometry_normal, shading_normal, -direction, material, ris_pix, pix, surface_active);
}
