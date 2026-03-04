#ifndef LIGHTS_UNIFIED_GLSL
#define LIGHTS_UNIFIED_GLSL

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
#include "poisson-disk-8x8.glsl"

#define EPSILON 1e-2

#ifndef SHADOW_RAY_ORIGIN_BIAS
#define SHADOW_RAY_ORIGIN_BIAS 0.2
#endif

#ifndef SHADOW_RAY_DISTANCE_EPSILON
#define SHADOW_RAY_DISTANCE_EPSILON 0.2
#endif

#ifndef SHADOW_RAY_DOT_EPSILON
#define SHADOW_RAY_DOT_EPSILON 1e-4
#endif

#ifndef POLYGON_SELF_LIGHT_PLANE_BIAS
#define POLYGON_SELF_LIGHT_PLANE_BIAS 1.0
#endif

#ifndef POLYGON_SELF_LIGHT_FADE_RANGE
#define POLYGON_SELF_LIGHT_FADE_RANGE 2.0
#endif

#ifndef POLYGON_LIGHT_MIN_DENOM
#define POLYGON_LIGHT_MIN_DENOM 1e-4
#endif

float fbool(bool b) { return b ? 1.0 : 0.0; }

vec3 offsetShadowOrigin(vec3 P, vec3 N, vec3 L)
{
    const float nl = dot(N, L);
    float sign_n = (nl >= 0.0) ? 1.0 : -1.0;
    if (abs(nl) < SHADOW_RAY_DOT_EPSILON) {
        sign_n = 1.0;
    }
    return P + N * (sign_n * SHADOW_RAY_ORIGIN_BIAS);
}

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
    vec3 sampled_L;
    bool shadowed;
    uint light_id;
};

uint getLightClusterIndex(vec3 P) {
    const ivec3 light_cell = ivec3(floor(P / LIGHT_GRID_CELL_SIZE)) - lights.m.grid_min_cell;
	const uint cluster_index = uint(dot(light_cell, ivec3(1, lights.m.grid_size.x, lights.m.grid_size.x * lights.m.grid_size.y)));
    return cluster_index;
}

uint getLightsCountInCluster(uint cluster_index) {
    uint num_point = uint(light_grid.clusters_[cluster_index].num_point_lights);
    uint num_poly  = uint(light_grid.clusters_[cluster_index].num_polygons);
    return num_point + num_poly;
}

uint getLightsCountTotal() {
    uint num_point = uint(lights.m.num_point_lights);
    uint num_poly  = uint(lights.m.num_polygons);
    return num_point + num_poly;
}

uint decodeHistoryLightId(float encoded_id, out bool out_of_bound) {
    bool is_polygonal = encoded_id >= 0.0;
    if (is_polygonal) { // polygonal light
        uint id = uint(encoded_id);
        if (id >= lights.m.num_polygons) {
            out_of_bound = true;
            return 0;
        } else {
            out_of_bound = false;
            return id + lights.m.num_point_lights;
        }
    } else { // point light
        int raw_id = -int(encoded_id) - 1; // from negative value
        // HACK: invert pointlights order because flashlight is first
        // and indices are broken after removing flashlight from array.
        int id = (int(lights.m.num_point_lights) - 1) - raw_id;
        if (id >= int(lights.m.num_point_lights) || id < 0) {
            out_of_bound = true;
            return 0;
        } else {
            out_of_bound = false;
            return uint(id);
        }
    }
}

float encodeHistoryLightId(uint unified_id) {
    bool is_point = unified_id < lights.m.num_point_lights;
    if (is_point) { // point light
        // HACK: invert pointlights order because flashlight is first
        // and indices are broken after removing flashlight from array.
        uint id = (lights.m.num_point_lights - 1) - unified_id;
        return float(-int(id) - 1); // encode in negative value
    } else { // polygon light
        return float(unified_id - lights.m.num_point_lights);
    }
}

struct LightSamplingData {
    vec3 L;
    float dist;
    vec3 emissive_color;
    float geom_weight;
};

