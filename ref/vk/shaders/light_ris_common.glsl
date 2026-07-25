#ifndef LIGHT_RIS_COMMON_GLSL_INCLUDED
#define LIGHT_RIS_COMMON_GLSL_INCLUDED

#include "debug.glsl"
#include "noise.glsl"
#include "brdf.glsl"
#include "light_ris_experimental.glsl"

const float shadow_offset_fudge = .1;

#include "light_common.glsl"
#include "light_weight.glsl"
#if RIS_INIT_PASS && defined(REGIR_ONION_IMAGE)
#include "regir_onion.glsl"
#endif

#ifndef LOAD_REFLECTION_RAY_LENGTH
#define LOAD_REFLECTION_RAY_LENGTH(pix) 0.0
#endif

#if RIS_INIT_PASS && !defined(RIS_CUSTOM_TEMPORAL_HISTORY)
#define REPROJECTION_LOAD_PREV_DEPTH_META(pix_) imageLoad(prev_temporal_asvgf_reproj_depth, (pix_))
#endif
#include "temporal_reprojection.glsl"
#if RIS_INIT_PASS && !defined(RIS_CUSTOM_TEMPORAL_HISTORY)
#undef REPROJECTION_LOAD_PREV_DEPTH_META
#endif

#ifndef RIS_LOCAL_SIZE_X
#define RIS_LOCAL_SIZE_X 8
#endif

#ifndef RIS_LOCAL_SIZE_Y
#define RIS_LOCAL_SIZE_Y 8
#endif

#ifndef RIS_SECONDARY_MAX_SAMPLES
#define RIS_SECONDARY_MAX_SAMPLES 4
#endif

#ifndef RIS_SECONDARY_DIELECTRIC_DIFFUSE_SAMPLES
#define RIS_SECONDARY_DIELECTRIC_DIFFUSE_SAMPLES 3
#endif

#ifndef RIS_SECONDARY_DIELECTRIC_SPECULAR_SAMPLES
#define RIS_SECONDARY_DIELECTRIC_SPECULAR_SAMPLES 1
#endif

#ifndef RIS_SECONDARY_METALLIC_DIFFUSE_SAMPLES
#define RIS_SECONDARY_METALLIC_DIFFUSE_SAMPLES 0
#endif

#ifndef RIS_SECONDARY_METALLIC_SPECULAR_SAMPLES
#define RIS_SECONDARY_METALLIC_SPECULAR_SAMPLES 4
#endif

#ifndef RIS_POISSON_POOL_SIZE
#define RIS_POISSON_POOL_SIZE 8
#endif

#ifndef RIS_SPATIAL_POOL_CAPACITY
#define RIS_SPATIAL_POOL_CAPACITY (RIS_POISSON_POOL_SIZE + 1)
#endif

#ifndef RIS_PRIMARY_CANDIDATES
#define RIS_PRIMARY_CANDIDATES 4
#endif

#ifndef RIS_PRIMARY_CANDIDATE_SCAN_WINDOW
#define RIS_PRIMARY_CANDIDATE_SCAN_WINDOW 4
#endif

#if RIS_PRIMARY_CANDIDATE_SCAN_WINDOW < 1
#error RIS_PRIMARY_CANDIDATE_SCAN_WINDOW must be at least 1
#endif

#ifndef RIS_NORMAL_COMPATIBILITY_MIN
#define RIS_NORMAL_COMPATIBILITY_MIN 0.85
#endif

#ifndef RIS_PLANE_DISTANCE_MAX
#define RIS_PLANE_DISTANCE_MAX 16.0
#endif

#ifndef RIS_SPATIAL_DISTANCE_MAX
#define RIS_SPATIAL_DISTANCE_MAX RIS_PLANE_DISTANCE_MAX
#endif

#ifndef RIS_WEIGHT_EPSILON
#define RIS_WEIGHT_EPSILON 1e-5
#endif

#ifndef RIS_INV_LIGHT_PDF_SOFT_CAP
#define RIS_INV_LIGHT_PDF_SOFT_CAP 16.0
#endif

#ifndef RIS_INV_LIGHT_PDF_HARD_CAP
#define RIS_INV_LIGHT_PDF_HARD_CAP 64.0
#endif

#ifndef RIS_STABILIZE_INV_LIGHT_PDF
#define RIS_STABILIZE_INV_LIGHT_PDF 0
#endif

