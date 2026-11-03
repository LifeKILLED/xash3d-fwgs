/* Shared REBLUR pass derived from NVIDIA NRD 4.18.
	* See ../../nrd_port/LICENSE.NVIDIA.txt and ../../nrd_port/LICENSE.MathLib.txt. */

layout(set=0,binding=1,rgba8) uniform readonly image2D TILES_IMAGE;
layout(set=0,binding=2,rgba16f) uniform readonly image2D NORMAL_IMAGE;
layout(set=0,binding=3,rgba32f) uniform readonly image2D VIEWZ_IMAGE;
layout(set=0,binding=4,rgba16f) uniform readonly image2D MOTION_IMAGE;
layout(set=0,binding=5,rgba32f) uniform readonly image2D PREV_TEMPORAL_DEPTH_IMAGE;
layout(set=0,binding=6,rgba16f) uniform readonly image2D PREV_TEMPORAL_NORMAL_IMAGE;
layout(set=0,binding=7,rgba32f) uniform readonly image2D PREV_TEMPORAL_INTERNAL_IMAGE;
layout(set=0,binding=8,rgba16f) uniform readonly image2D WORK_IMAGE;
layout(set=0,binding=9,rgba16f) uniform readonly image2D PREV_TEMPORAL_HISTORY_IMAGE;
layout(set=0,binding=10,rgba16f) uniform readonly image2D PREV_TEMPORAL_FAST_IMAGE;
#if !NRD_REFLECTION
layout(set=0,binding=11,rgba8) uniform writeonly image2D FRAME_COUNTS_OUTPUT_IMAGE;
layout(set=0,binding=12,rgba16f) uniform writeonly image2D RADIANCE_OUTPUT_IMAGE;
layout(set=0,binding=13,rgba16f) uniform writeonly image2D FAST_LUMA_OUTPUT_IMAGE;
layout(set=0,binding=14,rgba16f) uniform writeonly image2D HISTORY_FLAGS_OUTPUT_IMAGE;
#else
layout(set=0,binding=11,rgba16f) uniform readonly image2D PREV_TEMPORAL_TRACKING_IMAGE;
layout(set=0,binding=12,rgba16f) uniform readonly image2D TRACKING_DISTANCE_IMAGE;
layout(set=0,binding=13,rgba8) uniform writeonly image2D FRAME_COUNTS_OUTPUT_IMAGE;
layout(set=0,binding=14,rgba16f) uniform writeonly image2D RADIANCE_OUTPUT_IMAGE;
layout(set=0,binding=15,rgba16f) uniform writeonly image2D FAST_LUMA_OUTPUT_IMAGE;
layout(set=0,binding=16,rgba16f) uniform writeonly image2D TEMPORAL_TRACKING_OUTPUT_IMAGE;
layout(set=0,binding=17,rgba32f) uniform writeonly image2D HISTORY_FLAGS_OUTPUT_IMAGE;
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
#if NRD_REFLECTION
vec4 reblurNearest_normal(vec2 uv) { return imageLoad(NORMAL_IMAGE,clamp(ivec2(floor(uv*vec2(reblurExtent()))),ivec2(0),reblurExtent()-1)); }
#endif

vec4 reblurFetch_viewz(ivec2 p) {
	if(any(lessThan(p,ivec2(0))) || any(greaterThanEqual(p,reblurExtent()))) return vec4(0);
	return imageLoad(VIEWZ_IMAGE,p);
#if NRD_REFLECTION
}

vec4 reblurLinear_viewz(vec2 uv) {
	vec2 p=uv*vec2(reblurExtent())-0.5; ivec2 b=ivec2(floor(p)); vec2 f=fract(p);
	return mix(mix(imageLoad(VIEWZ_IMAGE,clamp(b,ivec2(0),reblurExtent()-1)),imageLoad(VIEWZ_IMAGE,clamp(b+ivec2(1,0),ivec2(0),reblurExtent()-1)),f.x),
	mix(imageLoad(VIEWZ_IMAGE,clamp(b+ivec2(0,1),ivec2(0),reblurExtent()-1)),imageLoad(VIEWZ_IMAGE,clamp(b+ivec2(1,1),ivec2(0),reblurExtent()-1)),f.x),f.y);
#endif
}

vec4 reblurFetch_motion(ivec2 p) {
	if(any(lessThan(p,ivec2(0))) || any(greaterThanEqual(p,reblurExtent()))) return vec4(0);
	return imageLoad(MOTION_IMAGE,p);
}

vec4 reblurGather_prev_temporal_depth(vec2 uv, ivec2 offset) {
	ivec2 b=ivec2(floor(uv*vec2(reblurExtent())-0.5))+offset;
	return vec4(imageLoad(PREV_TEMPORAL_DEPTH_IMAGE,clamp(b+ivec2(0,1),ivec2(0),reblurExtent()-1)).x,imageLoad(PREV_TEMPORAL_DEPTH_IMAGE,clamp(b+ivec2(1,1),ivec2(0),reblurExtent()-1)).x,
	imageLoad(PREV_TEMPORAL_DEPTH_IMAGE,clamp(b+ivec2(1,0),ivec2(0),reblurExtent()-1)).x,imageLoad(PREV_TEMPORAL_DEPTH_IMAGE,clamp(b,ivec2(0),reblurExtent()-1)).x);
}

vec4 reblurFetch_prev_temporal_normal(ivec2 p) {
	if(any(lessThan(p,ivec2(0))) || any(greaterThanEqual(p,reblurExtent()))) return vec4(0);
	return imageLoad(PREV_TEMPORAL_NORMAL_IMAGE,p);
}
#if NRD_REFLECTION
vec4 reblurNearest_prev_temporal_normal(vec2 uv) { return imageLoad(PREV_TEMPORAL_NORMAL_IMAGE,clamp(ivec2(floor(uv*vec2(reblurExtent()))),ivec2(0),reblurExtent()-1)); }
#endif

uvec4 reblurUintLoad_prev_temporal_internal(ivec2 p) {
	vec4 v=imageLoad(PREV_TEMPORAL_INTERNAL_IMAGE,p); return uvec4(uint(v.x),0u,0u,1u);
}

uvec4 reblurGather_prev_temporal_internal(vec2 uv, ivec2 offset) {
	ivec2 b=ivec2(floor(uv*vec2(reblurExtent())-0.5))+offset;
	return uvec4(reblurUintLoad_prev_temporal_internal(clamp(b+ivec2(0,1),ivec2(0),reblurExtent()-1)).x,reblurUintLoad_prev_temporal_internal(clamp(b+ivec2(1,1),ivec2(0),reblurExtent()-1)).x,
	reblurUintLoad_prev_temporal_internal(clamp(b+ivec2(1,0),ivec2(0),reblurExtent()-1)).x,reblurUintLoad_prev_temporal_internal(clamp(b,ivec2(0),reblurExtent()-1)).x);
}

