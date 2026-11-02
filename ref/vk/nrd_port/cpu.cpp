/* CPU constants ported from NVIDIA NRD 4.18; LICENSE.NVIDIA.txt applies. */
#include "cpu.h"
#include <cstdint>
#include <cstddef>
#include <cstring>
#define NRD_VERSION_MAJOR 4
#define NRD_VERSION_MINOR 18
#include "vendor/NRD/NRDSettings.h"
#include "vendor/MathLib/ml.h"
#include "vendor/MathLib/ml.hlsli"
#define NRD_CONSTANT(type,name) type name;
#include "vendor/NRD/REBLUR_Config.hlsli"
using namespace nrd;
struct ReblurConstants { REBLUR_SHARED_CONSTANTS };
static_assert(offsetof(ReblurConstants,gWorldToClip)==0,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gViewToClip)==64,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gViewToWorld)==128,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gWorldToViewPrev)==192,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gWorldToClipPrev)==256,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gWorldPrevToWorld)==320,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gRotatorPre)==384,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gRotator)==400,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gRotatorPost)==416,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gFrustum)==432,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gFrustumPrev)==448,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gCameraDelta)==464,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gHitDistSettings)==480,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gViewVectorWorld)==496,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gViewVectorWorldPrev)==512,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gMvScale)==528,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gMvBias)==544,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gConvergenceSettings)==560,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gAntilagSettings)==576,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gResourceSize)==584,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gResourceSizeInv)==592,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gResourceSizeInvPrev)==600,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gRectSize)==608,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gRectSizeInv)==616,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gRectSizePrev)==624,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gResolutionScale)==632,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gResolutionScalePrev)==640,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gJitter)==648,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gPrintfAt)==656,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gInputRectOrigin)==664,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gOutputRectOrigin)==672,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gDispatchInputRectOrigin)==680,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gDispatchOutputRectOrigin)==688,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gRectSizeMinusOne)==696,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gDisocclusionThreshold)==704,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gDisocclusionThresholdAlternate)==708,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gCameraAttachedReflectionMaterialID)==712,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gStrandMaterialID)==716,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gStrandThickness)==720,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gStabilizationStrength)==724,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gDebug)==728,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gOrthoMode)==732,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gUnproject)==736,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gDenoisingRange)==740,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gPlaneDistSensitivity)==744,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gFrameRateScale)==748,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gFrameRateScaleSmoothed)==752,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gMinBlurRadius)==756,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gMaxBlurRadius)==760,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gDiffPrepassBlurRadius)==764,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gSpecPrepassBlurRadius)==768,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gMaxAccumulatedFrameNum)==772,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gMaxFastAccumulatedFrameNum)==776,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gAntiFirefly)==780,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gLobeAngleFraction)==784,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gRoughnessFraction)==788,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gHistoryFixFrameNum)==792,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gHistoryFixBasePixelStride)==796,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gHistoryFixAlternatePixelStride)==800,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gHistoryFixAlternatePixelStrideMaterialID)==804,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gFastHistoryClampingSigmaScale)==808,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gMinRectDimMulUnproject)==812,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gUsePrepassNotOnlyForSpecularMotionEstimation)==816,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gSplitScreen)==820,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gSplitScreenPrev)==824,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gCheckerboardResolveAccumSpeed)==828,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gViewZScale)==832,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gFireflySuppressorMinRelativeScale)==836,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gMinHitDistanceWeight)==840,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gDiffMinMaterial)==844,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gSpecMinMaterial)==848,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gResponsiveAccumulationInvRoughnessThreshold)==852,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gResponsiveAccumulationMinAccumulatedFrameNum)==856,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gHasHistoryConfidence)==860,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gHasDisocclusionThresholdMix)==864,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gDiffCheckerboard)==868,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gSpecCheckerboard)==872,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gFrameIndex)==876,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gIsRectChanged)==880,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gResetHistory)==884,"constant layout mismatch");
static_assert(offsetof(ReblurConstants,gReturnHistoryLengthInsteadOfOcclusion)==888,"constant layout mismatch");
#define NRD_DECLARE_DIMS \
    uint16_t resourceW = m_CommonSettings.resourceSize[0]; \
    uint16_t resourceH = m_CommonSettings.resourceSize[1]; \
    uint16_t resourceWprev = m_CommonSettings.resourceSizePrev[0]; \
    uint16_t resourceHprev = m_CommonSettings.resourceSizePrev[1]; \
    uint16_t rectW = m_CommonSettings.rectSize[0]; \
    uint16_t rectH = m_CommonSettings.rectSize[1]; \
    uint16_t rectWprev = m_CommonSettings.rectSizePrev[0]; \
    uint16_t rectHprev = m_CommonSettings.rectSizePrev[1];


