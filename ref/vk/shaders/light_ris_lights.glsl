#ifndef LIGHT_RIS_LIGHTS_GLSL_INCLUDED
#define LIGHT_RIS_LIGHTS_GLSL_INCLUDED

#if LIGHT_POINT && LIGHT_POLYGON
#error RIS typed light include expects one light type per shader
#endif

#if !LIGHT_POINT && !LIGHT_POLYGON
#error RIS typed light include expects LIGHT_POINT or LIGHT_POLYGON
#endif

#ifndef RIS_LOAD_TEMPORAL_REFERENCE_POSITION
#define RIS_LOAD_TEMPORAL_REFERENCE_POSITION(pix_) imageLoad(geometry_prev_position, (pix_)).rgb
#endif

#ifndef RIS_DIRECT_SPECULAR_MIS
#define RIS_DIRECT_SPECULAR_MIS 0
#endif

#if RIS_APPLY_PASS && RIS_DIRECT_SPECULAR_MIS
vec3 g_ris_direct_specular_ray_dir = vec3(0.0);
float g_ris_direct_specular_ray_pdf = 0.0;
float g_ris_direct_specular_ray_len = 0.0;
bool g_ris_direct_specular_ray_valid = false;
bool g_ris_direct_specular_mis_selected_light = false;

void risSetDirectSpecularMisSelectedLight(bool selected_light)
{
	g_ris_direct_specular_mis_selected_light = selected_light;
}

void risSetDirectSpecularMisRay(ivec2 pix)
{
	const vec4 ray_pdf = imageLoad(reflection_direction_pdf, pix);
	g_ris_direct_specular_ray_len = length(ray_pdf.xyz);
	g_ris_direct_specular_ray_pdf = ray_pdf.w;
	g_ris_direct_specular_ray_valid = g_ris_direct_specular_ray_len > 1e-5 && g_ris_direct_specular_ray_pdf > 1e-8;
	g_ris_direct_specular_ray_dir = g_ris_direct_specular_ray_valid ? (ray_pdf.xyz / g_ris_direct_specular_ray_len) : vec3(0.0);
}
#else
void risSetDirectSpecularMisSelectedLight(bool selected_light) {}
void risSetDirectSpecularMisRay(ivec2 pix) {}
#endif


#if LIGHT_POLYGON

#define MAX_POLYGON_VERTEX_COUNT 8

#ifndef RIS_POLYGON_LTC_SPECULAR
#define RIS_POLYGON_LTC_SPECULAR 1
#endif

#ifndef RIS_POLYGON_ANALYTIC_DIFFUSE
#define RIS_POLYGON_ANALYTIC_DIFFUSE 0
#endif

#include "utils.glsl"
#include "peters2021-sampling/polygon_sampling.glsl"
#include "ltc_polygon.glsl"

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

#ifndef RIS_POLY_OUT_TEMPORAL_RANDOM_IMAGE
#define RIS_POLY_OUT_TEMPORAL_RANDOM_IMAGE out_temporal_ris_poly_random
#endif

#ifndef RIS_POLY_PREV_TEMPORAL_RANDOM_IMAGE
#define RIS_POLY_PREV_TEMPORAL_RANDOM_IMAGE prev_temporal_ris_poly_random
#endif

struct RisLightSample {
	uint light_id;
	PolygonLight light;
};

uint risLightCount(uint cluster_index)
{
	return uint(light_grid.clusters_[cluster_index].num_polygons);
}

uint risLightId(uint cluster_index, uint light_index)
{
	return uint(light_grid.clusters_[cluster_index].polygons[light_index]);
}

bool risLoadLightSample(uint light_id, out RisLightSample light_sample)
{
	if (light_id >= lights.m.num_polygons) {
		return false;
	}

	light_sample.light_id = light_id;
	light_sample.light = lights.m.polygons[light_id];
	return true;
}

vec2 risLightWeights(RisLightSample light_sample, vec3 P, vec3 N, vec3 V, MaterialProperties material)
{
	return max(lightPolygonWeightCalculation(light_sample.light, P, N, V, material.roughness), vec2(0.0));
}

uint risLightHash(RisLightSample light_sample)
{
	const PolygonLight poly = light_sample.light;
	uint hash_value = xxhash32(uvec4(
		risQuantizeLightValueForHash(poly.plane.x),
		risQuantizeLightValueForHash(poly.plane.y),
		risQuantizeLightValueForHash(poly.plane.z),
		risQuantizeLightValueForHash(poly.plane.w)));
	hash_value ^= xxhash32(uvec4(
		risQuantizeLightValueForHash(poly.center.x),
		risQuantizeLightValueForHash(poly.center.y),
		risQuantizeLightValueForHash(poly.center.z),
		risQuantizeLightValueForHash(poly.area)));
	hash_value ^= xxhash32(uvec4(
		risQuantizeLightValueForHash(poly.emissive.x),
		risQuantizeLightValueForHash(poly.emissive.y),
		risQuantizeLightValueForHash(poly.emissive.z),
		poly.vertices_count_offset >> 16));

	const uint vertices_offset = poly.vertices_count_offset & 0xffffu;
	const uint vertices_count = poly.vertices_count_offset >> 16;
	for (uint i = 0u; i < uint(MAX_POLYGON_VERTEX_COUNT); ++i) {
		if (i >= vertices_count) {
			break;
		}

			const vec3 vertex = lights.m.polygon_vertices[vertices_offset + i].xyz;
			hash_value ^= xxhash32(uvec4(
				risQuantizeLightValueForHash(vertex.x),
				risQuantizeLightValueForHash(vertex.y),
				risQuantizeLightValueForHash(vertex.z),
				i));
	}
	return risFoldTemporalHash(hash_value);
}