vec4 reblurFetch_work(ivec2 p) {
	if(any(lessThan(p,ivec2(0))) || any(greaterThanEqual(p,reblurExtent()))) return vec4(0);
	return imageLoad(WORK_IMAGE,p);
}

vec4 reblurLinear_prev_temporal_history(vec2 uv) {
	vec2 p=uv*vec2(reblurExtent())-0.5; ivec2 b=ivec2(floor(p)); vec2 f=fract(p);
	return mix(mix(imageLoad(PREV_TEMPORAL_HISTORY_IMAGE,clamp(b,ivec2(0),reblurExtent()-1)),imageLoad(PREV_TEMPORAL_HISTORY_IMAGE,clamp(b+ivec2(1,0),ivec2(0),reblurExtent()-1)),f.x),
	mix(imageLoad(PREV_TEMPORAL_HISTORY_IMAGE,clamp(b+ivec2(0,1),ivec2(0),reblurExtent()-1)),imageLoad(PREV_TEMPORAL_HISTORY_IMAGE,clamp(b+ivec2(1,1),ivec2(0),reblurExtent()-1)),f.x),f.y);
}

vec4 reblurFetch_prev_temporal_fast(ivec2 p) {
	if(any(lessThan(p,ivec2(0))) || any(greaterThanEqual(p,reblurExtent()))) return vec4(0);
	return imageLoad(PREV_TEMPORAL_FAST_IMAGE,p);
}

#if NRD_REFLECTION
vec4 reblurLinear_prev_temporal_tracking(vec2 uv) {
	vec2 p=uv*vec2(reblurExtent())-0.5; ivec2 b=ivec2(floor(p)); vec2 f=fract(p);
	return mix(mix(imageLoad(PREV_TEMPORAL_TRACKING_IMAGE,clamp(b,ivec2(0),reblurExtent()-1)),imageLoad(PREV_TEMPORAL_TRACKING_IMAGE,clamp(b+ivec2(1,0),ivec2(0),reblurExtent()-1)),f.x),
	mix(imageLoad(PREV_TEMPORAL_TRACKING_IMAGE,clamp(b+ivec2(0,1),ivec2(0),reblurExtent()-1)),imageLoad(PREV_TEMPORAL_TRACKING_IMAGE,clamp(b+ivec2(1,1),ivec2(0),reblurExtent()-1)),f.x),f.y);
}

vec4 reblurFetch_tracking_distance(ivec2 p) {
	if(any(lessThan(p,ivec2(0))) || any(greaterThanEqual(p,reblurExtent()))) return vec4(0);
	return imageLoad(TRACKING_DISTANCE_IMAGE,p);
}

#endif
void reblurStore_out_frame_counts(ivec2 p,vec4 v) { imageStore(FRAME_COUNTS_OUTPUT_IMAGE,p,vec4(v.x,0.0,0.0,1.0)); }
void reblurStore_out_radiance(ivec2 p,vec4 v) { imageStore(RADIANCE_OUTPUT_IMAGE,p,v); }
void reblurStore_out_fast_luma(ivec2 p,vec4 v) { imageStore(FAST_LUMA_OUTPUT_IMAGE,p,vec4(v.x,0.0,0.0,1.0)); }
#if !NRD_REFLECTION
void reblurStore_out_history_flags(ivec2 p,uvec4 v) { imageStore(HISTORY_FLAGS_OUTPUT_IMAGE,p,vec4(float(v.x & 255u),0.0,0.0,1.0)); }
#else
void reblurStore_out_temporal_tracking(ivec2 p,vec4 v) { imageStore(TEMPORAL_TRACKING_OUTPUT_IMAGE,p,vec4(v.x,0.0,0.0,1.0)); }
void reblurStore_out_history_flags(ivec2 p,uvec4 v) { imageStore(HISTORY_FLAGS_OUTPUT_IMAGE,p,vec4(float(v.x & 65535u),float(v.x >> 16u),0.0,1.0)); }
#endif
layout(local_size_x = 8, local_size_y = 16, local_size_z = 1) in;
#if NRD_REFLECTION

vec4 unusedRadiancePadding;
vec3 unusedPositionPadding;
float unusedAccumulationPadding;
vec3 unusedHistoryPadding;
#endif

shared vec4 s_Normal_HitDistForTracking[18][10];

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
#if !NRD_REFLECTION
		// Cooperative normal preload; every thread reaches the barrier.
