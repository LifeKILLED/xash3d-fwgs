/* Shared REBLUR pass derived from NVIDIA NRD 4.18.
	* See ../../nrd_port/LICENSE.NVIDIA.txt and ../../nrd_port/LICENSE.MathLib.txt. */

layout(set=0,binding=1,rgba8) uniform readonly image2D TILES_IMAGE;
layout(set=0,binding=2,rgba16f) uniform readonly image2D NORMAL_IMAGE;
layout(set=0,binding=3,rgba32f) uniform readonly image2D TEMPORAL_DEPTH_IMAGE;
layout(set=0,binding=4,rgba8) uniform readonly image2D FRAME_COUNTS_IMAGE;
#if !NRD_REFLECTION
layout(set=0,binding=5,rgba16f) uniform readonly image2D HISTORY_FLAGS_IMAGE;
layout(set=0,binding=6,rgba16f) uniform readonly image2D TEMPORAL_HISTORY_IMAGE;
layout(set=0,binding=7,rgba16f) uniform readonly image2D PREV_TEMPORAL_STABILIZED_IMAGE;
layout(set=0,binding=8,rgba16f) uniform readonly image2D MOTION_IMAGE;
layout(set=0,binding=9,rgba32f) uniform writeonly image2D TEMPORAL_INTERNAL_OUTPUT_IMAGE;
layout(set=0,binding=10,rgba16f) uniform writeonly image2D WORK_OUTPUT_IMAGE;
layout(set=0,binding=11,rgba16f) uniform writeonly image2D TEMPORAL_STABILIZED_OUTPUT_IMAGE;
#else
layout(set=0,binding=5,rgba32f) uniform readonly image2D HISTORY_FLAGS_IMAGE;
layout(set=0,binding=6,rgba16f) uniform readonly image2D TEMPORAL_TRACKING_IMAGE;
layout(set=0,binding=7,rgba16f) uniform readonly image2D TEMPORAL_HISTORY_IMAGE;
layout(set=0,binding=8,rgba16f) uniform readonly image2D PREV_TEMPORAL_STABILIZED_IMAGE;
layout(set=0,binding=9,rgba16f) uniform readonly image2D MOTION_IMAGE;
layout(set=0,binding=10,rgba32f) uniform writeonly image2D TEMPORAL_INTERNAL_OUTPUT_IMAGE;
layout(set=0,binding=11,rgba16f) uniform writeonly image2D WORK_OUTPUT_IMAGE;
layout(set=0,binding=12,rgba16f) uniform writeonly image2D TEMPORAL_STABILIZED_OUTPUT_IMAGE;
#endif
layout(set=0,binding=31,rgba32f) uniform readonly image2D REBLUR_REPROJECTION_MAP_IMAGE;

vec4 reblurFetch_tiles(ivec2 p) {
	if(any(lessThan(p,ivec2(0))) || any(greaterThanEqual(p,reblurExtent()))) return vec4(0);
	return imageLoad(TILES_IMAGE,p);
}

vec4 reblurFetch_normal(ivec2 p) {
	if(any(lessThan(p,ivec2(0))) || any(greaterThanEqual(p,reblurExtent()))) return vec4(0);
	return imageLoad(NORMAL_IMAGE,p);
}

vec4 reblurFetch_temporal_depth(ivec2 p) {
	if(any(lessThan(p,ivec2(0))) || any(greaterThanEqual(p,reblurExtent()))) return vec4(0);
	return imageLoad(TEMPORAL_DEPTH_IMAGE,p);
}

vec4 reblurFetch_frame_counts(ivec2 p) {
	if(any(lessThan(p,ivec2(0))) || any(greaterThanEqual(p,reblurExtent()))) return vec4(0);
	return imageLoad(FRAME_COUNTS_IMAGE,p);
}

uvec4 reblurUintLoad_history_flags(ivec2 p) {
#if !NRD_REFLECTION
	vec4 v=imageLoad(HISTORY_FLAGS_IMAGE,p); return uvec4(uint(v.x),0u,0u,1u);
#else
	vec4 v=imageLoad(HISTORY_FLAGS_IMAGE,p); return uvec4(uint(v.x) | (uint(v.y) << 16u),0u,0u,1u);
#endif
}
uvec4 reblurFetch_history_flags(ivec2 p) {
	if(any(lessThan(p,ivec2(0))) || any(greaterThanEqual(p,reblurExtent()))) return uvec4(0);
	return reblurUintLoad_history_flags(p);
#if NRD_REFLECTION
}

