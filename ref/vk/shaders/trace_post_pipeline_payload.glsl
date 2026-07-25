#ifndef TRACE_POST_PIPELINE_PAYLOAD_GLSL_INCLUDED
#define TRACE_POST_PIPELINE_PAYLOAD_GLSL_INCLUDED

#define TRACE_POST_RT_MAX_ENTRIES 8
#define PAYLOAD_LOCATION_TRACE_POST 3

// MAX_KUSOCHKI is 32768 and MAX_INSTANCES is 2048.
#define TRACE_POST_RT_KUSOK_BITS 15u
#define TRACE_POST_RT_KUSOK_MASK 0x7fffu

struct TracePostRtLegacyPayload {
	uint count;
	uvec2 hits[TRACE_POST_RT_MAX_ENTRIES];
	uint barycentrics[TRACE_POST_RT_MAX_ENTRIES];
	float depths[TRACE_POST_RT_MAX_ENTRIES];
};

uint tracePostRtPackGeometry(uint kusok_index, uint model_index)
{
	return kusok_index | (model_index << TRACE_POST_RT_KUSOK_BITS);
}

uint tracePostRtKusokIndex(uint packed_geometry)
{
	return packed_geometry & TRACE_POST_RT_KUSOK_MASK;
}

uint tracePostRtModelIndex(uint packed_geometry)
{
	return packed_geometry >> TRACE_POST_RT_KUSOK_BITS;
}

#endif
