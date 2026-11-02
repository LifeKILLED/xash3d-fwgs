/* REBLUR math derived from NVIDIA NRD 4.18; LICENSE.NVIDIA.txt applies. */
#include "cpu.h"
#include <cstdint>
#include <cstddef>
#include <cstring>
#include "../shaders/ray_interop.h"
#undef vec2
#undef mat4
extern "C" {
#include "../vk_math.h"
}
#define NRD_VERSION_MAJOR 4
#define NRD_VERSION_MINOR 18
#include "vendor/NRD/NRDSettings.h"
using namespace nrd;

// UBO inputs are column-major; the ported REBLUR parameters expect row-major.
static void reblurStoreMatrix(matrix4x4 destination,const matrix4x4 value) {
 Matrix4x4_Copy(destination,value);
}

template<class T,size_t N,class... V>
static void reblurStoreVector(T (&destination)[N],V... values) {
 static_assert(sizeof...(values)<=N,"REBLUR vector exceeds its UBO field");
 const T data[N]={static_cast<T>(values)...};
 memcpy(destination,data,sizeof(data));
}

static void reblurFrustum(const matrix4x4 projection,vec4_t frustum) {
 // Side-plane intercepts for the renderer's perspective projection.
 const float x0=(projection[3][2]+projection[0][2])/(projection[3][0]+projection[0][0]);
 const float x1=(projection[3][2]-projection[0][2])/(projection[3][0]-projection[0][0]);
 const float y0=(projection[3][2]+projection[1][2])/(projection[3][1]+projection[1][1]);
 const float y1=(projection[3][2]-projection[1][2])/(projection[3][1]-projection[1][1]);
 Vector4Set(frustum,-x0,-y1,x0-x1,y1-y0);
}

static void reblurRotator(vec4_t rotator,float phase,unsigned frame,float offset) {
 const float value=phase+(float)(frame*10368889u)/16777216.0f;
 float sine,cosine;
 SinCos((value-floorf(value))*DEG2RAD(90.0f)+offset,&sine,&cosine);
 Vector4Set(rotator,cosine,sine,-sine,cosine);
}

static void halfProjection(matrix4x4 projection,unsigned width,unsigned height) {
 float scaleX=(float)width/(2*(width/2)),scaleY=(float)height/(2*(height/2));
 float biasX=scaleX-1.0f+0.5f/(width/2),biasY=scaleY-1.0f+0.5f/(height/2);
 for(unsigned column=0;column<4;column++) {
  projection[0][column]=projection[0][column]*scaleX+projection[3][column]*biasX;
  projection[1][column]=projection[1][column]*scaleY+projection[3][column]*biasY;
 }
}

