#ifndef LIGHT_RIS_COMMON_GLSL_INCLUDED
#define LIGHT_RIS_COMMON_GLSL_INCLUDED

#include "debug.glsl"
#include "noise.glsl"
#include "brdf.glsl"

const float shadow_offset_fudge = .1;

#include "light_common.glsl"
#include "light_weight.glsl"

#ifndef LOAD_REFLECTION_RAY_LENGTH
#define LOAD_REFLECTION_RAY_LENGTH(pix) 0.0
#endif
#include "temporal_reprojection.glsl"

#ifndef RIS_LOCAL_SIZE_X
#define RIS_LOCAL_SIZE_X 8
#endif

#ifndef RIS_LOCAL_SIZE_Y
#define RIS_LOCAL_SIZE_Y 8
#endif

#ifndef RIS_SHARED_SAMPLE_COUNT
#define RIS_SHARED_SAMPLE_COUNT (RIS_LOCAL_SIZE_X * RIS_LOCAL_SIZE_Y)
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

#ifndef RIS_PRIMARY_CANDIDATES
#define RIS_PRIMARY_CANDIDATES 16
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

#ifndef RIS_PRIMARY_SAMPLE_MIX
#define RIS_PRIMARY_SAMPLE_MIX 0.2
#endif

#ifndef RIS_SECONDARY_SAMPLE_MIX
#define RIS_SECONDARY_SAMPLE_MIX 0.8
#endif

#ifndef RIS_PRIMARY_CONTRIBUTE_TO_OUTPUT
#define RIS_PRIMARY_CONTRIBUTE_TO_OUTPUT 0
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

const uint RIS_INVALID_LIGHT_ID = 0xffffffffu;
const uint RIS_TEMPORAL_HASH_MASK = 0x00ffffffu;

struct RisReservoir {
	uint valid;
	float sum_weight;
	float selected_weight;
	uint sample_count;
	vec3 contribution;
};

void risReservoirInit(out RisReservoir reservoir)
{
	reservoir.valid = 0u;
	reservoir.sum_weight = 0.0;
	reservoir.selected_weight = 0.0;
	reservoir.sample_count = 0u;
	reservoir.contribution = vec3(0.0);
}

void risReservoirUpdate(inout RisReservoir reservoir, float weight, vec3 contribution)
{
	if (weight <= RIS_WEIGHT_EPSILON) {
		return;
	}

	reservoir.sample_count += 1u;
	reservoir.sum_weight += weight;

	if (rand01() * reservoir.sum_weight < weight) {
		reservoir.valid = 1u;
		reservoir.selected_weight = weight;
		reservoir.contribution = contribution;
	}
}

vec3 risReservoirResolve(RisReservoir reservoir)
{
	if (reservoir.valid == 0u || reservoir.sample_count == 0u || reservoir.selected_weight <= RIS_WEIGHT_EPSILON) {
		return vec3(0.0);
	}

	return reservoir.contribution * (reservoir.sum_weight / (float(reservoir.sample_count) * reservoir.selected_weight));
}

bool risReservoirHasValue(RisReservoir reservoir)
{
	return reservoir.valid != 0u && reservoir.sample_count != 0u && reservoir.selected_weight > RIS_WEIGHT_EPSILON;
}

vec3 risBlendPrimarySecondary(RisReservoir primary_reservoir, vec3 secondary_contribution_sum, uint secondary_sample_count)
{
	const bool primary_valid = risReservoirHasValue(primary_reservoir);
	const bool secondary_valid = secondary_sample_count != 0u;
	const vec3 secondary_contribution = secondary_valid ? secondary_contribution_sum / float(secondary_sample_count) : vec3(0.0);

	if (primary_valid && secondary_valid) {
		return risReservoirResolve(primary_reservoir) * RIS_PRIMARY_SAMPLE_MIX +
			secondary_contribution * RIS_SECONDARY_SAMPLE_MIX;
	}

	if (secondary_valid) {
		return secondary_contribution;
	}

	if (primary_valid) {
		return risReservoirResolve(primary_reservoir);
	}

	return vec3(0.0);
}

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

uint risPrimaryCandidateCount(uint lights_num_in_cluster)
{
	return min(lights_num_in_cluster, uint(RIS_PRIMARY_CANDIDATES));
}

