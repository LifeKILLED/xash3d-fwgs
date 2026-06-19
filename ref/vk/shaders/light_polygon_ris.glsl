#ifndef LIGHT_POLYGON_RIS_GLSL_INCLUDED
#define LIGHT_POLYGON_RIS_GLSL_INCLUDED

#define MAX_POLYGON_VERTEX_COUNT 8

#include "utils.glsl"
#include "light_ris_common.glsl"
#include "peters2021-sampling/polygon_sampling.glsl"

struct RisPolySharedSample {
	uint valid;
	uint light_id;
	vec2 reuse_weights;
	vec3 source_P;
	vec3 source_N;
};

shared RisPolySharedSample ris_poly_shared[RIS_SHARED_SAMPLE_COUNT];

vec2 risPolygonProposalWeights(uint light_id, vec3 P, vec3 N, vec3 V, MaterialProperties material)
{
	if (light_id >= lights.m.num_polygons) {
		return vec2(0.0);
	}

	return max(lightPolygonWeightCalculation(lights.m.polygons[light_id], P, N, V, material.roughness), vec2(0.0));
}

uint risPolygonLightHash(uint light_id)
{
	if (light_id >= lights.m.num_polygons) {
		return 0u;
	}

	const PolygonLight poly = lights.m.polygons[light_id];
	uint hash_value = xxhash32(uvec4(
		floatBitsToUint(poly.plane.x),
		floatBitsToUint(poly.plane.y),
		floatBitsToUint(poly.plane.z),
		floatBitsToUint(poly.plane.w)));
	hash_value ^= xxhash32(uvec4(
		floatBitsToUint(poly.center.x),
		floatBitsToUint(poly.center.y),
		floatBitsToUint(poly.center.z),
		floatBitsToUint(poly.area)));
	hash_value ^= xxhash32(uvec4(
		floatBitsToUint(poly.emissive.x),
		floatBitsToUint(poly.emissive.y),
		floatBitsToUint(poly.emissive.z),
		poly.vertices_count_offset));
	return risFoldTemporalHash(hash_value);
}

bool risLoadPreviousPolygonReservoir(
	vec3 P,
	vec3 geometry_N,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	ivec2 pix,
	out RisTemporalReservoir reservoir,
	out float current_mixed_weight)
{
	reservoir = risInvalidTemporalReservoir();
	current_mixed_weight = 0.0;

	const vec3 prev_position = imageLoad(geometry_prev_position, pix).rgb;
	ivec2 history_pix;
	if (!risFindTemporalHistoryPixel(pix, prev_position, geometry_N, history_pix)) {
		return false;
	}

	RisTemporalReservoir history_reservoir = risDecodeTemporalReservoir(imageLoad(prev_temporal_ris_poly_reservoir, history_pix));
	if (!risTemporalReservoirValid(history_reservoir) || history_reservoir.light_id >= lights.m.num_polygons) {
		return false;
	}

	const uint current_hash = risPolygonLightHash(history_reservoir.light_id);
	if (current_hash != history_reservoir.light_hash) {
		return false;
	}

	const vec2 current_weights = risPolygonProposalWeights(history_reservoir.light_id, P, N, V, material);
	current_mixed_weight = risPrimaryMixedWeight(current_weights, material.metalness);
	if (current_mixed_weight <= RIS_WEIGHT_EPSILON) {
		return false;
	}

	reservoir = history_reservoir;
	return true;
}

