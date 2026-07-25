#ifndef LIGHT_WEIGHT_GLSL_INCLUDED
#define LIGHT_WEIGHT_GLSL_INCLUDED

#include "brdf.glsl"

#ifndef EPSILON
#define EPSILON 1e-2
#endif

#ifndef POLYGON_SELF_LIGHT_PLANE_BIAS
#define POLYGON_SELF_LIGHT_PLANE_BIAS 1.0
#endif

#ifndef POLYGON_SELF_LIGHT_FADE_RANGE
#define POLYGON_SELF_LIGHT_FADE_RANGE 2.0
#endif

#ifndef POLYGON_LIGHT_MIN_DENOM
#define POLYGON_LIGHT_MIN_DENOM 1e-4
#endif

#ifndef POLYGON_LIGHT_SAMPLE_NORMAL_EPSILON
#define POLYGON_LIGHT_SAMPLE_NORMAL_EPSILON 1e-3
#endif

#ifndef LIGHT_SPECULAR_MIN_ANGULAR
#define LIGHT_SPECULAR_MIN_ANGULAR 0.0025
#endif

#ifndef LIGHT_SPECULAR_ANGULAR_SCALE
#define LIGHT_SPECULAR_ANGULAR_SCALE 1.0
#endif

#ifndef LIGHT_SPECULAR_ROUGHNESS_FROM_ANGULAR
#define LIGHT_SPECULAR_ROUGHNESS_FROM_ANGULAR 2.0
#endif

#ifndef LIGHT_SPECULAR_GAIN_FROM_ANGULAR
#define LIGHT_SPECULAR_GAIN_FROM_ANGULAR 4.0
#endif

#ifndef LIGHT_SPECULAR_GAIN_MAX
#define LIGHT_SPECULAR_GAIN_MAX 2.0
#endif

#ifndef LIGHT_SPECULAR_PROPOSAL_DIFFUSE_MIN
#define LIGHT_SPECULAR_PROPOSAL_DIFFUSE_MIN 0.15
#endif

#ifndef LIGHT_SPECULAR_PROPOSAL_DIFFUSE_SMOOTH
#define LIGHT_SPECULAR_PROPOSAL_DIFFUSE_SMOOTH 1.0
#endif

#ifndef NON_BRDF_POINT_LIGHTS_MULTIPLIER
#define NON_BRDF_POINT_LIGHTS_MULTIPLIER 2.0
#endif

vec4 normalizedPolygonPlane(const PolygonLight poly) {
	const float nlen = max(length(poly.plane.xyz), 1e-6);
	return vec4(poly.plane.xyz / nlen, poly.plane.w / nlen);
}

float specularWeight(vec3 N, vec3 L, vec3 V, float roughness)
{
	const vec3 H = normalize(L + V);
	const float NoH = max(dot(N, H), 0.0);
	const float power = mix(128.0, 4.0, roughness * roughness);
	return pow(NoH, power);
}

float computeSpecularAngularRadius(float source_extent, float dist)
{
	float angular = source_extent / max(abs(dist), EPSILON);
	angular = max(angular * LIGHT_SPECULAR_ANGULAR_SCALE, LIGHT_SPECULAR_MIN_ANGULAR);
	return angular;
}

float computeSpecularCompensation(float angular_radius)
{
	return clamp(1.0 + angular_radius * LIGHT_SPECULAR_GAIN_FROM_ANGULAR, 1.0, LIGHT_SPECULAR_GAIN_MAX);
}

float computeSpecularProposalWeight(float light_weight, float guided_specular_weight, float roughness)
{
	const float diffuse_floor = mix(
		LIGHT_SPECULAR_PROPOSAL_DIFFUSE_SMOOTH,
		LIGHT_SPECULAR_PROPOSAL_DIFFUSE_MIN,
		roughness) * light_weight;
	return max(guided_specular_weight, diffuse_floor);
}

float polygonSelfLightFade(float plane_dist)
{
	return clamp(
		(plane_dist - POLYGON_SELF_LIGHT_PLANE_BIAS) / max(POLYGON_SELF_LIGHT_FADE_RANGE, EPSILON),
		0.0,
		1.0);
}

