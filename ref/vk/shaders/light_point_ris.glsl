#ifndef LIGHT_POINT_RIS_GLSL_INCLUDED
#define LIGHT_POINT_RIS_GLSL_INCLUDED

#include "light_ris_common.glsl"

struct RisPointSharedSample {
	uint valid;
	uint light_id;
	vec2 reuse_weights;
	vec3 source_P;
	vec3 source_N;
};

shared RisPointSharedSample ris_point_shared[RIS_SHARED_SAMPLE_COUNT];

bool risIsPointLightCandidate(uint light_id)
{
	if (light_id >= lights.m.num_point_lights) {
		return false;
	}

	const PointLight point_light = lights.m.point_lights[light_id];
	return point_light.environment == 0u && point_light.flashlight == 0u;
}

vec2 risPointProposalWeights(uint light_id, vec3 P, vec3 N, vec3 V, MaterialProperties material)
{
	if (!risIsPointLightCandidate(light_id)) {
		return vec2(0.0);
	}

	return max(lightPointWeightCalculation(lights.m.point_lights[light_id], P, N, V, material.roughness), vec2(0.0));
}

bool risSelectPointLight(
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
	const uint num_point_lights = uint(light_grid.clusters_[cluster_index].num_point_lights);
	const uint candidate_count = risPrimaryCandidateCount(num_point_lights);
	if (candidate_count == 0u) {
		light_id = 0u;
		inv_light_pdf = 0.0;
		return false;
	}

	const uint salt = 23u;
	const uint candidate_offset = risPrimaryCandidateOffset(pix, num_point_lights, salt);
	uint candidate_ids[RIS_PRIMARY_CANDIDATES];
	float candidate_weights[RIS_PRIMARY_CANDIDATES];
	for (uint j = 0u; j < uint(RIS_PRIMARY_CANDIDATES); ++j) {
		if (j >= candidate_count) {
			break;
		}

		const uint candidate_index = (candidate_offset + j) % num_point_lights;
		const uint candidate_id = uint(light_grid.clusters_[cluster_index].point_lights[candidate_index]);
		const float candidate_weight = risPrimaryMixedWeight(risPointProposalWeights(candidate_id, P, N, V, material), material.metalness);
		candidate_ids[j] = candidate_id;
		candidate_weights[j] = candidate_weight;
		total_weight += candidate_weight;
	}

	if (total_weight <= RIS_WEIGHT_EPSILON) {
		light_id = 0u;
		inv_light_pdf = 0.0;
		return false;
	}

	const float target_weight = risPrimaryRandom01(pix, salt) * total_weight;
	float weight_prefix = 0.0;
	for (uint j = 0u; j < uint(RIS_PRIMARY_CANDIDATES); ++j) {
		if (j >= candidate_count) {
			break;
		}

		const uint candidate_id = candidate_ids[j];
		const float candidate_weight = candidate_weights[j];
		if (candidate_weight <= RIS_WEIGHT_EPSILON) {
			continue;
		}

		weight_prefix += candidate_weight;
		if (target_weight <= weight_prefix || j + 1u == candidate_count) {
			light_id = candidate_id;
			inv_light_pdf = risStabilizeInvLightPdf(risPrimaryWindowInvPdfScale(num_point_lights, candidate_count) * total_weight / candidate_weight);
			return true;
		}
	}

	light_id = 0u;
	inv_light_pdf = 0.0;
	return false;
}

