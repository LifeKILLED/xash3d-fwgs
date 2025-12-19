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
#define NEXT_RADIANCE TEMPORAL_JOIN(out_temporal_radiance,  TEMPORAL_POSTFIX)
#define NEXT_MOMENTS  TEMPORAL_JOIN(out_temporal_moments,   TEMPORAL_POSTFIX)

//---------------------------------------------------------
// Compute
//---------------------------------------------------------

layout(local_size_x = 8, local_size_y = 8) in;

layout(set=0, binding=0, rgba16f) uniform writeonly image2D OUTPUT_RADIANCE;
layout(set=0, binding=1, rgba16f) uniform readonly  image2D INPUT_RADIANCE;
layout(set=0, binding=2, rgba16f) uniform readonly  image2D INPUT_RADIANCE_BLURRED;

layout(set=0, binding=3, rgba16f) uniform readonly  image2D reprojection_uv;

layout(set=0, binding=4, rgba32f) uniform image2D PREV_RADIANCE;
layout(set=0, binding=5, rgba32f) uniform image2D PREV_MOMENTS;

layout(set=0, binding=6, rgba32f) uniform image2D NEXT_RADIANCE;
layout(set=0, binding=7, rgba32f) uniform image2D NEXT_MOMENTS;

layout(set = 0, binding = 8) uniform UBO { UniformBuffer ubo; } ubo;

//---------------------------------------------------------
// CONFIG
//---------------------------------------------------------
#define EPS            1e-6

// First frames schedule you specifically asked for:
#define ALPHA1 0.50
#define ALPHA2 0.25
#define ALPHA3 0.12
#define ALPHA4 0.06

// #define FIREFLY_CLAMP  1.2

// #define MAX_ALPHA      0.5
// #define MIN_ALPHA      0.02
// #define HISTORY_MAX    64.0

// #define FIRST_FRAMES_COUNT 3
// #define VARIANCE_BLUR_FACTOR 0.1

//---------------------------------------------------------
// UTIL
//---------------------------------------------------------
float enc(float x) { return log(max(x, EPS)); }
float dec(float x) { return exp(x); }

// black stabilization for log domain
float safeLum(vec3 c)
{
    float L = luminance(c);
    return max(L, 0.0001); // prevents log(0)
}

vec3 colorBoxClamp(vec3 val, vec3 ref, float scale)
{
    vec3 lim = scale * ref;
    return ref + clamp(val-ref, -lim, lim);
}

vec3 reject_firefly(vec3 raw, vec3 blur)
{
    float Lr = luminance(raw);
    float Lb = luminance(blur);

    if (Lr > Lb * FIREFLY_CLAMP)
        return blur;

    return raw;
}

// main ----------------------------------------------------

