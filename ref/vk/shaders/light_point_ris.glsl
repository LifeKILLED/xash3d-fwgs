#ifndef LIGHT_POINT_RIS_GLSL_INCLUDED
#define LIGHT_POINT_RIS_GLSL_INCLUDED

#include "light_ris_common.glsl"

struct RisPointSharedSample {
	uint valid;
	uint light_id;
	uint cluster_index;
	float inv_light_pdf;
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

float risPointProposalWeight(uint light_id, vec3 P, vec3 N, vec3 V, MaterialProperties material)
{
	if (!risIsPointLightCandidate(light_id)) {
		return 0.0;
	}

	const vec2 weights = lightPointWeightCalculation(lights.m.point_lights[light_id], P, N, V, material.roughness);
	return max(weights.x + weights.y, 0.0);
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
	for (uint j = 0u; j < num_point_lights; ++j) {
		total_weight += risPointProposalWeight(uint(light_grid.clusters_[cluster_index].point_lights[j]), P, N, V, material);
	}

	if (total_weight <= RIS_WEIGHT_EPSILON) {
		light_id = 0u;
		inv_light_pdf = 0.0;
		return false;
	}

	const float target_weight = risBayerRandom01(pix, cluster_index, 0x706f696eu) * total_weight;
	float weight_prefix = 0.0;
	for (uint j = 0u; j < num_point_lights; ++j) {
		const uint candidate_id = uint(light_grid.clusters_[cluster_index].point_lights[j]);
		const float candidate_weight = risPointProposalWeight(candidate_id, P, N, V, material);
		if (candidate_weight <= RIS_WEIGHT_EPSILON) {
			continue;
		}

		weight_prefix += candidate_weight;
		if (target_weight <= weight_prefix || j + 1u == num_point_lights) {
			light_id = candidate_id;
			inv_light_pdf = total_weight / candidate_weight;
			return true;
		}
	}

	light_id = 0u;
	inv_light_pdf = 0.0;
	return false;
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
	diffuse = vec3(0.0);
	specular = vec3(0.0);
	weights = vec2(0.0);

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

	weights = lightPointWeightCalculation(point_light, P, N, V, material.roughness);
	return true;
}

void risStoreInitialPointSample(uint cluster_index, vec3 P, vec3 N, vec3 V, MaterialProperties material, ivec2 pix, bool ris_active)
{
	const uint shared_index = risLocalIndex();
	RisPointSharedSample shared_sample;
	shared_sample.valid = 0u;
	shared_sample.light_id = 0u;
	shared_sample.cluster_index = cluster_index;
	shared_sample.inv_light_pdf = 0.0;
	shared_sample.reuse_weights = vec2(0.0);
	shared_sample.source_P = P;
	shared_sample.source_N = N;

	if (ris_active) {
		uint light_id;
		float inv_light_pdf;
		if (risSelectPointLight(cluster_index, P, N, V, material, pix, light_id, inv_light_pdf)) {
			vec3 diffuse;
			vec3 specular;
			vec2 weights;
			const PointLight point_light = lights.m.point_lights[light_id];
			if (risEvaluatePointLightSample(point_light, P, N, V, material, inv_light_pdf, true, diffuse, specular, weights)) {
				shared_sample.valid = 1u;
				shared_sample.light_id = light_id;
				shared_sample.inv_light_pdf = inv_light_pdf;
				shared_sample.reuse_weights = weights;
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
		vec2 unused_weights;
		if (!risEvaluatePointLightSample(point_light, P, N, V, material, 1.0, true, candidate_diffuse, candidate_specular, unused_weights)) {
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

	risStoreInitialPointSample(cluster_index, P, N, V, material, pix, ris_active);
	barrier();

	vec3 always_diffuse;
	vec3 always_specular;
	computePointAlwaysSampledLights(P, N, V, material, cluster_index, ris_active, always_diffuse, always_specular, flashlight_diffuse, flashlight_specular);

	RisReservoir diffuse_reservoir;
	RisReservoir specular_reservoir;
	risReservoirInit(diffuse_reservoir);
	risReservoirInit(specular_reservoir);

	if (ris_active) {
		const RisPointSharedSample own_sample = ris_point_shared[risLocalIndex()];
		if (own_sample.valid != 0u && own_sample.cluster_index == cluster_index && own_sample.inv_light_pdf > 0.0) {
			vec3 candidate_diffuse;
			vec3 candidate_specular;
			vec2 candidate_weights;
			const PointLight point_light = lights.m.point_lights[own_sample.light_id];
			if (risEvaluatePointLightSample(point_light, P, N, V, material, own_sample.inv_light_pdf, true, candidate_diffuse, candidate_specular, candidate_weights)) {
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
			const RisPointSharedSample shared_sample = ris_point_shared[sample_index];

			if (shared_sample.valid == 0u || shared_sample.cluster_index != cluster_index || shared_sample.inv_light_pdf <= 0.0) {
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
				const RisPointSharedSample selected_sample = ris_point_shared[pool_indices[selected]];
				const PointLight point_light = lights.m.point_lights[selected_sample.light_id];
				if (risEvaluatePointLightSample(point_light, P, N, V, material, selected_sample.inv_light_pdf, true, candidate_diffuse, candidate_specular, candidate_weights)) {
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
				const RisPointSharedSample selected_sample = ris_point_shared[pool_indices[selected]];
				const PointLight point_light = lights.m.point_lights[selected_sample.light_id];
				if (risEvaluatePointLightSample(point_light, P, N, V, material, selected_sample.inv_light_pdf, true, candidate_diffuse, candidate_specular, candidate_weights)) {
					risReservoirUpdate(specular_reservoir, candidate_weights.y, candidate_specular);
				}
			}
		}
	}

	diffuse += always_diffuse + risReservoirResolve(diffuse_reservoir);
	specular += always_specular + risReservoirResolve(specular_reservoir);

	barrier();
}

#endif // LIGHT_POINT_RIS_GLSL_INCLUDED