bool risEvaluatePointLightContribution(
	PointLight point_light,
	vec3 P,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	float inv_light_pdf,
	bool visibility_test,
	out vec3 diffuse,
	out vec3 specular)
{
	diffuse = vec3(0.0);
	specular = vec3(0.0);

	const vec2 rnd = vec2(rand01(), rand01());
	const vec3 spotlight_dir = point_light.dir_stopdot2.xyz;
	const bool is_environment = point_light.environment != 0u;

	vec3 light_dir;
	float light_dist = 0.0;
	float one_over_pdf = 1.0;

	if (is_environment) {
		const float cos_theta_max = point_light.dir_stopdot2.a;
		const vec3 dir_sample_z = sampleConeZ(rnd, cos_theta_max);
		light_dir = normalize(orthonormalBasisZ(spotlight_dir) * dir_sample_z);

		if (dot(light_dir, N) < 1e-5) {
			return false;
		}

		one_over_pdf = 2.0 * kPi * max(0.0, 1.0 - cos_theta_max);
	} else {
		const vec3 light_pos = point_light.origin_r2.xyz;
		const float light_r2 = point_light.origin_r2.w;

		vec3 to_light = light_pos - P;
		const float light_dist2 = dot(to_light, to_light);
		const float d2_minus_r2 = light_dist2 - light_r2;
		if (d2_minus_r2 <= 0.0) {
			return false;
		}

		light_dist = sqrt(light_dist2);
		const float cos_theta_max = min(1.0, sqrt(d2_minus_r2 / light_dist2));
		const vec3 dir_sample_z = sampleConeZ(rnd, cos_theta_max);
		const mat3 basis = orthonormalBasisZ(to_light / light_dist);
		light_dir = normalize(basis * dir_sample_z);

		if (dot(light_dir, N) < 1e-5) {
			return false;
		}

		float spot_attenuation = 1.0;
		const float spot_dot = dot(light_dir, spotlight_dir);
		const float stopdot2 = point_light.dir_stopdot2.a;
		if (spot_dot < stopdot2) {
			return false;
		}

		const float stopdot = point_light.color_stopdot.a;
		if (spot_dot < stopdot) {
			spot_attenuation = (spot_dot - stopdot2) / (stopdot - stopdot2);
			if (spot_attenuation <= 0.0) {
				return false;
			}
		}

		one_over_pdf = 2.0 * kPi * max(0.0, 1.0 - cos_theta_max) * spot_attenuation * inv_light_pdf;
	}

	vec3 brdf_diffuse;
	vec3 brdf_specular;
	evalSplitBRDF(N, light_dir, V, material, brdf_diffuse, brdf_specular);

	const vec3 color = point_light.color_stopdot.rgb * one_over_pdf;
	diffuse = brdf_diffuse * color;
	specular = brdf_specular * color;

	const vec3 combined = diffuse + specular;
	if (dot(combined, combined) <= 0.0) {
		return false;
	}

	if (visibility_test) {
		if (is_environment) {
			if (shadowedSky(P, light_dir)) {
				return false;
			}
		} else if (shadowed(P, light_dir, light_dist + shadow_offset_fudge)) {
			return false;
		}
	}

	return true;
}

bool risEvaluatePointLightSample(
	PointLight point_light,
	vec3 P,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	float inv_light_pdf,
	bool visibility_test,
	out vec3 diffuse,
	out vec3 specular,
	out vec2 weights)
{
	weights = vec2(0.0);

	if (!risEvaluatePointLightContribution(point_light, P, N, V, material, inv_light_pdf, visibility_test, diffuse, specular)) {
		return false;
	}

	weights = lightPointWeightCalculation(point_light, P, N, V, material.roughness);
	return true;
}

void risStoreInitialPointSample(
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
	RisPointSharedSample shared_sample;
	shared_sample.valid = 0u;
	shared_sample.light_id = 0u;
	shared_sample.reuse_weights = vec2(0.0);
	shared_sample.source_P = P;
	shared_sample.source_N = N;

	primary_diffuse = vec3(0.0);
	primary_specular = vec3(0.0);
	primary_weights = vec2(0.0);

	if (ris_active) {
		uint light_id;
		float inv_light_pdf;
		if (risSelectPointLight(cluster_index, P, N, V, material, pix, light_id, inv_light_pdf)) {
			const PointLight point_light = lights.m.point_lights[light_id];
			vec2 weights;
			if (risEvaluatePointLightSample(point_light, P, N, V, material, inv_light_pdf, true, primary_diffuse, primary_specular, weights)) {
				primary_weights = vec2(1.0);
				if (any(greaterThan(weights, vec2(RIS_WEIGHT_EPSILON)))) {
					shared_sample.valid = 1u;
					shared_sample.light_id = light_id;
					shared_sample.reuse_weights = weights;
				}
			}
		}
	}

	ris_point_shared[shared_index] = shared_sample;
}