extern "C" void R_VkReblurPrepare(UniformBuffer *ubo,unsigned signal,unsigned previousWidth,
 unsigned previousHeight,float deltaMilliseconds,int reset) {
 ReblurSettings settings;
 settings.hitDistanceParameters.A=118.11024f;
 unsigned rectW=ubo->res[0],rectH=ubo->res[1],rectWprev=previousWidth,rectHprev=previousHeight;
 matrix4x4 viewToClip,viewToClipPrev,worldToView,worldToViewPrev;
 matrix4x4 viewToWorld,viewToWorldPrev,worldToClip,worldToClipPrev,worldPrevToWorld;
 Matrix4x4_FromArrayFloatGL(viewToClip,&ubo->proj[0][0]);
 Matrix4x4_FromArrayFloatGL(viewToClipPrev,&ubo->prev_proj[0][0]);
 Matrix4x4_FromArrayFloatGL(worldToView,&ubo->view[0][0]);
 Matrix4x4_FromArrayFloatGL(worldToViewPrev,&ubo->prev_view[0][0]);
 if(signal==0) {
  halfProjection(viewToClip,rectW,rectH);halfProjection(viewToClipPrev,rectWprev,rectHprev);
  rectW/=2;rectH/=2;rectWprev/=2;rectHprev/=2;
 }
 for(unsigned column=0;column<4;column++) {
  viewToClip[1][column]*=-1.0f;viewToClipPrev[1][column]*=-1.0f;
 }
 const unsigned resourceW=rectW,resourceH=rectH,resourceWprev=rectWprev,resourceHprev=rectHprev;
 // Xash perspective projections have clip.w = -view.z before LH conversion.
 if(viewToClip[3][2]<0.0f) {
  for(unsigned i=0;i<4;i++) {
   viewToClip[i][2]*=-1.0f;viewToClipPrev[i][2]*=-1.0f;
   worldToView[2][i]*=-1.0f;worldToViewPrev[2][i]*=-1.0f;
  }
 }
 Matrix4x4_Invert_Simple(viewToWorld,worldToView);
 Matrix4x4_Invert_Simple(viewToWorldPrev,worldToViewPrev);
 vec3_t cameraPosition,cameraPositionPrev,cameraDelta,viewDirection,viewDirectionPrev;
 for(unsigned i=0;i<3;i++) {
  cameraPosition[i]=viewToWorld[i][3];cameraPositionPrev[i]=viewToWorldPrev[i][3];
  viewDirection[i]=-viewToWorld[i][2];viewDirectionPrev[i]=-viewToWorldPrev[i][2];
 }
 VectorSubtract(cameraPositionPrev,cameraPosition,cameraDelta);
 for(unsigned i=0;i<3;i++) {
  viewToWorld[i][3]=0.0f;viewToWorldPrev[i][3]=cameraDelta[i];
 }
 Matrix4x4_Invert_Simple(worldToView,viewToWorld);
 Matrix4x4_Invert_Simple(worldToViewPrev,viewToWorldPrev);
 Matrix4x4_Concat(worldToClip,viewToClip,worldToView);
 Matrix4x4_Concat(worldToClipPrev,viewToClipPrev,worldToViewPrev);
 Matrix4x4_LoadIdentity(worldPrevToWorld);
 vec4_t frustum,frustumPrev,rotatorPre,rotator,rotatorPost;
 reblurFrustum(viewToClip,frustum);reblurFrustum(viewToClipPrev,frustumPrev);
 const float projectY=fabsf(viewToClip[1][1]);
 const float orthoMode=0.0f;
 reblurRotator(rotatorPre,1.0f/sqrtf(2.0f),ubo->frame_counter,0.0f);
 reblurRotator(rotator,1.0f/sqrtf(3.0f),ubo->frame_counter,0.0f);
 reblurRotator(rotatorPost,1.0f/sqrtf(3.0f),ubo->frame_counter,DEG2RAD(22.5f));
 static float smoothedMilliseconds[2]={16.66f,16.66f};
 float &timeDeltaSmoothed=smoothedMilliseconds[signal];
 float timeDelta=Q_max(deltaMilliseconds,0.1f);
 if(reset) timeDeltaSmoothed=timeDelta;
 else timeDeltaSmoothed+=(timeDelta-timeDeltaSmoothed)/(1.0f+200.0f/timeDeltaSmoothed);
 float frameRateScale=bound(0.25f,16.66f/timeDelta,4.0f);
 float frameRateScaleSmoothed=bound(0.25f,16.66f/timeDeltaSmoothed,4.0f);
 float jitterDelta=0.0f;
 float speed=frameRateScale*15.0f;
 float checkerboardResolveAccumSpeed=speed/(1.0f+speed);
 float splitScreenPrev=0.0f;

    bool isRectChanged = rectW != rectWprev || rectH != rectHprev;
    bool isHistoryReset = reset != 0;
    float unproject = 1.0f / (0.5f * rectH * projectY);
    float worstResolutionScale = Q_min(float(rectW) / float(resourceW), float(rectH) / float(resourceH));
    float maxBlurRadius = settings.maxBlurRadius * worstResolutionScale;
    float diffusePrepassBlurRadius = settings.diffusePrepassBlurRadius * worstResolutionScale;
    float specularPrepassBlurRadius = settings.specularPrepassBlurRadius * worstResolutionScale;
    float disocclusionThresholdBonus = (1.0f + jitterDelta) / float(rectH);
    float stabilizationStrength = settings.maxStabilizedFrameNum / (1.0f + settings.maxStabilizedFrameNum);
    uint32_t maxAccumulatedFrameNum = Q_min(settings.maxAccumulatedFrameNum, REBLUR_MAX_HISTORY_FRAME_NUM);

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
    memcpy(ubo->reblur_rotator_pre[signal],rotatorPre,sizeof(rotatorPre));
    memcpy(ubo->reblur_rotator[signal],rotator,sizeof(rotator));
    memcpy(ubo->reblur_rotator_post[signal],rotatorPost,sizeof(rotatorPost));
    memcpy(ubo->reblur_frustum[signal],frustum,sizeof(frustum));
    memcpy(ubo->reblur_frustum_prev[signal],frustumPrev,sizeof(frustumPrev));
    reblurStoreVector(ubo->reblur_camera_delta[signal], cameraDelta[0], cameraDelta[1], cameraDelta[2], 0.0f);
    reblurStoreVector(ubo->reblur_hit_dist_settings[signal], settings.hitDistanceParameters.A, settings.hitDistanceParameters.B, settings.hitDistanceParameters.C, 0.0f);
    reblurStoreVector(ubo->reblur_view_vector_world[signal], viewDirection[0], viewDirection[1], viewDirection[2], 0.0f);
    reblurStoreVector(ubo->reblur_view_vector_world_prev[signal], viewDirectionPrev[0], viewDirectionPrev[1], viewDirectionPrev[2], 0.0f);
    reblurStoreVector(ubo->reblur_mv_scale[signal], 1.0f, 1.0f, 1.0f, true ? 1.0f : 0.0f);
    reblurStoreVector(ubo->reblur_mv_bias[signal], 0.0f, 0.0f, 0.0f, 0.0f);
    reblurStoreVector(ubo->reblur_convergence_settings[signal], settings.convergenceSettings.s, settings.convergenceSettings.b, settings.convergenceSettings.p, 0.0f);
    reblurStoreVector(ubo->reblur_antilag_settings[signal], settings.antilagSettings.luminanceSigmaScale, settings.antilagSettings.luminanceSensitivity);
    reblurStoreVector(ubo->reblur_resource_size[signal], float(resourceW), float(resourceH));
    reblurStoreVector(ubo->reblur_resource_size_inv[signal], 1.0f / float(resourceW), 1.0f / float(resourceH));
    reblurStoreVector(ubo->reblur_resource_size_inv_prev[signal], 1.0f / float(resourceWprev), 1.0f / float(resourceHprev));
    reblurStoreVector(ubo->reblur_rect_size[signal], float(rectW), float(rectH));
    reblurStoreVector(ubo->reblur_rect_size_inv[signal], 1.0f / float(rectW), 1.0f / float(rectH));
    reblurStoreVector(ubo->reblur_rect_size_prev[signal], float(rectWprev), float(rectHprev));
    reblurStoreVector(ubo->reblur_resolution_scale[signal], float(rectW) / float(resourceW), float(rectH) / float(resourceH));
    reblurStoreVector(ubo->reblur_resolution_scale_prev[signal], float(rectWprev) / float(resourceWprev), float(rectHprev) / float(resourceHprev));
    reblurStoreVector(ubo->reblur_jitter[signal], 0.0f, 0.0f);
    reblurStoreVector(ubo->reblur_printf_at[signal], 9999u, 9999u);
    reblurStoreVector(ubo->reblur_input_rect_origin[signal], 0, 0);
    reblurStoreVector(ubo->reblur_output_rect_origin[signal], 0, 0);
    reblurStoreVector(ubo->reblur_dispatch_input_rect_origin[signal], 0, 0);
    reblurStoreVector(ubo->reblur_dispatch_output_rect_origin[signal], 0, 0);
    reblurStoreVector(ubo->reblur_rect_size_minus_one[signal], rectW - 1, rectH - 1);
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
    ubo->reblur_max_blur_radius[signal] = Q_max(maxBlurRadius, settings.minBlurRadius);
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
    ubo->reblur_fast_history_clamping_sigma_scale[signal] = 3.0f + (settings.fastHistoryClampingSigmaScale - 3.0f) * bound(0.0f, Q_max(maxBlurRadius, settings.minBlurRadius) / 2.0f, 1.0f);
    ubo->reblur_min_rect_dim_mul_unproject[signal] = (float)Q_min(rectW, rectH) * unproject;
    ubo->reblur_use_prepass_not_only_for_specular_motion_estimation[signal] = settings.usePrepassOnlyForSpecularMotionEstimation ? 0.0f : 1.0f;
    ubo->reblur_split_screen[signal] = 0.0f;
    ubo->reblur_split_screen_prev[signal] = splitScreenPrev;
    ubo->reblur_checkerboard_resolve_accum_speed[signal] = checkerboardResolveAccumSpeed;
    ubo->reblur_view_z_scale[signal] = 1.0f;
    ubo->reblur_firefly_suppressor_min_relative_scale[signal] = settings.fireflySuppressorMinRelativeScale;
    ubo->reblur_min_hit_distance_weight[signal] = settings.minHitDistanceWeight;
    ubo->reblur_diff_min_material[signal] = settings.minMaterialForDiffuse;
    ubo->reblur_spec_min_material[signal] = settings.minMaterialForSpecular;
    ubo->reblur_responsive_accumulation_inv_roughness_threshold[signal] = 1.0f / Q_max(settings.responsiveAccumulationSettings.roughnessThreshold, 1e-3f);
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
