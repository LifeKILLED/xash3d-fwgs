#ifndef LTC_POLYGON_GLSL_INCLUDED
#define LTC_POLYGON_GLSL_INCLUDED

// GGX fit and polygon integration from:
// Heitz et al., Real-Time Polygonal-Light Shading with Linearly Transformed Cosines.
// The reference data/code license is retained in ref/vk/ltc_code.LICENSE.

const float LTC_LUT_SIZE = 64.0;
const float LTC_LUT_SCALE = (LTC_LUT_SIZE - 1.0) / LTC_LUT_SIZE;
const float LTC_LUT_BIAS = 0.5 / LTC_LUT_SIZE;
const float LTC_MIN_ROUGHNESS = 0.01;
const float LTC_LIGHT_PLANE_MIN_DISTANCE = 0.01;
const float LTC_EDGE_MIN_SINE = 1e-5;

#ifndef LTC_SIGNED_DISTANCE_CULLING
#define LTC_SIGNED_DISTANCE_CULLING 1
#endif

vec3 ltcIntegrateEdgeVector(vec3 v1, vec3 v2)
{
	const float x = clamp(dot(v1, v2), -1.0, 1.0);
	const vec3 edge_cross = cross(v1, v2);
	if (dot(edge_cross, edge_cross) <= LTC_EDGE_MIN_SINE * LTC_EDGE_MIN_SINE) {
		return vec3(0.0);
	}
	const float y = abs(x);
	const float a = 0.8543985 + (0.4965155 + 0.0145206 * y) * y;
	const float b = 3.4175940 + (4.1616724 + y) * y;
	const float v = a / b;
	const float theta_over_sin_theta = x > 0.0
		? v
		: 0.5 * inversesqrt(max(1.0 - x * x, 1e-7)) - v;
	return edge_cross * theta_over_sin_theta;
}

vec3 ltcPolygonSpecular(
	PolygonLight poly,
	vec3 P,
	vec3 N,
	vec3 V,
	MaterialProperties material)
{
	const uint vertices_offset = poly.vertices_count_offset & 0xffffu;
	const uint vertices_count = min(
		poly.vertices_count_offset >> 16,
		uint(MAX_POLYGON_VERTEX_COUNT));
	const float ndotv = clamp(dot(N, V), 0.0, 1.0);
	if (vertices_count < 3u || ndotv <= 1e-5) {
		return vec3(0.0);
	}

#if LTC_SIGNED_DISTANCE_CULLING
	const float receiver_plane_distance = dot(normalizedPolygonPlane(poly), vec4(P, 1.0));
	if (receiver_plane_distance <= LTC_LIGHT_PLANE_MIN_DISTANCE) {
		return vec3(0.0);
	}
#endif

	vec2 lut_uv = vec2(clamp(material.roughness, LTC_MIN_ROUGHNESS, 1.0), sqrt(1.0 - ndotv));
	lut_uv = lut_uv * LTC_LUT_SCALE + LTC_LUT_BIAS;
	const vec4 matrix_lut = texture(ltc_lut_matrix, lut_uv);
	const vec4 amplitude_lut = texture(ltc_lut_amplitude, lut_uv);
	const mat3 inverse_ltc = mat3(
		vec3(matrix_lut.x, 0.0, matrix_lut.y),
		vec3(0.0, 1.0, 0.0),
		vec3(matrix_lut.z, 0.0, matrix_lut.w));

	vec3 tangent = V - N * ndotv;
	if (dot(tangent, tangent) <= 1e-8) {
		const vec3 axis = abs(N.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0);
		tangent = cross(axis, N);
	}
	tangent = normalize(tangent);
	const vec3 bitangent = cross(N, tangent);
	const mat3 world_to_ltc = inverse_ltc * transpose(mat3(tangent, bitangent, N));

	vec3 input_vertices[MAX_POLYGON_VERTEX_COUNT];
	for (uint i = 0u; i < uint(MAX_POLYGON_VERTEX_COUNT); ++i) {
		input_vertices[i] = i < vertices_count
			? world_to_ltc * (lights.m.polygon_vertices[vertices_offset + i].xyz - P)
			: vec3(0.0);
	}

	// Clipless LTC approximation: integrate the complete transformed contour,
	// then use ltc_lut_amplitude.w to approximate the portion above the cosine
	// horizon. This avoids topology changes from explicit polygon clipping.
	vec3 edge_sum = vec3(0.0);
	for (uint i = 0u; i < uint(MAX_POLYGON_VERTEX_COUNT); ++i) {
		if (i >= vertices_count) {
			break;
		}
		const uint next_i = i + 1u == vertices_count ? 0u : i + 1u;
		const float length1_squared = dot(input_vertices[i], input_vertices[i]);
		const float length2_squared = dot(input_vertices[next_i], input_vertices[next_i]);
		if (length1_squared <= 1e-12 || length2_squared <= 1e-12) {
			return vec3(0.0);
		}
		const vec3 v1 = input_vertices[i] * inversesqrt(length1_squared);
		const vec3 v2 = input_vertices[next_i] * inversesqrt(length2_squared);
		edge_sum += ltcIntegrateEdgeVector(v1, v2);
	}

	const float contour_length = length(edge_sum);
	if (contour_length <= 1e-8) {
		return vec3(0.0);
	}
	const float contour_elevation = clamp(edge_sum.z / contour_length, -1.0, 1.0);
	vec2 horizon_uv = vec2(
		contour_elevation * 0.5 + 0.5,
		clamp(contour_length, 0.0, 1.0));
	horizon_uv = horizon_uv * LTC_LUT_SCALE + LTC_LUT_BIAS;
	const float horizon_scale = max(texture(ltc_lut_amplitude, horizon_uv).w, 0.0);
	const float integral = contour_length * horizon_scale;
	const vec3 f0 = mix(vec3(0.04), material.base_color, material.metalness);
	const vec3 fresnel_amplitude = f0 * amplitude_lut.x + (vec3(1.0) - f0) * amplitude_lut.y;
	return poly.emissive * integral * max(fresnel_amplitude, vec3(0.0));
}

#endif