float onionCellMaxDirectionDot(vec3 center_dir, vec3 axis, float sin_half_angle)
{
	const float center_dot = clamp(dot(center_dir, axis), -1.0, 1.0);
	const float sin_angle = clamp(sin_half_angle, 0.0, 1.0);
	const float cos_angle = sqrt(max(1.0 - sin_angle * sin_angle, 0.0));
	const float sin_center = sqrt(max(1.0 - center_dot * center_dot, 0.0));

	if (center_dot >= cos_angle) {
		return 1.0;
	}

	return clamp(center_dot * cos_angle + sin_center * sin_angle, -1.0, 1.0);
}

float lightPointOnionWeightCalculation(PointLight pl, vec3 cell_center, float cell_radius)
{
	const float volume_radius = max(cell_radius, 0.0);
	const vec3 to_light = pl.origin_r2.xyz - cell_center;
	const float center_dist2 = dot(to_light, to_light);
	const float center_dist = sqrt(max(center_dist2, EPSILON));
	const vec3 center_dir = to_light / center_dist;

	const float light_radius = sqrt(max(pl.origin_r2.w, 0.0));
	const float effective_radius = light_radius + volume_radius;

	float solid_angle = 2.0 * kPi;

	if (center_dist > effective_radius) {
		const float radius_ratio2 = clamp(
			effective_radius * effective_radius / max(center_dist2, EPSILON), 0.0, 1.0);
		solid_angle = 2.0 * kPi * (1.0 - sqrt(max(1.0 - radius_ratio2, 0.0)));
	}

	const float stopdot2 = pl.dir_stopdot2.a;
	const float stopdot = pl.color_stopdot.a;
	float spot_att = 1.0;

	if (stopdot2 > -1.0) {
		float max_spot_dot = 1.0;

		if (center_dist > volume_radius) {
			max_spot_dot = onionCellMaxDirectionDot(
				center_dir, pl.dir_stopdot2.xyz, clamp(volume_radius / center_dist, 0.0, 1.0));
		}

		if (max_spot_dot < stopdot) {
			spot_att = max(0.0, (max_spot_dot - stopdot2) / max(stopdot - stopdot2, EPSILON));
		}
	}

	return solid_angle * spot_att * NON_BRDF_POINT_LIGHTS_MULTIPLIER
		* luminance(pl.color_stopdot.rgb);
}

float lightPolygonOnionWeightCalculation(PolygonLight poly, vec3 cell_center, float cell_radius)
{
	const float volume_radius = max(cell_radius, 0.0);
	const vec4 plane = normalizedPolygonPlane(poly);
	const float max_plane_dist = dot(plane, vec4(cell_center, 1.0)) + volume_radius;

	if (max_plane_dist <= POLYGON_SELF_LIGHT_PLANE_BIAS) {
		return 0.0;
	}

	const vec3 from_light = cell_center - poly.center;
	const float center_dist2 = dot(from_light, from_light);
	const float center_dist = sqrt(max(center_dist2, EPSILON));
	const vec3 center_dir = from_light / center_dist;
	float light_facing = 1.0;

	if (center_dist > volume_radius) {
		light_facing = max(onionCellMaxDirectionDot(
			center_dir, plane.xyz, clamp(volume_radius / center_dist, 0.0, 1.0)), 0.0);
	}

	if (light_facing <= 0.0) {
		return 0.0;
	}

	const float polygon_radius = sqrt(max(poly.area, 0.0) * (1.0 / kPi));
	const float volume_dist = max(center_dist - volume_radius, max(polygon_radius, EPSILON));
	const float geom_weight = poly.area * light_facing * (0.4 / (volume_dist * volume_dist));

	return geom_weight * polygonSelfLightFade(max_plane_dist) * luminance(poly.emissive);
}

