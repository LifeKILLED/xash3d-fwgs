#include "utils.glsl"
#include "noise.glsl"
#include "lk_dnsr_config.glsl"
#include "lk_dnsr_utils.glsl"
#include "color_spaces.glsl"

#define GLSL
#include "ray_interop.h"
#undef GLSL


// calculate weights only for this random lights in texel
//#define RANDOM_REGULAR_SAMPLES 32

// final lights count with heavy sampling and ray tracing
#define ADAPT_LIGHTS_COUNT 1

// clusters can be harder for memory bandwidth
#define CLUSTERS_IN_ADAPT_SAMPLING 1

// max value for simple light weight calculating
#define LIGHT_WEIGHT_MAX_VALUE 0.1

#define LIGHT_WEIGHT_MIN_VALUE 0.0

// use this normal type for simple weight calculating
#define LIGHT_WEIGHT_NORMAL shading_normal

// random choose of light and put in texture for sampling in separately shader
//#define LIGHT_CHOOSE_PASS 1

// use texture with chosen lights data for sampling
//#define LIGHT_SAMPLE_PASS 1

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 10, rgba32f) uniform readonly image2D SRC_FIRST_POSITION;
layout(set = 0, binding = 11, rgba32f) uniform readonly image2D SRC_POSITION;
layout(set = 0, binding = 12, rgba16f) uniform readonly image2D SRC_NORMALS;
layout(set = 0, binding = 13, rgba8) uniform readonly image2D SRC_MATERIAL;
layout(set = 0, binding = 14, rgba8) uniform readonly image2D SRC_BASE_COLOR;
layout(set = 0, binding = 15, rgba16f) uniform readonly image2D blue_noise;

#if LIGHT_SAMPLE_PASS
layout(set = 0, binding = 16, rgba16f) uniform readonly image2D SRC_LIGHTS_CHOSEN;
#endif

#if OUT_SEPARATELY
	layout(set=0, binding=20, rgba16f) uniform writeonly image2D OUT_DIFFUSE;
	layout(set=0, binding=21, rgba16f) uniform writeonly image2D OUT_SPECULAR;
#else
	layout(set=0, binding=20, rgba16f) uniform writeonly image2D OUT_LIGHTING;
#endif

layout(set = 0, binding = 1) uniform accelerationStructureEXT tlas;
layout(set = 0, binding = 2) uniform UBO { UniformBuffer ubo; } ubo;

#include "ray_kusochki.glsl"

#undef SHADER_OFFSET_HIT_SHADOW_BASE
#define SHADER_OFFSET_HIT_SHADOW_BASE 0
#undef SHADER_OFFSET_MISS_SHADOW
#define SHADER_OFFSET_MISS_SHADOW 0
#undef PAYLOAD_LOCATION_SHADOW
#define PAYLOAD_LOCATION_SHADOW 0

#define BINDING_LIGHTS 7
#define BINDING_LIGHT_CLUSTERS 8
#include "light.glsl"

void readNormals(ivec2 uv, out vec3 geometry_normal, out vec3 shading_normal) {
	const vec4 n = FIX_NAN(imageLoad(SRC_NORMALS, uv));
	geometry_normal = normalDecode(n.xy);
	shading_normal = normalDecode(n.zw);
}

float polyWeight(const PolygonLight poly, const vec3 P, const vec3 N) {
	const vec3 dir = poly.center - P;
	const float coplanar = 1. - clamp(dot(normalize(poly.plane.xyz), -normalize(dir)), 0., 1.);
	const float coplanar_pow = 1. - coplanar * coplanar;
	const float dist = LIGHT_WEIGHT_MIN_VALUE + 1. / dot(dir, dir);
	const float shading = dot(N, normalize(dir));
	const float weight = dist * shading * coplanar_pow * luminance(poly.emissive);
	return clamp(weight, 0., LIGHT_WEIGHT_MAX_VALUE);
}

vec3 polyShadingApproximate(const PolygonLight poly, const vec3 P, const vec3 N) {
	const vec3 dir = poly.center - P;
	const float coplanar = 1. - clamp(dot(normalize(poly.plane.xyz), -normalize(dir)), 0., 1.);
	const float coplanar_pow = 1. - coplanar * coplanar;
	const float dist = LIGHT_WEIGHT_MIN_VALUE + 1. / dot(dir, dir);
	const float shading = dot(N, normalize(dir));
	return max(vec3(0.), (poly.area / 4.) * dist * shading * coplanar_pow * poly.emissive);
}

