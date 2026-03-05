#ifndef DIRECT_SPECULAR_ATROUS_CONFIG_GLSL_INCLUDED
#define DIRECT_SPECULAR_ATROUS_CONFIG_GLSL_INCLUDED

#include "denoiser_config.glsl"

#define POSITION_T position_t
#define NORMALS_GS normals_gs
#define MATERIAL_RMXX material_rmxx
#define ATROUS_VARIANCE_OUTPUT out_specular_atrous_variance
#define ATROUS_VARIANCE_SOURCE specular_atrous_variance

#define SHADING_NORMAL_DOT_THRESHOLD 0.995
#define ATROUS_MAX_STEP DENOISER_MAX_ATROUS_STEP_SPECULAR
#define ATROUS_MASK_GATE_ENABLE 0

#endif