vec2 lightPointWeightCalculation(
	PointLight pl,
	vec3 P, vec3 N, vec3 V,
	float roughness)
{
	vec2 result = vec2(0.0);

	vec3 L;
	float geom_weight;
	float spec_angular_radius;

	if (pl.environment != 0) {
		L = pl.dir_stopdot2.xyz;
		geom_weight = 2.0 * kPi * (1.0 - pl.dir_stopdot2.a) * NON_BRDF_POINT_LIGHTS_MULTIPLIER;

		const float cone_spread = sqrt(max(1.0 - pl.dir_stopdot2.a * pl.dir_stopdot2.a, 0.0));
		spec_angular_radius = max(LIGHT_SPECULAR_MIN_ANGULAR, cone_spread * LIGHT_SPECULAR_ANGULAR_SCALE);
	} else {
		const vec3 toL = pl.origin_r2.xyz - P;
		const float dist2 = max(dot(toL, toL), EPSILON);
		const float inv_dist = inversesqrt(dist2);
		L = toL * inv_dist;

		const float spot_dot = dot(L, pl.dir_stopdot2.xyz);
		const float stopdot2 = pl.dir_stopdot2.a;
		const float stopdot = pl.color_stopdot.a;
		const float spot_att = (spot_dot < stopdot) ? max(0.0, (spot_dot - stopdot2) / (stopdot - stopdot2)) : 1.0;
		const float radius_ratio = sqrt(max(0.0, 1.0 - pl.origin_r2.w / dist2));
		geom_weight = 2.0 * kPi * (1.0 - radius_ratio) * spot_att * NON_BRDF_POINT_LIGHTS_MULTIPLIER;

		const float source_radius = sqrt(max(pl.origin_r2.w, 0.0));
		spec_angular_radius = max(LIGHT_SPECULAR_MIN_ANGULAR, source_radius * inv_dist * LIGHT_SPECULAR_ANGULAR_SCALE);
	}

	if (geom_weight > 0.0) {
		const float roughness_for_spec = clamp(roughness + spec_angular_radius * LIGHT_SPECULAR_ROUGHNESS_FROM_ANGULAR, 0.0, 1.0);
		const float light_weight = geom_weight * luminance(pl.color_stopdot.rgb);
		const float spec_weight = specularWeight(N, L, V, roughness_for_spec);
		const float spec_proposal_weight = computeSpecularProposalWeight(
			light_weight,
			light_weight * spec_weight * computeSpecularCompensation(spec_angular_radius),
			roughness * roughness);
		result = vec2(light_weight, spec_proposal_weight);
	}

	return result;
}

vec2 lightPolygonWeightCalculation(
	PolygonLight poly,
	vec3 P, vec3 N, vec3 V,
	float roughness)
{
	vec2 result = vec2(0.0);

	const vec4 plane = normalizedPolygonPlane(poly);
	const float plane_dist = dot(plane, vec4(P, 1.0));

	if (plane_dist > POLYGON_SELF_LIGHT_PLANE_BIAS) {
		const vec3 dir = poly.center + plane.xyz * POLYGON_LIGHT_SAMPLE_NORMAL_EPSILON - P;
		const float dist2 = max(dot(dir, dir), 1e-6);
		const vec3 L = dir * inversesqrt(dist2);
		const float denom = dot(L, plane.xyz);

		if (denom < -POLYGON_LIGHT_MIN_DENOM) {
			float geom_weight = poly.area * max(-denom, 0.0) * (0.4 / dist2);
			geom_weight *= polygonSelfLightFade(plane_dist);

			if (geom_weight > 0.0) {
				const float dist = max(0.0, -plane_dist / denom);
				const float spec_angular_radius = computeSpecularAngularRadius(sqrt(max(poly.area, 0.0) * (1.0 / kPi)), dist);
				const float roughness_for_spec = clamp(roughness + spec_angular_radius * LIGHT_SPECULAR_ROUGHNESS_FROM_ANGULAR, 0.0, 1.0);
				const float light_weight = geom_weight * luminance(poly.emissive);
				const float spec_weight = specularWeight(N, L, V, roughness_for_spec);
				const float spec_proposal_weight = computeSpecularProposalWeight(
					light_weight,
					light_weight * spec_weight * computeSpecularCompensation(spec_angular_radius),
					roughness * roughness);
				result = vec2(light_weight, spec_proposal_weight);
			}
		}
	}

	return result;
}

vec2 lightWeightFromIndex(uint light_index, vec3 P, vec3 N, vec3 V, float roughness)
{
#if LIGHT_POINT
	if (light_index >= lights.m.num_point_lights) {
		return vec2(0.0);
	}
	return lightPointWeightCalculation(lights.m.point_lights[light_index], P, N, V, roughness);
#elif LIGHT_POLYGON
	if (light_index >= lights.m.num_polygons) {
		return vec2(0.0);
	}
	return lightPolygonWeightCalculation(lights.m.polygons[light_index], P, N, V, roughness);
#else
	return vec2(0.0);
#endif
}

#endif // LIGHT_WEIGHT_GLSL_INCLUDED
