#include "debug.glsl"

const float color_culling_threshold = 0;//600./color_factor;
const float shadow_offset_fudge = .1;

#ifndef RANDOM_LIGHTS_COUNT
#define RANDOM_LIGHTS_COUNT 8
#endif

#ifndef LIGHT_POINT
#define LIGHT_POINT
#endif

#ifndef LIGHT_POLYGON
#define LIGHT_POLYGON
#endif

#include "brdf.glsl"
#include "light_common.glsl"
#include "lighting_utils.glsl"
#include "light_polygon.glsl"

#define EPSILON 1e-4

float fbool(bool b) { return b ? 1.0 : 0.0; }

float specularWeight(vec3 N, vec3 L, vec3 V, float roughness)
{
    vec3 H = normalize(L + V);
    float NoH = max(dot(N, H), 0.0);

    float power = mix(128.0, 4.0, roughness * roughness);
    return pow(NoH, power);
}

struct LightResult {
    vec3 diffuse;
    vec3 specular;
    uint light_id;
};

uint getLightClusterIndex(vec3 P) {
    const ivec3 light_cell = ivec3(floor(P / LIGHT_GRID_CELL_SIZE)) - lights.m.grid_min_cell;
	const uint cluster_index = uint(dot(light_cell, ivec3(1, lights.m.grid_size.x, lights.m.grid_size.x * lights.m.grid_size.y)));
    return cluster_index;
}

uint getUnifiedLightsCount(uint cluster_index) {
    uint num_point = uint(light_grid.clusters_[cluster_index].num_point_lights);
    uint num_poly  = uint(light_grid.clusters_[cluster_index].num_polygons);
    return num_point + num_poly;
}

LightResult evalUnifiedLight(
    vec3 P, vec3 N, vec3 V,
    MaterialProperties material,
    uint pick,
    vec3 rnd,
    bool eval_brdf,
    bool enable_shadow,
    bool use_clusters)
{
    LightResult r = LightResult(vec3(0.0), vec3(0.0), -1);

	uint cluster_index = getLightClusterIndex(P);

    uint num_point = use_clusters ?
                        uint(light_grid.clusters_[cluster_index].num_point_lights) :
                        lights.m.num_point_lights;

    bool is_point = pick < num_point;

    // ------------------------------------------------------
    // compute L and geom_weight inside if (only for memory)
    // ------------------------------------------------------
    vec3 L;
    float dist;
    vec3 emissive_color;
    float geom_weight;

    if(is_point)
    {
        uint idx_point = use_clusters ? 
                            uint(light_grid.clusters_[cluster_index].point_lights[pick]) :
                            pick;

        r.light_id = idx_point;

        PointLight pl = lights.m.point_lights[idx_point];
        emissive_color = pl.color_stopdot.rgb;
        vec3 toL = pl.origin_r2.xyz - P;
        float dist2 = dot(toL,toL);

        if(pl.environment != 0)
        {
            // environment/directional light
            L = normalize(orthonormalBasisZ(pl.dir_stopdot2.xyz) * sampleConeZ(rnd.xy, pl.dir_stopdot2.a));
            //L = pl.dir_stopdot2.xyz;
            dist = 10000.;

            geom_weight = 2.0 * kPi * (1.0 - pl.dir_stopdot2.a);
        }
        else
        {
            // spherical / point light
            vec3 Lc = toL / max(sqrt(dist2), EPSILON);
            L = normalize(orthonormalBasisZ(Lc) * sampleConeZ(rnd.xy, sqrt(max(0.0, 1.0 - pl.origin_r2.w / max(dist2,EPSILON)))));
            //L = toL; // simple
            dist = length(L) - EPSILON;

            // spot attenuation
            float spot_dot = dot(L, pl.dir_stopdot2.xyz);
            float stopdot2 = pl.dir_stopdot2.a;
            float stopdot  = pl.color_stopdot.a;
            float spot_att = 1.0;
            if(spot_dot < stopdot) {
                spot_att = (spot_dot - stopdot2) / (stopdot - stopdot2);
            }
            geom_weight = 2.0 * kPi * (1.0 - sqrt(max(0.0,1.0 - pl.origin_r2.w / max(dist2,EPSILON)))) * spot_att;
        }
    }
    else
    {
        uint idx_poly  = use_clusters ? 
                            uint(light_grid.clusters_[cluster_index].polygons[pick - num_point]) :
                            pick - num_point;

        r.light_id = idx_poly + num_point;

        PolygonLight poly = lights.m.polygons[idx_poly];
		const float plane_dist = dot(poly.plane, vec4(P, 1.f));
		
        vec4 s = vec4(0.);
        if (plane_dist > 0.) {
            s = getPolygonLightSampleSimpleSolid(P, V, poly, rnd);
            //vec4 s = getPolygonLightSampleSimple(P, V, poly, rnd);
            //vec4 s = getPolygonLightSampleStupid(P, poly);
            dist = - plane_dist / dot(s.xyz, poly.plane.xyz);
            L = s.xyz;
        }
        geom_weight = s.w;
        emissive_color = poly.emissive;
    }

    if (geom_weight > 0.0) {

        bool shadow_vis = false;
        if (enable_shadow) {
           shadow_vis = shadowed(P, L, dist);
        }

        if (!shadow_vis) {
            if (eval_brdf) {
                vec3 d, s;
                evalDecolorizedBRDF(N, L, V, emissive_color * geom_weight, material, d, s);
                r.diffuse  = d;
                r.specular = s;
            } else {
                float lum = luminance(emissive_color);
                float spec_weight = specularWeight(N, L, V, material.roughness);
                r.diffuse  = vec3(geom_weight * lum);
                r.specular = vec3(spec_weight * geom_weight * lum);
            }
        }
    }

    return r;
}


