#include "debug.glsl"
#include "utils.glsl"
#include "color_spaces.glsl"
#include "brdf.h"

#define GLSL
#include "ray_interop.h"
#undef GLSL

#define EPS 1e-6

//---------------------------------------------------------
// CONFIG
//---------------------------------------------------------
#ifndef ATROUS_STEP
#define ATROUS_STEP 1
#endif

//---------------------------------------------------------
// AGGRESSIVE DENOISE CONFIG
//---------------------------------------------------------
#define AGGRESSIVE_DENOISE 1        // 0 = off, 1 = on

#define VARIANCE_TO_RADIUS 8.0      // how fast kernel grows with variance
#define VARIANCE_RELAX_EDGE 1.5     // relax edge stopping
#define VARIANCE_FLATTEN_KERNEL 0.6 // flatten weights for noisy pixels

#define VARIANCE_MIN 1e-4
#define VARIANCE_MAX 0.5

//---------------------------------------------------------
// KERNEL
//---------------------------------------------------------

#ifdef VARIANCE_PASS
    // can be variable
    #define KERNEL 3
#else
const ivec2 KERNEL3[9] = ivec2[9](
    ivec2(-1,-1), ivec2(0,-1), ivec2(1,-1),
    ivec2(-1, 0), ivec2(0, 0), ivec2(1, 0),
    ivec2(-1, 1), ivec2(0, 1), ivec2(1, 1)
);

const float KERNEL3_W[9] = float[9](
    1, 2, 1,
    2, 4, 2,
    1, 2, 1
);
#endif

//---------------------------------------------------------
// IO
//---------------------------------------------------------
layout(local_size_x = 8, local_size_y = 8) in;

layout(set = 0, binding = 0, rgba16f) uniform readonly  image2D IN_RADIANCE;

#ifdef VARIANCE_PASS
layout(set = 0, binding = 1, rgba16f) uniform writeonly image2D out_atrous_variance;
#else // !VARIANCE_PASS
layout(set = 0, binding = 2, rgba16f) uniform writeonly image2D OUTPUT_RADIANCE;
layout(set = 0, binding = 3, rgba16f) uniform readonly image2D atrous_variance;
layout(set = 0, binding = 4, rgba32f) uniform readonly image2D POSITION_T;
layout(set = 0, binding = 5, rgba16f) uniform readonly image2D NORMALS_GS;
layout(set = 0, binding = 6, rgba8)   uniform readonly image2D MATERIAL_RMXX;
#endif // !VARIANCE_PASS

layout(set = 0, binding = 7) uniform UBO { UniformBuffer ubo; } ubo;

//---------------------------------------------------------
// UTIL
//---------------------------------------------------------
float safeLum(vec3 c) { return max(luminance(c), 1e-4); }

float wNormal(vec3 a, vec3 b, float relax)
{
    return pow(max(dot(a,b),0.0), 64.0 / relax);
}

float wPosition(vec3 a, vec3 b, float relax)
{
    float d = length(a - b);
    return exp(-d * 0.02 / relax);
}

float wRoughness(float a, float b, float relax)
{
    return exp(-abs(a-b) * 8.0 / relax);
}

float wVariance(float a, float b)
{
    float d = abs(a-b) / max(a, 1e-4);
    return exp(-d * 4.0);
}

//---------------------------------------------------------
// VARIANCE PASS
//---------------------------------------------------------
#ifdef VARIANCE_PASS

void main()
{
    ivec2 p   = ivec2(gl_GlobalInvocationID.xy);
    ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
    if(any(greaterThanEqual(p,res))) return;

    float m1 = 0.0;
    float m2 = 0.0;
    float w  = 0.0;

    for(int x = -KERNEL; x <= KERNEL; x++) {
        for(int y = -KERNEL; y <= KERNEL; y++) {
            ivec2 q = clamp(p + ivec2(x, y), ivec2(0), res-1);
            float L = safeLum(imageLoad(IN_RADIANCE, q).rgb);
            m1 += L;
            m2 += L * L;
            w  += 1.0;
        }
    }

    m1 /= w;
    m2 /= w;

    float variance = max(m2 - m1*m1, EPS);
    imageStore(out_atrous_variance, p, vec4(variance));
}

#else // !VARIANCE_PASS

//---------------------------------------------------------
// À-TROUS PASS
//---------------------------------------------------------

void main()
{
    ivec2 p   = ivec2(gl_GlobalInvocationID.xy);
    ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
    if(any(greaterThanEqual(p,res))) return;

    vec3 centerC = imageLoad(IN_RADIANCE, p).rgb;

    vec3  N0 = normalDecode(imageLoad(NORMALS_GS, p).zw);
    vec3  P0 = imageLoad(POSITION_T, p).xyz;
    float R0 = imageLoad(MATERIAL_RMXX, p).x;
    float V0 = imageLoad(atrous_variance, p).r;

    //---------------------------------------------------------
    // Variance factor
    //---------------------------------------------------------
    float v = clamp((V0 - VARIANCE_MIN) / (VARIANCE_MAX - VARIANCE_MIN), 0.0, 1.0);

#if AGGRESSIVE_DENOISE
    float relax = 1.0 + v * VARIANCE_RELAX_EDGE;
    float kernelFlatten = mix(1.0, VARIANCE_FLATTEN_KERNEL, v);
    int step = int(float(ATROUS_STEP) * (1.0 + v * VARIANCE_TO_RADIUS));
#else
    float relax = 1.0;
    float kernelFlatten = 1.0;
    int step = ATROUS_STEP;
#endif

    vec3 sumC = vec3(0);
    float sumW = 0.0;

    for(int i=0;i<9;i++)
    {
        ivec2 q = clamp(p + KERNEL3[i] * step, ivec2(0), res-1);

        vec3 c = imageLoad(IN_RADIANCE, q).rgb;

        vec3  N1 = normalDecode(imageLoad(NORMALS_GS, q).zw);
        vec3  P1 = imageLoad(POSITION_T, q).xyz;
        float R1 = imageLoad(MATERIAL_RMXX, q).x;
        float V1 = imageLoad(atrous_variance, q).r;

        float w =
              pow(KERNEL3_W[i], kernelFlatten)
            * wNormal(N0,N1,relax)
            * wPosition(P0,P1,relax)
            * wRoughness(R0,R1,relax)
            * wVariance(V0,V1);

        sumC += c * w;
        sumW += w;
    }

    vec3 outC = sumC / max(sumW, EPS);
    imageStore(OUTPUT_RADIANCE, p, vec4(outC,1));
}

#endif // !VARIANCE_PASS
