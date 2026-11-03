/* Shared REBLUR pass derived from NVIDIA NRD 4.18.
	* See ../../nrd_port/LICENSE.NVIDIA.txt and ../../nrd_port/LICENSE.MathLib.txt. */

layout(set=0,binding=1,rgba8) uniform readonly image2D TILES_IMAGE;
layout(set=0,binding=2,rgba16f) uniform readonly image2D NORMAL_IMAGE;
layout(set=0,binding=3,rgba32f) uniform readonly image2D VIEWZ_IMAGE;
layout(set=0,binding=4,rgba16f) uniform readonly image2D SIGNAL_IMAGE;
layout(set=0,binding=5,rgba16f) uniform writeonly image2D WORK_OUTPUT_IMAGE;
#if NRD_REFLECTION
layout(set=0,binding=6,rgba16f) uniform writeonly image2D TRACKING_DISTANCE_OUTPUT_IMAGE;
#endif

vec4 reblurFetch_tiles(ivec2 p) {
	if(any(lessThan(p,ivec2(0))) || any(greaterThanEqual(p,reblurExtent()))) return vec4(0);
	return imageLoad(TILES_IMAGE,p);
}

vec4 reblurFetch_normal(ivec2 p) {
	if(any(lessThan(p,ivec2(0))) || any(greaterThanEqual(p,reblurExtent()))) return vec4(0);
	return imageLoad(NORMAL_IMAGE,p);
}

vec4 reblurFetch_viewz(ivec2 p) {
	if(any(lessThan(p,ivec2(0))) || any(greaterThanEqual(p,reblurExtent()))) return vec4(0);
	return imageLoad(VIEWZ_IMAGE,p);
}

vec4 reblurFetch_signal(ivec2 p) {
	if(any(lessThan(p,ivec2(0))) || any(greaterThanEqual(p,reblurExtent()))) return vec4(0);
	return imageLoad(SIGNAL_IMAGE,p);
}

void reblurStore_out_work(ivec2 p,vec4 v) { imageStore(WORK_OUTPUT_IMAGE,p,v); }
#if NRD_REFLECTION
void reblurStore_out_tracking_distance(ivec2 p,vec4 v) { imageStore(TRACKING_DISTANCE_OUTPUT_IMAGE,p,vec4(v.x,0.0,0.0,1.0)); }
#endif
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

