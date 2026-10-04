#ifndef RAY_PRIMARY_COMMON_GLSL_INCLUDED
#define RAY_PRIMARY_COMMON_GLSL_INCLUDED

#define GLSL
#include "ray_interop.h"
#undef GLSL

struct RayPayloadPrimary {
	vec4 hit_t;
#ifndef RAY_QUERY
#ifndef RAY_BOUNCE
	vec4 prev_pos_t;
#endif
	vec4 base_color_a;
	vec4 normals_gs;
	vec4 material_rmxx;
	vec4 emissive;
#endif
};

#ifdef RAY_QUERY
struct RayPrimarySurface {
#ifndef RAY_BOUNCE
	vec4 prev_pos_t;
#endif
	vec4 base_color_a;
	vec4 normals_gs;
	vec4 material_rmxx;
	vec4 emissive;
};
#endif

#define PAYLOAD_LOCATION_PRIMARY 0

#endif //ifndef RAY_PRIMARY_COMMON_GLSL_INCLUDED
