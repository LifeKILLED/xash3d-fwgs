#ifndef RESTIR_COMMON_GLSL
#define RESTIR_COMMON_GLSL 1

#define AGE_MULTIPLIER 256.0
#define MAX_AGE 255u
#define MAX_RESTIR_NORM 8.0
#define DEATH_PER_FRAME 0.2

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
    if (w <= 0.0 || (lightIndex == r.lightIndex && w != 0.0))
        return;

    r.M += 1.0;
    r.w_sum += w;

    float p = w / r.w_sum;
    if (xi < p) {
        r.lightIndex = lightIndex;
        r.w_y = w;
    }
}

Reservoir loadReservoir(vec4 d)
{
    Reservoir r;
    r.lightIndex = uint(d.x);
    r.death = fract(d.x);
    r.w_sum = d.y;
    r.w_y = d.z;
    r.M = d.w;
    return r;
}

vec4 saveReservoir(Reservoir r)
{
    return vec4(
        float(r.lightIndex) + min(0.99, r.death),
        r.w_sum,
        r.w_y,
        r.M
    );
}

float restirConfidence(
    inout Reservoir r,
    float currLo
){
    float prevLo = r.w_y;
    float diff = abs(currLo - prevLo);
    float scale = max(prevLo, 1e-3);

    float radianceConf = exp(-diff / scale);

    float confidence = clamp(radianceConf, 0.0, 1.0);

    float damage = (1.0 - confidence);
    r.death += damage * damage;

    if (r.death > 1.0) {
        r = reservoirInit();
    }

    return confidence;
}

void restirUpdateDeath(inout Reservoir r) {
    r.death += DEATH_PER_FRAME;

    if (r.death >= 1.0)
        r = reservoirInit();
}

#endif // RESTIR_COMMON_GLSL
