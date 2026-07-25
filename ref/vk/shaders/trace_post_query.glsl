#ifndef TRACE_POST_QUERY_GLSL_INCLUDED
#define TRACE_POST_QUERY_GLSL_INCLUDED

#include "trace_post_common.glsl"

TracePostHit tracePostCandidateHit(rayQueryEXT rq)
{
	const uint kusok_index =
		rayQueryGetIntersectionInstanceCustomIndexEXT(rq, false) +
		rayQueryGetIntersectionGeometryIndexEXT(rq, false);
	return tracePostMakeHit(
		kusok_index,
		rayQueryGetIntersectionPrimitiveIndexEXT(rq, false),
		rayQueryGetIntersectionBarycentricsEXT(rq, false),
		rayQueryGetIntersectionInstanceIdEXT(rq, false));
}

TracePostLegacyPayload tracePostLegacyQuery(vec3 origin, vec3 direction, float ray_length)
{
	TracePostLegacyPayload payload;
	payload.count = 0u;
	payload.ray_length = ray_length;

	rayQueryEXT rq;
	const uint flags = gl_RayFlagsCullFrontFacingTrianglesEXT | gl_RayFlagsNoOpaqueEXT;
	rayQueryInitializeEXT(
		rq,
		tlas,
		flags,
		GEOMETRY_BIT_BLEND,
		origin,
		0.0,
		direction,
		ray_length + 16.0);

	while (rayQueryProceedEXT(rq) && payload.count < TRACE_POST_MAX_ENTRIES) {
		const TracePostHit hit = tracePostCandidateHit(rq);
		payload.hits[payload.count] = hit;
		payload.depths[payload.count] = rayQueryGetIntersectionTEXT(rq, false);
		payload.count++;
	}
	return payload;
}

#endif