bool risSelectPolygonLight(
	uint cluster_index,
	vec3 P,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	ivec2 pix,
	out uint light_id,
	out float inv_light_pdf)
{
	float total_weight = 0.0;
	const uint num_polygons = uint(light_grid.clusters_[cluster_index].num_polygons);
	const uint candidate_count = risPrimaryCandidateCount(num_polygons);
	if (candidate_count == 0u) {
		light_id = 0u;
		inv_light_pdf = 0.0;
		return false;
	}

	uint candidate_ids[RIS_PRIMARY_CANDIDATES];
	float candidate_weights[RIS_PRIMARY_CANDIDATES];
	for (uint i = 0u; i < uint(RIS_PRIMARY_CANDIDATES); ++i) {
		if (i >= candidate_count) {
			break;
		}

		const uint candidate_index = risPrimaryCandidateIndex(num_polygons, i);
		const uint candidate_id = uint(light_grid.clusters_[cluster_index].polygons[candidate_index]);
		const float candidate_weight = risPrimaryMixedWeight(risPolygonProposalWeights(candidate_id, P, N, V, material), material.metalness);
		candidate_ids[i] = candidate_id;
		candidate_weights[i] = candidate_weight;
		total_weight += candidate_weight;
	}

	if (total_weight <= RIS_WEIGHT_EPSILON) {
		light_id = 0u;
		inv_light_pdf = 0.0;
		return false;
	}

	const float target_weight = rand01() * total_weight;
	float weight_prefix = 0.0;
	for (uint i = 0u; i < uint(RIS_PRIMARY_CANDIDATES); ++i) {
		if (i >= candidate_count) {
			break;
		}

		const uint candidate_id = candidate_ids[i];
		const float candidate_weight = candidate_weights[i];
		if (candidate_weight <= RIS_WEIGHT_EPSILON) {
			continue;
		}

		weight_prefix += candidate_weight;
		if (target_weight <= weight_prefix || i + 1u == candidate_count) {
			light_id = candidate_id;
			inv_light_pdf = risStabilizeInvLightPdf(risPrimaryWindowInvPdfScale(num_polygons, candidate_count) * total_weight / candidate_weight);
			return true;
		}
	}

	light_id = 0u;
	inv_light_pdf = 0.0;
	return false;
}

bool risSampleSolidPolygon(
	PolygonLight poly,
	vec3 P,
	out vec3 sample_pos,
	out float inv_area_pdf)
{
	const uint vertices_offset = poly.vertices_count_offset & 0xffffu;
	const uint vertices_count = poly.vertices_count_offset >> 16;
	if (vertices_count < 3u) {
		sample_pos = vec3(0.0);
		inv_area_pdf = 0.0;
		return false;
	}

	vec3 vertices[MAX_POLYGON_VERTEX_COUNT];
	for (uint i = 0u; i < MAX_POLYGON_VERTEX_COUNT; ++i) {
		vertices[i] = (i < vertices_count) ? lights.m.polygon_vertices[vertices_offset + i].xyz : vec3(0.0);
	}

	const vec4 plane = normalizedPolygonPlane(poly);
	const float plane_dist = dot(plane, vec4(P, 1.0));
	if (plane_dist <= 0.0) {
		sample_pos = vec3(0.0);
		inv_area_pdf = 0.0;
		return false;
	}

	const solid_angle_polygon_t sap = prepare_solid_angle_polygon_sampling(vertices_count, vertices, P);
	if (sap.solid_angle <= 1e-6) {
		sample_pos = vec3(0.0);
		inv_area_pdf = 0.0;
		return false;
	}

	const vec3 L = normalize(sample_solid_angle_polygon(sap, vec2(rand01(), rand01())));
	const float denom = dot(L, plane.xyz);
	if (denom >= -1e-5) {
		sample_pos = vec3(0.0);
		inv_area_pdf = 0.0;
		return false;
	}

	const float dist = -plane_dist / denom;
	const float light_facing = max(-denom, 0.0);
	if (dist <= 1e-4 || light_facing <= 1e-5) {
		sample_pos = vec3(0.0);
		inv_area_pdf = 0.0;
		return false;
	}

	sample_pos = P + L * dist;
	inv_area_pdf = sap.solid_angle * dist * dist / light_facing;
	return true;
}

