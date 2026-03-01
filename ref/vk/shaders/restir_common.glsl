#ifndef RESTIR_COMMON_GLSL
#define RESTIR_COMMON_GLSL 1

#include "lights_unified.glsl"

#define MIN_RESTIR_WEIGHT 1e-4

#define CONF_STORE_MULT 0.98

struct Reservoir {
    uint  lightIndex; // выбранный свет
    float w_sum;      // Σ w_i
    float w_y;        // вес выбранного
    float M;          // число кандидатов
    float conf;       // одинаковость освещения в разных кадрах
};

Reservoir reservoirInit(float conf)
{
    Reservoir r;
    r.lightIndex = 0u;
    r.w_sum = 0.0;
    r.w_y = 0.0;
    r.M = 0.0;
    r.conf = conf;
    return r;
}

void reservoirUpdate(
    inout Reservoir r,
    uint lightIndex,
    float w_src,
    float xi
){
    float w = max(w_src, MIN_RESTIR_WEIGHT);

    r.M += 1.0;
    r.w_sum += w;

    float p = w / r.w_sum;
    if (xi < p) {
        r.lightIndex = lightIndex;
        r.w_y = w;
    }
}

Reservoir loadReservoir(vec4 d, out bool out_of_bound)
{
    uint light_id = decodeHistoryLightId(floor(d.x), out_of_bound);
    if (out_of_bound) {
       return reservoirInit(0.0);
    }

    out_of_bound = false;

    Reservoir r;
    r.lightIndex = light_id;
    r.w_sum = d.y;
    r.w_y = d.z;
    r.M = d.w;
    r.conf = fract(d.x) / CONF_STORE_MULT;

    return r;
}

vec4 saveReservoir(Reservoir r)
{
    return vec4(
        encodeHistoryLightId(r.lightIndex) + clamp(r.conf, 0.0, 1.0) * CONF_STORE_MULT,
        r.w_sum,
        r.w_y,
        r.M
    );
}

void updateRestirConfidence(
    inout Reservoir r,
    float currLoSrc
){
    float prevLo = r.w_y;

    float currLo = max(currLoSrc, MIN_RESTIR_WEIGHT);

    float diff = abs(currLo - prevLo);
    float scale = max(currLo, prevLo);

    r.conf = scale > 0.0 ? clamp(1.0 - (diff / scale), 0.0, 1.0) : 0.0;
}

#endif // RESTIR_COMMON_GLSL
