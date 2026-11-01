#ifndef LC_INDEPENDENT_GLSL
#define LC_INDEPENDENT_GLSL
#ifndef LC_PATH_FIREFLY_REJECTION
#define LC_PATH_FIREFLY_REJECTION 0
#endif
#ifndef LC_PATH_FIREFLY_RATIO
#define LC_PATH_FIREFLY_RATIO 1.5
#endif
#ifndef LC_PATH_FIREFLY_KILL_PROBABILITY
#define LC_PATH_FIREFLY_KILL_PROBABILITY 0.25
#endif
#ifndef LC_PATH_FIREFLY_MIN_SAMPLES
#define LC_PATH_FIREFLY_MIN_SAMPLES 8
#endif
#ifndef LC_PATH_RELIGHT_REJECTION
#define LC_PATH_RELIGHT_REJECTION 1
#endif
#ifndef LC_PATH_RELIGHT_MAX_RATIO
#define LC_PATH_RELIGHT_MAX_RATIO 1.25
#endif
#ifndef LC_PATH_RELIGHT_LUMINANCE_FLOOR
#define LC_PATH_RELIGHT_LUMINANCE_FLOOR 1e-6
#endif
// Compare the same selected path before RIS normalization, never color * W.
bool lcPathRelightValid(float previous, float current) {
    if (isnan(previous) || isinf(previous) || isnan(current) || isinf(current) ||
        previous<0.0 || current<0.0) return false;
#if LC_PATH_RELIGHT_REJECTION
    float lo=max(min(previous,current),LC_PATH_RELIGHT_LUMINANCE_FLOOR);
    float hi=max(max(previous,current),LC_PATH_RELIGHT_LUMINANCE_FLOOR);
    return hi<=lo*LC_PATH_RELIGHT_MAX_RATIO;
#else
    return true;
#endif
}
// Match brdfComputeGltfModel: alpha = roughness^2; ggxD clamps alpha^2.
float lcReflectionProposalAlpha2(float roughness) {
    float alpha=roughness*roughness;
    return max(alpha*alpha,1e-5);
}
float lcCameraConfidence(float translation, float distance, float relative_motion,
    float maximum, float minimum) {
    float motion=translation/max(distance,1.0)/relative_motion;
    return max(minimum,maximum/(1.0+motion*motion));
}
// Deliberately image-space only: median of four taps, no surface validation.
bool lcRejectPathFirefly(float value, vec4 taps, float random, float sample_count) {
    float lo=max(min(taps.x,taps.y),min(taps.z,taps.w));
    float hi=min(max(taps.x,taps.y),max(taps.z,taps.w));
    float median=0.5*(lo+hi);
    return sample_count>LC_PATH_FIREFLY_MIN_SAMPLES && value>LC_PATH_FIREFLY_RATIO*median &&
        random<LC_PATH_FIREFLY_KILL_PROBABILITY;
}
// Candidate payload stays in the caller. Counts include zero-weight proposals.
struct LCReservoir { float sum; float count; float target; };
bool lcOffer(inout LCReservoir r, float target, float inverse_pdf, float random) {
    float mass = max(target, 0.0) * inverse_pdf;
    r.count += 1.0;
    r.sum += mass;
    bool accept = mass > 0.0 && random * r.sum < mass;
    if (accept) r.target = target;
    return accept;
}
float lcNormalization(LCReservoir r) {
    return r.target > 0.0 ? r.sum / (r.count * r.target) : 0.0;
}
bool lcPathHistoryValid(vec4 h) {
    return !any(isnan(h)) && !any(isinf(h)) && h.x>0.0 && h.y>0.0 && h.z>=1.0;
}
bool lcMirrorPath(float roughness, float normal_dot) {
    return roughness<0.004 && normal_dot>=0.98;
}
float lcTransportConfidence(float relative_shift, float maximum) {
    return max(1.0,maximum/(1.0+relative_shift*relative_shift));
}
// Re-evaluate the selected path in its uniform random domain. Cap mass and M
// together so limiting confidence never changes the source estimator's scale.
bool lcMergePath(inout LCReservoir r, vec4 history, float target, float cap, float random) {
    float count=min(history.z,cap);
    float mass=history.y*(count/history.z)*(target/history.x);
    float fresh=r.sum;
    r.sum+=mass; r.count+=count;
    float small=min(fresh,mass)/r.sum;
    bool accept=mass<=fresh ? random<small : random>=small;
    if (accept) r.target=target;
    return accept;
}
vec4 lcEncodePath(LCReservoir r, float cap) {
    float count=min(r.count,cap);
    return vec4(r.target,r.sum*(count/r.count),count,lcNormalization(r));
}
// Lossless 32-bit path identity in two numeric float components (not NaN bits).
vec2 lcPackPathSeed(uint seed) { return vec2(seed & 65535u,seed >> 16u); }
uint lcUnpackPathSeed(vec2 seed) { return uint(seed.x) | (uint(seed.y)<<16u); }
float lcPathTarget(vec3 color) {
    return max(dot(color,vec3(0.2126,0.7152,0.0722)),1e-6);
}
float lcWeight(vec3 c) { return max(dot(c, vec3(0.2126, 0.7152, 0.0722)), 0.0); }
// Unit-albedo outgoing diffuse radiance; geometry normal only, no view/material.
vec3 lcDiffuse(vec3 radiance, vec3 geometry_normal, vec3 direction) {
    return radiance * (max(dot(geometry_normal, direction), 0.0) / 3.14159265);
}
float lcPointWeight(PointLight l, vec3 P, vec3 N) {
    if (l.environment != 0u) return max(1e-8, lcWeight(l.color_stopdot.rgb));
    vec3 d = l.origin_r2.xyz - P;
    float d2 = max(dot(d, d), 1e-8);
    return max(1e-8, lcWeight(l.color_stopdot.rgb) * l.origin_r2.w / d2 *
        max(dot(N, d * inversesqrt(d2)), 0.0));
}
float lcPolygonWeight(PolygonLight l, vec3 P, vec3 N) {
    vec3 d = l.center - P;
    float d2 = max(dot(d, d), 1e-8);
    vec3 L = d * inversesqrt(d2);
    return max(1e-8, lcWeight(l.emissive) * l.area / d2 *
        max(dot(N, L), 0.0) * max(-dot(l.plane.xyz, L), 0.0));
}
#endif
