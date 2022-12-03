#pragma once

struct ray_pass_s *R_VkRayLightDirectPolyPassCreate( void );
struct ray_pass_s *R_VkRayLightDirectPointPassCreate( void );
struct ray_pass_s* R_VkRayLightIndirectPolyPassCreate( void );
struct ray_pass_s* R_VkRayLightIndirectPointPassCreate( void );
struct ray_pass_s* R_VkRayLightReflectPolyPassCreate( void );
struct ray_pass_s* R_VkRayLightReflectPointPassCreate( void );

struct ray_pass_s* R_VkRayLightDirectPolyChoosePassCreate(void);
struct ray_pass_s* R_VkRayLightDirectPolySamplePassCreate(void);

struct ray_pass_s* R_VkRayLightReflectPolyChoosePassCreate(void);
struct ray_pass_s* R_VkRayLightReflectPolySamplePassCreate(void);

struct ray_pass_s* R_VkRayLightGIPolyChoosePassCreate(void);
struct ray_pass_s* R_VkRayLightGIPolySamplePassCreate(void);
