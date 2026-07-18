#if !defined(RIS_LIGHT_SAMPLE)
#error RIS_LIGHT_SAMPLE must be defined before including light_ris_template.glsl
#endif

#if !defined(RIS_LOAD_LIGHT)
#error RIS_LOAD_LIGHT must be defined before including light_ris_template.glsl
#endif

#if !defined(RIS_CLUSTER_LIGHT_COUNT) || !defined(RIS_CLUSTER_LIGHT_ID)
#error RIS_CLUSTER_LIGHT_COUNT and RIS_CLUSTER_LIGHT_ID must be defined before including light_ris_template.glsl
#endif

#if !defined(RIS_LIGHT_WEIGHTS) || !defined(RIS_LIGHT_HASH) || !defined(RIS_LIGHT_VISIBLE) || !defined(RIS_EVALUATE_LIGHT)
#error RIS light weight/hash/visibility/evaluate functions must be defined before including light_ris_template.glsl
#endif

#if RIS_INIT_PASS
bool RIS_LIGHT_HASH_MATCHES(uint light_id, uint light_hash)
{
	RIS_LIGHT_SAMPLE light;
	return RIS_LOAD_LIGHT(light_id, light) && RIS_LIGHT_HASH(light) == light_hash;
}

bool RIS_RESOLVE_RESERVOIR_LIGHT_ID(inout RisTemporalReservoir reservoir)
{
	if (!risTemporalReservoirValid(reservoir)) {
		return false;
	}

	if (RIS_LIGHT_HASH_MATCHES(reservoir.light_id, reservoir.light_hash)) {
		return true;
	}

	if (reservoir.light_id > 0u) {
		const uint prev_light_id = reservoir.light_id - 1u;
		if (RIS_LIGHT_HASH_MATCHES(prev_light_id, reservoir.light_hash)) {
			reservoir.light_id = prev_light_id;
			return true;
		}
	}

	const uint next_light_id = reservoir.light_id + 1u;
	if (next_light_id > reservoir.light_id && RIS_LIGHT_HASH_MATCHES(next_light_id, reservoir.light_hash)) {
		reservoir.light_id = next_light_id;
		return true;
	}

	return false;
}

bool RIS_LOAD_PREVIOUS_RESERVOIR(
	vec3 P,
	vec3 geometry_N,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	ivec2 pix,
	ivec2 surface_pix,
	out RisTemporalReservoir reservoir,
	out float current_mixed_weight)
{
	reservoir = risInvalidTemporalReservoir();
	current_mixed_weight = 0.0;

	const vec3 prev_position = RIS_LOAD_TEMPORAL_REFERENCE_POSITION(surface_pix);
	ivec2 history_pix;
	if (!risFindTemporalHistoryPixel(pix, surface_pix, prev_position, geometry_N, history_pix)) {
	#if RIS_SAME_PIXEL_HISTORY_FALLBACK
		if ((ubo.ubo.renderer_flags & RENDERER_FLAG_DISABLE_REPROJECTION) != 0) {
			return false;
		}
		history_pix = pix;
	#else
		return false;
	#endif
	}

	RisTemporalReservoir history_reservoir = RIS_LOAD_PREVIOUS_TEMPORAL_RESERVOIR(history_pix);
	if (!RIS_RESOLVE_RESERVOIR_LIGHT_ID(history_reservoir)) {
		return false;
	}

	RIS_LIGHT_SAMPLE history_light;
	if (!RIS_LOAD_LIGHT(history_reservoir.light_id, history_light)) {
		return false;
	}

	const vec2 current_weights = RIS_LIGHT_WEIGHTS(history_light, P, N, V, material);
	current_mixed_weight = risPrimaryMixedWeight(current_weights, material.metalness);
	if (current_mixed_weight <= RIS_WEIGHT_EPSILON) {
		return false;
	}

	if (!RIS_LIGHT_VISIBLE(history_light, P, N)) {
		return false;
	}

	reservoir = history_reservoir;
	return true;
}

