#pragma once

struct ray_pass_s;
struct ray_pass_s *R_VkRayDenoiserNoDenoiseCreate( void );
struct ray_pass_s* R_VkRayDenoiserAccumulateCreate(void);
struct ray_pass_s* R_VkRayDenoiserReprojectCreate(void);
struct ray_pass_s* R_VkRayDenoiserSpreadCreate(void);
struct ray_pass_s* R_VkRayDenoiserRefineCreate(void);
struct ray_pass_s* R_VkRayDenoiserComposeCreate(void);
struct ray_pass_s* R_VkRayDenoiserFXAACreate(void);

