#ifndef TRACE_POST_CAMERA_LEGACY_GLSL_INCLUDED
#define TRACE_POST_CAMERA_LEGACY_GLSL_INCLUDED

#ifdef TRACE_POST_USE_RAY_QUERY
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
#endif

layout(set = 0, binding = 1) uniform accelerationStructureEXT tlas;
layout(set = 0, binding = 2) uniform UBO { UniformBuffer ubo; } ubo;
layout(set = 0, binding = 6) uniform sampler2D textures[MAX_TEXTURES];
layout(set = 0, binding = 10, rgba32f) uniform readonly image2D position_t;
layout(set = 0, binding = 20, rgba16f) uniform writeonly image2D out_legacy_blend;
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

vec3 tracePostClipToWorldSpace(vec3 clip)
{
	const vec4 eye_space = ubo.ubo.inv_proj * vec4(clip, 1.0);
	return (ubo.ubo.inv_view * vec4(eye_space.xyz / eye_space.w, 1.0)).xyz;
}

void main()
{
	const ivec2 pix = ivec2(TRACE_POST_LAUNCH_ID);
	if (any(greaterThanEqual(pix, ubo.ubo.res))) {
		return;
	}
	const vec2 uv = (vec2(pix) + 0.5) / vec2(ubo.ubo.res) * 2.0 - 1.0;
	const vec3 origin = tracePostClipToWorldSpace(vec3(uv, 0.0));
	const vec3 far_position = tracePostClipToWorldSpace(vec3(uv, 1.0));
	const vec3 segment = far_position - origin;
	const float far_length = length(segment);
	const vec3 direction = segment / max(far_length, 1e-6);
	const float ray_length = imageLoad(position_t, pix).w > 0.0
		? imageLoad(position_t, pix).w
		: far_length;

#ifdef TRACE_POST_USE_RAY_QUERY
	TracePostLegacyPayload payload = tracePostLegacyQuery(origin, direction, ray_length);
#else
	tracePostLegacyPipeline(origin, direction, ray_length, trace_post_payload);
#endif
#ifdef TRACE_POST_USE_RAY_QUERY
	imageStore(out_legacy_blend, pix, tracePostCompositeLegacy(payload));
#else
	imageStore(out_legacy_blend, pix, tracePostCompositeLegacyPipeline(
		trace_post_payload, ray_length));
#endif
}

#endif
