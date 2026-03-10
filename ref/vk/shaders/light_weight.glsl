#ifndef LIGHT_WEIGHT_GLSL_INCLUDED
#define LIGHT_WEIGHT_GLSL_INCLUDED

#include "brdf.glsl"
#include "light_common.glsl"
#include "light_polygon.glsl"

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

#ifndef NON_BRDF_POINT_LIGHTS_MULTIPLIER
#define NON_BRDF_POINT_LIGHTS_MULTIPLIER 2.0
#endif

float specularWeight(vec3 N, vec3 L, vec3 V, float roughness)
{
    vec3 H = normalize(L + V);
    float NoH = max(dot(N, H), 0.0);
    float power = mix(128.0, 4.0, roughness * roughness);
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

        float cone_spread = sqrt(max(1.0 - pl.dir_stopdot2.a * pl.dir_stopdot2.a, 0.0));
        spec_angular_radius = max(LIGHT_SPECULAR_MIN_ANGULAR, cone_spread * LIGHT_SPECULAR_ANGULAR_SCALE);
    } else {
        vec3 toL = pl.origin_r2.xyz - P;
        float dist2 = max(dot(toL, toL), EPSILON);
        float inv_dist = inversesqrt(dist2);
        L = toL * inv_dist;

        float spot_dot = dot(L, pl.dir_stopdot2.xyz);
        float stopdot2 = pl.dir_stopdot2.a;
        float stopdot = pl.color_stopdot.a;
        float spot_att = (spot_dot < stopdot) ? max(0.0, (spot_dot - stopdot2) / (stopdot - stopdot2)) : 1.0;
        float radius_ratio = sqrt(max(0.0, 1.0 - pl.origin_r2.w / dist2));
        geom_weight = 2.0 * kPi * (1.0 - radius_ratio) * spot_att * NON_BRDF_POINT_LIGHTS_MULTIPLIER;

        float source_radius = sqrt(max(pl.origin_r2.w, 0.0));
        spec_angular_radius = max(LIGHT_SPECULAR_MIN_ANGULAR, source_radius * inv_dist * LIGHT_SPECULAR_ANGULAR_SCALE);
    }

    if (geom_weight > 0.0) {
        float roughness_for_spec = clamp(roughness + spec_angular_radius * LIGHT_SPECULAR_ROUGHNESS_FROM_ANGULAR, 0.0, 1.0);
        float light_weight = geom_weight * luminance(pl.color_stopdot.rgb);
        float spec_weight = specularWeight(N, L, V, roughness_for_spec);
        result = vec2(light_weight, light_weight * spec_weight * computeSpecularCompensation(spec_angular_radius));
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
        vec3 dir = poly.center + plane.xyz * POLYGON_LIGHT_SAMPLE_NORMAL_EPSILON - P;
        float dist2 = max(dot(dir, dir), 1e-6);
        vec3 L = dir * inversesqrt(dist2);
        float denom = dot(L, plane.xyz);

        if (denom < -POLYGON_LIGHT_MIN_DENOM) {
            float geom_weight = poly.area * max(-denom, 0.0) * (0.4 / dist2);
            geom_weight *= smoothstep(
                POLYGON_SELF_LIGHT_PLANE_BIAS,
                POLYGON_SELF_LIGHT_PLANE_BIAS + POLYGON_SELF_LIGHT_FADE_RANGE,
                plane_dist);

            if (geom_weight > 0.0) {
                float dist = max(0.0, -plane_dist / denom);
                float spec_angular_radius = computeSpecularAngularRadius(sqrt(max(poly.area, 0.0) * (1.0 / kPi)), dist);
                float roughness_for_spec = clamp(roughness + spec_angular_radius * LIGHT_SPECULAR_ROUGHNESS_FROM_ANGULAR, 0.0, 1.0);
                float light_weight = geom_weight * luminance(poly.emissive);
                float spec_weight = specularWeight(N, L, V, roughness_for_spec);
                result = vec2(light_weight, light_weight * spec_weight * computeSpecularCompensation(spec_angular_radius));
            }
        }
    }

    return result;
}

#endif // LIGHT_WEIGHT_GLSL_INCLUDED