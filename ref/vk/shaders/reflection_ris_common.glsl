#ifndef REFLECTION_RIS_COMMON_GLSL_INCLUDED
#define REFLECTION_RIS_COMMON_GLSL_INCLUDED

#include "light_ris_experimental.glsl"
#include "utils.glsl"
#include "color_spaces.glsl"
#include "noise.glsl"
#include "brdf.glsl"

#ifndef REFLECTION_RIS_HISTORY_DISTANCE_MAX
#define REFLECTION_RIS_HISTORY_DISTANCE_MAX 32.0
#endif

#ifndef REFLECTION_RIS_LIGHTING_NORMAL_OFFSET
#define REFLECTION_RIS_LIGHTING_NORMAL_OFFSET 0.01
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

bool reflectionRisPixelInBounds(ivec2 pix)
{
	return all(greaterThanEqual(pix, ivec2(0))) &&
		all(lessThan(pix, ubo.ubo.res));
}

#ifndef REFLECTION_RIS_COORDS_ONLY

bool reflectionRisLoadSpatialSurfaceRaw(ivec2 pix, out vec3 P, out vec3 geometry_N, out vec3 shading_N)
{
	P = vec3(0.0);
	geometry_N = vec3(0.0, 0.0, 1.0);
	shading_N = vec3(0.0, 0.0, 1.0);

	if (!reflectionRisPixelInBounds(pix)) {
		return false;
	}

	const vec4 pos_t = imageLoad(reflection_hit_pos, pix);
	if (pos_t.w <= 0.0) {
		return false;
	}

	const vec4 packed_normal = imageLoad(reflection_normals_gs, pix);
	geometry_N = normalDecode(packed_normal.xy);
	shading_N = normalDecode(packed_normal.zw);
	P = pos_t.xyz;
	return true;
}

MaterialProperties reflectionRisLoadMaterial(ivec2 pix)
{
	const vec4 material_data = imageLoad(reflection_material_rmxx, pix);
	MaterialProperties material;
	material.base_color = SRGBtoLINEAR(imageLoad(reflection_base_color_a, pix).rgb);
	material.metalness = material_data.g;
	material.roughness = material_data.r;
	return material;
}

bool reflectionRisLoadSurface(
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

	if (!reflectionRisPixelInBounds(pix)) {
		return false;
	}

	if (!reflectionRisLoadSpatialSurfaceRaw(pix, P, geometry_N, shading_N)) {
		emissive_radiance = imageLoad(reflection_emissive, pix).rgb;
		return false;
	}

	const vec3 stored_view = imageLoad(reflection_view_dir, pix).xyz;
	V = dot(stored_view, stored_view) > 1e-6 ? normalize(stored_view) : shading_N;
	material = reflectionRisLoadMaterial(pix);
	throughput = imageLoad(reflection_throughput, pix).rgb;
	emissive_radiance = imageLoad(reflection_emissive, pix).rgb;
	P += geometry_N * REFLECTION_RIS_LIGHTING_NORMAL_OFFSET;
	return any(greaterThan(throughput, vec3(1e-6)));
}

#define RIS_CUSTOM_RESERVOIR_SURFACE_SELECTION 1
bool risSelectReservoirSurfacePixel(ivec2 reservoir_pix, out ivec2 surface_pix)
{
	const ivec2 block_origin = RIS_RESERVOIR_BLOCK_ORIGIN(reservoir_pix);
	surface_pix = block_origin;
#if RIS_INIT_HALF_RES
	float best_t = 1e30;
	bool found = false;
	for (int y = 0; y < 2; ++y) {
		for (int x = 0; x < 2; ++x) {
			const ivec2 candidate_pix = block_origin + ivec2(x, y);
			if (!reflectionRisPixelInBounds(candidate_pix)) {
				continue;
			}
			const vec4 pos_t = imageLoad(reflection_hit_pos, candidate_pix);
			if (pos_t.w > 0.0 && pos_t.w < best_t) {
				best_t = pos_t.w;
				surface_pix = candidate_pix;
				found = true;
			}
		}
	}
	return found;
#else
	return reflectionRisPixelInBounds(surface_pix);
#endif
}

#define RIS_PIXEL_IN_BOUNDS(pix_) reflectionRisPixelInBounds(pix_)