LightResult evalRandomUnifiedLight(
    vec3 P, vec3 N, vec3 V,
    MaterialProperties material,
    vec3 sampling_rand,
    float pick_random,
    bool eval_brdf,
    bool enable_shadow)
{
    uint cluster_index = getLightClusterIndex(P);
    uint total = getUnifiedLightsCount(cluster_index);
    
    if(total == 0) {
        return LightResult(vec3(0.0), vec3(0.0), -1);
    }

    uint pick = min(uint(pick_random * float(total)), total - 1u);

    return evalUnifiedLight(P, N, V, material, pick, sampling_rand, eval_brdf, enable_shadow, true);
}

LightResult calculateUnifiedLight(
    vec3 P, vec3 N, vec3 V,
    MaterialProperties material,
    vec3 sampling_rand,
    bool eval_brdf,
    bool enable_shadow)
{
	uint cluster_index = getLightClusterIndex(P);
    uint total = getUnifiedLightsCount(cluster_index);
    
    LightResult r = LightResult(vec3(0.0), vec3(0.0), -1);

    if(total == 0)
        return r;

    for (uint i = 0; i < total; i++) {
        LightResult l = evalUnifiedLight(P, N, V, material, i, sampling_rand, eval_brdf, enable_shadow, true);    
        r.diffuse += l.diffuse;
        r.specular += l.specular;
    }

    return r;
}

struct LightRandomPickData {
    float curr_weight;
    float weights_sum;
    float pick_random;
    float pdf;
    float pdf_sum;
    uint pick_id;
};

#ifdef UNIFIED_LIGHTS_IMPORTANCE

