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

	const uint original_light_id = reservoir.light_id;
	for (uint distance = 1u; distance <= uint(RIS_TEMPORAL_LIGHT_ID_SEARCH_RADIUS); ++distance) {
		if (original_light_id >= distance) {
			const uint previous_light_id = original_light_id - distance;
			if (RIS_LIGHT_HASH_MATCHES(previous_light_id, reservoir.light_hash)) {
				reservoir.light_id = previous_light_id;
				return true;
			}
		}

		const uint next_light_id = original_light_id + distance;
		if (next_light_id > original_light_id && RIS_LIGHT_HASH_MATCHES(next_light_id, reservoir.light_hash)) {
			reservoir.light_id = next_light_id;
			return true;
		}
	}

	// Hash is only an ID-shift recovery hint. If no neighbor matches, retain the
	// original slot and treat the mismatch as a dynamically changed light rather
	// than invalidating otherwise valid temporal history.
	RIS_LIGHT_SAMPLE current_slot_light;
	return RIS_LOAD_LIGHT(original_light_id, current_slot_light);
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
	out float current_mixed_weight,
	out float confidence_mixed_weight)
{
	reservoir = risInvalidTemporalReservoir();
	current_mixed_weight = 0.0;
	confidence_mixed_weight = 0.0;

	const vec3 prev_position = RIS_LOAD_TEMPORAL_REFERENCE_POSITION(surface_pix);
	ivec2 history_pix;
	if (!risFindTemporalHistoryPixel(pix, surface_pix, prev_position, geometry_N, history_pix)) {
	#if RIS_SAME_PIXEL_HISTORY_FALLBACK
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

#if defined(RIS_CUSTOM_TEMPORAL_HISTORY)
	// Secondary hit normals do not currently have a temporal image. Do not use
	// the primary ASVGF normal for a different surface.
	const vec3 confidence_N = N;
#else
	// The ASVGF reprojection metadata stores the exact shading normal belonging
	// to this history texel. Keep current P for area/solid-angle evaluation and
	// replace only the BRDF normal for the confidence check.
	const vec3 confidence_N = normalDecode(imageLoad(prev_temporal_asvgf_reproj_depth, history_pix).ba);
#endif
	const vec2 confidence_weights = RIS_LIGHT_WEIGHTS(history_light, P, confidence_N, V, material);
	confidence_mixed_weight = risPrimaryMixedWeight(confidence_weights, material.metalness);

	if (!RIS_LIGHT_VISIBLE(history_light, P, N)) {
		return false;
	}

	reservoir = history_reservoir;
	return true;
}

#if RIS_UNIFIED_PASS
void RIS_COMPUTE_LIGHTING_UNIFIED(
	uint cluster_index,
	vec3 P,
	vec3 geometry_N,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	ivec2 pix,
	ivec2 surface_pix,
	bool ris_active,
	out vec3 diffuse,
	out vec3 specular)
{
	diffuse = vec3(0.0);
	specular = vec3(0.0);
	RisTemporalReservoir reservoir = risInvalidTemporalReservoir();
	const uint cluster_light_count = RIS_CLUSTER_LIGHT_COUNT(cluster_index);
	uint eligible_light_count = 0u;
	for (uint i = 0u; i < cluster_light_count; ++i) {
		RIS_LIGHT_SAMPLE unused_light;
		if (RIS_LOAD_LIGHT(RIS_CLUSTER_LIGHT_ID(cluster_index, i), unused_light)) {
			eligible_light_count += 1u;
		}
	}
	const float inv_discrete_light_pdf = float(eligible_light_count);

	// Reprojection supplies one concrete light sample. Its previous reservoir
	// mass is combined using the standard ReSTIR temporal-resampling weight;
	// BRDF and visibility are always reevaluated at the current surface.
	if (ris_active) {
		const vec3 prev_position = RIS_LOAD_TEMPORAL_REFERENCE_POSITION(surface_pix);
		ivec2 history_pix;
		if (risFindTemporalHistoryPixel(pix, surface_pix, prev_position, geometry_N, history_pix)) {
				RisTemporalReservoir history = RIS_LOAD_PREVIOUS_TEMPORAL_RESERVOIR(history_pix);
				if (RIS_RESOLVE_RESERVOIR_LIGHT_ID(history)) {
				RIS_LIGHT_SAMPLE history_light;
				vec3 history_diffuse;
				vec3 history_specular;
				if (RIS_LOAD_LIGHT(history.light_id, history_light) &&
					risEvaluateConcreteSample(history_light, history.sample_random, P, N, V, material, true,
						history_diffuse, history_specular)) {
					history_diffuse *= inv_discrete_light_pdf;
					history_specular *= inv_discrete_light_pdf;
						const vec2 history_lobes = risContributionLobeWeights(history_diffuse, history_specular);
						const float current_weight = risPrimaryMixedWeight(history_lobes, material.metalness);
						if (current_weight > RIS_WEIGHT_EPSILON) {
						#if defined(RIS_CUSTOM_TEMPORAL_HISTORY)
							const vec3 confidence_N = N;
						#else
							const vec3 confidence_N = normalDecode(
								imageLoad(prev_temporal_asvgf_reproj_depth, history_pix).ba);
						#endif
							vec3 confidence_diffuse;
							vec3 confidence_specular;
							float confidence_weight = 0.0;
							if (risEvaluateConcreteSample(
								history_light, history.sample_random, P, confidence_N, V, material, false,
								confidence_diffuse, confidence_specular)) {
								confidence_diffuse *= inv_discrete_light_pdf;
								confidence_specular *= inv_discrete_light_pdf;
								confidence_weight = risPrimaryMixedWeight(
									risContributionLobeWeights(confidence_diffuse, confidence_specular),
									material.metalness);
							}
							reservoir = risReweightTemporalReservoir(
								history,
								current_weight,
								confidence_weight,
								risTemporalRandom01(pix, RIS_TEMPORAL_LIFETIME_RANDOM_SALT));
					}
				}
			}
		}
	}

	if (ris_active) {
		for (uint j = 0u; j < uint(RIS_PRIMARY_CANDIDATES); ++j) {
			if (eligible_light_count == 0u) {
				break;
			}

			const uint selected_eligible_index = min(
				uint(risTemporalRandom01(pix, RIS_PRIMARY_MERGE_RANDOM_SALT + 0x200u + j) * float(eligible_light_count)),
				eligible_light_count - 1u);
			uint eligible_index = 0u;
			uint candidate_id = RIS_INVALID_LIGHT_ID;
			RIS_LIGHT_SAMPLE candidate_light;
			for (uint i = 0u; i < cluster_light_count; ++i) {
				const uint light_id = RIS_CLUSTER_LIGHT_ID(cluster_index, i);
				RIS_LIGHT_SAMPLE light;
				if (!RIS_LOAD_LIGHT(light_id, light)) {
					continue;
				}
				if (eligible_index++ == selected_eligible_index) {
					candidate_id = light_id;
					candidate_light = light;
					break;
				}
			}
			if (candidate_id == RIS_INVALID_LIGHT_ID) {
				continue;
			}

			const vec3 sample_random = vec3(
				risTemporalRandom01(pix, RIS_PRIMARY_MERGE_RANDOM_SALT + j * 3u + 0u),
				risTemporalRandom01(pix, RIS_PRIMARY_MERGE_RANDOM_SALT + j * 3u + 1u),
				risTemporalRandom01(pix, RIS_PRIMARY_MERGE_RANDOM_SALT + j * 3u + 2u));
			vec3 candidate_diffuse;
			vec3 candidate_specular;
			if (!risEvaluateConcreteSample(candidate_light, sample_random, P, N, V, material, true,
				candidate_diffuse, candidate_specular)) {
				// Zero-target proposals still count towards M.
				reservoir.sample_count += 1.0;
				continue;
			}
			candidate_diffuse *= inv_discrete_light_pdf;
			candidate_specular *= inv_discrete_light_pdf;
			const vec2 candidate_lobes = risContributionLobeWeights(candidate_diffuse, candidate_specular);
			const float mixed_weight = risPrimaryMixedWeight(candidate_lobes, material.metalness);
			if (mixed_weight <= RIS_WEIGHT_EPSILON) {
				reservoir.sample_count += 1.0;
				continue;
			}

			RisTemporalCandidate candidate;
			candidate.light_id = candidate_id;
			candidate.light_hash = RIS_LIGHT_HASH(candidate_light);
			candidate.mixed_weight = mixed_weight;
			candidate.sample_random = sample_random;
			candidate.sample_count = 1.0;
			reservoir = risMergeTemporalCandidate(
				reservoir, candidate,
				risTemporalRandom01(pix, RIS_PRIMARY_MERGE_RANDOM_SALT + 0x100u + j));
		}
	}

	reservoir = risFinalizeTemporalReservoir(reservoir);
	if (risTemporalReservoirValid(reservoir)) {
		RIS_LIGHT_SAMPLE selected_light;
		if (RIS_LOAD_LIGHT(reservoir.light_id, selected_light)) {
			// Keep the persisted identity pair canonical: the stored hash always
			// comes directly from the light addressed by the final stored ID.
			reservoir.light_hash = RIS_LIGHT_HASH(selected_light);
			vec3 selected_diffuse;
			vec3 selected_specular;
			if (
			// Every selectable candidate already passed visibility in this invocation.
			risEvaluateConcreteSample(selected_light, reservoir.sample_random, P, N, V, material, false,
				selected_diffuse, selected_specular)) {
			selected_diffuse *= inv_discrete_light_pdf;
			selected_specular *= inv_discrete_light_pdf;
			const float reservoir_weight = reservoir.weight_sum /
				max(reservoir.sample_count * reservoir.mixed_weight, RIS_WEIGHT_EPSILON);
			diffuse = selected_diffuse * reservoir_weight;
			specular = selected_specular * reservoir_weight;
			}
		} else {
			reservoir = risInvalidTemporalReservoir();
		}
	}
	if (risReservoirPixelInBounds(pix)) {
		RIS_STORE_TEMPORAL_RESERVOIR(pix, reservoir);
	}
}
#endif

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
		visible_candidate.sample_random = vec3(0.0);
		visible_candidate.sample_count = 1.0;
		reservoir = risMergeTemporalCandidate(
			reservoir,
			visible_candidate,
			risTemporalRandom01(pix, RIS_PRIMARY_MERGE_RANDOM_SALT + j));
	}

	return reservoir;
}

