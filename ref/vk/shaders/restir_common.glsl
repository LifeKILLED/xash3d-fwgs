#ifndef RESTIR_COMMON_GLSL
#define RESTIR_COMMON_GLSL 1

// float lightWeightPoly(const PolygonLight poly, const vec3 P, const vec3 N) {
// 	const vec3 dir = poly.center - P;
//     const vec3 dirNorm = normalize(dir);
// 	const float coplanar = 1. - clamp(dot(normalize(poly.plane.xyz), -dirNorm), 0., 1.);
// 	const float coplanar_pow = 1. - coplanar * coplanar;
// 	const float dist = 1. / dot(dir, dir);
// 	const float shading = dot(N, dirNorm);
// 	return dist * shading * coplanar_pow * luminanceM(poly.emissive) * poly.area;
// }

// float lightWeightPoint(const PointLight point, const vec3 P, const vec3 N) {
//     const float intensity = luminance(point.color_stopdot.rgb);
//     const bool is_environment = point.environment != 0);
//     if (is_environment) {
//         return intensity * dot(normalize(point.dir_stopdot2.xyz), N);
//     } else {
//         const vec3 dir = point.origin_r2.xyz - P;
//         const float light_dist2 = dot(dir, dir);

//         // TODO: need to remove for realistic lighting
//         const float d2_minus_r2 = max(0.0, light_dist2 - point.origin_r2.w);

//         const float light_dot = dot(dir, N);

//         float spot_attenuation = 1.;
//         // Spotlights
//         // Check for angles early
//         // TODO split into separate spotlights and point lights arrays
//         const float spot_dot = dot(light_dir, spotlight_dir);
//         const float stopdot2 = point.dir_stopdot2.a;
//         if (spot_dot < stopdot2)
//             continue;

//         const float stopdot = point.color_stopdot.a;

//         // For non-spotlighths stopdot will be -1.. spot_dot can never be less than that
//         spot_attenuation = (spot_dot < stopdot) ? max(0.0, (spot_dot - stopdot2) / (stopdot - stopdot2)) : 1.0;

//         one_over_pdf = 2. * kPi * max(0., 1. - cos_theta_max) * spot_attenuation;
// }

struct Reservoir {
    uint lightIndex;
    float weightSum;
    float W; // accumulated probability
    float M; // number of samples
};

// --- Reservoir helper functions ---
Reservoir reservoirInit(uint li, float w)
{
    Reservoir r;
    r.lightIndex = li;
    r.weightSum = w;
    r.W = w;
    r.M = 1.0;
    return r;
}

void reservoirUpdate(inout Reservoir r, uint li, float w, float randVal)
{
    if (r.W == 0.0) {
        r = reservoirInit(li, w);
        return;
    }

#ifdef RESTIR_CLAMP
    w = min(w, 100.0);
#endif
    r.M += 1.0;
    float p = w / r.W;
    if(randVal < p) {
        r.lightIndex = li;
        r.W = w;
    }
    r.weightSum += w;
}

Reservoir loadReservoir(vec4 d)
{
    Reservoir r;
    r.lightIndex = uint(d.x);
    r.weightSum = d.y;
    r.W = d.z;
    r.M = d.w;
    return r;
}

// --- Random generator ---
// uint seedFromPixel(ivec2 px) { return uint(px.x*1973 + px.y*9277); }
// float rand(inout uint seed)
// {
//     seed ^= seed << 13;
//     seed ^= seed >> 17;
//     seed ^= seed << 5;
//     return float(seed) / 4294967296.0;
// }

// // --- Visibility function (user-provided) ---
// bool visibilityRay(vec3 P, vec3 lightPos)
// {
//     // abstract placeholder
//     return true;
// }

#endif // RESTIR_COMMON_GLSL