#include "utils.glsl"
#include "noise.glsl"
#include "brdf.h"
#include "denoiser_config.glsl"

#define GLSL
#include "ray_interop.h"
#undef GLSL

#ifndef SPATIAL_RADIUS
#define SPATIAL_RADIUS 4.0
#endif

#ifndef SPATIAL_RANDOM_POISSON_ROTATION
#define SPATIAL_RANDOM_POISSON_ROTATION 1
#endif

#ifndef SPATIAL_SAMPLES
#define SPATIAL_SAMPLES 16
#endif

#ifndef POSITION_PLANE_THRESHOLD
#define POSITION_PLANE_THRESHOLD 0.010
#endif

#ifndef POSITION_DIST2_THRESHOLD
#define POSITION_DIST2_THRESHOLD 0.0004
#endif

#ifndef ROUGHNESS_DIFF_THRESHOLD
#define ROUGHNESS_DIFF_THRESHOLD 0.12
#endif

#ifndef SHADING_NORMAL_DOT_THRESHOLD
#define SHADING_NORMAL_DOT_THRESHOLD 0.95
#endif

#ifndef GEOMETRY_NORMAL_DOT_THRESHOLD
#define GEOMETRY_NORMAL_DOT_THRESHOLD 0.95
#endif

#ifndef SPATIAL_CONFIDENCE_MIN
#define SPATIAL_CONFIDENCE_MIN 0.1
#endif

#ifndef SPATIAL_CONFIDENCE_SCALE
#define SPATIAL_CONFIDENCE_SCALE 1.0
#endif

#ifndef SPATIAL_ENABLE_ROUGHNESS_GATE
#define SPATIAL_ENABLE_ROUGHNESS_GATE 1
#endif

#ifndef SPATIAL_ENABLE_GGX_TRANSFER
#define SPATIAL_ENABLE_GGX_TRANSFER 0
#endif

#ifndef SPATIAL_GGX_NORMALIZE_TO_CENTER
#define SPATIAL_GGX_NORMALIZE_TO_CENTER 1
#endif

#ifndef SPATIAL_GGX_MAX_GAIN
#define SPATIAL_GGX_MAX_GAIN 4.0
#endif

#ifndef SPATIAL_GGX_PDF_EPS
#define SPATIAL_GGX_PDF_EPS 1e-4
#endif

#ifndef SPATIAL_GGX_PDF_MAX_RATIO
#define SPATIAL_GGX_PDF_MAX_RATIO 16.0
#endif

#ifndef SPATIAL_ENABLE_PDF_REWEIGHT
#define SPATIAL_ENABLE_PDF_REWEIGHT 1
#endif

#ifndef SPATIAL_PDF_EPS
#define SPATIAL_PDF_EPS SPATIAL_GGX_PDF_EPS
#endif

#ifndef SPATIAL_PDF_MAX_RATIO
#define SPATIAL_PDF_MAX_RATIO SPATIAL_GGX_PDF_MAX_RATIO
#endif

#ifndef SPATIAL_LIGHTDIR_ZERO_EPS
#define SPATIAL_LIGHTDIR_ZERO_EPS 1e-8
#endif

#ifndef SPATIAL_DEFAULT_LIGHT_MODE
#if SPATIAL_ENABLE_GGX_TRANSFER
#define SPATIAL_DEFAULT_LIGHT_MODE 1
#else
#define SPATIAL_DEFAULT_LIGHT_MODE 0
#endif
#endif

#ifndef SPATIAL_RECONSTRUCTION_STAGE_ENABLED
#define SPATIAL_RECONSTRUCTION_STAGE_ENABLED 1
#endif

#ifndef SPATIAL_RECONSTRUCTION_CONF_MULT
#define SPATIAL_RECONSTRUCTION_CONF_MULT DENOISER_SPATIAL_RECONSTRUCTION_CONF_MULT
#endif

layout(local_size_x = 8, local_size_y = 8) in;

layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D OUTPUT_DIRECT;
layout(set = 0, binding = 1, rgba16f) uniform readonly image2D INPUT_DIRECT;
layout(set = 0, binding = 2, rgba16f) uniform readonly image2D INPUT_LIGHTDIR;
layout(set = 0, binding = 3, rgba32f) uniform readonly image2D POSITION_T;
layout(set = 0, binding = 4, rgba16f) uniform readonly image2D NORMALS_GS;
layout(set = 0, binding = 5, rgba8) uniform readonly image2D MATERIAL_RMXX;
layout(set = 0, binding = 6) uniform UBO { UniformBuffer ubo; } ubo;

