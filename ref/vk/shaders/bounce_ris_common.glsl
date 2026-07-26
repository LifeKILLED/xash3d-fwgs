#ifndef BOUNCE_RIS_COMMON_GLSL_INCLUDED
#define BOUNCE_RIS_COMMON_GLSL_INCLUDED

#ifndef RIS_SIMPLIFIED_RESAMPLING
#define RIS_SIMPLIFIED_RESAMPLING 1
#endif

#include "light_ris_experimental.glsl"
#include "utils.glsl"
#include "color_spaces.glsl"
#include "noise.glsl"
#include "brdf.glsl"

const uint BOUNCE_RIS_DIFFUSE_LANE_0 = 0u;
const uint BOUNCE_RIS_DIFFUSE_LANE_1 = 1u;
const uint BOUNCE_RIS_DIFFUSE_LANE_2 = 2u;
const uint BOUNCE_RIS_DIFFUSE_LANE_3 = 3u;
const uint BOUNCE_RIS_DIFFUSE_LANE_COUNT = 4u;

#ifndef BOUNCE_RIS_HISTORY_DISTANCE_MAX
#define BOUNCE_RIS_HISTORY_DISTANCE_MAX 32.0
#endif

#ifndef BOUNCE_RIS_LIGHTING_NORMAL_OFFSET
#define BOUNCE_RIS_LIGHTING_NORMAL_OFFSET 0.01
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

ivec2 bounceRisLaneSize()
{
	return ubo.ubo.res / 2;
}

uint bounceRisLaneFromPixel(ivec2 pix)
{
	const ivec2 lane_size = bounceRisLaneSize();
	return uint(pix.x >= lane_size.x) | (uint(pix.y >= lane_size.y) << 1u);
}

ivec2 bounceRisLaneOrigin(uint lane)
{
	const ivec2 lane_size = bounceRisLaneSize();
	return ivec2(int(lane & 1u), int((lane >> 1u) & 1u)) * lane_size;
}

ivec2 bounceRisLaneLocalPixel(ivec2 pix)
{
	return pix - bounceRisLaneOrigin(bounceRisLaneFromPixel(pix));
}

ivec2 bounceRisAtlasPixel(ivec2 local_pix, uint lane)
{
	return bounceRisLaneOrigin(lane) + local_pix;
}

bool bounceRisPixelInBounds(ivec2 pix)
{
	const ivec2 lane_size = bounceRisLaneSize();
	const ivec2 local_pix = bounceRisLaneLocalPixel(pix);
	return all(greaterThanEqual(pix, ivec2(0))) &&
		all(lessThan(pix, ubo.ubo.res)) &&
		all(greaterThanEqual(local_pix, ivec2(0))) &&
		all(lessThan(local_pix, lane_size));
}

bool bounceRisSameLaneAndInBounds(ivec2 center_pix, ivec2 sample_pix)
{
	return bounceRisPixelInBounds(sample_pix) &&
		bounceRisLaneFromPixel(center_pix) == bounceRisLaneFromPixel(sample_pix);
}

#ifndef BOUNCE_RIS_COORDS_ONLY

bool bounceRisLoadSpatialSurfaceRaw(ivec2 pix, out vec3 P, out vec3 geometry_N, out vec3 shading_N)
{
	P = vec3(0.0);
	geometry_N = vec3(0.0, 0.0, 1.0);
	shading_N = vec3(0.0, 0.0, 1.0);

	if (!bounceRisPixelInBounds(pix)) {
		return false;
	}

	const vec4 pos_t = imageLoad(bounce_hit_pos, pix);
	if (pos_t.w <= 0.0) {
		return false;
	}

	const vec4 packed_normal = imageLoad(bounce_normals_gs, pix);
	geometry_N = normalDecode(packed_normal.xy);
	shading_N = normalDecode(packed_normal.zw);
	P = pos_t.xyz;
	return true;
}

MaterialProperties bounceRisLoadMaterial(ivec2 pix)
{
	MaterialProperties material;
	material.base_color = SRGBtoLINEAR(imageLoad(bounce_base_color_a, pix).rgb);
	material.metalness = 0.0;
	material.roughness = 1.0;
	return material;
}

bool bounceRisLoadSurface(
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

	if (!bounceRisLoadSpatialSurfaceRaw(pix, P, geometry_N, shading_N)) {
		emissive_radiance = imageLoad(bounce_emissive, pix).rgb;
		return false;
	}

	const vec3 stored_view = imageLoad(bounce_view_dir, pix).xyz;
	V = dot(stored_view, stored_view) > 1e-6 ? normalize(stored_view) : shading_N;
	material = bounceRisLoadMaterial(pix);
	throughput = imageLoad(bounce_throughput, pix).rgb;
	emissive_radiance = imageLoad(bounce_emissive, pix).rgb;
	P += geometry_N * BOUNCE_RIS_LIGHTING_NORMAL_OFFSET;
	return any(greaterThan(throughput, vec3(1e-6)));
}

