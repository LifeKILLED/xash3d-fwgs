#pragma once

struct ray_pass_s;
struct ray_pass_s *R_VkRayDenoiserCreate( void );
struct ray_pass_s *R_VkRayDenoiserAccumulateCreate(void);
