// NVIDIA NRD-derived helpers. See ../../nrd_port/LICENSE.NVIDIA.txt.
#define GLSL
#include "../ray_interop.h"
#define REBLUR_SIGNAL (1 - NRD_BOUNCE)
layout(set=0,binding=0) uniform UBO { UniformBuffer ubo; } ubo;
bool reblurEnabled() {
#if NRD_BOUNCE
return ubo.ubo.nrd_bounce != 0u;
#else
return ubo.ubo.nrd_reflection != 0u;
#endif
}
ivec2 reblurExtent() { return ivec2(ubo.ubo.reblur_resource_size[REBLUR_SIGNAL].xy); }
