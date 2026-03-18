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
#include "light_weight.glsl"
#include "poisson-disk-8x8.glsl"


#ifndef SHADOW_RAY_ORIGIN_BIAS
#define SHADOW_RAY_ORIGIN_BIAS 0.1
#endif

#ifndef SHADOW_RAY_DISTANCE_EPSILON
#define SHADOW_RAY_DISTANCE_EPSILON 0.1
#endif

#ifndef SHADOW_RAY_TARGET_BIAS
#define SHADOW_RAY_TARGET_BIAS SHADOW_RAY_ORIGIN_BIAS
#endif

#ifndef SHADOW_RAY_EXTRA_BIAS
#define SHADOW_RAY_EXTRA_BIAS SHADOW_RAY_DISTANCE_EPSILON
#endif

#ifndef SHADOW_RAY_DOT_EPSILON
#define SHADOW_RAY_DOT_EPSILON 1e-4
#endif

#ifndef SPECULAR_COSINE_WEIGHT
#define SPECULAR_COSINE_WEIGHT 0.2
#endif

#ifndef POLYGON_LIGHT_MIS_BRDF_MAX_ROUGHNESS
#define POLYGON_LIGHT_MIS_BRDF_MAX_ROUGHNESS 0.35
#endif

#ifndef POLYGON_LIGHT_MIS_MIN_LIGHT_PROB
#define POLYGON_LIGHT_MIS_MIN_LIGHT_PROB 0.02
#endif

#ifndef POLYGON_LIGHT_MIS_MAX_LIGHT_PROB
#define POLYGON_LIGHT_MIS_MAX_LIGHT_PROB 0.95
#endif

#ifndef POLYGON_LIGHT_MIS_MIRROR_ROUGHNESS
#define POLYGON_LIGHT_MIS_MIRROR_ROUGHNESS 0.04
#endif

#ifndef UNIFIED_CUSTOM_BRDF_MIN_ALPHA
#define UNIFIED_CUSTOM_BRDF_MIN_ALPHA 0.001
#endif

#ifndef UNIFIED_CUSTOM_BRDF_SPECULAR_CLAMP
#define UNIFIED_CUSTOM_BRDF_SPECULAR_CLAMP 64.0
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

float shadowRayTMax(float light_dist)
{
    float trim = SHADOW_RAY_ORIGIN_BIAS + SHADOW_RAY_TARGET_BIAS + SHADOW_RAY_EXTRA_BIAS;
    return max(0.0, light_dist - trim);
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
    float spec_angular_radius;
    float spec_compensation;
};


LightSamplingData calculatePointLightSamplingData(
    PointLight pl,
    vec3 P,
    vec3 N,
    vec3 V,
    MaterialProperties material,
    vec3 rnd)
{
    LightSamplingData l = LightSamplingData(vec3(0.), 0., vec3(0.), 0., LIGHT_SPECULAR_MIN_ANGULAR, 1.0);

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
        float cone_spread = sqrt(max(1.0 - pl.dir_stopdot2.a * pl.dir_stopdot2.a, 0.0));
        l.spec_angular_radius = max(LIGHT_SPECULAR_MIN_ANGULAR, cone_spread * LIGHT_SPECULAR_ANGULAR_SCALE);
        l.spec_compensation = computeSpecularCompensation(l.spec_angular_radius);
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

        float source_radius = sqrt(max(pl.origin_r2.w, 0.0));
        l.spec_angular_radius = computeSpecularAngularRadius(source_radius, l.dist);
        l.spec_compensation = computeSpecularCompensation(l.spec_angular_radius);
    }

    return l;
}