const vec3 POISSON[16] = vec3[](
    vec3( 0.000000000,  0.000000000, 0.128544338),
    vec3(-0.797630122,  0.623220526, 0.044399352),
    vec3(-0.282518518,  0.028872056, 0.111670655),
    vec3( 0.520033692,  0.179071984, 0.089961024),
    vec3( 0.857848520,  0.407217906, 0.037285218),
    vec3( 0.260589372, -0.961425346, 0.016540041),
    vec3(-0.197658008,  0.629159807, 0.063970742),
    vec3(-0.246892394, -0.927460750, 0.018080349),
    vec3(-0.099761954, -0.393746506, 0.098064610),
    vec3(-0.676933518, -0.107831894, 0.062739748),
    vec3( 0.289867508,  0.968136196, 0.014606041),
    vec3( 0.836644372, -0.218037444, 0.036161873),
    vec3(-0.499614432, -0.472562398, 0.061649521),
    vec3( 0.947539128, -0.810473276, 0.006911358),
    vec3( 0.310520506,  0.532561108, 0.060446005),
    vec3( 0.567593882, -0.598135228, 0.034960177)
);

float normalGate(vec3 a, vec3 b, float threshold) {
    return step(threshold, max(dot(a, b), 0.0));
}

float positionGate(vec3 d, vec3 geomNorm, float invCenterDist) {
    float nPlaneDist = abs(dot(d, geomNorm)) * invCenterDist;
    float nDist2 = dot(d, d) * (invCenterDist * invCenterDist);
    float wPlane = step(nPlaneDist, POSITION_PLANE_THRESHOLD);
    float wDist = step(nDist2, POSITION_DIST2_THRESHOLD);
    return max(wPlane, wDist);
}

float clampWeightNonNegative(float w) {
    return max(w, 0.0);
}

vec3 clampRadianceNonNegative(vec3 c) {
    return max(c, vec3(0.0));
}

vec3 defaultLightDirection(vec3 N, vec3 V, float roughness) {
#if SPATIAL_DEFAULT_LIGHT_MODE == 1
    vec3 R = reflect(-V, N);
    float rough_mix = clamp(roughness * roughness, 0.0, 1.0);
    return normalize(mix(R, N, rough_mix));
#else
    return N;
#endif
}

vec3 resolveLightDirection(vec3 sampledL, vec3 N, vec3 V, float roughness) {
    float len2 = dot(sampledL, sampledL);
    return (len2 > SPATIAL_LIGHTDIR_ZERO_EPS) ? (sampledL * inversesqrt(len2)) : defaultLightDirection(N, V, roughness);
}

float lightSamplingPdf(vec3 N, vec3 V, vec3 L, float roughness) {
    float NdotL = max(dot(N, L), 0.0);
    if (NdotL <= 1e-6) {
        return 0.0;
    }

#if SPATIAL_DEFAULT_LIGHT_MODE == 1
    float NdotV = max(dot(N, V), 0.0);
    if (NdotV <= 1e-6) {
        return 0.0;
    }

    vec3 H = normalize(L + V);
    float NdotH = max(dot(N, H), 0.0);
    float VdotH = max(dot(V, H), 1e-6);

    float alpha = max(roughness * roughness, 1e-4);
    float a2 = alpha * alpha;
    float dDen = NdotH * NdotH * (a2 - 1.0) + 1.0;
    float D = a2 / (PI * dDen * dDen);

    // Microfacet reflection PDF for wi from wh mapping.
    return (D * NdotH) / max(4.0 * VdotH, 1e-6);
#else
    // Cosine-weighted hemisphere PDF.
    return NdotL * (1.0 / PI);
#endif
}