bool risEvaluatePolygonSamplePositionWithInvPdf(
	PolygonLight poly,
	vec3 sample_pos,
	float inv_pdf,
	vec3 P,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	out vec3 diffuse,
	out vec3 specular)
{
	diffuse = vec3(0.0);
	specular = vec3(0.0);

	if (inv_pdf <= 0.0) {
		return false;
	}

	const vec3 to_light = sample_pos - P;
	const float dist2 = dot(to_light, to_light);
	if (dist2 <= 1e-6) {
		return false;
	}

	const float dist = sqrt(dist2);
	const vec3 L = to_light / dist;
	const float light_facing = max(dot(-L, normalizedPolygonPlane(poly).xyz), 0.0);
	if (light_facing <= 0.0) {
		return false;
	}

	if (shadowed(P, L, dist)) {
		return false;
	}

	vec3 brdf_diffuse;
	vec3 brdf_specular;
	evalSplitBRDF(N, L, V, material, brdf_diffuse, brdf_specular);

	const vec3 light = poly.emissive * (light_facing * inv_pdf / dist2);
	diffuse = light * brdf_diffuse;
	specular = light * brdf_specular;
	return true;
}

bool risEvaluatePolygonLightSample(
	uint light_id,
	float inv_light_pdf,
	vec3 P,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	out vec3 diffuse,
	out vec3 specular)
{
	diffuse = vec3(0.0);
	specular = vec3(0.0);

	if (light_id >= lights.m.num_polygons || inv_light_pdf <= 0.0) {
		return false;
	}

	const PolygonLight poly = lights.m.polygons[light_id];
	vec3 sample_pos;
	float inv_area_pdf;
	if (!risSampleSolidPolygon(poly, P, sample_pos, inv_area_pdf)) {
		return false;
	}

	return risEvaluatePolygonSamplePositionWithInvPdf(poly, sample_pos, inv_light_pdf * inv_area_pdf, P, N, V, material, diffuse, specular);
}

bool risEvaluatePolygonLightSampleWithWeights(
	uint light_id,
	float inv_light_pdf,
	vec3 P,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	out vec3 diffuse,
	out vec3 specular,
	out vec2 weights)
{
	weights = vec2(0.0);

	if (!risEvaluatePolygonLightSample(light_id, inv_light_pdf, P, N, V, material, diffuse, specular)) {
		return false;
	}

	weights = lightPolygonWeightCalculation(lights.m.polygons[light_id], P, N, V, material.roughness);
	return any(greaterThan(weights, vec2(RIS_WEIGHT_EPSILON)));
}

void risStoreInitialPolygonSample(
	uint cluster_index,
	vec3 P,
	vec3 geometry_N,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	ivec2 pix,
	bool ris_active,
	out vec3 primary_diffuse,
	out vec3 primary_specular,
	out vec2 primary_weights)
{
	const uint shared_index = risLocalIndex();
	RisPolySharedSample shared_sample;
	shared_sample.valid = 0u;
	shared_sample.light_id = 0u;
	shared_sample.reuse_weights = vec2(0.0);
	shared_sample.source_P = P;
	shared_sample.source_N = N;

	primary_diffuse = vec3(0.0);
	primary_specular = vec3(0.0);
	primary_weights = vec2(0.0);

	RisTemporalReservoir old_reservoir = risInvalidTemporalReservoir();
	float old_current_mixed_weight = 0.0;
	if (ris_active) {
		risLoadPreviousPolygonReservoir(
			P,
			geometry_N,
			N,
			V,
			material,
			pix,
			old_reservoir,
			old_current_mixed_weight);
	}

	RisTemporalCandidate new_candidate;
	new_candidate.light_id = RIS_INVALID_LIGHT_ID;
	new_candidate.light_hash = 0u;
	new_candidate.mixed_weight = 0.0;

	if (ris_active) {
		uint light_id;
		float inv_light_pdf;
		if (risSelectPolygonLight(cluster_index, P, N, V, material, pix, light_id, inv_light_pdf)) {
			vec2 weights;
			if (risEvaluatePolygonLightSampleWithWeights(light_id, inv_light_pdf, P, N, V, material, primary_diffuse, primary_specular, weights)) {
				primary_weights = vec2(1.0);
				if (any(greaterThan(weights, vec2(RIS_WEIGHT_EPSILON)))) {
					new_candidate.light_id = light_id;
					new_candidate.light_hash = risPolygonLightHash(light_id);
					new_candidate.mixed_weight = risPrimaryMixedWeight(weights, material.metalness);
				}
			}
		}
	}

	const float temporal_rand_reset = risTemporalRandom01(pix, 0x72737430u);
	const float temporal_rand_lifetime = risTemporalRandom01(pix, 0x72737431u);
	const bool old_reservoir_survives = risTemporalOldReservoirSurvives(
		old_reservoir,
		old_current_mixed_weight,
		temporal_rand_reset,
		temporal_rand_lifetime);

	RisTemporalReservoir merged_reservoir = risUpdateTemporalReservoir(
		old_reservoir,
		old_current_mixed_weight,
		new_candidate,
		temporal_rand_reset,
		temporal_rand_lifetime,
		risTemporalRandom01(pix, 0x72737432u));

	const uint shared_light_id = risSelectTemporalSharedLight(
		old_reservoir,
		old_current_mixed_weight,
		old_reservoir_survives,
		new_candidate,
		risTemporalRandom01(pix, 0x72737433u));

	if (shared_light_id != RIS_INVALID_LIGHT_ID) {
		const vec2 merged_weights = risPolygonProposalWeights(shared_light_id, P, N, V, material);
		if (any(greaterThan(merged_weights, vec2(RIS_WEIGHT_EPSILON)))) {
			shared_sample.valid = 1u;
			shared_sample.light_id = shared_light_id;
			shared_sample.reuse_weights = merged_weights;
		}
	}

	if (risPixelInBounds(pix)) {
		imageStore(out_temporal_ris_poly_reservoir, pix, risEncodeTemporalReservoir(merged_reservoir));
	}

	ris_poly_shared[shared_index] = shared_sample;
}

