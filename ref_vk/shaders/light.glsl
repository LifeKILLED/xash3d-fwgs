layout (set = 0, binding = BINDING_LIGHTS) readonly buffer SBOLights { LightsMetadata m; } lights;
layout (set = 0, binding = BINDING_LIGHT_CLUSTERS, align = 1) readonly buffer UBOLightClusters {
	ivec3 grid_min, grid_size;
	//uint8_t clusters_data[MAX_LIGHT_CLUSTERS * LIGHT_CLUSTER_SIZE + HACK_OFFSET];
	LightCluster clusters_[MAX_LIGHT_CLUSTERS];
} light_grid;

const float color_culling_threshold = 0;//600./color_factor;
const float shadow_offset_fudge = .1;

#ifdef RAY_QUERY
// TODO sync with native code
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
#endif

#include "brdf.h"
#include "light_common.glsl"

#if LIGHT_POLYGON
#include "light_polygon.glsl"
#endif

#if LIGHT_POINT
void sampleSinglePointLight(vec3 P, vec3 N, vec3 throughput, vec3 view_dir, MaterialProperties material, PointLight light, out vec3 diffuse, out vec3 specular) {
	vec3 color = light.color_stopdot.rgb * throughput;
	if (dot(color,color) < color_culling_threshold)
		return;

	const vec4 origin_r = light.origin_r;
	const float stopdot = light.color_stopdot.a;
	const vec3 dir = light.dir_stopdot2.xyz;
	const float stopdot2 = light.dir_stopdot2.a;
	const bool not_environment = (light.environment == 0);

	const vec3 light_dir = not_environment ? (origin_r.xyz - P) : -dir; // TODO need to randomize sampling direction for environment soft shadow
	const float radius = origin_r.w;

	const vec3 light_dir_norm = normalize(light_dir);
	const float light_dot = dot(light_dir_norm, N);
	if (light_dot < 1e-5)
		return;

	const float spot_dot = -dot(light_dir_norm, dir);
	if (spot_dot < stopdot2)
		return;

	float spot_attenuation = 1.f;
	if (spot_dot < stopdot)
		spot_attenuation = (spot_dot - stopdot2) / (stopdot - stopdot2);

	//float fdist = 1.f;
	float light_dist = 1e5; // TODO this is supposedly not the right way to do shadows for environment lights.m. qrad checks for hitting SURF_SKY, and maybe we should too?
	const float d2 = dot(light_dir, light_dir);
	const float r2 = origin_r.w * origin_r.w;
	if (not_environment) {
		if (radius < 1e-3)
			return;

		const float dist = length(light_dir);
		if (radius > dist)
			return;

		light_dist = dist - radius;
		const float pdf = 1. / ((1. - sqrt(d2 - r2) / dist) * spot_attenuation);
		color /= pdf;
	} else {
		color *= 2;
	}

	// if (dot(color,color) < color_culling_threshold)
	// 	continue;

	vec3 ldiffuse, lspecular;
	evalSplitBRDF(N, light_dir_norm, view_dir, material, ldiffuse, lspecular);
	ldiffuse *= color;
	lspecular *= color;

	vec3 combined = ldiffuse + lspecular;

	if (dot(combined,combined) < color_culling_threshold)
		return;

	// FIXME split environment and other lights
	if (not_environment) {
		if (shadowed(P, light_dir_norm, light_dist + shadow_offset_fudge))
			return;
	} else {
		// for environment light check that we've hit SURF_SKY
		if (shadowedSky(P, light_dir_norm, light_dist + shadow_offset_fudge))
			return;
	}

	diffuse += ldiffuse;
	specular += lspecular;
}

void computePointLights(vec3 P, vec3 N, uint cluster_index, vec3 throughput, vec3 view_dir, MaterialProperties material, out vec3 diffuse, out vec3 specular) {
	diffuse = specular = vec3(0.);

	//diffuse = vec3(1.);//float(lights.m.num_point_lights) / 64.);
//#define USE_CLUSTERS
#ifdef USE_CLUSTERS
	const uint num_point_lights = uint(light_grid.clusters[cluster_index].num_point_lights);
	for (uint j = 0; j < num_point_lights; ++j) {
		const uint i = uint(light_grid.clusters[cluster_index].point_lights[j]);
#else
	for (uint i = 0; i < lights.m.num_point_lights; ++i) {
#endif

		sampleSinglePointLight(P, N, throughput, view_dir, material, lights.m.point_lights[i], diffuse, specular);

	} // for all lights
}
#endif

void computeLighting(vec3 P, vec3 N, vec3 throughput, vec3 view_dir, MaterialProperties material, out vec3 diffuse, out vec3 specular) {
	diffuse = specular = vec3(0.);

	const ivec3 light_cell = ivec3(floor(P / LIGHT_GRID_CELL_SIZE)) - light_grid.grid_min;
	const uint cluster_index = uint(dot(light_cell, ivec3(1, light_grid.grid_size.x, light_grid.grid_size.x * light_grid.grid_size.y)));

#ifdef USE_CLUSTERS
	if (any(greaterThanEqual(light_cell, light_grid.grid_size)) || cluster_index >= MAX_LIGHT_CLUSTERS)
		return; // throughput * vec3(1., 0., 0.);
#endif

	//diffuse = specular = vec3(1.);
	//return;

	// const uint cluster_offset = cluster_index * LIGHT_CLUSTER_SIZE + HACK_OFFSET;
	// const int num_dlights = int(light_grid.clusters_data[cluster_offset + LIGHT_CLUSTER_NUM_DLIGHTS_OFFSET]);
	// const int num_emissive_surfaces = int(light_grid.clusters_data[cluster_offset + LIGHT_CLUSTER_NUM_EMISSIVE_SURFACES_OFFSET]);
	// const uint emissive_surfaces_offset = cluster_offset + LIGHT_CLUSTER_EMISSIVE_SURFACES_DATA_OFFSET;
	//C = vec3(float(num_emissive_surfaces));

	//C = vec3(float(int(light_grid.clusters[cluster_index].num_emissive_surfaces)));
	//C += .3 * fract(vec3(light_cell) / 4.);

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
