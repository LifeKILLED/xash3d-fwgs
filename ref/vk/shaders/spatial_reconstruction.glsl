// originally implemented by Mikhail Gorobets for Diligent Engine
// https://github.com/DiligentGraphics/DiligentEngine

#ifndef SPATIAL_RECONSTRUCTION_RADIUS
#define SPATIAL_RECONSTRUCTION_RADIUS 4.
#endif

#ifndef SPECULAR_INPUT_IMAGE
#define SPECULAR_INPUT_IMAGE indirect_specular
#endif

#ifndef SPECULAR_OUTPUT_IMAGE
#define SPECULAR_OUTPUT_IMAGE out_indirect_specular_reconstructed
#endif

#ifndef UPSCALE_SCALE
	#define UPSCALE_SCALE 2
#endif

#include "debug.glsl"

#define SPECULAR_CLAMPING_MAX 10.0
#define SPATIAL_RECONSTRUCTION_SAMPLES 16

#define GLSL
#include "ray_interop.h"
#undef GLSL

#define RAY_BOUNCE
#define RAY_QUERY
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba16f) uniform image2D SPECULAR_OUTPUT_IMAGE;

layout(set = 0, binding = 1, rgba32f) uniform readonly image2D position_t;
layout(set = 0, binding = 2, rgba16f) uniform readonly image2D normals_gs;
layout(set = 0, binding = 3, rgba8) uniform readonly image2D material_rmxx;
layout(set = 0, binding = 4, rgba16f) uniform readonly image2D SPECULAR_INPUT_IMAGE;
layout(set = 0, binding = 5, rgba32f) uniform readonly image2D reflection_direction_pdf;

layout(set = 0, binding = 7) uniform UBO { UniformBuffer ubo; } ubo;

#include "utils.glsl"
#include "noise.glsl"
#include "brdf.glsl"

#ifndef PI
	#define PI 3.14 // FIXME please
#endif

void readNormals(ivec2 uv, out vec3 geometry_normal, out vec3 shading_normal) {
	const vec4 n = imageLoad(normals_gs, uv);
	geometry_normal = normalDecode(n.xy);
	shading_normal = normalDecode(n.zw);
}

struct PixelAreaStatistic {
	float mean;
	float variance;
	float weightSum;
	vec4 colorSum;
};

float computeGaussianWeight(float texelDistance) {
	return exp(-0.66 * texelDistance * texelDistance); // assuming texelDistance is normalized to 1
}

// Visibility = G2(v,l,a) / (4 * (n,v) * (n,l))
// see https://google.github.io/filament/Filament.md.html#materialsystem/specularbrdf
float smithGGXVisibilityCorrelated(float NdotL, float NdotV, float alphaRoughness) {
	// G1 (masking) is % microfacets visible in 1 direction
	// G2 (shadow-masking) is % microfacets visible in 2 directions
	// If uncorrelated:
	//	G2(NdotL, NdotV) = G1(NdotL) * G1(NdotV)
	//	Less realistic as higher points are more likely visible to both L and V
	//
	// https://ubm-twvideo01.s3.amazonaws.com/o1/vault/gdc2017/Presentations/Hammon_Earl_PBR_Diffuse_Lighting.pdf

	float a2 = alphaRoughness * alphaRoughness;

	float GGXV = NdotL * sqrt(max(NdotV * NdotV * (1.0 - a2) + a2, 1e-7));
	float GGXL = NdotV * sqrt(max(NdotL * NdotL * (1.0 - a2) + a2, 1e-7));

	return 0.5 / (GGXV + GGXL);
}

// The following equation(s) model the distribution of microfacet normals across the area being drawn (aka D())
// Implementation from "Average Irregularity Representation of a Roughened Surface for Ray Reflection" by T. S. Trowbridge, and K. P. Reitz
// Follows the distribution function recommended in the SIGGRAPH 2013 course notes from EPIC Games, Equation 3.
float normalDistribution_GGX(float NdotH, float alphaRoughness) {
	// "Sampling the GGX Distribution of Visible Normals" (2018) by Eric Heitz - eq. (1)
	// https://jcgt.org/published/0007/04/01/

	// Make sure we reasonably handle alphaRoughness == 0
	// (which corresponds to delta function)
	alphaRoughness = max(alphaRoughness, 1e-3);

	float a2  = alphaRoughness * alphaRoughness;
	float nh2 = NdotH * NdotH;
	float f   = nh2 * a2 + (1.0 - nh2);
	return a2 / max(PI * f * f, 1e-9);
}