LightSamplingData calculatePointLightSamplingData(PointLight pl, vec3 P, vec3 rnd)
{
    LightSamplingData l = LightSamplingData(vec3(0.), 0., vec3(0.), 0.);

    l.emissive_color = pl.color_stopdot.rgb;

#ifdef LIMIT_LIGHT_LUMINANCE
    float lum = luminance(l.emissive_color);
    if (lum > 1.0) {
        l.emissive_color /= lum;
    }
#endif

    vec3 toL = pl.origin_r2.xyz - P;
    float dist2 = dot(toL,toL);

    if(pl.environment != 0)
    {
        // environment/directional light
#ifdef STUPID_POINT_LIGHT_SAMPLING
        l.L = pl.dir_stopdot2.xyz;
#else
        l.L = normalize(orthonormalBasisZ(pl.dir_stopdot2.xyz) * sampleConeZ(rnd.xy, pl.dir_stopdot2.a));
#endif
        l.dist = -10000.; // sky distance is negative

        l.geom_weight = 2.0 * kPi * (1.0 - pl.dir_stopdot2.a);
    }
    else
    {
        // spherical / point light
#ifdef STUPID_POINT_LIGHT_SAMPLING
        l.L = normalize(toL); // simple
#else
        vec3 Lc = toL / max(sqrt(dist2), EPSILON);
        l.L = normalize(orthonormalBasisZ(Lc) * sampleConeZ(rnd.xy, sqrt(max(0.0, 1.0 - pl.origin_r2.w / max(dist2,EPSILON)))));
#endif
        l.dist = length(toL);

        // spot attenuation
        float spot_dot = dot(l.L, pl.dir_stopdot2.xyz);
        float stopdot2 = pl.dir_stopdot2.a;
        float stopdot  = pl.color_stopdot.a;
        float spot_att = 1.0;
        if(spot_dot < stopdot) {
            spot_att = max(0.0, (spot_dot - stopdot2) / (stopdot - stopdot2));
        }
        l.geom_weight = 2.0 * kPi * (1.0 - sqrt(max(0.0,1.0 - pl.origin_r2.w / max(dist2,EPSILON)))) * spot_att;
    }

    return l;
}

LightSamplingData calculatePolygonLightSamplingData(PolygonLight poly, vec3 P, vec3 V, SampleContext ctx, vec3 rnd)
{
    LightSamplingData l = LightSamplingData(vec3(0.), 0., vec3(0.), 0.);

    const vec4 plane = normalizedPolygonPlane(poly);
    const float plane_dist = dot(plane, vec4(P, 1.f));

    if (plane_dist > POLYGON_SELF_LIGHT_PLANE_BIAS) {
#ifdef PROJECTED_LIGHT_SAMPLED_UNIFIED
        const vec4 s = getPolygonLightSampleProjected(V, ctx, poly, rnd); // slow and noisy
#else
#ifdef STUPID_POLYGON_SAMPLING
        //const vec4 s = getPolygonLightSampleStupid(P, poly); // poor
        const vec4 s = getPolygonLightSampleSimple(P, V, poly, vec3(0.5, 0.5, 0.5)); // not so fast and bad
#else
        //const vec4 s = getPolygonLightSampleSolid(P, V, ctx, poly, rnd); // slow
        const vec4 s = getPolygonLightSampleSimpleSolid(P, V, poly, rnd); // so so
        //const vec4 s = getPolygonLightSampleSimple(P, V, poly, rnd); // not so fast and bad
#endif
#endif
        const float denom = dot(s.xyz, plane.xyz);
        if (s.w > 0.0 && denom < -POLYGON_LIGHT_MIN_DENOM) {
            l.dist = max(0.0, -plane_dist / denom);
            l.L = s.xyz;
            float self_fade = smoothstep(
                POLYGON_SELF_LIGHT_PLANE_BIAS,
                POLYGON_SELF_LIGHT_PLANE_BIAS + POLYGON_SELF_LIGHT_FADE_RANGE,
                plane_dist);
            l.geom_weight = s.w * self_fade;
            l.emissive_color = poly.emissive;

        #ifdef LIMIT_LIGHT_LUMINANCE
            float lum = luminance(l.emissive_color);
            if (lum > 1.0) {
                l.emissive_color /= lum;
            }
        #endif
        }
    }

    return l;
}

void unifiedLightFinalShading(
    inout LightResult r,
    LightSamplingData l,
    vec3 P, vec3 N, vec3 V,
    MaterialProperties material,
    bool eval_brdf,
    bool enable_shadow)
{
    if (l.geom_weight > 0.0) {

        bool shadow_vis = false;

#ifndef DISABLE_RAYS
        if (enable_shadow && l.dist > 0.0) {
            const vec3 shadow_origin = offsetShadowOrigin(P, N, l.L);
            shadow_vis = shadowed(shadow_origin, l.L, max(0.0, l.dist - SHADOW_RAY_DISTANCE_EPSILON));
        }
#endif

        r.shadowed = shadow_vis;
        if (eval_brdf) {
            vec3 d, s;
            evalDecolorizedBRDF(N, l.L, V, l.emissive_color * l.geom_weight, material, d, s);
            r.diffuse  = d;
            r.specular = s;
        } else {
            float lum = luminance(l.emissive_color);
            float spec_weight = specularWeight(N, l.L, V, material.roughness);
            r.diffuse  = vec3(l.geom_weight * lum);
            r.specular = vec3(spec_weight * l.geom_weight * lum);
        }
    }
}

