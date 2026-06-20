#ifndef LIGHT_POINT_RIS_GLSL_INCLUDED
#define LIGHT_POINT_RIS_GLSL_INCLUDED

#include "light_ris_common.glsl"

#ifndef RIS_LOAD_TEMPORAL_REFERENCE_POSITION
#define RIS_LOAD_TEMPORAL_REFERENCE_POSITION(pix_) imageLoad(geometry_prev_position, (pix_)).rgb
#endif

#ifndef RIS_POINT_OUT_CANDIDATE_IMAGE
#define RIS_POINT_OUT_CANDIDATE_IMAGE out_ris_point_candidate
#endif

#ifndef RIS_POINT_CANDIDATE_IMAGE
#define RIS_POINT_CANDIDATE_IMAGE ris_point_candidate
#endif

#ifndef RIS_POINT_OUT_TEMPORAL_RESERVOIR_IMAGE
#define RIS_POINT_OUT_TEMPORAL_RESERVOIR_IMAGE out_temporal_ris_point_reservoir
#endif

#ifndef RIS_POINT_PREV_TEMPORAL_RESERVOIR_IMAGE
#define RIS_POINT_PREV_TEMPORAL_RESERVOIR_IMAGE prev_temporal_ris_point_reservoir
#endif

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

uint risPointLightHash(uint light_id)
{
	if (light_id >= lights.m.num_point_lights) {
		return 0u;
	}

	const PointLight point_light = lights.m.point_lights[light_id];
	uint hash_value = xxhash32(uvec4(
		floatBitsToUint(point_light.origin_r2.x),
		floatBitsToUint(point_light.origin_r2.y),
		floatBitsToUint(point_light.origin_r2.z),
		floatBitsToUint(point_light.origin_r2.w)));
	hash_value ^= xxhash32(uvec4(
		floatBitsToUint(point_light.color_stopdot.x),
		floatBitsToUint(point_light.color_stopdot.y),
		floatBitsToUint(point_light.color_stopdot.z),
		floatBitsToUint(point_light.color_stopdot.w)));
	hash_value ^= xxhash32(uvec4(
		floatBitsToUint(point_light.dir_stopdot2.x),
		floatBitsToUint(point_light.dir_stopdot2.y),
		floatBitsToUint(point_light.dir_stopdot2.z),
		floatBitsToUint(point_light.dir_stopdot2.w)));
	hash_value ^= xxhash32(uvec4(
		point_light.environment,
		point_light.flashlight,
		0u,
		0u));
	return risFoldTemporalHash(hash_value);
}

#if RIS_INIT_PASS
bool risPointLightHashMatches(uint light_id, uint light_hash)
{
	return risIsPointLightCandidate(light_id) && risPointLightHash(light_id) == light_hash;
}

bool risResolvePointReservoirLightId(inout RisTemporalReservoir reservoir)
{
	if (!risTemporalReservoirValid(reservoir)) {
		return false;
	}

	if (risPointLightHashMatches(reservoir.light_id, reservoir.light_hash)) {
		return true;
	}

	if (reservoir.light_id > 0u) {
		const uint prev_light_id = reservoir.light_id - 1u;
		if (risPointLightHashMatches(prev_light_id, reservoir.light_hash)) {
			reservoir.light_id = prev_light_id;
			return true;
		}
	}

	const uint next_light_id = reservoir.light_id + 1u;
	if (next_light_id > reservoir.light_id && risPointLightHashMatches(next_light_id, reservoir.light_hash)) {
		reservoir.light_id = next_light_id;
		return true;
	}

	return false;
}