#ifndef RIS_INIT_PASS
#define RIS_INIT_PASS 0
#endif

#ifndef RIS_APPLY_PASS
#define RIS_APPLY_PASS 0
#endif

#ifndef RIS_APPLY_VISIBILITY_TEST
#define RIS_APPLY_VISIBILITY_TEST 1
#endif

#ifndef RIS_TEMPORAL_WEIGHT_DELTA_RESET
#define RIS_TEMPORAL_WEIGHT_DELTA_RESET 0.3
#endif

#ifndef RIS_TEMPORAL_RANDOM_RESET_PROBABILITY
#define RIS_TEMPORAL_RANDOM_RESET_PROBABILITY 0.001
#endif

#ifndef RIS_TEMPORAL_MAX_RESERVOIR_MASS
#define RIS_TEMPORAL_MAX_RESERVOIR_MASS 8.0
#endif

#ifndef RIS_BAYER_SHARED_VISIBILITY
#define RIS_BAYER_SHARED_VISIBILITY 0
#endif

#ifndef RIS_BAYER_CANDIDATE_SEGMENTS
#define RIS_BAYER_CANDIDATE_SEGMENTS 0
#endif

#ifndef RIS_BAYER_SEGMENT_COUNT
#define RIS_BAYER_SEGMENT_COUNT 9
#endif

#ifndef RIS_BAYER_SEGMENT_MAX_CANDIDATES
#define RIS_BAYER_SEGMENT_MAX_CANDIDATES 32
#endif

const uint RIS_INVALID_LIGHT_ID = 0xffffffffu;
const uint RIS_TEMPORAL_HASH_MASK = 0x00ffffffu;

#if RIS_BAYER_CANDIDATE_SEGMENTS
#if RIS_LOCAL_SIZE_X < 3 || RIS_LOCAL_SIZE_Y < 3
#error RIS_BAYER_CANDIDATE_SEGMENTS requires at least 3x3 local workgroups
#endif

#if RIS_BAYER_SEGMENT_COUNT != 9
#error RIS_BAYER_CANDIDATE_SEGMENTS expects a 3x3 Bayer matrix
#endif

#if RIS_BAYER_SEGMENT_MAX_CANDIDATES > 32
#error RIS_BAYER_SEGMENT_MAX_CANDIDATES must fit in one uint mask
#endif

#define RIS_BAYER_WORKGROUP_SIZE (RIS_LOCAL_SIZE_X * RIS_LOCAL_SIZE_Y)

uint risBayerIndex(ivec2 pix)
{
	const uint x = uint(pix.x % 3);
	const uint y = uint(pix.y % 3);
	const uint bayer[9] = uint[9](
		0u, 7u, 3u,
		6u, 5u, 2u,
		4u, 1u, 8u);
	return bayer[x + y * 3u];
}

void risBayerSegmentRange(uint light_count, uint bayer_index, out uint segment_begin, out uint segment_count)
{
	const uint clamped_index = min(bayer_index, uint(RIS_BAYER_SEGMENT_COUNT - 1));
	segment_begin = light_count * clamped_index / uint(RIS_BAYER_SEGMENT_COUNT);
	const uint segment_end = light_count * (clamped_index + 1u) / uint(RIS_BAYER_SEGMENT_COUNT);
	segment_count = min(segment_end - segment_begin, uint(RIS_BAYER_SEGMENT_MAX_CANDIDATES));
}

uint risBayerLocalIndex(ivec2 local_pix)
{
	return uint(local_pix.x) + uint(local_pix.y) * uint(RIS_LOCAL_SIZE_X);
}

uint risBayerLocalInvocationIndex()
{
	return risBayerLocalIndex(ivec2(gl_LocalInvocationID.xy));
}

ivec2 risBayerGatherCenterLocal()
{
	return clamp(
		ivec2(gl_LocalInvocationID.xy),
		ivec2(1),
		ivec2(RIS_LOCAL_SIZE_X - 2, RIS_LOCAL_SIZE_Y - 2));
}

ivec2 risBayerGatherSampleLocal(uint sample_index)
{
	const ivec2 offset = ivec2(int(sample_index % 3u) - 1, int(sample_index / 3u) - 1);
	return risBayerGatherCenterLocal() + offset;
}

ivec2 risBayerLocalToPixel(ivec2 pix, ivec2 local_pix)
{
	return pix + local_pix - ivec2(gl_LocalInvocationID.xy);
}