#endif
		vec4 tileClassification = reblurFetch_tiles(ivec2(uvec2(ivec3(gl_GlobalInvocationID).xy >> ivec2(4))));
		float tileIsSky = tileClassification.x;
		if (tileIsSky == 0.0) {
			uvec2 sharedPixelOrigin = uvec2((ivec3(gl_GlobalInvocationID).xy - ivec3(gl_LocalInvocationID).xy) - ivec2(1));
#if NRD_REFLECTION
			bool isPrepassDisabled = ubo.ubo.reblur_spec_prepass_blur_radius[REBLUR_SIGNAL] == 0.0;
#endif
			for (uint sharedIndex = gl_LocalInvocationIndex; sharedIndex < 180u; sharedIndex += 128u) {
				uint sharedX = sharedIndex % 10u;
				uint sharedY = sharedIndex / 10u;
#if !NRD_REFLECTION
				vec4 sharedNormalRoughness = reblurFetch_normal(ivec2(uvec2(clamp(ivec2(sharedPixelOrigin + uvec2(sharedX, sharedY)), ivec2(0), ubo.ubo.reblur_rect_size_minus_one[REBLUR_SIGNAL].xy))));
#else
				uvec2 sharedPixel = uvec2(clamp(ivec2(sharedPixelOrigin + uvec2(sharedX, sharedY)), ivec2(0), ubo.ubo.reblur_rect_size_minus_one[REBLUR_SIGNAL].xy));
				vec4 sharedNormalRoughness = reblurFetch_normal(ivec2(sharedPixel));
#endif
				vec3 sharedNormalUnnormalized = reblurDecodeNormalUnnormalized(sharedNormalRoughness);
#if !NRD_REFLECTION
				s_Normal_HitDistForTracking[sharedY][sharedX] = vec4(reblurSafeNormalize(sharedNormalUnnormalized), 0.0);
#else
				float sharedHitDistance;
				if (isPrepassDisabled) {
					sharedHitDistance = reblurFetch_work(ivec2(sharedPixel)).w;
				} else {
					sharedHitDistance = reblurFetch_tracking_distance(ivec2(sharedPixel)).x;
				}
				bool sharedHitDistanceInvalid;
				if (!(sharedHitDistance == 0.0)) {
					sharedHitDistanceInvalid = !(abs(reblurFetch_viewz(ivec2(sharedPixel)).x * ubo.ubo.reblur_view_z_scale[REBLUR_SIGNAL]) < ubo.ubo.reblur_denoising_range[REBLUR_SIGNAL]);
				} else {
					sharedHitDistanceInvalid = true;
				}
				s_Normal_HitDistForTracking[sharedY][sharedX] = vec4(reblurSafeNormalize(sharedNormalUnnormalized), sharedHitDistanceInvalid ? 1000000.0 : sharedHitDistance);
#endif
			}
		}
		barrier();
		bool skipPixel;
		if (!(tileIsSky != 0.0)) {
			skipPixel = any(greaterThan(ivec3(gl_GlobalInvocationID).xy, ubo.ubo.reblur_rect_size_minus_one[REBLUR_SIGNAL].xy));
		} else {
			skipPixel = true;
		}
		if (skipPixel) {
			break;
		}
		uvec2 out_pix = uvec2(ivec3(gl_GlobalInvocationID).xy);
		float viewDepth = abs(reblurFetch_viewz(ivec2(out_pix)).x * ubo.ubo.reblur_view_z_scale[REBLUR_SIGNAL]);
		if (!(viewDepth < ubo.ubo.reblur_denoising_range[REBLUR_SIGNAL])) {
			break;
		}
		vec2 pixelUv = (vec2(ivec3(gl_GlobalInvocationID).xy) + vec2(0.5)) * ubo.ubo.reblur_rect_size_inv[REBLUR_SIGNAL].xy;
		bool isPerspective = ubo.ubo.reblur_ortho_mode[REBLUR_SIGNAL] == 0.0;
		vec2 positionViewXY = ((pixelUv * ubo.ubo.reblur_frustum[REBLUR_SIGNAL].zw) + ubo.ubo.reblur_frustum[REBLUR_SIGNAL].xy).xy * (isPerspective ? viewDepth : ubo.ubo.reblur_ortho_mode[REBLUR_SIGNAL]);
#if !NRD_REFLECTION
		vec3 positionView = vec3(positionViewXY.x, positionViewXY.y, 0.0);
#else
		vec3 positionView = vec3(positionViewXY.x, positionViewXY.y, unusedPositionPadding.z);
#endif
		positionView.z = viewDepth;
#if !NRD_REFLECTION
		vec3 positionWorld = positionView * mat3(transpose(reblurViewToWorld())[0].xyz, transpose(reblurViewToWorld())[1].xyz, transpose(reblurViewToWorld())[2].xyz);
#else
		mat3 viewToWorldRotation = mat3(transpose(reblurViewToWorld())[0].xyz, transpose(reblurViewToWorld())[1].xyz, transpose(reblurViewToWorld())[2].xyz);
		vec3 positionWorld = positionView * viewToWorldRotation;
#endif
		vec3 averagedNormalWorld = s_Normal_HitDistForTracking[gl_LocalInvocationID.y][gl_LocalInvocationID.x].xyz * 0.25;
		for (int normalTap = 1; normalTap < 4; ++normalTap) {
			ivec2 sharedNormalPixel = ivec2(gl_LocalInvocationID.xy) + ivec2(normalTap & 1, normalTap >> 1);
			averagedNormalWorld += s_Normal_HitDistForTracking[sharedNormalPixel.y][sharedNormalPixel.x].xyz * 0.25;
		}
#if NRD_REFLECTION
		float minTrackingHitDistance = 1000000.0;
		for (int trackingY = 0; trackingY < 3; ++trackingY) {
			for (int trackingX = 0; trackingX < 3; ++trackingX) {
				ivec2 trackingPixel = ivec2(gl_LocalInvocationID.xy) + ivec2(trackingX, trackingY);
				minTrackingHitDistance = spvNMin(minTrackingHitDistance, s_Normal_HitDistForTracking[trackingPixel.y][trackingPixel.x].w);
			}
		}
#endif
		vec4 packedNormalRoughness = reblurFetch_normal(ivec2(out_pix));
#if NRD_REFLECTION
		float signedRoughness = (packedNormalRoughness.z * 2.0) - 1.0;
		float roughness = abs(signedRoughness);
#endif
		float materialId = packedNormalRoughness.w * 3.0;
#if !NRD_REFLECTION
		vec3 normalWorldUnnormalized = reblurDecodeNormalUnnormalized(packedNormalRoughness);
		vec3 surfaceNormalWorld = (reblurSafeNormalize(normalWorldUnnormalized)).xyz;
		// Reconstruct previous position from screen-space or world-space motion.
#else
		vec3 decodedSurfaceNormal = reblurDecodeNormalUnnormalized(packedNormalRoughness);
		vec3 normalizedSurfaceNormalWorld = reblurSafeNormalize(decodedSurfaceNormal);
		vec3 surfaceNormalWorld = normalizedSurfaceNormalWorld.xyz;
		float averagedNormalLength = length(averagedNormalWorld);
		float averagedNormalLengthSquared = averagedNormalLength * averagedNormalLength;
		float roughnessSquared = roughness * roughness;
		float normalVarianceAdjustedRoughness = sqrt(clamp(roughnessSquared + (clamp(1.0 - averagedNormalLengthSquared, 0.0, 1.0) * (1.0 / spvNMax(averagedNormalLength * (3.0 - averagedNormalLengthSquared), 1.0000000036274937255387218471014e-15))), 0.0, 1.0));
		float roughnessHitDistanceCurve = 1.0 - exp2(((-200.0) * roughness) * roughness);
		float clampedRoughness = clamp(roughness, 0.0, 1.0);
		float hitDistanceNormalization = (ubo.ubo.reblur_hit_dist_settings[REBLUR_SIGNAL].x + (abs(viewDepth) * ubo.ubo.reblur_hit_dist_settings[REBLUR_SIGNAL].y)) * mix(ubo.ubo.reblur_hit_dist_settings[REBLUR_SIGNAL].z, 1.0, roughnessHitDistanceCurve * pow(clampedRoughness, 0.5));
		float hitDistanceForTracking = ((minTrackingHitDistance == 1000000.0) ? 0.0 : minTrackingHitDistance) * ((ubo.ubo.reblur_spec_prepass_blur_radius[REBLUR_SIGNAL] == 0.0) ? hitDistanceNormalization : 1.0);
		reblurStore_out_temporal_tracking(ivec2(out_pix),vec4(hitDistanceForTracking));