struct NrdConstants {
    CommonSettings m_CommonSettings = {};
    float4x4 m_ViewToClip = float4x4::Identity();
    float4x4 m_ViewToClipPrev = float4x4::Identity();
    float4x4 m_ClipToView = float4x4::Identity();
    float4x4 m_ClipToViewPrev = float4x4::Identity();
    float4x4 m_WorldToView = float4x4::Identity();
    float4x4 m_WorldToViewPrev = float4x4::Identity();
    float4x4 m_ViewToWorld = float4x4::Identity();
    float4x4 m_ViewToWorldPrev = float4x4::Identity();
    float4x4 m_WorldToClip = float4x4::Identity();
    float4x4 m_WorldToClipPrev = float4x4::Identity();
    float4x4 m_ClipToWorld = float4x4::Identity();
    float4x4 m_ClipToWorldPrev = float4x4::Identity();
    float4x4 m_WorldPrevToWorld = float4x4::Identity();
    float4 m_RotatorPre = float4::Zero();
    float4 m_Rotator = float4::Zero();
    float4 m_RotatorPost = float4::Zero();
    float4 m_Frustum = float4::Zero();
    float4 m_FrustumPrev = float4::Zero();
    float3 m_CameraDelta = float3::Zero();
    float3 m_ViewDirection = float3::Zero();
    float3 m_ViewDirectionPrev = float3::Zero();
    float m_SplitScreenPrev = 0.0f;
    float m_OrthoMode = 0.0f;
    float m_CheckerboardResolveAccumSpeed = 0.0f;
    float m_JitterDelta = 0.0f;
    float m_TimeDelta = 0.0f;
    float m_TimeDeltaSmoothed = 16.66f;
    float m_FrameRateScale = 0.0f;
    float m_FrameRateScaleSmoothed = 1.0f;
    float m_ProjectY = 0.0f;
void AddSharedConstants_Reblur(const ReblurSettings&,void*);
void Prepare(const NrdFrame& f) {
 memcpy(m_CommonSettings.viewToClipMatrix,f.projection,64);
 memcpy(m_CommonSettings.viewToClipMatrixPrev,f.previousProjection,64);
 // Engine UV.y follows clip Y; NRD helpers use D3D UV.y = -clipY * 0.5 + 0.5.
 for(unsigned column=0;column<4;column++) {
  m_CommonSettings.viewToClipMatrix[column*4+1]*=-1.0f;
  m_CommonSettings.viewToClipMatrixPrev[column*4+1]*=-1.0f;
 }
 memcpy(m_CommonSettings.worldToViewMatrix,f.view,64);
 memcpy(m_CommonSettings.worldToViewMatrixPrev,f.previousView,64);
 memcpy(m_CommonSettings.worldPrevToWorldMatrix,float4x4::Identity().a,64);
 m_CommonSettings.isMotionVectorInWorldSpace=true;
 m_CommonSettings.motionVectorScale[0]=m_CommonSettings.motionVectorScale[1]=m_CommonSettings.motionVectorScale[2]=1;
 m_CommonSettings.resourceSize[0]=m_CommonSettings.rectSize[0]=uint16_t(f.width);
 m_CommonSettings.resourceSize[1]=m_CommonSettings.rectSize[1]=uint16_t(f.height);
 m_CommonSettings.resourceSizePrev[0]=m_CommonSettings.rectSizePrev[0]=uint16_t(f.previousWidth);
 m_CommonSettings.resourceSizePrev[1]=m_CommonSettings.rectSizePrev[1]=uint16_t(f.previousHeight);
 m_CommonSettings.frameIndex=f.frame;
 m_CommonSettings.accumulationMode=f.reset?AccumulationMode::RESTART:AccumulationMode::CONTINUE;
 memcpy(m_CommonSettings.cameraJitter,f.jitter,8);
 memcpy(m_CommonSettings.cameraJitterPrev,f.previousJitter,8);
    { // Rotators (respecting sample patterns symmetry)
        // Square roots of primes provide excellent decorrelation for Weyl sequences
        float anglePre = Sequence::Weyl1D(1.0f / sqrt(2.0f), m_CommonSettings.frameIndex);
        float angle = Sequence::Weyl1D(1.0f / sqrt(3.0f), m_CommonSettings.frameIndex);

        // "PostBlur" rotator is rotated to avoid mapping to same directions after "Blur"
        constexpr float minNonSymmetryAngle = 22.5f; // see the kernel: 90 - symmetry angle, 45 - same directions

        m_RotatorPre = Geometry::GetRotator(anglePre * radians(90.0f));
        m_Rotator = Geometry::GetRotator(angle * radians(90.0f));
        m_RotatorPost = Geometry::GetRotator(angle * radians(90.0f) + radians(minNonSymmetryAngle));
    }

    // Main matrices
    m_ViewToClip = float4x4(
        float4(m_CommonSettings.viewToClipMatrix),
        float4(m_CommonSettings.viewToClipMatrix + 4),
        float4(m_CommonSettings.viewToClipMatrix + 8),
        float4(m_CommonSettings.viewToClipMatrix + 12));

    m_ViewToClipPrev = float4x4(
        float4(m_CommonSettings.viewToClipMatrixPrev),
        float4(m_CommonSettings.viewToClipMatrixPrev + 4),
        float4(m_CommonSettings.viewToClipMatrixPrev + 8),
        float4(m_CommonSettings.viewToClipMatrixPrev + 12));

    m_WorldToView = float4x4(
        float4(m_CommonSettings.worldToViewMatrix),
        float4(m_CommonSettings.worldToViewMatrix + 4),
        float4(m_CommonSettings.worldToViewMatrix + 8),
        float4(m_CommonSettings.worldToViewMatrix + 12));

    m_WorldToViewPrev = float4x4(
        float4(m_CommonSettings.worldToViewMatrixPrev),
        float4(m_CommonSettings.worldToViewMatrixPrev + 4),
        float4(m_CommonSettings.worldToViewMatrixPrev + 8),
        float4(m_CommonSettings.worldToViewMatrixPrev + 12));

    m_WorldPrevToWorld = float4x4(
        float4(m_CommonSettings.worldPrevToWorldMatrix),
        float4(m_CommonSettings.worldPrevToWorldMatrix + 4),
        float4(m_CommonSettings.worldPrevToWorldMatrix + 8),
        float4(m_CommonSettings.worldPrevToWorldMatrix + 12));

    // Convert to LH
    uint32_t flags = 0;
    DecomposeProjection(STYLE_D3D, STYLE_D3D, m_ViewToClip, &flags, nullptr, nullptr, m_Frustum.a, nullptr, nullptr);

    if (!(flags & PROJ_LEFT_HANDED)) {
        m_ViewToClip[2] = -m_ViewToClip[2];
        m_ViewToClipPrev[2] = -m_ViewToClipPrev[2];

        m_WorldToView.Transpose();
        m_WorldToView[2] = -m_WorldToView[2];
        m_WorldToView.Transpose();

        m_WorldToViewPrev.Transpose();
        m_WorldToViewPrev[2] = -m_WorldToViewPrev[2];
        m_WorldToViewPrev.Transpose();
    }

    // Compute other matrices
    m_ViewToWorld = m_WorldToView;
    m_ViewToWorld.InvertOrtho();

    m_ViewToWorldPrev = m_WorldToViewPrev;
    m_ViewToWorldPrev.InvertOrtho();

    const float3& cameraPosition = m_ViewToWorld[3].xyz;
    const float3& cameraPositionPrev = m_ViewToWorldPrev[3].xyz;
    float3 translationDelta = cameraPositionPrev - cameraPosition;

    // IMPORTANT: this part is mandatory needed to preserve precision by making matrices camera relative
    m_ViewToWorld.SetTranslation(float3::Zero());
    m_WorldToView = m_ViewToWorld;
    m_WorldToView.InvertOrtho();

    m_ViewToWorldPrev.SetTranslation(translationDelta);
    m_WorldToViewPrev = m_ViewToWorldPrev;
    m_WorldToViewPrev.InvertOrtho();

    m_WorldToClip = m_ViewToClip * m_WorldToView;
    m_WorldToClipPrev = m_ViewToClipPrev * m_WorldToViewPrev;

    m_ClipToWorldPrev = m_WorldToClipPrev;
    m_ClipToWorldPrev.Invert();

    m_ClipToView = m_ViewToClip;
    m_ClipToView.Invert();

    m_ClipToViewPrev = m_ViewToClipPrev;
    m_ClipToViewPrev.Invert();

    m_ClipToWorld = m_WorldToClip;
    m_ClipToWorld.Invert();

    float project[3];
    DecomposeProjection(STYLE_D3D, STYLE_D3D, m_ViewToClip, &flags, nullptr, nullptr, m_Frustum.a, project, nullptr);

    m_ProjectY = project[1];
    m_OrthoMode = (flags & PROJ_ORTHO) ? -1.0f : 0.0f;

    DecomposeProjection(STYLE_D3D, STYLE_D3D, m_ViewToClipPrev, &flags, nullptr, nullptr, m_FrustumPrev.a, nullptr, nullptr);

    m_ViewDirection = -float3(m_ViewToWorld[2]);
    m_ViewDirectionPrev = -float3(m_ViewToWorldPrev[2]);

    m_CameraDelta = float3(translationDelta.x, translationDelta.y, translationDelta.z);


 m_FrameRateScale=clamp(16.66f/max(f.deltaMilliseconds,0.1f),0.25f,4.0f);
 if(f.reset) m_TimeDeltaSmoothed=max(f.deltaMilliseconds,0.1f);
 else m_TimeDeltaSmoothed+=(max(f.deltaMilliseconds,0.1f)-m_TimeDeltaSmoothed)/(1.0f+200.0f/m_TimeDeltaSmoothed);
 m_FrameRateScaleSmoothed=clamp(16.66f/m_TimeDeltaSmoothed,0.25f,4.0f);
 m_JitterDelta=max(abs(f.jitter[0]-f.previousJitter[0]),abs(f.jitter[1]-f.previousJitter[1]));
 float speed=m_FrameRateScale*15.0f;
 m_CheckerboardResolveAccumSpeed=lerp(speed/(1.0f+speed),0.5f,m_JitterDelta);
}
};

