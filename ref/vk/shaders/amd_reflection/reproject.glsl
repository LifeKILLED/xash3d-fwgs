#include "common.glsl"
layout(local_size_x=8,local_size_y=8) in;

layout(set=0,binding=1,rgba32f) uniform readonly image2D AMD_POSITION_T_IMAGE;
layout(set=0,binding=2,rgba32f) uniform readonly image2D AMD_GEOMETRY_PREV_POSITION_IMAGE;
#if AMD_REFLECTION
layout(set=0,binding=3,rgba32f) uniform readonly image2D AMD_REFLECTION_DIRECTION_PDF_IMAGE;
#endif
layout(set=0,binding=4,rgba16f) uniform readonly image2D AMD_NORMALS_GS_IMAGE;
#if AMD_REFLECTION
layout(set=0,binding=5,rgba8) uniform readonly image2D AMD_MATERIAL_RMXX_IMAGE;
#endif
layout(set=0,binding=6,rgba16f) uniform readonly image2D AMD_INDIRECT_SPECULAR_IMAGE;
layout(set=0,binding=7,rgba16f) uniform readonly image2D AMD_PREV_TEMPORAL_AMD_RADIANCE_IMAGE;
layout(set=0,binding=8,rgba16f) uniform readonly image2D AMD_PREV_TEMPORAL_AMD_GEOMETRY_IMAGE;
layout(set=0,binding=9,rgba32f) uniform readonly image2D AMD_PREV_TEMPORAL_AMD_DEPTH_IMAGE;
layout(set=0,binding=10,rgba16f) uniform readonly image2D AMD_PREV_TEMPORAL_AMD_VARIANCE_IMAGE;
layout(set=0,binding=11,rgba16f) uniform readonly image2D AMD_PREV_TEMPORAL_AMD_SAMPLES_IMAGE;
layout(set=0,binding=12,rgba16f) uniform writeonly image2D AMD_OUT_TEMPORAL_AMD_GEOMETRY_IMAGE;
layout(set=0,binding=13,rgba32f) uniform writeonly image2D AMD_OUT_TEMPORAL_AMD_DEPTH_IMAGE;
layout(set=0,binding=14,rgba16f) uniform writeonly image2D AMD_OUT_TEMPORAL_AMD_SAMPLES_IMAGE;
layout(set=0,binding=15,rgba16f) uniform writeonly image2D AMD_OUT_AMD_REPROJECTED_IMAGE;
layout(set=0,binding=16,rgba16f) uniform writeonly image2D AMD_OUT_AMD_VARIANCE_IMAGE;
layout(set=0,binding=17,rgba16f) uniform writeonly image2D AMD_OUT_AMD_AVERAGE_IMAGE;
AMD_SAMPLER(AMD_PREV_TEMPORAL_AMD_RADIANCE_IMAGE)
AMD_SAMPLER(AMD_PREV_TEMPORAL_AMD_GEOMETRY_IMAGE)
AMD_SAMPLER(AMD_PREV_TEMPORAL_AMD_DEPTH_IMAGE)
AMD_SAMPLER(AMD_PREV_TEMPORAL_AMD_VARIANCE_IMAGE)
AMD_SAMPLER(AMD_PREV_TEMPORAL_AMD_SAMPLES_IMAGE)

float FFX_DNSR_Reflections_LoadRoughness(ivec2 p) { return AMD_ROUGHNESS(p); }
vec3 FFX_DNSR_Reflections_LoadRadiance(ivec2 p) { return AMD_LOAD(AMD_INDIRECT_SPECULAR_IMAGE,p).rgb; }
vec3 FFX_DNSR_Reflections_LoadWorldSpaceNormal(ivec2 p) { return normalDecode(AMD_GEOMETRY_LOAD(AMD_NORMALS_GS_IMAGE,p).xy); }

float FFX_DNSR_Reflections_LoadDepth(ivec2 p) {
    vec4 surface = AMD_GEOMETRY_LOAD(AMD_POSITION_T_IMAGE,p);
    vec4 clip = ubo.ubo.proj * ubo.ubo.view * vec4(surface.xyz,1.0);
    return abs(clip.w) > 1e-6 ? clamp(clip.z / clip.w,0.0,1.0) : 1.0;
}
float FFX_DENOISER_LoadDepth(ivec2 p, int mip) { return FFX_DNSR_Reflections_LoadDepth(p); }

