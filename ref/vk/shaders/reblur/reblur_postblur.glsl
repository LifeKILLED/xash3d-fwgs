/* Shared REBLUR pass derived from NVIDIA NRD 4.18.
	* See ../../nrd_port/LICENSE.NVIDIA.txt and ../../nrd_port/LICENSE.MathLib.txt. */

layout(set=0,binding=1,rgba8) uniform readonly image2D TILES_IMAGE;
layout(set=0,binding=2,rgba16f) uniform readonly image2D NORMAL_IMAGE;
layout(set=0,binding=3,rgba8) uniform readonly image2D FRAME_COUNTS_IMAGE;
layout(set=0,binding=4,rgba32f) uniform readonly image2D TEMPORAL_DEPTH_IMAGE;
layout(set=0,binding=5,rgba16f) uniform readonly image2D RADIANCE_IMAGE;
layout(set=0,binding=6,rgba16f) uniform writeonly image2D TEMPORAL_NORMAL_OUTPUT_IMAGE;
layout(set=0,binding=7,rgba16f) uniform writeonly image2D TEMPORAL_HISTORY_OUTPUT_IMAGE;

vec4 reblurFetch_tiles(ivec2 p) {
	if(any(lessThan(p,ivec2(0))) || any(greaterThanEqual(p,reblurExtent()))) return vec4(0);
	return imageLoad(TILES_IMAGE,p);
}

vec4 reblurFetch_normal(ivec2 p) {
	if(any(lessThan(p,ivec2(0))) || any(greaterThanEqual(p,reblurExtent()))) return vec4(0);
	return imageLoad(NORMAL_IMAGE,p);
}

vec4 reblurFetch_frame_counts(ivec2 p) {
	if(any(lessThan(p,ivec2(0))) || any(greaterThanEqual(p,reblurExtent()))) return vec4(0);
	return imageLoad(FRAME_COUNTS_IMAGE,p);
}

vec4 reblurFetch_temporal_depth(ivec2 p) {
	if(any(lessThan(p,ivec2(0))) || any(greaterThanEqual(p,reblurExtent()))) return vec4(0);
	return imageLoad(TEMPORAL_DEPTH_IMAGE,p);
}

vec4 reblurFetch_radiance(ivec2 p) {
	if(any(lessThan(p,ivec2(0))) || any(greaterThanEqual(p,reblurExtent()))) return vec4(0);
	return imageLoad(RADIANCE_IMAGE,p);
}

void reblurStore_out_temporal_normal(ivec2 p,vec4 v) { imageStore(TEMPORAL_NORMAL_OUTPUT_IMAGE,p,v); }
void reblurStore_out_temporal_history(ivec2 p,vec4 v) { imageStore(TEMPORAL_HISTORY_OUTPUT_IMAGE,p,v); }
layout(local_size_x = 8, local_size_y = 16, local_size_z = 1) in;

vec3 unusedPositionPadding;
float unusedAccumulationPadding;

spirv_instruction(set = "GLSL.std.450", id = 79) float spvNMin(float, float);
spirv_instruction(set = "GLSL.std.450", id = 79) vec2 spvNMin(vec2, vec2);
spirv_instruction(set = "GLSL.std.450", id = 79) vec3 spvNMin(vec3, vec3);
spirv_instruction(set = "GLSL.std.450", id = 79) vec4 spvNMin(vec4, vec4);
spirv_instruction(set = "GLSL.std.450", id = 80) float spvNMax(float, float);
spirv_instruction(set = "GLSL.std.450", id = 80) vec2 spvNMax(vec2, vec2);
spirv_instruction(set = "GLSL.std.450", id = 80) vec3 spvNMax(vec3, vec3);
spirv_instruction(set = "GLSL.std.450", id = 80) vec4 spvNMax(vec4, vec4);

#include "reblur_filter_math.glsl"

