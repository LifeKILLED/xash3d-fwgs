#ifndef DENOISER_CONFIG_GLSL_INCLUDED
#define DENOISER_CONFIG_GLSL_INCLUDED

// Master toggles for denoiser stages.
#ifndef DENOISER_ENABLE_SHADOWS_FILTERING
#define DENOISER_ENABLE_SHADOWS_FILTERING 1
#endif

#ifndef DENOISER_ENABLE_SPATIAL_RECONSTRUCTION
#define DENOISER_ENABLE_SPATIAL_RECONSTRUCTION 1
#endif

#ifndef DENOISER_ENABLE_REPROJECTION
#define DENOISER_ENABLE_REPROJECTION 1
#endif

#ifndef DENOISER_ENABLE_ATROUS
#define DENOISER_ENABLE_ATROUS 1
#endif

// Per-lobe max allowed a-trous step; larger steps are bypassed.
#ifndef DENOISER_MAX_ATROUS_STEP_DIFFUSE
#define DENOISER_MAX_ATROUS_STEP_DIFFUSE 16
#endif

#ifndef DENOISER_MAX_ATROUS_STEP_SPECULAR
#define DENOISER_MAX_ATROUS_STEP_SPECULAR 16
#endif


// not plane, it's sphere, but working
#define NEAR_PLANE_OFFSET 5.

// we downsample gi map and store bounces positions in neighboor texels
// downsample image dimensions by 2 = store 4 bounces
// downsample image dimensions by 3 = store 9 bounces

#ifndef GI_DOWNSAMPLE
#define GI_DOWNSAMPLE 2
#endif

// max bounces for testing bounces visiblity
#define GI_BOUNCES_MAX 1

#endif
