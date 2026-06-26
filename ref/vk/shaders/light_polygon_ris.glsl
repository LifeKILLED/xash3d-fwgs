#ifndef LIGHT_POLYGON_RIS_GLSL_INCLUDED
#define LIGHT_POLYGON_RIS_GLSL_INCLUDED

#define MAX_POLYGON_VERTEX_COUNT 8

#include "utils.glsl"
#include "light_ris_common.glsl"
#include "peters2021-sampling/polygon_sampling.glsl"

#ifndef RIS_LOAD_TEMPORAL_REFERENCE_POSITION
#define RIS_LOAD_TEMPORAL_REFERENCE_POSITION(pix_) imageLoad(geometry_prev_position, (pix_)).rgb
#endif

#ifndef RIS_POLY_OUT_CANDIDATE_IMAGE
#define RIS_POLY_OUT_CANDIDATE_IMAGE out_ris_poly_candidate
#endif

#ifndef RIS_POLY_CANDIDATE_IMAGE
#define RIS_POLY_CANDIDATE_IMAGE ris_poly_candidate
#endif

#ifndef RIS_POLY_OUT_TEMPORAL_RESERVOIR_IMAGE
#define RIS_POLY_OUT_TEMPORAL_RESERVOIR_IMAGE out_temporal_ris_poly_reservoir
#endif

#ifndef RIS_POLY_PREV_TEMPORAL_RESERVOIR_IMAGE
#define RIS_POLY_PREV_TEMPORAL_RESERVOIR_IMAGE prev_temporal_ris_poly_reservoir
#endif

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
		poly.vertices_count_offset >> 16));

	const uint vertices_offset = poly.vertices_count_offset & 0xffffu;
	const uint vertices_count = poly.vertices_count_offset >> 16;
	for (uint i = 0u; i < uint(MAX_POLYGON_VERTEX_COUNT); ++i) {
		if (i >= vertices_count) {
			break;
		}

		const vec3 vertex = lights.m.polygon_vertices[vertices_offset + i].xyz;
		hash_value ^= xxhash32(uvec4(
			floatBitsToUint(vertex.x),
			floatBitsToUint(vertex.y),
			floatBitsToUint(vertex.z),
			i));
	}
	return risFoldTemporalHash(hash_value);
}

#if RIS_INIT_PASS
bool risProbePolygonLightVisibility(uint light_id, vec3 P);

#if RIS_BAYER_SHARED_VISIBILITY
shared uint risPolygonBayerClusterIndices[RIS_BAYER_WORKGROUP_SIZE];
shared uint risPolygonBayerVisibleMasks[RIS_BAYER_WORKGROUP_SIZE];
#endif

bool risPolygonLightHashMatches(uint light_id, uint light_hash)
{
	return light_id < lights.m.num_polygons && risPolygonLightHash(light_id) == light_hash;
}

bool risResolvePolygonReservoirLightId(inout RisTemporalReservoir reservoir)
{
	if (!risTemporalReservoirValid(reservoir)) {
		return false;
	}

	if (risPolygonLightHashMatches(reservoir.light_id, reservoir.light_hash)) {
		return true;
	}

	if (reservoir.light_id > 0u) {
		const uint prev_light_id = reservoir.light_id - 1u;
		if (risPolygonLightHashMatches(prev_light_id, reservoir.light_hash)) {
			reservoir.light_id = prev_light_id;
			return true;
		}
	}

	const uint next_light_id = reservoir.light_id + 1u;
	if (next_light_id > reservoir.light_id && risPolygonLightHashMatches(next_light_id, reservoir.light_hash)) {
		reservoir.light_id = next_light_id;
		return true;
	}

	return false;
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

	const vec3 prev_position = RIS_LOAD_TEMPORAL_REFERENCE_POSITION(pix);
	ivec2 history_pix;
	if (!risFindTemporalHistoryPixel(pix, prev_position, geometry_N, history_pix)) {
		return false;
	}

	RisTemporalReservoir history_reservoir = risDecodeTemporalReservoir(imageLoad(RIS_POLY_PREV_TEMPORAL_RESERVOIR_IMAGE, history_pix));
	if (!risResolvePolygonReservoirLightId(history_reservoir)) {
		return false;
	}

	const vec2 current_weights = risPolygonProposalWeights(history_reservoir.light_id, P, N, V, material);
	current_mixed_weight = risPrimaryMixedWeight(current_weights, material.metalness);
	if (current_mixed_weight <= RIS_WEIGHT_EPSILON) {
		return false;
	}

	if (!risProbePolygonLightVisibility(history_reservoir.light_id, P)) {
		return false;
	}

	reservoir = history_reservoir;
	return true;
}
#endif

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
	bool visibility_test,
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

	if (visibility_test && shadowed(P, L, dist)) {
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
	bool visibility_test,
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

	return risEvaluatePolygonSamplePositionWithInvPdf(poly, sample_pos, inv_light_pdf * inv_area_pdf, P, N, V, material, visibility_test, diffuse, specular);
}