bool risBayerMaskBitSet(uint mask, uint bit_index)
{
	return (mask & (1u << bit_index)) != 0u;
}
#endif

float risStabilizeInvLightPdf(float inv_light_pdf)
{
#if RIS_STABILIZE_INV_LIGHT_PDF
	if (inv_light_pdf <= RIS_INV_LIGHT_PDF_SOFT_CAP) {
		return inv_light_pdf;
	}

	const float range = max(RIS_INV_LIGHT_PDF_HARD_CAP - RIS_INV_LIGHT_PDF_SOFT_CAP, 1e-3);
	const float overshoot = inv_light_pdf - RIS_INV_LIGHT_PDF_SOFT_CAP;
	return RIS_INV_LIGHT_PDF_SOFT_CAP + range * overshoot / (overshoot + range);
#else
	return inv_light_pdf;
#endif
}

uint risPrimaryCandidateScanCount(uint lights_num_in_cluster)
{
	return min(
		lights_num_in_cluster,
		uint(RIS_PRIMARY_CANDIDATES) * uint(RIS_PRIMARY_CANDIDATE_SCAN_WINDOW));
}

uint risPrimaryCandidateStartIndex(uint lights_num_in_cluster)
{
	if (lights_num_in_cluster == 0u) {
		return 0u;
	}

	return min(uint(rand01() * float(lights_num_in_cluster)), lights_num_in_cluster - 1u);
}

uint risPrimaryCandidateIndex(uint lights_num_in_cluster, uint candidate_start_index, uint candidate_ordinal)
{
	if (lights_num_in_cluster == 0u) {
		return 0u;
	}

	const uint tail_count = lights_num_in_cluster - candidate_start_index;
	return candidate_ordinal < tail_count
		? candidate_start_index + candidate_ordinal
		: candidate_ordinal - tail_count;
}

float risPrimaryWindowInvPdfScale(uint lights_num_in_cluster, uint candidate_count)
{
	if (candidate_count == 0u) {
		return 0.0;
	}

	return float(lights_num_in_cluster) / float(candidate_count);
}

float risPrimaryMixedWeight(vec2 weights, float metalness)
{
	const float dielectric = clamp(1.0 - metalness, 0.0, 1.0);
	return max(weights.x * dielectric + weights.y, 0.0);
}

vec3 risResolveSampleAverage(vec3 contribution_sum, uint sample_count)
{
	return sample_count != 0u ? contribution_sum / float(sample_count) : vec3(0.0);
}

struct RisTemporalReservoir {
	uint light_id;
	uint light_hash;
	float mixed_weight;
	float weight_sum;
};

struct RisTemporalCandidate {
	uint light_id;
	uint light_hash;
	float mixed_weight;
};

struct RisCandidateImageSample {
	uint light_id;
	vec2 weights;
	float mixed_weight;
};

RisTemporalReservoir risInvalidTemporalReservoir()
{
	RisTemporalReservoir reservoir;
	reservoir.light_id = RIS_INVALID_LIGHT_ID;
	reservoir.light_hash = 0u;
	reservoir.mixed_weight = 0.0;
	reservoir.weight_sum = 0.0;
	return reservoir;
}

bool risTemporalReservoirValid(RisTemporalReservoir reservoir)
{
	return reservoir.light_id != RIS_INVALID_LIGHT_ID &&
		reservoir.mixed_weight > RIS_WEIGHT_EPSILON &&
		reservoir.weight_sum > RIS_WEIGHT_EPSILON;
}

#if RIS_INIT_PASS && defined(RIS_REUSE_DIRECT_RESERVOIR)
bool risFindDirectReservoirPixel(vec3 P, vec3 geometry_N, out ivec2 direct_reservoir_pix)
{
	direct_reservoir_pix = ivec2(-1);

	const vec4 clip = ubo.ubo.proj * ubo.ubo.view * vec4(P, 1.0);
	if (clip.w <= 0.0) {
		return false;
	}

	const vec2 ndc = clip.xy / clip.w;
	if (any(greaterThan(abs(ndc), vec2(1.0)))) {
		return false;
	}

	const ivec2 projected_pix = ivec2((ndc * 0.5 + 0.5) * vec2(ubo.ubo.res));
	if (any(lessThan(projected_pix, ivec2(0))) || any(greaterThanEqual(projected_pix, ubo.ubo.res))) {
		return false;
	}

	direct_reservoir_pix = RIS_DIRECT_RESERVOIR_PIXEL_FROM_SURFACE(projected_pix);
	const ivec2 direct_surface_pix = projected_pix;

	const vec4 direct_pos_t = imageLoad(position_t, direct_surface_pix);
	if (direct_pos_t.w <= 0.0) {
		return false;
	}

	const vec3 direct_geometry_N = normalDecode(imageLoad(normals_gs, direct_surface_pix).xy);
	if (dot(geometry_N, direct_geometry_N) < 0.25) {
		return false;
	}

	const float pixel_footprint = max(direct_pos_t.w * ubo.ubo.ray_cone_width, 0.01);
	const float position_tolerance = max(0.25, pixel_footprint * 8.0);
	return distance(P, direct_pos_t.xyz) <= position_tolerance;
}
#endif