void computePointAlwaysSampledLights(
	vec3 P,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	uint cluster_index,
	bool ris_active,
	out vec3 diffuse,
	out vec3 specular,
	out vec3 flashlight_diffuse,
	out vec3 flashlight_specular)
{
	diffuse = vec3(0.0);
	specular = vec3(0.0);
	flashlight_diffuse = vec3(0.0);
	flashlight_specular = vec3(0.0);

	if (!ris_active) {
		return;
	}

	const uint num_point_lights = uint(light_grid.clusters_[cluster_index].num_point_lights);
	for (uint j = 0u; j < num_point_lights; ++j) {
		const uint light_id = uint(light_grid.clusters_[cluster_index].point_lights[j]);
		if (light_id >= lights.m.num_point_lights) {
			continue;
		}

		const PointLight point_light = lights.m.point_lights[light_id];
		const bool is_environment = point_light.environment != 0u;
		const bool is_flashlight = point_light.flashlight != 0u;
		if (!is_environment && !is_flashlight) {
			continue;
		}

		vec3 candidate_diffuse;
		vec3 candidate_specular;
		if (!risEvaluatePointLightContribution(point_light, P, N, V, material, 1.0, true, candidate_diffuse, candidate_specular)) {
			continue;
		}

		if (is_flashlight) {
			flashlight_diffuse += candidate_diffuse;
			flashlight_specular += candidate_specular;
		} else {
			diffuse += candidate_diffuse;
			specular += candidate_specular;
		}
	}
}

void computePointLightingRIS(
	vec3 P,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	uint cluster_index,
	ivec2 pix,
	bool ris_active,
	inout vec3 diffuse,
	inout vec3 specular,
	out vec3 flashlight_diffuse,
	out vec3 flashlight_specular)
{
	flashlight_diffuse = vec3(0.0);
	flashlight_specular = vec3(0.0);

	vec3 primary_candidate_diffuse;
	vec3 primary_candidate_specular;
	vec2 primary_candidate_weights;
	risStoreInitialPointSample(
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

	vec3 always_diffuse;
	vec3 always_specular;
	computePointAlwaysSampledLights(P, N, V, material, cluster_index, ris_active, always_diffuse, always_specular, flashlight_diffuse, flashlight_specular);

	RisReservoir primary_diffuse_reservoir;
	RisReservoir primary_specular_reservoir;
	vec3 secondary_diffuse_sum = vec3(0.0);
	vec3 secondary_specular_sum = vec3(0.0);
	uint secondary_sample_count = 0u;
	risReservoirInit(primary_diffuse_reservoir);
	risReservoirInit(primary_specular_reservoir);

	if (ris_active) {
		if (any(greaterThan(primary_candidate_weights, vec2(RIS_WEIGHT_EPSILON)))) {
			risReservoirUpdate(primary_diffuse_reservoir, primary_candidate_weights.x, primary_candidate_diffuse);
			risReservoirUpdate(primary_specular_reservoir, primary_candidate_weights.y, primary_candidate_specular);
		}

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
			const RisPointSharedSample shared_sample = ris_point_shared[sample_index];

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
				const PointLight point_light = lights.m.point_lights[pool_light_ids[selected]];
				const float secondary_inv_light_pdf = diffuse_weight_sum / max(pool_weights[selected].x, RIS_WEIGHT_EPSILON);
				secondary_sample_count += 1u;
				if (risEvaluatePointLightContribution(point_light, P, N, V, material, secondary_inv_light_pdf, true, candidate_diffuse, candidate_specular)) {
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
				const PointLight point_light = lights.m.point_lights[pool_light_ids[selected]];
				const float secondary_inv_light_pdf = specular_weight_sum / max(pool_weights[selected].y, RIS_WEIGHT_EPSILON);
				secondary_sample_count += 1u;
				if (risEvaluatePointLightContribution(point_light, P, N, V, material, secondary_inv_light_pdf, true, candidate_diffuse, candidate_specular)) {
					secondary_diffuse_sum += candidate_diffuse;
					secondary_specular_sum += candidate_specular;
				}
			}
		}
	}

	diffuse += always_diffuse + risBlendPrimarySecondary(primary_diffuse_reservoir, secondary_diffuse_sum, secondary_sample_count);
	specular += always_specular + risBlendPrimarySecondary(primary_specular_reservoir, secondary_specular_sum, secondary_sample_count);

	barrier();
}

#endif // LIGHT_POINT_RIS_GLSL_INCLUDED