LightSamplingData calculatePolygonLightSamplingData(PolygonLight poly, vec3 P, vec3 N, vec3 V, MaterialProperties material, SampleContext ctx, vec3 rnd)
{
    LightSamplingData l = LightSamplingData(vec3(0.), 0., vec3(0.), 0., LIGHT_SPECULAR_MIN_ANGULAR, 1.0);

    const vec4 plane = normalizedPolygonPlane(poly);
    const float plane_dist = dot(plane, vec4(P, 1.f));

    if (plane_dist <= POLYGON_SELF_LIGHT_PLANE_BIAS) {
        return l;
    }

    // Technique A: existing polygon solid-angle sampler.
    const vec4 s_light = getPolygonLightSampleSimpleSolid(P, V, poly, rnd);
    if (s_light.w <= 0.0) {
        return l;
    }

    const float self_fade = smoothstep(
        POLYGON_SELF_LIGHT_PLANE_BIAS,
        POLYGON_SELF_LIGHT_PLANE_BIAS + POLYGON_SELF_LIGHT_FADE_RANGE,
        plane_dist);
    if (self_fade <= 0.0) {
        return l;
    }

    const float p_light = 1.0 / max(s_light.w, 1e-8);

    float c_light = 1.0;
    float c_brdf = 0.0;
    vec3 L = s_light.xyz;
    vec3 R = vec3(0.0);
    float cone_cos_max = 1.0;
    float cone_pdf = 0.0;
    float p_brdf = 0.0;
    bool sampled_brdf = false;

    bool allow_brdf_proposal = material.roughness <= POLYGON_LIGHT_MIS_BRDF_MAX_ROUGHNESS;
    if (allow_brdf_proposal) {
        float rough2 = material.roughness * material.roughness;
        cone_cos_max = clamp(1.0 - rough2 * 0.75, 0.2, 0.9999);
        cone_pdf = 1.0 / max(2.0 * kPi * (1.0 - cone_cos_max), 1e-8);
        R = normalize(reflect(-V, N));

        // Technique B: specular-oriented BRDF proposal (cone around reflection).
        vec3 L_brdf = normalize(orthonormalBasisZ(R) * sampleConeZ(rnd.xy, cone_cos_max));

        // Keep light sampling dominant to avoid energy loss and excess variance.
        float rough = clamp(material.roughness, 0.0, 1.0);
        c_light = clamp(rough * rough * 0.85 + 0.02, POLYGON_LIGHT_MIS_MIN_LIGHT_PROB, POLYGON_LIGHT_MIS_MAX_LIGHT_PROB);
        if (rough <= POLYGON_LIGHT_MIS_MIRROR_ROUGHNESS) {
            c_light = 0.0;
        }
        c_brdf = 1.0 - c_light;

        bool choose_light = rnd.z < c_light;
        sampled_brdf = !choose_light;
        L = choose_light ? s_light.xyz : L_brdf;

        float dot_lr = dot(L, R);
        p_brdf = (dot_lr >= cone_cos_max) ? cone_pdf : 0.0;
    }

    const float denom = dot(L, plane.xyz);
    if (denom >= -POLYGON_LIGHT_MIN_DENOM) {
        return l;
    }

    float dist = max(0.0, -plane_dist / denom);
    if (dist <= 0.0) {
        return l;
    }

    // For BRDF proposal we must reject rays that do not hit the polygon interior.
    if (sampled_brdf) {
        const vec3 hit = P + L * dist;
        const uint vertices_offset = poly.vertices_count_offset & 0xffffu;
        const uint vertices_count = poly.vertices_count_offset >> 16;
        bool inside = true;
        float ref_sign = 0.0;
        bool have_ref = false;
        for (uint i = 0u; i < vertices_count; ++i) {
            vec3 a = lights.m.polygon_vertices[vertices_offset + i].xyz;
            vec3 b = lights.m.polygon_vertices[vertices_offset + ((i + 1u) % vertices_count)].xyz;
            float s = dot(cross(b - a, hit - a), plane.xyz);
            if (abs(s) <= 1e-6) {
                continue;
            }
            if (!have_ref) {
                ref_sign = sign(s);
                have_ref = true;
            } else if (s * ref_sign < -1e-5) {
                inside = false;
                break;
            }
        }
        if (!inside) {
            return l;
        }
    }

    float p_mix = c_light * p_light + c_brdf * p_brdf;
    if (p_mix <= 1e-8) {
        return l;
    }
    l.geom_weight = self_fade / p_mix;

    l.dist = dist;
    l.L = L;
    l.emissive_color = poly.emissive;
    float source_radius = sqrt(max(poly.area, 0.0) * (1.0 / kPi));
    l.spec_angular_radius = computeSpecularAngularRadius(source_radius, l.dist);
    l.spec_compensation = computeSpecularCompensation(l.spec_angular_radius);

#ifdef LIMIT_LIGHT_LUMINANCE
    float lum = luminance(l.emissive_color);
    if (lum > 1.0) {
        l.emissive_color /= lum;
    }
#endif

    return l;
}

