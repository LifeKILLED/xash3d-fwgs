#ifndef LIGHT_RIS_GLSL_INCLUDED
#define LIGHT_RIS_GLSL_INCLUDED

#include "light_ris_common.glsl"

#if LIGHT_POLYGON
#include "light_polygon_ris.glsl"
#endif

#if LIGHT_POINT
#include "light_point_ris.glsl"
#endif

void computeLightingRIS(
	vec3 P,
	vec3 N,
	vec3 V,
	MaterialProperties material,
	ivec2 pix,
	bool surface_active,
	out vec3 diffuse,
	out vec3 specular,
	out vec3 flashlight_diffuse,
	out vec3 flashlight_specular)
{
	diffuse = vec3(0.0);
	specular = vec3(0.0);
	flashlight_diffuse = vec3(0.0);
	flashlight_specular = vec3(0.0);

	uint cluster_index = 0u;
	const bool cluster_valid = surface_active && risComputeClusterIndex(P, cluster_index);
	const bool ris_active = cluster_valid && ((ubo.ubo.debug_flags & DEBUG_FLAG_WHITE_FURNACE) == 0);

#if LIGHT_POLYGON
	computePolygonLightingRIS(P, N, V, material, cluster_index, pix, ris_active, diffuse, specular);
#endif

#if LIGHT_POINT
	computePointLightingRIS(P, N, V, material, cluster_index, pix, ris_active, diffuse, specular, flashlight_diffuse, flashlight_specular);
#endif
}

#endif // LIGHT_RIS_GLSL_INCLUDED