#endif
		vec3 motionVector = (reblurFetch_motion(ivec2(out_pix)).xyz * ubo.ubo.reblur_mv_scale[REBLUR_SIGNAL].xyz) + ubo.ubo.reblur_mv_bias[REBLUR_SIGNAL].xyz;
		vec2 screenMotionUv = pixelUv + motionVector.xy;
		vec3 previousPositionWorld;
		vec2 surfaceMotionUv;
		if (ubo.ubo.reblur_mv_scale[REBLUR_SIGNAL].w == 0.0) {
			vec3 screenMotionWithDepth;
			if (ubo.ubo.reblur_mv_scale[REBLUR_SIGNAL].z == 0.0) {
				vec3 inferredDepthMotion;
				inferredDepthMotion.z = (vec4(positionWorld, 1.0) * transpose(reblurWorldToView(true))).z - viewDepth;
				screenMotionWithDepth = inferredDepthMotion;
			} else {
				screenMotionWithDepth = motionVector;
			}
			float viewDepth2 = viewDepth + screenMotionWithDepth.z;
			vec2 positionViewXY2 = ((screenMotionUv * ubo.ubo.reblur_frustum_prev[REBLUR_SIGNAL].zw) + ubo.ubo.reblur_frustum_prev[REBLUR_SIGNAL].xy).xy * (isPerspective ? viewDepth2 : ubo.ubo.reblur_ortho_mode[REBLUR_SIGNAL]);
#if !NRD_REFLECTION
			vec3 positionView2 = vec3(positionViewXY2.x, positionViewXY2.y, 0.0);
#else
			vec3 positionView2 = vec3(positionViewXY2.x, positionViewXY2.y, unusedPositionPadding.z);
#endif
			positionView2.z = viewDepth2;
			mat4 previousWorldToView = transpose(transpose(reblurWorldToView(true)));
			previousPositionWorld = (positionView2 * mat3(previousWorldToView[0].xyz, previousWorldToView[1].xyz, previousWorldToView[2].xyz)) + vec4(reblurCameraDelta(), 0.0).xyz;
			surfaceMotionUv = screenMotionUv;
		} else {
			vec3 worldMotionPosition = positionWorld + motionVector;
			vec4 worldMotionClipPosition = vec4(worldMotionPosition, 1.0) * reblurWorldToClip(true);
			previousPositionWorld = worldMotionPosition;
			surfaceMotionUv = ((worldMotionClipPosition.xy / vec2(worldMotionClipPosition.w)) * vec2(0.5, -0.5)) + vec2(0.5);
		}
#if !NRD_REFLECTION
		// Previous-frame footprint: four bilinear taps inside a 12-tap validity stencil.
#endif
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
		vec2 previousPixelPosition = asvgfDonor;
		vec2 previousPixelFloor = floor(previousPixelPosition);
		vec2 previousGatherUv = (previousPixelFloor + vec2(-1.0)) * ubo.ubo.reblur_resource_size_inv_prev[REBLUR_SIGNAL].xy;
		ivec2 previousNormalOrigin = ivec3(ivec2(previousPixelFloor), 0).xy;
#else
		vec2 surfacePreviousPixel = asvgfDonor;
		vec2 surfacePreviousFloor = floor(surfacePreviousPixel);
		vec2 surfaceGatherUv = (surfacePreviousFloor + vec2(-1.0)) * ubo.ubo.reblur_resource_size_inv_prev[REBLUR_SIGNAL].xy;
		ivec2 surfaceNormalOrigin = ivec3(ivec2(surfacePreviousFloor), 0).xy;
#endif
		vec3 previousNormalsUnnormalized[4];
		for (int reprojectionTap = 0; reprojectionTap < 4; ++reprojectionTap) {
#if !NRD_REFLECTION
			ivec2 previousNormalPixel = previousNormalOrigin + ivec2(reprojectionTap & 1, reprojectionTap >> 1);
#else
			ivec2 previousNormalPixel = surfaceNormalOrigin + ivec2(reprojectionTap & 1, reprojectionTap >> 1);
#endif
			vec4 previousPackedNormal = reblurFetch_prev_temporal_normal(previousNormalPixel);
			previousNormalsUnnormalized[reprojectionTap] = reblurDecodeNormalUnnormalized(previousPackedNormal);
		}
#if NRD_REFLECTION
		float surfaceNormalDotTopLeft = dot((reblurSafeNormalize(previousNormalsUnnormalized[0])).xyz, averagedNormalWorld);
		float surfaceNormalDotTopRight = dot((reblurSafeNormalize(previousNormalsUnnormalized[1])).xyz, averagedNormalWorld);
		float surfaceNormalDotBottomLeft = dot((reblurSafeNormalize(previousNormalsUnnormalized[2])).xyz, averagedNormalWorld);
		float surfaceNormalDotBottomRight = dot((reblurSafeNormalize(previousNormalsUnnormalized[3])).xyz, averagedNormalWorld);
		float surfaceRightWeight = 0.0;
		float surfaceBottomWeight = 0.0;
#endif
		bvec2 perspectiveMask = bvec2(isPerspective);
#if NRD_REFLECTION
		vec2 surfaceParallaxOriginUv = mix(pixelUv, surfaceMotionUv, perspectiveMask);
#endif
		vec4 forwardParallaxClip = vec4(previousPositionWorld + vec4(reblurCameraDelta(), 0.0).xyz, 1.0) * reblurWorldToClip(true);
#if !NRD_REFLECTION
		vec4 backwardParallaxClip = vec4(previousPositionWorld - vec4(reblurCameraDelta(), 0.0).xyz, 1.0) * reblurWorldToClip(false);
		float maxParallaxPixels = spvNMax(length(((((forwardParallaxClip.xy / vec2(forwardParallaxClip.w)) * vec2(0.5, -0.5)) + vec2(0.5)) - mix(pixelUv, surfaceMotionUv, perspectiveMask)) * ubo.ubo.reblur_rect_size[REBLUR_SIGNAL].xy), length(((((backwardParallaxClip.xy / vec2(backwardParallaxClip.w)) * vec2(0.5, -0.5)) + vec2(0.5)) - mix(surfaceMotionUv, pixelUv, perspectiveMask)) * ubo.ubo.reblur_rect_size[REBLUR_SIGNAL].xy));
		float projectionDepthScale = mix(viewDepth, 1.0, abs(ubo.ubo.reblur_ortho_mode[REBLUR_SIGNAL]));