void computePolygonLightingRIS(
	vec3 P,
	vec3 geometry_N,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	uint cluster_index,
	ivec2 pix,
	bool ris_active,
	out vec3 diffuse,
	out vec3 specular)
{
	diffuse = vec3(0.0);
	specular = vec3(0.0);

	vec3 primary_candidate_diffuse;
	vec3 primary_candidate_specular;
	vec2 primary_candidate_weights;
	risStoreInitialPolygonSample(
		cluster_index,
		P,
		geometry_N,
		N,
		V,
		material,
		pix,
		ris_active,
		primary_candidate_diffuse,
		primary_candidate_specular,
		primary_candidate_weights);
	barrier();

	RisReservoir primary_diffuse_reservoir;
	RisReservoir primary_specular_reservoir;
	vec3 secondary_diffuse_sum = vec3(0.0);
	vec3 secondary_specular_sum = vec3(0.0);
	uint secondary_sample_count = 0u;
	risReservoirInit(primary_diffuse_reservoir);
	risReservoirInit(primary_specular_reservoir);

	if (ris_active) {
#if RIS_PRIMARY_CONTRIBUTE_TO_OUTPUT
		if (any(greaterThan(primary_candidate_weights, vec2(RIS_WEIGHT_EPSILON)))) {
			risReservoirUpdate(primary_diffuse_reservoir, primary_candidate_weights.x, primary_candidate_diffuse);
			risReservoirUpdate(primary_specular_reservoir, primary_candidate_weights.y, primary_candidate_specular);
		}
#endif

		uint pool_light_ids[RIS_POISSON_POOL_SIZE];
		vec2 pool_weights[RIS_POISSON_POOL_SIZE];
		uint pool_count = 0u;
		float diffuse_weight_sum = 0.0;
		float specular_weight_sum = 0.0;
		uint secondary_diffuse_target_count;
		uint secondary_specular_target_count;
		risSecondarySampleCounts(material.metalness, secondary_diffuse_target_count, secondary_specular_target_count);

		for (uint i = 0u; i < RIS_POISSON_POOL_SIZE; ++i) {
			const ivec2 local_pos = ivec2(gl_LocalInvocationID.xy) + risPoissonNeighborOffset(i, pix);
			if (any(lessThan(local_pos, ivec2(0))) || local_pos.x >= RIS_LOCAL_SIZE_X || local_pos.y >= RIS_LOCAL_SIZE_Y) {
				continue;
			}

			const uint sample_index = uint(local_pos.y * RIS_LOCAL_SIZE_X + local_pos.x);
			const RisPolySharedSample shared_sample = ris_poly_shared[sample_index];

			if (shared_sample.valid == 0u) {
				continue;
			}

			const float edge_weight = risSurfaceCompatibilityWeight(P, N, shared_sample.source_P, shared_sample.source_N);
			if (edge_weight <= RIS_WEIGHT_EPSILON) {
				continue;
			}

			vec2 reuse_weights = max(shared_sample.reuse_weights, vec2(0.0)) * edge_weight;
			if (!any(greaterThan(reuse_weights, vec2(RIS_WEIGHT_EPSILON)))) {
				continue;
			}

			pool_light_ids[pool_count] = shared_sample.light_id;
			pool_weights[pool_count] = reuse_weights;
			diffuse_weight_sum += reuse_weights.x;
			specular_weight_sum += reuse_weights.y;
			pool_count += 1u;
		}

		if (diffuse_weight_sum > RIS_WEIGHT_EPSILON) {
			for (uint pick = 0u; pick < uint(RIS_SECONDARY_MAX_SAMPLES); ++pick) {
				if (pick >= secondary_diffuse_target_count) {
					break;
				}

				const float target_weight = risSpatialRandom01(pix, pick, 0x64696666u) * diffuse_weight_sum;
				float weight_prefix = 0.0;
				uint selected = 0u;
				for (uint i = 0u; i < RIS_POISSON_POOL_SIZE; ++i) {
					if (i >= pool_count) {
						break;
					}
					if (pool_weights[i].x <= RIS_WEIGHT_EPSILON) {
						continue;
					}
					weight_prefix += pool_weights[i].x;
					selected = i;
					if (target_weight <= weight_prefix || i + 1u == pool_count) {
						break;
					}
				}

				vec3 candidate_diffuse;
				vec3 candidate_specular;
				const float secondary_inv_light_pdf = diffuse_weight_sum / max(pool_weights[selected].x, RIS_WEIGHT_EPSILON);
				secondary_sample_count += 1u;
				if (risEvaluatePolygonLightSample(pool_light_ids[selected], secondary_inv_light_pdf, P, N, V, material, candidate_diffuse, candidate_specular)) {
					secondary_diffuse_sum += candidate_diffuse;
					secondary_specular_sum += candidate_specular;
				}
			}
		}

		if (specular_weight_sum > RIS_WEIGHT_EPSILON) {
			for (uint pick = 0u; pick < uint(RIS_SECONDARY_MAX_SAMPLES); ++pick) {
				if (pick >= secondary_specular_target_count) {
					break;
				}

				const float target_weight = risSpatialRandom01(pix, pick, 0x73706563u) * specular_weight_sum;
				float weight_prefix = 0.0;
				uint selected = 0u;
				for (uint i = 0u; i < RIS_POISSON_POOL_SIZE; ++i) {
					if (i >= pool_count) {
						break;
					}
					if (pool_weights[i].y <= RIS_WEIGHT_EPSILON) {
						continue;
					}
					weight_prefix += pool_weights[i].y;
					selected = i;
					if (target_weight <= weight_prefix || i + 1u == pool_count) {
						break;
					}
				}

				vec3 candidate_diffuse;
				vec3 candidate_specular;
				const float secondary_inv_light_pdf = specular_weight_sum / max(pool_weights[selected].y, RIS_WEIGHT_EPSILON);
				secondary_sample_count += 1u;
				if (risEvaluatePolygonLightSample(pool_light_ids[selected], secondary_inv_light_pdf, P, N, V, material, candidate_diffuse, candidate_specular)) {
					secondary_diffuse_sum += candidate_diffuse;
					secondary_specular_sum += candidate_specular;
				}
			}
		}
	}

	diffuse = risBlendPrimarySecondary(primary_diffuse_reservoir, secondary_diffuse_sum, secondary_sample_count);
	specular = risBlendPrimarySecondary(primary_specular_reservoir, secondary_specular_sum, secondary_sample_count);

	barrier();
}

#endif // LIGHT_POLYGON_RIS_GLSL_INCLUDED