void NrdConstants::AddSharedConstants_Reblur(const ReblurSettings& settings, void* data) {
    struct SharedConstants {
        REBLUR_SHARED_CONSTANTS
    };

    NRD_DECLARE_DIMS;

    bool isRectChanged = rectW != rectWprev || rectH != rectHprev;
    bool isHistoryReset = m_CommonSettings.accumulationMode != AccumulationMode::CONTINUE;
    float unproject = 1.0f / (0.5f * rectH * m_ProjectY);
    float worstResolutionScale = min(float(rectW) / float(resourceW), float(rectH) / float(resourceH));
    float maxBlurRadius = settings.maxBlurRadius * worstResolutionScale;
    float diffusePrepassBlurRadius = settings.diffusePrepassBlurRadius * worstResolutionScale;
    float specularPrepassBlurRadius = settings.specularPrepassBlurRadius * worstResolutionScale;
    float disocclusionThresholdBonus = (1.0f + m_JitterDelta) / float(rectH);
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

    SharedConstants* consts = (SharedConstants*)data;
    consts->gWorldToClip = m_WorldToClip;
    consts->gViewToClip = m_ViewToClip;
    consts->gViewToWorld = m_ViewToWorld;
    consts->gWorldToViewPrev = m_WorldToViewPrev;
    consts->gWorldToClipPrev = m_WorldToClipPrev;
    consts->gWorldPrevToWorld = m_WorldPrevToWorld;
    consts->gRotatorPre = m_RotatorPre;
    consts->gRotator = m_Rotator;
    consts->gRotatorPost = m_RotatorPost;
    consts->gFrustum = m_Frustum;
    consts->gFrustumPrev = m_FrustumPrev;
    consts->gCameraDelta = m_CameraDelta.xmm;
    consts->gHitDistSettings = float4(settings.hitDistanceParameters.A, settings.hitDistanceParameters.B, settings.hitDistanceParameters.C, 0.0f);
    consts->gViewVectorWorld = m_ViewDirection.xmm;
    consts->gViewVectorWorldPrev = m_ViewDirectionPrev.xmm;
    consts->gMvScale = float4(m_CommonSettings.motionVectorScale[0], m_CommonSettings.motionVectorScale[1], m_CommonSettings.motionVectorScale[2], m_CommonSettings.isMotionVectorInWorldSpace ? 1.0f : 0.0f);
    consts->gMvBias = float4(m_CommonSettings.motionVectorBias[0], m_CommonSettings.motionVectorBias[1], m_CommonSettings.motionVectorBias[2], 0.0f);
    consts->gConvergenceSettings = float4(settings.convergenceSettings.s, settings.convergenceSettings.b, settings.convergenceSettings.p, 0.0f);
    consts->gAntilagSettings = float2(settings.antilagSettings.luminanceSigmaScale, settings.antilagSettings.luminanceSensitivity);
    consts->gResourceSize = float2(float(resourceW), float(resourceH));
    consts->gResourceSizeInv = float2(1.0f / float(resourceW), 1.0f / float(resourceH));
    consts->gResourceSizeInvPrev = float2(1.0f / float(resourceWprev), 1.0f / float(resourceHprev));
    consts->gRectSize = float2(float(rectW), float(rectH));
    consts->gRectSizeInv = float2(1.0f / float(rectW), 1.0f / float(rectH));
    consts->gRectSizePrev = float2(float(rectWprev), float(rectHprev));
    consts->gResolutionScale = float2(float(rectW) / float(resourceW), float(rectH) / float(resourceH));
    consts->gResolutionScalePrev = float2(float(rectWprev) / float(resourceWprev), float(rectHprev) / float(resourceHprev));
    consts->gJitter = float2(m_CommonSettings.cameraJitter[0], m_CommonSettings.cameraJitter[1]);
    consts->gPrintfAt = uint2(m_CommonSettings.printfAt[0], m_CommonSettings.printfAt[1]);
    consts->gInputRectOrigin = int2(m_CommonSettings.inputRectOrigin[0], m_CommonSettings.inputRectOrigin[1]);
    consts->gOutputRectOrigin = int2(m_CommonSettings.outputRectOrigin[0], m_CommonSettings.outputRectOrigin[1]);
    consts->gDispatchInputRectOrigin = int2(0, 0);
    consts->gDispatchOutputRectOrigin = int2(0, 0);
    consts->gRectSizeMinusOne = int2(rectW - 1, rectH - 1);
    consts->gDisocclusionThreshold = m_CommonSettings.disocclusionThreshold + disocclusionThresholdBonus;
    consts->gDisocclusionThresholdAlternate = m_CommonSettings.disocclusionThresholdAlternate + disocclusionThresholdBonus;
    consts->gCameraAttachedReflectionMaterialID = m_CommonSettings.cameraAttachedReflectionMaterialID;
    consts->gStrandMaterialID = m_CommonSettings.strandMaterialID;
    consts->gStrandThickness = m_CommonSettings.strandThickness;
    consts->gStabilizationStrength = isHistoryReset ? 0.0f : stabilizationStrength;
    consts->gDebug = m_CommonSettings.debug;
    consts->gOrthoMode = m_OrthoMode;
    consts->gUnproject = unproject;
    consts->gDenoisingRange = m_CommonSettings.denoisingRange;
    consts->gPlaneDistSensitivity = settings.planeDistanceSensitivity;
    consts->gFrameRateScale = m_FrameRateScale;
    consts->gFrameRateScaleSmoothed = m_FrameRateScaleSmoothed;
    consts->gMaxBlurRadius = max(maxBlurRadius, settings.minBlurRadius);
    consts->gMinBlurRadius = settings.minBlurRadius;
    consts->gDiffPrepassBlurRadius = diffusePrepassBlurRadius;
    consts->gSpecPrepassBlurRadius = specularPrepassBlurRadius;
    consts->gMaxAccumulatedFrameNum = isHistoryReset ? 0 : float(maxAccumulatedFrameNum);
    consts->gMaxFastAccumulatedFrameNum = isHistoryReset ? 0 : float(settings.maxFastAccumulatedFrameNum);
    consts->gAntiFirefly = settings.enableAntiFirefly ? 1.0f : 0.0f;
    consts->gLobeAngleFraction = settings.lobeAngleFraction * settings.lobeAngleFraction; // TODO: GetSpecularLobeTanHalfAngle has been fixed, but we want to use existing settings
    consts->gRoughnessFraction = settings.roughnessFraction;
    consts->gHistoryFixFrameNum = (float)settings.historyFixFrameNum;
    consts->gHistoryFixBasePixelStride = (float)settings.historyFixBasePixelStride;
    consts->gHistoryFixAlternatePixelStride = (float)settings.historyFixAlternatePixelStride;
    consts->gHistoryFixAlternatePixelStrideMaterialID = m_CommonSettings.historyFixAlternatePixelStrideMaterialID;
    consts->gFastHistoryClampingSigmaScale = lerp(3.0f, settings.fastHistoryClampingSigmaScale, saturate(max(maxBlurRadius, settings.minBlurRadius) / 2.0f));
    consts->gMinRectDimMulUnproject = (float)min(rectW, rectH) * unproject;
    consts->gUsePrepassNotOnlyForSpecularMotionEstimation = settings.usePrepassOnlyForSpecularMotionEstimation ? 0.0f : 1.0f;
    consts->gSplitScreen = m_CommonSettings.splitScreen;
    consts->gSplitScreenPrev = m_SplitScreenPrev;
    consts->gCheckerboardResolveAccumSpeed = m_CheckerboardResolveAccumSpeed;
    consts->gViewZScale = m_CommonSettings.viewZScale;
    consts->gFireflySuppressorMinRelativeScale = settings.fireflySuppressorMinRelativeScale;
    consts->gMinHitDistanceWeight = settings.minHitDistanceWeight;
    consts->gDiffMinMaterial = settings.minMaterialForDiffuse;
    consts->gSpecMinMaterial = settings.minMaterialForSpecular;
    consts->gResponsiveAccumulationInvRoughnessThreshold = 1.0f / max(settings.responsiveAccumulationSettings.roughnessThreshold, 1e-3f);
    consts->gResponsiveAccumulationMinAccumulatedFrameNum = settings.responsiveAccumulationSettings.minAccumulatedFrameNum;
    consts->gHasHistoryConfidence = m_CommonSettings.isHistoryConfidenceAvailable;
    consts->gHasDisocclusionThresholdMix = m_CommonSettings.isDisocclusionThresholdMixAvailable;
    consts->gDiffCheckerboard = diffCheckerboard;
    consts->gSpecCheckerboard = specCheckerboard;
    consts->gFrameIndex = m_CommonSettings.frameIndex;
    consts->gIsRectChanged = isRectChanged ? 1 : 0;
    consts->gResetHistory = isHistoryReset ? 1 : 0;
    consts->gReturnHistoryLengthInsteadOfOcclusion = settings.returnHistoryLengthInsteadOfOcclusion ? 1 : 0;
}