RisCandidateImageSample risInvalidCandidateImageSample()
{
	RisCandidateImageSample candidate;
	candidate.light_id = RIS_INVALID_LIGHT_ID;
	candidate.weights = vec2(0.0);
	candidate.mixed_weight = 0.0;
	return candidate;
}

bool risCandidateImageSampleValid(RisCandidateImageSample candidate)
{
	return candidate.light_id != RIS_INVALID_LIGHT_ID &&
		any(greaterThan(candidate.weights, vec2(RIS_WEIGHT_EPSILON)));
}

bool risPixelInBounds(ivec2 pix)
{
#ifndef RIS_PIXEL_IN_BOUNDS
#define RIS_PIXEL_IN_BOUNDS(pix_) (all(greaterThanEqual((pix_), ivec2(0))) && all(lessThan((pix_), ubo.ubo.res)))
#endif
	return RIS_PIXEL_IN_BOUNDS(pix);
}

ivec2 risReservoirResolution()
{
#if RIS_INIT_HALF_RES
	return (ubo.ubo.res + ivec2(1)) / 2;
#else
	return ubo.ubo.res;
#endif
}

bool risReservoirPixelInBounds(ivec2 pix)
{
	return all(greaterThanEqual(pix, ivec2(0))) && all(lessThan(pix, risReservoirResolution()));
}

#ifndef RIS_CUSTOM_RESERVOIR_SURFACE_SELECTION
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
			if (!risPixelInBounds(candidate_pix)) {
				continue;
			}
			const vec4 pos_t = imageLoad(position_t, candidate_pix);
			if (pos_t.w > 0.0 && pos_t.w < best_t) {
				best_t = pos_t.w;
				surface_pix = candidate_pix;
				found = true;
			}
		}
	}
	return found;
#else
	return risPixelInBounds(surface_pix);
#endif
}
#endif


bool risInitWorkgroupOutsideBounds()
{
#if RIS_INIT_PASS && RIS_INIT_HALF_RES
	const ivec2 group_origin = ivec2(gl_WorkGroupID.xy) * ivec2(RIS_LOCAL_SIZE_X, RIS_LOCAL_SIZE_Y);
	return any(greaterThanEqual(group_origin, risReservoirResolution()));
#else
	return false;
#endif
}

float risEncodeLightId(uint light_id)
{
	return light_id == RIS_INVALID_LIGHT_ID ? 0.0 : float(light_id) + 1.0;
}

uint risDecodeLightId(float encoded_id)
{
	if (!(encoded_id > 0.0) || isnan(encoded_id) || isinf(encoded_id)) {
		return RIS_INVALID_LIGHT_ID;
	}

	return uint(max(floor(encoded_id + 0.5) - 1.0, 0.0));
}

uint risFoldTemporalHash(uint light_hash)
{
	return light_hash & RIS_TEMPORAL_HASH_MASK;
}

RisTemporalReservoir risDecodeTemporalReservoir(vec4 encoded)
{
	RisTemporalReservoir reservoir;
	reservoir.light_id = risDecodeLightId(encoded.x);
	reservoir.light_hash = uint(clamp(floor(encoded.y + 0.5), 0.0, float(RIS_TEMPORAL_HASH_MASK)));
	reservoir.mixed_weight = max(encoded.z, 0.0);
	reservoir.weight_sum = max(encoded.w, 0.0);

	if (!risTemporalReservoirValid(reservoir)) {
		return risInvalidTemporalReservoir();
	}

	return reservoir;
}

