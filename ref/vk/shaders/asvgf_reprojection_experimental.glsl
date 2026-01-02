#include "debug.glsl"
#include "utils.glsl"
#include "color_spaces.glsl"
#include "brdf.h"

#define GLSL
#include "ray_interop.h"
#undef GLSL

#define EPS 1e-6

#ifndef INPUT_RADIANCE
#define INPUT_RADIANCE radiance
#endif

#ifndef OUTPUT_RADIANCE
#define OUTPUT_RADIANCE OUTPUT_RADIANCE
#endif

#ifndef TEMPORAL_POSTFIX
#define TEMPORAL_POSTFIX _radiance
#endif

#define TEMPORAL_JOIN(a, b)       TEMPORAL_JOIN_EXPAND(a, b)
#define TEMPORAL_JOIN_EXPAND(a,b) a##b

#define PREV_RADIANCE TEMPORAL_JOIN(prev_temporal_radiance, TEMPORAL_POSTFIX)
#define PREV_MOMENTS  TEMPORAL_JOIN(prev_temporal_moments,  TEMPORAL_POSTFIX)
#define PREV_TREMOR   TEMPORAL_JOIN(prev_temporal_tremor,   TEMPORAL_POSTFIX)
#define NEXT_RADIANCE TEMPORAL_JOIN(out_temporal_radiance,  TEMPORAL_POSTFIX)
#define NEXT_MOMENTS  TEMPORAL_JOIN(out_temporal_moments,   TEMPORAL_POSTFIX)
#define NEXT_TREMOR   TEMPORAL_JOIN(out_temporal_tremor,    TEMPORAL_POSTFIX)

//---------------------------------------------------------
// CONFIG
//---------------------------------------------------------
#define HISTORY_MAX 64.0

// Luminance agreement thresholds (relative to current)
#define LUMA_MATCH_FULL 0.2
#define LUMA_MATCH_FADE 2.0

// Temporal blending
#define MAX_HISTORY_ALPHA 0.98
#define MIN_HISTORY_ALPHA 0.5

// History adaptation
#define HISTORY_GROW_SPEED   0.5
#define HISTORY_SHRINK_SPEED 0.6

// Tremor analysis
#define TREMOR_SAMPLES 5
#define TREMOR_MIN_STABILITY      0.02
#define TREMOR_GRADIENT_THRESHOLD 0.5

#define TREMOR_AMPLITUDE_FULL 0.02
#define TREMOR_AMPLITUDE_FADE 0.08

#define TREMOR_RISE_SPEED  0.5   // how fast tremor reacts
#define TREMOR_FALL_SPEED  0.3  // how slowly tremor decays

#define TREMOR_STABILITY_MULT 1.0

//---------------------------------------------------------
// UTIL
//---------------------------------------------------------
float safeLum(vec3 c)
{
    return max(luminance(c), 1e-4);
}

float enc(float x) { return log(max(x, EPS)); }
float dec(float x) { return exp(x); }

//---------------------------------------------------------
// Compute
//---------------------------------------------------------
layout(local_size_x = 8, local_size_y = 8) in;

layout(set=0, binding=0, rgba16f) uniform writeonly image2D OUTPUT_RADIANCE;
layout(set=0, binding=1, rgba16f) uniform readonly image2D INPUT_RADIANCE;
layout(set=0, binding=3, rgba16f) uniform readonly image2D reprojection_uv;

layout(set=0, binding=4, rgba32f) uniform image2D PREV_RADIANCE;
layout(set=0, binding=5, rgba32f) uniform image2D PREV_MOMENTS;
layout(set=0, binding=8, rgba32f) uniform image2D PREV_TREMOR;

layout(set=0, binding=6, rgba32f) uniform image2D NEXT_RADIANCE;
layout(set=0, binding=7, rgba32f) uniform image2D NEXT_MOMENTS;
layout(set=0, binding=9, rgba32f) uniform image2D NEXT_TREMOR;

layout(set=0, binding=10) uniform UBO { UniformBuffer ubo; } ubo;

