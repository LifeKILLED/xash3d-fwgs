#ifndef REFRACTION_RIS_COMMON_GLSL_INCLUDED
#define REFRACTION_RIS_COMMON_GLSL_INCLUDED

#include "light_ris_experimental.glsl"
#include "utils.glsl"
#include "color_spaces.glsl"
#include "noise.glsl"
#include "brdf.glsl"

const uint REFRACTION_RIS_LAYER_0 = 0u;
const uint REFRACTION_RIS_LAYER_1 = 1u;
const uint REFRACTION_RIS_LAYER_2 = 2u;
const uint REFRACTION_RIS_LAYER_3 = 3u;
const uint REFRACTION_RIS_LAYER_COUNT = 4u;

#ifndef REFRACTION_RIS_HISTORY_DISTANCE_MAX
#define REFRACTION_RIS_HISTORY_DISTANCE_MAX 32.0
#endif

#ifndef REFRACTION_RIS_LIGHTING_NORMAL_OFFSET
#define REFRACTION_RIS_LIGHTING_NORMAL_OFFSET 0.01
#endif

#ifndef RIS_NORMAL_COMPATIBILITY_MIN
#define RIS_NORMAL_COMPATIBILITY_MIN 0.85
#endif

#define RIS_CUSTOM_SURFACE_COMPATIBILITY_WEIGHT 1
float risSurfaceCompatibilityWeight(vec3 P, vec3 N, vec3 sample_P, vec3 sample_N)
{
	const float normal_alignment = dot(N, sample_N);
	if (normal_alignment < RIS_NORMAL_COMPATIBILITY_MIN) {
		return 0.0;
	}

	const float normal_weight = clamp(
		(normal_alignment - RIS_NORMAL_COMPATIBILITY_MIN) / max(1.0 - RIS_NORMAL_COMPATIBILITY_MIN, 1e-3),
		0.0,
		1.0);
	const float spatial_distance = length(P - sample_P);
	return normal_weight / (1.0 + spatial_distance);
}

ivec2 refractionRisLayerSize()
{
	return ubo.ubo.res / 2;
}

uint refractionRisLayerFromPixel(ivec2 pix)
{
	const ivec2 layer_size = refractionRisLayerSize();
	return uint(pix.x >= layer_size.x) | (uint(pix.y >= layer_size.y) << 1u);
}

ivec2 refractionRisLayerOrigin(uint layer)
{
	const ivec2 layer_size = refractionRisLayerSize();
	return ivec2(int(layer & 1u), int((layer >> 1u) & 1u)) * layer_size;
}

ivec2 refractionRisLayerLocalPixel(ivec2 pix)
{
	return pix - refractionRisLayerOrigin(refractionRisLayerFromPixel(pix));
}

ivec2 refractionRisAtlasPixel(ivec2 local_pix, uint layer)
{
	return refractionRisLayerOrigin(layer) + local_pix;
}

bool refractionRisPixelInBounds(ivec2 pix)
{
	const ivec2 layer_size = refractionRisLayerSize();
	const ivec2 local_pix = refractionRisLayerLocalPixel(pix);
	return all(greaterThanEqual(pix, ivec2(0))) &&
		all(lessThan(pix, ubo.ubo.res)) &&
		all(greaterThanEqual(local_pix, ivec2(0))) &&
		all(lessThan(local_pix, layer_size));
}

bool refractionRisSameLayerAndInBounds(ivec2 center_pix, ivec2 sample_pix)
{
	return refractionRisPixelInBounds(sample_pix) &&
		refractionRisLayerFromPixel(center_pix) == refractionRisLayerFromPixel(sample_pix);
}

#ifndef REFRACTION_RIS_COORDS_ONLY

bool refractionRisLoadSpatialSurfaceRaw(ivec2 pix, out vec3 P, out vec3 geometry_N, out vec3 shading_N)
{
	P = vec3(0.0);
	geometry_N = vec3(0.0, 0.0, 1.0);
	shading_N = vec3(0.0, 0.0, 1.0);

	if (!refractionRisPixelInBounds(pix)) {
		return false;
	}

	const vec4 pos_t = imageLoad(refraction_hit_pos, pix);
	if (pos_t.w <= 0.0) {
		return false;
	}

	const vec4 packed_normal = imageLoad(refraction_normals_gs, pix);
	geometry_N = normalDecode(packed_normal.xy);
	shading_N = normalDecode(packed_normal.zw);
	P = pos_t.xyz;
	return true;
}

MaterialProperties refractionRisLoadMaterial(ivec2 pix)
{
	const vec4 material_data = imageLoad(refraction_material_rmxx, pix);
	MaterialProperties material;
	material.base_color = SRGBtoLINEAR(imageLoad(refraction_base_color_a, pix).rgb);
	material.metalness = material_data.g;
	material.roughness = material_data.r;
	return material;
}

bool refractionRisLoadSurface(
	ivec2 pix,
	out vec3 P,
	out vec3 geometry_N,
	out vec3 shading_N,
	out vec3 V,
	out MaterialProperties material,
	out vec3 throughput,
	out vec3 emissive_radiance)
{
	V = vec3(0.0, 0.0, 1.0);
	material.base_color = vec3(0.0);
	material.metalness = 0.0;
	material.roughness = 1.0;
	throughput = vec3(0.0);
	emissive_radiance = vec3(0.0);

	if (!refractionRisLoadSpatialSurfaceRaw(pix, P, geometry_N, shading_N)) {
		emissive_radiance = imageLoad(refraction_emissive, pix).rgb;
		return false;
	}

	const vec3 stored_view = imageLoad(refraction_view_dir, pix).xyz;
	V = dot(stored_view, stored_view) > 1e-6 ? normalize(stored_view) : shading_N;
	material = refractionRisLoadMaterial(pix);
	throughput = imageLoad(refraction_throughput, pix).rgb;
	emissive_radiance = imageLoad(refraction_emissive, pix).rgb;
	P += geometry_N * REFRACTION_RIS_LIGHTING_NORMAL_OFFSET;
	return any(greaterThan(throughput, vec3(1e-6)));
}

