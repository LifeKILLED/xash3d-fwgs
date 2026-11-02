#pragma once
#include "VImage.h"
void R_VkNrdResourcesEnsure(unsigned width,unsigned height);
void R_VkNrdResourcesShutdown(void);
r_vk_image_t *R_VkNrdResource(const char *name);