vec4 risEncodeTemporalReservoir(RisTemporalReservoir reservoir)
{
	if (!risTemporalReservoirValid(reservoir)) {
		return vec4(0.0);
	}

	return vec4(
		risEncodeLightId(reservoir.light_id),
		float(risFoldTemporalHash(reservoir.light_hash)),
		reservoir.mixed_weight,
		reservoir.weight_sum);
}

RisCandidateImageSample risDecodeCandidateImageSample(vec4 encoded)
{
	RisCandidateImageSample candidate;
	candidate.light_id = risDecodeLightId(encoded.x);
	candidate.weights = max(encoded.yz, vec2(0.0));
	candidate.mixed_weight = max(encoded.w, 0.0);

	if (!risCandidateImageSampleValid(candidate)) {
		return risInvalidCandidateImageSample();
	}

	return candidate;
}

vec4 risEncodeCandidateImageSample(RisCandidateImageSample candidate)
{
	if (!risCandidateImageSampleValid(candidate)) {
		return vec4(0.0);
	}

	return vec4(
		risEncodeLightId(candidate.light_id),
		max(candidate.weights, vec2(0.0)),
		max(candidate.mixed_weight, 0.0));
}

float risTemporalRandom01(ivec2 pix, uint salt)
{
	return uintToFloat01(xxhash32(uvec4(
		uint(pix.x),
		uint(pix.y),
		ubo.ubo.random_seed,
		salt)));
}

float risTemporalResetProbability(float previous_weight, float current_weight)
{
	const float reference_weight = max(max(previous_weight, current_weight), RIS_WEIGHT_EPSILON);
	const float relative_delta = abs(current_weight - previous_weight) / reference_weight;
	return clamp(relative_delta / max(RIS_TEMPORAL_WEIGHT_DELTA_RESET, RIS_WEIGHT_EPSILON), 0.0, 1.0);
}

bool risTemporalOldReservoirSurvives(
	RisTemporalReservoir old_reservoir,
	float old_current_mixed_weight,
	float rand_reset,
	float rand_lifetime)
{
	if (!risTemporalReservoirValid(old_reservoir) || old_current_mixed_weight <= RIS_WEIGHT_EPSILON) {
		return false;
	}

	const float reset_probability = risTemporalResetProbability(old_reservoir.mixed_weight, old_current_mixed_weight);
	return rand_reset >= reset_probability && rand_lifetime >= RIS_TEMPORAL_RANDOM_RESET_PROBABILITY;
}

RisTemporalReservoir risReweightTemporalReservoir(
	RisTemporalReservoir old_reservoir,
	float old_current_mixed_weight,
	float rand_reset,
	float rand_lifetime)
{
	if (!risTemporalOldReservoirSurvives(old_reservoir, old_current_mixed_weight, rand_reset, rand_lifetime)) {
		return risInvalidTemporalReservoir();
	}

	const float reweight = old_current_mixed_weight / max(old_reservoir.mixed_weight, RIS_WEIGHT_EPSILON);
	RisTemporalReservoir reservoir = old_reservoir;
	reservoir.mixed_weight = old_current_mixed_weight;
	reservoir.weight_sum = max(old_reservoir.weight_sum, old_reservoir.mixed_weight) * reweight;
	return reservoir;
}

RisTemporalReservoir risMergeTemporalCandidate(
	RisTemporalReservoir reservoir,
	RisTemporalCandidate new_candidate,
	float rand_select)
{
	if (new_candidate.light_id != RIS_INVALID_LIGHT_ID && new_candidate.mixed_weight > RIS_WEIGHT_EPSILON) {
		const float old_mass = risTemporalReservoirValid(reservoir) ? max(reservoir.weight_sum, reservoir.mixed_weight) : 0.0;
		const float new_mass = new_candidate.mixed_weight;
		const float total_mass = old_mass + new_mass;

		if (old_mass <= RIS_WEIGHT_EPSILON || rand_select * total_mass < new_mass) {
			reservoir.light_id = new_candidate.light_id;
			reservoir.light_hash = new_candidate.light_hash;
			reservoir.mixed_weight = new_candidate.mixed_weight;
		}

		reservoir.weight_sum = total_mass;
	}

	return reservoir;
}