#define RIS_CUSTOM_RESERVOIR_SURFACE_SELECTION 1
bool risSelectReservoirSurfacePixel(ivec2 reservoir_pix, out ivec2 surface_pix)
{
	const ivec2 block_origin = RIS_RESERVOIR_BLOCK_ORIGIN(reservoir_pix);
	surface_pix = block_origin;
#if RIS_INIT_HALF_RES
	const uint layer = refractionRisLayerFromPixel(block_origin);
	float best_t = 1e30;
	bool found = false;
	for (int y = 0; y < 2; ++y) {
		for (int x = 0; x < 2; ++x) {
			const ivec2 candidate_pix = block_origin + ivec2(x, y);
			if (!refractionRisPixelInBounds(candidate_pix) || refractionRisLayerFromPixel(candidate_pix) != layer) {
				continue;
			}
			const vec4 pos_t = imageLoad(refraction_hit_pos, candidate_pix);
			if (pos_t.w > 0.0 && pos_t.w < best_t) {
				best_t = pos_t.w;
				surface_pix = candidate_pix;
				found = true;
			}
		}
	}
	return found;
#else
	return refractionRisPixelInBounds(surface_pix);
#endif
}

#define RIS_PIXEL_IN_BOUNDS(pix_) refractionRisPixelInBounds(pix_)
#define RIS_SPATIAL_SAMPLE_COMPATIBLE(center_pix_, sample_pix_) refractionRisSameLayerAndInBounds((center_pix_), (sample_pix_))

#define RIS_CUSTOM_SPATIAL_SURFACE 1
bool risLoadSpatialSurface(ivec2 pix, out vec3 P, out vec3 N)
{
	vec3 geometry_N;
	return refractionRisLoadSpatialSurfaceRaw(pix, P, geometry_N, N);
}

#if RIS_INIT_PASS
#define TEMPORAL_REPROJECTION_ENABLE_HALF_RES_ATLAS_PRIMARY_PLANE 1

#ifndef REFRACTION_RIS_PRIMARY_ALPHA_EPSILON
#define REFRACTION_RIS_PRIMARY_ALPHA_EPSILON 0.001
#endif

#define TEMPORAL_REPROJECTION_PRIMARY_PIXEL_COMPATIBLE(primary_pix_) (imageLoad(base_color_a, (primary_pix_)).a < 1.0 - REFRACTION_RIS_PRIMARY_ALPHA_EPSILON)

bool reprojectHalfResAtlasPrimaryPlanePixelLegacy(
	ivec2 local_pix,
	ivec2 half_res,
	AsvgfReprojectionParams params,
	out ivec2 history_local_pix);

#define RIS_CUSTOM_TEMPORAL_HISTORY 1
bool risFindTemporalHistoryPixel(ivec2 pix, ivec2 surface_pix, vec3 prev_position, vec3 geometry_normal, out ivec2 history_pix)
{
	history_pix = ivec2(-1);

	if ((ubo.ubo.renderer_flags & RENDERER_FLAG_DISABLE_REPROJECTION) != 0) {
		return false;
	}

	const uint layer = refractionRisLayerFromPixel(surface_pix);
	const ivec2 layer_size = refractionRisLayerSize();
	ivec2 history_center_local_pix;
	if (!reprojectHalfResAtlasPrimaryPlanePixelLegacy(refractionRisLayerLocalPixel(surface_pix), layer_size, ubo.ubo.asvgf.refraction, history_center_local_pix)) {
		return false;
	}

	const vec4 current_pos_t = imageLoad(refraction_hit_pos, surface_pix);
	if (current_pos_t.w <= 0.0) {
		return false;
	}

	ivec2 history_surface_pix = ivec2(-1);
	float best_dist2 = REFRACTION_RIS_HISTORY_DISTANCE_MAX * REFRACTION_RIS_HISTORY_DISTANCE_MAX;
	for (int y = -1; y <= 1; ++y) {
		for (int x = -1; x <= 1; ++x) {
			const ivec2 sample_local = history_center_local_pix + ivec2(x, y);
			if (any(lessThan(sample_local, ivec2(0))) || any(greaterThanEqual(sample_local, layer_size))) {
				continue;
			}

			const ivec2 sample_pix = refractionRisAtlasPixel(sample_local, layer);
			const vec4 history_pos_t = imageLoad(prev_refraction_hit_pos, sample_pix);
			if (history_pos_t.w <= 0.0) {
				continue;
			}

			const vec3 delta = history_pos_t.xyz - current_pos_t.xyz;
			const float dist2 = dot(delta, delta);
			if (dist2 < best_dist2) {
				best_dist2 = dist2;
				history_surface_pix = sample_pix;
			}
		}
	}

	if (history_surface_pix.x < 0 || !refractionRisSameLayerAndInBounds(surface_pix, history_surface_pix)) {
		return false;
	}
	history_pix = RIS_RESERVOIR_PIXEL_FROM_SURFACE(history_surface_pix);
	return true;
}

#define RIS_LOAD_TEMPORAL_REFERENCE_POSITION(pix_) imageLoad(refraction_hit_pos, (pix_)).xyz
#endif

#endif // REFRACTION_RIS_COORDS_ONLY

#endif // REFRACTION_RIS_COMMON_GLSL_INCLUDED