vec2 FFX_DNSR_Reflections_LoadMotionVector(ivec2 p) {
    vec4 prev = ubo.ubo.prev_proj * ubo.ubo.prev_view * vec4(AMD_GEOMETRY_LOAD(AMD_GEOMETRY_PREV_POSITION_IMAGE,p).xyz,1.0);
    if (prev.w <= 1e-6 || ubo.ubo.frame_counter <= 1u) return vec2(2.0);
    vec2 prevUV = prev.xy / prev.w * 0.5 + 0.5;
    vec2 prevPixel = (prevUV * vec2(ubo.ubo.res) - 0.5) / float(AMD_PIXEL_SCALE);
    return (prevPixel - vec2(p)) * InverseRenderSize();
}
float FFX_DNSR_Reflections_LoadRayLength(ivec2 p) { return AMD_RAY_LENGTH(p); }
void FFX_DNSR_Reflections_StoreRadianceReprojected(ivec2 p, vec3 v) { AMD_STORE(AMD_OUT_AMD_REPROJECTED_IMAGE,p,vec4(v,0)); }
void FFX_DNSR_Reflections_StoreVariance(ivec2 p, float v) { AMD_STORE(AMD_OUT_AMD_VARIANCE_IMAGE,p,vec4(v)); }
void FFX_DNSR_Reflections_StoreNumSamples(ivec2 p, float v) { AMD_STORE(AMD_OUT_TEMPORAL_AMD_SAMPLES_IMAGE,p,vec4(v)); }
void FFX_DNSR_Reflections_StoreAverageRadiance(ivec2 p, vec3 v) { AMD_STORE(AMD_OUT_AMD_AVERAGE_IMAGE,p,vec4(v,0)); }
vec3 FFX_DNSR_Reflections_LoadRadianceHistory(ivec2 p) { return AMD_LOAD(AMD_PREV_TEMPORAL_AMD_RADIANCE_IMAGE,p).rgb; }
vec3 FFX_DNSR_Reflections_LoadWorldSpaceNormalHistory(ivec2 p) { return AMD_LOAD(AMD_PREV_TEMPORAL_AMD_GEOMETRY_IMAGE,p).xyz; }
float FFX_DNSR_Reflections_LoadDepthHistory(ivec2 p) { return AMD_LOAD(AMD_PREV_TEMPORAL_AMD_DEPTH_IMAGE,p).x; }
vec3 FFX_DNSR_Reflections_SampleRadianceHistory(vec2 uv) { return AMD_SAMPLE(AMD_PREV_TEMPORAL_AMD_RADIANCE_IMAGE,uv,ivec2(RenderSize())).rgb; }
vec3 FFX_DNSR_Reflections_SampleWorldSpaceNormalHistory(vec2 uv) { return AMD_SAMPLE(AMD_PREV_TEMPORAL_AMD_GEOMETRY_IMAGE,uv,ivec2(RenderSize())).xyz; }
float FFX_DNSR_Reflections_SampleRoughnessHistory(vec2 uv) { return AMD_SAMPLE(AMD_PREV_TEMPORAL_AMD_GEOMETRY_IMAGE,uv,ivec2(RenderSize())).w; }
float FFX_DNSR_Reflections_SampleDepthHistory(vec2 uv) { return AMD_SAMPLE(AMD_PREV_TEMPORAL_AMD_DEPTH_IMAGE,uv,ivec2(RenderSize())).x; }
float FFX_DNSR_Reflections_SampleVarianceHistory(vec2 uv) { return AMD_SAMPLE(AMD_PREV_TEMPORAL_AMD_VARIANCE_IMAGE,uv,ivec2(RenderSize())).x; }
float FFX_DNSR_Reflections_SampleNumSamplesHistory(vec2 uv) { return AMD_SAMPLE(AMD_PREV_TEMPORAL_AMD_SAMPLES_IMAGE,uv,ivec2(RenderSize())).x; }

#define AMD_HISTORY_VALID (ubo.ubo.reblur_reset_history[AMD_SIGNAL] == 0u && ubo.ubo.frame_counter > 1u)
#include "ffx_denoiser_reflections_reproject.h"
void main() {
    Reproject(gl_LocalInvocationIndex, gl_WorkGroupID.x, gl_LocalInvocationID.xy);
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    AMD_STORE(AMD_OUT_TEMPORAL_AMD_GEOMETRY_IMAGE,p,vec4(FFX_DNSR_Reflections_LoadWorldSpaceNormal(p),FFX_DNSR_Reflections_LoadRoughness(p)));
    AMD_STORE(AMD_OUT_TEMPORAL_AMD_DEPTH_IMAGE,p,vec4(FFX_DNSR_Reflections_LoadDepth(p)));
}
