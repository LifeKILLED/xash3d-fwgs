#ifndef TRACE_POST_DECALS_SURFACE_GLSL_INCLUDED
#define TRACE_POST_DECALS_SURFACE_GLSL_INCLUDED

#ifdef TRACE_POST_USE_RAY_QUERY
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
#endif

layout(set = 0, binding = 1) uniform accelerationStructureEXT tlas;
layout(set = 0, binding = 2) uniform UBO { UniformBuffer ubo; } ubo;
layout(set = 0, binding = 6) uniform sampler2D textures[MAX_TEXTURES];

layout(set = 0, binding = 10, rgba32f) uniform readonly image2D TRACE_POST_HIT_POS;
layout(set = 0, binding = 11, rgba16f) uniform readonly image2D TRACE_POST_NORMALS;
layout(set = 0, binding = 20, rgba8) uniform image2D TRACE_POST_OUT_BASE_COLOR;
layout(set = 0, binding = 21, rgba8) uniform image2D TRACE_POST_OUT_MATERIAL;

layout(set = 0, binding = 30, std430) readonly buffer ModelHeaders { ModelHeader a[]; } model_headers;
layout(set = 0, binding = 31, std430) readonly buffer Kusochki { Kusok a[]; } kusochki;
layout(set = 0, binding = 32, std430) readonly buffer Indices { uint16_t a[]; } indices;
layout(set = 0, binding = 33, std430) readonly buffer Vertices { Vertex a[]; } vertices;

#ifdef TRACE_POST_USE_RAY_QUERY
#include "trace_post_query.glsl"
#else
#include "trace_post_pipeline_common.glsl"
layout(location = PAYLOAD_LOCATION_TRACE_POST) rayPayloadEXT TracePostRtDecalPayload trace_post_payload;
#define TRACE_POST_DECALS 1
#include "trace_post_pipeline.glsl"
#endif

void main()
{
	const ivec2 pix = ivec2(TRACE_POST_LAUNCH_ID);
	if (any(greaterThanEqual(pix, ubo.ubo.res))) {
		return;
	}

	const vec4 hit_pos = imageLoad(TRACE_POST_HIT_POS, pix);
	if (hit_pos.w <= 0.0) {
		return;
	}

	const vec3 geometry_normal = normalDecode(imageLoad(TRACE_POST_NORMALS, pix).xy);
#ifdef TRACE_POST_USE_RAY_QUERY
	TracePostDecalPayload payload = tracePostDecalQuery(hit_pos.xyz, geometry_normal);
#else
	tracePostDecalPipeline(hit_pos.xyz, geometry_normal, trace_post_payload);
#endif

	vec4 base_color_a = SRGBtoLINEAR(imageLoad(TRACE_POST_OUT_BASE_COLOR, pix));
	vec4 material_rmxx = imageLoad(TRACE_POST_OUT_MATERIAL, pix);
#ifdef TRACE_POST_USE_RAY_QUERY
	tracePostCompositeDecals(payload, base_color_a, material_rmxx);
#else
	tracePostCompositeDecalsPipeline(
		trace_post_payload,
		base_color_a,
		material_rmxx);
#endif
	imageStore(TRACE_POST_OUT_BASE_COLOR, pix, LINEARtoSRGB(base_color_a));
	imageStore(TRACE_POST_OUT_MATERIAL, pix, material_rmxx);
}

#endif