RisTemporalReservoir risMergeTemporalCandidateWeighted(
	RisTemporalReservoir reservoir,
	RisTemporalCandidate new_candidate,
	float selection_mass,
	float rand_select)
{
	if (new_candidate.light_id != RIS_INVALID_LIGHT_ID &&
		new_candidate.mixed_weight > RIS_WEIGHT_EPSILON &&
		selection_mass > RIS_WEIGHT_EPSILON) {
		const float old_mass = risTemporalReservoirValid(reservoir) ? max(reservoir.weight_sum, reservoir.mixed_weight) : 0.0;
		const float total_mass = old_mass + selection_mass;
		if (old_mass <= RIS_WEIGHT_EPSILON || rand_select * total_mass < selection_mass) {
			reservoir.light_id = new_candidate.light_id;
			reservoir.light_hash = new_candidate.light_hash;
			reservoir.mixed_weight = new_candidate.mixed_weight;
		}
		reservoir.weight_sum = total_mass;
	}
	return reservoir;
}

RisTemporalReservoir risFinalizeTemporalReservoir(RisTemporalReservoir reservoir)
{
	if (!risTemporalReservoirValid(reservoir)) {
		return risInvalidTemporalReservoir();
	}

	const float selected_weight = max(reservoir.mixed_weight, RIS_WEIGHT_EPSILON);
	reservoir.weight_sum = clamp(reservoir.weight_sum, selected_weight, selected_weight * RIS_TEMPORAL_MAX_RESERVOIR_MASS);
	return reservoir;
}

#if RIS_INIT_PASS
#ifndef RIS_CUSTOM_TEMPORAL_HISTORY
bool risFindTemporalHistoryPixel(ivec2 pix, ivec2 surface_pix, vec3 prev_position, vec3 geometry_normal, out ivec2 history_pix)
{
	history_pix = ivec2(-1);

	if ((ubo.ubo.renderer_flags & RENDERER_FLAG_DISABLE_REPROJECTION) != 0) {
		return false;
	}

	ivec2 history_surface_pix;
	float selected_depth_threshold = 0.0;
	const bool found = findBestReprojectedHistoryTexel(
		prev_position,
		geometry_normal,
		surface_pix,
		ubo.ubo.res,
		history_surface_pix,
		selected_depth_threshold);
	if (found) {
		history_pix = RIS_RESERVOIR_PIXEL_FROM_SURFACE(history_surface_pix);
	}
	return found;
}
#endif
#endif

uint risRoundSampleCount(float value)
{
	return uint(floor(max(value, 0.0) + 0.5));
}

void risSecondarySampleCounts(float metalness, out uint diffuse_count, out uint specular_count)
{
	const float dielectric_diffuse = float(RIS_SECONDARY_DIELECTRIC_DIFFUSE_SAMPLES);
	const float metallic_diffuse = float(RIS_SECONDARY_METALLIC_DIFFUSE_SAMPLES);
	const float dielectric_total = float(RIS_SECONDARY_DIELECTRIC_DIFFUSE_SAMPLES + RIS_SECONDARY_DIELECTRIC_SPECULAR_SAMPLES);
	const float metallic_total = float(RIS_SECONDARY_METALLIC_DIFFUSE_SAMPLES + RIS_SECONDARY_METALLIC_SPECULAR_SAMPLES);
	const float t = clamp(metalness, 0.0, 1.0);

	const uint total_count = min(risRoundSampleCount(mix(dielectric_total, metallic_total, t)), uint(RIS_SECONDARY_MAX_SAMPLES));
	diffuse_count = min(risRoundSampleCount(mix(dielectric_diffuse, metallic_diffuse, t)), total_count);
	specular_count = total_count - diffuse_count;
}

bool risComputeClusterIndex(vec3 P, out uint cluster_index)
{
	const ivec3 light_cell = ivec3(floor(P / LIGHT_GRID_CELL_SIZE)) - lights.m.grid_min_cell;
	cluster_index = uint(dot(light_cell, ivec3(1, lights.m.grid_size.x, lights.m.grid_size.x * lights.m.grid_size.y)));

	if (any(lessThan(light_cell, ivec3(0))) || any(greaterThanEqual(light_cell, lights.m.grid_size)) || cluster_index >= MAX_LIGHT_CLUSTERS) {
		return false;
	}

	return true;
}

#ifndef RIS_CUSTOM_SURFACE_COMPATIBILITY_WEIGHT
float risSurfaceCompatibilityWeight(vec3 P, vec3 N, vec3 sample_P, vec3 sample_N)
{
	return normalCompatibilityWeight(N, sample_N, RIS_NORMAL_COMPATIBILITY_MIN);
}
#endif