float PackLightIndexAndProbability(int index, float probability) {
	if (probability == 0.)
		return -1.; // guaranted void value, fix float inaccuracy

	// pack id in whole number and probability in mantissa
	return float(index) + min(0.99, probability);
}

void UnpackLightIndexAndProbability(float light_id_probability, out int index, out float probability) {
	if (light_id_probability < 0.)
	{
		index = -1; // guaranted void value, fix float inaccuracy
		probability = 0.;
	}
	else
	{
		index = int(light_id_probability);
		probability = light_id_probability - float(index);
	}
}

void main() {
	const ivec2 pix = ivec2(gl_GlobalInvocationID);
	const ivec2 res = ivec2(imageSize(SRC_MATERIAL));
	rand01_state = ubo.ubo.random_seed + pix.x * 1833 + pix.y * 31337;

	// FIXME incorrect for reflection/refraction
	const ivec3 pix_src = CheckerboardToPix(pix, res);
	const vec2 uv = PixToUV(pix_src.xy, res);
	const vec4 target    = ubo.ubo.inv_proj * vec4(uv.x, uv.y, 1, 1);
	const vec3 direction = normalize((ubo.ubo.inv_view * vec4(target.xyz, 0)).xyz);

	vec3 regular_diffuse = vec3(0.), regular_specular = vec3(0.);
	vec3 diffuse = vec3(0.), specular = vec3(0.);
	vec4 lightWeightsIndices = vec4(-1.);

	const vec4 material_data = FIX_NAN(imageLoad(SRC_MATERIAL, pix));
	const vec3 base_color_a = SRGBtoLINEAR(FIX_NAN(imageLoad(SRC_BASE_COLOR, pix)).rgb);

	if (any(equal(base_color_a, vec3(0.)))) {
	#if OUT_SEPARATELY
		imageStore(OUT_DIFFUSE, pix, vec4(0.));
		imageStore(OUT_SPECULAR, pix, vec4(0.));
	#else
		imageStore(OUT_LIGHTING, pix, vec4(0.));
	#endif
		return;
	}

	MaterialProperties material;
	
#ifdef GRAY_MATERIAL
	material.baseColor = vec3(1.);
#else
	material.baseColor = base_color_a;
#endif
#ifdef GLOBAL_ILLUMINATION
	material.metalness = 0.;
	material.roughness = 1.;
#else
	material.metalness = material_data.g;
	material.roughness = material_data.r;
#endif
	material.emissive = vec3(0.f);	

	vec3 geometry_normal, shading_normal;
	readNormals(pix, geometry_normal, shading_normal);

	const vec3 pos = FIX_NAN(imageLoad(SRC_POSITION, pix)).xyz + geometry_normal * 0.1;
	
#if REUSE_SCREEN_LIGHTING

	// Try to use SSR and put this UV to output texture if all is OK
	uint lighting_is_reused = 0;
	const vec3 origin = (ubo.ubo.inv_view * vec4(0, 0, 0, 1)).xyz;

	// can we see it in reflection?
	if (dot(direction, pos - origin) > .0) {
		const ivec2 res = ivec2(imageSize(SRC_FIRST_POSITION));
		const vec2 first_uv = WorldPositionToUV(pos, inverse(ubo.ubo.inv_proj), inverse(ubo.ubo.inv_view));
		const ivec2 first_pix = UVToPix(first_uv, res);

		if (any(greaterThanEqual(first_pix, ivec2(0))) && any(lessThan(first_pix, res))) {
	
			const vec3 first_pos = FIX_NAN(imageLoad(SRC_FIRST_POSITION, first_pix)).xyz;

			const float nessesary_depth = length(origin - pos);
			const float current_depth = length(origin - first_pos);

			if (abs(nessesary_depth - current_depth) < 2.) {
				lighting_is_reused = 1;
				diffuse = vec3(first_uv, -100.); // -100 it's SSR marker
			}
		}
	}

	if (lighting_is_reused != 1) {

	#if REFLECTIONS
		material.baseColor = base_color_a; // mix lighting with base color if it's not SSR
	#endif
#else
	{
#endif // REUSE_SCREEN_LIGHTING

	#if PRIMARY_VIEW
		const vec3 view_dir = -direction;
	#else
		const vec3 primary_pos = FIX_NAN(imageLoad(SRC_FIRST_POSITION, pix)).xyz;
		const vec3 view_dir = normalize(primary_pos - pos);
	#endif

		const vec3 throughput = vec3(1.);
		const vec3 P = pos + geometry_normal * .001;

		float sample_random_pos[ADAPT_LIGHTS_COUNT] = {0.0f};
		int sampled_id[ADAPT_LIGHTS_COUNT] = {-1};
		float sampled_probability[ADAPT_LIGHTS_COUNT] = {0.0f};

#ifndef LIGHT_SAMPLE_PASS // - need to choose lights by random

	#ifdef CLUSTERS_IN_ADAPT_SAMPLING
		const ivec3 light_cell = ivec3(floor(P / LIGHT_GRID_CELL_SIZE)) - lights.m.grid_min_cell;
		const uint cluster_index = uint(dot(light_cell, ivec3(1, lights.m.grid_size.x, lights.m.grid_size.x * lights.m.grid_size.y)));
		const uint num_polygons = uint(light_grid.clusters_[cluster_index].num_polygons);
	#else
		const uint num_polygons = lights.m.num_polygons;
	#endif

		if (num_polygons == 0)
			return;

		float light_weights_sum = 0.;

	#ifdef RANDOM_REGULAR_SAMPLES
		const uint start = num_polygons > RANDOM_REGULAR_SAMPLES ? rand_range(num_polygons - RANDOM_REGULAR_SAMPLES) : 0;
		const uint random_end = start + RANDOM_REGULAR_SAMPLES;
		const uint end = random_end < num_polygons ? random_end : num_polygons;
	#else
		const uint start = 0;
		const uint end = num_polygons;
	#endif

		const float sampling_factor = float(num_polygons) / float(end - start);
		for (uint i = start; i < end; i++) {

		#ifdef CLUSTERS_IN_ADAPT_SAMPLING
			const uint selected = uint(light_grid.clusters_[cluster_index].polygons[i]);
		#else
			const uint selected = i;
		#endif

			vec3 curr_diffuse = vec3(0.), curr_specular = vec3(0.);
			const PolygonLight poly = lights.m.polygons[selected];

			const float curr_weight = luminance(polyShadingApproximate(poly, P, LIGHT_WEIGHT_NORMAL));
			light_weights_sum += curr_weight;
		}

		if (light_weights_sum > 0.) {
			for (uint a = 0; a < ADAPT_LIGHTS_COUNT; a++) {
				//sample_random_pos[a] = rand01() * light_weights_sum;
				sample_random_pos[a] = FIX_NAN(imageLoad(blue_noise, pix)).x * light_weights_sum;
				sampled_id[a] = -1;
				sampled_probability[a] = 0.;
			}

			float sample_rnd_start = 0.;
			float sample_rnd_end = 0.;
			for (uint i = start; i < end; i++) {

			#ifdef CLUSTERS_IN_ADAPT_SAMPLING
				const uint selected = uint(light_grid.clusters_[cluster_index].polygons[i]);
			#else
				const uint selected = i;
			#endif

				const PolygonLight poly = lights.m.polygons[selected];
				const float curr_weight = luminance(polyShadingApproximate(poly, P, LIGHT_WEIGHT_NORMAL));

				sample_rnd_start = sample_rnd_end;
				sample_rnd_end += curr_weight;

				for (uint a = 0; a < ADAPT_LIGHTS_COUNT; a++) {
					if (sample_random_pos[a] > sample_rnd_start && sample_random_pos[a] < sample_rnd_end) {
						sampled_id[a] = int(selected);
						sampled_probability[a] = (curr_weight / light_weights_sum);
					}
				}
			}
		}

#endif // not LIGHT_SAMPLE_PASS - need to choose lights by random


#ifdef LIGHT_CHOOSE_PASS // save lights ids in diffuse channel and write it in out texture

		// TODO: how do this better?
	#if (ADAPT_LIGHTS_COUNT == 1)
		lightWeightsIndices.x = float(sampled_id[0]);
		lightWeightsIndices.y = sampled_probability[0];
	#elif (ADAPT_LIGHTS_COUNT == 2)
		lightWeightsIndices.x = float(sampled_id[0]);
		lightWeightsIndices.y = sampled_probability[0];
		lightWeightsIndices.z = float(sampled_id[1]);
		lightWeightsIndices.w = sampled_probability[1];
	#else
		int i = 0;
		if (i < ADAPT_LIGHTS_COUNT) lightWeightsIndices.x = PackLightIndexAndProbability(sampled_id[i], sampled_probability[i++]);
		if (i < ADAPT_LIGHTS_COUNT) lightWeightsIndices.y = PackLightIndexAndProbability(sampled_id[i], sampled_probability[i++]);
		if (i < ADAPT_LIGHTS_COUNT) lightWeightsIndices.z = PackLightIndexAndProbability(sampled_id[i], sampled_probability[i++]);
		if (i < ADAPT_LIGHTS_COUNT) lightWeightsIndices.w = PackLightIndexAndProbability(sampled_id[i], sampled_probability[i++]);
	#endif

#else // not LIGHT_CHOOSE_PASS - make true samples with rays

#ifdef LIGHT_SAMPLE_PASS 

		// fill chosen lights array by image buffer from separated pass
		const vec4 lightIndecesAndWeightes = FIX_NAN(imageLoad(SRC_LIGHTS_CHOSEN, pix));

		// TODO: how do this better?
	#if (ADAPT_LIGHTS_COUNT == 1)
		sampled_id[0] =		 int(lightIndecesAndWeightes.x);
		sampled_probability[0] = lightIndecesAndWeightes.y;
	#elif (ADAPT_LIGHTS_COUNT == 2)
		sampled_id[0] =		 int(lightIndecesAndWeightes.x);
		sampled_probability[0] = lightIndecesAndWeightes.y;
		sampled_id[1] =		 int(lightIndecesAndWeightes.z);
		sampled_probability[1] = lightIndecesAndWeightes.w;
	#else
		int i = 0;
		if (i < ADAPT_LIGHTS_COUNT) UnpackLightIndexAndProbability(lightIndecesAndWeightes.x, sampled_id[i], sampled_probability[i++]);
		if (i < ADAPT_LIGHTS_COUNT) UnpackLightIndexAndProbability(lightIndecesAndWeightes.y, sampled_id[i], sampled_probability[i++]);
		if (i < ADAPT_LIGHTS_COUNT) UnpackLightIndexAndProbability(lightIndecesAndWeightes.z, sampled_id[i], sampled_probability[i++]);
		if (i < ADAPT_LIGHTS_COUNT) UnpackLightIndexAndProbability(lightIndecesAndWeightes.w, sampled_id[i], sampled_probability[i++]);
	#endif
#endif // LIGHT_SAMPLE_PASS

		const SampleContext ctx = buildSampleContext(P, shading_normal, view_dir);
		vec3 curr_diffuse = vec3(0.), curr_specular = vec3(0.);

		for (uint a = 0; a < ADAPT_LIGHTS_COUNT; a++) {
			if (sampled_id[a] != -1 && sampled_probability[a] > 0.) {
				const PolygonLight poly = lights.m.polygons[sampled_id[a]];
				//if (pix_src.x < res.x / 2) {
					sampleSinglePolygonLight(P, shading_normal, view_dir, ctx, material, poly, curr_diffuse, curr_specular);
				//} else {
				//	curr_diffuse = polyShadingApproximate(poly, P, LIGHT_WEIGHT_NORMAL);
				//}
				diffuse += curr_diffuse / sampled_probability[a];
				specular += curr_specular / sampled_probability[a];
			}
		}

		//diffuse = vec3(light_weights_sum);
		//specular *= 10.;

		diffuse /= 25. * float(ADAPT_LIGHTS_COUNT);
		specular /= 25. * float(ADAPT_LIGHTS_COUNT);

		
#endif // not LIGHT_CHOOSE_PASS - make true samples with rays

	}
#if LIGHT_CHOOSE_PASS
	imageStore(OUT_LIGHTING, pix, lightWeightsIndices);
#elif OUT_SEPARATELY
	imageStore(OUT_DIFFUSE, pix, vec4(diffuse, 0.));
	imageStore(OUT_SPECULAR, pix, vec4(specular, 0.));
#else
	imageStore(OUT_LIGHTING, pix, vec4(diffuse + specular, 0.));
#endif
}