//---------------------------------------------------------
// MAIN
//---------------------------------------------------------
void main()
{
    const ivec2 p   = ivec2(gl_GlobalInvocationID.xy);
    const ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
    if (any(greaterThanEqual(p, res))) return;

    // Current frame (denoised color as reference)
    vec3 rawC = imageLoad(INPUT_RADIANCE, p).rgb;
    float rawL = safeLum(rawC);

    // Reprojection
    ivec2 rp = ivec2(imageLoad(reprojection_uv, p).xy);
    bool valid = all(greaterThanEqual(rp, ivec2(0))) &&
                 all(lessThan(rp, res));

    vec3 histC;
    float histL;
    float H;
    vec4 tremorPrev;

    if (!valid)
    {
        histC = rawC;
        histL = rawL;
        H = 1.0;
        tremorPrev = vec4(rawL);
    }
    else
    {
        histC = imageLoad(PREV_RADIANCE, rp).rgb;
        vec4 mm = imageLoad(PREV_MOMENTS, rp);
        histL = dec(mm.r);
        H     = mm.a;
        tremorPrev = imageLoad(PREV_TREMOR, rp);
    }

    //---------------------------------------------------------
    // Tremor luminance analysis (raw luminance history)
    //---------------------------------------------------------
    float l[TREMOR_SAMPLES];
    l[0] = rawL;
    l[1] = tremorPrev.x;
    l[2] = tremorPrev.y;
    l[3] = tremorPrev.z;
    l[4] = tremorPrev.w;

    // Linear trend estimation
    float slope = (l[3] - l[0]) / float(TREMOR_SAMPLES - 1);
    float intercept = l[0];

    float maxDev = 0.0;
    for (int i = 0; i < TREMOR_SAMPLES; ++i)
    {
        float expected = intercept + slope * float(i);
        maxDev = max(maxDev, abs(l[i] - expected));
    }

    float trendStrength = abs(slope) / max(rawL, EPS);
    float tremorAmplitude = maxDev / max(rawL, EPS);

    // Accumulated tremor (hysteresis)
    float prevAccumTremor = tremorPrev.w;
    float targetTremor = clamp(tremorAmplitude, 0.0, 1.0);

    // float accumTremor;
    // if (targetTremor > prevAccumTremor)
    // {
    //     // Tremor rises quickly
    //     accumTremor = mix(prevAccumTremor, targetTremor, TREMOR_RISE_SPEED);
    // }
    // else
    // {
    //     // Tremor decays slowly
    //     accumTremor = mix(prevAccumTremor, targetTremor, TREMOR_FALL_SPEED);
    // }

    // accumTremor = clamp(accumTremor, 0.0, 1.0);


    // Detect stable jitter vs real lighting change
    float tremorStability =
        1.0 - smoothstep(TREMOR_MIN_STABILITY, TREMOR_GRADIENT_THRESHOLD, trendStrength);

    // tremorStability *=
    //     1.0 - smoothstep(0.0, LUMA_MATCH_FADE, tremorAmplitude);
    // tremorStability *=
    //     1.0 - smoothstep(
    //         TREMOR_AMPLITUDE_FULL,
    //         TREMOR_AMPLITUDE_FADE,
    //         accumTremor
    //     );

    tremorStability = clamp(tremorStability * TREMOR_STABILITY_MULT, 0.0, 1.0);

    //---------------------------------------------------------
    // Luminance agreement with history
    //---------------------------------------------------------
    float relDiff = abs(histL - rawL) / max(rawL, EPS);

    float historyMatch;
    // if (relDiff <= LUMA_MATCH_FULL)
        historyMatch = 1.0;
    // else if (relDiff >= LUMA_MATCH_FADE)
    //     historyMatch = 0.0;
    // else
    //     historyMatch = 1.0 - smoothstep(LUMA_MATCH_FULL, LUMA_MATCH_FADE, relDiff);

    //---------------------------------------------------------
    // History alpha (boosted by tremor stability)
    //---------------------------------------------------------
    float historyFactor = 0.98;//clamp(H / HISTORY_MAX, 0.0, 1.0);

    float alpha = mix(MIN_HISTORY_ALPHA, MAX_HISTORY_ALPHA, historyFactor);
    alpha *= historyMatch;
    //alpha *= mix(0.5, 1.0, tremorStability);
    alpha *= tremorStability;
    //alpha *= mix(0.05, 1.0, tremorStability);
    //alpha *= mix(0.6, 1.0, tremorStability);

    //---------------------------------------------------------
    // Temporal blend (current frame is reference)
    //---------------------------------------------------------
    vec3 outC = mix(rawC, histC, alpha);
    float outL = safeLum(outC);

    //---------------------------------------------------------
    // Smooth history length adaptation
    //---------------------------------------------------------
    float targetH = mix(1.0, HISTORY_MAX, historyMatch * tremorStability);
    float newH;

    if (targetH > H)
        newH = mix(H, targetH, HISTORY_GROW_SPEED);
    else
        newH = mix(H, targetH, HISTORY_SHRINK_SPEED);

    newH = clamp(newH, 1.0, HISTORY_MAX);

    vec3 tremorStabilityVisualize = mix(vec3(1.), vec3(1., 0., 0.), tremorStability);

    //---------------------------------------------------------
    // Store
    //---------------------------------------------------------
    imageStore(OUTPUT_RADIANCE, p, vec4(outC, 1.0) * vec4(tremorStabilityVisualize, 1.0));
    imageStore(NEXT_RADIANCE,  p, vec4(outC, 1.0));
    imageStore(NEXT_MOMENTS,   p, vec4(enc(outL), 0.0, 0.0, newH));

    // Shift tremor luminance history
    imageStore(
        NEXT_TREMOR,
        p,
        // vec4(rawL, tremorPrev.x, tremorPrev.y, accumTremor)
        vec4(rawL, tremorPrev.x, tremorPrev.y, tremorPrev.z)
    );
}