bool risSurfaceCompatible(vec3 P, vec3 N, vec3 sample_P, vec3 sample_N)
{
	return risSurfaceCompatibilityWeight(P, N, sample_P, sample_N) > RIS_WEIGHT_EPSILON;
}

#ifndef RIS_SPATIAL_PLANE_SAMPLE_PIXEL
#define RIS_SPATIAL_PLANE_SAMPLE_PIXEL(center_pix_, sample_pix_) (sample_pix_)
#endif

#ifndef RIS_SPATIAL_PLANE_RES
#define RIS_SPATIAL_PLANE_RES(center_pix_) ubo.ubo.res
#endif

#ifndef RIS_CUSTOM_SPATIAL_COMPATIBILITY_WEIGHT
float risSpatialCompatibilityWeight(
	ivec2 center_pix,
	ivec2 sample_pix,
	vec3 P,
	vec3 N,
	vec3 sample_P,
	vec3 sample_N)
{
#ifdef RIS_CUSTOM_SURFACE_COMPATIBILITY_WEIGHT
	return risSurfaceCompatibilityWeight(P, N, sample_P, sample_N);
#else
	return currentFramePlaneCompatibleTexelWeight(
		RIS_SPATIAL_PLANE_SAMPLE_PIXEL(center_pix, sample_pix),
		RIS_SPATIAL_PLANE_RES(center_pix),
		P,
		N,
		sample_P,
		sample_N,
		RIS_NORMAL_COMPATIBILITY_MIN);
#endif
}
#endif

#ifndef RIS_SPATIAL_SAMPLE_COMPATIBLE
#define RIS_SPATIAL_SAMPLE_COMPATIBLE(center_pix_, sample_pix_) true
#endif

#ifndef RIS_CUSTOM_SPATIAL_SURFACE
bool risLoadSpatialSurface(ivec2 pix, out vec3 P, out vec3 N)
{
	P = vec3(0.0);
	N = vec3(0.0, 0.0, 1.0);

	if (!risPixelInBounds(pix)) {
		return false;
	}

	const vec4 pos_t = imageLoad(position_t, pix);
	if (pos_t.w <= 0.0) {
		return false;
	}

	const vec4 packed_normal = imageLoad(normals_gs, pix);
	const vec3 geometry_N = normalDecode(packed_normal.xy);
	P = pos_t.xyz + geometry_N * 0.001;
	N = normalDecode(packed_normal.zw);
	return true;
}
#endif

bool risLoadReservoirSpatialSurface(ivec2 reservoir_pix, out ivec2 surface_pix, out vec3 P, out vec3 N)
{
	if (!risReservoirPixelInBounds(reservoir_pix) || !risSelectReservoirSurfacePixel(reservoir_pix, surface_pix)) {
		return false;
	}
	return risLoadSpatialSurface(surface_pix, P, N);
}

float risSpatialRandom01(ivec2 pix, uint candidate_index, uint salt)
{
	return uintToFloat01(xxhash32(uvec4(
		uint(pix.x),
		uint(pix.y),
		ubo.ubo.random_seed,
		candidate_index ^ salt)));
}

ivec2 risRotateOffset(ivec2 offset, uint rotation)
{
	if (rotation == 1u) {
		return ivec2(-offset.y, offset.x);
	}
	if (rotation == 2u) {
		return -offset;
	}
	if (rotation == 3u) {
		return ivec2(offset.y, -offset.x);
	}
	return offset;
}

ivec2 risPoissonNeighborOffset(uint candidate_index, ivec2 pix)
{
	const ivec2 poisson_offsets[RIS_POISSON_POOL_SIZE] = ivec2[RIS_POISSON_POOL_SIZE](
		ivec2( 3,  0),
		ivec2(-3,  1),
		ivec2( 2,  3),
		ivec2(-1,  4),
		ivec2(-4,  0),
		ivec2(-2, -3),
		ivec2( 1, -4),
		ivec2( 4, -2)
	);

	const uint h = xxhash32(uvec4(
		uint(pix.x),
		uint(pix.y),
		ubo.ubo.random_seed,
		0x706f6973u));
	const uint index = (candidate_index + h) & (RIS_POISSON_POOL_SIZE - 1u);
	ivec2 offset = poisson_offsets[index];

	if (((h >> 8u) & 1u) != 0u) {
		offset.x = -offset.x;
	}

	return risRotateOffset(offset, (h >> 9u) & 3u);
}

#endif // LIGHT_RIS_COMMON_GLSL_INCLUDED
