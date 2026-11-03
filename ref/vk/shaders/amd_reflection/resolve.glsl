#include "common.glsl"
layout(local_size_x=8,local_size_y=8) in;

#if AMD_REFLECTION
layout(set=0,binding=1,rgba8) uniform readonly image2D AMD_MATERIAL_RMXX_IMAGE;
#endif
layout(set=0,binding=2,rgba16f) uniform readonly image2D AMD_AMD_FILTERED_IMAGE;
layout(set=0,binding=3,rgba16f) uniform readonly image2D AMD_AMD_FILTERED_VARIANCE_IMAGE;
layout(set=0,binding=4,rgba16f) uniform readonly image2D AMD_AMD_AVERAGE_IMAGE;
layout(set=0,binding=5,rgba16f) uniform readonly image2D AMD_AMD_REPROJECTED_IMAGE;
layout(set=0,binding=6,rgba16f) uniform readonly image2D AMD_TEMPORAL_AMD_SAMPLES_IMAGE;
layout(set=0,binding=7,rgba16f) uniform writeonly image2D AMD_OUT_TEMPORAL_AMD_RADIANCE_IMAGE;
layout(set=0,binding=8,rgba16f) uniform writeonly image2D AMD_OUT_TEMPORAL_AMD_VARIANCE_IMAGE;
AMD_SAMPLER(AMD_AMD_AVERAGE_IMAGE)

float FFX_DNSR_Reflections_LoadRoughness(ivec2 p) { return AMD_ROUGHNESS(p); }

vec3 FFX_DNSR_Reflections_SampleAverageRadiance(vec2 uv) {
    return AMD_SAMPLE(AMD_AMD_AVERAGE_IMAGE,uv,(ivec2(RenderSize())+7)/8).rgb;
}
vec3 FFX_DNSR_Reflections_LoadRadiance(ivec2 p) { return AMD_LOAD(AMD_AMD_FILTERED_IMAGE,p).rgb; }
float FFX_DNSR_Reflections_LoadVariance(ivec2 p) { return AMD_LOAD(AMD_AMD_FILTERED_VARIANCE_IMAGE,p).x; }
float FFX_DNSR_Reflections_LoadNumSamples(ivec2 p) { return AMD_LOAD(AMD_TEMPORAL_AMD_SAMPLES_IMAGE,p).x; }
vec3 FFX_DNSR_Reflections_LoadRadianceReprojected(ivec2 p) { return AMD_LOAD(AMD_AMD_REPROJECTED_IMAGE,p).rgb; }

void FFX_DNSR_Reflections_StoreTemporalAccumulation(ivec2 p, vec3 v, float variance) {
    AMD_STORE(AMD_OUT_TEMPORAL_AMD_RADIANCE_IMAGE,p,vec4(v,0));
    AMD_STORE(AMD_OUT_TEMPORAL_AMD_VARIANCE_IMAGE,p,vec4(variance));
}

#include "ffx_denoiser_reflections_resolve_temporal.h"
void main() {
    ResolveTemporal(gl_LocalInvocationIndex, gl_WorkGroupID.x, gl_LocalInvocationID.xy);
}