void main() {
	if (!reblurEnabled()) return;
	if (any(greaterThanEqual(gl_WorkGroupID.xy, ubo.ubo.reblur_groups_8x8_8x16[REBLUR_SIGNAL].zw))) return;
	do {
		ivec2 pix = ivec2((((((uvec2(ubo.ubo.reblur_rect_size[REBLUR_SIGNAL].xy) + uvec2(7u, 15u)) / uvec2(8u, 16u)) - uvec2(1u)) - gl_WorkGroupID.xy) * uvec2(8u, 16u)) + uvec2(ivec3(gl_LocalInvocationID).xy));
		if (reblurFetch_tiles(ivec2(uvec2(pix >> ivec2(4)))).x != 0.0) {
			break;
		}
		uvec2 clampedPixel = uvec2(min(pix, ubo.ubo.reblur_rect_size_minus_one[REBLUR_SIGNAL].xy));
#if !NRD_REFLECTION
		vec2 accumulatedFrameCounts = roundEven(reblurFetch_frame_counts(ivec2(clampedPixel)).xy * 63.0);
		float accumulatedFrames = accumulatedFrameCounts.x;
#else
		vec4 packedAccumulationData = reblurFetch_frame_counts(ivec2(clampedPixel));
		vec2 accumulationChannels = packedAccumulationData.xy;
		accumulationChannels.y = packedAccumulationData.x;
		vec2 accumulatedFrames = roundEven(accumulationChannels * 63.0);
		float specularFrameCount = accumulatedFrames.y;
#endif
		float viewDepth = abs(reblurFetch_temporal_depth(ivec2(clampedPixel)).x * ubo.ubo.reblur_view_z_scale[REBLUR_SIGNAL]);
		bool outsideDenoisingRange = !(viewDepth < ubo.ubo.reblur_denoising_range[REBLUR_SIGNAL]);
#if !NRD_REFLECTION
		vec2 nonLinearAccumulationSpeed = mix(vec2(1.0 / (1.0 + ((ubo.ubo.reblur_convergence_settings[REBLUR_SIGNAL].x * mix(ubo.ubo.reblur_convergence_settings[REBLUR_SIGNAL].y, 1.0, clamp(accumulatedFrames / (1.0 + (ubo.ubo.reblur_max_accumulated_frame_num[REBLUR_SIGNAL] * ubo.ubo.reblur_convergence_settings[REBLUR_SIGNAL].z)), 0.0, 1.0))) * accumulatedFrames)), unusedAccumulationPadding), vec2(0.0), bvec2(outsideDenoisingRange));
#else
		vec2 nonLinearAccumulationSpeed = mix(vec2(unusedAccumulationPadding, 1.0 / (1.0 + ((ubo.ubo.reblur_convergence_settings[REBLUR_SIGNAL].x * mix(ubo.ubo.reblur_convergence_settings[REBLUR_SIGNAL].y, 1.0, clamp(specularFrameCount / (1.0 + (ubo.ubo.reblur_max_accumulated_frame_num[REBLUR_SIGNAL] * ubo.ubo.reblur_convergence_settings[REBLUR_SIGNAL].z)), 0.0, 1.0))) * specularFrameCount))), vec2(0.0), bvec2(outsideDenoisingRange));
#endif
		bool skipPixel;
		if (!outsideDenoisingRange) {
			skipPixel = any(greaterThan(pix, ubo.ubo.reblur_rect_size_minus_one[REBLUR_SIGNAL].xy));
		} else {
			skipPixel = true;
		}
		if (skipPixel) {
			break;
		}
		uvec2 out_pix = uvec2(pix);
		vec4 packedNormalRoughness = reblurFetch_normal(ivec2(out_pix));
#if NRD_REFLECTION
		float centerSignedRoughness = (packedNormalRoughness.z * 2.0) - 1.0;
		float roughness = abs(centerSignedRoughness);
#endif
		vec3 decodedNormal = reblurDecodeNormalUnnormalized(packedNormalRoughness);
		vec3 normalWorld = (reblurSafeNormalize(decodedNormal)).xyz;
		mat4 viewToWorld = transpose(transpose(reblurViewToWorld()));
		vec3 normalView = normalWorld * mat3(viewToWorld[0].xyz, viewToWorld[1].xyz, viewToWorld[2].xyz);
#if !NRD_REFLECTION
		vec2 pixelUv = (vec2(pix) + vec2(0.5)) * ubo.ubo.reblur_rect_size_inv[REBLUR_SIGNAL].xy;
#endif
		bool isPerspective = ubo.ubo.reblur_ortho_mode[REBLUR_SIGNAL] == 0.0;
#if !NRD_REFLECTION
		vec2 positionViewXY = ((pixelUv * ubo.ubo.reblur_frustum[REBLUR_SIGNAL].zw) + ubo.ubo.reblur_frustum[REBLUR_SIGNAL].xy).xy * (isPerspective ? viewDepth : ubo.ubo.reblur_ortho_mode[REBLUR_SIGNAL]);
#else
		vec2 positionViewXY = ((((vec2(pix) + vec2(0.5)) * ubo.ubo.reblur_rect_size_inv[REBLUR_SIGNAL].xy) * ubo.ubo.reblur_frustum[REBLUR_SIGNAL].zw) + ubo.ubo.reblur_frustum[REBLUR_SIGNAL].xy).xy * (isPerspective ? viewDepth : ubo.ubo.reblur_ortho_mode[REBLUR_SIGNAL]);
#endif
		vec3 positionView = vec3(positionViewXY.x, positionViewXY.y, unusedPositionPadding.z);
		positionView.z = viewDepth;
		vec3 viewDirection;
		if (isPerspective) {
			viewDirection = normalize(-positionView);
		} else {
			viewDirection = vec3(0.0, 0.0, -1.0);
		}
#if !NRD_REFLECTION
		float frustumSize = ubo.ubo.reblur_min_rect_dim_mul_unproject[REBLUR_SIGNAL] * mix(viewDepth, 1.0, abs(ubo.ubo.reblur_ortho_mode[REBLUR_SIGNAL]));
#else
		float projectionDepthScale = mix(viewDepth, 1.0, abs(ubo.ubo.reblur_ortho_mode[REBLUR_SIGNAL]));
		float frustumSize = ubo.ubo.reblur_min_rect_dim_mul_unproject[REBLUR_SIGNAL] * projectionDepthScale;
#endif
		reblurStore_out_temporal_normal(ivec2(out_pix),packedNormalRoughness);
		vec4 centerRadiance = reblurFetch_radiance(ivec2(out_pix));
#if NRD_REFLECTION
		float clampedRoughness = clamp(roughness, 0.0, 1.0);
		float dominantDirectionFit = 0.2984749972820281982421875 * log(39.4114990234375 - (39.002899169921875 * clampedRoughness));
		float dominantDirectionFactor = clamp((pow(clamp(1.0 - abs(dot(normalView, viewDirection)), 0.0, 1.0), 10.86489963531494140625) * (1.0 - dominantDirectionFit)) + dominantDirectionFit, 0.0, 1.0);
		vec3 dominantDirectionView = vec4(normalize(mix(normalView, reflect(-viewDirection, normalView), vec3(dominantDirectionFactor))), dominantDirectionFactor).xyz;
		float hitDistanceRoughnessFactor = (1.0 - exp2(((-200.0) * roughness) * roughness)) * pow(clampedRoughness, 0.5);
#endif
		float centerHitDistance = centerRadiance.w;
#if !NRD_REFLECTION
		float diffuseAccumulationSpeed = nonLinearAccumulationSpeed.x;
#else
		float normalizedHitDistanceToFrustum = clamp((centerHitDistance * ((ubo.ubo.reblur_hit_dist_settings[REBLUR_SIGNAL].x + (abs(viewDepth) * ubo.ubo.reblur_hit_dist_settings[REBLUR_SIGNAL].y)) * mix(ubo.ubo.reblur_hit_dist_settings[REBLUR_SIGNAL].z, 1.0, hitDistanceRoughnessFactor))) / frustumSize, 0.0, 1.0);
		float specularAccumulationSpeed = nonLinearAccumulationSpeed.y;
#endif
		float planeWeightScale = 1.0 / (ubo.ubo.reblur_plane_dist_sensitivity[REBLUR_SIGNAL] * frustumSize);
		float planeWeightBias = -(dot(normalView, positionView) * planeWeightScale);
#if !NRD_REFLECTION
		float lobeWeightFraction = clamp(0.75 * mix(clamp(ubo.ubo.reblur_lobe_angle_fraction[REBLUR_SIGNAL], 0.0, 1.0), 1.0, diffuseAccumulationSpeed), 0.0, 1.0);
		float normalWeightScale = 2.0 / spvNMax(atan(sqrt(lobeWeightFraction / (1.00000095367431640625 - lobeWeightFraction))), 0.00294117652811110019683837890625);
		float hitDistanceWeightScale = 1.0 / diffuseAccumulationSpeed;
#else
		float lobeWeightFraction = clamp(0.75 * mix(clamp(ubo.ubo.reblur_lobe_angle_fraction[REBLUR_SIGNAL], 0.0, 1.0), 1.0, specularAccumulationSpeed), 0.0, 1.0);
		float normalWeightScale = 2.0 / spvNMax(atan(clampedRoughness * sqrt(lobeWeightFraction / (1.00000095367431640625 - lobeWeightFraction))), 0.00294117652811110019683837890625);
		float roughnessWeightScale = 1.0 / mix(0.00999999977648258209228515625, 1.0, clamp(roughness * (ubo.ubo.reblur_roughness_fraction[REBLUR_SIGNAL] * 0.5), 0.0, 1.0));
		float roughnessWeightBias = -(roughness * roughnessWeightScale);
		float hitDistanceWeightScale = 1.0 / specularAccumulationSpeed;
#endif
		float hitDistanceWeightBias = -(centerHitDistance * hitDistanceWeightScale);
#if !NRD_REFLECTION
		float minHitDistanceWeight = (ubo.ubo.reblur_min_hit_distance_weight[REBLUR_SIGNAL] * 0.5) * diffuseAccumulationSpeed;
		vec2 foreshorteningScale = mix(vec2(1.0) - abs(normalView.xy), vec2(1.0), vec2(abs(dot(normalView, viewDirection))));
		vec2 blurRadiusUv = (foreshorteningScale / vec2(spvNMax(foreshorteningScale.x, foreshorteningScale.y))) * (ubo.ubo.reblur_rect_size_inv[REBLUR_SIGNAL].xy * spvNMax(clamp(2.0 * sqrt(clamp(clamp((centerHitDistance * (ubo.ubo.reblur_hit_dist_settings[REBLUR_SIGNAL].x + (abs(viewDepth) * ubo.ubo.reblur_hit_dist_settings[REBLUR_SIGNAL].y))) / frustumSize, 0.0, 1.0) * diffuseAccumulationSpeed, 0.0, 1.0)), 0.0, 1.0) * ubo.ubo.reblur_max_blur_radius[REBLUR_SIGNAL], ubo.ubo.reblur_min_blur_radius[REBLUR_SIGNAL]));
		vec4 scaledRotator = vec4(ubo.ubo.reblur_rotator_post[REBLUR_SIGNAL].xz * blurRadiusUv.x, ubo.ubo.reblur_rotator_post[REBLUR_SIGNAL].yw * blurRadiusUv.y);
		vec2 kernelAxisX = scaledRotator.xz;
		float centerMaterial = spvNMax(packedNormalRoughness.w * 3.0, ubo.ubo.reblur_diff_min_material[REBLUR_SIGNAL]);
		vec2 kernelUv0 = pixelUv + (kernelAxisX * (-1.0));
		vec2 kernelAxisY = scaledRotator.yw;
		vec2 kernelUv1 = pixelUv + (kernelAxisY * 1.0);
		vec2 kernelUv2 = pixelUv + (kernelAxisX * 1.0);
		vec2 kernelUv3 = pixelUv + (kernelAxisY * (-1.0));
		vec2 diagonalNegativeX = kernelAxisX * (-0.3535533845424652099609375);
		vec2 diagonalPositiveY = kernelAxisY * 0.3535533845424652099609375;
		vec2 kernelUv4 = pixelUv + (diagonalNegativeX + diagonalPositiveY);
		vec2 diagonalPositiveX = kernelAxisX * 0.3535533845424652099609375;
		vec2 kernelUv5 = pixelUv + (diagonalPositiveX + diagonalPositiveY);
		vec2 diagonalNegativeY = kernelAxisY * (-0.3535533845424652099609375);
		vec2 kernelUv6 = pixelUv + (diagonalPositiveX + diagonalNegativeY);
		vec2 kernelUv7 = pixelUv + (diagonalNegativeX + diagonalNegativeY);
#else
		float minHitDistanceWeight = ((ubo.ubo.reblur_min_hit_distance_weight[REBLUR_SIGNAL] * 0.5) * hitDistanceRoughnessFactor) * specularAccumulationSpeed;
		float hitDistanceBlend = sqrt(normalizedHitDistanceToFrustum);
		float kernelSkewFactor = mix(1.0, mix(mix(0.25 + (0.75 * roughness), 1.0, abs(dot(normalView, dominantDirectionView))), 1.0, specularAccumulationSpeed), hitDistanceBlend);
		vec3 kernelNormal = normalize(mix(normalView, dominantDirectionView, vec3(hitDistanceBlend)));
		float worldBlurRadius = (spvNMax((clamp(2.0 * sqrt(clamp(normalizedHitDistanceToFrustum * specularAccumulationSpeed, 0.0, 1.0)), 0.0, 1.0) * ubo.ubo.reblur_max_blur_radius[REBLUR_SIGNAL]) * hitDistanceRoughnessFactor, ubo.ubo.reblur_min_blur_radius[REBLUR_SIGNAL] * hitDistanceRoughnessFactor) * ubo.ubo.reblur_unproject[REBLUR_SIGNAL]) * projectionDepthScale;
		float normalZ = normalView.z;
		float normalZSign = (step(0.0, normalZ) * 2.0) - 1.0;
		float inverseBasisDenominator = 1.0 / (normalZSign + normalZ);
		float normalY = normalView.y;
		float scaledNormalY = normalY * inverseBasisDenominator;
		float normalX = normalView.x;
		float normalCrossTerm = normalX * scaledNormalY;
		float signedNormalX = normalX * normalZSign;
		vec3 kernelBitangent;
		vec3 kernelTangent;
		if (abs(dot(kernelNormal, normalView)) < 0.999000012874603271484375) {
			vec3 reflectedKernelNormal = reflect(-kernelNormal, normalView);
			vec3 kernelCrossAxis = normalize(cross(normalView, reflectedKernelNormal));
			kernelBitangent = cross(reflectedKernelNormal, kernelCrossAxis);
			kernelTangent = kernelCrossAxis;
		} else {
			kernelBitangent = vec3(normalCrossTerm, (normalY * scaledNormalY) - normalZSign, normalY);
			kernelTangent = vec3(((signedNormalX * normalX) * inverseBasisDenominator) - 1.0, normalZSign * normalCrossTerm, signedNormalX);
		}
		vec3 scaledKernelTangent = kernelTangent * (worldBlurRadius * kernelSkewFactor);
		vec3 scaledKernelBitangent = kernelBitangent * (worldBlurRadius / kernelSkewFactor);
		vec2 rotatedOffsetLeft = ubo.ubo.reblur_rotator_post[REBLUR_SIGNAL].xz * (-1.0);
		vec4 kernelClipLeft = vec4((positionView + (scaledKernelTangent * rotatedOffsetLeft.x)) + (scaledKernelBitangent * rotatedOffsetLeft.y), 1.0) * transpose(reblurProjection(false));
		vec2 kernelNdcLeft = kernelClipLeft.xy / vec2(kernelClipLeft.w);
		vec3 kernelScreenLeft = vec3(kernelNdcLeft.x, kernelNdcLeft.y, kernelClipLeft.w);
		kernelScreenLeft.y = -kernelNdcLeft.y;
		float centerMaterial = spvNMax(packedNormalRoughness.w * 3.0, ubo.ubo.reblur_spec_min_material[REBLUR_SIGNAL]);
		vec2 kernelUv0 = (kernelScreenLeft.xy * 0.5) + vec2(0.5);
		vec2 rotatedOffsetTop = ubo.ubo.reblur_rotator_post[REBLUR_SIGNAL].yw * 1.0;
		vec4 kernelClipTop = vec4((positionView + (scaledKernelTangent * rotatedOffsetTop.x)) + (scaledKernelBitangent * rotatedOffsetTop.y), 1.0) * transpose(reblurProjection(false));
		vec2 kernelNdcTop = kernelClipTop.xy / vec2(kernelClipTop.w);
		vec3 kernelScreenTop = vec3(kernelNdcTop.x, kernelNdcTop.y, kernelClipTop.w);
		kernelScreenTop.y = -kernelNdcTop.y;
		vec2 kernelUv1 = (kernelScreenTop.xy * 0.5) + vec2(0.5);
		vec2 rotatedOffsetRight = ubo.ubo.reblur_rotator_post[REBLUR_SIGNAL].xz * 1.0;
		vec4 kernelClipRight = vec4((positionView + (scaledKernelTangent * rotatedOffsetRight.x)) + (scaledKernelBitangent * rotatedOffsetRight.y), 1.0) * transpose(reblurProjection(false));
		vec2 kernelNdcRight = kernelClipRight.xy / vec2(kernelClipRight.w);
		vec3 kernelScreenRight = vec3(kernelNdcRight.x, kernelNdcRight.y, kernelClipRight.w);
		kernelScreenRight.y = -kernelNdcRight.y;
		vec2 kernelUv2 = (kernelScreenRight.xy * 0.5) + vec2(0.5);
		vec2 rotatedOffsetBottom = ubo.ubo.reblur_rotator_post[REBLUR_SIGNAL].yw * (-1.0);
		vec4 kernelClipBottom = vec4((positionView + (scaledKernelTangent * rotatedOffsetBottom.x)) + (scaledKernelBitangent * rotatedOffsetBottom.y), 1.0) * transpose(reblurProjection(false));
		vec2 kernelNdcBottom = kernelClipBottom.xy / vec2(kernelClipBottom.w);
		vec3 kernelScreenBottom = vec3(kernelNdcBottom.x, kernelNdcBottom.y, kernelClipBottom.w);
		kernelScreenBottom.y = -kernelNdcBottom.y;
		vec2 kernelUv3 = (kernelScreenBottom.xy * 0.5) + vec2(0.5);
		vec2 diagonalNegativeX = ubo.ubo.reblur_rotator_post[REBLUR_SIGNAL].xz * (-0.3535533845424652099609375);
		vec2 diagonalPositiveY = ubo.ubo.reblur_rotator_post[REBLUR_SIGNAL].yw * 0.3535533845424652099609375;
		vec2 rotatedOffsetTopLeft = diagonalNegativeX + diagonalPositiveY;
		vec4 kernelClipTopLeft = vec4((positionView + (scaledKernelTangent * rotatedOffsetTopLeft.x)) + (scaledKernelBitangent * rotatedOffsetTopLeft.y), 1.0) * transpose(reblurProjection(false));
		vec2 kernelNdcTopLeft = kernelClipTopLeft.xy / vec2(kernelClipTopLeft.w);
		vec3 kernelScreenTopLeft = vec3(kernelNdcTopLeft.x, kernelNdcTopLeft.y, kernelClipTopLeft.w);
		kernelScreenTopLeft.y = -kernelNdcTopLeft.y;
		vec2 kernelUv4 = (kernelScreenTopLeft.xy * 0.5) + vec2(0.5);
		vec2 diagonalPositiveX = ubo.ubo.reblur_rotator_post[REBLUR_SIGNAL].xz * 0.3535533845424652099609375;
		vec2 rotatedOffsetTopRight = diagonalPositiveX + diagonalPositiveY;
		vec4 kernelClipTopRight = vec4((positionView + (scaledKernelTangent * rotatedOffsetTopRight.x)) + (scaledKernelBitangent * rotatedOffsetTopRight.y), 1.0) * transpose(reblurProjection(false));
		vec2 kernelNdcTopRight = kernelClipTopRight.xy / vec2(kernelClipTopRight.w);
		vec3 kernelScreenTopRight = vec3(kernelNdcTopRight.x, kernelNdcTopRight.y, kernelClipTopRight.w);
		kernelScreenTopRight.y = -kernelNdcTopRight.y;
		vec2 kernelUv5 = (kernelScreenTopRight.xy * 0.5) + vec2(0.5);
		vec2 diagonalNegativeY = ubo.ubo.reblur_rotator_post[REBLUR_SIGNAL].yw * (-0.3535533845424652099609375);
		vec2 rotatedOffsetBottomRight = diagonalPositiveX + diagonalNegativeY;
		vec4 kernelClipBottomRight = vec4((positionView + (scaledKernelTangent * rotatedOffsetBottomRight.x)) + (scaledKernelBitangent * rotatedOffsetBottomRight.y), 1.0) * transpose(reblurProjection(false));
		vec2 kernelNdcBottomRight = kernelClipBottomRight.xy / vec2(kernelClipBottomRight.w);
		vec3 kernelScreenBottomRight = vec3(kernelNdcBottomRight.x, kernelNdcBottomRight.y, kernelClipBottomRight.w);
		kernelScreenBottomRight.y = -kernelNdcBottomRight.y;
		vec2 kernelUv6 = (kernelScreenBottomRight.xy * 0.5) + vec2(0.5);
		vec2 rotatedOffsetBottomLeft = diagonalNegativeX + diagonalNegativeY;
		vec4 kernelClipBottomLeft = vec4((positionView + (scaledKernelTangent * rotatedOffsetBottomLeft.x)) + (scaledKernelBitangent * rotatedOffsetBottomLeft.y), 1.0) * transpose(reblurProjection(false));
		vec2 kernelNdcBottomLeft = kernelClipBottomLeft.xy / vec2(kernelClipBottomLeft.w);
		vec3 kernelScreenBottomLeft = vec3(kernelNdcBottomLeft.x, kernelNdcBottomLeft.y, kernelClipBottomLeft.w);
		kernelScreenBottomLeft.y = -kernelNdcBottomLeft.y;
		vec2 kernelUv7 = (kernelScreenBottomLeft.xy * 0.5) + vec2(0.5);
#endif
		const float sampleGaussianWeights[8] = float[8](
			0.51685130596160888671875, 0.51685130596160888671875, 0.51685130596160888671875, 0.51685130596160888671875, 0.84789371490478515625, 0.84789371490478515625, 0.84789371490478515625, 0.84789371490478515625);
		vec2 sampleUvs[8] = vec2[8](kernelUv0, kernelUv1, kernelUv2, kernelUv3, kernelUv4, kernelUv5, kernelUv6, kernelUv7);
		vec4 sum = centerRadiance;
		float sum_w = 1.0;
		for (int i = 0; i < 8; ++i) {
			vec2 sampleUv = sampleUvs[i];
			float sampleGaussianWeight = sampleGaussianWeights[i];
			vec2 mirroredUv = spvNMin(vec2(1.0) - abs(vec2(1.0) - (fract(sampleUv * 0.5) * 2.0)), vec2(0.999989986419677734375));
			uvec2 p = uvec2(ivec2(mirroredUv * ubo.ubo.reblur_rect_size[REBLUR_SIGNAL].xy));
			float sampleViewDepth = abs(reblurFetch_temporal_depth(ivec2(p)).x * ubo.ubo.reblur_view_z_scale[REBLUR_SIGNAL]);
			vec2 sampleViewXY = ((mirroredUv * ubo.ubo.reblur_frustum[REBLUR_SIGNAL].zw) + ubo.ubo.reblur_frustum[REBLUR_SIGNAL].xy).xy * (isPerspective ? sampleViewDepth : ubo.ubo.reblur_ortho_mode[REBLUR_SIGNAL]);
			vec3 sampleViewPosition = vec3(sampleViewXY.x, sampleViewXY.y, 0.0);
			sampleViewPosition.z = sampleViewDepth;
			vec4 sampleNormalRoughness = reblurFetch_normal(ivec2(p));
#if NRD_REFLECTION
			float signedRoughness = (sampleNormalRoughness.z * 2.0) - 1.0;
			float sampleRoughness = abs(signedRoughness);
#endif
			vec3 sampleNormalUnnormalized = reblurDecodeNormalUnnormalized(sampleNormalRoughness);
			float normalDot = dot(normalWorld, (reblurSafeNormalize(sampleNormalUnnormalized)).xyz);
			float normalAngleWeight = clamp((abs((reblurNormalAngle(normalDot)) * normalWeightScale) - 1.0) * (-1.0), 0.0, 1.0);
#if NRD_REFLECTION
			float roughnessWeight = clamp((abs((sampleRoughness * roughnessWeightScale) + roughnessWeightBias) - 1.0) * (-1.0), 0.0, 1.0);
#endif
			float planeWeight = clamp((abs((dot(normalView, sampleViewPosition) * planeWeightScale) + planeWeightBias) - 1.0) * (-1.0), 0.0, 1.0);
#if !NRD_REFLECTION
			float geometryWeight = (!(sampleViewDepth < ubo.ubo.reblur_denoising_range[REBLUR_SIGNAL])) ? 0.0 : ((((any(notEqual(sampleUv, mirroredUv)) ? 1.0 : sampleGaussianWeight) * float(centerMaterial == spvNMax(sampleNormalRoughness.w * 3.0, ubo.ubo.reblur_diff_min_material[REBLUR_SIGNAL]))) * ((normalAngleWeight * normalAngleWeight) * (3.0 - (normalAngleWeight * 2.0)))) * ((planeWeight * planeWeight) * (3.0 - (planeWeight * 2.0))));
#else
			float geometryWeight = (!(sampleViewDepth < ubo.ubo.reblur_denoising_range[REBLUR_SIGNAL])) ? 0.0 : (((((any(notEqual(sampleUv, mirroredUv)) ? 1.0 : sampleGaussianWeight) * float(centerMaterial == spvNMax(sampleNormalRoughness.w * 3.0, ubo.ubo.reblur_spec_min_material[REBLUR_SIGNAL]))) * ((normalAngleWeight * normalAngleWeight) * (3.0 - (normalAngleWeight * 2.0)))) * ((roughnessWeight * roughnessWeight) * (3.0 - (roughnessWeight * 2.0)))) * ((planeWeight * planeWeight) * (3.0 - (planeWeight * 2.0))));
#endif
			vec4 sampleRadiance = mix(reblurFetch_radiance(ivec2(p)), vec4(0.0), bvec4(geometryWeight == 0.0));
			float hitDistanceDelta = (-3.0) * abs((sampleRadiance.w * hitDistanceWeightScale) + hitDistanceWeightBias);
			float w = geometryWeight * (minHitDistanceWeight + (1.0 / (((hitDistanceDelta * hitDistanceDelta) - hitDistanceDelta) + 1.0)));
			sum += sampleRadiance * w;
			sum_w += w;
		}
		vec4 filteredRadiance = sum * (1.0 / spvNMax(sum_w, 1.0000000036274937255387218471014e-15));
		filteredRadiance.w = centerHitDistance;
		reblurStore_out_temporal_history(ivec2(out_pix),filteredRadiance);
		break;
	} while(false);
}