#if RIS_INIT_PASS
RisTemporalReservoir risLoadPreviousTemporalReservoir(ivec2 pix)
{
	RisTemporalReservoir reservoir = risDecodeTemporalReservoir(imageLoad(RIS_POLY_PREV_TEMPORAL_RESERVOIR_IMAGE, pix));
#if RIS_UNIFIED_PASS
	const vec4 random_count = imageLoad(RIS_POLY_PREV_TEMPORAL_RANDOM_IMAGE, pix);
	reservoir.sample_random = clamp(random_count.xyz, vec3(0.0), vec3(1.0));
	reservoir.sample_count = max(random_count.w, 0.0);
#endif
	return risTemporalReservoirValid(reservoir) ? reservoir : risInvalidTemporalReservoir();
}

#ifdef RIS_REUSE_DIRECT_RESERVOIR
RisTemporalReservoir risLoadDirectTemporalReservoir(ivec2 pix)
{
	return risDecodeTemporalReservoir(imageLoad(direct_reusing_ris_poly_reservoir, pix));
}
#endif

void risStoreTemporalReservoir(ivec2 pix, RisTemporalReservoir reservoir)
{
	const vec4 encoded = risEncodeTemporalReservoir(reservoir);
	imageStore(RIS_POLY_OUT_TEMPORAL_RESERVOIR_IMAGE, pix, encoded);
#if RIS_UNIFIED_PASS
	imageStore(RIS_POLY_OUT_TEMPORAL_RANDOM_IMAGE, pix,
		risTemporalReservoirValid(reservoir) ? vec4(clamp(reservoir.sample_random, vec3(0.0), vec3(1.0)), reservoir.sample_count) : vec4(0.0));
#endif
#ifdef RIS_OUT_REUSE_IMAGE
	imageStore(RIS_OUT_REUSE_IMAGE, pix, encoded);
#endif
}

void risStoreCandidateImageSample(ivec2 pix, RisCandidateImageSample candidate)
{
#if !RIS_UNIFIED_PASS
	imageStore(RIS_POLY_OUT_CANDIDATE_IMAGE, pix, risEncodeCandidateImageSample(candidate));
#endif
}

#if RIS_BAYER_SHARED_VISIBILITY
shared uint risBayerClusterIndices[RIS_BAYER_WORKGROUP_SIZE];
shared uint risBayerVisibleMasks[RIS_BAYER_WORKGROUP_SIZE];

void risStoreBayerVisibility(uint local_index, uint cluster_index, uint visible_mask)
{
	risBayerClusterIndices[local_index] = cluster_index;
	risBayerVisibleMasks[local_index] = visible_mask;
}

void risLoadBayerVisibility(uint local_index, out uint cluster_index, out uint visible_mask)
{
	cluster_index = risBayerClusterIndices[local_index];
	visible_mask = risBayerVisibleMasks[local_index];
}
#endif
#endif

