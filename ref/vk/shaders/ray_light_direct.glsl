#include "utils.glsl"
#include "noise.glsl"

#include "ray_kusochki.glsl"
#include "color_spaces.glsl"

#ifdef HEITZ_SHADOWS
layout(set = 0, binding = 35) uniform sampler3D blue_noise_texture;
#include "bluenoise.glsl"
// Shared by every light, independent of cluster order and early light culling.
vec4 heitz_light_random = vec4(0.5);
#endif

#include "light.glsl"

void readNormals(ivec2 uv, out vec3 geometry_normal, out vec3 shading_normal) {
	const vec4 n = imageLoad(normals_gs, uv);
	geometry_normal = normalDecode(n.xy);
	shading_normal = normalDecode(n.zw);
}

void main() {
#ifdef RAY_TRACE
	const vec2 uv = (gl_LaunchIDEXT.xy + .5) / gl_LaunchSizeEXT.xy * 2. - 1.;
	const ivec2 pix = ivec2(gl_LaunchIDEXT.xy);
#elif defined(RAY_QUERY)
	const ivec2 pix = ivec2(gl_GlobalInvocationID);
	const ivec2 res = ubo.ubo.res;
	if (any(greaterThanEqual(pix, res))) {
		return;
	}
	const vec2 uv = (gl_GlobalInvocationID.xy + .5) / res * 2. - 1.;
#else
#error You have two choices here. Ray trace, or Rake Yuri. So what it's gonna be, huh? Choose wisely.
#endif

	rand01_state = ubo.ubo.random_seed + pix.x * 1833 + pix.y * 31337;
#ifdef HEITZ_SHADOWS
	// One nearest-neighbor fetch per pixel in each direct-light dispatch. Both
	// dispatches read the same texel; there are no per-light hashes or shifts.
	// Decode UNORM8 to bin centers so no variate is exactly zero or one.
	const vec4 noise = blueNoise(ivec3(pix, int(ubo.ubo.frame_counter % BLUE_NOISE_SIZE)));
	heitz_light_random = (noise * 255.0 + 0.5) / 256.0;
#endif

	// FIXME incorrect for reflection/refraction
	const vec4 target    = ubo.ubo.inv_proj * vec4(uv.x, uv.y, 1, 1);
	const vec3 direction = normalize((ubo.ubo.inv_view * vec4(target.xyz, 0)).xyz);

	const vec4 material_data = imageLoad(material_rmxx, pix);

	MaterialProperties material;
	material.base_color = SRGBtoLINEAR(imageLoad(base_color_a, pix).rgb);
	material.metalness = material_data.g;
	material.roughness = material_data.r;

#ifdef BRDF_COMPARE
	g_mat_gltf2 = pix.x > ubo.ubo.res.x / 2.;
#endif

	const vec4 pos_t = imageLoad(position_t, pix);

	vec3 diffuse = vec3(0.), specular = vec3(0.);

	if (pos_t.w > 0.) {
		const vec4 packed_normal = imageLoad(normals_gs, pix);
		const vec3 geometry_normal = normalDecode(packed_normal.xy);
		const vec3 shading_normal = normalDecode(packed_normal.zw);
#ifdef DEBUG_VALIDATE_EXTRA
		if (IS_INVALIDV(pos_t.xyz) || IS_INVALIDV(geometry_normal)) {
			debugPrintfEXT("ray_light_direct.glsl:%d INVALID pos_t.xyz=(%f,%f,%f) geometry_normal=(%f,%f,%f) packed_normal=(%f,%f,%f,%f)",
				__LINE__, PRIVEC3(pos_t.xyz), PRIVEC3(geometry_normal), PRIVEC4(packed_normal));
		} else
#endif
		computeLighting(pos_t.xyz + geometry_normal * .001, shading_normal, -direction, material, diffuse, specular);
	}

	DEBUG_VALIDATE_RANGE_VEC3("direct.diffuse", diffuse, 0., 1e6);
	DEBUG_VALIDATE_RANGE_VEC3("direct.specular", specular, 0., 1e6);

#if LIGHT_POINT
#ifdef HEITZ_SHADOWS
	imageStore(out_heitz_point_analytic_diffuse, pix, vec4(heitz_analytic_diffuse, 0.0));
	imageStore(out_heitz_point_analytic_specular, pix, vec4(heitz_analytic_specular, 0.0));
	imageStore(out_heitz_point_unshadowed_diffuse, pix, vec4(heitz_unshadowed_diffuse, 0.0));
	imageStore(out_heitz_point_unshadowed_specular, pix, vec4(heitz_unshadowed_specular, 0.0));
#endif
	imageStore(out_light_point_diffuse, pix, vec4(diffuse, 0.f));
	imageStore(out_light_point_specular, pix, vec4(specular, 0.f));
#endif

#if LIGHT_POLYGON
#ifdef HEITZ_SHADOWS
	imageStore(out_heitz_poly_analytic_diffuse, pix, vec4(heitz_analytic_diffuse, 0.0));
	imageStore(out_heitz_poly_analytic_specular, pix, vec4(heitz_analytic_specular, 0.0));
	imageStore(out_heitz_poly_unshadowed_diffuse, pix, vec4(heitz_unshadowed_diffuse, 0.0));
	imageStore(out_heitz_poly_unshadowed_specular, pix, vec4(heitz_unshadowed_specular, 0.0));
#endif
	imageStore(out_light_poly_diffuse, pix, vec4(diffuse, 0.f));
	imageStore(out_light_poly_specular, pix, vec4(specular, 0.f));
#endif
}
