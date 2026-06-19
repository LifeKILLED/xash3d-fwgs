#ifndef LIGHT_POLYGON_RIS_GLSL_INCLUDED
#define LIGHT_POLYGON_RIS_GLSL_INCLUDED

#define MAX_POLYGON_VERTEX_COUNT 8

#include "utils.glsl"
#include "light_ris_common.glsl"
#include "peters2021-sampling/polygon_sampling.glsl"

struct RisPolySharedSample {
	uint valid;
	uint light_id;
	uint cluster_index;
	float inv_pdf;
	vec2 reuse_weights;
	vec3 sample_pos;
	vec3 source_P;
	vec3 source_N;
};

shared RisPolySharedSample ris_poly_shared[RIS_SHARED_SAMPLE_COUNT];

float risPolygonProposalWeight(uint light_id, vec3 P, vec3 N, vec3 V, MaterialProperties material)
{
	if (light_id >= lights.m.num_polygons) {
		return 0.0;
	}

	const vec2 weights = lightPolygonWeightCalculation(lights.m.polygons[light_id], P, N, V, material.roughness);
	return max(weights.x + weights.y, 0.0);
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
	for (uint i = 0u; i < num_polygons; ++i) {
		total_weight += risPolygonProposalWeight(uint(light_grid.clusters_[cluster_index].polygons[i]), P, N, V, material);
	}

	if (total_weight <= RIS_WEIGHT_EPSILON) {
		light_id = 0u;
		inv_light_pdf = 0.0;
		return false;
	}

	const float target_weight = risBayerRandom01(pix, cluster_index, 0x706f6c79u) * total_weight;
	float weight_prefix = 0.0;
	for (uint i = 0u; i < num_polygons; ++i) {
		const uint candidate_id = uint(light_grid.clusters_[cluster_index].polygons[i]);
		const float candidate_weight = risPolygonProposalWeight(candidate_id, P, N, V, material);
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
	float inv_light_pdf,
	vec3 P,
	out vec3 sample_pos,
	out float inv_pdf)
{
	const uint vertices_offset = poly.vertices_count_offset & 0xffffu;
	const uint vertices_count = poly.vertices_count_offset >> 16;
	if (vertices_count < 3u) {
		sample_pos = vec3(0.0);
		inv_pdf = 0.0;
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
		inv_pdf = 0.0;
		return false;
	}

	const solid_angle_polygon_t sap = prepare_solid_angle_polygon_sampling(vertices_count, vertices, P);
	if (sap.solid_angle <= 1e-6) {
		sample_pos = vec3(0.0);
		inv_pdf = 0.0;
		return false;
	}

	const vec3 L = normalize(sample_solid_angle_polygon(sap, vec2(rand01(), rand01())));
	const float denom = dot(L, plane.xyz);
	if (denom >= -1e-5) {
		sample_pos = vec3(0.0);
		inv_pdf = 0.0;
		return false;
	}

	const float dist = -plane_dist / denom;
	const float light_facing = max(-denom, 0.0);
	if (dist <= 1e-4 || light_facing <= 1e-5) {
		sample_pos = vec3(0.0);
		inv_pdf = 0.0;
		return false;
	}

	sample_pos = P + L * dist;
	inv_pdf = inv_light_pdf * sap.solid_angle * dist * dist / light_facing;
	return true;
}

void risStoreInitialPolygonSample(uint cluster_index, vec3 P, vec3 N, vec3 V, MaterialProperties material, ivec2 pix, bool ris_active)
{
	const uint shared_index = risLocalIndex();
	RisPolySharedSample shared_sample;
	shared_sample.valid = 0u;
	shared_sample.light_id = 0u;
	shared_sample.cluster_index = cluster_index;
	shared_sample.inv_pdf = 0.0;
	shared_sample.reuse_weights = vec2(0.0);
	shared_sample.sample_pos = vec3(0.0);
	shared_sample.source_P = P;
	shared_sample.source_N = N;

	if (ris_active) {
		uint light_id;
		float inv_light_pdf;
		if (risSelectPolygonLight(cluster_index, P, N, V, material, pix, light_id, inv_light_pdf)) {
			if (light_id < lights.m.num_polygons) {
				const PolygonLight poly = lights.m.polygons[light_id];
				vec3 sample_pos;
				float inv_pdf;
				if (risSampleSolidPolygon(poly, inv_light_pdf, P, sample_pos, inv_pdf)) {
					const vec3 to_light = sample_pos - P;
					const float dist2 = dot(to_light, to_light);
					if (dist2 > 1e-6) {
						const float dist = sqrt(dist2);
						const vec3 L = to_light / dist;
						const float light_facing = max(dot(-L, normalizedPolygonPlane(poly).xyz), 0.0);
						if (light_facing > 0.0 && !shadowed(P, L, dist)) {
							shared_sample.valid = 1u;
							shared_sample.light_id = light_id;
							shared_sample.inv_pdf = inv_pdf;
							shared_sample.reuse_weights = lightPolygonWeightCalculation(poly, P, N, V, material.roughness);
							shared_sample.sample_pos = sample_pos;
						}
					}
				}
			}
		}
	}

	ris_poly_shared[shared_index] = shared_sample;
}

bool risEvaluatePolygonSample(
	RisPolySharedSample shared_sample,
	vec3 P,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	out vec3 diffuse,
	out vec3 specular,
	out vec2 weights)
{
	diffuse = vec3(0.0);
	specular = vec3(0.0);
	weights = vec2(0.0);

	if (shared_sample.valid == 0u || shared_sample.light_id >= lights.m.num_polygons) {
		return false;
	}

	const PolygonLight poly = lights.m.polygons[shared_sample.light_id];
	const vec3 to_light = shared_sample.sample_pos - P;
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

	const vec3 light = poly.emissive * (light_facing * shared_sample.inv_pdf / dist2);
	diffuse = light * brdf_diffuse;
	specular = light * brdf_specular;
	weights = lightPolygonWeightCalculation(poly, P, N, V, material.roughness);
	return any(greaterThan(weights, vec2(RIS_WEIGHT_EPSILON)));
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

	risStoreInitialPolygonSample(cluster_index, P, N, V, material, pix, ris_active);
	barrier();

	RisReservoir diffuse_reservoir;
	RisReservoir specular_reservoir;
	risReservoirInit(diffuse_reservoir);
	risReservoirInit(specular_reservoir);

	if (ris_active) {
		const RisPolySharedSample own_sample = ris_poly_shared[risLocalIndex()];
		if (own_sample.valid != 0u && own_sample.cluster_index == cluster_index) {
			vec3 candidate_diffuse;
			vec3 candidate_specular;
			vec2 candidate_weights;
			if (risEvaluatePolygonSample(own_sample, P, N, V, material, candidate_diffuse, candidate_specular, candidate_weights)) {
				risReservoirUpdate(diffuse_reservoir, candidate_weights.x, candidate_diffuse);
				risReservoirUpdate(specular_reservoir, candidate_weights.y, candidate_specular);
			}
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

			if (shared_sample.valid == 0u || shared_sample.cluster_index != cluster_index) {
				continue;
			}

			if (!risSurfaceCompatible(P, N, shared_sample.source_P, shared_sample.source_N)) {
				continue;
			}

			const vec2 reuse_weights = max(shared_sample.reuse_weights, vec2(0.0));
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
					weight_prefix += pool_weights[i].x;
					selected = i;
					if (target_weight <= weight_prefix || i + 1u == pool_count) {
						break;
					}
				}

				vec3 candidate_diffuse;
				vec3 candidate_specular;
				vec2 candidate_weights;
				if (risEvaluatePolygonSample(ris_poly_shared[pool_indices[selected]], P, N, V, material, candidate_diffuse, candidate_specular, candidate_weights)) {
					risReservoirUpdate(diffuse_reservoir, candidate_weights.x, candidate_diffuse);
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
					weight_prefix += pool_weights[i].y;
					selected = i;
					if (target_weight <= weight_prefix || i + 1u == pool_count) {
						break;
					}
				}

				vec3 candidate_diffuse;
				vec3 candidate_specular;
				vec2 candidate_weights;
				if (risEvaluatePolygonSample(ris_poly_shared[pool_indices[selected]], P, N, V, material, candidate_diffuse, candidate_specular, candidate_weights)) {
					risReservoirUpdate(specular_reservoir, candidate_weights.y, candidate_specular);
				}
			}
		}
	}

	diffuse = risReservoirResolve(diffuse_reservoir);
	specular = risReservoirResolve(specular_reservoir);

	barrier();
}

#endif // LIGHT_POLYGON_RIS_GLSL_INCLUDED