void main()
{
    const ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    const ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);

    if (any(greaterThanEqual(p, res))) {
		return;
	}

    vec3 raw = imageLoad(INPUT_RADIANCE, p).rgb;
    vec3 blur = imageLoad(INPUT_RADIANCE_BLURRED, p).rgb;

    // stronger firefly rejection
    vec3 raw_ff = reject_firefly(raw, blur);
    raw_ff = colorBoxClamp(raw_ff, blur, 6.0);

    float rawL = safeLum(raw_ff);

    // reprojection
    vec2 reproj = imageLoad(reprojection_uv, p).xy;
    bool valid = reproj.x >= 0.0;

    vec3 histC = vec3(0);
    float m1 = 0, m2 = 0, m3 = 0, H = 0;

    if (valid)
    {
        ivec2 rp = ivec2(reproj);
        vec4 hc = imageLoad(PREV_RADIANCE, rp);
        vec4 mm = imageLoad(PREV_MOMENTS, rp);

        histC = hc.rgb;
        m1 = mm.r;
        m2 = mm.g;
        m3 = mm.b;
        H  = mm.a;
    }

    float histL = dec(m1);

    // reset logic: safer and less aggressive
    bool reset2 = (!valid) ||
                 (rawL > histL * 5.0) ||
                 (histL > rawL * 5.0) ||
                 (H < 1);

    if (reset2)
    {
        H = 1.0;
        float L = rawL;
        histC = raw_ff;
        m1 = enc(L);
        m2 = enc(L * L);
        m3 = 0.0;
    }

    // Stage 1 prediction
    vec3 predicted = histC;
    float predL = dec(m1);

    float m1_lin = dec(m1);
    float m2_lin = dec(m2);
    float variance = max(m2_lin - m1_lin*m1_lin, EPS);

    // -----------------------------------------------
    // NOISE CHECK: if variance > rawL / 10.0,
    // increase blur contribution (strong noise removal)
    // -----------------------------------------------
    float noiseThreshold = rawL * VARIANCE_BLUR_FACTOR;            // your "luminance/10.0"
    float noiseFactor = smoothstep(noiseThreshold, noiseThreshold * 2.5, variance);
    // noiseFactor = 0 → clean
    // noiseFactor = 1 → very noisy

    // base blur mix (your original code)
    float blurW_base = clamp(variance * 30.0, 0.0, 1.0);

    // -------------------------------------------------------------
    // USE BLUR ONLY FOR HISTORY RESET AND FIRST FRAMES
    // -------------------------------------------------------------

    // --- 1. HISTORY RESET uses blur ---
    float rawLb  = safeLum(blur);
    bool reset_noisy = (rawL > rawLb * FIREFLY_CLAMP * 2.0);

    // keep your reset block but add noise reset:
    bool reset = (!valid) ||
                (rawL > histL * 5.0) ||
                (histL > rawL * 5.0) ||
                (H < 1) ||
                reset_noisy;

    // --- 2. FIRST FRAMES USE BLUR MIX ---
    // only frames H = 1..FIRST_FRAMES_COUNT
    float blurFirstFrames = (H <= FIRST_FRAMES_COUNT) ? 1.0 : 0.0;

    // mix only in first frames
    raw_ff = mix(raw_ff, blur, blurFirstFrames * 0.85);

    //---------------------------------------------------------
    // TEMPORAL ALPHA (your requested schedule + responsiveness fix)
    //---------------------------------------------------------

    float alpha;

    // keep your first-frames schedule:
    if (H == 1 && FIRST_FRAMES_COUNT <= 1)      alpha = ALPHA1;
    else if (H == 2 && FIRST_FRAMES_COUNT <= 2) alpha = ALPHA2;
    else if (H == 3 && FIRST_FRAMES_COUNT <= 3) alpha = ALPHA3;
    else if (H == 4 && FIRST_FRAMES_COUNT <= 4) alpha = ALPHA4;
    else
    {
        float v = clamp(variance * 20.0, 0.0, 1.0);
        alpha = mix(MIN_ALPHA, MAX_ALPHA, v);
    }

    //---------------------------------------------------------
    // --- FIX FOR HISTORY LAG (critical) ---
    //---------------------------------------------------------

    // color change detector (fast response)
    float resp_raw_hist = length(raw_ff - predicted);

    // luminance difference factor
    float lumDiff = abs(rawL - predL) / max(predL, 0.001);

    // scale to 0..1
    float resp = clamp(resp_raw_hist*2.0 + lumDiff*4.0, 0.0, 1.0);

    // sigmoid response (smooth fast wakeup)
    float alpha_resp = 1.0 - exp(-resp * 6.0);

    // final alpha = max of your alpha and responsiveness
    alpha = max(alpha, alpha_resp * MAX_ALPHA);

    // clamp
    alpha = clamp(alpha, MIN_ALPHA, MAX_ALPHA);

    //---------------------------------------------------------
    // ReBLUR-style correction
    //---------------------------------------------------------
    vec3 corrected = colorBoxClamp(raw_ff, predicted, 4.0);

    //---------------------------------------------------------
    // ACCUMULATE
    //---------------------------------------------------------
    vec3 outC = mix(predicted, corrected, alpha);
    float outL = safeLum(outC);

    float nm1 = mix(m1, enc(outL), alpha);
    float nm2 = mix(m2, enc(outL*outL), alpha);
    float nm3 = mix(m3, enc(outL)-nm1, alpha);

    float newH = min(H + 1.0, HISTORY_MAX);

    //---------------------------------------------------------
    // STORE
    //---------------------------------------------------------
    imageStore(OUTPUT_RADIANCE, p, vec4(outC,1));
    imageStore(NEXT_RADIANCE, p, vec4(outC,1));
    imageStore(NEXT_MOMENTS, p, vec4(nm1,nm2,nm3,newH));
}
