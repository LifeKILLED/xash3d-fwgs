#ifndef LIGHT_RIS_GLSL_INCLUDED
#define LIGHT_RIS_GLSL_INCLUDED

#include "light_ris_common.glsl"

#include "light_ris_lights.glsl"

bool computeLightingRISState(
	vec3 P,
	bool surface_active,
	out uint cluster_index,
	out bool ris_active)
{
	cluster_index = 0u;
	const bool cluster_valid = surface_active && risComputeClusterIndex(P, cluster_index);
	ris_active = cluster_valid && ((ubo.ubo.debug_flags & DEBUG_FLAG_WHITE_FURNACE) == 0);
	return cluster_valid;
}

#if RIS_UNIFIED_PASS
void computeLightingRISUnified(
	vec3 P,
	vec3 geometry_N,
	vec3 shading_N,
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
	uint cluster_index;
	bool ris_active;
	computeLightingRISState(P, surface_active, cluster_index, ris_active);

#if LIGHT_POLYGON
	computePolygonLightingRISUnified(
		cluster_index, P, geometry_N, shading_N, V, material, pix, pix,
		ris_active, diffuse, specular);
#endif
	#if LIGHT_POINT
		computePointLightingRISUnified(
			cluster_index, P, geometry_N, shading_N, V, material, pix, pix,
			ris_active, diffuse, specular);
		vec3 always_diffuse;
		vec3 always_specular;
	computePointAlwaysSampledLights(
		P, shading_N, V, material, cluster_index, ris_active,
		always_diffuse, always_specular, flashlight_diffuse, flashlight_specular);
		diffuse += always_diffuse;
		specular += always_specular;
	#endif
}
#endif

#if RIS_INIT_PASS
void computeLightingRISInit(
	vec3 P,
	vec3 geometry_N,
	vec3 shading_N,
	vec3 V,
	MaterialProperties material,
	ivec2 pix,
	ivec2 surface_pix,
	bool surface_active)
{
	uint cluster_index;
	bool ris_active;
	computeLightingRISState(P, surface_active, cluster_index, ris_active);

#if LIGHT_POLYGON
	computePolygonLightingRISInit(cluster_index, P, geometry_N, shading_N, V, material, pix, surface_pix, ris_active);
#endif

#if LIGHT_POINT
	computePointLightingRISInit(cluster_index, P, geometry_N, shading_N, V, material, pix, surface_pix, ris_active);
#endif
}
#endif

#if RIS_APPLY_PASS
void computeLightingRISApply(
	vec3 P,
	vec3 shading_N,
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

	uint cluster_index;
	bool ris_active;
	computeLightingRISState(P, surface_active, cluster_index, ris_active);

#if LIGHT_POLYGON
	computePolygonLightingRISApply(P, shading_N, V, material, pix, ris_active, diffuse, specular);
#endif

#if LIGHT_POINT
	computePointLightingRISApply(P, shading_N, V, material, cluster_index, pix, ris_active, diffuse, specular, flashlight_diffuse, flashlight_specular);
#endif
}
#endif

#endif // LIGHT_RIS_GLSL_INCLUDED
