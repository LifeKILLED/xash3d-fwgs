#include "debug.glsl"
#include "denoiser_config.glsl"
#include "utils.glsl"
#include "color_spaces.glsl"
#include "brdf.h"

#define GLSL
#include "ray_interop.h"
#undef GLSL

#define EPS 1e-6

#ifndef ATROUS_STEP
#define ATROUS_STEP 1
#endif

#ifndef AGGRESSIVE_DENOISE
#define AGGRESSIVE_DENOISE 0
#endif

#ifndef VARIANCE_RELAX_EDGE
#define VARIANCE_RELAX_EDGE 0.0
#endif

#ifndef VARIANCE_FLATTEN_KERNEL
#define VARIANCE_FLATTEN_KERNEL 0.0
#endif

#ifndef ATROUS_WITHOUT_VARIANCE
#define ATROUS_WITHOUT_VARIANCE 0
#endif

#define VARIANCE_MIN 0.0
#define VARIANCE_MAX 0.25
#define VARIANCE_RADIUS 2

#define ROUGHNESS_DIFF_THRESHOLD 0.12
#define ATROUS_BLACK_LUMA_THRESHOLD 1e-4
#define GEOMETRY_NORMAL_DOT_THRESHOLD 0.75
#define COMMON_SHADING_NORMAL_DOT_THRESHOLD 0.98
#define ATROUS_FLAT_GEOM_DOT_THRESHOLD 0.985
#define ATROUS_SHADING_GATE_FLAT_RELAX 0.6
#define ATROUS_NORMAL_GATE_SOFTNESS 0.05
#define ATROUS_NORMAL_GATE_MIN_WEIGHT 0.0
#define ATROUS_POSITION_STEP_GROWTH 0.35

#define ATROUS_USE_HONEST_KERNEL 1
#ifndef ATROUS_KERNEL_RADIUS
#if ATROUS_USE_HONEST_KERNEL
#define ATROUS_KERNEL_RADIUS 2
#else
#define ATROUS_KERNEL_RADIUS 1
#endif
#endif

// Diffuse configuration.
#define DIFFUSE_MAX_STEP DENOISER_MAX_ATROUS_STEP_DIFFUSE
#define DIFFUSE_MASK_CHANNEL 0
#define DIFFUSE_MASK_DIFF_MIN 0.01
#define DIFFUSE_MASK_DIFF_MAX 0.30
#define DIFFUSE_MASK_GATE_STRENGTH 1.0
#define DIFFUSE_LUMA_GATE_ENABLE 1
#define DIFFUSE_LUMA_THR_MIN 0.07
#define DIFFUSE_LUMA_THR_AT_HALF_VAR 1.0
#define DIFFUSE_LUMA_SOFTNESS_MULT 3.2
#define DIFFUSE_LUMA_REL_EPS 0.03
#define DIFFUSE_LUMA_BLEND 0.30

// Specular configuration.
#define SPECULAR_MAX_STEP DENOISER_MAX_ATROUS_STEP_SPECULAR
#define SPECULAR_LUMA_GATE_ENABLE 0
#define SPECULAR_LUMA_THR_MIN 0.05
#define SPECULAR_LUMA_THR_AT_HALF_VAR 1.0
#define SPECULAR_LUMA_SOFTNESS_MULT 2.0
#define SPECULAR_LUMA_REL_EPS 0.03
#define SPECULAR_LUMA_BLEND 0.35

const float KERNEL5_1D[5] = float[5](1, 4, 6, 4, 1);

layout(local_size_x = 8, local_size_y = 8) in;

#ifndef IN_DIFFUSE_RADIANCE
#define IN_DIFFUSE_RADIANCE diffuse_mixed
#endif

#ifndef IN_SPECULAR_RADIANCE
#define IN_SPECULAR_RADIANCE specular_mixed
#endif

layout(set = 0, binding = 0, rgba16f) uniform readonly image2D IN_DIFFUSE_RADIANCE;
layout(set = 0, binding = 1, rgba16f) uniform readonly image2D IN_SPECULAR_RADIANCE;

