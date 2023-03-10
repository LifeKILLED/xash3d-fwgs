#include "utils.glsl"
#include "noise.glsl"
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
#define LIGHT_WEIGHT_MAX_VALUE 10.

// use this normal type for simple weight calculating
#define LIGHT_WEIGHT_NORMAL shading_normal


layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 10, rgba32f) uniform readonly image2D SRC_FIRST_POSITION;
layout(set = 0, binding = 11, rgba32f) uniform readonly image2D SRC_POSITION;
layout(set = 0, binding = 12, rgba16f) uniform readonly image2D SRC_NORMALS;
layout(set = 0, binding = 13, rgba8) uniform readonly image2D SRC_MATERIAL;
layout(set = 0, binding = 14, rgba8) uniform readonly image2D SRC_BASE_COLOR;

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
	const vec4 n = imageLoad(SRC_NORMALS, uv);
	geometry_normal = normalDecode(n.xy);
	shading_normal = normalDecode(n.zw);
}

float polyWeight(const PolygonLight poly, const vec3 P, const vec3 N) {
	const vec3 dir = poly.center - P;
	const float coplanar = 1. - clamp(dot(normalize(poly.plane.xyz), -normalize(dir)), 0., 1.);
	const float coplanar_pow = 1. - coplanar * coplanar;
	const float dist = 1. / dot(dir, dir);
	const float shading = dot(N, normalize(dir));
	return clamp(dist * shading * coplanar_pow * luminance(poly.emissive), 0.0, LIGHT_WEIGHT_MAX_VALUE);
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

	const vec4 material_data = imageLoad(SRC_MATERIAL, pix);
	const vec3 base_color_a = SRGBtoLINEAR(imageLoad(SRC_BASE_COLOR, pix).rgb);

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

	const vec3 pos = imageLoad(SRC_POSITION, pix).xyz + geometry_normal * 0.1;


	
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
	
			const vec3 first_pos = imageLoad(SRC_FIRST_POSITION, first_pix).xyz;

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
		const vec3 primary_pos = imageLoad(SRC_FIRST_POSITION, pix).xyz;
		const vec3 view_dir = normalize(primary_pos - pos);
	#endif

		const vec3 throughput = vec3(1.);

		const vec3 P = pos + geometry_normal * .001;

		const ivec3 light_cell = ivec3(floor(P / LIGHT_GRID_CELL_SIZE)) - lights.m.grid_min_cell;
		const uint cluster_index = uint(dot(light_cell, ivec3(1, lights.m.grid_size.x, lights.m.grid_size.x * lights.m.grid_size.y)));

	#ifdef CLUSTERS_IN_ADAPT_SAMPLING
		const uint num_polygons = uint(light_grid.clusters_[cluster_index].num_polygons);
	#else
		const uint num_polygons = lights.m.num_polygons;
	#endif

		if (num_polygons == 0)
			return;

		float light_weights_sum = 0.;

	#ifdef RANDOM_REGULAR_SAMPLES
		const uint start = num_polygons > REGULAR_SAMPLES ? rand_range(num_polygons - REGULAR_SAMPLES) : 0;
		const uint random_end = start + REGULAR_SAMPLES;
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

			const float curr_weight = polyWeight(poly, P, LIGHT_WEIGHT_NORMAL);
			light_weights_sum += curr_weight;
		}

		if (light_weights_sum > 0.) {
			float sample_random_pos[ADAPT_LIGHTS_COUNT];
			int sampled_id[ADAPT_LIGHTS_COUNT];
			//float sampled_probability[ADAPT_LIGHTS_COUNT];

			for (uint a = 0; a < ADAPT_LIGHTS_COUNT; a++) {
				sample_random_pos[a] = rand01() * light_weights_sum;
				sampled_id[a] = -1;
				//sampled_probability[a] = 0.001;
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
				const float curr_weight = polyWeight(poly, P, LIGHT_WEIGHT_NORMAL);

				sample_rnd_start = sample_rnd_end;
				sample_rnd_end += curr_weight;

				for (uint a = 0; a < ADAPT_LIGHTS_COUNT; a++) {
					if (sample_random_pos[a] > sample_rnd_start && sample_random_pos[a] < sample_rnd_end) {
						sampled_id[a] = int(selected);
						//sampled_probability[a] = (curr_weight / light_weights_sum);
					}
				}
			}

			const SampleContext ctx = buildSampleContext(P, shading_normal, view_dir);

			vec3 curr_diffuse = vec3(0.), curr_specular = vec3(0.);
			for (uint a = 0; a < ADAPT_LIGHTS_COUNT; a++) {
				if (sampled_id[a] != -1) {
					const PolygonLight poly = lights.m.polygons[sampled_id[a]];
					sampleSinglePolygonLight(P, shading_normal, view_dir, ctx, material, poly, curr_diffuse, curr_specular);
					diffuse += curr_diffuse /*/ sampled_probability[a]*/;
					specular += curr_specular /*/ sampled_probability[a]*/;
				}
			}

			diffuse /= float(ADAPT_LIGHTS_COUNT);
			specular /= float(ADAPT_LIGHTS_COUNT);
		}
	}

#if OUT_SEPARATELY
	imageStore(OUT_DIFFUSE, pix, vec4(diffuse, 0.));
	imageStore(OUT_SPECULAR, pix, vec4(specular, 0.));
#else
	imageStore(OUT_LIGHTING, pix, vec4(diffuse + specular, 0.));
#endif
}