void evalUnifiedDecolorizedBRDF(
    vec3 N,
    vec3 L,
    vec3 V,
    vec3 radiance,
    MaterialProperties material,
    out vec3 out_diffuse,
    out vec3 out_specular)
{
    out_diffuse = vec3(0.0);
    out_specular = vec3(0.0);

    float NoL = max(dot(N, L), 0.0);
    float NoV = max(dot(N, V), 0.0);
    if (NoL <= 1e-6 || NoV <= 1e-6) {
        return;
    }

    vec3 H = L + V;
    float h_len2 = dot(H, H);
    if (h_len2 <= 1e-8) {
        return;
    }
    H *= inversesqrt(h_len2);

    float NoH = max(dot(N, H), 0.0);
    float VoH = max(dot(V, H), 0.0);

    float alpha = max(UNIFIED_CUSTOM_BRDF_MIN_ALPHA, material.roughness * material.roughness);
    float D = D_GGX_BRDF(NoH, alpha);
    float G = G_Smith_BRDF(NoV, NoL, alpha);

    vec3 f0_rgb = calculateSpecularColor(material.base_color, material.metalness);
    float f0 = clamp(luminance(f0_rgb), 0.0, 1.0);
    float F = f0 + (1.0 - f0) * pow(1.0 - VoH, 5.0);

    float kd = max(1.0 - material.metalness, 0.0);
    float diffuse_brdf = kd * kOneOverPi;
    float spec_brdf = (D * G * F) / max(4.0 * NoV * NoL, 1e-5);
    if (UNIFIED_CUSTOM_BRDF_SPECULAR_CLAMP > 0.0) {
        spec_brdf = min(spec_brdf, UNIFIED_CUSTOM_BRDF_SPECULAR_CLAMP);
    }

    out_diffuse = radiance * (NoL * diffuse_brdf);
    out_specular = radiance * (NoL * spec_brdf);
}