#if defined(REGIR_ONION_IMAGE)
RisTemporalReservoir RIS_MERGE_REGIR_VISIBLE_CANDIDATES(
	vec3 P,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	ivec2 pix,
	RisTemporalReservoir reservoir,
	out bool accepted_any)
{
	accepted_any = false;
	uint rnd = regirHash(ubo.ubo.random_seed ^ uint(pix.x) * 1833u ^ uint(pix.y) * 31337u ^ RIS_PRIMARY_MERGE_RANDOM_SALT);
	uint cell_index;

	if (!regirSelectOnionCell(P, rnd, cell_index)) {
		return reservoir;
	}

	for (uint j = 0u; j < REGIR_ONION_LOOKUP_CANDIDATES; ++j) {
		RegirOnionCandidate onion_candidate;

		if (!regirLoadOnionCandidate(cell_index, j, rnd, onion_candidate)) {
			continue;
		}

		RIS_LIGHT_SAMPLE light;
		if (!RIS_LOAD_LIGHT(onion_candidate.light_id, light)) {
			continue;
		}

		accepted_any = true;

		const vec2 weights = RIS_LIGHT_WEIGHTS(light, P, N, V, material);
		const float mixed_weight = risPrimaryMixedWeight(weights, material.metalness);

		if (mixed_weight <= RIS_WEIGHT_EPSILON || !RIS_LIGHT_VISIBLE(light, P, N)) {
			continue;
		}

		RisTemporalCandidate candidate;
		candidate.light_id = onion_candidate.light_id;
		candidate.light_hash = RIS_LIGHT_HASH(light);
		candidate.mixed_weight = mixed_weight;
		candidate.sample_random = vec3(0.0);
		candidate.sample_count = 1.0;

		reservoir = risMergeTemporalCandidateWeighted(
			reservoir,
			candidate,
			mixed_weight * onion_candidate.inv_source_pdf,
			regirRandom(rnd));
	}

	return reservoir;
}
#endif

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
			visible_candidate.sample_random = vec3(0.0);
			visible_candidate.sample_count = 1.0;
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
			visible_candidate.sample_random = vec3(0.0);
			visible_candidate.sample_count = 1.0;
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
#if defined(RIS_REUSE_DIRECT_RESERVOIR)
	const bool reuse_only = ubo.ubo.debug_display_only == DEBUG_DISPLAY_RESERVOIR_REUSING;
	const bool reuse_enabled =
		(ubo.ubo.renderer_flags & RENDERER_FLAG_DISABLE_RESERVOIR_REUSING) == 0 ||
		reuse_only;
	bool is_diffuse_ris_reused = false;
	RisTemporalReservoir direct_reservoir = risInvalidTemporalReservoir();

	if (reuse_enabled && ris_active) {
		ivec2 direct_reservoir_pix;
		if (risFindDirectReservoirPixel(P, geometry_N, direct_reservoir_pix)) {
			direct_reservoir = RIS_LOAD_DIRECT_TEMPORAL_RESERVOIR(direct_reservoir_pix);
			is_diffuse_ris_reused = risTemporalReservoirValid(direct_reservoir);
		}
	}

	const bool skip_own_ris =
		reuse_enabled && (reuse_only || is_diffuse_ris_reused);
	const bool own_ris_active = ris_active && !skip_own_ris;
