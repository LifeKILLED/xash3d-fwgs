#pragma once

struct ray_pass_s;
struct ray_pass_s *R_VkRayDenoiserCreate( void );
struct ray_pass_s* R_VkRayDenoiserAccumulateCreate(void);
struct ray_pass_s* R_VkRayDenoiserReflectionsCreate(void);
struct ray_pass_s* R_VkRayDenoiserDiffuseCreate(void);
struct ray_pass_s* R_VkRayDenoiserRefineCreate(void);
struct ray_pass_s* R_VkRayDenoiserComposeCreate(void);
struct ray_pass_s* R_VkRayDenoiserFXAACreate(void);