#define RIS_CUSTOM_SPATIAL_SURFACE 1
bool risLoadSpatialSurface(ivec2 pix, out vec3 P, out vec3 N)
{
	vec3 geometry_N;
	return reflectionRisLoadSpatialSurfaceRaw(pix, P, geometry_N, N);
}

#if RIS_INIT_PASS
bool reprojectToPrevFramePixelForParamsLegacy(
	AsvgfReprojectionParams params,
	vec3 prev_position,
	ivec2 res,
	out ivec2 reproj_pix,
	out float depth_necessary,
	out float depth_threshold);
float decodeReprojectionDepth(float stored_depth);
bool isValidReprojectionDepth(float depth);
bool computePlaneDepthInPrevFrame(ivec2 prev_pix, ivec2 res, vec3 plane_point, vec3 plane_normal, out float depth);
float makeReprojectionDepthThresholdForParams(AsvgfReprojectionParams params, float expected_depth, float stored_depth, float base_threshold);

bool reflectionRisFindPrimaryHistoryPixel(ivec2 pix, out ivec2 history_center_pix)
{
	history_center_pix = ivec2(-1);

	if (!reflectionRisPixelInBounds(pix)) {
		return false;
	}

	const vec4 current_primary_pos_t = imageLoad(position_t, pix);
	if (current_primary_pos_t.w <= 0.0) {
		return false;
	}

	const vec3 prev_position = imageLoad(geometry_prev_position, pix).rgb;
	const vec3 geometry_normal = normalDecode(imageLoad(normals_gs, pix).xy);

	float depth_necessary = 0.0;
	float depth_threshold = 0.0;
	if (!reprojectToPrevFramePixelForParamsLegacy(
			ubo.ubo.asvgf.indirect_specular,
			prev_position,
			ubo.ubo.res,
			history_center_pix,
			depth_necessary,
			depth_threshold)) {
		return false;
	}

	const vec4 history_depth_meta = imageLoad(prev_temporal_asvgf_reproj_depth, history_center_pix);
	const float history_depth = decodeReprojectionDepth(history_depth_meta.r);
	if (!isValidReprojectionDepth(history_depth)) {
		return false;
	}

	float expected_depth = depth_necessary;
	float plane_depth = 0.0;
	if (computePlaneDepthInPrevFrame(history_center_pix, ubo.ubo.res, prev_position, geometry_normal, plane_depth)) {
		expected_depth = plane_depth;
	}

	const float threshold = makeReprojectionDepthThresholdForParams(
		ubo.ubo.asvgf.indirect_specular,
		expected_depth,
		history_depth,
		depth_threshold);
	return abs(history_depth - expected_depth) < threshold;
}

#define RIS_CUSTOM_TEMPORAL_HISTORY 1
bool risFindTemporalHistoryPixel(ivec2 pix, ivec2 surface_pix, vec3 prev_position, vec3 geometry_normal, out ivec2 history_pix)
{
	history_pix = ivec2(-1);

	ivec2 history_center_pix;
	if (!reflectionRisFindPrimaryHistoryPixel(surface_pix, history_center_pix)) {
		return false;
	}

	const vec4 current_pos_t = imageLoad(reflection_hit_pos, surface_pix);
	if (current_pos_t.w <= 0.0) {
		return false;
	}

	ivec2 history_surface_pix = ivec2(-1);
	float best_dist2 = REFLECTION_RIS_HISTORY_DISTANCE_MAX * REFLECTION_RIS_HISTORY_DISTANCE_MAX;
	for (int y = -1; y <= 1; ++y) {
		for (int x = -1; x <= 1; ++x) {
			const ivec2 sample_pix = history_center_pix + ivec2(x, y);
			if (!reflectionRisPixelInBounds(sample_pix)) {
				continue;
			}

			const vec4 history_pos_t = imageLoad(prev_reflection_hit_pos, sample_pix);
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

	if (history_surface_pix.x < 0 || !reflectionRisPixelInBounds(history_surface_pix)) {
		return false;
	}
	history_pix = RIS_RESERVOIR_PIXEL_FROM_SURFACE(history_surface_pix);
	return true;
}

#define RIS_LOAD_TEMPORAL_REFERENCE_POSITION(pix_) imageLoad(reflection_hit_pos, (pix_)).xyz
#endif

#endif // REFLECTION_RIS_COORDS_ONLY

#endif // REFLECTION_RIS_COMMON_GLSL_INCLUDED
