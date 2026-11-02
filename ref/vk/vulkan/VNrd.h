#pragma once
#include "VNrdResources.h"
#include "VCombuf.h"
#include "../nrd_port/cpu.h"
typedef struct {
 NrdFrame frame;
 unsigned frameSlot,diffuseMode,specularMode;
 r_vk_image_t *position,*normals,*material,*previousPosition;
 r_vk_image_t *diffuse,*specular,*diffuseRay,*specularRay;
 r_vk_image_t *diffuseDestination,*specularDestination;
} NrdDispatch;
void R_VkNrdDispatch(vk_combuf_t *combuf,const NrdDispatch *args);
void R_VkNrdShutdown(void);
