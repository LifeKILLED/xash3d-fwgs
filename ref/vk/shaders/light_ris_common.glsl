#ifndef LIGHT_RIS_COMMON_GLSL_INCLUDED
#define LIGHT_RIS_COMMON_GLSL_INCLUDED

#include "debug.glsl"
#include "noise.glsl"
#include "brdf.glsl"

const float shadow_offset_fudge = .1;

#include "light_common.glsl"
#include "light_weight.glsl"

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
#define RIS_PRIMARY_CANDIDATES 8
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

#ifndef RIS_PRIMARY_SAMPLE_MIX
#define RIS_PRIMARY_SAMPLE_MIX 0.2
#endif

#ifndef RIS_SECONDARY_SAMPLE_MIX
#define RIS_SECONDARY_SAMPLE_MIX 0.8
#endif

#define RIS_LOBE_DIFFUSE 0u
#define RIS_LOBE_SPECULAR 1u

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
	if (inv_light_pdf <= RIS_INV_LIGHT_PDF_SOFT_CAP) {
		return inv_light_pdf;
	}

	const float range = max(RIS_INV_LIGHT_PDF_HARD_CAP - RIS_INV_LIGHT_PDF_SOFT_CAP, 1e-3);
	const float overshoot = inv_light_pdf - RIS_INV_LIGHT_PDF_SOFT_CAP;
	return RIS_INV_LIGHT_PDF_SOFT_CAP + range * overshoot / (overshoot + range);
}

uint risBayer4(ivec2 p)
{
	const uint bayer[16] = uint[16](
		 0u,  8u,  2u, 10u,
		12u,  4u, 14u,  6u,
		 3u, 11u,  1u,  9u,
		15u,  7u, 13u,  5u
	);
	const ivec2 q = p & ivec2(3);
	return bayer[q.y * 4 + q.x];
}

uint risPrimarySeedPhase(uint salt)
{
	return xxhash32(uvec4(ubo.ubo.random_seed, salt, 0x72697370u, 0x70686173u));
}

float risPrimaryRandom01(ivec2 pix, uint salt)
{
	return uintToFloat01(xxhash32(uvec4(
		uint(pix.x),
		uint(pix.y),
		ubo.ubo.random_seed,
		salt)));
}

uint risPrimaryCandidateCount(uint lights_num_in_cluster)
{
	return min(lights_num_in_cluster, uint(RIS_PRIMARY_CANDIDATES));
}

uint risPrimaryCandidateOffset(ivec2 pix, uint lights_num_in_cluster, uint salt)
{
	if (lights_num_in_cluster <= uint(RIS_PRIMARY_CANDIDATES)) {
		return 0u;
	}

	const uint phase = risPrimarySeedPhase(salt ^ 0x6f666673u);
	const uint bayer_offset = (((risBayer4(pix) + (phase & 15u)) & 15u) * lights_num_in_cluster) >> 4u;
	return (bayer_offset + ubo.ubo.frame_counter) % lights_num_in_cluster;
}

float risPrimaryWindowInvPdfScale(uint lights_num_in_cluster, uint candidate_count)
{
	if (candidate_count == 0u) {
		return 0.0;
	}

	return float(lights_num_in_cluster) / float(candidate_count);
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

float risSelectLobeWeight(vec2 weights, uint lobe)
{
	return (lobe == RIS_LOBE_SPECULAR) ? weights.y : weights.x;
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
