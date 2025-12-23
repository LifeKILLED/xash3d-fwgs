#include "debug.glsl"
#include "utils.glsl"
#include "color_spaces.glsl"
#include "brdf.h"

#define GLSL
#include "ray_interop.h"
#undef GLSL

// === VERTICAL PASS ===

// === Tunable parameters ===
// #define R_BASE 4           // radius in fully lit or fully shadowed areas
// #define R_PENUMBRA 12      // radius in penumbra
// #define SIGMA_N 0.02       // normal similarity
// #define SIGMA_P 4.0        // position similarity
// #define SIGMA_R 0.2        // roughness similarity

layout(local_size_x = 16, local_size_y = 8) in;

layout(set = 0, binding = 0, rgba16f) uniform readonly image2D radiance_temp;

layout(set = 0, binding = 1, rgba32f) uniform readonly image2D POSITION_T;
layout(set = 0, binding = 2, rgba16f) uniform readonly image2D NORMALS_GS;
layout(set = 0, binding = 3, rgba8)   uniform readonly image2D MATERIAL_RMXX;

layout(set = 0, binding = 4, rgba16f) uniform writeonly image2D OUT_RADIANCE;

layout(set = 0, binding = 5) uniform UBO { UniformBuffer ubo; } ubo;

// Same utility functions here …
ivec2 clampedPix(ivec2 c, ivec2 res) {
    return  clamp(c, ivec2(0), res - ivec2(1));
}
float computeGeomGrad(vec3 N0, vec3 P0, vec3 Nx, vec3 Ny, vec3 Px, vec3 Py) {
    float dp = length(Px - P0) + length(Py - P0);
    float dn = 1.0 - dot(N0, normalize(Nx + Ny + N0));
    return clamp(dp * 0.25 + dn * 2.0, 0.0, 1.0);
}
float computeVariance(vec3 c, vec3 cx, vec3 cy) {
    float v = length(c - 0.5 * (cx + cy));
    return clamp(v * 0.5, 0.0, 1.0);
}

void main() {
    const ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
    const ivec2 pix = ivec2(gl_GlobalInvocationID.xy);

	if (any(greaterThanEqual(pix, res)))
		return;

    float R0 = imageLoad(MATERIAL_RMXX, pix).x;

#if MIRROR_FIX
    if (R0 < 0.02) {
        imageStore(OUT_RADIANCE,  pix, imageLoad(radiance_temp, pix));
        return;
    }
#endif

    vec3 P0  = imageLoad(POSITION_T,  pix).xyz;
    vec3 N0  = normalDecode(imageLoad(NORMALS_GS, pix).zw);

    // === neighbors for gradient ===
    vec3 Px = imageLoad(POSITION_T, clampedPix(pix + ivec2(1,0), res)).xyz;
    vec3 Py = imageLoad(POSITION_T, clampedPix(pix + ivec2(0,1), res)).xyz;

    vec3 Nx = normalDecode(imageLoad(NORMALS_GS, clampedPix(pix + ivec2(1,0), res)).zw);
    vec3 Ny = normalDecode(imageLoad(NORMALS_GS, clampedPix(pix + ivec2(0,1), res)).zw);

    vec3 c0 = imageLoad(radiance_temp, pix).xyz;
    vec3 cx = imageLoad(radiance_temp, clampedPix(pix + ivec2(1,0), res)).xyz;
    vec3 cy = imageLoad(radiance_temp, clampedPix(pix + ivec2(0,1), res)).xyz;

    float L0 = luminance(c0);
    float Lx = luminance(cx);
    float Ly = luminance(cy);

    float gradLum  = clamp(abs(Lx-L0)+abs(Ly-L0),0.0,1.0);
    float gradGeom = computeGeomGrad(N0,P0,Nx,Ny,Px,Py);
    float var      = computeVariance(c0,cx,cy);

    float grad = 0.60*gradLum + 0.30*gradGeom + 0.10*var;

    float radius = mix(float(R_PENUMBRA), float(R_BASE),
                       smoothstep(0.0, 0.8, grad));
    int R = int(radius);

    vec3 diffAcc = vec3(0.0);
    float wSum = 0.0;

    for(int y=-R; y<=R; y++) {
        ivec2 c = pix + ivec2(0, y);

        vec3 P  = imageLoad(POSITION_T, clampedPix(c, res)).xyz;
        vec3 N  = normalDecode(imageLoad(NORMALS_GS, clampedPix(c, res)).zw);
        float Rr= imageLoad(MATERIAL_RMXX, clampedPix(c, res)).x;

        float wPos = exp(-dot(P-P0, P-P0) / (SIGMA_P*SIGMA_P));
        float wN   = exp(-(1.0 - max(dot(N,N0),0.0)) / (SIGMA_N*SIGMA_N));
        float wR   = exp(-(abs(Rr-R0)) / SIGMA_R);

        float w = wPos * wN * wR;

    #ifdef SPECULAR_FIX
        float tight = mix(0.25, 1.0, R0);
    #else
        float tight = 1.0;
    #endif
        vec3 d  = imageLoad(radiance_temp, clampedPix(c, res)).xyz;
        diffAcc += d * w * tight;

        wSum += w;
    }

    diffAcc /= max(wSum,1e-5);

    imageStore(OUT_RADIANCE,  pix, vec4(diffAcc,1));
}
