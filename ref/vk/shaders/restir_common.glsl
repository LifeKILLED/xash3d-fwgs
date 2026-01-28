#ifndef RESTIR_COMMON_GLSL
#define RESTIR_COMMON_GLSL 1

struct Reservoir {
    uint  lightIndex; // выбранный свет
    float w_sum;      // Σ w_i
    float w_y;        // вес выбранного
    float M;          // число кандидатов
};

Reservoir reservoirInit()
{
    Reservoir r;
    r.lightIndex = 0u;
    r.w_sum = 0.0;
    r.w_y = 0.0;
    r.M = 0.0;
    return r;
}

void reservoirUpdate(
    inout Reservoir r,
    uint lightIndex,
    float w,
    float xi // rand in [0,1)
){
    if (w <= 0.0)
        return;

    r.M += 1.0;
    r.w_sum += w;

    // Probability of replacement
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
    r.w_sum = d.y;
    r.w_y = d.z;
    r.M = d.w;
    return r;
}

vec4 saveReservoir(Reservoir r)
{
    return vec4(
        float(r.lightIndex),
        r.w_sum,
        r.w_y,
        r.M
    );
}

#endif // RESTIR_COMMON_GLSL