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

#ifndef RIS_NEIGHBOR_CANDIDATES
#define RIS_NEIGHBOR_CANDIDATES 7
#endif

#ifndef RIS_NEIGHBOR_RADIUS
#define RIS_NEIGHBOR_RADIUS 3
#endif

#ifndef RIS_NORMAL_COMPATIBILITY_MIN
#define RIS_NORMAL_COMPATIBILITY_MIN 0.85
#endif

#ifndef RIS_PLANE_DISTANCE_MAX
#define RIS_PLANE_DISTANCE_MAX 16.0
#endif

#ifndef RIS_WEIGHT_EPSILON
#define RIS_WEIGHT_EPSILON 1e-5
#endif

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

uint risBayer8(ivec2 p)
{
	const uint bayer[64] = uint[64](
		 0u, 32u,  8u, 40u,  2u, 34u, 10u, 42u,
		48u, 16u, 56u, 24u, 50u, 18u, 58u, 26u,
		12u, 44u,  4u, 36u, 14u, 46u,  6u, 38u,
		60u, 28u, 52u, 20u, 62u, 30u, 54u, 22u,
		 3u, 35u, 11u, 43u,  1u, 33u,  9u, 41u,
		51u, 19u, 59u, 27u, 49u, 17u, 57u, 25u,
		15u, 47u,  7u, 39u, 13u, 45u,  5u, 37u,
		63u, 31u, 55u, 23u, 61u, 29u, 53u, 21u
	);
	const ivec2 q = p & ivec2(7);
	return bayer[q.y * 8 + q.x];
}

float risBayerRandom01(ivec2 pix, uint cluster_index, uint salt)
{
	const uint h = xxhash32(uvec4(ubo.ubo.random_seed, ubo.ubo.frame_counter, cluster_index, salt));
	const uint rank = (risBayer8(pix) + (h & 63u)) & 63u;
	const float jitter = uintToFloat01(xxhash32(h ^ 0x51ed270bu));
	return (float(rank) + jitter) * (1.0 / 64.0);
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

bool risSurfaceCompatible(vec3 P, vec3 N, vec3 sample_P, vec3 sample_N)
{
	if (dot(N, sample_N) < RIS_NORMAL_COMPATIBILITY_MIN) {
		return false;
	}

	const float plane_distance = abs(dot(P - sample_P, N));
	return plane_distance <= RIS_PLANE_DISTANCE_MAX;
}

ivec2 risRandomNeighborOffset(uint candidate_index, ivec2 pix)
{
	const uvec4 seed = uvec4(
		uint(pix.x),
		uint(pix.y),
		ubo.ubo.frame_counter ^ ubo.ubo.random_seed,
		candidate_index + 0x9e3779b9u);
	const uvec4 h = pcg4d(seed);
	const int diameter = RIS_NEIGHBOR_RADIUS * 2 + 1;

	return ivec2(
		int(h.x % uint(diameter)) - RIS_NEIGHBOR_RADIUS,
		int(h.y % uint(diameter)) - RIS_NEIGHBOR_RADIUS);
}

#endif // LIGHT_RIS_COMMON_GLSL_INCLUDED
