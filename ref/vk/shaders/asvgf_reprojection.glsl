#include "debug.glsl"
#include "utils.glsl"
#include "color_spaces.glsl"
#include "brdf.h"

#define GLSL
#include "ray_interop.h"
#undef GLSL

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
#define EPS 1e-6

// Temporal accumulation alphas
#define ALPHA1 0.30
#define ALPHA2 0.20
#define ALPHA3 0.12
#define ALPHA4 0.06
#define MIN_ALPHA 0.01
#define MAX_ALPHA 0.25

#define FIREFLY_CLAMP 1.5

// History / first frame
#define FIRST_FRAMES_COUNT 1
#define HISTORY_MAX 64.0

// Noise / variance
#define VARIANCE_BLUR_FACTOR 0.1
#define TREMOR_VARIANCE_MULT 0.4
#define NOISE_ALPHA_MULT 0.5

// Temporal tuning
#define ALPHA_GLOBAL_MULT 0.5
#define RESET_ALPHA_MULT 0.25
#define DELTA_CLAMP 0.5

// Smart tremor parameters
#define TREMOR_AMPLITUDE_THRESHOLD 0.4
#define TREMOR_ALPHA_MULT 0.2
#define TREMOR_HISTORY_FRAMES 3
#define TREMOR_CONTINUITY_THRESHOLD 0.08
#define TREMOR_SMOOTH_FACTOR 0.3
#define TREMOR_DEVIATION_THRESHOLD 0.03

//---------------------------------------------------------
// UTIL
//---------------------------------------------------------
float enc(float x) { return log(max(x, EPS)); }
float dec(float x) { return exp(x); }

float safeLum(vec3 c) { return max(luminance(c), 0.0001); }

vec3 colorBoxClamp(vec3 val, vec3 ref, float scale)
{
    vec3 lim = scale * ref;
    return ref + clamp(val-ref, -lim, lim);
}

vec3 reject_firefly(vec3 raw, vec3 blur)
{
    float Lr = luminance(raw);
    float Lb = luminance(blur);
    return (Lr > Lb * FIREFLY_CLAMP) ? blur : raw;
}

//---------------------------------------------------------
// Compute
//---------------------------------------------------------
layout(local_size_x = 8, local_size_y = 8) in;

layout(set=0, binding=0, rgba16f) uniform writeonly image2D OUTPUT_RADIANCE;
layout(set=0, binding=1, rgba16f) uniform readonly image2D INPUT_RADIANCE;

#ifdef INPUT_RADIANCE_BLURRED
layout(set=0, binding=2, rgba16f) uniform readonly image2D INPUT_RADIANCE_BLURRED;
#endif

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
    const ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    const ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
    if (any(greaterThanEqual(p, res))) return;

    vec3 raw = imageLoad(INPUT_RADIANCE, p).rgb;
#ifdef INPUT_RADIANCE_BLURRED
    vec3 blur = imageLoad(INPUT_RADIANCE_BLURRED, p).rgb;
#else
    vec3 blur = raw;