// #include "debug.glsl"
// #include "utils.glsl"
// #include "color_spaces.glsl"
// #include "brdf.h"

// #define GLSL
// #include "ray_interop.h"
// #undef GLSL

// #define EPS 1e-6

// #ifndef INPUT_RADIANCE
// #define INPUT_RADIANCE radiance
// #endif

// #ifndef OUTPUT_RADIANCE
// #define OUTPUT_RADIANCE OUTPUT_RADIANCE
// #endif

// #ifndef TEMPORAL_POSTFIX
// #define TEMPORAL_POSTFIX _radiance
// #endif

// #define TEMPORAL_JOIN(a, b)       TEMPORAL_JOIN_EXPAND(a, b)
// #define TEMPORAL_JOIN_EXPAND(a,b) a##b

// #define PREV_RADIANCE TEMPORAL_JOIN(prev_temporal_radiance, TEMPORAL_POSTFIX)
// #define PREV_MOMENTS  TEMPORAL_JOIN(prev_temporal_moments,  TEMPORAL_POSTFIX)
// #define PREV_TREMOR   TEMPORAL_JOIN(prev_temporal_tremor,   TEMPORAL_POSTFIX)
// #define NEXT_RADIANCE TEMPORAL_JOIN(out_temporal_radiance,  TEMPORAL_POSTFIX)
// #define NEXT_MOMENTS  TEMPORAL_JOIN(out_temporal_moments,   TEMPORAL_POSTFIX)
// #define NEXT_TREMOR   TEMPORAL_JOIN(out_temporal_tremor,    TEMPORAL_POSTFIX)

// //---------------------------------------------------------
// // CONFIG
// //---------------------------------------------------------
// #define HISTORY_MAX 64.0

// // Relative luminance thresholds (relative to current frame)
// #define LUMA_MATCH_FULL   0.3
// #define LUMA_MATCH_FADE   0.4

// // History response
// #define MIN_HISTORY_ALPHA 0.02
// #define MAX_HISTORY_ALPHA 0.5

// // History size adaptation
// #define HISTORY_GROW_SPEED 0.25
// #define HISTORY_SHRINK_SPEED 0.5

// //---------------------------------------------------------
// // UTIL
// //---------------------------------------------------------
// float safeLum(vec3 c)
// {
//     return max(luminance(c), 1e-4);
// }

// float enc(float x) { return log(max(x, EPS)); }
// float dec(float x) { return exp(x); }

// //---------------------------------------------------------
// // Compute
// //---------------------------------------------------------
// layout(local_size_x = 8, local_size_y = 8) in;