#define PASS_WEIGHTS_SUM 0
#define PASS_RUSSIAN_ROULETTE 1
LightResult calculateUnifiedLightImportance(
    vec3 P, vec3 N, vec3 V,
    MaterialProperties material,
    vec3 sampling_rand,
    bool eval_brdf,
    bool enable_shadow,
    ivec2 pix)
{
	uint cluster_index = getLightClusterIndex(P);
    uint total = getUnifiedLightsCount(cluster_index);
    
    LightResult r = LightResult(vec3(0.0), vec3(0.0), -1);

    if(total > 0) {
        bool iterate_all = total <= RANDOM_LIGHTS_COUNT;

        uint first_light_id = uint(rand01() * float(total));
        float pdf = iterate_all ? 1.0 : float(total) / float(RANDOM_LIGHTS_COUNT);

        LightRandomPickData diff_pick = LightRandomPickData(0,0,0,0,0,-1);
        LightRandomPickData spec_pick = LightRandomPickData(0,0,0,0,0,-1);

        for (uint pass = 0; pass < 2; pass++) {
            for (uint i = 0; i < RANDOM_LIGHTS_COUNT; i++) { // always fixed cycle
                bool out_of_bounds = iterate_all && i >= total;
                if (!out_of_bounds) {
                    uint light_id = iterate_all ? i : (first_light_id + i) % total;

                    LightResult l = evalUnifiedLight(P, N, V, material, light_id, sampling_rand, eval_brdf, false, true);

                    float diff_weight = luminance(l.diffuse);
                    diff_pick.weights_sum += diff_weight;

                    float spec_weight = luminance(l.specular);
                    spec_pick.weights_sum += spec_weight;

                    if (pass == PASS_RUSSIAN_ROULETTE) {
                        if (diff_weight > 0.0 && diff_pick.pick_id == -1 && diff_pick.pick_random <= diff_pick.weights_sum) {
                            diff_pick.pick_id = light_id;
                            diff_pick.pdf = diff_weight / diff_pick.pdf_sum;
                        }

                        if (spec_weight > 0.0 && spec_pick.pick_id == -1 && spec_pick.pick_random <= spec_pick.weights_sum) {
                            spec_pick.pick_id = light_id;
                            spec_pick.pdf = spec_weight / spec_pick.pdf_sum;
                        }
                    }
                }

                if (pass == PASS_WEIGHTS_SUM) {
                    const float rnd = rand01();
                    diff_pick.pick_random = rnd * diff_pick.weights_sum;
                    diff_pick.pdf_sum = diff_pick.weights_sum;
                    diff_pick.weights_sum = 0.0;

                    spec_pick.pick_random = rnd * spec_pick.weights_sum;
                    spec_pick.pdf_sum = spec_pick.weights_sum;
                    spec_pick.weights_sum = 0.0;
                }
            }
        }

        if (diff_pick.pick_id != -1 && diff_pick.pdf > 0.0) {
            LightResult l = evalUnifiedLight(P, N, V, material, diff_pick.pick_id, sampling_rand, eval_brdf, true, true);
            r.diffuse += l.diffuse / diff_pick.pdf;
        }

        if (spec_pick.pick_id != -1 && spec_pick.pdf > 0.0) {
            LightResult l = evalUnifiedLight(P, N, V, material, spec_pick.pick_id, sampling_rand, eval_brdf, true, true);
            r.specular += l.specular / spec_pick.pdf;
        }
    }

    return r;
}
#undef PASS_WEIGHTS_SUM
#undef PASS_RUSSIAN_ROULETTE
#endif // UNIFIED_LIGHTS_IMPORTANCE

LightResult calculateUnifiedLightsRandom(
    vec3 P, vec3 N, vec3 V,
    MaterialProperties material,
    vec3 sampling_rand,
    bool eval_brdf,
    bool enable_shadow)
{
	uint cluster_index = getLightClusterIndex(P);
    uint total = getUnifiedLightsCount(cluster_index);
    
    LightResult r = LightResult(vec3(0.0), vec3(0.0), -1);

    if(total == 0)
        return r;

    float pdf = float(total) / float(RANDOM_LIGHTS_COUNT);

    for (uint i = 0; i < RANDOM_LIGHTS_COUNT; i++) {
        LightResult l = evalRandomUnifiedLight(P, N, V, material, sampling_rand, rand01(), eval_brdf, enable_shadow);
        r.diffuse += l.diffuse * pdf;
        r.specular += l.specular * pdf;
    }

    return r;
}