uint risPrimaryCandidateIndex(uint lights_num_in_cluster, uint candidate_ordinal)
{
	if (lights_num_in_cluster <= uint(RIS_PRIMARY_CANDIDATES)) {
		return candidate_ordinal;
	}

	return min(uint(rand01() * float(lights_num_in_cluster)), lights_num_in_cluster - 1u);
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

bool risPixelInBounds(ivec2 pix)
{
	return all(greaterThanEqual(pix, ivec2(0))) && all(lessThan(pix, ubo.ubo.res));
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

RisTemporalReservoir risUpdateTemporalReservoir(
	RisTemporalReservoir old_reservoir,
	float old_current_mixed_weight,
	RisTemporalCandidate new_candidate,
	float rand_reset,
	float rand_lifetime,
	float rand_select)
{
	const bool old_valid = risTemporalOldReservoirSurvives(old_reservoir, old_current_mixed_weight, rand_reset, rand_lifetime);

	RisTemporalReservoir reservoir = risInvalidTemporalReservoir();

	if (old_valid) {
		const float reweight = old_current_mixed_weight / max(old_reservoir.mixed_weight, RIS_WEIGHT_EPSILON);
		reservoir = old_reservoir;
		reservoir.mixed_weight = old_current_mixed_weight;
		reservoir.weight_sum = max(old_reservoir.weight_sum, old_reservoir.mixed_weight) * reweight;
	}

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

	if (!risTemporalReservoirValid(reservoir)) {
		return risInvalidTemporalReservoir();
	}

	const float selected_weight = max(reservoir.mixed_weight, RIS_WEIGHT_EPSILON);
	reservoir.weight_sum = clamp(reservoir.weight_sum, selected_weight, selected_weight * RIS_TEMPORAL_MAX_RESERVOIR_MASS);
	return reservoir;
}

uint risSelectTemporalSharedLight(
	RisTemporalReservoir old_reservoir,
	float old_current_mixed_weight,
	bool old_valid,
	RisTemporalCandidate new_candidate,
	float rand_select)
{
	const bool use_old = old_valid && old_reservoir.light_id != RIS_INVALID_LIGHT_ID && old_current_mixed_weight > RIS_WEIGHT_EPSILON;
	const bool use_new = new_candidate.light_id != RIS_INVALID_LIGHT_ID && new_candidate.mixed_weight > RIS_WEIGHT_EPSILON;

	if (!use_old && !use_new) {
		return RIS_INVALID_LIGHT_ID;
	}
	if (!use_old) {
		return new_candidate.light_id;
	}
	if (!use_new) {
		return old_reservoir.light_id;
	}

	const float total_weight = old_current_mixed_weight + new_candidate.mixed_weight;
	return rand_select * total_weight < new_candidate.mixed_weight ? new_candidate.light_id : old_reservoir.light_id;
}

bool risFindTemporalHistoryPixel(ivec2 pix, vec3 prev_position, vec3 geometry_normal, out ivec2 history_pix)
{
	history_pix = ivec2(-1);

	if ((ubo.ubo.renderer_flags & RENDERER_FLAG_DISABLE_REPROJECTION) != 0) {
		return false;
	}

	float depth_necessary = 0.0;
	float depth_threshold = 0.0;
	if (!reprojectToPrevFramePixel(prev_position, ubo.ubo.res, history_pix, depth_necessary, depth_threshold)) {
		return false;
	}

	const vec4 history_depth_meta = imageLoad(prev_temporal_asvgf_reproj_depth, history_pix);
	const float history_depth = decodeReprojectionDepth(history_depth_meta.r);
	if (!isValidReprojectionDepth(history_depth)) {
		return false;
	}

	float expected_depth = depth_necessary;
	float plane_depth = 0.0;
	if (computePlaneDepthInPrevFrame(history_pix, ubo.ubo.res, prev_position, geometry_normal, plane_depth)) {
		expected_depth = plane_depth;
	}

	const float threshold = makeReprojectionDepthThreshold(expected_depth, history_depth, depth_threshold);
	return abs(history_depth - expected_depth) < threshold;
}

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

uint risLocalIndex()
{
	return gl_LocalInvocationID.y * RIS_LOCAL_SIZE_X + gl_LocalInvocationID.x;
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

float risSurfaceCompatibilityWeight(vec3 P, vec3 N, vec3 sample_P, vec3 sample_N)
{
	const float normal_alignment = dot(N, sample_N);
	if (normal_alignment < RIS_NORMAL_COMPATIBILITY_MIN) {
		return 0.0;
	}

	const vec3 surface_delta = P - sample_P;
	const float spatial_distance2 = dot(surface_delta, surface_delta);
	const float spatial_distance_max2 = RIS_SPATIAL_DISTANCE_MAX * RIS_SPATIAL_DISTANCE_MAX;
	if (spatial_distance2 >= spatial_distance_max2) {
		return 0.0;
	}

	const float normal_weight = clamp(
		(normal_alignment - RIS_NORMAL_COMPATIBILITY_MIN) / max(1.0 - RIS_NORMAL_COMPATIBILITY_MIN, 1e-3),
		0.0,
		1.0);
	const float distance_weight = 1.0 - spatial_distance2 / spatial_distance_max2;
	return normal_weight * distance_weight;
}

bool risSurfaceCompatible(vec3 P, vec3 N, vec3 sample_P, vec3 sample_N)
{
	return risSurfaceCompatibilityWeight(P, N, sample_P, sample_N) > RIS_WEIGHT_EPSILON;
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
