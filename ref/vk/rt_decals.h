#pragma once

#include "vk_core.h"

struct vk_render_geometry_s;

qboolean RT_DecalsInit(void);
void RT_DecalsShutdown(void);
void RT_DecalsClearKusochki(void);
void RT_DecalsSetKusochki(uint32_t offset, const struct vk_render_geometry_s *geometries, int count);
void RT_DecalsFreeKusochki(uint32_t offset, int count);