vec4 reblurFetch_temporal_tracking(ivec2 p) {
	if(any(lessThan(p,ivec2(0))) || any(greaterThanEqual(p,reblurExtent()))) return vec4(0);
	return imageLoad(TEMPORAL_TRACKING_IMAGE,p);
#endif
}

vec4 reblurFetch_temporal_history(ivec2 p) {
	if(any(lessThan(p,ivec2(0))) || any(greaterThanEqual(p,reblurExtent()))) return vec4(0);
	return imageLoad(TEMPORAL_HISTORY_IMAGE,p);
}

vec4 reblurLinear_prev_temporal_stabilized(vec2 uv) {
	vec2 p=uv*vec2(reblurExtent())-0.5; ivec2 b=ivec2(floor(p)); vec2 f=fract(p);
	return mix(mix(imageLoad(PREV_TEMPORAL_STABILIZED_IMAGE,clamp(b,ivec2(0),reblurExtent()-1)),imageLoad(PREV_TEMPORAL_STABILIZED_IMAGE,clamp(b+ivec2(1,0),ivec2(0),reblurExtent()-1)),f.x),
	mix(imageLoad(PREV_TEMPORAL_STABILIZED_IMAGE,clamp(b+ivec2(0,1),ivec2(0),reblurExtent()-1)),imageLoad(PREV_TEMPORAL_STABILIZED_IMAGE,clamp(b+ivec2(1,1),ivec2(0),reblurExtent()-1)),f.x),f.y);
}

void reblurStore_out_temporal_internal(ivec2 p,uvec4 v) { imageStore(TEMPORAL_INTERNAL_OUTPUT_IMAGE,p,vec4(float(v.x & 65535u),0.0,0.0,1.0)); }
void reblurStore_out_work(ivec2 p,vec4 v) { imageStore(WORK_OUTPUT_IMAGE,p,v); }
void reblurStore_out_temporal_stabilized(ivec2 p,vec4 v) { imageStore(TEMPORAL_STABILIZED_OUTPUT_IMAGE,p,vec4(v.x,0.0,0.0,1.0)); }
layout(local_size_x = 8, local_size_y = 16, local_size_z = 1) in;

vec3 unusedPositionPadding;
#if NRD_REFLECTION
vec3 unusedVirtualPadding;
#endif

#if !NRD_REFLECTION
shared float s_DiffLuma[18][10];
#else
shared float s_SpecLuma[18][10];
#endif

spirv_instruction(set = "GLSL.std.450", id = 79) float spvNMin(float, float);
spirv_instruction(set = "GLSL.std.450", id = 79) vec2 spvNMin(vec2, vec2);
spirv_instruction(set = "GLSL.std.450", id = 79) vec3 spvNMin(vec3, vec3);
spirv_instruction(set = "GLSL.std.450", id = 79) vec4 spvNMin(vec4, vec4);
spirv_instruction(set = "GLSL.std.450", id = 80) float spvNMax(float, float);
spirv_instruction(set = "GLSL.std.450", id = 80) vec2 spvNMax(vec2, vec2);
spirv_instruction(set = "GLSL.std.450", id = 80) vec3 spvNMax(vec3, vec3);
spirv_instruction(set = "GLSL.std.450", id = 80) vec4 spvNMax(vec4, vec4);
#if NRD_REFLECTION

#include "reblur_filter_math.glsl"
#endif