#if RIS_APPLY_PASS
RisCandidateImageSample risLoadCandidateImageSample(ivec2 pix)
{
	return risDecodeCandidateImageSample(imageLoad(RIS_POLY_CANDIDATE_IMAGE, pix));
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

// Cheap visibility-only sample: choose a fan triangle uniformly, regardless
// of its area, then choose a uniform barycentric point inside that triangle.
bool risSampleUniformPolygonTriangle(
	PolygonLight poly,
	vec3 sample_random,
	out vec3 sample_pos)
{
	const uint vertices_offset = poly.vertices_count_offset & 0xffffu;
	const uint vertices_count = poly.vertices_count_offset >> 16;
	if (vertices_count < 3u) {
		sample_pos = vec3(0.0);
		return false;
	}

	const uint triangle_count = vertices_count - 2u;
	const uint triangle_index = min(
		uint(clamp(sample_random.x, 0.0, 0.99999994) * float(triangle_count)),
		triangle_count - 1u);
	const vec3 v0 = lights.m.polygon_vertices[vertices_offset].xyz;
	const vec3 v1 = lights.m.polygon_vertices[vertices_offset + triangle_index + 1u].xyz;
	const vec3 v2 = lights.m.polygon_vertices[vertices_offset + triangle_index + 2u].xyz;
	const float sqrt_u = sqrt(clamp(sample_random.y, 0.0, 1.0));
	const float b0 = 1.0 - sqrt_u;
	const float b1 = sqrt_u * (1.0 - clamp(sample_random.z, 0.0, 1.0));
	const float b2 = sqrt_u * clamp(sample_random.z, 0.0, 1.0);
	sample_pos = v0 * b0 + v1 * b1 + v2 * b2;
	return true;
}

// Reconstruct a surface-area sample independently of the shaded point.  The
// first component selects a triangle in the polygon fan proportionally to its
// area; the other two generate uniform barycentric coordinates.
bool risSampleAreaPolygon(
	PolygonLight poly,
	vec3 sample_random,
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

	const vec3 v0 = lights.m.polygon_vertices[vertices_offset].xyz;
	float total_area = 0.0;
	for (uint i = 1u; i + 1u < vertices_count; ++i) {
		const vec3 v1 = lights.m.polygon_vertices[vertices_offset + i].xyz;
		const vec3 v2 = lights.m.polygon_vertices[vertices_offset + i + 1u].xyz;
		total_area += 0.5 * length(cross(v1 - v0, v2 - v0));
	}
	if (total_area <= 1e-8) {
		sample_pos = vec3(0.0);
		inv_area_pdf = 0.0;
		return false;
	}

	const float target_area = clamp(sample_random.x, 0.0, 0.99999994) * total_area;
	float area_prefix = 0.0;
	vec3 selected_v1 = lights.m.polygon_vertices[vertices_offset + 1u].xyz;
	vec3 selected_v2 = lights.m.polygon_vertices[vertices_offset + 2u].xyz;
	for (uint i = 1u; i + 1u < vertices_count; ++i) {
		const vec3 v1 = lights.m.polygon_vertices[vertices_offset + i].xyz;
		const vec3 v2 = lights.m.polygon_vertices[vertices_offset + i + 1u].xyz;
		const float triangle_area = 0.5 * length(cross(v1 - v0, v2 - v0));
		selected_v1 = v1;
		selected_v2 = v2;
		area_prefix += triangle_area;
		if (target_area <= area_prefix || i + 2u == vertices_count) {
			break;
		}
	}

	const float sqrt_u = sqrt(clamp(sample_random.y, 0.0, 1.0));
	const float b0 = 1.0 - sqrt_u;
	const float b1 = sqrt_u * (1.0 - clamp(sample_random.z, 0.0, 1.0));
	const float b2 = sqrt_u * clamp(sample_random.z, 0.0, 1.0);
	sample_pos = v0 * b0 + selected_v1 * b1 + selected_v2 * b2;
	inv_area_pdf = total_area;
	return true;
}


#if RIS_APPLY_PASS && RIS_DIRECT_SPECULAR_MIS
bool risRayTriangleHit(vec3 ro, vec3 rd, vec3 v0, vec3 v1, vec3 v2, out float t)
{
	const float eps = 1e-6;
	const vec3 e1 = v1 - v0;
	const vec3 e2 = v2 - v0;
	const vec3 p = cross(rd, e2);
	const float det = dot(e1, p);
	if (abs(det) <= eps) {
		return false;
	}

	const float inv_det = 1.0 / det;
	const vec3 s = ro - v0;
	const float u = dot(s, p) * inv_det;
	if (u < 0.0 || u > 1.0) {
		return false;
	}

	const vec3 q = cross(s, e1);
	const float v = dot(rd, q) * inv_det;
	if (v < 0.0 || u + v > 1.0) {
		return false;
	}

	t = dot(e2, q) * inv_det;
	return t > eps;
}

bool risRayHitsPolygonLight(PolygonLight poly, vec3 P, vec3 R, out float hit_t, out float solid_angle)
{
	hit_t = 1e30;
	solid_angle = 0.0;

	const uint vertices_offset = poly.vertices_count_offset & 0xffffu;
	const uint vertices_count = poly.vertices_count_offset >> 16;
	if (vertices_count < 3u) {
		return false;
	}

	vec3 vertices[MAX_POLYGON_VERTEX_COUNT];
	for (uint i = 0u; i < MAX_POLYGON_VERTEX_COUNT; ++i) {
		vertices[i] = (i < vertices_count) ? lights.m.polygon_vertices[vertices_offset + i].xyz : vec3(0.0);
	}

	const solid_angle_polygon_t sap = prepare_solid_angle_polygon_sampling(vertices_count, vertices, P);
	if (sap.solid_angle <= 1e-6) {
		return false;
	}

	const vec4 plane = normalizedPolygonPlane(poly);
	if (dot(plane.xyz, -R) <= 1e-6) {
		return false;
	}

	bool hit = false;
	const vec3 v0 = vertices[0];
	for (uint i = 1u; i + 1u < vertices_count; ++i) {
		float t;
		if (risRayTriangleHit(P, R, v0, vertices[i], vertices[i + 1u], t) && t < hit_t) {
			hit_t = t;
			hit = true;
		}
	}

	if (!hit || hit_t > g_ris_direct_specular_ray_len + 1e-3) {
		return false;
	}

	solid_angle = sap.solid_angle;
	return true;
}

bool risEvaluatePolygonReflectionMis(
	PolygonLight poly,
	float inv_light_pdf,
	vec3 P,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	out vec3 specular)
{
	specular = vec3(0.0);
	if (!g_ris_direct_specular_ray_valid || inv_light_pdf <= 0.0) {
		return false;
	}

	float hit_t;
	float solid_angle;
	if (!risRayHitsPolygonLight(poly, P, g_ris_direct_specular_ray_dir, hit_t, solid_angle)) {
		return false;
	}

	vec3 brdf_diffuse;
	vec3 brdf_specular;
	evalSplitBRDF(N, g_ris_direct_specular_ray_dir, V, material, brdf_diffuse, brdf_specular);
	if (dot(brdf_specular, brdf_specular) <= 0.0) {
		return false;
	}

	const float inv_light_dir_pdf = inv_light_pdf * solid_angle;
	const float p_light = 1.0 / max(inv_light_dir_pdf, 1e-20);
	const float w_bsdf = powerHeuristic(g_ris_direct_specular_ray_pdf, p_light);
	specular = poly.emissive * brdf_specular * (inv_light_pdf / max(g_ris_direct_specular_ray_pdf, 1e-20)) * w_bsdf;
	return true;
}
#endif

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
	if (light_facing <= 0.0 || dot(N, L) <= 1e-5) {
		return false;
	}

	if (visibility_test && shadowed(P, L, dist)) {
		return false;
	}

	vec3 brdf_diffuse;
	vec3 brdf_specular;
	evalSplitBRDF(N, L, V, material, brdf_diffuse, brdf_specular);

	const vec3 light = poly.emissive * (light_facing * inv_pdf / dist2);
	float specular_mis_weight = 1.0;
#if RIS_APPLY_PASS && RIS_DIRECT_SPECULAR_MIS
	if (g_ris_direct_specular_mis_selected_light) {
		const float p_light = dist2 / max(light_facing * inv_pdf, 1e-20);
		const float p_bsdf = ggxReflectionPdf(N, V, L, material.roughness);
		specular_mis_weight = powerHeuristic(p_light, p_bsdf);
	}
#endif
	diffuse = light * brdf_diffuse;
	specular = light * brdf_specular * specular_mis_weight;
	return true;
}

