#ifndef TRACE_POST_LEGACY_SURFACE_GLSL_INCLUDED
#define TRACE_POST_LEGACY_SURFACE_GLSL_INCLUDED

#ifdef TRACE_POST_USE_RAY_QUERY
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
#endif

layout(set = 0, binding = 1) uniform accelerationStructureEXT tlas;
layout(set = 0, binding = 2) uniform UBO { UniformBuffer ubo; } ubo;
layout(set = 0, binding = 6) uniform sampler2D textures[MAX_TEXTURES];

layout(set = 0, binding = 10, rgba32f) uniform readonly image2D TRACE_POST_RAY_ORIGIN_LENGTH;
layout(set = 0, binding = 11, rgba16f) uniform readonly image2D TRACE_POST_VIEW_DIR;
layout(set = 0, binding = 20, rgba16f) uniform image2D TRACE_POST_OUT_THROUGHPUT;
layout(set = 0, binding = 21, rgba16f) uniform image2D TRACE_POST_OUT_EMISSIVE;

layout(set = 0, binding = 30, std430) readonly buffer ModelHeaders { ModelHeader a[]; } model_headers;
layout(set = 0, binding = 31, std430) readonly buffer Kusochki { Kusok a[]; } kusochki;
layout(set = 0, binding = 32, std430) readonly buffer Indices { uint16_t a[]; } indices;
layout(set = 0, binding = 33, std430) readonly buffer Vertices { Vertex a[]; } vertices;

#ifdef TRACE_POST_USE_RAY_QUERY
#include "trace_post_query.glsl"
#else
#include "trace_post_pipeline_common.glsl"
layout(location = PAYLOAD_LOCATION_TRACE_POST) rayPayloadEXT TracePostRtLegacyPayload trace_post_payload;
#define TRACE_POST_LEGACY 1
#include "trace_post_pipeline.glsl"
#endif

void main()
{
	const ivec2 pix = ivec2(TRACE_POST_LAUNCH_ID);
	if (any(greaterThanEqual(pix, ubo.ubo.res))) {
		return;
	}

	const vec4 origin_length = imageLoad(TRACE_POST_RAY_ORIGIN_LENGTH, pix);
	const vec3 stored_view_dir = imageLoad(TRACE_POST_VIEW_DIR, pix).xyz;
	if (origin_length.w <= 0.0 || dot(stored_view_dir, stored_view_dir) <= 1e-6) {
		return;
	}
	const vec3 ray_direction = -normalize(stored_view_dir);

#ifdef TRACE_POST_USE_RAY_QUERY
	TracePostLegacyPayload payload = tracePostLegacyQuery(origin_length.xyz, ray_direction, origin_length.w);
#else
	tracePostLegacyPipeline(origin_length.xyz, ray_direction, origin_length.w, trace_post_payload);
#endif
#ifdef TRACE_POST_USE_RAY_QUERY
	const vec4 blend = tracePostCompositeLegacy(payload);
#else
	const vec4 blend = tracePostCompositeLegacyPipeline(
		trace_post_payload,
		origin_length.w);
#endif

	vec4 throughput = imageLoad(TRACE_POST_OUT_THROUGHPUT, pix);
	vec3 emissive = imageLoad(TRACE_POST_OUT_EMISSIVE, pix).rgb;
#if TRACE_POST_REFLECTION
	emissive = throughput.rgb * (SRGBtoLINEAR(blend.rgb) + emissive * blend.a);
#else
	emissive = SRGBtoLINEAR(blend.rgb) + emissive * blend.a;
#endif
	throughput.rgb *= blend.a;
	imageStore(TRACE_POST_OUT_THROUGHPUT, pix, throughput);
	imageStore(TRACE_POST_OUT_EMISSIVE, pix, vec4(emissive, 0.0));
}

#endif
