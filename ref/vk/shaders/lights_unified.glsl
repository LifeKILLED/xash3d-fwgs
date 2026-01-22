#include "debug.glsl"

const float color_culling_threshold = 0;//600./color_factor;
const float shadow_offset_fudge = .1;

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
};

uint getLightClusterIndex(vec3 P) {
    const ivec3 light_cell = ivec3(floor(P / LIGHT_GRID_CELL_SIZE)) - lights.m.grid_min_cell;
	const uint cluster_index = uint(dot(light_cell, ivec3(1, lights.m.grid_size.x, lights.m.grid_size.x * lights.m.grid_size.y)));
    return cluster_index;
}

LightResult evalUnifiedLight(
    vec3 P, vec3 N, vec3 V,
    MaterialProperties material,
    uint pick,
    vec3 rnd,
    bool eval_brdf,
    bool enable_shadow)
{
    LightResult r = LightResult(vec3(0.0), vec3(0.0));

	uint cluster_index = getLightClusterIndex(P);

    uint num_point = uint(light_grid.clusters_[cluster_index].num_point_lights);
    bool is_point = pick < num_point;

    // ------------------------------------------------------
    // compute L and geom_weight inside if (only for memory)
    // ------------------------------------------------------
    vec3 L;
    vec3 emissive_color;
    float geom_weight;

    if(is_point)
    {
        uint idx_point = uint(light_grid.clusters_[cluster_index].point_lights[pick]);
        PointLight pl = lights.m.point_lights[idx_point];
        emissive_color = pl.color_stopdot.rgb;
        vec3 toL = pl.origin_r2.xyz - P;
        float dist2 = dot(toL,toL);

        if(pl.environment != 0)
        {
            // environment/directional light
            vec3 L = normalize(orthonormalBasisZ(pl.dir_stopdot2.xyz) * sampleConeZ(rnd.xy, pl.dir_stopdot2.a));
            //vec3 L = pl.dir_stopdot2.xyz;

            geom_weight = 2.0 * kPi * (1.0 - pl.dir_stopdot2.a);
        }
        else
        {
            // spherical / point light
            vec3 Lc = toL / max(sqrt(dist2), EPSILON);
            vec3 L = normalize(orthonormalBasisZ(Lc) * sampleConeZ(rnd.xy, sqrt(max(0.0, 1.0 - pl.origin_r2.w / max(dist2,EPSILON)))));

            //vec3 L = toL;

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
        uint idx_poly  = uint(light_grid.clusters_[cluster_index].polygons[pick - num_point]);
        PolygonLight poly = lights.m.polygons[idx_poly];
        vec4 s = getPolygonLightSampleSimple(P, V, poly, rnd);
        //vec4 s = getPolygonLightSampleStupid(P, poly);
        L = s.xyz;
        geom_weight = s.w;
        emissive_color = poly.emissive;
    }

    bool shadow_vis = false;
    if (enable_shadow && geom_weight > 0.001) {
        shadow_vis = shadowed(P, L, length(L) - EPSILON);
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

    uint num_point = uint(light_grid.clusters_[cluster_index].num_point_lights);
    uint num_poly  = uint(light_grid.clusters_[cluster_index].num_polygons);
    uint total = num_point + num_poly;
    
    if(total == 0) {
        return LightResult(vec3(0.0), vec3(0.0));
    }

    uint pick = min(uint(pick_random * float(total)), total - 1u);

    return evalUnifiedLight(P, N, V, material, pick, sampling_rand, eval_brdf, enable_shadow);
}

LightResult calculateUnifiedLight(
    vec3 P, vec3 N, vec3 V,
    MaterialProperties material,
    vec3 sampling_rand,
    bool eval_brdf,
    bool enable_shadow)
{
	uint cluster_index = getLightClusterIndex(P);

    uint num_point = uint(light_grid.clusters_[cluster_index].num_point_lights);
    uint num_poly  = uint(light_grid.clusters_[cluster_index].num_polygons);
    uint total = num_point + num_poly;
    
    LightResult r = LightResult(vec3(0.0), vec3(0.0));

    if(total == 0)
        return r;

    for (uint i = 0; i < total; i++) {
        LightResult l = evalUnifiedLight(P, N, V, material, i, sampling_rand, eval_brdf, enable_shadow);    
        r.diffuse += l.diffuse;
        r.specular += l.specular;
    }

    return r;
}

LightResult calculateUnifiedLightImportance(
    vec3 P, vec3 N, vec3 V,
    MaterialProperties material,
    vec3 sampling_rand,
    bool eval_brdf,
    bool enable_shadow)
{
	uint cluster_index = getLightClusterIndex(P);

    uint num_point = uint(light_grid.clusters_[cluster_index].num_point_lights);
    uint num_poly  = uint(light_grid.clusters_[cluster_index].num_polygons);
    uint total = num_point + num_poly;
    
    LightResult r = LightResult(vec3(0.0), vec3(0.0));

    if(total == 0)
        return r;

    uint samples_count = 16;

    float pdf = float(total) / float(samples_count);

    for (uint i = 0; i < samples_count; i++) {
        LightResult l = evalRandomUnifiedLight(P, N, V, material, sampling_rand, rand01(), true, false);
        r.diffuse += l.diffuse * pdf;
        r.specular += l.specular * pdf;
    }

    return r;
}