#else
		vec2 forwardParallaxUv = ((forwardParallaxClip.xy / vec2(forwardParallaxClip.w)) * vec2(0.5, -0.5)) + vec2(0.5);
		float surfaceForwardParallaxPixels = length((forwardParallaxUv - surfaceParallaxOriginUv) * ubo.ubo.reblur_rect_size[REBLUR_SIGNAL].xy);
		vec3 backwardParallaxPosition = previousPositionWorld - vec4(reblurCameraDelta(), 0.0).xyz;
		vec4 backwardParallaxClip = vec4(backwardParallaxPosition, 1.0) * reblurWorldToClip(false);
		float surfaceBackwardParallaxPixels = length(((((backwardParallaxClip.xy / vec2(backwardParallaxClip.w)) * vec2(0.5, -0.5)) + vec2(0.5)) - mix(surfaceMotionUv, pixelUv, perspectiveMask)) * ubo.ubo.reblur_rect_size[REBLUR_SIGNAL].xy);
		float maxSurfaceParallaxPixels = spvNMax(surfaceForwardParallaxPixels, surfaceBackwardParallaxPixels);
		float orthoFactor = abs(ubo.ubo.reblur_ortho_mode[REBLUR_SIGNAL]);
		float projectionDepthScale = mix(viewDepth, 1.0, orthoFactor);
		float pixelWorldSize = ubo.ubo.reblur_unproject[REBLUR_SIGNAL] * projectionDepthScale;
		float frustumSize = ubo.ubo.reblur_min_rect_dim_mul_unproject[REBLUR_SIGNAL] * projectionDepthScale;
#endif
		bool isStrandMaterial = materialId == ubo.ubo.reblur_strand_material_id[REBLUR_SIGNAL];
		float strandThresholdBlend;
		if (isStrandMaterial) {
#if !NRD_REFLECTION
			strandThresholdBlend = clamp((0.5 * (ubo.ubo.reblur_unproject[REBLUR_SIGNAL] * projectionDepthScale)) / (ubo.ubo.reblur_strand_thickness[REBLUR_SIGNAL] + 9.9999999747524270787835121154785e-07), 0.0, 1.0);
#else
			strandThresholdBlend = clamp((0.5 * pixelWorldSize) / (ubo.ubo.reblur_strand_thickness[REBLUR_SIGNAL] + 9.9999999747524270787835121154785e-07), 0.0, 1.0);
#endif
		} else {
			strandThresholdBlend = 0.0;
		}
		float materialDisocclusionThreshold = mix(ubo.ubo.reblur_disocclusion_threshold[REBLUR_SIGNAL], ubo.ubo.reblur_disocclusion_threshold_alternate[REBLUR_SIGNAL], strandThresholdBlend);
		float disocclusionThreshold;
		if (isStrandMaterial) {
#if !NRD_REFLECTION
			float strandParallaxBlend = clamp(maxParallaxPixels, 0.0, 1.0);
#else
			float strandParallaxBlend = clamp(maxSurfaceParallaxPixels, 0.0, 1.0);
#endif
			disocclusionThreshold = mix(0.25, materialDisocclusionThreshold, (strandParallaxBlend * strandParallaxBlend) * (3.0 - (strandParallaxBlend * 2.0)));
		} else {
			disocclusionThreshold = materialDisocclusionThreshold;
		}
		vec3 viewDirectionWorld;
		if (isPerspective) {
			viewDirectionWorld = normalize(-positionWorld);
		} else {
			viewDirectionWorld = vec4(reblurViewDirection(false), 0.0).xyz;
		}
		float absNormalDotView = abs(dot(surfaceNormalWorld, viewDirectionWorld));
#if !NRD_REFLECTION
		// Reject history by normal agreement, screen bounds, plane depth and material.
		uvec4 packedStateUpperLeft = reblurGather_prev_temporal_internal(previousGatherUv,ivec2(1));
		uvec4 packedStateUpperRight = reblurGather_prev_temporal_internal(previousGatherUv,ivec2(3, 1));
		uvec4 packedStateLowerLeft = reblurGather_prev_temporal_internal(previousGatherUv,ivec2(1, 3));
		uvec4 packedStateLowerRight = reblurGather_prev_temporal_internal(previousGatherUv,ivec2(3));
#else
		uvec4 surfacePackedStateUpperLeft = reblurGather_prev_temporal_internal(surfaceGatherUv,ivec2(1));
		uvec4 surfacePackedStateUpperRight = reblurGather_prev_temporal_internal(surfaceGatherUv,ivec2(3, 1));
		uvec4 surfacePackedStateLowerLeft = reblurGather_prev_temporal_internal(surfaceGatherUv,ivec2(1, 3));
		uvec4 surfacePackedStateLowerRight = reblurGather_prev_temporal_internal(surfaceGatherUv,ivec2(3));
#endif
		vec4 historyStateChannelMax = spvNMax(vec4(63.0, 63.0, 15.0, 0.0), vec4(1.0));
		vec4 historyStateChannelScale = vec4(1.0) / historyStateChannelMax;