bool risProbePolygonLightVisibility(uint light_id, vec3 P)
{
	if (light_id >= lights.m.num_polygons) {
		return false;
	}

	const PolygonLight poly = lights.m.polygons[light_id];
	const uint vertices_offset = poly.vertices_count_offset & 0xffffu;
	const uint vertices_count = poly.vertices_count_offset >> 16;
	if (vertices_count < 3u) {
		return false;
	}

	const vec4 plane = normalizedPolygonPlane(poly);
	if (dot(plane, vec4(P, 1.0)) <= 0.0) {
		return false;
	}

	const uint triangle_count = vertices_count - 2u;
	const uint triangle_index = min(uint(rand01() * float(triangle_count)), triangle_count - 1u);
	const vec3 v0 = lights.m.polygon_vertices[vertices_offset].xyz;
	const vec3 v1 = lights.m.polygon_vertices[vertices_offset + triangle_index + 1u].xyz;
	const vec3 v2 = lights.m.polygon_vertices[vertices_offset + triangle_index + 2u].xyz;

	const float r0 = rand01();
	const float r1 = rand01();
	const float sqrt_r0 = sqrt(r0);
	const vec3 sample_pos = v0 * (1.0 - sqrt_r0) + v1 * (sqrt_r0 * (1.0 - r1)) + v2 * (sqrt_r0 * r1);

	const vec3 to_light = sample_pos - P;
	const float dist2 = dot(to_light, to_light);
	if (dist2 <= 1e-6) {
		return false;
	}

	const float dist = sqrt(dist2);
	const vec3 L = to_light / dist;
	if (dot(-L, plane.xyz) <= 1e-5) {
		return false;
	}

	return !shadowed(P, L, dist);
}

