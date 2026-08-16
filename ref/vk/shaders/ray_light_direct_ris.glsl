#include "utils.glsl"
#include "noise.glsl"

#include "ray_kusochki.glsl"
#include "color_spaces.glsl"
#include "brdf.glsl"
#include "temporal_reservoir_rotation.glsl"

#ifndef RIS_DIRECT_DIFFUSE_SHADING_PERMUTATION
#define RIS_DIRECT_DIFFUSE_SHADING_PERMUTATION 0
#endif

#if RIS_DIRECT_DIFFUSE_SHADING_PERMUTATION
#ifndef RIS_DIRECT_DIFFUSE_SHADING_PERMUTATION_NORMAL_MIN
#define RIS_DIRECT_DIFFUSE_SHADING_PERMUTATION_NORMAL_MIN 0.90
#endif
#ifndef RIS_DIRECT_DIFFUSE_SHADING_PERMUTATION_RELATIVE_DEPTH_MAX
#define RIS_DIRECT_DIFFUSE_SHADING_PERMUTATION_RELATIVE_DEPTH_MAX 0.10
#endif

const uint RIS_DIRECT_DIFFUSE_SHADING_PERMUTATION_SALT = 0x6473706du;

// Frame-local, presentation-only permutation shared with the temporal
// reservoir experiments. A globally phased 2x2 grid chooses an independent
// H/V/diagonal pairing per cell, then each of the two pairs independently
// stays or swaps. No mapping from this stage is ever stored in history.
#ifndef RIS_DIRECT_DIFFUSE_SHADING_PERMUTATION_SWAP_PROBABILITY
#define RIS_DIRECT_DIFFUSE_SHADING_PERMUTATION_SWAP_PROBABILITY 0.75
#endif

ivec2 risDirectDiffuseRawShadingPartner(ivec2 pix, ivec2 res)
{
	const uint frame_seed = xxhash32(uvec4(
		ubo.ubo.frame_counter, ubo.ubo.random_seed,
		RIS_DIRECT_DIFFUSE_SHADING_PERMUTATION_SALT, 0x6672616du));
	return temporalReservoirPairPermutationPixel(
		pix, res, frame_seed, RIS_DIRECT_DIFFUSE_SHADING_PERMUTATION_SALT,
		float(RIS_DIRECT_DIFFUSE_SHADING_PERMUTATION_SWAP_PROBABILITY));
}

// Reject the whole pair symmetrically at obvious current-frame surface
// discontinuities. Because both endpoints evaluate the same predicate, this
// preserves the one-to-one mapping and cannot create write collisions.
bool risDirectDiffuseShadingPairCompatible(ivec2 a, ivec2 b)
{
	if (all(equal(a, b))) {
		return true;
	}

	const vec4 pa = imageLoad(position_t, a);
	const vec4 pb = imageLoad(position_t, b);
	if (pa.w <= 0.0 || pb.w <= 0.0) {
		return false;
	}

	const vec3 na = normalDecode(imageLoad(normals_gs, a).xy);
	const vec3 nb = normalDecode(imageLoad(normals_gs, b).xy);
	if (dot(na, nb) < float(RIS_DIRECT_DIFFUSE_SHADING_PERMUTATION_NORMAL_MIN)) {
		return false;
	}

	const float depth_scale = max(max(abs(pa.w), abs(pb.w)), 1e-4);
	const float relative_depth = abs(pa.w - pb.w) / depth_scale;
	return relative_depth <= float(RIS_DIRECT_DIFFUSE_SHADING_PERMUTATION_RELATIVE_DEPTH_MAX);
}

ivec2 risDirectDiffuseShadingPixel(ivec2 pix)
{
	const ivec2 res = ubo.ubo.res;
	const ivec2 partner = risDirectDiffuseRawShadingPartner(pix, res);
	return risDirectDiffuseShadingPairCompatible(pix, partner) ? partner : pix;
}

void risDirectDiffuseLoadShadingSurface(
	ivec2 source_pix,
	out ivec2 shading_pix,
	out vec3 P,
	out vec3 N,
	out vec3 V,
	out MaterialProperties material,
	out bool surface_active)
{
	shading_pix = source_pix;
	P = vec3(0.0);
	N = vec3(0.0, 0.0, 1.0);
	V = vec3(0.0, 0.0, 1.0);
	material.base_color = vec3(0.0);
	material.metalness = 0.0;
	material.roughness = 1.0;
	surface_active = false;

	const ivec2 res = ubo.ubo.res;
	if (any(lessThan(source_pix, ivec2(0))) || any(greaterThanEqual(source_pix, res))) {
		return;
	}

	shading_pix = risDirectDiffuseShadingPixel(source_pix);
	const vec4 pos_t = imageLoad(position_t, shading_pix);
	if (pos_t.w <= 0.0) {
		return;
	}

	const vec4 packed_normal = imageLoad(normals_gs, shading_pix);
	const vec3 geometry_normal = normalDecode(packed_normal.xy);
	N = normalDecode(packed_normal.zw);
	P = pos_t.xyz + geometry_normal * 0.001;

	const vec4 material_data = imageLoad(material_rmxx, shading_pix);
	material.base_color = SRGBtoLINEAR(imageLoad(base_color_a, shading_pix).rgb);
	material.metalness = material_data.g;
	material.roughness = material_data.r;

	const vec2 uv = (vec2(shading_pix) + vec2(0.5)) / vec2(res) * 2.0 - 1.0;
	const vec4 target = ubo.ubo.inv_proj * vec4(uv.x, uv.y, 1.0, 1.0);
	const vec3 direction = normalize((ubo.ubo.inv_view * vec4(target.xyz, 0.0)).xyz);
	V = -direction;
	surface_active = true;
}

#define RIS_DIRECT_DIFFUSE_LOAD_SHADING_SURFACE risDirectDiffuseLoadShadingSurface
#endif

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
#if RIS_DIRECT_DIFFUSE_SHADING_PERMUTATION
		const ivec2 diffuse_output_pix = risDirectDiffuseShadingPixel(pix);
#else
		const ivec2 diffuse_output_pix = pix;
#endif
		imageStore(out_light_point_diffuse, diffuse_output_pix, vec4(diffuse, 0.0));
		imageStore(out_light_point_specular, pix, vec4(specular, 0.0));
		imageStore(out_light_point_flashlight_diffuse, pix, vec4(flashlight_diffuse, 0.0));
		imageStore(out_light_point_flashlight_specular, pix, vec4(flashlight_specular, 0.0));
#endif

#if LIGHT_POLYGON
#if RIS_DIRECT_DIFFUSE_SHADING_PERMUTATION
		const ivec2 diffuse_output_pix = risDirectDiffuseShadingPixel(pix);
#else
		const ivec2 diffuse_output_pix = pix;
#endif
		imageStore(out_light_poly_diffuse, diffuse_output_pix, vec4(diffuse, 0.0));
		imageStore(out_light_poly_specular, pix, vec4(specular, 0.0));
#endif
	}
}
