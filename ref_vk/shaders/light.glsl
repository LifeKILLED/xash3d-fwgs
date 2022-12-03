layout (set = 0, binding = BINDING_LIGHTS) readonly buffer UBOLights { LightsMetadata lights; }; // TODO this is pretty much static and should be a buffer, not UBO
layout (set = 0, binding = BINDING_LIGHT_CLUSTERS, align = 1) readonly buffer UBOLightClusters {
	ivec3 grid_min, grid_size;
	//uint8_t clusters_data[MAX_LIGHT_CLUSTERS * LIGHT_CLUSTER_SIZE + HACK_OFFSET];
	LightCluster clusters_[MAX_LIGHT_CLUSTERS];
} light_grid;

const float color_culling_threshold = 0;//600./color_factor;
const float shadow_offset_fudge = .1;

#include "brdf.h"
#include "light_common.glsl"

// Different for loop and single sample, remove code doubling
#ifdef ONE_LIGHT_PER_TEXEL
	#define SKIP_LIGHT() return;
#else
	#define SKIP_LIGHT() continue;
#endif

#ifdef LIGHT_POLYGON
#include "light_polygon.glsl"
#endif

#if LIGHT_POINT

#ifndef POINT_LIGHTS_PER_TEXEL
#define POINT_LIGHTS_PER_TEXEL 2.
#endif

void PointLightCalculate(PointLight light, vec3 P, vec3 N, inout vec3 color, inout vec3 light_dir_norm, inout float light_dist) {
	color = vec3(0.);
	light_dir_norm = vec3(1., 0., 0.);
	light_dist = 1e5; // TODO this is supposedly not the right way to do shadows for environment lights. qrad checks for hitting SURF_SKY, and maybe we should too?

	if (light.environment == 0) { // point lights and spots
		const vec4 origin_r = light.origin_r;
		const float stopdot = light.color_stopdot.a;
		const float stopdot2 = light.dir_stopdot2.a;

		const vec3 light_dir = origin_r.xyz - P;
		const float radius = origin_r.w;

		light_dir_norm = normalize(light_dir);

		const float light_dot = dot(light_dir_norm, N);
		if (light_dot < 1e-5)
			return;
			
		const float spot_dot = -dot(light_dir_norm, light.dir_stopdot2.xyz);
		if (spot_dot < stopdot2)
			return;

		float spot_attenuation = 1.f;
		if (spot_dot < stopdot)
			spot_attenuation = (spot_dot - stopdot2) / (stopdot - stopdot2);

		const float d2 = dot(light_dir, light_dir);
		const float r2 = origin_r.w * origin_r.w;

		const float dist = length(light_dir);

		if (radius < 1e-3 || radius > dist)
			return;

		light_dist = dist - radius;

		const float pdf = 1. / ((1. - sqrt(d2 - r2) / dist) * spot_attenuation);
		color = light.color_stopdot.rgb / pdf;
	} else { // sunlight
		light_dir_norm = normalize(-light.dir_stopdot2.xyz);
		color = light.color_stopdot.rgb * 2;
		light_dist = 10000.;
	}
}

void computePointLights(vec3 P, vec3 N, uint cluster_index, vec3 throughput, vec3 view_dir, MaterialProperties material, out vec3 diffuse, out vec3 specular) {
	diffuse = specular = vec3(0.);
	const vec3 shadow_sample_offset = normalize(vec3(rand01(), rand01(), rand01()) - vec3(.5));

	const uint num_lights = lights.num_point_lights;
	float weights_total = 0.;
	for (uint index = 0; index < num_lights; ++index) {
		PointLight light = lights.point_lights[index];

		if (light.environment == 1)
			continue; // sample always

		vec3 light_dir_norm;
		vec3 color;
		float light_dist;
		PointLightCalculate(light, P, N, color, light_dir_norm, light_dist);

		float irradiance = dot(color, color);
		if (irradiance <= 0.0001)
			continue;

		weights_total += irradiance * dot(N, normalize(light_dir_norm));
	}

	for (uint index = 0; index < num_lights; ++index) {

		PointLight light = lights.point_lights[index];
		const bool not_environment = light.environment == 0;

		vec3 light_dir_norm;
		vec3 color;
		float light_dist;
		PointLightCalculate(light, P, N, color, light_dir_norm, light_dist);

		float irradiance = dot(color, color);
		if (irradiance <= 0.0001)
			SKIP_LIGHT();

		const float weight_current = irradiance * dot(N, normalize(light_dir_norm)) / weights_total;

		if (not_environment && weight_current * POINT_LIGHTS_PER_TEXEL < rand01())
			SKIP_LIGHT();
				
		//color *= 1. / weight_current;

		vec3 ldiffuse, lspecular;
		evalSplitBRDF(N, light_dir_norm, view_dir, material, ldiffuse, lspecular);
		ldiffuse *= color;
		lspecular *= color;

		vec3 combined = ldiffuse + lspecular;

		const float shadow_sample_radius = not_environment ? light.origin_r.w : 1000.;
		const vec3 shadow_sample_dir = light_dir_norm * light_dist + shadow_sample_offset * shadow_sample_radius;

		// FIXME split environment and other lights
		if (not_environment) {
			if (shadowed(P, normalize(shadow_sample_dir), length(shadow_sample_dir)))
				SKIP_LIGHT()
		} else {
			// for environment light check that we've hit SURF_SKY
			if (shadowedSky(P, normalize(shadow_sample_dir), length(shadow_sample_dir)))
				SKIP_LIGHT()
		}

		diffuse += ldiffuse;
		specular += lspecular;

#ifdef ONE_LIGHT_PER_TEXEL
		diffuse *= float(num_lights);
		specular *= float(num_lights);
#else
	} // for all lights
#endif

}
#endif

void computeLighting(vec3 P, vec3 N, vec3 throughput, vec3 view_dir, MaterialProperties material, out vec3 diffuse, out vec3 specular) {
	diffuse = specular = vec3(0.);

	const ivec3 light_cell = ivec3(floor(P / LIGHT_GRID_CELL_SIZE)) - light_grid.grid_min;
	const uint cluster_index = uint(dot(light_cell, ivec3(1, light_grid.grid_size.x, light_grid.grid_size.x * light_grid.grid_size.y)));

#if LIGHT_POLYGON
	sampleEmissiveSurfaces(P, N, throughput, view_dir, material, cluster_index, diffuse, specular);
#endif


#if LIGHT_POINT
	vec3 ldiffuse = vec3(0.), lspecular = vec3(0.);
	computePointLights(P, N, cluster_index, throughput, view_dir, material, ldiffuse, lspecular);
	diffuse += ldiffuse;
	specular += lspecular;
#endif

	if (any(isnan(diffuse)))
		diffuse = vec3(1.,0.,0.);

	if (any(isnan(specular)))
		specular = vec3(0.,1.,0.);

	if (any(lessThan(diffuse,vec3(0.))))
			diffuse = vec3(1., 0., 1.);

	if (any(lessThan(specular,vec3(0.))))
			specular = vec3(0., 1., 1.);

	//specular = vec3(0.,1.,0.);
	//diffuse = vec3(0.);
}