bool isFlashlightOrSky(uint light_id, vec3 origin, vec3 P, bool use_clusters)
{
	uint cluster_index = getLightClusterIndex(P);

    uint num_point = use_clusters ?
                        uint(light_grid.clusters_[cluster_index].num_point_lights) :
                        lights.m.num_point_lights;

    bool is_point = light_id < num_point;

    if(is_point)
    {
        uint idx_point = use_clusters ? 
                            uint(light_grid.clusters_[cluster_index].point_lights[light_id]) :
                            light_id;

        PointLight pl = lights.m.point_lights[idx_point];
        return pl.environment != 0 || pl.flashlight != 0;
    }

    return false;
}

LightResult sampleFlashlightAndSky(
    vec3 P, vec3 N, vec3 V,
    MaterialProperties material,
    vec3 rnd,
    vec3 origin,
    bool eval_brdf,
    bool enable_shadow,
    bool use_clusters)
{
	uint cluster_index = getLightClusterIndex(P);

    LightResult result = LightResult(vec3(0.0), vec3(0.0), vec3(0.0), false, 0);
    LightSamplingData sky = LightSamplingData(vec3(0.), 0., vec3(0.), 0.);

    uint num_point = use_clusters ?
                        uint(light_grid.clusters_[cluster_index].num_point_lights) :
                        lights.m.num_point_lights;

    for (uint i = 0; i < num_point; i++) {
        if (isFlashlightOrSky(i, origin, P, use_clusters)) { // all checks is in this function
            
            uint idx_point = use_clusters ?
                                uint(light_grid.clusters_[cluster_index].point_lights[i]) :
                                i;

            LightSamplingData l = calculatePointLightSamplingData(lights.m.point_lights[idx_point], P, rnd);

            bool need_to_separate_sky = enable_shadow && l.dist < 0.0;
            if (need_to_separate_sky) { // calculate sky shadow outside of loop for better perfomance
                sky = l;
            } else {                
                LightResult r = LightResult(vec3(0.0), vec3(0.0), vec3(0.0), false, 0);
                unifiedLightFinalShading(r, l, P, N, V, material, eval_brdf, enable_shadow);
                r.sampled_L = l.L;
                
                result.diffuse += r.diffuse;
                result.specular += r.specular;
            }
        }
    }

    if (enable_shadow && sky.dist < 0.0) {
        if (!shadowedSky(P, sky.L)) {

            LightResult r = LightResult(vec3(0.0), vec3(0.0), vec3(0.0), false, 0);
            unifiedLightFinalShading(r, sky, P, N, V, material, eval_brdf, false);
            r.sampled_L = sky.L;
            
            result.diffuse += r.diffuse;
            result.specular += r.specular;
        }
    }

    return result;
}

LightResult evalUnifiedLight(
    vec3 P, vec3 N, vec3 V,
    MaterialProperties material,
    SampleContext ctx,
    uint pick,
    vec3 rnd,
    bool eval_brdf,
    bool enable_shadow,
    bool use_clusters)
{
    LightResult r = LightResult(vec3(0.0), vec3(0.0), vec3(0.0), false, uint(-1));

	uint cluster_index = getLightClusterIndex(P);

    uint num_point = use_clusters ?
                        uint(light_grid.clusters_[cluster_index].num_point_lights) :
                        lights.m.num_point_lights;

    bool is_point = pick < num_point;

    // ------------------------------------------------------
    // compute L and geom_weight inside if (only for memory)
    // ------------------------------------------------------
    
    LightSamplingData l;

    if(is_point)
    {
        uint idx_point = use_clusters ? 
                            uint(light_grid.clusters_[cluster_index].point_lights[pick]) :
                            pick;

        r.light_id = idx_point;

        l = calculatePointLightSamplingData(lights.m.point_lights[idx_point], P, rnd);
    }
    else
    {
        uint idx_poly  = use_clusters ? 
                            uint(light_grid.clusters_[cluster_index].polygons[pick - num_point]) :
                            pick - num_point;

        r.light_id = idx_poly + lights.m.num_point_lights;

        l = calculatePolygonLightSamplingData(lights.m.polygons[idx_poly], P, V, ctx, rnd);		
    }

    unifiedLightFinalShading(r, l, P, N, V, material, eval_brdf, enable_shadow);
    r.sampled_L = l.L;

    return r;
}


