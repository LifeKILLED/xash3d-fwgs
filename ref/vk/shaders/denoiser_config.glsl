#ifndef DENOISER_CONFIG_GLSL_INCLUDED
#define DENOISER_CONFIG_GLSL_INCLUDED

// Pass toggles in rt.json order (denoiser-related chain).
#define DENOISER_ENABLE_STABILIZE_RESERVOIRS 1
#define DENOISER_ENABLE_DIFFUSE_SAMPLING_FILTER 1
#define DENOISER_ENABLE_SHADOWS_FILTERING 1
#define DENOISER_ENABLE_SPATIAL_RECONSTRUCTION 1
#define DENOISER_ENABLE_REPROJECTION 1
#define ASVGF_SHADOW_POSTFILTER_ENABLE 1
#define DENOISER_ENABLE_DEFLICKERING 0
#define DENOISER_ENABLE_ATROUS 1

// Diffuse sampling filter.
#define DENOISER_SPATIAL_DIFFUSE_ENABLE 1
#define DENOISER_SPATIAL_SPECULAR_ENABLE 1

// Shadow filtering and shadow-mask reconstruction.
#define DENOISER_SHADOW_MASK_CATMULL_RADIUS 12
#define DENOISER_SHADOW_MASK_CATMULL_TENSION -0.5
#define DENOISER_SHADOW_MASK_CATMULL_DETAIL_PRESERVE 0.35

// Direct shadow-filter hard edge preserve.
#define DENOISER_SHADOW_HARD_EDGE_MAX_BLUR 0.09
#define DENOISER_SHADOW_EDGE_LOCK_ENABLE 1
#define DENOISER_SHADOW_EDGE_LOCK_THRESHOLD 0.84
#define DENOISER_SHADOW_EDGE_LOCK_BLEND 0.55

// Spatial reconstruction.

// Shared position-gate thresholds for all denoiser passes.
#define DENOISER_POSITION_PLANE_THRESHOLD 0.2
#define DENOISER_POSITION_DIST2_THRESHOLD 0.05
// Unified scale for both plane distance and texel distance in position gate.
#define DENOISER_POSITION_GATE_SCALE 0.001
// World-space texel footprint margin used by dynamic position gate.
#define DENOISER_POSITION_TEXEL_SIZE_MARGIN 1.5

// Reprojected ASVGF shadow-mask Catmull-Rom filter.
#define DENOISER_ASVGF_SHADOW_CATMULL_RADIUS 12
// Higher values preserve more local detail (less blur near gradients).
#define DENOISER_ASVGF_SHADOW_CATMULL_DETAIL_PRESERVE 0.7
// 0 = horizontal/vertical passes, 1 = diagonal passes (↘ then ↗).
#define DENOISER_ASVGF_SHADOW_CATMULL_DIAGONAL_ENABLE 1
// Temporary debug: show smoothed ASVGF shadow mask instead of a-trous radiance output.
#define DENOISER_DEBUG_ATROUS_OUTPUT_SHADOW_MASK 0
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

#endif // DENOISER_CONFIG_GLSL_INCLUDED
