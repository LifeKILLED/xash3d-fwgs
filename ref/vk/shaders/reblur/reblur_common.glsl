// NVIDIA NRD-derived helpers. See ../../nrd_port/LICENSE.NVIDIA.txt.
#define GLSL
#include "../ray_interop.h"
#define REBLUR_SIGNAL NRD_REFLECTION
layout(set=0,binding=0) uniform UBO { UniformBuffer ubo; } ubo;
bool reblurEnabled() {
#if !NRD_REFLECTION
return ubo.ubo.nrd_bounce != 0u;
#else
return ubo.ubo.nrd_reflection != 0u;
#endif
}
ivec2 reblurExtent() { return ivec2(ubo.ubo.reblur_resource_size[REBLUR_SIGNAL].xy); }

// REBLUR uses positive view Z and row-vector multiplication at its call sites.
vec3 reblurCameraDelta()
{
    return ubo.ubo.prev_inv_view[3].xyz - ubo.ubo.inv_view[3].xyz;
}

float reblurViewZSign()
{
    return ubo.ubo.proj[2][3] < 0.0 ? -1.0 : 1.0;
}

vec3 reblurViewDirection(bool previous)
{
    return -(previous ? ubo.ubo.prev_inv_view[2].xyz : ubo.ubo.inv_view[2].xyz) * reblurViewZSign();
}

mat4 reblurViewToWorld()
{
    mat4 rotation = ubo.ubo.inv_view;
    rotation[2] *= reblurViewZSign();
    rotation[3] = vec4(0.0, 0.0, 0.0, 1.0);
    return rotation;
}

mat4 reblurProjection(bool previous)
{
    mat4 projection = previous ? ubo.ubo.prev_proj : ubo.ubo.proj;
#if !NRD_REFLECTION
    vec2 halfExtent = previous ? ubo.ubo.reblur_rect_size_prev[REBLUR_SIGNAL].xy
                               : ubo.ubo.reblur_rect_size[REBLUR_SIGNAL].xy;
    // Match primary pixel 2*p in the half-resolution atlas. Resizes reset history.
    vec2 scale = vec2(ubo.ubo.res) / (2.0 * halfExtent);
    vec2 bias = scale - 1.0 + 0.5 / halfExtent;
    for (int column = 0; column < 4; ++column)
        projection[column].xy = projection[column].xy * scale + projection[column].w * bias;
#endif
    for (int column = 0; column < 4; ++column)
        projection[column].y = -projection[column].y;
    projection[2] *= reblurViewZSign();
    return projection;
}

mat4 reblurWorldToView(bool previous)
{
    mat4 view = previous ? ubo.ubo.prev_view : ubo.ubo.view;
    vec3 translation = previous ? -(mat3(view) * reblurCameraDelta()) : vec3(0.0);
    view[3] = vec4(translation, 1.0);
    for (int column = 0; column < 4; ++column)
        view[column].z *= reblurViewZSign();
    return view;
}

mat4 reblurWorldToClip(bool previous)
{
    return transpose(reblurProjection(previous) * reblurWorldToView(previous));
}