vec3 unusedPositionPadding;
#if !NRD_REFLECTION
float unusedNormalPadding;
#endif

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
	if (any(greaterThanEqual(gl_WorkGroupID.xy, ubo.ubo.reblur_groups_16x16[REBLUR_SIGNAL].xy))) return;
	do {
		ivec2 pix = ivec2((((((uvec2(ubo.ubo.reblur_rect_size[REBLUR_SIGNAL].xy) + uvec2(15u)) / uvec2(16u)) - uvec2(1u)) - gl_WorkGroupID.xy) * uvec2(16u)) + uvec2(ivec3(gl_LocalInvocationID).xy));
		bool skipPixel;
		if (!(reblurFetch_tiles(ivec2(uvec2(pix >> ivec2(4)))).x != 0.0)) {
			skipPixel = any(greaterThan(pix, ubo.ubo.reblur_rect_size_minus_one[REBLUR_SIGNAL].xy));
		} else {
			skipPixel = true;
		}
		if (skipPixel) {
			break;
		}
		uvec2 out_pix = uvec2(pix);
		float viewDepth = abs(reblurFetch_viewz(ivec2(out_pix)).x * ubo.ubo.reblur_view_z_scale[REBLUR_SIGNAL]);
		if (!(viewDepth < ubo.ubo.reblur_denoising_range[REBLUR_SIGNAL])) {
			break;
		}
		vec4 packedNormalRoughness = reblurFetch_normal(ivec2(out_pix));
#if NRD_REFLECTION
		float centerSignedRoughness = (packedNormalRoughness.z * 2.0) - 1.0;
		float roughness = abs(centerSignedRoughness);
#endif
		vec3 decodedNormal = reblurDecodeNormalUnnormalized(packedNormalRoughness);
		vec3 normalWorld = (reblurSafeNormalize(decodedNormal)).xyz;
		mat4 viewToWorld = transpose(transpose(reblurViewToWorld()));
		vec3 normalView = normalWorld * mat3(viewToWorld[0].xyz, viewToWorld[1].xyz, viewToWorld[2].xyz);
		vec2 pixelUv = (vec2(pix) + vec2(0.5)) * ubo.ubo.reblur_rect_size_inv[REBLUR_SIGNAL].xy;
		bool isPerspective = ubo.ubo.reblur_ortho_mode[REBLUR_SIGNAL] == 0.0;
		vec2 positionViewXY = ((pixelUv * ubo.ubo.reblur_frustum[REBLUR_SIGNAL].zw) + ubo.ubo.reblur_frustum[REBLUR_SIGNAL].xy).xy * (isPerspective ? viewDepth : ubo.ubo.reblur_ortho_mode[REBLUR_SIGNAL]);
		vec3 positionView = vec3(positionViewXY.x, positionViewXY.y, unusedPositionPadding.z);
		positionView.z = viewDepth;
#if !NRD_REFLECTION
		float frustumSize = ubo.ubo.reblur_min_rect_dim_mul_unproject[REBLUR_SIGNAL] * mix(viewDepth, 1.0, abs(ubo.ubo.reblur_ortho_mode[REBLUR_SIGNAL]));
#else
		vec3 viewDirection;
		if (isPerspective) {
			viewDirection = normalize(-positionView);
		} else {
			viewDirection = vec3(0.0, 0.0, -1.0);
		}
		float absNormalDotView = abs(dot(normalView, viewDirection));
		float orthoFactor = abs(ubo.ubo.reblur_ortho_mode[REBLUR_SIGNAL]);
		float frustumSize = ubo.ubo.reblur_min_rect_dim_mul_unproject[REBLUR_SIGNAL] * mix(viewDepth, 1.0, orthoFactor);
#endif
		ivec2 checkerboardPixel = pix;
#if !NRD_REFLECTION
		checkerboardPixel.x = pix.x >> (((ubo.ubo.reblur_diff_checkerboard[REBLUR_SIGNAL] == 2u) ? 0 : 1) & 31);
#else
		checkerboardPixel.x = pix.x >> (((ubo.ubo.reblur_spec_checkerboard[REBLUR_SIGNAL] == 2u) ? 0 : 1) & 31);
#endif
		vec4 centerRadiance = reblurFetch_signal(ivec2(uvec2(checkerboardPixel)));
		vec4 filteredRadiance;
#if !NRD_REFLECTION
		if (ubo.ubo.reblur_diff_prepass_blur_radius[REBLUR_SIGNAL] != 0.0) {
#else
		if (ubo.ubo.reblur_spec_prepass_blur_radius[REBLUR_SIGNAL] != 0.0) {
			uint pixelX = out_pix.x;
			uint mortonSpreadXBytes = (pixelX | (pixelX << 8u)) & 16711935u;
			uint mortonSpreadXNibbles = (mortonSpreadXBytes | (mortonSpreadXBytes << 4u)) & 252645135u;
			uint mortonSpreadXPairs = (mortonSpreadXNibbles | (mortonSpreadXNibbles << 2u)) & 858993459u;
			uint pixelY = out_pix.y;
			uint mortonSpreadYBytes = (pixelY | (pixelY << 8u)) & 16711935u;
			uint mortonSpreadYNibbles = (mortonSpreadYBytes | (mortonSpreadYBytes << 4u)) & 252645135u;
			uint mortonSpreadYPairs = (mortonSpreadYNibbles | (mortonSpreadYNibbles << 2u)) & 858993459u;
			uint mortonPixel = ((mortonSpreadXPairs | (mortonSpreadXPairs << 1u)) & 1431655765u) | (((mortonSpreadYPairs | (mortonSpreadYPairs << 1u)) & 1431655765u) << 1u);
			uint frameSeed = ubo.ubo.reblur_frame_index[REBLUR_SIGNAL] + 56598313u;
			uint frameHash = reblurHash(frameSeed);
			uint pixelHashFirst = (mortonPixel ^ (mortonPixel >> 16u)) * 2146121005u;
			uint pixelHashSecond = (pixelHashFirst ^ (pixelHashFirst >> 15u)) * 2221713035u;
			uint candidateRngSeed = frameHash ^ ((((pixelHashSecond ^ (pixelHashSecond >> 16u)) + 2654435769u) + (frameHash << 6u)) + (frameHash >> 2u));
			float clampedRoughness = clamp(roughness, 0.0, 1.0);
			float dominantDirectionFit = 0.2984749972820281982421875 * log(39.4114990234375 - (39.002899169921875 * clampedRoughness));
			float dominantDirectionFactor = clamp((pow(clamp(1.0 - absNormalDotView, 0.0, 1.0), 10.86489963531494140625) * (1.0 - dominantDirectionFit)) + dominantDirectionFit, 0.0, 1.0);
			float hitDistanceRoughnessFactor = (1.0 - exp2(((-200.0) * roughness) * roughness)) * pow(clampedRoughness, 0.5);
#endif
			float centerHitDistance = centerRadiance.w;
#if NRD_REFLECTION
			float worldHitDistance = centerHitDistance * ((ubo.ubo.reblur_hit_dist_settings[REBLUR_SIGNAL].x + (abs(viewDepth) * ubo.ubo.reblur_hit_dist_settings[REBLUR_SIGNAL].y)) * mix(ubo.ubo.reblur_hit_dist_settings[REBLUR_SIGNAL].z, 1.0, hitDistanceRoughnessFactor));
#endif
			float planeWeightScale = 1.0 / (ubo.ubo.reblur_plane_dist_sensitivity[REBLUR_SIGNAL] * frustumSize);
			float planeWeightBias = -(dot(normalView, positionView) * planeWeightScale);
			float lobeWeightFraction = clamp(0.75 * mix(clamp(ubo.ubo.reblur_lobe_angle_fraction[REBLUR_SIGNAL], 0.0, 1.0), 1.0, 0.0909090936183929443359375), 0.0, 1.0);
#if !NRD_REFLECTION
			float normalWeightScale = 0.5 / spvNMax(atan(sqrt(lobeWeightFraction / (1.00000095367431640625 - lobeWeightFraction))), 0.00294117652811110019683837890625);
#else
			float normalWeightScale = 0.5 / spvNMax(atan(clampedRoughness * sqrt(lobeWeightFraction / (1.00000095367431640625 - lobeWeightFraction))), 0.00294117652811110019683837890625);
			float roughnessWeightScale = 1.0 / mix(0.00999999977648258209228515625, 1.0, clamp(roughness * (ubo.ubo.reblur_roughness_fraction[REBLUR_SIGNAL] * 2.0), 0.0, 1.0));
			float roughnessWeightBias = -(roughness * roughnessWeightScale);
#endif
			float hitDistanceWeightBias = centerHitDistance * (-11.0);
#if !NRD_REFLECTION
			float minHitDistanceWeight = ubo.ubo.reblur_min_hit_distance_weight[REBLUR_SIGNAL] * 2.0;
			vec2 blurRadiusUv = ubo.ubo.reblur_rect_size_inv[REBLUR_SIGNAL].xy * spvNMax(clamp(sqrt(clamp(clamp((centerHitDistance * (ubo.ubo.reblur_hit_dist_settings[REBLUR_SIGNAL].x + (abs(viewDepth) * ubo.ubo.reblur_hit_dist_settings[REBLUR_SIGNAL].y))) / frustumSize, 0.0, 1.0), 0.0, 1.0)), 0.0, 1.0) * ubo.ubo.reblur_diff_prepass_blur_radius[REBLUR_SIGNAL], ubo.ubo.reblur_min_blur_radius[REBLUR_SIGNAL]);
#else
			float minHitDistanceWeight = (ubo.ubo.reblur_min_hit_distance_weight[REBLUR_SIGNAL] * 2.0) * hitDistanceRoughnessFactor;
			vec2 blurRadiusUv = ubo.ubo.reblur_rect_size_inv[REBLUR_SIGNAL].xy * spvNMin(spvNMax((clamp(sqrt(clamp(clamp(worldHitDistance / frustumSize, 0.0, 1.0), 0.0, 1.0)), 0.0, 1.0) * ubo.ubo.reblur_spec_prepass_blur_radius[REBLUR_SIGNAL]) * hitDistanceRoughnessFactor, ubo.ubo.reblur_min_blur_radius[REBLUR_SIGNAL] * hitDistanceRoughnessFactor), ((worldHitDistance * abs(dot(normalView, vec4(normalize(mix(normalView, reflect(-viewDirection, normalView), vec3(dominantDirectionFactor))), dominantDirectionFactor).xyz))) * (clampedRoughness * 0.65465319156646728515625)) / (ubo.ubo.reblur_unproject[REBLUR_SIGNAL] * mix(viewDepth + (worldHitDistance * dominantDirectionFactor), 1.0, orthoFactor)));
#endif
			vec4 scaledRotator = vec4(ubo.ubo.reblur_rotator_pre[REBLUR_SIGNAL].xz * blurRadiusUv.x, ubo.ubo.reblur_rotator_pre[REBLUR_SIGNAL].yw * blurRadiusUv.y);
#if !NRD_REFLECTION
			float centerMaterial = spvNMax(packedNormalRoughness.w * 3.0, ubo.ubo.reblur_diff_min_material[REBLUR_SIGNAL]);
			vec2 kernelUv0 = pixelUv + (scaledRotator.xz * (-1.0));
			vec2 kernelUv1 = pixelUv + (scaledRotator.yw * 1.0);
			vec2 kernelUv2 = pixelUv + (scaledRotator.xz * 1.0);
			vec2 kernelUv3 = pixelUv + (scaledRotator.yw * (-1.0));
			vec2 diagonalNegativeX = scaledRotator.xz * (-0.3535533845424652099609375);
			vec2 diagonalPositiveY = scaledRotator.yw * 0.3535533845424652099609375;
#else
			float initialTrackingDistance = (worldHitDistance == 0.0) ? 1000000.0 : worldHitDistance;
			vec2 kernelAxisX = scaledRotator.xz;
			float centerMaterial = spvNMax(packedNormalRoughness.w * 3.0, ubo.ubo.reblur_spec_min_material[REBLUR_SIGNAL]);
			float roughnessContactFade = clamp((roughness - 0.5) * 2.0, 0.0, 1.0);
			vec2 kernelUv0 = pixelUv + (kernelAxisX * (-1.0));
			vec2 kernelAxisY = scaledRotator.yw;
			vec2 kernelUv1 = pixelUv + (kernelAxisY * 1.0);
			vec2 kernelUv2 = pixelUv + (kernelAxisX * 1.0);
			vec2 kernelUv3 = pixelUv + (kernelAxisY * (-1.0));
			vec2 diagonalNegativeX = kernelAxisX * (-0.3535533845424652099609375);
			vec2 diagonalPositiveY = kernelAxisY * 0.3535533845424652099609375;
#endif
			vec2 kernelUv4 = pixelUv + (diagonalNegativeX + diagonalPositiveY);
#if !NRD_REFLECTION
			vec2 diagonalPositiveX = scaledRotator.xz * 0.3535533845424652099609375;
#else
			vec2 diagonalPositiveX = kernelAxisX * 0.3535533845424652099609375;
#endif
			vec2 kernelUv5 = pixelUv + (diagonalPositiveX + diagonalPositiveY);
#if !NRD_REFLECTION
			vec2 diagonalNegativeY = scaledRotator.yw * (-0.3535533845424652099609375);
#else
			vec2 diagonalNegativeY = kernelAxisY * (-0.3535533845424652099609375);
#endif
			vec2 kernelUv6 = pixelUv + (diagonalPositiveX + diagonalNegativeY);
			vec2 kernelUv7 = pixelUv + (diagonalNegativeX + diagonalNegativeY);
			const float sampleGaussianWeights[8] = float[8](
				0.51685130596160888671875, 0.51685130596160888671875, 0.51685130596160888671875, 0.51685130596160888671875, 0.84789371490478515625, 0.84789371490478515625, 0.84789371490478515625, 0.84789371490478515625);
			vec2 sampleUvs[8] = vec2[8](kernelUv0, kernelUv1, kernelUv2, kernelUv3, kernelUv4, kernelUv5, kernelUv6, kernelUv7);
			vec4 sum = centerRadiance;
			float sum_w = 1.0;
#if NRD_REFLECTION
			uint rngState = candidateRngSeed;
			float trackingHitDistance = initialTrackingDistance;
#endif
			for (int i = 0; i < 8; ++i) {
				vec2 sampleUv = sampleUvs[i];
				float sampleGaussianWeight = sampleGaussianWeights[i];
				vec2 mirroredUv = spvNMin(vec2(1.0) - abs(vec2(1.0) - (fract(sampleUv * 0.5) * 2.0)), vec2(0.999989986419677734375));
				uvec2 p = uvec2(ivec2(mirroredUv * ubo.ubo.reblur_rect_size[REBLUR_SIGNAL].xy));
				float sampleViewDepth = abs(reblurFetch_viewz(ivec2(p)).x * ubo.ubo.reblur_view_z_scale[REBLUR_SIGNAL]);
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
				vec4 sampleRadiance = mix(reblurFetch_signal(ivec2(p)), vec4(0.0), bvec4(geometryWeight == 0.0));
#if !NRD_REFLECTION
				float hitDistanceDelta = (-3.0) * abs((sampleRadiance.w * 11.0) + hitDistanceWeightBias);
				float w = geometryWeight * (minHitDistanceWeight + (1.0 / (((hitDistanceDelta * hitDistanceDelta) - hitDistanceDelta) + 1.0)));
#else
				float sampleHitDistanceNormalized = sampleRadiance.w;
				float sampleHitDistance = sampleHitDistanceNormalized * ((ubo.ubo.reblur_hit_dist_settings[REBLUR_SIGNAL].x + (abs(sampleViewDepth) * ubo.ubo.reblur_hit_dist_settings[REBLUR_SIGNAL].y)) * mix(ubo.ubo.reblur_hit_dist_settings[REBLUR_SIGNAL].z, 1.0, (1.0 - exp2(((-200.0) * sampleRoughness) * sampleRoughness)) * pow(clamp(sampleRoughness, 0.0, 1.0), 0.5)));
				uint hashValue = reblurHash(rngState);
				float nextTrackingHitDistance;
				if ((uintBitsToFloat((hashValue >> 9u) | 1065353216u) - 1.0) < ((geometryWeight * absNormalDotView) * float(sampleHitDistance != 0.0))) {
					nextTrackingHitDistance = spvNMin(trackingHitDistance, sampleHitDistance);
				} else {
					nextTrackingHitDistance = trackingHitDistance;
				}
				float hitDistanceDelta = (-3.0) * abs((sampleHitDistanceNormalized * 11.0) + hitDistanceWeightBias);
				float w = ((geometryWeight * ubo.ubo.reblur_use_prepass_not_only_for_specular_motion_estimation[REBLUR_SIGNAL]) * mix(clamp(sampleHitDistance / ((length(sampleViewPosition - positionView) + 9.9999999747524270787835121154785e-07) + worldHitDistance), 0.0, 1.0), 1.0, roughnessContactFade)) * (minHitDistanceWeight + (1.0 / (((hitDistanceDelta * hitDistanceDelta) - hitDistanceDelta) + 1.0)));
				rngState = hashValue;
				trackingHitDistance = nextTrackingHitDistance;
#endif
				sum += sampleRadiance * w;
				sum_w += w;
			}
#if NRD_REFLECTION
			reblurStore_out_tracking_distance(ivec2(out_pix),vec4((trackingHitDistance == 1000000.0) ? 0.0 : trackingHitDistance));
#endif
			filteredRadiance = sum * (1.0 / spvNMax(sum_w, 1.0000000036274937255387218471014e-15));
		} else {
			filteredRadiance = centerRadiance;
		}
		reblurStore_out_work(ivec2(out_pix),filteredRadiance);
		break;
	} while(false);
}
