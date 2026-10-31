#pragma once

#include "vk_common.h"

qboolean RT_LightCacheInit(void);
void RT_LightCacheShutdown(void);
void RT_LightCacheClear(void);
void RT_LightCacheAddSurface(const model_t *model, const msurface_t *surf);
void RT_LightCacheTransform(const model_t *model, const matrix4x4 transform);