#ifdef VARIANCE_PASS
layout(set = 0, binding = 2, rgba16f) uniform writeonly image2D out_diffuse_atrous_variance;
layout(set = 0, binding = 3, rgba16f) uniform writeonly image2D out_specular_atrous_variance;
#else
#ifndef OUTPUT_DIFFUSE_RADIANCE
#define OUTPUT_DIFFUSE_RADIANCE out_diffuse_direct_atrous
#endif

#ifndef OUTPUT_SPECULAR_RADIANCE
#define OUTPUT_SPECULAR_RADIANCE out_specular_direct_atrous
#endif

layout(set = 0, binding = 2, rgba16f) uniform writeonly image2D OUTPUT_DIFFUSE_RADIANCE;
layout(set = 0, binding = 3, rgba16f) uniform writeonly image2D OUTPUT_SPECULAR_RADIANCE;
layout(set = 0, binding = 4, rgba16f) uniform readonly image2D diffuse_atrous_variance;
layout(set = 0, binding = 5, rgba16f) uniform readonly image2D specular_atrous_variance;
layout(set = 0, binding = 6, rgba32f) uniform readonly image2D position_t;
layout(set = 0, binding = 7, rgba16f) uniform readonly image2D normals_gs;
layout(set = 0, binding = 8, rgba8) uniform readonly image2D material_rmxx;
layout(set = 0, binding = 9, rgba16f) uniform readonly image2D asvgf_shadow_mask_normalized;
#endif

layout(set = 0, binding = 10) uniform UBO { UniformBuffer ubo; } ubo;

float safeLum(vec3 c) { return max(luminance(c), 1e-4); }

float spatialKernelWeight(ivec2 k, float kernelFlatten)
{
#if ATROUS_USE_HONEST_KERNEL && ATROUS_KERNEL_RADIUS == 2
	float wx = KERNEL5_1D[k.x + 2];
	float wy = KERNEL5_1D[k.y + 2];
	float base = wx * wy;
#else
	float dist2 = dot(vec2(k), vec2(k));
	float base = 1.0 / (1.0 + 0.35 * dist2);
#endif
	return mix(base, 1.0, kernelFlatten);
}

float wNormalThreshold(vec3 a, vec3 b, float dotThreshold, float relax)
{
	float diff = max(0.0, dot(a, b));
	return mix(diff, smoothstep(0.98, 1.0, diff), 0.98);
	// float nd = max(dot(a, b), 0.0);
	// float soft = ATROUS_NORMAL_GATE_SOFTNESS * max(relax, 1.0);
	// float t0 = clamp(dotThreshold - soft, 0.0, 1.0);
	// float t1 = clamp(dotThreshold + soft * 0.5, t0 + 1e-4, 1.0);
	// float w = smoothstep(t0, t1, nd);
	// return mix(ATROUS_NORMAL_GATE_MIN_WEIGHT, 1.0, w);
}

float wPositionGate(vec3 d, vec3 geomNorm, float invCenterDist, float planeThreshold, float worldTexelSize)
{
	return positionEdgeStopWithWorldTexel(d, geomNorm, invCenterDist, planeThreshold, worldTexelSize);
}

float wRoughness(float a, float b, float relax)
{
	return step(abs(a - b), ROUGHNESS_DIFF_THRESHOLD * relax);
}

float wMask(float centerMask, float sampleMask)
{
	float dm = abs(sampleMask - centerMask);
	float t = (dm - DIFFUSE_MASK_DIFF_MIN) / max(DIFFUSE_MASK_DIFF_MAX - DIFFUSE_MASK_DIFF_MIN, 1e-4);
	float rawW = 1.0 - clamp(t, 0.0, 1.0);
	return mix(1.0, rawW, clamp(DIFFUSE_MASK_GATE_STRENGTH, 0.0, 1.0));
}