bool risLoadPreviousPointReservoir(
	vec3 P,
	vec3 geometry_N,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	ivec2 pix,
	out RisTemporalReservoir reservoir,
	out float current_mixed_weight,
	out bool temporal_reprojection_found)
{
	reservoir = risInvalidTemporalReservoir();
	current_mixed_weight = 0.0;
	temporal_reprojection_found = (ubo.ubo.renderer_flags & RENDERER_FLAG_DISABLE_REPROJECTION) != 0;

	const vec3 prev_position = RIS_LOAD_TEMPORAL_REFERENCE_POSITION(pix);
	ivec2 history_pix;
	if (!risFindTemporalHistoryPixel(pix, prev_position, geometry_N, history_pix)) {
		return false;
	}
	temporal_reprojection_found = true;

	RisTemporalReservoir history_reservoir = risDecodeTemporalReservoir(imageLoad(RIS_POINT_PREV_TEMPORAL_RESERVOIR_IMAGE, history_pix));
	if (!risResolvePointReservoirLightId(history_reservoir)) {
		return false;
	}

	const vec2 current_weights = risPointProposalWeights(history_reservoir.light_id, P, N, V, material);
	current_mixed_weight = risPrimaryMixedWeight(current_weights, material.metalness);
	if (current_mixed_weight <= RIS_WEIGHT_EPSILON) {
		return false;
	}

	reservoir = history_reservoir;
	return true;
}
#endif