void unifiedLightFinalShading(
    inout LightResult r,
    LightSamplingData l,
    vec3 P, vec3 N, vec3 V,
    MaterialProperties material,
    bool enable_shadow)
{
    if (l.geom_weight > 0.0) {
        float specular_compensation = l.spec_compensation;

        bool shadow_vis = false;

#ifndef DISABLE_RAYS
        if (enable_shadow && l.dist > 0.0) {
            const vec3 shadow_origin = offsetShadowOrigin(P, N, l.L);
            shadow_vis = shadowed(shadow_origin, l.L, shadowRayTMax(l.dist));
        }
#endif
        r.shadowed = shadow_vis;
        vec3 d, s;
        evalUnifiedDecolorizedBRDF(N, l.L, V, l.emissive_color * l.geom_weight, material, d, s);
        r.diffuse  = d;
        r.specular = s * specular_compensation;
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
    bool enable_shadow,
    bool use_clusters)
{
	uint cluster_index = getLightClusterIndex(P);

    LightResult result = LightResult(vec3(0.0), vec3(0.0), vec3(0.0), false, 0);
    LightSamplingData sky = LightSamplingData(vec3(0.), 0., vec3(0.), 0., LIGHT_SPECULAR_MIN_ANGULAR, 1.0);

    uint num_point = use_clusters ?
                        uint(light_grid.clusters_[cluster_index].num_point_lights) :
                        lights.m.num_point_lights;

    for (uint i = 0; i < num_point; i++) {
        if (isFlashlightOrSky(i, origin, P, use_clusters)) { // all checks is in this function
            
            uint idx_point = use_clusters ?
                                uint(light_grid.clusters_[cluster_index].point_lights[i]) :
                                i;

            LightSamplingData l = calculatePointLightSamplingData(lights.m.point_lights[idx_point], P, N, V, material, rnd);

            bool need_to_separate_sky = enable_shadow && l.dist < 0.0;
            if (need_to_separate_sky) { // calculate sky shadow outside of loop for better perfomance
                sky = l;
            } else {                
                LightResult r = LightResult(vec3(0.0), vec3(0.0), vec3(0.0), false, 0);
                unifiedLightFinalShading(r, l, P, N, V, material, enable_shadow);
                r.sampled_L = l.L;
                
                result.diffuse += r.diffuse;
                result.specular += r.specular;
            }
        }
    }

    if (enable_shadow && sky.dist < 0.0) {
        if (!shadowedSky(P, sky.L)) {

            LightResult r = LightResult(vec3(0.0), vec3(0.0), vec3(0.0), false, 0);
            unifiedLightFinalShading(r, sky, P, N, V, material, false);
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

        l = calculatePointLightSamplingData(lights.m.point_lights[idx_point], P, N, V, material, rnd);
    }
    else
    {
        uint idx_poly  = use_clusters ? 
                            uint(light_grid.clusters_[cluster_index].polygons[pick - num_point]) :
                            pick - num_point;

        r.light_id = idx_poly + lights.m.num_point_lights;

        l = calculatePolygonLightSamplingData(lights.m.polygons[idx_poly], P, N, V, material, ctx, rnd);		
    }

    unifiedLightFinalShading(r, l, P, N, V, material, enable_shadow);
    r.sampled_L = l.L;

    return r;
}



LightResult evalUnifiedLightWeight(
    vec3 P, vec3 N, vec3 V,
    MaterialProperties material,
    SampleContext ctx,
    uint pick,
    bool use_clusters)
{
    LightResult r = LightResult(vec3(0.0), vec3(0.0), vec3(0.0), false, uint(-1));

    uint cluster_index = getLightClusterIndex(P);
    uint num_point = use_clusters ?
                        uint(light_grid.clusters_[cluster_index].num_point_lights) :
                        lights.m.num_point_lights;

    bool is_point = pick < num_point;

    if (is_point)
    {
        uint idx_point = use_clusters ?
                            uint(light_grid.clusters_[cluster_index].point_lights[pick]) :
                            pick;

        PointLight pl = lights.m.point_lights[idx_point];
        vec2 w = lightPointWeightCalculation(pl, P, N, V, material.roughness);
        r.diffuse = vec3(max(w.x, 0.0));
        r.specular = vec3(max(w.y, 0.0));
        r.light_id = idx_point;

        if (pl.environment != 0) {
            r.sampled_L = pl.dir_stopdot2.xyz;
        } else {
            vec3 toL = pl.origin_r2.xyz - P;
            float d2 = dot(toL, toL);
            r.sampled_L = d2 > 1e-8 ? normalize(toL) : N;
        }
    }
    else
    {
        uint idx_poly = use_clusters ?
                            uint(light_grid.clusters_[cluster_index].polygons[pick - num_point]) :
                            pick - num_point;

        PolygonLight poly = lights.m.polygons[idx_poly];
        vec2 w = lightPolygonWeightCalculation(poly, P, N, V, material.roughness);
        r.diffuse = vec3(max(w.x, 0.0));
        r.specular = vec3(max(w.y, 0.0));
        r.light_id = idx_poly + lights.m.num_point_lights;

        vec3 toC = poly.center - P;
        float d2 = dot(toC, toC);
        r.sampled_L = d2 > 1e-8 ? normalize(toC) : N;
    }

    return r;
}
LightResult evalRandomUnifiedLight(
    vec3 P, vec3 N, vec3 V,
    MaterialProperties material,
    SampleContext ctx,
    vec3 sampling_rand,
    float pick_random,
    bool enable_shadow)
{
    uint cluster_index = getLightClusterIndex(P);
    uint total = getLightsCountInCluster(cluster_index);

    if(total == 0) {
        return LightResult(vec3(0.0), vec3(0.0), vec3(0.0), false, uint(-1));
    }

    uint pick = min(uint(pick_random * float(total)), total - 1u);

    return evalUnifiedLight(P, N, V, material, ctx, pick, sampling_rand, enable_shadow, true);
}

LightResult calculateUnifiedLight(
    vec3 P, vec3 N, vec3 V,
    MaterialProperties material,
    SampleContext ctx,
    vec3 sampling_rand,
    bool enable_shadow)
{
	uint cluster_index = getLightClusterIndex(P);
    uint total = getLightsCountInCluster(cluster_index);
    
    LightResult r = LightResult(vec3(0.0), vec3(0.0), vec3(0.0), false, uint(-1));

    if(total == 0)
        return r;

    for (uint i = 0; i < total; i++) {
        LightResult l = evalUnifiedLight(P, N, V, material, ctx, i, sampling_rand, enable_shadow, true);    
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

                    LightResult l = evalUnifiedLight(P, N, V, material, ctx, light_id, sampling_rand, false, true);

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
            LightResult l = evalUnifiedLight(P, N, V, material, ctx, diff_pick.pick_id, sampling_rand, true, false);
            r.diffuse += l.diffuse / diff_pick.pdf;
        }

        if (spec_pick.pick_id != -1 && spec_pick.pdf > 0.0) {
            LightResult l = evalUnifiedLight(P, N, V, material, ctx, spec_pick.pick_id, sampling_rand, true, false);
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
    bool enable_shadow)
{
	uint cluster_index = getLightClusterIndex(P);
    uint total = getLightsCountInCluster(cluster_index);
    
    LightResult r = LightResult(vec3(0.0), vec3(0.0), vec3(0.0), false, uint(-1));

    if(total == 0)
        return r;

    float pdf = float(total) / float(RANDOM_LIGHTS_COUNT);

    for (uint i = 0; i < RANDOM_LIGHTS_COUNT; i++) {
        LightResult l = evalRandomUnifiedLight(P, N, V, material, ctx, sampling_rand, rand01(), enable_shadow);
        r.diffuse += l.diffuse * pdf;
        r.specular += l.specular * pdf;
    }

    return r;
}

#endif // LIGHTS_UNIFIED_GLSL