#if RIS_INIT_PASS
RisTemporalReservoir risMergeVisiblePolygonCandidates(
	uint cluster_index,
	vec3 P,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	ivec2 pix,
	RisTemporalReservoir reservoir)
{
	const uint num_polygons = uint(light_grid.clusters_[cluster_index].num_polygons);
	const uint candidate_count = risPrimaryCandidateScanCount(num_polygons);
	const uint candidate_start_index = risPrimaryCandidateStartIndex(num_polygons);
	uint candidate_ordinal = 0u;

	for (uint i = 0u; i < uint(RIS_PRIMARY_CANDIDATES); ++i) {
		if (candidate_ordinal >= candidate_count) {
			break;
		}

		uint selected_id = RIS_INVALID_LIGHT_ID;
		float selected_mixed_weight = 0.0;
		for (uint scan = 0u; scan < uint(RIS_PRIMARY_CANDIDATE_SCAN_WINDOW); ++scan) {
			if (candidate_ordinal >= candidate_count) {
				break;
			}

			const uint candidate_index = risPrimaryCandidateIndex(num_polygons, candidate_start_index, candidate_ordinal);
			candidate_ordinal++;

			const uint candidate_id = uint(light_grid.clusters_[cluster_index].polygons[candidate_index]);
			const vec2 weights = risPolygonProposalWeights(candidate_id, P, N, V, material);
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

		if (!risProbePolygonLightVisibility(selected_id, P)) {
			continue;
		}

		RisTemporalCandidate visible_candidate;
		visible_candidate.light_id = selected_id;
		visible_candidate.light_hash = risPolygonLightHash(selected_id);
		visible_candidate.mixed_weight = selected_mixed_weight;
		reservoir = risMergeTemporalCandidate(
			reservoir,
			visible_candidate,
			risTemporalRandom01(pix, 0x72737460u + i));
	}

	return reservoir;
}

#if RIS_BAYER_SHARED_VISIBILITY
RisTemporalReservoir risMergeBayerSharedVisiblePolygonCandidates(
	uint cluster_index,
	vec3 P,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	ivec2 pix,
	bool ris_active,
	RisTemporalReservoir reservoir)
{
	const uint local_index = risBayerLocalInvocationIndex();
	uint visible_mask = 0u;

	if (ris_active) {
		const uint num_polygons = uint(light_grid.clusters_[cluster_index].num_polygons);
		uint segment_begin;
		uint segment_count;
		risBayerSegmentRange(num_polygons, risBayerIndex(pix), segment_begin, segment_count);

		for (uint bit_index = 0u; bit_index < uint(RIS_BAYER_SEGMENT_MAX_CANDIDATES); ++bit_index) {
			if (bit_index >= segment_count) {
				break;
			}

			const uint candidate_index = segment_begin + bit_index;
			const uint candidate_id = uint(light_grid.clusters_[cluster_index].polygons[candidate_index]);
			const vec2 weights = risPolygonProposalWeights(candidate_id, P, N, V, material);
			const float mixed_weight = risPrimaryMixedWeight(weights, material.metalness);
			if (mixed_weight <= RIS_WEIGHT_EPSILON) {
				continue;
			}

			if (!risProbePolygonLightVisibility(candidate_id, P)) {
				continue;
			}

			visible_mask |= 1u << bit_index;

			RisTemporalCandidate visible_candidate;
			visible_candidate.light_id = candidate_id;
			visible_candidate.light_hash = risPolygonLightHash(candidate_id);
			visible_candidate.mixed_weight = mixed_weight;
			reservoir = risMergeTemporalCandidate(
				reservoir,
				visible_candidate,
				risTemporalRandom01(pix, 0x62796f00u + bit_index));
		}

		risPolygonBayerClusterIndices[local_index] = cluster_index;
	} else {
		risPolygonBayerClusterIndices[local_index] = RIS_INVALID_LIGHT_ID;
	}
	risPolygonBayerVisibleMasks[local_index] = visible_mask;

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
		const uint sample_cluster_index = risPolygonBayerClusterIndices[sample_local_index];
		const uint sample_visible_mask = risPolygonBayerVisibleMasks[sample_local_index];
		if (sample_cluster_index >= MAX_LIGHT_CLUSTERS || sample_visible_mask == 0u) {
			continue;
		}

		const ivec2 sample_pix = risBayerLocalToPixel(pix, sample_local_pix);
		if (!risPixelInBounds(sample_pix)) {
			continue;
		}

		const uint num_polygons = uint(light_grid.clusters_[sample_cluster_index].num_polygons);
		uint segment_begin;
		uint segment_count;
		risBayerSegmentRange(num_polygons, risBayerIndex(sample_pix), segment_begin, segment_count);

		for (uint bit_index = 0u; bit_index < uint(RIS_BAYER_SEGMENT_MAX_CANDIDATES); ++bit_index) {
			if (bit_index >= segment_count) {
				break;
			}
			if (!risBayerMaskBitSet(sample_visible_mask, bit_index)) {
				continue;
			}

			const uint candidate_index = segment_begin + bit_index;
			const uint candidate_id = uint(light_grid.clusters_[sample_cluster_index].polygons[candidate_index]);
			const vec2 weights = risPolygonProposalWeights(candidate_id, P, N, V, material);
			const float mixed_weight = risPrimaryMixedWeight(weights, material.metalness);
			if (mixed_weight <= RIS_WEIGHT_EPSILON) {
				continue;
			}

			RisTemporalCandidate visible_candidate;
			visible_candidate.light_id = candidate_id;
			visible_candidate.light_hash = risPolygonLightHash(candidate_id);
			visible_candidate.mixed_weight = mixed_weight;
			reservoir = risMergeTemporalCandidate(
				reservoir,
				visible_candidate,
				risTemporalRandom01(
					pix,
					0x62796f80u + sample_index * uint(RIS_BAYER_SEGMENT_MAX_CANDIDATES) + bit_index));
		}
	}

	return reservoir;
}
#endif