// layout(set=0, binding=0, rgba16f) uniform writeonly image2D OUTPUT_RADIANCE;
// layout(set=0, binding=1, rgba16f) uniform readonly image2D INPUT_RADIANCE;
// layout(set=0, binding=3, rgba16f) uniform readonly image2D reprojection_uv;

// layout(set=0, binding=4, rgba32f) uniform image2D PREV_RADIANCE;
// layout(set=0, binding=5, rgba32f) uniform image2D PREV_MOMENTS;

// layout(set=0, binding=6, rgba32f) uniform image2D NEXT_RADIANCE;
// layout(set=0, binding=7, rgba32f) uniform image2D NEXT_MOMENTS;
// layout(set=0, binding=9, rgba32f) uniform image2D NEXT_TREMOR;

// layout(set=0, binding=10) uniform UBO { UniformBuffer ubo; } ubo;

// //---------------------------------------------------------
// // MAIN
// //---------------------------------------------------------
// void main()
// {
//     const ivec2 p   = ivec2(gl_GlobalInvocationID.xy);
//     const ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
//     if (any(greaterThanEqual(p, res))) return;

//     // Current denoised frame (reference)
//     vec3 rawC = imageLoad(INPUT_RADIANCE, p).rgb;
//     float rawL = safeLum(rawC);

//     // Reprojection
//     ivec2 rp = ivec2(imageLoad(reprojection_uv, p).xy);
//     bool valid = all(greaterThanEqual(rp, ivec2(0))) &&
//                  all(lessThan(rp, res));

//     vec3 histC;
//     float histL;
//     float H;

//     if (!valid)
//     {
//         histC = rawC;
//         histL = rawL;
//         H = 1.0;
//     }
//     else
//     {
//         vec4 hc = imageLoad(PREV_RADIANCE, rp);
//         vec4 mm = imageLoad(PREV_MOMENTS, rp);

//         histC = hc.rgb;
//         histL = dec(mm.r);
//         H     = mm.a;
//     }

//     //---------------------------------------------------------
//     // Luminance-based history validity (current is reference)
//     //---------------------------------------------------------
//     float lumDiff = abs(histL - rawL);
//     float relDiff = lumDiff / max(rawL, EPS);

//     // History weight based on luminance agreement
//     float historyMatch;
//     if (relDiff <= LUMA_MATCH_FULL)
//         historyMatch = 1.0;
//     else if (relDiff >= LUMA_MATCH_FADE)
//         historyMatch = 0.0;
//     else
//         historyMatch = 1.0 - smoothstep(LUMA_MATCH_FULL, LUMA_MATCH_FADE, relDiff);

//     //---------------------------------------------------------
//     // History length driven blending
//     //---------------------------------------------------------
//     float historyFactor = clamp(H / HISTORY_MAX, 0.0, 1.0);

//     float alpha = mix(MIN_HISTORY_ALPHA, MAX_HISTORY_ALPHA, historyFactor);
//     alpha *= historyMatch;

//     //---------------------------------------------------------
//     // Final temporal blend (current frame dominates)
//     //---------------------------------------------------------
//     vec3 outC = mix(rawC, histC, alpha);
//     float outL = safeLum(outC);

//     //---------------------------------------------------------
//     // Smooth history length adaptation
//     //---------------------------------------------------------
//     float targetH = mix(1.0, HISTORY_MAX, historyMatch);
//     float newH;

//     if (targetH > H)
//         newH = mix(H, targetH, HISTORY_GROW_SPEED);
//     else
//         newH = mix(H, targetH, HISTORY_SHRINK_SPEED);

//     newH = clamp(newH, 1.0, HISTORY_MAX);

//     //---------------------------------------------------------
//     // Store
//     //---------------------------------------------------------
//     imageStore(OUTPUT_RADIANCE, p, vec4(outC, 1.0));
//     imageStore(NEXT_RADIANCE,  p, vec4(outC, 1.0));
//     imageStore(NEXT_MOMENTS,   p, vec4(enc(outL), 0.0, 0.0, newH));

//     // Tremor buffer unused but preserved
//     imageStore(NEXT_TREMOR, p, vec4(0.0));
// }
