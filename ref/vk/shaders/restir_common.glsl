#ifndef RESTIR_COMMON_GLSL
#define RESTIR_COMMON_GLSL 1

#ifndef RESTIR_COMMON_NO_LIGHTING
#include "lights_unified.glsl"
#endif

#define MIN_RESTIR_WEIGHT 1e-4
#define MAX_RESTIR_WEIGHT 0.02

#define CONF_STORE_MULT 0.98

struct Reservoir {
    uint  light_index;
    float w_sum;
    float w_clamped;
    float w_full;
    float checked_count;
    float conf;
};

void restirRefreshReservoirWeightsNoConfidence(
    inout Reservoir r,
    float curr_w
);

Reservoir reservoirInit(float conf)
{
    Reservoir r;
    r.light_index = 0u;
    r.w_sum = 0.0;
    r.w_clamped = 0.0;
    r.w_full = 0.0;
    r.checked_count = 0.0;
    r.conf = conf;
    return r;
}

float clampRestirWeight(float w_full)
{
    return clamp(w_full, MIN_RESTIR_WEIGHT, min(1.0, MAX_RESTIR_WEIGHT));
}

void reservoirUpdate(
    inout Reservoir r,
    uint light_index,
    float curr_w_full,
    float xi
){
    float curr_w_clamped = clampRestirWeight(curr_w_full);

    r.checked_count += 1.0;
    r.w_sum += curr_w_clamped;

    float p = curr_w_clamped / r.w_sum;
    if (xi < p) {
        r.light_index = light_index;
        r.w_clamped = curr_w_clamped;
        r.w_full = curr_w_full;
    }
}

#ifndef RESTIR_COMMON_NO_LIGHTING
Reservoir loadReservoir(vec4 d, out bool out_of_bound)
{
    uint light_id = decodeHistoryLightId(floor(d.x), out_of_bound);
    if (out_of_bound) {
       return reservoirInit(0.0);
    }

    out_of_bound = false;

    Reservoir r;
    r.light_index = light_id;
    r.w_sum = d.y;
    r.w_full = d.z;
    r.w_clamped = fract(d.w);
    r.checked_count = floor(d.w);
    r.conf = fract(d.x) / CONF_STORE_MULT;

    return r;
}

vec4 saveReservoir(Reservoir r)
{
    return vec4(
        encodeHistoryLightId(r.light_index) + clamp(r.conf, 0.0, 1.0) * CONF_STORE_MULT,
        r.w_sum,
        r.w_full,
        floor(r.checked_count) + clamp(r.w_clamped, 0.0, 1.0)
    );
}
#else
Reservoir loadReservoir(vec4 d, out bool out_of_bound)
{
    out_of_bound = false;

    Reservoir r;
    r.light_index = 0u;
    r.w_sum = d.y;
    r.w_full = d.z;
    r.w_clamped = fract(d.w);
    r.checked_count = floor(d.w);
    r.conf = fract(d.x) / CONF_STORE_MULT;

    return r;
}

vec4 saveReservoir(Reservoir r)
{
    return vec4(
        clamp(r.conf, 0.0, 1.0) * CONF_STORE_MULT,
        r.w_sum,
        r.w_full,
        floor(r.checked_count) + clamp(r.w_clamped, 0.0, 1.0)
    );
}
#endif

void updateRestirConfidence(
    inout Reservoir r,
    float curr_w
){
    float diff = abs(curr_w - r.w_full);
    float scale = max(curr_w, r.w_full);

    // If both previous and current weights are zero, treat as stable empty lighting.
    r.conf = scale > 0.0 ? clamp(1.0 - (diff / scale), 0.0, 1.0) : 1.0;

    restirRefreshReservoirWeightsNoConfidence(r, curr_w);
}

void restirRefreshReservoirWeightsNoConfidence(
    inout Reservoir r,
    float curr_w
){
    float curr_w_clamped = clampRestirWeight(curr_w);
    r.w_sum += curr_w_clamped - r.w_clamped;
    r.w_clamped = curr_w_clamped;
    r.w_full = curr_w;
}

float restirLightingWeight(in Reservoir r)
{
    return r.w_sum / (r.checked_count * r.w_clamped);
}

#endif // RESTIR_COMMON_GLSL
