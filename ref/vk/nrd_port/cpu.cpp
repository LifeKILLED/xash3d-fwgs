/* REBLUR math derived from NVIDIA NRD 4.18; LICENSE.NVIDIA.txt applies. */
#include "cpu.h"
#include <cstdint>
#include <cstddef>
#include <cstring>
#include "../shaders/ray_interop.h"
#undef vec2
#undef mat4
#ifdef _MSC_VER
#include <intrin.h>
#endif
#define NRD_VERSION_MAJOR 4
#define NRD_VERSION_MINOR 18
#include "vendor/NRD/NRDSettings.h"
// MathLib remaps SIMD intrinsics; platform headers must precede it.
#include "vendor/MathLib/ml.h"
#include "vendor/MathLib/ml.hlsli"
using namespace nrd;

static float4x4 reblurLoadMatrix(const matrix4x4 source) {
 const float *p=&source[0][0];
 return float4x4(float4(p),float4(p+4),float4(p+8),float4(p+12));
}
static void reblurStoreMatrix(matrix4x4 destination,float4x4 value) {
 // Preserve the row-major interpretation used by the ported shader arithmetic.
 value.Transpose();memcpy(destination,value.a,64);
}
template<class T,size_t N,class V>
static void reblurStoreVector(T (&destination)[N],const V& value) {
 static_assert(sizeof(value)<=sizeof(destination),"REBLUR vector exceeds its UBO field");
 memcpy(destination,&value,sizeof(value));
}

static void halfProjection(float *projection,unsigned width,unsigned height) {
 float scaleX=(float)width/(2*(width/2)),scaleY=(float)height/(2*(height/2));
 float biasX=scaleX-1.0f+0.5f/(width/2),biasY=scaleY-1.0f+0.5f/(height/2);
 for(unsigned column=0;column<4;column++) {
  projection[column*4]=projection[column*4]*scaleX+projection[column*4+3]*biasX;
  projection[column*4+1]=projection[column*4+1]*scaleY+projection[column*4+3]*biasY;
 }
}

