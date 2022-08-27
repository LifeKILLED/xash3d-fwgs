#pragma once

struct ray_pass_s;
struct ray_pass_s *R_VkRayDenoiserNoDenoiseCreate( void );
struct ray_pass_s* R_VkRayDenoiserLastFrameBuffersCreate( void );
struct ray_pass_s* R_VkRayDenoiserFakeMotionVectorsCreate( void );
struct ray_pass_s* R_VkRayDenoiserAccumulateCreate( void );
struct ray_pass_s* R_VkRayDenoiserReprojectCreate( void );

struct ray_pass_s* R_VkRayDenoiserGIBlurPass1Create( void );
struct ray_pass_s* R_VkRayDenoiserGIBlurPass2Create( void );
struct ray_pass_s* R_VkRayDenoiserGIBlurPass3Create( void );

struct ray_pass_s* R_VkRayDenoiserDiffuseSVGFVarianceCreate( void );
struct ray_pass_s* R_VkRayDenoiserDiffuseSVGFPass1Create( void );
struct ray_pass_s* R_VkRayDenoiserDiffuseSVGFPass2Create( void );
struct ray_pass_s* R_VkRayDenoiserDiffuseSVGFPass3Create( void );

struct ray_pass_s* R_VkRayDenoiserSpecularSVGFVarianceCreate( void );
struct ray_pass_s* R_VkRayDenoiserSpecularSVGFPass1Create( void );
struct ray_pass_s* R_VkRayDenoiserSpecularSVGFPass2Create( void );
struct ray_pass_s* R_VkRayDenoiserSpecularSVGFPass3Create( void );

struct ray_pass_s* R_VkRayDenoiserComposeCreate( void );
struct ray_pass_s* R_VkRayDenoiserFXAACreate( void );

