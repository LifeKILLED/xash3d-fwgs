#include "common.glsl"
layout(local_size_x=8,local_size_y=8) in;

layout(set=0,binding=1,rgba32f) uniform readonly image2D AMD_POSITION_T_IMAGE;
layout(set=0,binding=2,rgba16f) uniform readonly image2D AMD_NORMALS_GS_IMAGE;
#if AMD_REFLECTION
layout(set=0,binding=3,rgba8) uniform readonly image2D AMD_MATERIAL_RMXX_IMAGE;
#endif
layout(set=0,binding=4,rgba16f) uniform readonly image2D AMD_INDIRECT_SPECULAR_IMAGE;
layout(set=0,binding=5,rgba16f) uniform readonly image2D AMD_AMD_VARIANCE_IMAGE;
layout(set=0,binding=6,rgba16f) uniform readonly image2D AMD_AMD_AVERAGE_IMAGE;
layout(set=0,binding=7,rgba16f) uniform writeonly image2D AMD_OUT_AMD_FILTERED_IMAGE;
layout(set=0,binding=8,rgba16f) uniform writeonly image2D AMD_OUT_AMD_FILTERED_VARIANCE_IMAGE;
AMD_SAMPLER(AMD_AMD_AVERAGE_IMAGE)

float FFX_DNSR_Reflections_LoadRoughness(ivec2 p) { return AMD_ROUGHNESS(p); }
vec3 FFX_DNSR_Reflections_LoadRadiance(ivec2 p) { return AMD_LOAD(AMD_INDIRECT_SPECULAR_IMAGE,p).rgb; }
vec3 FFX_DNSR_Reflections_LoadWorldSpaceNormal(ivec2 p) { return normalDecode(AMD_GEOMETRY_LOAD(AMD_NORMALS_GS_IMAGE,p).xy); }

float FFX_DNSR_Reflections_LoadDepth(ivec2 p) {
    vec4 surface = AMD_GEOMETRY_LOAD(AMD_POSITION_T_IMAGE,p);
    vec4 clip = ubo.ubo.proj * ubo.ubo.view * vec4(surface.xyz,1.0);
    return abs(clip.w) > 1e-6 ? clamp(clip.z / clip.w,0.0,1.0) : 1.0;
}
float FFX_DENOISER_LoadDepth(ivec2 p, int mip) { return FFX_DNSR_Reflections_LoadDepth(p); }

vec3 FFX_DNSR_Reflections_SampleAverageRadiance(vec2 uv) {
    return AMD_SAMPLE(AMD_AMD_AVERAGE_IMAGE,uv,(ivec2(RenderSize())+7)/8).rgb;
}

vec3 FFX_DENOISER_LoadWorldSpaceNormal(ivec2 p) { return FFX_DNSR_Reflections_LoadWorldSpaceNormal(p); }
vec3 LoadRadiance(ivec3 p) { return FFX_DNSR_Reflections_LoadRadiance(p.xy); }
float LoadVariance(ivec3 p) { return AMD_LOAD(AMD_AMD_VARIANCE_IMAGE,p.xy).x; }
void FFX_DNSR_Reflections_StorePrefilteredReflections(ivec2 p, vec3 v, float variance) {
    AMD_STORE(AMD_OUT_AMD_FILTERED_IMAGE,p,vec4(v,0));
    AMD_STORE(AMD_OUT_AMD_FILTERED_VARIANCE_IMAGE,p,vec4(variance));
}

#include "ffx_denoiser_reflections_prefilter.h"
void main() {
    Prefilter(gl_LocalInvocationIndex, gl_WorkGroupID.x, ivec2(gl_LocalInvocationID.xy));
}