extern "C" void R_VkReblurPrepare(UniformBuffer *ubo,unsigned signal,unsigned previousWidth,
 unsigned previousHeight,float deltaMilliseconds,int reset) {
 ReblurSettings settings;
 settings.hitDistanceParameters.A=118.11024f;
 unsigned rectW=ubo->res[0],rectH=ubo->res[1],rectWprev=previousWidth,rectHprev=previousHeight;
 float4x4 viewToClip=reblurLoadMatrix(ubo->proj),viewToClipPrev=reblurLoadMatrix(ubo->prev_proj);
 if(signal==0) {
  halfProjection(viewToClip.a,rectW,rectH);halfProjection(viewToClipPrev.a,rectWprev,rectHprev);
  rectW/=2;rectH/=2;rectWprev/=2;rectHprev/=2;
 }
 for(unsigned column=0;column<4;column++) {viewToClip.a[column*4+1]*=-1.0f;viewToClipPrev.a[column*4+1]*=-1.0f;}
 unsigned resourceW=rectW,resourceH=rectH,resourceWprev=rectWprev,resourceHprev=rectHprev;
 float4x4 worldToView=reblurLoadMatrix(ubo->view),worldToViewPrev=reblurLoadMatrix(ubo->prev_view);
 float4x4 viewToWorld,viewToWorldPrev,worldToClip,worldToClipPrev;
 float4x4 worldPrevToWorld=float4x4::Identity();
 float4 frustum=float4::Zero(),frustumPrev=float4::Zero();
 float3 viewDirection,viewDirectionPrev,cameraDelta;
 float projectY,orthoMode;
 float anglePre=Sequence::Weyl1D(1.0f/sqrt(2.0f),ubo->frame_counter);
 float angle=Sequence::Weyl1D(1.0f/sqrt(3.0f),ubo->frame_counter);
 float4 rotatorPre=Geometry::GetRotator(anglePre*radians(90.0f));
 float4 rotator=Geometry::GetRotator(angle*radians(90.0f));
 float4 rotatorPost=Geometry::GetRotator(angle*radians(90.0f)+radians(22.5f));
    // Convert to LH
    uint32_t flags = 0;
    DecomposeProjection(STYLE_D3D, STYLE_D3D, viewToClip, &flags, nullptr, nullptr, frustum.a, nullptr, nullptr);

    if (!(flags & PROJ_LEFT_HANDED)) {
        viewToClip[2] = -viewToClip[2];
        viewToClipPrev[2] = -viewToClipPrev[2];

        worldToView.Transpose();
        worldToView[2] = -worldToView[2];
        worldToView.Transpose();

        worldToViewPrev.Transpose();
        worldToViewPrev[2] = -worldToViewPrev[2];
        worldToViewPrev.Transpose();
    }

    // Compute other matrices
    viewToWorld = worldToView;
    viewToWorld.InvertOrtho();

    viewToWorldPrev = worldToViewPrev;
    viewToWorldPrev.InvertOrtho();

    const float3& cameraPosition = viewToWorld[3].xyz;
    const float3& cameraPositionPrev = viewToWorldPrev[3].xyz;
    float3 translationDelta = cameraPositionPrev - cameraPosition;

    // IMPORTANT: this part is mandatory needed to preserve precision by making matrices camera relative
    viewToWorld.SetTranslation(float3::Zero());
    worldToView = viewToWorld;
    worldToView.InvertOrtho();

    viewToWorldPrev.SetTranslation(translationDelta);
    worldToViewPrev = viewToWorldPrev;
    worldToViewPrev.InvertOrtho();

    worldToClip = viewToClip * worldToView;
    worldToClipPrev = viewToClipPrev * worldToViewPrev;

    float project[3];
    DecomposeProjection(STYLE_D3D, STYLE_D3D, viewToClip, &flags, nullptr, nullptr, frustum.a, project, nullptr);

    projectY = project[1];
    orthoMode = (flags & PROJ_ORTHO) ? -1.0f : 0.0f;

    DecomposeProjection(STYLE_D3D, STYLE_D3D, viewToClipPrev, &flags, nullptr, nullptr, frustumPrev.a, nullptr, nullptr);

    viewDirection = -float3(viewToWorld[2]);
    viewDirectionPrev = -float3(viewToWorldPrev[2]);

    cameraDelta = float3(translationDelta.x, translationDelta.y, translationDelta.z);
 static float smoothedMilliseconds[2]={16.66f,16.66f};
 float &timeDeltaSmoothed=smoothedMilliseconds[signal];
 float timeDelta=max(deltaMilliseconds,0.1f);
 if(reset) timeDeltaSmoothed=timeDelta;
 else timeDeltaSmoothed+=(timeDelta-timeDeltaSmoothed)/(1.0f+200.0f/timeDeltaSmoothed);
 float frameRateScale=clamp(16.66f/timeDelta,0.25f,4.0f);
 float frameRateScaleSmoothed=clamp(16.66f/timeDeltaSmoothed,0.25f,4.0f);
 float jitterDelta=0.0f;
 float speed=frameRateScale*15.0f;
 float checkerboardResolveAccumSpeed=speed/(1.0f+speed);
 float splitScreenPrev=0.0f;

    bool isRectChanged = rectW != rectWprev || rectH != rectHprev;
    bool isHistoryReset = reset != 0;
    float unproject = 1.0f / (0.5f * rectH * projectY);
    float worstResolutionScale = min(float(rectW) / float(resourceW), float(rectH) / float(resourceH));
    float maxBlurRadius = settings.maxBlurRadius * worstResolutionScale;
    float diffusePrepassBlurRadius = settings.diffusePrepassBlurRadius * worstResolutionScale;
    float specularPrepassBlurRadius = settings.specularPrepassBlurRadius * worstResolutionScale;
    float disocclusionThresholdBonus = (1.0f + jitterDelta) / float(rectH);
    float stabilizationStrength = settings.maxStabilizedFrameNum / (1.0f + settings.maxStabilizedFrameNum);
    uint32_t maxAccumulatedFrameNum = min(settings.maxAccumulatedFrameNum, REBLUR_MAX_HISTORY_FRAME_NUM);

    uint32_t diffCheckerboard = 2;
    uint32_t specCheckerboard = 2;
    switch (settings.checkerboardMode) {
        case CheckerboardMode::BLACK:
            diffCheckerboard = 0;
            specCheckerboard = 1;
            break;
        case CheckerboardMode::WHITE:
            diffCheckerboard = 1;
            specCheckerboard = 0;
            break;
        default:
            break;
    }

    reblurStoreMatrix(ubo->reblur_world_to_clip[signal], worldToClip);
    reblurStoreMatrix(ubo->reblur_view_to_clip[signal], viewToClip);
    reblurStoreMatrix(ubo->reblur_view_to_world[signal], viewToWorld);
    reblurStoreMatrix(ubo->reblur_world_to_view_prev[signal], worldToViewPrev);
    reblurStoreMatrix(ubo->reblur_world_to_clip_prev[signal], worldToClipPrev);
    reblurStoreMatrix(ubo->reblur_world_prev_to_world[signal], worldPrevToWorld);
    reblurStoreVector(ubo->reblur_rotator_pre[signal], rotatorPre);
    reblurStoreVector(ubo->reblur_rotator[signal], rotator);
    reblurStoreVector(ubo->reblur_rotator_post[signal], rotatorPost);
    reblurStoreVector(ubo->reblur_frustum[signal], frustum);
    reblurStoreVector(ubo->reblur_frustum_prev[signal], frustumPrev);
    reblurStoreVector(ubo->reblur_camera_delta[signal], cameraDelta.xmm);
    reblurStoreVector(ubo->reblur_hit_dist_settings[signal], float4(settings.hitDistanceParameters.A, settings.hitDistanceParameters.B, settings.hitDistanceParameters.C, 0.0f));
    reblurStoreVector(ubo->reblur_view_vector_world[signal], viewDirection.xmm);
    reblurStoreVector(ubo->reblur_view_vector_world_prev[signal], viewDirectionPrev.xmm);
    reblurStoreVector(ubo->reblur_mv_scale[signal], float4(1.0f, 1.0f, 1.0f, true ? 1.0f : 0.0f));
    reblurStoreVector(ubo->reblur_mv_bias[signal], float4(0.0f, 0.0f, 0.0f, 0.0f));
    reblurStoreVector(ubo->reblur_convergence_settings[signal], float4(settings.convergenceSettings.s, settings.convergenceSettings.b, settings.convergenceSettings.p, 0.0f));
    reblurStoreVector(ubo->reblur_antilag_settings[signal], float2(settings.antilagSettings.luminanceSigmaScale, settings.antilagSettings.luminanceSensitivity));
    reblurStoreVector(ubo->reblur_resource_size[signal], float2(float(resourceW), float(resourceH)));
    reblurStoreVector(ubo->reblur_resource_size_inv[signal], float2(1.0f / float(resourceW), 1.0f / float(resourceH)));
    reblurStoreVector(ubo->reblur_resource_size_inv_prev[signal], float2(1.0f / float(resourceWprev), 1.0f / float(resourceHprev)));
    reblurStoreVector(ubo->reblur_rect_size[signal], float2(float(rectW), float(rectH)));
    reblurStoreVector(ubo->reblur_rect_size_inv[signal], float2(1.0f / float(rectW), 1.0f / float(rectH)));
    reblurStoreVector(ubo->reblur_rect_size_prev[signal], float2(float(rectWprev), float(rectHprev)));
    reblurStoreVector(ubo->reblur_resolution_scale[signal], float2(float(rectW) / float(resourceW), float(rectH) / float(resourceH)));
    reblurStoreVector(ubo->reblur_resolution_scale_prev[signal], float2(float(rectWprev) / float(resourceWprev), float(rectHprev) / float(resourceHprev)));
    reblurStoreVector(ubo->reblur_jitter[signal], float2(0.0f, 0.0f));
    reblurStoreVector(ubo->reblur_printf_at[signal], uint2(9999u, 9999u));
    reblurStoreVector(ubo->reblur_input_rect_origin[signal], int2(0, 0));
    reblurStoreVector(ubo->reblur_output_rect_origin[signal], int2(0, 0));
    reblurStoreVector(ubo->reblur_dispatch_input_rect_origin[signal], int2(0, 0));
    reblurStoreVector(ubo->reblur_dispatch_output_rect_origin[signal], int2(0, 0));
    reblurStoreVector(ubo->reblur_rect_size_minus_one[signal], int2(rectW - 1, rectH - 1));
    ubo->reblur_disocclusion_threshold[signal] = 0.01f + disocclusionThresholdBonus;
    ubo->reblur_disocclusion_threshold_alternate[signal] = 0.05f + disocclusionThresholdBonus;
    ubo->reblur_camera_attached_reflection_material_id[signal] = 999.0f;
    ubo->reblur_strand_material_id[signal] = 999.0f;
    ubo->reblur_strand_thickness[signal] = 80e-6f;
    ubo->reblur_stabilization_strength[signal] = isHistoryReset ? 0.0f : stabilizationStrength;
    ubo->reblur_debug[signal] = 0.0f;
    ubo->reblur_ortho_mode[signal] = orthoMode;
    ubo->reblur_unproject[signal] = unproject;
    ubo->reblur_denoising_range[signal] = 500000.0f;
    ubo->reblur_plane_dist_sensitivity[signal] = settings.planeDistanceSensitivity;
    ubo->reblur_frame_rate_scale[signal] = frameRateScale;
    ubo->reblur_frame_rate_scale_smoothed[signal] = frameRateScaleSmoothed;
    ubo->reblur_max_blur_radius[signal] = max(maxBlurRadius, settings.minBlurRadius);
    ubo->reblur_min_blur_radius[signal] = settings.minBlurRadius;
    ubo->reblur_diff_prepass_blur_radius[signal] = diffusePrepassBlurRadius;
    ubo->reblur_spec_prepass_blur_radius[signal] = specularPrepassBlurRadius;
    ubo->reblur_max_accumulated_frame_num[signal] = isHistoryReset ? 0 : float(maxAccumulatedFrameNum);
    ubo->reblur_max_fast_accumulated_frame_num[signal] = isHistoryReset ? 0 : float(settings.maxFastAccumulatedFrameNum);
    ubo->reblur_anti_firefly[signal] = settings.enableAntiFirefly ? 1.0f : 0.0f;
    ubo->reblur_lobe_angle_fraction[signal] = settings.lobeAngleFraction * settings.lobeAngleFraction; // TODO: GetSpecularLobeTanHalfAngle has been fixed, but we want to use existing settings
    ubo->reblur_roughness_fraction[signal] = settings.roughnessFraction;
    ubo->reblur_history_fix_frame_num[signal] = (float)settings.historyFixFrameNum;
    ubo->reblur_history_fix_base_pixel_stride[signal] = (float)settings.historyFixBasePixelStride;
    ubo->reblur_history_fix_alternate_pixel_stride[signal] = (float)settings.historyFixAlternatePixelStride;
    ubo->reblur_history_fix_alternate_pixel_stride_material_id[signal] = 999.0f;
    ubo->reblur_fast_history_clamping_sigma_scale[signal] = lerp(3.0f, settings.fastHistoryClampingSigmaScale, saturate(max(maxBlurRadius, settings.minBlurRadius) / 2.0f));
    ubo->reblur_min_rect_dim_mul_unproject[signal] = (float)min(rectW, rectH) * unproject;
    ubo->reblur_use_prepass_not_only_for_specular_motion_estimation[signal] = settings.usePrepassOnlyForSpecularMotionEstimation ? 0.0f : 1.0f;
    ubo->reblur_split_screen[signal] = 0.0f;
    ubo->reblur_split_screen_prev[signal] = splitScreenPrev;
    ubo->reblur_checkerboard_resolve_accum_speed[signal] = checkerboardResolveAccumSpeed;
    ubo->reblur_view_z_scale[signal] = 1.0f;
    ubo->reblur_firefly_suppressor_min_relative_scale[signal] = settings.fireflySuppressorMinRelativeScale;
    ubo->reblur_min_hit_distance_weight[signal] = settings.minHitDistanceWeight;
    ubo->reblur_diff_min_material[signal] = settings.minMaterialForDiffuse;
    ubo->reblur_spec_min_material[signal] = settings.minMaterialForSpecular;
    ubo->reblur_responsive_accumulation_inv_roughness_threshold[signal] = 1.0f / max(settings.responsiveAccumulationSettings.roughnessThreshold, 1e-3f);
    ubo->reblur_responsive_accumulation_min_accumulated_frame_num[signal] = settings.responsiveAccumulationSettings.minAccumulatedFrameNum;
    ubo->reblur_has_history_confidence[signal] = false;
    ubo->reblur_has_disocclusion_threshold_mix[signal] = false;
    ubo->reblur_diff_checkerboard[signal] = diffCheckerboard;
    ubo->reblur_spec_checkerboard[signal] = specCheckerboard;
    ubo->reblur_frame_index[signal] = ubo->frame_counter;
    ubo->reblur_is_rect_changed[signal] = isRectChanged ? 1 : 0;
    ubo->reblur_reset_history[signal] = isHistoryReset ? 1 : 0;
    ubo->reblur_return_history_length_instead_of_occlusion[signal] = settings.returnHistoryLengthInsteadOfOcclusion ? 1 : 0;
 const uint32_t groups8[]={ (rectW+7)/8,(rectH+7)/8,(rectW+7)/8,(rectH+15)/16 };
 const uint32_t groups16[]={ (rectW+15)/16,(rectH+15)/16,0,0 };
 memcpy(ubo->reblur_groups_8x8_8x16[signal],groups8,sizeof(groups8));
 memcpy(ubo->reblur_groups_16x16[signal],groups16,sizeof(groups16));
}