RisTemporalReservoir RIS_MERGE_VISIBLE_CANDIDATES(
	uint cluster_index,
	vec3 P,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	ivec2 pix,
	RisTemporalReservoir reservoir)
{
	const uint num_lights = RIS_CLUSTER_LIGHT_COUNT(cluster_index);
	const uint candidate_count = risPrimaryCandidateScanCount(num_lights);
	const uint candidate_start_index = risPrimaryCandidateStartIndex(num_lights);
	uint candidate_ordinal = 0u;

	for (uint j = 0u; j < uint(RIS_PRIMARY_CANDIDATES); ++j) {
		if (candidate_ordinal >= candidate_count) {
			break;
		}

		uint selected_id = RIS_INVALID_LIGHT_ID;
		float selected_mixed_weight = 0.0;
		for (uint scan = 0u; scan < uint(RIS_PRIMARY_CANDIDATE_SCAN_WINDOW); ++scan) {
			if (candidate_ordinal >= candidate_count) {
				break;
			}

			const uint candidate_index = risPrimaryCandidateIndex(num_lights, candidate_start_index, candidate_ordinal);
			candidate_ordinal++;

			const uint candidate_id = RIS_CLUSTER_LIGHT_ID(cluster_index, candidate_index);
			RIS_LIGHT_SAMPLE candidate_light;
			if (!RIS_LOAD_LIGHT(candidate_id, candidate_light)) {
				continue;
			}

			const vec2 weights = RIS_LIGHT_WEIGHTS(candidate_light, P, N, V, material);
			const float mixed_weight = risPrimaryMixedWeight(weights, material.metalness);
			if (mixed_weight <= RIS_WEIGHT_EPSILON) {
				continue;
			}

			selected_id = candidate_id;
			selected_mixed_weight = mixed_weight;
			break;
		}

		if (selected_id == RIS_INVALID_LIGHT_ID) {
			continue;
		}

		RIS_LIGHT_SAMPLE selected_light;
		if (!RIS_LOAD_LIGHT(selected_id, selected_light)) {
			continue;
		}

		if (!RIS_LIGHT_VISIBLE(selected_light, P, N)) {
			continue;
		}

		RisTemporalCandidate visible_candidate;
		visible_candidate.light_id = selected_id;
		visible_candidate.light_hash = RIS_LIGHT_HASH(selected_light);
		visible_candidate.mixed_weight = selected_mixed_weight;
		reservoir = risMergeTemporalCandidate(
			reservoir,
			visible_candidate,
			risTemporalRandom01(pix, RIS_PRIMARY_MERGE_RANDOM_SALT + j));
	}

	return reservoir;
}