vec2 computeWeightRayLength(vec4 rayDirectionPDF, vec3 V, vec3 N, float roughness, float NdotV, float weight) {
	float rayLength = length(rayDirectionPDF.xyz);
	vec3 rayDirection = normalize(rayDirectionPDF.xyz);
	float PDF = rayDirectionPDF.w;
	float alphaRoughness = roughness * roughness;

	vec3 L = rayDirection;
	vec3 H = normalize(L + V);

	float NdotH = saturate(dot(N, H));
	float NdotL = saturate(dot(N, L));

	float vis = smithGGXVisibilityCorrelated(NdotL, NdotV, alphaRoughness);
	float D = normalDistribution_GGX(NdotH, alphaRoughness);
	float localBRDF = vis * D * NdotL;
	localBRDF *= computeGaussianWeight(weight);
	float rcpRayLength = rayLength == 0. ? 0. : 1. / rayLength;
	return vec2(max(localBRDF / max(PDF, 1.0e-5f), 1e-6), rcpRayLength);
}

// Weighted incremental variance
// https://en.wikipedia.org/wiki/Algorithms_for_calculating_variance
void computeWeightedVariance(inout PixelAreaStatistic stat, vec3 sampleColor, float weight) {
	stat.colorSum.xyz += weight * sampleColor;
	stat.weightSum += weight;

	float value = luminance(sampleColor.rgb);
	float prevMean = stat.mean;

	float rcpWeightSum = stat.weightSum == 0. ? 0. : 1. / stat.weightSum;

	stat.mean += weight * rcpWeightSum * (value - prevMean);
	stat.variance += weight * (value - prevMean) * (value - stat.mean);
}

float computeResolvedDepth(vec3 origin, vec3 position, float surfaceHitDistance) {
	return distance(origin, position) + surfaceHitDistance;
}

ivec2 clampScreenCoord(ivec2 pix, ivec2 res) {
	return max(ivec2(0), min(ivec2(res - 1), pix));
}

vec3 clampSpecular(vec3 specular, float maxLuminace) {
	float lum = luminance(specular);
	if (lum == 0.)
		return vec3(0.);

	float clamped = min(maxLuminace, lum);
	return specular * (clamped / lum);
}

