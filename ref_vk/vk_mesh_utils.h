#pragma once

#include "vk_common.h"
#include "vk_geometry.h"

void VK_NormalsSmooth_Start(float angle_dot_treshold, qboolean split_by_uv_seams);
void VK_NormalsSmooth_AddVertex(vk_vertex_t *vertex);
void VK_NormalsSmooth_Apply();