void main() {
	if (!reblurEnabled()) return;
	if (any(greaterThanEqual(gl_WorkGroupID.xy, ubo.ubo.reblur_groups_8x8_8x16[REBLUR_SIGNAL].zw))) return;
	do {
		ivec2 pix = ivec2((((((uvec2(ubo.ubo.reblur_rect_size[REBLUR_SIGNAL].xy) + uvec2(7u, 15u)) / uvec2(8u, 16u)) - uvec2(1u)) - gl_WorkGroupID.xy) * uvec2(8u, 16u)) + uvec2(ivec3(gl_LocalInvocationID).xy));
		vec4 tileClassification = reblurFetch_tiles(ivec2(uvec2(pix >> ivec2(4))));
		float tileIsSky = tileClassification.x;
		if (tileIsSky == 0.0) {
			uvec2 sharedPixelOrigin = uvec2((pix - ivec3(gl_LocalInvocationID).xy) - ivec2(1));
			for (uint sharedIndex = gl_LocalInvocationIndex; sharedIndex < 180u; sharedIndex += 128u) {
				uint sharedX = sharedIndex % 10u;
				uint sharedY = sharedIndex / 10u;
				uvec2 sharedPixel = uvec2(clamp(ivec2(sharedPixelOrigin + uvec2(sharedX, sharedY)), ivec2(0), ubo.ubo.reblur_rect_size_minus_one[REBLUR_SIGNAL].xy));
#if !NRD_REFLECTION
				s_DiffLuma[sharedY][sharedX] = (!(abs(reblurFetch_temporal_depth(ivec2(sharedPixel)).x * ubo.ubo.reblur_view_z_scale[REBLUR_SIGNAL]) < ubo.ubo.reblur_denoising_range[REBLUR_SIGNAL])) ? (-32768.0) : reblurFetch_temporal_history(ivec2(sharedPixel)).x;
#else
				s_SpecLuma[sharedY][sharedX] = (!(abs(reblurFetch_temporal_depth(ivec2(sharedPixel)).x * ubo.ubo.reblur_view_z_scale[REBLUR_SIGNAL]) < ubo.ubo.reblur_denoising_range[REBLUR_SIGNAL])) ? (-32768.0) : reblurFetch_temporal_history(ivec2(sharedPixel)).x;
#endif
			}
		}
		barrier();
		bool skipPixel;
		if (!(tileIsSky != 0.0)) {
			skipPixel = any(greaterThan(pix, ubo.ubo.reblur_rect_size_minus_one[REBLUR_SIGNAL].xy));
		} else {
			skipPixel = true;
		}
		if (skipPixel) {
			break;
		}
		uvec2 out_pix = uvec2(pix);
		float viewDepth = abs(reblurFetch_temporal_depth(ivec2(out_pix)).x * ubo.ubo.reblur_view_z_scale[REBLUR_SIGNAL]);
		if (!(viewDepth < ubo.ubo.reblur_denoising_range[REBLUR_SIGNAL])) {
			break;
		}
		vec2 pixelUv = (vec2(pix) + vec2(0.5)) * ubo.ubo.reblur_rect_size_inv[REBLUR_SIGNAL].xy;
		vec2 surfaceMotionUv;
		bool asvgfHistoryValid = false;
		vec2 asvgfDonor = vec2(0.0); {
#if !NRD_REFLECTION
			vec2 encodedDonor = imageLoad(REBLUR_REPROJECTION_MAP_IMAGE,ivec2(out_pix)).rg;
#else
			vec2 encodedDonor = imageLoad(REBLUR_REPROJECTION_MAP_IMAGE,ivec2(out_pix)).ba;
#endif
			asvgfHistoryValid = all(greaterThan(encodedDonor, vec2(0.0))) &&
				ubo.ubo.reblur_reset_history[REBLUR_SIGNAL] == 0u;
			asvgfDonor = asvgfHistoryValid ? encodedDonor - 1.0 : vec2(0.0);
			surfaceMotionUv = (asvgfDonor + 0.5) * ubo.ubo.reblur_rect_size_inv[REBLUR_SIGNAL].xy;
		}
#if !NRD_REFLECTION
		vec2 accumulatedFrameCounts = roundEven(reblurFetch_frame_counts(ivec2(out_pix)).xy * 63.0);
		uvec4 packedReprojectionData = reblurFetch_history_flags(ivec2(out_pix));
		uint reprojectionBits = packedReprojectionData.x;
		vec2 bilinearFraction = vec2(0.0);
		vec4 historyTapValidity = vec4(notEqual((uvec4(reprojectionBits & 255u) & uvec4(1u, 2u, 4u, 8u)), uvec4(0u)));
		float validTopLeft = historyTapValidity.x;
		float rightWeight = bilinearFraction.x;
		float validTopRight = historyTapValidity.y;
		float bottomWeight = bilinearFraction.y;
		float validBottomLeft = historyTapValidity.z;
		float validBottomRight = historyTapValidity.w;
		float footprintQuality = sqrt(clamp(mix(mix(validTopLeft, validTopRight, rightWeight), mix(validBottomLeft, validBottomRight, rightWeight), bottomWeight), 0.0, 1.0));
#else
		vec4 packedNormalRoughness = reblurFetch_normal(ivec2(out_pix));
		float signedRoughness = (packedNormalRoughness.z * 2.0) - 1.0;
		float roughness = abs(signedRoughness);
		float normalizedMaterialId = packedNormalRoughness.w;
		float materialId = normalizedMaterialId * 3.0;
		vec4 packedAccumulationData = reblurFetch_frame_counts(ivec2(out_pix));
		vec2 accumulationChannels = packedAccumulationData.xy;
		accumulationChannels.y = packedAccumulationData.x;
		vec2 accumulatedFrames = roundEven(accumulationChannels * 63.0);
#endif
		ivec2 sharedCenterPixel = ivec3(gl_LocalInvocationID).xy + ivec2(1);
		int sharedCenterY = sharedCenterPixel.y;
		int sharedCenterX = sharedCenterPixel.x;
		float secondMomentSum;
		float firstMomentSum;
#if !NRD_REFLECTION
		secondMomentSum = s_DiffLuma[sharedCenterY][sharedCenterX] * s_DiffLuma[sharedCenterY][sharedCenterX];
		firstMomentSum = s_DiffLuma[sharedCenterY][sharedCenterX];
#else
		secondMomentSum = s_SpecLuma[sharedCenterY][sharedCenterX] * s_SpecLuma[sharedCenterY][sharedCenterX];
		firstMomentSum = s_SpecLuma[sharedCenterY][sharedCenterX];
#endif
		float secondMomentRow;
		float firstMomentRow;
		SPIRV_CROSS_UNROLL
		for (int neighborIndex = 0; neighborIndex <= 2; secondMomentSum = secondMomentRow, firstMomentSum = firstMomentRow, neighborIndex++) {
			secondMomentRow = secondMomentSum;
			firstMomentRow = firstMomentSum;
			float secondMomentNext;
			float firstMomentNext;
			SPIRV_CROSS_UNROLL
			for (int neighborIndex2 = 0; neighborIndex2 <= 2; secondMomentRow = secondMomentNext, firstMomentRow = firstMomentNext, neighborIndex2++) {
				bool isCenterTap;
				if (neighborIndex2 == 1) {
					isCenterTap = neighborIndex == 1;
				} else {
					isCenterTap = false;
				}
				if (isCenterTap) {
					secondMomentNext = secondMomentRow;
					firstMomentNext = firstMomentRow;
					continue;
				}
				ivec2 statisticsPixel = ivec3(gl_LocalInvocationID).xy + ivec2(neighborIndex2, neighborIndex);
				int statisticsY = statisticsPixel.y;
				int statisticsX = statisticsPixel.x;
#if !NRD_REFLECTION
				float neighborLuminance = (s_DiffLuma[statisticsY][statisticsX] == (-32768.0)) ? s_DiffLuma[sharedCenterY][sharedCenterX] : s_DiffLuma[statisticsY][statisticsX];
#else
				float neighborLuminance = (s_SpecLuma[statisticsY][statisticsX] == (-32768.0)) ? s_SpecLuma[sharedCenterY][sharedCenterX] : s_SpecLuma[statisticsY][statisticsX];
#endif
				secondMomentNext = secondMomentRow + (neighborLuminance * neighborLuminance);
				firstMomentNext = firstMomentRow + neighborLuminance;
			}
		}
		float meanLuminance = firstMomentSum * 0.111111111938953399658203125;
		float sigma = sqrt(abs((secondMomentSum * 0.111111111938953399658203125) - (meanLuminance * meanLuminance)));
#if !NRD_REFLECTION
		float accumulatedFrames = accumulatedFrameCounts.x;
#else
		float specularFrameCount = accumulatedFrames.y;
#endif
		float currentLuminance;
#if !NRD_REFLECTION
		if (accumulatedFrames < ubo.ubo.reblur_history_fix_frame_num[REBLUR_SIGNAL]) {
			currentLuminance = spvNMin(s_DiffLuma[sharedCenterY][sharedCenterX], meanLuminance * (1.2000000476837158203125 + (1.0 / (1.0 + accumulatedFrames))));
#else
		if (specularFrameCount < ubo.ubo.reblur_history_fix_frame_num[REBLUR_SIGNAL]) {
			currentLuminance = spvNMin(s_SpecLuma[sharedCenterY][sharedCenterX], meanLuminance * (1.2000000476837158203125 + (1.0 / (1.0 + specularFrameCount))));
#endif
		} else {
#if !NRD_REFLECTION
			currentLuminance = s_DiffLuma[sharedCenterY][sharedCenterX];
#else
			currentLuminance = s_SpecLuma[sharedCenterY][sharedCenterX];
#endif
		}
		float sampledHistoryLuminance = asvgfHistoryValid ? imageLoad(PREV_TEMPORAL_STABILIZED_IMAGE,ivec2(asvgfDonor)).x : 0.0;
		float historyLuminance = spvNMax(sampledHistoryLuminance, 0.0);
#if NRD_REFLECTION
		float footprintQuality = float(asvgfHistoryValid);
#endif
		float antilagSigmaRange = sigma * ubo.ubo.reblur_antilag_settings[REBLUR_SIGNAL].xy.x;
		float antilagFrameRateScale = 2.0 * ubo.ubo.reblur_frame_rate_scale_smoothed[REBLUR_SIGNAL];
		float clampedHistoryLuminance = clamp(historyLuminance, meanLuminance - antilagSigmaRange, meanLuminance + antilagSigmaRange);
#if !NRD_REFLECTION
		float antilagConfidence = 1.0 / (1.0 + (((abs(historyLuminance - clampedHistoryLuminance) / (spvNMax(historyLuminance, clampedHistoryLuminance) + 9.9999999747524270787835121154785e-07)) * (footprintQuality * accumulatedFrames)) / ((ubo.ubo.reblur_antilag_settings[REBLUR_SIGNAL].xy.y * antilagFrameRateScale) * antilagFrameRateScale)));
		float adjustedFrameCount = mix(spvNMin(accumulatedFrames, ubo.ubo.reblur_history_fix_frame_num[REBLUR_SIGNAL]), accumulatedFrames, antilagConfidence);
#else
		float antilagConfidence = 1.0 / (1.0 + (((abs(historyLuminance - clampedHistoryLuminance) / (spvNMax(historyLuminance, clampedHistoryLuminance) + 9.9999999747524270787835121154785e-07)) * (footprintQuality * specularFrameCount)) / ((ubo.ubo.reblur_antilag_settings[REBLUR_SIGNAL].xy.y * antilagFrameRateScale) * antilagFrameRateScale)));
		float adjustedFrameCount = mix(spvNMin(specularFrameCount, ubo.ubo.reblur_history_fix_frame_num[REBLUR_SIGNAL]), specularFrameCount, antilagConfidence);
#endif
		float historyWeight = (footprintQuality * (1.0 - (1.0 / (1.0 + ((ubo.ubo.reblur_convergence_settings[REBLUR_SIGNAL].x * mix(ubo.ubo.reblur_convergence_settings[REBLUR_SIGNAL].y, 1.0, clamp(adjustedFrameCount / (1.0 + (ubo.ubo.reblur_max_accumulated_frame_num[REBLUR_SIGNAL] * ubo.ubo.reblur_convergence_settings[REBLUR_SIGNAL].z)), 0.0, 1.0))) * adjustedFrameCount))))) * antilagConfidence;
#if NRD_REFLECTION
		float stableFrameCountSample = float(surfaceMotionUv.x >= ubo.ubo.reblur_split_screen_prev[REBLUR_SIGNAL]);
		float responsiveRoughness = clamp(spvNMax(roughness, 0.001000000047497451305389404296875) * ubo.ubo.reblur_responsive_accumulation_inv_roughness_threshold[REBLUR_SIGNAL], 0.0, 1.0);
		float responsiveHistoryScale = mix((1.0 - exp2(((-200.0) * roughness) * roughness)) * pow(clamp(roughness, 0.0, 1.0), 0.25), 1.0, 0.5 + (((responsiveRoughness * responsiveRoughness) * (3.0 - (responsiveRoughness * 2.0))) * 0.5));
		float outputStableFrameCount;
		if (materialId == ubo.ubo.reblur_strand_material_id[REBLUR_SIGNAL]) {
			outputStableFrameCount = spvNMin(responsiveHistoryScale, 0.5);
		} else {
			outputStableFrameCount = responsiveHistoryScale;
		}
#endif
		float stabilizationSigmaRange = sigma * (1.0 + ((historyWeight * 6.0) * ubo.ubo.reblur_frame_rate_scale_smoothed[REBLUR_SIGNAL]));
#if !NRD_REFLECTION
		float stabilizedLuminance = mix(currentLuminance, clamp(historyLuminance, meanLuminance - stabilizationSigmaRange, meanLuminance + stabilizationSigmaRange), spvNMin((historyWeight * float(pixelUv.x >= ubo.ubo.reblur_split_screen[REBLUR_SIGNAL])) * float(surfaceMotionUv.x >= ubo.ubo.reblur_split_screen_prev[REBLUR_SIGNAL]), ubo.ubo.reblur_stabilization_strength[REBLUR_SIGNAL]));
#else
		float stabilizedLuminance = mix(currentLuminance, clamp(historyLuminance, meanLuminance - stabilizationSigmaRange, meanLuminance + stabilizationSigmaRange), spvNMin((((historyWeight * float(pixelUv.x >= ubo.ubo.reblur_split_screen[REBLUR_SIGNAL])) * stableFrameCountSample)) * outputStableFrameCount, ubo.ubo.reblur_stabilization_strength[REBLUR_SIGNAL]));
#endif
		vec4 historyRadiance = reblurFetch_temporal_history(ivec2(out_pix));
		vec3 scaledRadianceYCoCg = historyRadiance.xyz * (stabilizedLuminance / spvNMax(historyRadiance.x, 9.9999999747524270787835121154785e-07));
		vec4 outputRadianceAndHitDistance = vec4(scaledRadianceYCoCg.x, scaledRadianceYCoCg.y, scaledRadianceYCoCg.z, historyRadiance.w);
		float outputHitDistance;
		if (ubo.ubo.reblur_return_history_length_instead_of_occlusion[REBLUR_SIGNAL] != 0u) {
			outputHitDistance = adjustedFrameCount;
		} else {
			outputHitDistance = historyRadiance.w;
		}
		outputRadianceAndHitDistance.w = outputHitDistance;
		reblurStore_out_work(ivec2(out_pix),outputRadianceAndHitDistance);
		reblurStore_out_temporal_stabilized(ivec2(out_pix),vec4(stabilizedLuminance));
#if !NRD_REFLECTION
		uvec4 packedHistoryChannels = uvec4((clamp(vec3(roundEven(spvNMin(adjustedFrameCount + 1.0, ubo.ubo.reblur_max_accumulated_frame_num[REBLUR_SIGNAL])) * 0.01587301678955554962158203125, roundEven(spvNMin(accumulatedFrameCounts.y + 1.0, ubo.ubo.reblur_max_accumulated_frame_num[REBLUR_SIGNAL])) * 0.01587301678955554962158203125, reblurFetch_normal(ivec2(out_pix)).w * 0.2000000178813934326171875).xyzz, vec4(0.0), vec4(1.0)) * vec4(63.0, 63.0, 15.0, 0.0)) + vec4(0.5));
#else
		uvec4 packedHistoryChannels = uvec4((clamp(vec3(roundEven(spvNMin(accumulatedFrames.x + 1.0, ubo.ubo.reblur_max_accumulated_frame_num[REBLUR_SIGNAL])) * 0.01587301678955554962158203125, roundEven(spvNMin(adjustedFrameCount + 1.0, ubo.ubo.reblur_max_accumulated_frame_num[REBLUR_SIGNAL])) * 0.01587301678955554962158203125, normalizedMaterialId * 0.2000000178813934326171875).xyzz, vec4(0.0), vec4(1.0)) * vec4(63.0, 63.0, 15.0, 0.0)) + vec4(0.5));
#endif
		uvec3 shiftedHistoryChannels = packedHistoryChannels.yzw << uvec3(6u, 12u, 16u);
		uvec2 combinedHistoryChannels = uvec4(packedHistoryChannels.x, shiftedHistoryChannels.x, shiftedHistoryChannels.y, shiftedHistoryChannels.z).xy | shiftedHistoryChannels.yz;
		reblurStore_out_temporal_internal(ivec2(out_pix),uvec4(combinedHistoryChannels.x | combinedHistoryChannels.y));
		break;
	} while(false);
}