float wLuminance(float lumCenter, float lumSample, float varianceCenter, int gateEnable, float thrMin, float thrHalfVar, float softnessMult, float relEps, float blend)
{
	if (gateEnable == 0) {
		return 1.0;
	}

	float nv = clamp(varianceCenter, 0.0, 1.0);
	float thr = mix(thrMin, thrHalfVar, nv);
	float thrSoft = max(thr * softnessMult, thr + 1e-4);
	float lmax = max(max(lumCenter, lumSample), relEps);
	float d = abs(lumSample - lumCenter) / lmax;
	float t = (d - thr) / max(thrSoft - thr, 1e-4);
	float w = 1.0 - clamp(t, 0.0, 1.0);
	w = mix(1.0, w, blend);
	return clamp(w, 0.0, 1.0);
}

#ifdef VARIANCE_PASS
void main()
{
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
	if (any(greaterThanEqual(p, res))) return;

#if ATROUS_WITHOUT_VARIANCE
	imageStore(out_diffuse_atrous_variance, p, vec4(1.0));
	imageStore(out_specular_atrous_variance, p, vec4(1.0));
	return;
#else
	if (DENOISER_ENABLE_ATROUS == 0) {
		imageStore(out_diffuse_atrous_variance, p, vec4(1.0));
		imageStore(out_specular_atrous_variance, p, vec4(1.0));
		return;
	}

	vec3 centerDiffuse = imageLoad(IN_DIFFUSE_RADIANCE, p).rgb;
	vec3 centerSpecular = imageLoad(IN_SPECULAR_RADIANCE, p).rgb;

	bool blackDiffuse = luminance(max(centerDiffuse, vec3(0.0))) <= ATROUS_BLACK_LUMA_THRESHOLD;
	bool blackSpecular = luminance(max(centerSpecular, vec3(0.0))) <= ATROUS_BLACK_LUMA_THRESHOLD;
	if (blackDiffuse && blackSpecular) {
		imageStore(out_diffuse_atrous_variance, p, vec4(1.0));
		imageStore(out_specular_atrous_variance, p, vec4(1.0));
		return;
	}

	float m1Diffuse = 0.0;
	float m2Diffuse = 0.0;
	float m1Specular = 0.0;
	float m2Specular = 0.0;
	float w = 0.0;

	for (int y = -VARIANCE_RADIUS; y <= VARIANCE_RADIUS; y++) {
		for (int x = -VARIANCE_RADIUS; x <= VARIANCE_RADIUS; x++) {
			ivec2 q = clamp(p + ivec2(x, y), ivec2(0), res - 1);
			float ld = safeLum(imageLoad(IN_DIFFUSE_RADIANCE, q).rgb);
			float ls = safeLum(imageLoad(IN_SPECULAR_RADIANCE, q).rgb);
			m1Diffuse += ld;
			m2Diffuse += ld * ld;
			m1Specular += ls;
			m2Specular += ls * ls;
			w += 1.0;
		}
	}

	m1Diffuse /= w;
	m2Diffuse /= w;
	m1Specular /= w;
	m2Specular /= w;

	float varianceDiffuse = max(m2Diffuse - m1Diffuse * m1Diffuse, 0.0);
	varianceDiffuse /= max(m1Diffuse * m1Diffuse, 1e-3);
	varianceDiffuse = clamp(varianceDiffuse, 0.0, 1.0);

	float varianceSpecular = max(m2Specular - m1Specular * m1Specular, 0.0);
	varianceSpecular /= max(m1Specular * m1Specular, 1e-3);
	varianceSpecular = clamp(varianceSpecular, 0.0, 1.0);

	imageStore(out_diffuse_atrous_variance, p, vec4(varianceDiffuse));
	imageStore(out_specular_atrous_variance, p, vec4(varianceSpecular));
#endif
}
#else
void main()
{
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
	if (any(greaterThanEqual(p, res))) return;

	vec3 centerDiffuse = imageLoad(IN_DIFFUSE_RADIANCE, p).rgb;
	vec3 centerSpecular = imageLoad(IN_SPECULAR_RADIANCE, p).rgb;

	bool doDiffuse = (DENOISER_ENABLE_ATROUS != 0) && (ATROUS_STEP <= DIFFUSE_MAX_STEP);
	bool doSpecular = (DENOISER_ENABLE_ATROUS != 0) && (ATROUS_STEP <= SPECULAR_MAX_STEP);

	if (!doDiffuse) {
		imageStore(OUTPUT_DIFFUSE_RADIANCE, p, vec4(centerDiffuse, 1.0));
	}
	if (!doSpecular) {
		imageStore(OUTPUT_SPECULAR_RADIANCE, p, vec4(centerSpecular, 1.0));
	}
	if (!doDiffuse && !doSpecular) {
		return;
	}

	vec4 normalsEncoded = imageLoad(normals_gs, p);
	vec3 geomNorm = normalDecode(normalsEncoded.xy);
	vec3 shadingNormCenter = normalDecode(normalsEncoded.zw);
	vec3 p0 = imageLoad(position_t, p).xyz;
#if ATROUS_WITHOUT_VARIANCE
	float varianceDiffuseCenter = 0.0;
	float varianceSpecularCenter = 0.0;
#else
	float varianceDiffuseCenter = imageLoad(diffuse_atrous_variance, p).r;
	float varianceSpecularCenter = imageLoad(specular_atrous_variance, p).r;
#endif
#if !ATROUS_WITHOUT_VARIANCE
	float lumDiffuseCenter = safeLum(centerDiffuse);
	float lumSpecularCenter = safeLum(centerSpecular);
#endif

#if ATROUS_WITHOUT_VARIANCE
	float nd = 0.0;
	float ns = 0.0;
#else
	float nd = clamp((varianceDiffuseCenter - VARIANCE_MIN) / (VARIANCE_MAX - VARIANCE_MIN), 0.0, 1.0);
	float ns = clamp((varianceSpecularCenter - VARIANCE_MIN) / (VARIANCE_MAX - VARIANCE_MIN), 0.0, 1.0);
#endif

#if AGGRESSIVE_DENOISE
	float relaxDiffuse = 1.0 + nd * VARIANCE_RELAX_EDGE;
	float relaxSpecular = 1.0 + ns * VARIANCE_RELAX_EDGE;
	float relaxCommon = max(relaxDiffuse, relaxSpecular);
	float flattenCommon = clamp(max(nd, ns) * VARIANCE_FLATTEN_KERNEL, 0.0, 1.0);
#else
	float relaxDiffuse = 1.0;
	float relaxSpecular = 1.0;
	float relaxCommon = 1.0;
	float flattenCommon = 0.0;
#endif

	float stepScale = float(ATROUS_STEP);
	float gateStepScale = mix(1.0, stepScale, clamp(ATROUS_POSITION_STEP_GROWTH, 0.0, 1.0));
	float kernelRadiusScale = float(max(ATROUS_KERNEL_RADIUS, 1));
	float maxSampleRadiusScale = kernelRadiusScale * max(stepScale, 1.0);
	float invCenterDist = 1.0 / max(length(p0), 1.0);
	vec3 camPos = (ubo.ubo.inv_view * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float worldTexelSize = estimateWorldTexelSizeFromCenter(
		p, res, camPos, p0, ubo.ubo.inv_proj, ubo.ubo.inv_view, DENOISER_POSITION_TEXEL_SIZE_MARGIN * gateStepScale);
	float planeThresholdCommon = DENOISER_POSITION_PLANE_THRESHOLD * gateStepScale * relaxCommon;
	float worldTexelThresholdCommon = worldTexelSize * maxSampleRadiusScale * relaxCommon;

	float centerMask = imageLoad(asvgf_shadow_mask_normalized, p)[DIFFUSE_MASK_CHANNEL];
	float roughnessCenter = doSpecular ? imageLoad(material_rmxx, p).x : 0.0;

	vec3 sumDiffuse = vec3(0.0);
	float sumWeightDiffuse = 0.0;
	vec3 sumSpecular = vec3(0.0);
	float sumWeightSpecular = 0.0;

	for (int oy = -ATROUS_KERNEL_RADIUS; oy <= ATROUS_KERNEL_RADIUS; oy++) {
		for (int ox = -ATROUS_KERNEL_RADIUS; ox <= ATROUS_KERNEL_RADIUS; ox++) {
			ivec2 k = ivec2(ox, oy);
			ivec2 q = clamp(p + k * ATROUS_STEP, ivec2(0), res - 1);

			vec4 normalsQ = imageLoad(normals_gs, q);
			vec3 shadingNormQ = normalDecode(normalsQ.zw);
			float wShading = wNormalThreshold(shadingNormCenter, shadingNormQ, COMMON_SHADING_NORMAL_DOT_THRESHOLD, relaxCommon);
			if (wShading <= 1e-4) {
				continue;
			}

			vec3 p1 = imageLoad(position_t, q).xyz;
			float wPos = wPositionGate(p1 - p0, geomNorm, invCenterDist, planeThresholdCommon, worldTexelThresholdCommon);
			if (wPos <= 0.0) {
				continue;
			}

			float spatialW = spatialKernelWeight(k, flattenCommon);
			float sampleMask = imageLoad(asvgf_shadow_mask_normalized, q)[DIFFUSE_MASK_CHANNEL];
			float wMaskV = wMask(centerMask, sampleMask);
			float baseCommon = spatialW * wShading * wPos;

			if (doDiffuse) {
				float baseW = baseCommon * wMaskV;
				vec3 c = imageLoad(IN_DIFFUSE_RADIANCE, q).rgb;
#if ATROUS_WITHOUT_VARIANCE
				float wL = 1.0;
#else
				float l1 = safeLum(c);
				float wL = wLuminance(lumDiffuseCenter, l1, varianceDiffuseCenter, DIFFUSE_LUMA_GATE_ENABLE, DIFFUSE_LUMA_THR_MIN, DIFFUSE_LUMA_THR_AT_HALF_VAR, DIFFUSE_LUMA_SOFTNESS_MULT, DIFFUSE_LUMA_REL_EPS, DIFFUSE_LUMA_BLEND);
#endif
				float w = baseW * wL;
				sumDiffuse += c * w;
				sumWeightDiffuse += w;
			}

			if (doSpecular) {
				float roughnessQ = imageLoad(material_rmxx, q).x;
				float wRough = wRoughness(roughnessCenter, roughnessQ, relaxSpecular);
				if (wRough > 0.0) {
					float baseW = baseCommon * wMaskV * wRough;
					vec3 c = imageLoad(IN_SPECULAR_RADIANCE, q).rgb;
#if ATROUS_WITHOUT_VARIANCE
					float wL = 1.0;
#else
					float l1 = safeLum(c);
					float wL = wLuminance(lumSpecularCenter, l1, varianceSpecularCenter, SPECULAR_LUMA_GATE_ENABLE, SPECULAR_LUMA_THR_MIN, SPECULAR_LUMA_THR_AT_HALF_VAR, SPECULAR_LUMA_SOFTNESS_MULT, SPECULAR_LUMA_REL_EPS, SPECULAR_LUMA_BLEND);
#endif
					float w = baseW * wL;
					sumSpecular += c * w;
					sumWeightSpecular += w;
				}
			}
		}
	}

	if (doDiffuse) {
		vec3 outDiffuse = (sumWeightDiffuse > EPS) ? (sumDiffuse / sumWeightDiffuse) : centerDiffuse;
		imageStore(OUTPUT_DIFFUSE_RADIANCE, p, vec4(outDiffuse, 1.0));
	}
	if (doSpecular) {
		vec3 outSpecular = (sumWeightSpecular > EPS) ? (sumSpecular / sumWeightSpecular) : centerSpecular;
		imageStore(OUTPUT_SPECULAR_RADIANCE, p, vec4(outSpecular, 1.0));
	}
}
#endif