#if !NRD_REFLECTION
		vec4 historyStateTopLeft = vec4((uvec4(packedStateUpperLeft.y) >> uvec4(0u, 6u, 12u, 16u)) & uvec4(63u, 63u, 15u, 0u)) * historyStateChannelScale;
		vec4 historyStateTopRight = vec4((uvec4(packedStateUpperRight.x) >> uvec4(0u, 6u, 12u, 16u)) & uvec4(63u, 63u, 15u, 0u)) * historyStateChannelScale;
		vec4 historyStateBottomLeft = vec4((uvec4(packedStateLowerLeft.z) >> uvec4(0u, 6u, 12u, 16u)) & uvec4(63u, 63u, 15u, 0u)) * historyStateChannelScale;
		vec4 historyStateBottomRight = vec4((uvec4(packedStateLowerRight.w) >> uvec4(0u, 6u, 12u, 16u)) & uvec4(63u, 63u, 15u, 0u)) * historyStateChannelScale;
		vec3 validHistoryUpperLeft;
		vec3 validHistoryUpperRight;
		vec3 validHistoryLowerLeft;
		vec3 validHistoryLowerRight; {
			validHistoryUpperLeft = vec3(0.0, 0.0, float(asvgfHistoryValid));
			validHistoryUpperRight = vec3(0.0);
			validHistoryLowerLeft = vec3(0.0);
			validHistoryLowerRight = vec3(0.0);
#else
		vec4 surfaceHistoryStateTopLeft = vec4((uvec4(surfacePackedStateUpperLeft.y) >> uvec4(0u, 6u, 12u, 16u)) & uvec4(63u, 63u, 15u, 0u)) * historyStateChannelScale;
		vec4 surfaceHistoryStateTopRight = vec4((uvec4(surfacePackedStateUpperRight.x) >> uvec4(0u, 6u, 12u, 16u)) & uvec4(63u, 63u, 15u, 0u)) * historyStateChannelScale;
		vec4 surfaceHistoryStateBottomLeft = vec4((uvec4(surfacePackedStateLowerLeft.z) >> uvec4(0u, 6u, 12u, 16u)) & uvec4(63u, 63u, 15u, 0u)) * historyStateChannelScale;
		vec4 surfaceHistoryStateBottomRight = vec4((uvec4(surfacePackedStateLowerRight.w) >> uvec4(0u, 6u, 12u, 16u)) & uvec4(63u, 63u, 15u, 0u)) * historyStateChannelScale;
		vec3 surfaceValidUpperLeft;
		vec3 surfaceValidUpperRight;
		vec3 surfaceValidLowerLeft;
		vec3 surfaceValidLowerRight; {
			surfaceValidUpperLeft = vec3(0.0, 0.0, float(asvgfHistoryValid));
			surfaceValidUpperRight = vec3(0.0);
			surfaceValidLowerLeft = vec3(0.0);
			surfaceValidLowerRight = vec3(0.0);
#endif
		}
#if !NRD_REFLECTION
		float bilinearLeftWeight = 1.0;
		float bilinearTopWeight = 1.0;
		float historyWeightTopLeft = validHistoryUpperLeft.z * (bilinearLeftWeight * bilinearTopWeight);
		float bilinearRightWeight = 0.0;
		float historyWeightTopRight = validHistoryUpperRight.y * (bilinearRightWeight * bilinearTopWeight);
		float bilinearBottomWeight = 0.0;
		float historyWeightBottomLeft = validHistoryLowerLeft.y * (bilinearLeftWeight * bilinearBottomWeight);
		float historyWeightBottomRight = validHistoryLowerRight.x * (bilinearRightWeight * bilinearBottomWeight);
		vec4 bilinearHistoryWeights = vec4(historyWeightTopLeft, historyWeightTopRight, historyWeightBottomLeft, historyWeightBottomRight);
		float surfaceHistoryWeightSum = dot(bilinearHistoryWeights, vec4(1.0));
		bool hasNoHistoryWeight = surfaceHistoryWeightSum < 9.9999997473787516355514526367188e-05;
		float inverseHistoryWeightSum;
		if (hasNoHistoryWeight) {
			inverseHistoryWeightSum = 0.0;
#else
		float surfaceLeftWeight = 1.0;
		float surfaceTopWeight = 1.0;
		float surfaceHistoryWeightTopLeft = surfaceValidUpperLeft.z * (surfaceLeftWeight * surfaceTopWeight);
		float surfaceHistoryWeightTopRight = surfaceValidUpperRight.y * (surfaceRightWeight * surfaceTopWeight);
		float surfaceHistoryWeightBottomLeft = surfaceValidLowerLeft.y * (surfaceLeftWeight * surfaceBottomWeight);
		float surfaceHistoryWeightBottomRight = surfaceValidLowerRight.x * (surfaceRightWeight * surfaceBottomWeight);
		vec4 surfaceHistoryWeights = vec4(surfaceHistoryWeightTopLeft, surfaceHistoryWeightTopRight, surfaceHistoryWeightBottomLeft, surfaceHistoryWeightBottomRight);
		float surfaceHistoryWeightSum = dot(surfaceHistoryWeights, vec4(1.0));
		float inverseSurfaceHistoryWeight;
		if (surfaceHistoryWeightSum < 9.9999997473787516355514526367188e-05) {
			inverseSurfaceHistoryWeight = 0.0;
#endif
		} else {
#if !NRD_REFLECTION
			inverseHistoryWeightSum = 1.0 / surfaceHistoryWeightSum;
#else
			inverseSurfaceHistoryWeight = 1.0 / surfaceHistoryWeightSum;
#endif
		}
#if !NRD_REFLECTION
		float reprojectedFrameCount = ((((roundEven((historyStateTopLeft.xy * 63.0).xy).x * historyWeightTopLeft) + (roundEven((historyStateTopRight.xy * 63.0).xy).x * historyWeightTopRight)) + (roundEven((historyStateBottomLeft.xy * 63.0).xy).x * historyWeightBottomLeft)) + (roundEven((historyStateBottomRight.xy * 63.0).xy).x * historyWeightBottomRight)) * inverseHistoryWeightSum;
#else
		float surfaceReprojectedFrameCount = ((((roundEven((surfaceHistoryStateTopLeft.xy * 63.0).xy).y * surfaceHistoryWeightTopLeft) + (roundEven((surfaceHistoryStateTopRight.xy * 63.0).xy).y * surfaceHistoryWeightTopRight)) + (roundEven((surfaceHistoryStateBottomLeft.xy * 63.0).xy).y * surfaceHistoryWeightBottomLeft)) + (roundEven((surfaceHistoryStateBottomRight.xy * 63.0).xy).y * surfaceHistoryWeightBottomRight)) * inverseSurfaceHistoryWeight;
#endif
		vec3 previousViewDirectionWorld;
		if (isPerspective) {
			previousViewDirectionWorld = normalize(vec4(reblurCameraDelta(), 0.0).xyz - previousPositionWorld);
		} else {
			previousViewDirectionWorld = vec4(reblurViewDirection(true), 0.0).xyz;
		}
		float normalDotViewRatio = (abs(dot(surfaceNormalWorld, previousViewDirectionWorld)) + 0.001000000047497451305389404296875) / (absNormalDotView + 0.001000000047497451305389404296875);
#if !NRD_REFLECTION
		reblurStore_out_history_flags(ivec2(out_pix), uvec4(uint(asvgfHistoryValid)));
		float confidenceAdjustedFrameCount = reprojectedFrameCount * mix(sqrt(clamp(mix(mix(validHistoryUpperLeft.z, validHistoryUpperRight.y, bilinearRightWeight), mix(validHistoryLowerLeft.y, validHistoryLowerRight.x, bilinearRightWeight), bilinearBottomWeight), 0.0, 1.0)) * mix(0.100000001490116119384765625, 1.0, clamp(normalDotViewRatio * normalDotViewRatio, 0.0, 1.0)), 1.0, 1.0 / (1.0 + reprojectedFrameCount));
#else
		float surfaceConfidenceAdjustedFrameCount = surfaceReprojectedFrameCount * mix(sqrt(clamp(mix(mix(surfaceValidUpperLeft.z, surfaceValidUpperRight.y, surfaceRightWeight), mix(surfaceValidLowerLeft.y, surfaceValidLowerRight.x, surfaceRightWeight), surfaceBottomWeight), 0.0, 1.0)) * mix(0.100000001490116119384765625, 1.0, clamp(normalDotViewRatio * normalDotViewRatio, 0.0, 1.0)), 1.0, 1.0 / (1.0 + surfaceReprojectedFrameCount));
#endif
		vec4 currentRadiance = reblurFetch_work(ivec2(out_pix));
#if !NRD_REFLECTION
		// Use five-fetch Catmull-Rom only when the full footprint is valid; otherwise bilinear.
#else
		float cameraDistance = length(positionWorld);
		float motionFrameRateScale = ubo.ubo.reblur_frame_rate_scale[REBLUR_SIGNAL] * 0.75;
		float surfaceMotionMagnitude = clamp((length((surfaceMotionUv - pixelUv) * ubo.ubo.reblur_rect_size[REBLUR_SIGNAL].xy) * motionFrameRateScale) * 4.0, 0.0, 1.0);
		float surfaceCurrentFrameWeight = 1.0 / (1.0 + surfaceConfidenceAdjustedFrameCount);
		float currentHitDistance = currentRadiance.w;
		float clampedAdjustedRoughness = clamp(normalVarianceAdjustedRoughness, 0.0, 1.0);
		float surfaceLobeAngle = spvNMax(atan((((clampedAdjustedRoughness * 1.7320473194122314453125) * mix(absNormalDotView, 1.0, normalVarianceAdjustedRoughness)) * surfaceCurrentFrameWeight) / (clamp((mix(reblurLinear_prev_temporal_history(surfaceMotionUv * ubo.ubo.reblur_resolution_scale_prev[REBLUR_SIGNAL].xy).w, currentHitDistance, surfaceCurrentFrameWeight) * hitDistanceNormalization) / frustumSize, 0.0, 1.0) + 9.9999999747524270787835121154785e-07)), 0.00294117652811110019683837890625);
		float surfaceHistoryConfidence = mix(pow(clamp(clamp(((atan(((motionFrameRateScale * maxSurfaceParallaxPixels) * pixelWorldSize) / cameraDistance) * mix(0.100000001490116119384765625, 1.0, surfaceMotionMagnitude)) - surfaceLobeAngle) / (-surfaceLobeAngle), 0.0, 1.0), 0.0, 1.0), 4.0), 1.0, clamp((normalVarianceAdjustedRoughness - 0.800000011920928955078125) * 10.000003814697265625, 0.0, 1.0));
		float responsiveRoughness = clamp(spvNMax(normalVarianceAdjustedRoughness, 0.001000000047497451305389404296875) * ubo.ubo.reblur_responsive_accumulation_inv_roughness_threshold[REBLUR_SIGNAL], 0.0, 1.0);
		float responsiveRoughnessSmooth = (responsiveRoughness * responsiveRoughness) * (3.0 - (responsiveRoughness * 2.0));
		float responsiveHitDistanceFactor = (1.0 - exp2(((-200.0) * normalVarianceAdjustedRoughness) * normalVarianceAdjustedRoughness)) * pow(clampedAdjustedRoughness, 0.25);
		vec2 normalLimitedFrameCounts = spvNMax(vec2(ubo.ubo.reblur_max_accumulated_frame_num[REBLUR_SIGNAL]) * (pow(clamp(vec2(mix(mix(surfaceNormalDotTopLeft, surfaceNormalDotTopRight, surfaceRightWeight), mix(surfaceNormalDotBottomLeft, surfaceNormalDotBottomRight, surfaceRightWeight), surfaceBottomWeight), surfaceNormalDotTopLeft), vec2(0.0), vec2(1.0)), vec2(mix(32.0, 1.0, responsiveHitDistanceFactor) * (1.0 - responsiveRoughnessSmooth))) * mix(responsiveHitDistanceFactor, 1.0, responsiveRoughnessSmooth)), vec2(float(ubo.ubo.reblur_responsive_accumulation_min_accumulated_frame_num[REBLUR_SIGNAL])));
		vec2 confidenceLimitedFrameCounts = vec2(surfaceHistoryConfidence, surfaceHistoryConfidence) * ubo.ubo.reblur_max_accumulated_frame_num[REBLUR_SIGNAL];
		vec2 historyFixFrameCountLimits = spvNMin(confidenceLimitedFrameCounts, spvNMax(normalLimitedFrameCounts, vec2(ubo.ubo.reblur_history_fix_frame_num[REBLUR_SIGNAL])));
		vec2 historyFrameCountLimits = spvNMin(confidenceLimitedFrameCounts, normalLimitedFrameCounts);
		float surfaceFrameCount = spvNMin(surfaceConfidenceAdjustedFrameCount, historyFrameCountLimits.x);
#endif
		vec4 reprojectedHistoryYCoCg = asvgfHistoryValid ? imageLoad(PREV_TEMPORAL_HISTORY_IMAGE,ivec2(asvgfDonor)) : vec4(0.0);
		ivec2 fastHistoryPixelOrigin = ivec2(asvgfDonor);
#if NRD_REFLECTION
		float bilinearHistoryWeightSum = dot(surfaceHistoryWeights, vec4(1.0));
#endif
		float reprojectedFastLuminance;
#if !NRD_REFLECTION
		if (hasNoHistoryWeight) {
#else
		if (bilinearHistoryWeightSum < 9.9999997473787516355514526367188e-05) {
#endif
			reprojectedFastLuminance = 0.0;
		} else {
#if !NRD_REFLECTION
			reprojectedFastLuminance = ((((reblurFetch_prev_temporal_fast(fastHistoryPixelOrigin).x * historyWeightTopLeft) + (reblurFetch_prev_temporal_fast((fastHistoryPixelOrigin)+(ivec2(1, 0))).x * historyWeightTopRight)) + (reblurFetch_prev_temporal_fast((fastHistoryPixelOrigin)+(ivec2(0, 1))).x * historyWeightBottomLeft)) + (reblurFetch_prev_temporal_fast((fastHistoryPixelOrigin)+(ivec2(1))).x * historyWeightBottomRight)) / surfaceHistoryWeightSum;
#else
			reprojectedFastLuminance = ((((reblurFetch_prev_temporal_fast(fastHistoryPixelOrigin).x * surfaceHistoryWeights.x) + (reblurFetch_prev_temporal_fast((fastHistoryPixelOrigin)+(ivec2(1, 0))).x * surfaceHistoryWeights.y)) + (reblurFetch_prev_temporal_fast((fastHistoryPixelOrigin)+(ivec2(0, 1))).x * surfaceHistoryWeights.z)) + (reblurFetch_prev_temporal_fast((fastHistoryPixelOrigin)+(ivec2(1))).x * surfaceHistoryWeights.w)) / bilinearHistoryWeightSum;
#endif
		}
#if !NRD_REFLECTION
		// Decode history, accumulate radiance/hit distance, then apply firefly suppression.
#endif
		float historyYMinusCg = reprojectedHistoryYCoCg.x - reprojectedHistoryYCoCg.z;
		vec3 historyRadianceRgb = spvNMax(vec3(historyYMinusCg + reprojectedHistoryYCoCg.y, reprojectedHistoryYCoCg.x + reprojectedHistoryYCoCg.z, historyYMinusCg - reprojectedHistoryYCoCg.y), vec3(0.0)).xyz;
		float historyLuminance = dot(historyRadianceRgb, vec3(0.25, 0.5, 0.25));
		float historyNormalizedHitDistance = clamp(reprojectedHistoryYCoCg.w, 0.0, 1.0);
#if NRD_REFLECTION
		float confidenceAdjustedFrameCount = surfaceFrameCount;
#endif
		float currentFrameWeight = 1.0 / (1.0 + confidenceAdjustedFrameCount);
		vec3 accumulatedRadianceYCoCg = mix(vec3(historyLuminance, dot(historyRadianceRgb, vec3(0.5, 0.0, -0.5)), dot(historyRadianceRgb, vec3(-0.25, 0.5, -0.25))).xyz, currentRadiance.xyz, vec3(currentFrameWeight));
#if !NRD_REFLECTION
		float accumulatedHitDistance = mix(historyNormalizedHitDistance, currentRadiance.w, spvNMax(currentFrameWeight, 1.0 / (1.0 + (0.5 * ubo.ubo.reblur_max_accumulated_frame_num[REBLUR_SIGNAL]))));
#else
		float accumulatedHitDistance = mix(historyNormalizedHitDistance, currentHitDistance, spvNMax(currentFrameWeight, 1.0 / (1.0 + ((0.5 * (roughnessHitDistanceCurve * pow(clampedRoughness, 0.25))) * ubo.ubo.reblur_max_accumulated_frame_num[REBLUR_SIGNAL]))));
#endif
		float accumulatedFrameCount = confidenceAdjustedFrameCount + 1.0;
		float fireflySuppressionSpeed = (confidenceAdjustedFrameCount * ubo.ubo.reblur_max_blur_radius[REBLUR_SIGNAL]) * 0.100000001490116119384765625;
		float fireflySuppressionStrength = fireflySuppressionSpeed / (1.0 + fireflySuppressionSpeed);
		float accumulatedLuminance = accumulatedRadianceYCoCg.x;
		float fireflyLuminanceLimit = historyLuminance * (ubo.ubo.reblur_firefly_suppressor_min_relative_scale[REBLUR_SIGNAL] + (38.0 / accumulatedFrameCount));
		vec3 suppressedRadianceYCoCg = accumulatedRadianceYCoCg.xyz * (mix(accumulatedLuminance, spvNMin(accumulatedLuminance, fireflyLuminanceLimit), fireflySuppressionStrength) / spvNMax(accumulatedLuminance, 9.9999999747524270787835121154785e-07));
#if !NRD_REFLECTION
		vec4 outputRadianceAndHitDistance = vec4(suppressedRadianceYCoCg.x, suppressedRadianceYCoCg.y, suppressedRadianceYCoCg.z, 0.0);
#else
		vec4 outputRadianceAndHitDistance = vec4(suppressedRadianceYCoCg.x, suppressedRadianceYCoCg.y, suppressedRadianceYCoCg.z, unusedRadiancePadding.w);
#endif
		outputRadianceAndHitDistance.w = mix(accumulatedHitDistance, spvNMin(accumulatedHitDistance, historyNormalizedHitDistance * (1.2000000476837158203125 + (1.0 / accumulatedFrameCount))), fireflySuppressionStrength);
		reblurStore_out_radiance(ivec2(out_pix),outputRadianceAndHitDistance);
#if !NRD_REFLECTION
		float accumulatedFastLuminance = mix(spvNMax(reprojectedFastLuminance, 0.0), currentRadiance.x, 1.0 / (1.0 + spvNMin(confidenceAdjustedFrameCount, ubo.ubo.reblur_max_fast_accumulated_frame_num[REBLUR_SIGNAL])));
#else
		float fastHistoryFrameCountLimit;
		if (isStrandMaterial) {
			fastHistoryFrameCountLimit = spvNMax(ubo.ubo.reblur_max_fast_accumulated_frame_num[REBLUR_SIGNAL], ubo.ubo.reblur_max_accumulated_frame_num[REBLUR_SIGNAL] * 0.20000000298023223876953125);
		} else {
			fastHistoryFrameCountLimit = ubo.ubo.reblur_max_fast_accumulated_frame_num[REBLUR_SIGNAL];
		}
		float accumulatedFastLuminance = mix(spvNMax(reprojectedFastLuminance, 0.0), currentRadiance.x, spvNMax(1.0 - surfaceHistoryConfidence, 1.0 / (1.0 + spvNMin(confidenceAdjustedFrameCount, fastHistoryFrameCountLimit))));
#endif
		reblurStore_out_fast_luma(ivec2(out_pix),vec4(mix(accumulatedFastLuminance, spvNMin(accumulatedFastLuminance, fireflyLuminanceLimit * 4.0), fireflySuppressionStrength)));
#if !NRD_REFLECTION
		float unusedSpecularFrameCount = roundEven(0.0);
		reblurStore_out_frame_counts(ivec2(out_pix),vec2(clamp(roundEven(confidenceAdjustedFrameCount) * 0.01587301678955554962158203125, 0.0, 1.0), clamp(unusedSpecularFrameCount * 0.01587301678955554962158203125, 0.0, 1.0)).xyyy);
#else
		reblurStore_out_history_flags(ivec2(out_pix), uvec4(uint(asvgfHistoryValid)));
		float packedAccumulatedFrames = clamp(roundEven(spvNMin(surfaceConfidenceAdjustedFrameCount, historyFixFrameCountLimits.x)) * 0.01587301678955554962158203125, 0.0, 1.0);
		vec2 packedAccumulationData = vec2(unusedAccumulationPadding, packedAccumulatedFrames);
		packedAccumulationData.x = packedAccumulatedFrames;
		reblurStore_out_frame_counts(ivec2(out_pix),packedAccumulationData.xyyy);
#endif
		break;
	} while(false);
}