bool risSelectPointLight(
	uint cluster_index,
	vec3 P,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	ivec2 pix,
	bool first_frame_of_texel,
	out uint light_id,
	out float inv_light_pdf)
{
	float total_weight = 0.0;
	const uint num_point_lights = uint(light_grid.clusters_[cluster_index].num_point_lights);
	const uint candidate_count = risPrimaryCandidateCount(num_point_lights, first_frame_of_texel);
	if (candidate_count == 0u) {
		light_id = 0u;
		inv_light_pdf = 0.0;
		return false;
	}

	uint candidate_ids[RIS_FIRST_FRAME_OF_TEXEL_CANDIDATES_COUNT];
	float candidate_weights[RIS_FIRST_FRAME_OF_TEXEL_CANDIDATES_COUNT];
	for (uint j = 0u; j < uint(RIS_FIRST_FRAME_OF_TEXEL_CANDIDATES_COUNT); ++j) {
		if (j >= candidate_count) {
			break;
		}

		const uint candidate_index = risPrimaryCandidateIndex(num_point_lights, candidate_count, j);
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

	const float target_weight = rand01() * total_weight;
	float weight_prefix = 0.0;
	for (uint j = 0u; j < uint(RIS_FIRST_FRAME_OF_TEXEL_CANDIDATES_COUNT); ++j) {
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

bool risProbePointLightVisibility(uint light_id, vec3 P, vec3 N)
{
	if (!risIsPointLightCandidate(light_id)) {
		return false;
	}

	const PointLight point_light = lights.m.point_lights[light_id];
	const vec3 light_pos = point_light.origin_r2.xyz;
	const float light_r2 = point_light.origin_r2.w;
	const vec3 to_light = light_pos - P;
	const float light_dist2 = dot(to_light, to_light);
	const float d2_minus_r2 = light_dist2 - light_r2;
	if (d2_minus_r2 <= 0.0) {
		return false;
	}

	const float light_dist = sqrt(light_dist2);
	const float cos_theta_max = min(1.0, sqrt(d2_minus_r2 / light_dist2));
	const vec3 dir_sample_z = sampleConeZ(vec2(rand01(), rand01()), cos_theta_max);
	const vec3 light_dir = normalize(orthonormalBasisZ(to_light / light_dist) * dir_sample_z);

	if (dot(light_dir, N) < 1e-5) {
		return false;
	}

	if (dot(light_dir, point_light.dir_stopdot2.xyz) < point_light.dir_stopdot2.a) {
		return false;
	}

	return !shadowed(P, light_dir, light_dist + shadow_offset_fudge);
}

#if RIS_INIT_PASS
void computePointLightingRISInit(
	uint cluster_index,
	vec3 P,
	vec3 geometry_N,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	ivec2 pix,
	bool ris_active)
{
	RisTemporalReservoir old_reservoir = risInvalidTemporalReservoir();
	float old_current_mixed_weight = 0.0;
	bool temporal_reprojection_found = false;
	if (ris_active) {
		risLoadPreviousPointReservoir(
			P,
			geometry_N,
			N,
			V,
			material,
			pix,
			old_reservoir,
			old_current_mixed_weight,
			temporal_reprojection_found);
	}
	const bool first_frame_of_texel = ris_active && !temporal_reprojection_found;

	RisTemporalCandidate new_candidate;
	new_candidate.light_id = RIS_INVALID_LIGHT_ID;
	new_candidate.light_hash = 0u;
	new_candidate.mixed_weight = 0.0;

	if (ris_active) {
		uint light_id;
		float inv_light_pdf;
		if (risSelectPointLight(cluster_index, P, N, V, material, pix, first_frame_of_texel, light_id, inv_light_pdf)) {
			const vec2 weights = risPointProposalWeights(light_id, P, N, V, material);
			if (any(greaterThan(weights, vec2(RIS_WEIGHT_EPSILON)))) {
				new_candidate.light_id = light_id;
				new_candidate.light_hash = risPointLightHash(light_id);
				new_candidate.mixed_weight = risPrimaryMixedWeight(weights, material.metalness);
			}
		}
	}

	const float temporal_rand_reset = risTemporalRandom01(pix, 0x72737440u);
	const float temporal_rand_lifetime = risTemporalRandom01(pix, 0x72737441u);
	RisTemporalReservoir merged_reservoir = risUpdateTemporalReservoir(
		old_reservoir,
		old_current_mixed_weight,
		new_candidate,
		temporal_rand_reset,
		temporal_rand_lifetime,
		risTemporalRandom01(pix, 0x72737442u));

	RisCandidateImageSample image_candidate = risInvalidCandidateImageSample();
	if (risTemporalReservoirValid(merged_reservoir)) {
		if (risProbePointLightVisibility(merged_reservoir.light_id, P, N)) {
			const vec2 merged_weights = risPointProposalWeights(merged_reservoir.light_id, P, N, V, material);
			if (any(greaterThan(merged_weights, vec2(RIS_WEIGHT_EPSILON)))) {
				image_candidate.light_id = merged_reservoir.light_id;
				image_candidate.weights = merged_weights;
				image_candidate.mixed_weight = risPrimaryMixedWeight(merged_weights, material.metalness);
			} else {
				merged_reservoir = risInvalidTemporalReservoir();
			}
		} else {
			merged_reservoir = risInvalidTemporalReservoir();
		}
	}

	if (risPixelInBounds(pix)) {
		imageStore(RIS_POINT_OUT_TEMPORAL_RESERVOIR_IMAGE, pix, risEncodeTemporalReservoir(merged_reservoir));
		imageStore(RIS_POINT_OUT_CANDIDATE_IMAGE, pix, risEncodeCandidateImageSample(image_candidate));
	}
}
#endif

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

#if RIS_APPLY_PASS
void computePointLightingRISApply(
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

	vec3 always_diffuse;
	vec3 always_specular;
	computePointAlwaysSampledLights(P, N, V, material, cluster_index, ris_active, always_diffuse, always_specular, flashlight_diffuse, flashlight_specular);

	vec3 secondary_diffuse_sum = vec3(0.0);
	vec3 secondary_specular_sum = vec3(0.0);
	uint secondary_sample_count = 0u;
	const bool secondary_visibility_test = RIS_APPLY_VISIBILITY_TEST != 0;

	if (ris_active) {
		uint pool_light_ids[RIS_SPATIAL_POOL_CAPACITY];
		vec2 pool_weights[RIS_SPATIAL_POOL_CAPACITY];
		uint pool_count = 0u;
		float diffuse_weight_sum = 0.0;
		float specular_weight_sum = 0.0;
		uint secondary_diffuse_target_count;
		uint secondary_specular_target_count;
		risSecondarySampleCounts(material.metalness, secondary_diffuse_target_count, secondary_specular_target_count);

		const RisCandidateImageSample self_candidate = risDecodeCandidateImageSample(imageLoad(RIS_POINT_CANDIDATE_IMAGE, pix));
		if (risCandidateImageSampleValid(self_candidate) && risIsPointLightCandidate(self_candidate.light_id)) {
			const vec2 self_weights = max(self_candidate.weights, vec2(0.0));
			if (any(greaterThan(self_weights, vec2(RIS_WEIGHT_EPSILON)))) {
				pool_light_ids[pool_count] = self_candidate.light_id;
				pool_weights[pool_count] = self_weights;
				diffuse_weight_sum += self_weights.x;
				specular_weight_sum += self_weights.y;
				pool_count += 1u;
			}
		}

		for (uint i = 0u; i < RIS_POISSON_POOL_SIZE; ++i) {
			const ivec2 sample_pix = pix + risPoissonNeighborOffset(i, pix);
			if (!risPixelInBounds(sample_pix)) {
				continue;
			}
			if (!RIS_SPATIAL_SAMPLE_COMPATIBLE(pix, sample_pix)) {
				continue;
			}

			const RisCandidateImageSample image_candidate = risDecodeCandidateImageSample(imageLoad(RIS_POINT_CANDIDATE_IMAGE, sample_pix));
			if (!risCandidateImageSampleValid(image_candidate) || !risIsPointLightCandidate(image_candidate.light_id)) {
				continue;
			}

			vec3 sample_P;
			vec3 sample_N;
			if (!risLoadSpatialSurface(sample_pix, sample_P, sample_N)) {
				continue;
			}

			const float edge_weight = risSurfaceCompatibilityWeight(P, N, sample_P, sample_N);
			if (edge_weight <= RIS_WEIGHT_EPSILON) {
				continue;
			}

			vec2 reuse_weights = max(image_candidate.weights, vec2(0.0)) * edge_weight;
			if (!any(greaterThan(reuse_weights, vec2(RIS_WEIGHT_EPSILON)))) {
				continue;
			}

			if (pool_count < uint(RIS_SPATIAL_POOL_CAPACITY)) {
				pool_light_ids[pool_count] = image_candidate.light_id;
				pool_weights[pool_count] = reuse_weights;
				diffuse_weight_sum += reuse_weights.x;
				specular_weight_sum += reuse_weights.y;
				pool_count += 1u;
			}
		}

		if (diffuse_weight_sum > RIS_WEIGHT_EPSILON) {
			for (uint pick = 0u; pick < uint(RIS_SECONDARY_MAX_SAMPLES); ++pick) {
				if (pick >= secondary_diffuse_target_count) {
					break;
				}

				const float target_weight = risSpatialRandom01(pix, pick, 0x64696666u) * diffuse_weight_sum;
				float weight_prefix = 0.0;
				uint selected = 0u;
				for (uint i = 0u; i < uint(RIS_SPATIAL_POOL_CAPACITY); ++i) {
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
				if (risEvaluatePointLightContribution(point_light, P, N, V, material, secondary_inv_light_pdf, secondary_visibility_test, candidate_diffuse, candidate_specular)) {
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
				for (uint i = 0u; i < uint(RIS_SPATIAL_POOL_CAPACITY); ++i) {
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
				if (risEvaluatePointLightContribution(point_light, P, N, V, material, secondary_inv_light_pdf, secondary_visibility_test, candidate_diffuse, candidate_specular)) {
					secondary_diffuse_sum += candidate_diffuse;
					secondary_specular_sum += candidate_specular;
				}
			}
		}
	}

	diffuse += always_diffuse + risResolveSampleAverage(secondary_diffuse_sum, secondary_sample_count);
	specular += always_specular + risResolveSampleAverage(secondary_specular_sum, secondary_sample_count);
}
#endif

#endif // LIGHT_POINT_RIS_GLSL_INCLUDED
