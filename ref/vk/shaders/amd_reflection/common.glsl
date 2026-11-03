// This file is part of the FidelityFX SDK.
//
// Copyright (C) 2024 Advanced Micro Devices, Inc.
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files(the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and /or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions :
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#define GLSL
#include "../ray_interop.h"
#include "../utils.glsl"
layout(set=0,binding=0) uniform UBO { UniformBuffer ubo; } ubo;

#define FFX_GLSL 1
#define FFX_GPU 1
#define FFX_HALF 0
#define FFX_GROUPSHARED shared
#define FFX_GROUP_MEMORY_BARRIER barrier()
#define FFX_MATRIX_MULTIPLY(a,b) ((a)*(b))
#define FFX_PARAMETER_OUT out
#define ffxPackHalf2x16 packHalf2x16
#define ffxFract fract
#define ffxLerp mix
#define FfxBoolean bool
#define FfxFloat32 float
#define FfxFloat32x2 vec2
#define FfxFloat32x3 vec3
#define FfxFloat32x4 vec4
#define FfxFloat32Mat4 mat4
#define FfxInt32 int
#define FfxInt32x2 ivec2
#define FfxInt32x3 ivec3
#define FfxUInt32 uint
#define FfxUInt32x2 uvec2

uvec2 ffxRemapForWaveReduction(uint index) {
    return uvec2((index >> 1u) & 7u, ((index >> 3u) & 6u) | (index & 1u));
}
uint GetDenoiserTile(uint group_id) {
    uvec2 origin = gl_WorkGroupID.xy * 8u;
    return origin.x | (origin.y << 16u);
}
uvec2 RenderSize() { return uvec2(ubo.ubo.res / AMD_PIXEL_SCALE); }
vec2 InverseRenderSize() { return 1.0 / vec2(RenderSize()); }
mat4 InvProjection() {
    mat4 flipY = mat4(1.0);
    flipY[1][1] = -1.0;
    return ubo.ubo.inv_proj * flipY;
}
mat4 InvView() { return ubo.ubo.inv_view; }
mat4 PrevViewProjection() {
    mat4 flipY = mat4(1.0);
    flipY[1][1] = -1.0;
    return flipY * ubo.ubo.prev_proj * ubo.ubo.prev_view;
}
float RoughnessThreshold() { return 1.0; }
float TemporalStabilityFactor() { return 0.9; }
bool amdInBounds(ivec2 p) {
    return all(greaterThanEqual(p, ivec2(0))) && all(lessThan(p, ivec2(RenderSize())));
}
#define AMD_LOAD(img,p) imageLoad(img,clamp(p,ivec2(0),ivec2(RenderSize())-1))
#define AMD_GEOMETRY_LOAD(img,p) imageLoad(img,clamp(p,ivec2(0),ivec2(RenderSize())-1)*AMD_PIXEL_SCALE)
#define AMD_STORE(img,p,value) if (amdInBounds(p)) imageStore(img,p,value)
// Generate one bilinear sampler per storage image so its format stays explicit.
#define AMD_SAMPLER(img) AMD_DEFINE_SAMPLER(img)
#define AMD_DEFINE_SAMPLER(img) \
vec4 sample_##img(vec2 uv, ivec2 size) { \
    vec2 p = clamp(uv, vec2(0), vec2(1)) * vec2(size) - 0.5; \
    ivec2 lo = ivec2(floor(p)); \
    ivec2 hi = clamp(lo + 1, ivec2(0), size - 1); \
    vec2 w = fract(p); \
    lo = clamp(lo, ivec2(0), size - 1); \
    return mix(mix(imageLoad(img, lo), imageLoad(img, ivec2(hi.x, lo.y)), w.x), \
               mix(imageLoad(img, ivec2(lo.x, hi.y)), imageLoad(img, hi), w.x), w.y); \
}
#define AMD_SAMPLE(img,uv,size) AMD_CALL_SAMPLER(img,uv,size)
#define AMD_CALL_SAMPLER(img,uv,size) sample_##img(uv,size)