#if RIS_BAYER_CANDIDATE_SEGMENTS
RisTemporalReservoir RIS_MERGE_BAYER_SHARED_VISIBLE_CANDIDATES(
	uint cluster_index,
	vec3 P,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	ivec2 pix,
	ivec2 surface_pix,
	bool ris_active,
	RisTemporalReservoir reservoir)
{
	const uint local_index = risBayerLocalInvocationIndex();
	uint visible_mask = 0u;

	if (ris_active) {
		const uint num_lights = RIS_CLUSTER_LIGHT_COUNT(cluster_index);
		uint segment_begin;
		uint segment_count;
		risBayerSegmentRange(num_lights, risBayerIndex(pix), segment_begin, segment_count);

		for (uint bit_index = 0u; bit_index < uint(RIS_BAYER_SEGMENT_MAX_CANDIDATES); ++bit_index) {
			if (bit_index >= segment_count) {
				break;
			}

			const uint candidate_index = segment_begin + bit_index;
			const uint candidate_id = RIS_CLUSTER_LIGHT_ID(cluster_index, candidate_index);
			RIS_LIGHT_SAMPLE candidate_light;
			if (!RIS_LOAD_LIGHT(candidate_id, candidate_light)) {
				continue;
			}

			const vec2 weights = RIS_LIGHT_WEIGHTS(candidate_light, P, N, V, material);
			const float mixed_weight = risPrimaryMixedWeight(weights, material.metalness);
			if (mixed_weight <= RIS_WEIGHT_EPSILON) {
				continue;
			}

			if (!RIS_LIGHT_VISIBLE(candidate_light, P, N)) {
				continue;
			}

			visible_mask |= 1u << bit_index;

			RisTemporalCandidate visible_candidate;
			visible_candidate.light_id = candidate_id;
			visible_candidate.light_hash = RIS_LIGHT_HASH(candidate_light);
			visible_candidate.mixed_weight = mixed_weight;
			reservoir = risMergeTemporalCandidate(
				reservoir,
				visible_candidate,
				risTemporalRandom01(pix, RIS_BAYER_OWN_RANDOM_SALT + bit_index));
		}

	}

#if RIS_BAYER_SHARED_VISIBILITY
	if (ris_active) {
		RIS_STORE_BAYER_VISIBILITY(local_index, cluster_index, visible_mask);
	} else {
		RIS_STORE_BAYER_VISIBILITY(local_index, RIS_INVALID_LIGHT_ID, visible_mask);
	}

	memoryBarrierShared();
	barrier();

	if (!ris_active) {
		return reservoir;
	}

	const ivec2 self_local_pix = ivec2(gl_LocalInvocationID.xy);
	for (uint sample_index = 0u; sample_index < uint(RIS_BAYER_SEGMENT_COUNT); ++sample_index) {
		const ivec2 sample_local_pix = risBayerGatherSampleLocal(sample_index);
		if (all(equal(sample_local_pix, self_local_pix))) {
			continue;
		}

		const uint sample_local_index = risBayerLocalIndex(sample_local_pix);
		uint sample_cluster_index;
		uint sample_visible_mask;
		RIS_LOAD_BAYER_VISIBILITY(sample_local_index, sample_cluster_index, sample_visible_mask);
		if (sample_cluster_index >= MAX_LIGHT_CLUSTERS || sample_visible_mask == 0u) {
			continue;
		}

		const ivec2 sample_pix = risBayerLocalToPixel(pix, sample_local_pix);
		if (!risReservoirPixelInBounds(sample_pix)) {
			continue;
		}
		ivec2 sample_surface_pix;
		if (!risSelectReservoirSurfacePixel(sample_pix, sample_surface_pix) ||
			!RIS_SPATIAL_SAMPLE_COMPATIBLE(surface_pix, sample_surface_pix)) {
			continue;
		}

#ifndef RIS_CUSTOM_SURFACE_COMPATIBILITY_WEIGHT
		vec3 sample_P;
		vec3 sample_N;
		if (!risLoadSpatialSurface(sample_surface_pix, sample_P, sample_N)) {
			continue;
		}

		if (risSpatialCompatibilityWeight(surface_pix, sample_surface_pix, P, N, sample_P, sample_N) <= RIS_WEIGHT_EPSILON) {
			continue;
		}
#endif

		const uint num_lights = RIS_CLUSTER_LIGHT_COUNT(sample_cluster_index);
		uint segment_begin;
		uint segment_count;
		risBayerSegmentRange(num_lights, risBayerIndex(sample_pix), segment_begin, segment_count);

		for (uint bit_index = 0u; bit_index < uint(RIS_BAYER_SEGMENT_MAX_CANDIDATES); ++bit_index) {
			if (bit_index >= segment_count) {
				break;
			}
			if (!risBayerMaskBitSet(sample_visible_mask, bit_index)) {
				continue;
			}

			const uint candidate_index = segment_begin + bit_index;
			const uint candidate_id = RIS_CLUSTER_LIGHT_ID(sample_cluster_index, candidate_index);
			RIS_LIGHT_SAMPLE candidate_light;
			if (!RIS_LOAD_LIGHT(candidate_id, candidate_light)) {
				continue;
			}

			const vec2 weights = RIS_LIGHT_WEIGHTS(candidate_light, P, N, V, material);
			const float mixed_weight = risPrimaryMixedWeight(weights, material.metalness);
			if (mixed_weight <= RIS_WEIGHT_EPSILON) {
				continue;
			}

			RisTemporalCandidate visible_candidate;
			visible_candidate.light_id = candidate_id;
			visible_candidate.light_hash = RIS_LIGHT_HASH(candidate_light);
			visible_candidate.mixed_weight = mixed_weight;
			reservoir = risMergeTemporalCandidate(
				reservoir,
				visible_candidate,
				risTemporalRandom01(
					pix,
					RIS_BAYER_NEIGHBOR_RANDOM_SALT + sample_index * uint(RIS_BAYER_SEGMENT_MAX_CANDIDATES) + bit_index));
		}
	}
#endif

	return reservoir;
}
#endif

