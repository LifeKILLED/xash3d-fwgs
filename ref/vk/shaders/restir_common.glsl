#ifndef RESTIR_COMMON_GLSL
#define RESTIR_COMMON_GLSL 1

#include "lights_unified.glsl"

#define AGE_MULTIPLIER 256.0
#define MAX_AGE 255u
#define MAX_RESTIR_NORM 8.0
#define MAX_CONSTANT_DEATH_FRAMES 120.0
#define MAX_RESERVOIR_HISTORY_FRAMES 64

struct Reservoir {
    uint  lightIndex; // выбранный свет
    float death;      // единица - смэрть в мучениях
    float w_sum;      // Σ w_i
    float w_y;        // вес выбранного
    float M;          // число кандидатов
};

Reservoir reservoirInit()
{
    Reservoir r;
    r.lightIndex = 0u;
    r.death = 0.0;
    r.w_sum = 0.0;
    r.w_y = 0.0;
    r.M = 0.0;
    return r;
}

void reservoirUpdate(
    inout Reservoir r,
    uint lightIndex,
    float w,
    float xi
){
    if (w <= 0.0)// || (lightIndex == r.lightIndex && w != 0.0))
        return;

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
       return reservoirInit();
    }

    out_of_bound = false;

    Reservoir r;
    r.lightIndex = light_id;
    r.death = fract(d.x);
    r.w_sum = d.y;
    r.w_y = d.z;
    r.M = d.w;

    return r;
}

vec4 saveReservoir(Reservoir r)
{
    float encoded_light_id = encodeHistoryLightId(r.lightIndex);
    return vec4(
        encoded_light_id + min(0.99, r.death),
        r.w_sum,
        r.w_y,
        r.M
    );
}

float restirConfidence(
    inout Reservoir r,
    float currLo
){
    if (currLo == 0.0) {
        r = reservoirInit();
        return 0.0;
    }

    float prevLo = r.w_y;

    float diff = abs(currLo - prevLo);
    float scale = max(min(currLo, prevLo), 1e-3);
    float confidence = min(1.0, 1.0 - (diff / scale) / 0.2);

    confidence = 1.0 - (diff / scale);

    //confidence = smoothstep(0.5, 1.0, confidence);

    // r.death += max(0.0, 1.0 - confidence); // FIXME: stabilize confidence and use it for kill bad reservoirs
    // r.death += 1.0 / mix(1.0, MAX_CONSTANT_DEATH_FRAMES, rand01()); // constant life for reducion fireflyes
    // if (r.death >= 0.99) {
    //     r = reservoirInit();
    // } //else
    if (r.M > MAX_RESERVOIR_HISTORY_FRAMES) {
        r.w_sum = currLo;//r.w_sum - prevLo + currLo;
        r.w_y = currLo;
        r.M = 1;
    }

    return confidence;
}

#endif // RESTIR_COMMON_GLSL