static void halfProjection(float *projection,unsigned width,unsigned height) {
 float scaleX=(float)width/(2*(width/2)),scaleY=(float)height/(2*(height/2));
 float biasX=scaleX-1.0f+0.5f/(width/2),biasY=scaleY-1.0f+0.5f/(height/2);
 for(unsigned column=0;column<4;column++) {
  projection[column*4]=projection[column*4]*scaleX+projection[column*4+3]*biasX;
  projection[column*4+1]=projection[column*4+1]*scaleY+projection[column*4+3]*biasY;
 }
}

extern "C" void NrdPrepareConstants(const NrdFrame *frame,void *data) {
 NrdFrame local=*frame;
 if(local.signal==0) {
  halfProjection(local.projection,local.width,local.height);
  halfProjection(local.previousProjection,local.previousWidth,local.previousHeight);
  local.width/=2;local.height/=2;local.previousWidth/=2;local.previousHeight/=2;
 }
 alignas(16) unsigned char aligned[1024] = {};
 static NrdConstants controllers[2];
 NrdConstants& c=controllers[frame->signal & 1]; c.Prepare(local);
 { ReblurSettings s; s.hitDistanceParameters.A=118.11024f; c.AddSharedConstants_Reblur(s,aligned); }
 memcpy(data,aligned,1024);
}