void main()
{
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
    if (any(greaterThanEqual(p, res))) return;

    vec4 centerColor = imageLoad(INPUT_DIRECT, p);
    vec4 centerL = imageLoad(INPUT_LIGHTDIR, p);

    if (DENOISER_ENABLE_SPATIAL_RECONSTRUCTION == 0 || SPATIAL_RECONSTRUCTION_STAGE_ENABLED == 0) {
        imageStore(OUTPUT_DIRECT, p, centerColor);
        return;
    }

    vec4 n0enc = imageLoad(NORMALS_GS, p);
    vec3 G0 = normalDecode(n0enc.xy);
    vec3 N0 = normalDecode(n0enc.zw);
    vec3 P0 = imageLoad(POSITION_T, p).xyz;
    float R0 = imageLoad(MATERIAL_RMXX, p).x;
    vec3 camPos = (ubo.ubo.inv_view * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
    vec3 V0 = normalize(camPos - P0);
    vec3 L0n = resolveLightDirection(centerL.xyz, N0, V0, R0);
    vec3 center_rgb = clampRadianceNonNegative(centerColor.rgb);
    float center_a = max(centerColor.a, 0.0);

    float invCenterDist = 1.0 / max(length(P0), 1.0);
    // Center is treated like a regular sample: BRDF/pdf, confidence and Poisson weight.
    float center_pdf = lightSamplingPdf(N0, V0, L0n, R0);
    float center_confW = clampWeightNonNegative(max(SPATIAL_CONFIDENCE_MIN, center_a * SPATIAL_CONFIDENCE_SCALE));
    float center_spatialW = clampWeightNonNegative(POISSON[0].z);
    float center_w = clampWeightNonNegative(center_pdf * center_confW * center_spatialW);
    vec3 sumC = center_rgb * center_w;
    float conf_sum = center_a;
    float sumW = center_w;
    int accepted_samples = 0;

    vec2 axisX = vec2(SPATIAL_RADIUS, 0.0);
#if SPATIAL_RANDOM_POISSON_ROTATION
    rand01_state = uint(ubo.ubo.random_seed) + uint(p.x) * 1833u + uint(p.y) * 31337u + 12u;
    float rotation_angle = rand01() * (2.0 * PI);
    vec2 rotation_dir = vec2(cos(rotation_angle), sin(rotation_angle));
    axisX = rotation_dir * SPATIAL_RADIUS;
#endif
    vec2 axisY = vec2(-axisX.y, axisX.x);

    for (int i = 0; i < SPATIAL_SAMPLES; i++) {
        vec2 offset = POISSON[i].x * axisX + POISSON[i].y * axisY;
        ivec2 q = clamp(ivec2(vec2(p) + vec2(0.5) + offset), ivec2(0), res - 1);
        if (all(equal(q, p))) continue;

        vec4 normEnc = imageLoad(NORMALS_GS, q);
        vec3 N1 = normalDecode(normEnc.zw);
        float wn = normalGate(N0, N1, SHADING_NORMAL_DOT_THRESHOLD);
        if (wn == 0.0) continue;

        vec3 G1 = normalDecode(normEnc.xy);
        float wg = normalGate(G0, G1, GEOMETRY_NORMAL_DOT_THRESHOLD);
        if (wg == 0.0) continue;

        vec3 P1 = imageLoad(POSITION_T, q).xyz;
        float wp = positionGate(P1 - P0, G0, invCenterDist);
        if (wp == 0.0) continue;

        float R1 = imageLoad(MATERIAL_RMXX, q).x;
        float wr = 1.0;
#if SPATIAL_ENABLE_ROUGHNESS_GATE
        wr = step(abs(R0 - R1), ROUGHNESS_DIFF_THRESHOLD);
        if (wr == 0.0) continue;
#endif

        vec4 c = imageLoad(INPUT_DIRECT, q);
        float c_a = clamp(c.a, 0.0, 1.0);
        conf_sum -= (1.0 - c_a) * SPATIAL_RECONSTRUCTION_CONF_MULT;

        vec3 Lqraw = imageLoad(INPUT_LIGHTDIR, q).xyz;
        vec3 V1 = normalize(camPos - P1);
        vec3 LqAtCenter = resolveLightDirection(Lqraw, N0, V0, R0);
        vec3 LqAtSample = resolveLightDirection(Lqraw, N1, V1, R1);

        float pdf_target = lightSamplingPdf(N0, V0, LqAtCenter, R0);
        if (pdf_target <= 1e-6) continue;
        float wl = pdf_target;

#if SPATIAL_ENABLE_PDF_REWEIGHT
        float pdf_source = lightSamplingPdf(N1, V1, LqAtSample, R1);
        wl = clamp(pdf_target / max(pdf_source, SPATIAL_PDF_EPS), 0.0, SPATIAL_PDF_MAX_RATIO);
#endif

        wl = clamp(wl, 0.0, SPATIAL_GGX_MAX_GAIN);

        float confW = max(SPATIAL_CONFIDENCE_MIN, c.a * SPATIAL_CONFIDENCE_SCALE);
        confW = clampWeightNonNegative(confW);
        float spatialW = clampWeightNonNegative(POISSON[i].z);
        float w = clampWeightNonNegative(wn * wg * wp * wr * wl * confW * spatialW);

        if (w > 0.0) {
            vec3 c_rgb = clampRadianceNonNegative(c.rgb);
            sumC += c_rgb * w;
            sumW += w;
            accepted_samples++;
        }
    }

    vec3 outC = clampRadianceNonNegative(sumC / max(sumW, 1e-6));
    float outA = max(conf_sum, 0.0);

    // Mirror fallback: if nothing valid was gathered, keep center sample.
    if (accepted_samples == 0) {
        outC = center_rgb;
    }

    imageStore(OUTPUT_DIRECT, p, vec4(outC, outA));
}