#else
	const bool is_diffuse_ris_reused = false;
	const bool skip_own_ris = false;
	const bool own_ris_active = ris_active;
#endif

	RisTemporalReservoir old_reservoir = risInvalidTemporalReservoir();
	float old_current_mixed_weight = 0.0;
	float old_confidence_mixed_weight = 0.0;
	if (own_ris_active) {
		RIS_LOAD_PREVIOUS_RESERVOIR(
			P,
			geometry_N,
			N,
			V,
			material,
			pix,
			surface_pix,
			old_reservoir,
			old_current_mixed_weight,
			old_confidence_mixed_weight);
	}

	const float temporal_rand_lifetime = risTemporalRandom01(pix, RIS_TEMPORAL_LIFETIME_RANDOM_SALT);
	RisTemporalReservoir merged_reservoir = risReweightTemporalReservoir(
		old_reservoir,
		old_current_mixed_weight,
		old_confidence_mixed_weight,
		temporal_rand_lifetime);

#if defined(RIS_REUSE_DIRECT_RESERVOIR)
	if (is_diffuse_ris_reused) {
		merged_reservoir = direct_reservoir;
	}
#endif

#if defined(REGIR_ONION_IMAGE)
	bool regir_accepted = false;
	if (own_ris_active && (ubo.ubo.renderer_flags & RENDERER_FLAG_DISABLE_REGIR) == 0u) {
		merged_reservoir = RIS_MERGE_REGIR_VISIBLE_CANDIDATES(
			P, N, V, material, pix, merged_reservoir, regir_accepted);
	}
	if (own_ris_active && !regir_accepted) {
		merged_reservoir = RIS_MERGE_VISIBLE_CANDIDATES(
			cluster_index, P, N, V, material, pix, merged_reservoir);
	}
