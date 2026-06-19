#ifndef LIGHT_POLYGON_RIS_GLSL_INCLUDED
#define LIGHT_POLYGON_RIS_GLSL_INCLUDED

#define MAX_POLYGON_VERTEX_COUNT 8

#include "utils.glsl"
#include "light_ris_common.glsl"
#include "peters2021-sampling/polygon_sampling.glsl"

struct RisPolySharedSample {
	uint diffuse_valid;
	uint specular_valid;
	uint diffuse_light_id;
	uint specular_light_id;
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

bool risSelectPolygonLight(
	uint cluster_index,
	vec3 P,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	ivec2 pix,
	uint lobe,
	out uint light_id,
	out float inv_light_pdf)
{
	float total_weight = 0.0;
	const uint num_polygons = uint(light_grid.clusters_[cluster_index].num_polygons);
	for (uint i = 0u; i < num_polygons; ++i) {
		total_weight += risSelectLobeWeight(risPolygonProposalWeights(uint(light_grid.clusters_[cluster_index].polygons[i]), P, N, V, material), lobe);
	}

	if (total_weight <= RIS_WEIGHT_EPSILON) {
		light_id = 0u;
		inv_light_pdf = 0.0;
		return false;
	}

	const uint salt = (lobe == RIS_LOBE_SPECULAR) ? 17u : 0u;
	const uint candidate_offset = risPrimaryCandidateOffset(pix, num_polygons, salt);
	const float target_weight = risPrimaryBayerRandom01(pix, salt) * total_weight;
	float weight_prefix = 0.0;
	for (uint i = 0u; i < num_polygons; ++i) {
		const uint candidate_index = (i + candidate_offset) % num_polygons;
		const uint candidate_id = uint(light_grid.clusters_[cluster_index].polygons[candidate_index]);
		const float candidate_weight = risSelectLobeWeight(risPolygonProposalWeights(candidate_id, P, N, V, material), lobe);
		if (candidate_weight <= RIS_WEIGHT_EPSILON) {
			continue;
		}

		weight_prefix += candidate_weight;
		if (target_weight <= weight_prefix || i + 1u == num_polygons) {
			light_id = candidate_id;
			inv_light_pdf = total_weight / candidate_weight;
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
	shared_sample.diffuse_valid = 0u;
	shared_sample.specular_valid = 0u;
	shared_sample.diffuse_light_id = 0u;
	shared_sample.specular_light_id = 0u;
	shared_sample.reuse_weights = vec2(0.0);
	shared_sample.source_P = P;
	shared_sample.source_N = N;

	primary_diffuse = vec3(0.0);
	primary_specular = vec3(0.0);
	primary_weights = vec2(0.0);

	if (ris_active) {
		uint diffuse_light_id;
		float diffuse_inv_light_pdf;
		if (risSelectPolygonLight(cluster_index, P, N, V, material, pix, RIS_LOBE_DIFFUSE, diffuse_light_id, diffuse_inv_light_pdf)) {
			vec3 unused_specular;
			vec2 weights;
			if (risEvaluatePolygonLightSampleWithWeights(diffuse_light_id, diffuse_inv_light_pdf, P, N, V, material, primary_diffuse, unused_specular, weights)) {
				primary_weights.x = weights.x;
				if (weights.x > RIS_WEIGHT_EPSILON) {
					shared_sample.diffuse_valid = 1u;
					shared_sample.diffuse_light_id = diffuse_light_id;
					shared_sample.reuse_weights.x = weights.x;
				}
			}
		}

		uint specular_light_id;
		float specular_inv_light_pdf;
		if (risSelectPolygonLight(cluster_index, P, N, V, material, pix, RIS_LOBE_SPECULAR, specular_light_id, specular_inv_light_pdf)) {
			vec3 unused_diffuse;
			vec2 weights;
			if (risEvaluatePolygonLightSampleWithWeights(specular_light_id, specular_inv_light_pdf, P, N, V, material, unused_diffuse, primary_specular, weights)) {
				primary_weights.y = weights.y;
				if (weights.y > RIS_WEIGHT_EPSILON) {
					shared_sample.specular_valid = 1u;
					shared_sample.specular_light_id = specular_light_id;
					shared_sample.reuse_weights.y = weights.y;
				}
			}
		}
	}

	ris_poly_shared[shared_index] = shared_sample;
}

void computePolygonLightingRIS(
	vec3 P,
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
	uint secondary_diffuse_sample_count = 0u;
	uint secondary_specular_sample_count = 0u;
	risReservoirInit(primary_diffuse_reservoir);
	risReservoirInit(primary_specular_reservoir);

	if (ris_active) {
		if (any(greaterThan(primary_candidate_weights, vec2(RIS_WEIGHT_EPSILON)))) {
			risReservoirUpdate(primary_diffuse_reservoir, primary_candidate_weights.x, primary_candidate_diffuse);
			risReservoirUpdate(primary_specular_reservoir, primary_candidate_weights.y, primary_candidate_specular);
		}

		uint pool_indices[RIS_POISSON_POOL_SIZE];
		vec2 pool_weights[RIS_POISSON_POOL_SIZE];
		uint pool_count = 0u;
		float diffuse_weight_sum = 0.0;
		float specular_weight_sum = 0.0;

		for (uint i = 0u; i < RIS_POISSON_POOL_SIZE; ++i) {
			const ivec2 local_pos = ivec2(gl_LocalInvocationID.xy) + risPoissonNeighborOffset(i, pix);
			if (any(lessThan(local_pos, ivec2(0))) || local_pos.x >= RIS_LOCAL_SIZE_X || local_pos.y >= RIS_LOCAL_SIZE_Y) {
				continue;
			}

			const uint sample_index = uint(local_pos.y * RIS_LOCAL_SIZE_X + local_pos.x);
			const RisPolySharedSample shared_sample = ris_poly_shared[sample_index];

			if (shared_sample.diffuse_valid == 0u && shared_sample.specular_valid == 0u) {
				continue;
			}

			const float edge_weight = risSurfaceCompatibilityWeight(P, N, shared_sample.source_P, shared_sample.source_N);
			if (edge_weight <= RIS_WEIGHT_EPSILON) {
				continue;
			}

			vec2 reuse_weights = max(shared_sample.reuse_weights, vec2(0.0)) * edge_weight;
			if (shared_sample.diffuse_valid == 0u) {
				reuse_weights.x = 0.0;
			}
			if (shared_sample.specular_valid == 0u) {
				reuse_weights.y = 0.0;
			}
			if (!any(greaterThan(reuse_weights, vec2(RIS_WEIGHT_EPSILON)))) {
				continue;
			}

			pool_indices[pool_count] = sample_index;
			pool_weights[pool_count] = reuse_weights;
			diffuse_weight_sum += reuse_weights.x;
			specular_weight_sum += reuse_weights.y;
			pool_count += 1u;
		}

		for (uint pick = 0u; pick < RIS_NEIGHBOR_CANDIDATES; ++pick) {
			if (diffuse_weight_sum > RIS_WEIGHT_EPSILON) {
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
				const RisPolySharedSample selected_sample = ris_poly_shared[pool_indices[selected]];
				const float secondary_inv_light_pdf = diffuse_weight_sum / max(pool_weights[selected].x, RIS_WEIGHT_EPSILON);
				secondary_diffuse_sample_count += 1u;
				if (risEvaluatePolygonLightSample(selected_sample.diffuse_light_id, secondary_inv_light_pdf, P, N, V, material, candidate_diffuse, candidate_specular)) {
					secondary_diffuse_sum += candidate_diffuse;
				}
			}

			if (specular_weight_sum > RIS_WEIGHT_EPSILON) {
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
				const RisPolySharedSample selected_sample = ris_poly_shared[pool_indices[selected]];
				const float secondary_inv_light_pdf = specular_weight_sum / max(pool_weights[selected].y, RIS_WEIGHT_EPSILON);
				secondary_specular_sample_count += 1u;
				if (risEvaluatePolygonLightSample(selected_sample.specular_light_id, secondary_inv_light_pdf, P, N, V, material, candidate_diffuse, candidate_specular)) {
					secondary_specular_sum += candidate_specular;
				}
			}
		}
	}

	diffuse = risBlendPrimarySecondary(primary_diffuse_reservoir, secondary_diffuse_sum, secondary_diffuse_sample_count);
	specular = risBlendPrimarySecondary(primary_specular_reservoir, secondary_specular_sum, secondary_specular_sample_count);

	barrier();
}

#endif // LIGHT_POLYGON_RIS_GLSL_INCLUDED