void RIS_COMPUTE_LIGHTING_INIT(
	uint cluster_index,
	vec3 P,
	vec3 geometry_N,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	ivec2 pix,
	ivec2 surface_pix,
	bool ris_active)
{
	RisTemporalReservoir old_reservoir = risInvalidTemporalReservoir();
	float old_current_mixed_weight = 0.0;
	if (ris_active) {
		RIS_LOAD_PREVIOUS_RESERVOIR(
			P,
			geometry_N,
			N,
			V,
			material,
			pix,
			surface_pix,
			old_reservoir,
			old_current_mixed_weight);
	}

	const float temporal_rand_reset = risTemporalRandom01(pix, RIS_TEMPORAL_RESET_RANDOM_SALT);
	const float temporal_rand_lifetime = risTemporalRandom01(pix, RIS_TEMPORAL_LIFETIME_RANDOM_SALT);
	RisTemporalReservoir merged_reservoir = risReweightTemporalReservoir(
		old_reservoir,
		old_current_mixed_weight,
		temporal_rand_reset,
		temporal_rand_lifetime);

#if RIS_BAYER_CANDIDATE_SEGMENTS
	merged_reservoir = RIS_MERGE_BAYER_SHARED_VISIBLE_CANDIDATES(
		cluster_index,
		P,
		N,
		V,
		material,
		pix,
		surface_pix,
		ris_active,
		merged_reservoir);
#else
	if (ris_active) {
		merged_reservoir = RIS_MERGE_VISIBLE_CANDIDATES(
			cluster_index,
			P,
			N,
			V,
			material,
			pix,
			merged_reservoir);
	}
#endif
	merged_reservoir = risFinalizeTemporalReservoir(merged_reservoir);

	RisCandidateImageSample image_candidate = risInvalidCandidateImageSample();
	if (risTemporalReservoirValid(merged_reservoir)) {
		RIS_LIGHT_SAMPLE merged_light;
		if (RIS_LOAD_LIGHT(merged_reservoir.light_id, merged_light)) {
			const vec2 merged_weights = RIS_LIGHT_WEIGHTS(merged_light, P, N, V, material);
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

	if (risReservoirPixelInBounds(pix)) {
		RIS_STORE_TEMPORAL_RESERVOIR(pix, merged_reservoir);
		RIS_STORE_CANDIDATE_IMAGE_SAMPLE(pix, image_candidate);
	}
}
#endif

#if RIS_APPLY_PASS
void RIS_COMPUTE_LIGHTING_APPLY(
	vec3 P,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	ivec2 pix,
	bool ris_active,
	out vec3 diffuse,
	out vec3 specular)
{
	diffuse = vec3(0.0);
	specular = vec3(0.0);
	risSetDirectSpecularMisRay(pix);

	vec3 secondary_diffuse_sum = vec3(0.0);
	vec3 secondary_specular_sum = vec3(0.0);
	uint secondary_sample_count = 0u;
	const bool secondary_visibility_test = RIS_APPLY_VISIBILITY_TEST != 0;

	const ivec2 reservoir_pix = RIS_RESERVOIR_PIXEL_FROM_SURFACE(pix);
	if (ris_active && risReservoirPixelInBounds(reservoir_pix)) {
		uint pool_light_ids[RIS_SPATIAL_POOL_CAPACITY];
		vec2 pool_weights[RIS_SPATIAL_POOL_CAPACITY];
		uint pool_count = 0u;
		float diffuse_weight_sum = 0.0;
		float specular_weight_sum = 0.0;
		uint secondary_diffuse_target_count;
		uint secondary_specular_target_count;
		risSecondarySampleCounts(material.metalness, secondary_diffuse_target_count, secondary_specular_target_count);

		const RisCandidateImageSample self_candidate = RIS_LOAD_CANDIDATE_IMAGE_SAMPLE(reservoir_pix);
		RIS_LIGHT_SAMPLE self_light;
		if (risCandidateImageSampleValid(self_candidate) && RIS_LOAD_LIGHT(self_candidate.light_id, self_light)) {
	#if RIS_INIT_HALF_RES
			const vec2 self_weights = RIS_LIGHT_WEIGHTS(self_light, P, N, V, material);
	#else
			const vec2 self_weights = max(self_candidate.weights, vec2(0.0));
	#endif
			if (any(greaterThan(self_weights, vec2(RIS_WEIGHT_EPSILON)))) {
				pool_light_ids[pool_count] = self_candidate.light_id;
				pool_weights[pool_count] = self_weights;
				diffuse_weight_sum += self_weights.x;
				specular_weight_sum += self_weights.y;
				pool_count += 1u;
			}
		}

#if RIS_APPLY_SPATIAL_REUSE
		for (uint i = 0u; i < RIS_POISSON_POOL_SIZE; ++i) {
			const ivec2 sample_reservoir_pix = reservoir_pix + risPoissonNeighborOffset(i, reservoir_pix);
			if (!risReservoirPixelInBounds(sample_reservoir_pix)) {
				continue;
			}

			ivec2 sample_surface_pix;
			vec3 sample_P;
			vec3 sample_N;
			if (!risLoadReservoirSpatialSurface(sample_reservoir_pix, sample_surface_pix, sample_P, sample_N)) {
				continue;
			}
			if (!RIS_SPATIAL_SAMPLE_COMPATIBLE(pix, sample_surface_pix)) {
				continue;
			}

			const RisCandidateImageSample image_candidate = RIS_LOAD_CANDIDATE_IMAGE_SAMPLE(sample_reservoir_pix);
			RIS_LIGHT_SAMPLE image_light;
			if (!risCandidateImageSampleValid(image_candidate) || !RIS_LOAD_LIGHT(image_candidate.light_id, image_light)) {
				continue;
			}

			const float edge_weight = risSpatialCompatibilityWeight(pix, sample_surface_pix, P, N, sample_P, sample_N);
			if (edge_weight <= RIS_WEIGHT_EPSILON) {
				continue;
			}

	#if RIS_INIT_HALF_RES
			vec2 reuse_weights = RIS_LIGHT_WEIGHTS(image_light, P, N, V, material) * edge_weight;
	#else
			vec2 reuse_weights = max(image_candidate.weights, vec2(0.0)) * edge_weight;
	#endif
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
#endif

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
				const float secondary_inv_light_pdf = diffuse_weight_sum / max(pool_weights[selected].x, RIS_WEIGHT_EPSILON);
				secondary_sample_count += 1u;
				RIS_LIGHT_SAMPLE selected_light;
				if (RIS_LOAD_LIGHT(pool_light_ids[selected], selected_light) &&
					RIS_EVALUATE_LIGHT(selected_light, secondary_inv_light_pdf, P, N, V, material, secondary_visibility_test, candidate_diffuse, candidate_specular)) {
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
				const float secondary_inv_light_pdf = specular_weight_sum / max(pool_weights[selected].y, RIS_WEIGHT_EPSILON);
				secondary_sample_count += 1u;
				RIS_LIGHT_SAMPLE selected_light;
				if (RIS_LOAD_LIGHT(pool_light_ids[selected], selected_light) &&
					RIS_EVALUATE_LIGHT(selected_light, secondary_inv_light_pdf, P, N, V, material, secondary_visibility_test, candidate_diffuse, candidate_specular)) {
					secondary_diffuse_sum += candidate_diffuse;
					secondary_specular_sum += candidate_specular;
				}
			}
		}
	}

	diffuse = risResolveSampleAverage(secondary_diffuse_sum, secondary_sample_count);
	specular = risResolveSampleAverage(secondary_specular_sum, secondary_sample_count);
}
#endif