bool risEvaluateLight(
	RisLightSample light_sample,
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

	if (inv_light_pdf <= 0.0) {
		return false;
	}

	bool evaluated = false;
#if RIS_APPLY_PASS && RIS_DIRECT_SPECULAR_MIS
	risSetDirectSpecularMisSelectedLight(true);
#endif
	vec3 sample_pos;
	float inv_area_pdf;
	if (risSampleSolidPolygon(light_sample.light, P, sample_pos, inv_area_pdf)) {
		evaluated = risEvaluatePolygonSamplePositionWithInvPdf(light_sample.light, sample_pos, inv_light_pdf * inv_area_pdf, P, N, V, material, visibility_test, diffuse, specular);
	#if RIS_POLYGON_LTC_SPECULAR
		if (evaluated) {
			// Integrate the complete GGX lobe over the polygon. The random area
			// sample remains responsible for diffuse and the visibility decision;
			// only the discrete-light PDF applies to the analytic LTC result.
			specular = ltcPolygonSpecular(light_sample.light, P, N, V, material) * inv_light_pdf;
		}
	#endif
	}

#if RIS_APPLY_PASS && RIS_DIRECT_SPECULAR_MIS && !RIS_POLYGON_LTC_SPECULAR
	vec3 reflection_specular;
	if (risEvaluatePolygonReflectionMis(light_sample.light, inv_light_pdf, P, N, V, material, reflection_specular)) {
		specular += reflection_specular;
		evaluated = true;
	}
	risSetDirectSpecularMisSelectedLight(false);
#elif RIS_APPLY_PASS && RIS_DIRECT_SPECULAR_MIS
	risSetDirectSpecularMisSelectedLight(false);
#endif

	return evaluated;
}

bool risPolygonSamplePositionVisible(
	PolygonLight poly,
	vec3 sample_pos,
	vec3 P,
	vec3 N,
	bool visibility_test)
{
	const vec3 to_light = sample_pos - P;
	const float dist2 = dot(to_light, to_light);
	if (dist2 <= 1e-6) {
		return false;
	}
	const float dist = sqrt(dist2);
	const vec3 L = to_light / dist;
	const vec3 light_N = normalizedPolygonPlane(poly).xyz;
	if (dot(N, L) <= 1e-5 || dot(-L, light_N) <= 1e-5) {
		return false;
	}
	return !visibility_test || !shadowed(P, L, dist);
}