void main() {
	const ivec2 pix = ivec2(gl_GlobalInvocationID);
	const ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);

	const ivec2 pix_scaled = pix / UPSCALE_SCALE;
	const ivec2 res_scaled = res / UPSCALE_SCALE;

	if (any(greaterThanEqual(pix, res))) {
		return;
	}

	rand01_state = ubo.ubo.random_seed + pix.x * 1833 + pix.y * 31337 + 12;

	if ((ubo.ubo.renderer_flags & RENDERER_FLAG_SPATIAL_RECONSTRUCTION) == 0) {
		imageStore(SPECULAR_OUTPUT_IMAGE, pix, imageLoad(SPECULAR_INPUT_IMAGE, pix / UPSCALE_SCALE));
		return;
	}

	const vec2 uv = (gl_GlobalInvocationID.xy + .5) / res * 2. - 1.;
	
	const vec3 origin = (ubo.ubo.inv_view * vec4(0, 0, 0, 1)).xyz;
	const vec3 position = imageLoad(position_t, pix).xyz;

	vec3 poisson[SPATIAL_RECONSTRUCTION_SAMPLES];
	poisson[0]  = vec3( 0.000000000,  0.000000000, 0.128544338);
	poisson[1]  = vec3(-0.797630122,  0.623220526, 0.044399352);
	poisson[2]  = vec3(-0.282518518,  0.028872056, 0.111670655);
	poisson[3]  = vec3( 0.520033692,  0.179071984, 0.089961024);
	poisson[4]  = vec3( 0.857848520,  0.407217906, 0.037285218);
	poisson[5]  = vec3( 0.260589372, -0.961425346, 0.016540041);
	poisson[6]  = vec3(-0.197658008,  0.629159807, 0.063970742);
	poisson[7]  = vec3(-0.246892394, -0.927460750, 0.018080349);
	poisson[8]  = vec3(-0.099761954, -0.393746506, 0.098064610);
	poisson[9]  = vec3(-0.676933518, -0.107831894, 0.062739748);
	poisson[10] = vec3( 0.289867508,  0.968136196, 0.014606041);
	poisson[11] = vec3( 0.836644372, -0.218037444, 0.036161873);
	poisson[12] = vec3(-0.499614432, -0.472562398, 0.061649521);
	poisson[13] = vec3( 0.947539128, -0.810473276, 0.006911358);
	poisson[14] = vec3( 0.310520506,  0.532561108, 0.060446005);
	poisson[15] = vec3( 0.567593882, -0.598135228, 0.034960177);

	vec3 geometry_normal, shading_normal;
	readNormals(pix, geometry_normal, shading_normal);

	vec3 V = normalize(origin - position);
	float NdotV = saturate(dot(shading_normal, V));

	float roughness = imageLoad(material_rmxx, pix).x;

	PixelAreaStatistic pixelAreaStat;
	pixelAreaStat.colorSum = vec4(0.0, 0.0, 0.0, 0.0);
	pixelAreaStat.weightSum = 0.0;
	pixelAreaStat.variance = 0.0;
	pixelAreaStat.mean = 0.0;

	float nearestSurfaceHitDistance = 0.0;

	vec3 result_color = vec3(0.);
	float weights_sum = 0.;

	vec3 aabbMin = imageLoad(reflection_direction_pdf, pix_scaled).xyz;
	vec3 aabbMax = aabbMin;
	for(int x = -1; x <= 1; x++) {
 		for(int y = -1; y <= 1; y++) {
 			const ivec2 p_scaled = pix_scaled + ivec2(x, y);
 			if (any(greaterThanEqual(p_scaled, res_scaled)) || any(lessThan(p_scaled, ivec2(0)))) {
 				continue;
 			}
			vec3 nearDir = imageLoad(reflection_direction_pdf, p_scaled).xyz;
			aabbMin = min(aabbMin, nearDir);
			aabbMax = max(aabbMax, nearDir);
 		}
 	}

	vec2 axisX = normalize(vec2(rand01(), rand01())) * SPATIAL_RECONSTRUCTION_RADIUS;
	vec2 axisY = vec2(-axisX.y, axisX.x);
 
 	// TODO: Try to implement sampling from https://youtu.be/MyTOGHqyquU?t=1043
	for (int i = 0; i < SPATIAL_RECONSTRUCTION_SAMPLES; i++)
	{
		vec2 offset = poisson[i].x * axisX + poisson[i].y * axisY;
		ivec2 p = clampScreenCoord(ivec2(vec2(pix) + vec2(0.5) + offset), res); 
		ivec2 p_scaled = p / UPSCALE_SCALE;

		vec4 reflDirPDF = imageLoad(reflection_direction_pdf, p_scaled);
		if (any(greaterThan(reflDirPDF.xyz, aabbMax)) || any(lessThan(reflDirPDF.xyz, aabbMin))) {
			continue;
		}

		vec2 weightLength = computeWeightRayLength(reflDirPDF, V, shading_normal, roughness, NdotV, poisson[i].z);
		vec3 sampleColor = clampSpecular(imageLoad(SPECULAR_INPUT_IMAGE, p_scaled).xyz, SPECULAR_CLAMPING_MAX);
		computeWeightedVariance(pixelAreaStat, sampleColor, weightLength.x);

		if (weightLength.x > 1.0e-6)
			nearestSurfaceHitDistance = max(weightLength.y, nearestSurfaceHitDistance);

		result_color += sampleColor.xyz * weightLength.x;
		weights_sum += weightLength.x;
	}

	if (weights_sum > 0.) {
		result_color /= weights_sum;
	}

	vec4 resolvedRadiance = pixelAreaStat.colorSum / max(pixelAreaStat.weightSum, 1e-6f);
	float resolvedVariance = pixelAreaStat.variance / max(pixelAreaStat.weightSum, 1e-6f);
	float resolvedDepth = computeResolvedDepth(origin, position, nearestSurfaceHitDistance);

	imageStore(SPECULAR_OUTPUT_IMAGE, pix, vec4(resolvedRadiance.xyz, resolvedVariance));
}