LightResult evalRandomUnifiedLight(
    vec3 P, vec3 N, vec3 V,
    MaterialProperties material,
    SampleContext ctx,
    vec3 sampling_rand,
    float pick_random,
    bool eval_brdf,
    bool enable_shadow)
{
    uint cluster_index = getLightClusterIndex(P);
    uint total = getLightsCountInCluster(cluster_index);

    if(total == 0) {
        return LightResult(vec3(0.0), vec3(0.0), vec3(0.0), false, uint(-1));
    }

    uint pick = min(uint(pick_random * float(total)), total - 1u);

    return evalUnifiedLight(P, N, V, material, ctx, pick, sampling_rand, eval_brdf, enable_shadow, true);
}

LightResult calculateUnifiedLight(
    vec3 P, vec3 N, vec3 V,
    MaterialProperties material,
    SampleContext ctx,
    vec3 sampling_rand,
    bool eval_brdf,
    bool enable_shadow)
{
	uint cluster_index = getLightClusterIndex(P);
    uint total = getLightsCountInCluster(cluster_index);
    
    LightResult r = LightResult(vec3(0.0), vec3(0.0), vec3(0.0), false, uint(-1));

    if(total == 0)
        return r;

    for (uint i = 0; i < total; i++) {
        LightResult l = evalUnifiedLight(P, N, V, material, ctx, i, sampling_rand, eval_brdf, enable_shadow, true);    
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

void updatePickData(vec3 radiance, uint light_id, inout LightRandomPickData data, bool pick_pass) {
    float weight = luminance(radiance);
    data.weights_sum += weight;

    if (pick_pass) {
        if (weight > 0.0 && data.pick_id == -1 && data.pick_random <= data.weights_sum) {
            data.pick_id = light_id;
            data.pdf = weight / data.pdf_sum;
        }
    }
}

void endOfWeightPass(float rnd, inout LightRandomPickData data) {
    data.pick_random = rnd * data.weights_sum;
    data.pdf_sum = data.weights_sum;
    data.weights_sum = 0.0;
}

#ifdef UNIFIED_LIGHTS_IMPORTANCE

#define PASS_WEIGHTS_SUM 0
#define PASS_RUSSIAN_ROULETTE 1
LightResult calculateUnifiedLightImportance(
    vec3 P, vec3 N, vec3 V,
    MaterialProperties material,
    SampleContext ctx,
    vec3 sampling_rand,
    bool eval_brdf,
    bool enable_shadow,
    ivec2 pix)
{
	uint cluster_index = getLightClusterIndex(P);
    uint total = getLightsCountInCluster(cluster_index);
    
    LightResult r = LightResult(vec3(0.0), vec3(0.0), vec3(0.0), false, uint(-1));

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

                    LightResult l = evalUnifiedLight(P, N, V, material, ctx, light_id, sampling_rand, eval_brdf, false, true);

                    bool pick_pass = pass == PASS_RUSSIAN_ROULETTE;
                    updatePickData(l.diffuse, l.light_id, diff_pick, pick_pass);
                    updatePickData(l.specular, l.light_id, spec_pick, pick_pass);
                }

                if (pass == PASS_WEIGHTS_SUM) {
                    const float rnd = rand01();
                    endOfWeightPass(rnd, diff_pick);
                    endOfWeightPass(rnd, spec_pick);
                }
            }
        }

        if (diff_pick.pick_id != -1 && diff_pick.pdf > 0.0) {
            LightResult l = evalUnifiedLight(P, N, V, material, ctx, diff_pick.pick_id, sampling_rand, eval_brdf, true, false);
            r.diffuse += l.diffuse / diff_pick.pdf;
        }

        if (spec_pick.pick_id != -1 && spec_pick.pdf > 0.0) {
            LightResult l = evalUnifiedLight(P, N, V, material, ctx, spec_pick.pick_id, sampling_rand, eval_brdf, true, false);
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
    SampleContext ctx,
    vec3 sampling_rand,
    bool eval_brdf,
    bool enable_shadow)
{
	uint cluster_index = getLightClusterIndex(P);
    uint total = getLightsCountInCluster(cluster_index);
    
    LightResult r = LightResult(vec3(0.0), vec3(0.0), vec3(0.0), false, uint(-1));

    if(total == 0)
        return r;

    float pdf = float(total) / float(RANDOM_LIGHTS_COUNT);

    for (uint i = 0; i < RANDOM_LIGHTS_COUNT; i++) {
        LightResult l = evalRandomUnifiedLight(P, N, V, material, ctx, sampling_rand, rand01(), eval_brdf, enable_shadow);
        r.diffuse += l.diffuse * pdf;
        r.specular += l.specular * pdf;
    }

    return r;
}

#endif // LIGHTS_UNIFIED_GLSL