bool risEvaluateConcreteSample(
	RisLightSample light_sample,
	vec3 sample_random,
	vec3 P,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	bool visibility_test,
	out vec3 diffuse,
	out vec3 specular)
{
	vec3 sample_pos;
	float inv_area_pdf;
#if RIS_POLYGON_ANALYTIC_DIFFUSE && RIS_POLYGON_LTC_SPECULAR
	if (!risSampleUniformPolygonTriangle(light_sample.light, sample_random, sample_pos)) {
#else
	if (!risSampleAreaPolygon(light_sample.light, sample_random, sample_pos, inv_area_pdf)) {
#endif
		diffuse = vec3(0.0);
		specular = vec3(0.0);
		return false;
	}
#if RIS_POLYGON_ANALYTIC_DIFFUSE && RIS_POLYGON_LTC_SPECULAR
	// The saved random chooses a fan triangle without area weighting and then a
	// barycentric point used only by visibility. Lighting never evaluates
	// a solid-angle PDF or a BRDF at this random direction.
	if (!risPolygonSamplePositionVisible(
		light_sample.light, sample_pos, P, N, visibility_test)) {
		diffuse = vec3(0.0);
		specular = vec3(0.0);
		return false;
	}
	diffuse = ltcPolygonDiffuse(light_sample.light, P, N, V, material);
	specular = ltcPolygonSpecular(light_sample.light, P, N, V, material);
	return dot(diffuse + specular, diffuse + specular) > 0.0;
#else
	const bool evaluated = risEvaluatePolygonSamplePositionWithInvPdf(
		light_sample.light, sample_pos, inv_area_pdf, P, N, V, material,
		visibility_test, diffuse, specular);
	#if RIS_POLYGON_LTC_SPECULAR
	if (evaluated) {
		specular = ltcPolygonSpecular(light_sample.light, P, N, V, material);
	}
	#endif
	#if RIS_POLYGON_ANALYTIC_DIFFUSE
	if (evaluated) {
		diffuse = ltcPolygonDiffuse(light_sample.light, P, N, V, material);
	}
	#endif
	return evaluated;
#endif
}

bool risConcreteSampleVisible(
	RisLightSample light_sample,
	vec3 sample_random,
	vec3 P,
	vec3 N)
{
	vec3 sample_pos;
	if (!risSampleUniformPolygonTriangle(
		light_sample.light, sample_random, sample_pos)) {
		return false;
	}

	return risPolygonSamplePositionVisible(
		light_sample.light, sample_pos, P, N, true);
}

bool risLightVisible(RisLightSample light_sample, vec3 P, vec3 N)
{
	const PolygonLight poly = light_sample.light;
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

#define RIS_COMPUTE_LIGHTING_INIT computePolygonLightingRISInit
#define RIS_COMPUTE_LIGHTING_APPLY computePolygonLightingRISApply
#define RIS_COMPUTE_LIGHTING_UNIFIED computePolygonLightingRISUnified
#define RIS_TEMPORAL_RESET_RANDOM_SALT 0x72737430u
#define RIS_TEMPORAL_LIFETIME_RANDOM_SALT 0x72737431u
#define RIS_PRIMARY_MERGE_RANDOM_SALT 0x72737460u
#define RIS_BAYER_OWN_RANDOM_SALT 0x62796f00u
#define RIS_BAYER_NEIGHBOR_RANDOM_SALT 0x62796f80u

#endif

#if LIGHT_POINT

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

#ifndef RIS_POINT_OUT_TEMPORAL_RANDOM_IMAGE
#define RIS_POINT_OUT_TEMPORAL_RANDOM_IMAGE out_temporal_ris_point_random
#endif

#ifndef RIS_POINT_PREV_TEMPORAL_RANDOM_IMAGE
#define RIS_POINT_PREV_TEMPORAL_RANDOM_IMAGE prev_temporal_ris_point_random
#endif

bool risIsPointLightCandidate(uint light_id)
{
	if (light_id >= lights.m.num_point_lights) {
		return false;
	}

	const PointLight point_light = lights.m.point_lights[light_id];
	return point_light.environment == 0u && point_light.flashlight == 0u;
}

struct RisLightSample {
	uint light_id;
	PointLight light;
};

uint risLightCount(uint cluster_index)
{
	return uint(light_grid.clusters_[cluster_index].num_point_lights);
}

uint risLightId(uint cluster_index, uint light_index)
{
	return uint(light_grid.clusters_[cluster_index].point_lights[light_index]);
}

bool risLoadLightSample(uint light_id, out RisLightSample light_sample)
{
	if (!risIsPointLightCandidate(light_id)) {
		return false;
	}

	light_sample.light_id = light_id;
	light_sample.light = lights.m.point_lights[light_id];
	return true;
}

vec2 risLightWeights(RisLightSample light_sample, vec3 P, vec3 N, vec3 V, MaterialProperties material)
{
	return max(lightPointWeightCalculation(light_sample.light, P, N, V, material.roughness), vec2(0.0));
}

uint risLightHash(RisLightSample light_sample)
{
	const PointLight point_light = light_sample.light;
	uint hash_value = xxhash32(uvec4(
		risQuantizeLightValueForHash(point_light.origin_r2.x),
		risQuantizeLightValueForHash(point_light.origin_r2.y),
		risQuantizeLightValueForHash(point_light.origin_r2.z),
		risQuantizeLightValueForHash(point_light.origin_r2.w)));
	hash_value ^= xxhash32(uvec4(
		risQuantizeLightValueForHash(point_light.color_stopdot.x),
		risQuantizeLightValueForHash(point_light.color_stopdot.y),
		risQuantizeLightValueForHash(point_light.color_stopdot.z),
		risQuantizeLightValueForHash(point_light.color_stopdot.w)));
	hash_value ^= xxhash32(uvec4(
		risQuantizeLightValueForHash(point_light.dir_stopdot2.x),
		risQuantizeLightValueForHash(point_light.dir_stopdot2.y),
		risQuantizeLightValueForHash(point_light.dir_stopdot2.z),
		risQuantizeLightValueForHash(point_light.dir_stopdot2.w)));
	hash_value ^= xxhash32(uvec4(
		point_light.environment,
		point_light.flashlight,
		0u,
		0u));
	return risFoldTemporalHash(hash_value);
}

#if RIS_INIT_PASS
RisTemporalReservoir risLoadPreviousTemporalReservoir(ivec2 pix)
{
	RisTemporalReservoir reservoir = risDecodeTemporalReservoir(imageLoad(RIS_POINT_PREV_TEMPORAL_RESERVOIR_IMAGE, pix));
#if RIS_UNIFIED_PASS
	const vec4 random_count = imageLoad(RIS_POINT_PREV_TEMPORAL_RANDOM_IMAGE, pix);
	reservoir.sample_random = clamp(random_count.xyz, vec3(0.0), vec3(1.0));
	reservoir.sample_count = max(random_count.w, 0.0);
#endif
	return risTemporalReservoirValid(reservoir) ? reservoir : risInvalidTemporalReservoir();
}

#ifdef RIS_REUSE_DIRECT_RESERVOIR
RisTemporalReservoir risLoadDirectTemporalReservoir(ivec2 pix)
{
	return risDecodeTemporalReservoir(imageLoad(direct_reusing_ris_point_reservoir, pix));
}
#endif

void risStoreTemporalReservoir(ivec2 pix, RisTemporalReservoir reservoir)
{
	const vec4 encoded = risEncodeTemporalReservoir(reservoir);
	imageStore(RIS_POINT_OUT_TEMPORAL_RESERVOIR_IMAGE, pix, encoded);
#if RIS_UNIFIED_PASS
	imageStore(RIS_POINT_OUT_TEMPORAL_RANDOM_IMAGE, pix,
		risTemporalReservoirValid(reservoir) ? vec4(clamp(reservoir.sample_random, vec3(0.0), vec3(1.0)), reservoir.sample_count) : vec4(0.0));
#endif
#ifdef RIS_OUT_REUSE_IMAGE
	imageStore(RIS_OUT_REUSE_IMAGE, pix, encoded);
#endif
}

void risStoreCandidateImageSample(ivec2 pix, RisCandidateImageSample candidate)
{
#if !RIS_UNIFIED_PASS
	imageStore(RIS_POINT_OUT_CANDIDATE_IMAGE, pix, risEncodeCandidateImageSample(candidate));
#endif
}

#if RIS_BAYER_SHARED_VISIBILITY
shared uint risBayerClusterIndices[RIS_BAYER_WORKGROUP_SIZE];
shared uint risBayerVisibleMasks[RIS_BAYER_WORKGROUP_SIZE];

void risStoreBayerVisibility(uint local_index, uint cluster_index, uint visible_mask)
{
	risBayerClusterIndices[local_index] = cluster_index;
	risBayerVisibleMasks[local_index] = visible_mask;
}

void risLoadBayerVisibility(uint local_index, out uint cluster_index, out uint visible_mask)
{
	cluster_index = risBayerClusterIndices[local_index];
	visible_mask = risBayerVisibleMasks[local_index];
}
#endif
#endif

#if RIS_APPLY_PASS
RisCandidateImageSample risLoadCandidateImageSample(ivec2 pix)
{
	return risDecodeCandidateImageSample(imageLoad(RIS_POINT_CANDIDATE_IMAGE, pix));
}
#endif


#if RIS_APPLY_PASS && RIS_DIRECT_SPECULAR_MIS
bool risEvaluatePointReflectionMis(
	PointLight point_light,
	vec3 P,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	float inv_light_pdf,
	out vec3 specular)
{
	specular = vec3(0.0);
	if (!g_ris_direct_specular_ray_valid || inv_light_pdf <= 0.0 || point_light.environment != 0u) {
		return false;
	}

	const vec3 C = point_light.origin_r2.xyz;
	const float r2 = point_light.origin_r2.w;
	const vec3 to_center = C - P;
	const float center_dist2 = dot(to_center, to_center);
	const float d2_minus_r2 = center_dist2 - r2;
	if (r2 <= 0.0 || d2_minus_r2 <= 0.0) {
		return false;
	}

	const vec3 oc = P - C;
	const float b = dot(oc, g_ris_direct_specular_ray_dir);
	const float c = dot(oc, oc) - r2;
	const float h = b * b - c;
	if (h <= 0.0) {
		return false;
	}

	const float hit_t = -b - sqrt(h);
	if (hit_t <= 1e-5 || hit_t > g_ris_direct_specular_ray_len + 1e-3) {
		return false;
	}

	if (dot(g_ris_direct_specular_ray_dir, N) < 1e-5) {
		return false;
	}

	const vec3 spotlight_dir = point_light.dir_stopdot2.xyz;
	const float spot_dot = dot(g_ris_direct_specular_ray_dir, spotlight_dir);
	const float stopdot2 = point_light.dir_stopdot2.a;
	if (spot_dot < stopdot2) {
		return false;
	}

	float spot_attenuation = 1.0;
	const float stopdot = point_light.color_stopdot.a;
	if (spot_dot < stopdot) {
		spot_attenuation = (spot_dot - stopdot2) / (stopdot - stopdot2);
		if (spot_attenuation <= 0.0) {
			return false;
		}
	}

	vec3 brdf_diffuse;
	vec3 brdf_specular;
	evalSplitBRDF(N, g_ris_direct_specular_ray_dir, V, material, brdf_diffuse, brdf_specular);
	if (dot(brdf_specular, brdf_specular) <= 0.0) {
		return false;
	}

	const float cos_theta_max = min(1.0, sqrt(d2_minus_r2 / center_dist2));
	const float solid_angle = 2.0 * kPi * max(0.0, 1.0 - cos_theta_max);
	if (solid_angle <= 1e-8) {
		return false;
	}

	const float inv_light_dir_pdf = solid_angle * inv_light_pdf;
	const float p_light = 1.0 / max(inv_light_dir_pdf, 1e-20);
	const float w_bsdf = powerHeuristic(g_ris_direct_specular_ray_pdf, p_light);
	specular = point_light.color_stopdot.rgb * spot_attenuation * brdf_specular * (inv_light_pdf / max(g_ris_direct_specular_ray_pdf, 1e-20)) * w_bsdf;
	return true;
}
#endif

bool risEvaluatePointLightContribution(
	PointLight point_light,
	vec2 sample_random,
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

	const vec2 rnd = clamp(sample_random, vec2(0.0), vec2(1.0));
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

	float specular_mis_weight = 1.0;
#if RIS_APPLY_PASS && RIS_DIRECT_SPECULAR_MIS
	if (g_ris_direct_specular_mis_selected_light && !is_environment && inv_light_pdf > 0.0) {
		const vec3 light_pos = point_light.origin_r2.xyz;
		const float light_r2 = point_light.origin_r2.w;
		const vec3 to_light = light_pos - P;
		const float light_dist2 = dot(to_light, to_light);
		const float d2_minus_r2 = light_dist2 - light_r2;
		if (d2_minus_r2 > 0.0) {
			const float cos_theta_max = min(1.0, sqrt(d2_minus_r2 / light_dist2));
			const float inv_light_dir_pdf = 2.0 * kPi * max(0.0, 1.0 - cos_theta_max) * inv_light_pdf;
			const float p_light = 1.0 / max(inv_light_dir_pdf, 1e-20);
			const float p_bsdf = ggxReflectionPdf(N, V, light_dir, material.roughness);
			specular_mis_weight = powerHeuristic(p_light, p_bsdf);
		}
	}
#endif

	const vec3 color = point_light.color_stopdot.rgb * one_over_pdf;
	diffuse = brdf_diffuse * color;
	specular = brdf_specular * color * specular_mis_weight;

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

bool risLightVisible(RisLightSample light_sample, vec3 P, vec3 N)
{
	const PointLight point_light = light_sample.light;
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

bool risEvaluateLight(
	RisLightSample light_sample,
	float inv_light_pdf,
	vec3 P,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	bool visibility_test,
	out vec3 diffuse,
	out vec3 specular)
{
#if RIS_APPLY_PASS && RIS_DIRECT_SPECULAR_MIS
	risSetDirectSpecularMisSelectedLight(true);
#endif
	const bool evaluated = risEvaluatePointLightContribution(light_sample.light, vec2(rand01(), rand01()), P, N, V, material, inv_light_pdf, visibility_test, diffuse, specular);
#if RIS_APPLY_PASS && RIS_DIRECT_SPECULAR_MIS
	vec3 reflection_specular;
	if (risEvaluatePointReflectionMis(light_sample.light, P, N, V, material, inv_light_pdf, reflection_specular)) {
		specular += reflection_specular;
		risSetDirectSpecularMisSelectedLight(false);
		return true;
	}
	risSetDirectSpecularMisSelectedLight(false);
#endif
	return evaluated;
}

bool risEvaluateConcreteSample(
	RisLightSample light_sample,
	vec3 sample_random,
	vec3 P,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	bool visibility_test,
	out vec3 diffuse,
	out vec3 specular)
{
	return risEvaluatePointLightContribution(
		light_sample.light, sample_random.yz, P, N, V, material, 1.0,
		visibility_test, diffuse, specular);
}

bool risConcreteSampleVisible(
	RisLightSample light_sample,
	vec3 sample_random,
	vec3 P,
	vec3 N)
{
	const PointLight point_light = light_sample.light;
	const vec2 rnd = clamp(sample_random.yz, vec2(0.0), vec2(1.0));
	const vec3 axis = point_light.dir_stopdot2.xyz;
	vec3 light_dir;
	float light_dist = 0.0;

	if (point_light.environment != 0u) {
		light_dir = normalize(orthonormalBasisZ(axis) *
			sampleConeZ(rnd, point_light.dir_stopdot2.a));
		if (dot(N, light_dir) <= 1e-5) {
			return false;
		}
		return !shadowedSky(P, light_dir);
	}

	const vec3 to_light = point_light.origin_r2.xyz - P;
	const float light_dist2 = dot(to_light, to_light);
	const float d2_minus_r2 = light_dist2 - point_light.origin_r2.w;
	if (d2_minus_r2 <= 0.0) {
		return false;
	}
	light_dist = sqrt(light_dist2);
	const float cos_theta_max = min(1.0, sqrt(d2_minus_r2 / light_dist2));
	light_dir = normalize(orthonormalBasisZ(to_light / light_dist) *
		sampleConeZ(rnd, cos_theta_max));
	if (dot(N, light_dir) <= 1e-5 ||
		dot(light_dir, axis) < point_light.dir_stopdot2.a) {
		return false;
	}
	return !shadowed(P, light_dir, light_dist + shadow_offset_fudge);
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
		if (!risEvaluatePointLightContribution(point_light, vec2(rand01(), rand01()), P, N, V, material, 1.0, true, candidate_diffuse, candidate_specular)) {
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

#define RIS_COMPUTE_LIGHTING_INIT computePointLightingRISInit
#define RIS_COMPUTE_LIGHTING_APPLY computePointLightingRISApplySamples
#define RIS_COMPUTE_LIGHTING_UNIFIED computePointLightingRISUnified
#define RIS_TEMPORAL_RESET_RANDOM_SALT 0x72737440u
#define RIS_TEMPORAL_LIFETIME_RANDOM_SALT 0x72737441u
#define RIS_PRIMARY_MERGE_RANDOM_SALT 0x72737450u
#define RIS_BAYER_OWN_RANDOM_SALT 0x62797000u
#define RIS_BAYER_NEIGHBOR_RANDOM_SALT 0x62797080u

#endif

#define RIS_LIGHT_SAMPLE RisLightSample
#define RIS_LOAD_LIGHT risLoadLightSample
#define RIS_CLUSTER_LIGHT_COUNT risLightCount
#define RIS_CLUSTER_LIGHT_ID risLightId
#define RIS_LIGHT_WEIGHTS risLightWeights
#define RIS_LIGHT_HASH risLightHash
#define RIS_LIGHT_VISIBLE risLightVisible
#define RIS_EVALUATE_LIGHT risEvaluateLight
#define RIS_CONCRETE_SAMPLE_VISIBLE risConcreteSampleVisible
#define RIS_LOAD_PREVIOUS_TEMPORAL_RESERVOIR risLoadPreviousTemporalReservoir
#define RIS_LOAD_DIRECT_TEMPORAL_RESERVOIR risLoadDirectTemporalReservoir
#define RIS_STORE_TEMPORAL_RESERVOIR risStoreTemporalReservoir
#define RIS_STORE_CANDIDATE_IMAGE_SAMPLE risStoreCandidateImageSample
#define RIS_LOAD_CANDIDATE_IMAGE_SAMPLE risLoadCandidateImageSample
#define RIS_STORE_BAYER_VISIBILITY risStoreBayerVisibility
#define RIS_LOAD_BAYER_VISIBILITY risLoadBayerVisibility
#define RIS_LIGHT_HASH_MATCHES risLightHashMatches
#define RIS_RESOLVE_RESERVOIR_LIGHT_ID risResolveReservoirLightId
#define RIS_LOAD_PREVIOUS_RESERVOIR risLoadPreviousReservoir
#define RIS_MERGE_VISIBLE_CANDIDATES risMergeVisibleCandidates
#define RIS_MERGE_BAYER_SHARED_VISIBLE_CANDIDATES risMergeBayerSharedVisibleCandidates

#include "light_ris_template.glsl"

#undef RIS_LIGHT_SAMPLE
#undef RIS_LOAD_LIGHT
#undef RIS_CLUSTER_LIGHT_COUNT
#undef RIS_CLUSTER_LIGHT_ID
#undef RIS_LIGHT_WEIGHTS
#undef RIS_LIGHT_HASH
#undef RIS_LIGHT_VISIBLE
#undef RIS_EVALUATE_LIGHT
#undef RIS_CONCRETE_SAMPLE_VISIBLE
#undef RIS_LOAD_PREVIOUS_TEMPORAL_RESERVOIR
#undef RIS_LOAD_DIRECT_TEMPORAL_RESERVOIR
#undef RIS_STORE_TEMPORAL_RESERVOIR
#undef RIS_STORE_CANDIDATE_IMAGE_SAMPLE
#undef RIS_LOAD_CANDIDATE_IMAGE_SAMPLE
#undef RIS_STORE_BAYER_VISIBILITY
#undef RIS_LOAD_BAYER_VISIBILITY
#undef RIS_LIGHT_HASH_MATCHES
#undef RIS_RESOLVE_RESERVOIR_LIGHT_ID
#undef RIS_LOAD_PREVIOUS_RESERVOIR
#undef RIS_MERGE_VISIBLE_CANDIDATES
#undef RIS_MERGE_BAYER_SHARED_VISIBLE_CANDIDATES
#undef RIS_COMPUTE_LIGHTING_INIT
#undef RIS_COMPUTE_LIGHTING_APPLY
#undef RIS_COMPUTE_LIGHTING_UNIFIED
#undef RIS_TEMPORAL_RESET_RANDOM_SALT
#undef RIS_TEMPORAL_LIFETIME_RANDOM_SALT
#undef RIS_PRIMARY_MERGE_RANDOM_SALT
#undef RIS_BAYER_OWN_RANDOM_SALT
#undef RIS_BAYER_NEIGHBOR_RANDOM_SALT

#if LIGHT_POINT && RIS_APPLY_PASS
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

	vec3 ris_diffuse;
	vec3 ris_specular;
	computePointLightingRISApplySamples(P, N, V, material, pix, ris_active, ris_diffuse, ris_specular);

	diffuse += always_diffuse + ris_diffuse;
	specular += always_specular + ris_specular;
}
#endif

#endif // LIGHT_RIS_LIGHTS_GLSL_INCLUDED