#elif RIS_BAYER_CANDIDATE_SEGMENTS
	merged_reservoir = RIS_MERGE_BAYER_SHARED_VISIBLE_CANDIDATES(
		cluster_index,
		P,
		N,
		V,
		material,
		pix,
		surface_pix,
		own_ris_active,
		merged_reservoir);
#else
	if (own_ris_active) {
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

	RisCandidateImageSample image_candidate = risInvalidCandidateImageSample();
	if (is_diffuse_ris_reused || !skip_own_ris) {
		if (!is_diffuse_ris_reused) {
			merged_reservoir = risFinalizeTemporalReservoir(merged_reservoir);
		}

		if (risTemporalReservoirValid(merged_reservoir)) {
			RIS_LIGHT_SAMPLE merged_light;
			if (RIS_LOAD_LIGHT(merged_reservoir.light_id, merged_light)) {
				const vec2 merged_weights = RIS_LIGHT_WEIGHTS(merged_light, P, N, V, material);
				if (any(greaterThan(merged_weights, vec2(RIS_WEIGHT_EPSILON)))) {
					image_candidate.light_id = merged_reservoir.light_id;
					image_candidate.weights = merged_weights;
					image_candidate.mixed_weight = risPrimaryMixedWeight(merged_weights, material.metalness);
				} else if (!is_diffuse_ris_reused) {
					merged_reservoir = risInvalidTemporalReservoir();
				}
			} else if (!is_diffuse_ris_reused) {
				merged_reservoir = risInvalidTemporalReservoir();
			}
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
		vec2 pool_target_weights[RIS_SPATIAL_POOL_CAPACITY];
		vec2 pool_selection_masses[RIS_SPATIAL_POOL_CAPACITY];
		uint pool_count = 0u;
		vec2 selection_mass_sum = vec2(0.0);
		// Self always represents one estimator, including when it is empty.
		float confidence_sum = 1.0;
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
				pool_target_weights[pool_count] = self_weights;
				pool_selection_masses[pool_count] = self_weights;
				selection_mass_sum += self_weights;
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

			const float edge_weight = risSpatialCompatibilityWeight(pix, sample_surface_pix, P, N, sample_P, sample_N);
			if (edge_weight <= RIS_WEIGHT_EPSILON) {
				continue;
			}
			const RisCandidateImageSample image_candidate = RIS_LOAD_CANDIDATE_IMAGE_SAMPLE(sample_reservoir_pix);
			RIS_LIGHT_SAMPLE image_light;
			if (!risCandidateImageSampleValid(image_candidate) || !RIS_LOAD_LIGHT(image_candidate.light_id, image_light)) {
				continue;
			}

	#if RIS_INIT_HALF_RES
			vec2 reuse_weights = RIS_LIGHT_WEIGHTS(image_light, P, N, V, material);
	#else
			vec2 reuse_weights = max(image_candidate.weights, vec2(0.0));
	#endif
			if (!any(greaterThan(reuse_weights, vec2(RIS_WEIGHT_EPSILON)))) {
				continue;
			}

			if (pool_count < uint(RIS_SPATIAL_POOL_CAPACITY)) {
				const vec2 reuse_masses = reuse_weights * edge_weight;
				pool_light_ids[pool_count] = image_candidate.light_id;
				pool_target_weights[pool_count] = reuse_weights;
				pool_selection_masses[pool_count] = reuse_masses;
				selection_mass_sum += reuse_masses;
				confidence_sum += edge_weight;
				pool_count += 1u;
			}
		}
#endif

		if (selection_mass_sum.x > RIS_WEIGHT_EPSILON) {
			for (uint pick = 0u; pick < uint(RIS_SECONDARY_MAX_SAMPLES); ++pick) {
				if (pick >= secondary_diffuse_target_count) {
					break;
				}

				const float target_weight = risSpatialRandom01(pix, pick, 0x64696666u) * selection_mass_sum.x;
				float weight_prefix = 0.0;
				uint selected = 0u;
				for (uint i = 0u; i < uint(RIS_SPATIAL_POOL_CAPACITY); ++i) {
					if (i >= pool_count) {
						break;
					}
					if (pool_selection_masses[i].x <= RIS_WEIGHT_EPSILON) {
						continue;
					}
					weight_prefix += pool_selection_masses[i].x;
					selected = i;
					if (target_weight <= weight_prefix || i + 1u == pool_count) {
						break;
					}
				}

				vec3 candidate_diffuse;
				vec3 candidate_specular;
				const float secondary_inv_light_pdf = selection_mass_sum.x /
					max(confidence_sum * pool_target_weights[selected].x, RIS_WEIGHT_EPSILON);
				secondary_sample_count += 1u;
				RIS_LIGHT_SAMPLE selected_light;
				if (RIS_LOAD_LIGHT(pool_light_ids[selected], selected_light) &&
					RIS_EVALUATE_LIGHT(selected_light, secondary_inv_light_pdf, P, N, V, material, secondary_visibility_test, candidate_diffuse, candidate_specular)) {
					secondary_diffuse_sum += candidate_diffuse;
					secondary_specular_sum += candidate_specular;
				}
			}
		}

		if (selection_mass_sum.y > RIS_WEIGHT_EPSILON) {
			for (uint pick = 0u; pick < uint(RIS_SECONDARY_MAX_SAMPLES); ++pick) {
				if (pick >= secondary_specular_target_count) {
					break;
				}

				const float target_weight = risSpatialRandom01(pix, pick, 0x73706563u) * selection_mass_sum.y;
				float weight_prefix = 0.0;
				uint selected = 0u;
				for (uint i = 0u; i < uint(RIS_SPATIAL_POOL_CAPACITY); ++i) {
					if (i >= pool_count) {
						break;
					}
					if (pool_selection_masses[i].y <= RIS_WEIGHT_EPSILON) {
						continue;
					}
					weight_prefix += pool_selection_masses[i].y;
					selected = i;
					if (target_weight <= weight_prefix || i + 1u == pool_count) {
						break;
					}
				}

				vec3 candidate_diffuse;
				vec3 candidate_specular;
				const float secondary_inv_light_pdf = selection_mass_sum.y /
					max(confidence_sum * pool_target_weights[selected].y, RIS_WEIGHT_EPSILON);
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