void computePolygonLightingRISInit(
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

	const float temporal_rand_reset = risTemporalRandom01(pix, 0x72737430u);
	const float temporal_rand_lifetime = risTemporalRandom01(pix, 0x72737431u);
	RisTemporalReservoir merged_reservoir = risReweightTemporalReservoir(
		old_reservoir,
		old_current_mixed_weight,
		temporal_rand_reset,
		temporal_rand_lifetime);

#if RIS_BAYER_SHARED_VISIBILITY
	merged_reservoir = risMergeBayerSharedVisiblePolygonCandidates(
		cluster_index,
		P,
		N,
		V,
		material,
		pix,
		ris_active,
		merged_reservoir);
#else
	if (ris_active) {
		merged_reservoir = risMergeVisiblePolygonCandidates(
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
		const vec2 merged_weights = risPolygonProposalWeights(merged_reservoir.light_id, P, N, V, material);
		if (any(greaterThan(merged_weights, vec2(RIS_WEIGHT_EPSILON)))) {
			image_candidate.light_id = merged_reservoir.light_id;
			image_candidate.weights = merged_weights;
			image_candidate.mixed_weight = risPrimaryMixedWeight(merged_weights, material.metalness);
		} else {
			merged_reservoir = risInvalidTemporalReservoir();
		}
	}

	if (risPixelInBounds(pix)) {
		imageStore(RIS_POLY_OUT_TEMPORAL_RESERVOIR_IMAGE, pix, risEncodeTemporalReservoir(merged_reservoir));
		imageStore(RIS_POLY_OUT_CANDIDATE_IMAGE, pix, risEncodeCandidateImageSample(image_candidate));
	}
}
#endif

#if RIS_APPLY_PASS
void computePolygonLightingRISApply(
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

		const RisCandidateImageSample self_candidate = risDecodeCandidateImageSample(imageLoad(RIS_POLY_CANDIDATE_IMAGE, pix));
		if (risCandidateImageSampleValid(self_candidate) && self_candidate.light_id < lights.m.num_polygons) {
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

			const RisCandidateImageSample image_candidate = risDecodeCandidateImageSample(imageLoad(RIS_POLY_CANDIDATE_IMAGE, sample_pix));
			if (!risCandidateImageSampleValid(image_candidate) || image_candidate.light_id >= lights.m.num_polygons) {
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
				const float secondary_inv_light_pdf = diffuse_weight_sum / max(pool_weights[selected].x, RIS_WEIGHT_EPSILON);
				secondary_sample_count += 1u;
				if (risEvaluatePolygonLightSample(pool_light_ids[selected], secondary_inv_light_pdf, P, N, V, material, secondary_visibility_test, candidate_diffuse, candidate_specular)) {
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
				if (risEvaluatePolygonLightSample(pool_light_ids[selected], secondary_inv_light_pdf, P, N, V, material, secondary_visibility_test, candidate_diffuse, candidate_specular)) {
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

#endif // LIGHT_POLYGON_RIS_GLSL_INCLUDED