#endif

    vec3 raw_ff = reject_firefly(raw, blur);
    raw_ff = colorBoxClamp(raw_ff, blur, 6.0);
    float rawL = safeLum(raw_ff);

    // Reprojection
    vec2 rp_uv = imageLoad(reprojection_uv, p).xy;
    bool valid = all(greaterThanEqual(rp_uv, vec2(0.0))) && all(lessThan(rp_uv, vec2(res)));
    ivec2 rp = ivec2(floor(rp_uv + vec2(0.5)));
    valid = valid && all(greaterThanEqual(rp, ivec2(0))) && all(lessThan(rp, res));

    vec3 histC = vec3(0);
    float m1=0, m2=0, m3=0, H=0;

    if (!valid)
    {
        histC = raw_ff;
        m1 = enc(rawL); m2 = enc(rawL*rawL); m3=0.0; H=1.0;
    }
    else
    {
        vec4 hc = imageLoad(PREV_RADIANCE, rp);
        vec4 mm = imageLoad(PREV_MOMENTS, rp);
        histC = hc.rgb; m1 = mm.r; m2 = mm.g; m3 = mm.b; H = mm.a;

        // Soft reset
        float rawLb = safeLum(blur);
        bool reset_noisy = rawL > rawLb * FIREFLY_CLAMP*2.0;
        float lumRatio = clamp(rawL/(dec(m1)+EPS),0.0,10.0);
        float lightChange = smoothstep(0.2,2.0,max(lumRatio,1.0/lumRatio));
        float reset_strength = max(lightChange, reset_noisy?1.0:0.0);
        float resetAlpha = clamp(reset_strength,0.0,1.0)*RESET_ALPHA_MULT;

        histC = mix(histC, raw_ff, resetAlpha);
        m1    = mix(m1, enc(rawL), resetAlpha);
        m2    = mix(m2, enc(rawL*rawL), resetAlpha);
        m3    = mix(m3, 0.0, resetAlpha);
        H     = mix(H,1.0,resetAlpha);
    }

    float histL = dec(m1);
    vec3 predicted = histC;
    float predL = dec(m1);

    // Variance
    float m1_lin = dec(m1), m2_lin = dec(m2);
    float variance = max(m2_lin - m1_lin*m1_lin, EPS);
    float tremorVar = dot(abs(predicted - raw_ff), vec3(0.333));
    variance = max(variance, tremorVar*TREMOR_VARIANCE_MULT);

    //---------------------------------------------------------
    // SMART TREMOR DETECTION USING CURVE DEVIATION
    //---------------------------------------------------------
    vec4 prevDeltas = imageLoad(PREV_TREMOR, p);
    float deltaL = rawL - predL;

    float deltas[4] = float[4](deltaL, prevDeltas.r, prevDeltas.g, prevDeltas.b);

    // Compute linear trend: slope = (delta3 - delta0)/3
    float slope = (deltas[3]-deltas[0])/3.0;
    float intercept = deltas[0];
    float maxDev = 0.0;
    for(int i=0;i<4;i++)
    {
        float expected = intercept + slope*i;
        float dev = abs(deltas[i]-expected);
        maxDev = max(maxDev, dev);
    }

    float tremorFactor = 0.0;
    if(maxDev > TREMOR_DEVIATION_THRESHOLD && abs(deltaL)<TREMOR_AMPLITUDE_THRESHOLD)
        tremorFactor = TREMOR_ALPHA_MULT;

    //---------------------------------------------------------
    // Noise factor
    //---------------------------------------------------------
    float noiseThreshold = rawL * VARIANCE_BLUR_FACTOR;
    float noiseFactor = smoothstep(noiseThreshold, noiseThreshold*2.5, variance);

    //---------------------------------------------------------
    // First frames blur mix
    //---------------------------------------------------------
    float blurFirstFrames = (H <= FIRST_FRAMES_COUNT) ? 1.0 : 0.0;
    raw_ff = mix(raw_ff, blur, blurFirstFrames*0.85);

    //---------------------------------------------------------
    // Adaptive temporal alpha
    //---------------------------------------------------------
    float alpha;
    if(H==1 && FIRST_FRAMES_COUNT<=1) alpha=ALPHA1;
    else if(H==2 && FIRST_FRAMES_COUNT<=2) alpha=ALPHA2;
    else if(H==3 && FIRST_FRAMES_COUNT<=3) alpha=ALPHA3;
    else if(H==4 && FIRST_FRAMES_COUNT<=4) alpha=ALPHA4;
    else
    {
        float v = clamp(variance*20.0,0.0,1.0);
        alpha = mix(MIN_ALPHA,MAX_ALPHA,v);
    }

    // Light motion response
    float resp_raw_hist = length(raw_ff - predicted);
    float lumDiff = abs(rawL - predL)/max(predL,0.001);
    float resp = clamp(resp_raw_hist*2.0 + lumDiff*4.0,0.0,1.0);
    float alpha_resp = 1.0 - exp(-resp*6.0);

    alpha = max(alpha, alpha_resp*MAX_ALPHA);
    alpha = mix(alpha, MAX_ALPHA, noiseFactor*NOISE_ALPHA_MULT);

    // Apply tremor damping
    alpha *= (1.0 - tremorFactor);
    alpha = clamp(alpha, MIN_ALPHA, MAX_ALPHA);
    alpha *= ALPHA_GLOBAL_MULT;

    //---------------------------------------------------------
    // ReBLUR-style correction
    //---------------------------------------------------------
    vec3 corrected = colorBoxClamp(raw_ff, predicted, 4.0);
    vec3 delta = corrected - predicted;
    delta = clamp(delta, -predL*DELTA_CLAMP, predL*DELTA_CLAMP);
    vec3 outC = predicted + delta*alpha;
    float outL = safeLum(outC);

    //---------------------------------------------------------
    // Accumulate
    //---------------------------------------------------------
    float nm1 = mix(m1, enc(outL), alpha);
    float nm2 = mix(m2, enc(outL*outL), alpha);
    float nm3 = mix(m3, enc(outL)-nm1, alpha);
    float newH = min(H+1.0, HISTORY_MAX);

    //---------------------------------------------------------
    // Store
    //---------------------------------------------------------
    imageStore(OUTPUT_RADIANCE, p, vec4(outC,1));
    imageStore(NEXT_RADIANCE, p, vec4(outC,1));
    imageStore(NEXT_MOMENTS, p, vec4(nm1,nm2,nm3,newH));

    // Store tremor deltas for next frame
    imageStore(NEXT_TREMOR, p, vec4(deltas[0], deltas[1], deltas[2], deltas[3]));
}
