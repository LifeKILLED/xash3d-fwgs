// Pass toggles in rt.json order (denoiser-related chain).
#define DENOISER_ENABLE_STABILIZE_RESERVOIRS 1
#define DENOISER_ENABLE_DIFFUSE_SAMPLING_FILTER 1
#define DENOISER_ENABLE_SHADOWS_FILTERING 1
#define DENOISER_ENABLE_SHADOW_MASK_CATMULL_ROM 1
#define DENOISER_ENABLE_SPATIAL_RECONSTRUCTION 1
#define DENOISER_ENABLE_REPROJECTION 1
#define DENOISER_ENABLE_DEFLICKERING 0
#define DENOISER_ENABLE_ATROUS 1

// Diffuse sampling filter.
#define DENOISER_SPATIAL_DIFFUSE_ENABLE 1
#define DENOISER_SPATIAL_SPECULAR_ENABLE 1
#define DENOISER_SPATIAL_CONFIDENCE_SCALE_DIFFUSE 1.0
#define DENOISER_SPATIAL_RECONSTRUCTION_CONF_MULT 0.2

// Shadow filtering and shadow-mask reconstruction.
#define DENOISER_SHADOW_MASK_ATROUS_MAX_STEP 8
#define DENOISER_SHADOW_MASK_CATMULL_RADIUS 8

// Spatial reconstruction.
#define DENOISER_SPATIAL_CONFIDENCE_SCALE_SPECULAR 1.0

// Confidence influence for temporal history control in restir_asvgf_direct.
// 0.0 = confidence does not affect history.
// 1.0 = maximal confidence-based history reduction.
#define DENOISER_ASVGF_CONFIDENCE_INFLUENCE 0.3
// Confidence influence for deflickering_asvgf heuristics.
// 0.0 = confidence does not affect thresholds.
// 1.0 = maximal confidence-based threshold tightening (no direct history multiply).
#define DENOISER_DEFLICKER_ASVGF_CONFIDENCE_INFLUENCE 0.3

// Firefly rejection.
#define DENOISER_ENABLE_PRE_FIREFLY_REJECTION_DIFFUSE 0
#define DENOISER_ENABLE_PRE_FIREFLY_REJECTION_SPECULAR 0

// Direct diffuse/specular a-trous.
#define DENOISER_MAX_ATROUS_STEP_DIFFUSE 16
#define DENOISER_MAX_ATROUS_STEP_SPECULAR 16

// Debug views.
#define DENOISER_DEBUG_CONFIDENCE_VIEW 0
#define DENOISER_DEBUG_SHADOW_MASK_VIEW 0
#define DENOISER_DEBUG_DIRECT_DIFFUSE_ATROUS_VARIANCE 0

// Legacy shared constants.
#define NEAR_PLANE_OFFSET 5.
#define GI_DOWNSAMPLE 2
#define GI_BOUNCES_MAX 1