#define RIS_CUSTOM_RESERVOIR_SURFACE_SELECTION 1
bool risSelectReservoirSurfacePixel(ivec2 reservoir_pix, out ivec2 surface_pix)
{
	const ivec2 block_origin = RIS_RESERVOIR_BLOCK_ORIGIN(reservoir_pix);
	surface_pix = block_origin;
#if RIS_INIT_HALF_RES
	const uint lane = bounceRisLaneFromPixel(block_origin);
	float best_t = 1e30;
	bool found = false;
	for (int y = 0; y < 2; ++y) {
		for (int x = 0; x < 2; ++x) {
			const ivec2 candidate_pix = block_origin + ivec2(x, y);
			if (!bounceRisPixelInBounds(candidate_pix) || bounceRisLaneFromPixel(candidate_pix) != lane) {
				continue;
			}
			const vec4 pos_t = imageLoad(bounce_hit_pos, candidate_pix);
			if (pos_t.w > 0.0 && pos_t.w < best_t) {
				best_t = pos_t.w;
				surface_pix = candidate_pix;
				found = true;
			}
		}
	}
	return found;
#else
	return bounceRisPixelInBounds(surface_pix);
#endif
}

#define RIS_PIXEL_IN_BOUNDS(pix_) bounceRisPixelInBounds(pix_)
#define RIS_SPATIAL_SAMPLE_COMPATIBLE(center_pix_, sample_pix_) bounceRisSameLaneAndInBounds((center_pix_), (sample_pix_))

#define RIS_CUSTOM_SPATIAL_SURFACE 1
bool risLoadSpatialSurface(ivec2 pix, out vec3 P, out vec3 N)
{
	vec3 geometry_N;
	return bounceRisLoadSpatialSurfaceRaw(pix, P, geometry_N, N);
}

#if RIS_INIT_PASS
#define TEMPORAL_REPROJECTION_ENABLE_HALF_RES_ATLAS_PRIMARY_PLANE 1

bool reprojectHalfResAtlasPrimaryPlanePixelLegacy(
	ivec2 local_pix,
	ivec2 half_res,
	AsvgfReprojectionParams params,
	out ivec2 history_local_pix);

AsvgfReprojectionParams bounceRisReprojectionParams(uint lane)
{
	return ubo.ubo.asvgf.indirect_diffuse;
}

#define RIS_CUSTOM_TEMPORAL_HISTORY 1
bool risFindTemporalHistoryPixel(ivec2 pix, ivec2 surface_pix, vec3 prev_position, vec3 geometry_normal, out ivec2 history_pix)
{
	history_pix = ivec2(-1);

	const uint lane = bounceRisLaneFromPixel(surface_pix);
	const ivec2 lane_size = bounceRisLaneSize();
	ivec2 history_center_local_pix;
	if (!reprojectHalfResAtlasPrimaryPlanePixelLegacy(bounceRisLaneLocalPixel(surface_pix), lane_size, bounceRisReprojectionParams(lane), history_center_local_pix)) {
		return false;
	}

	const vec4 current_pos_t = imageLoad(bounce_hit_pos, surface_pix);
	if (current_pos_t.w <= 0.0) {
		return false;
	}

	ivec2 history_surface_pix = ivec2(-1);
	float best_dist2 = BOUNCE_RIS_HISTORY_DISTANCE_MAX * BOUNCE_RIS_HISTORY_DISTANCE_MAX;
	for (int y = -1; y <= 1; ++y) {
		for (int x = -1; x <= 1; ++x) {
			const ivec2 sample_local = history_center_local_pix + ivec2(x, y);
			if (any(lessThan(sample_local, ivec2(0))) || any(greaterThanEqual(sample_local, lane_size))) {
				continue;
			}

			const ivec2 sample_pix = bounceRisAtlasPixel(sample_local, lane);
			const vec4 history_pos_t = imageLoad(prev_bounce_hit_pos, sample_pix);
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

	if (history_surface_pix.x < 0 || !bounceRisSameLaneAndInBounds(surface_pix, history_surface_pix)) {
		return false;
	}
	history_pix = RIS_RESERVOIR_PIXEL_FROM_SURFACE(history_surface_pix);
	return true;
}

#define RIS_LOAD_TEMPORAL_REFERENCE_POSITION(pix_) imageLoad(bounce_hit_pos, (pix_)).xyz
#endif

#endif // BOUNCE_RIS_COORDS_ONLY

#endif // BOUNCE_RIS_COMMON_GLSL_INCLUDED
