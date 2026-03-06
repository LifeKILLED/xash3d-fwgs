#ifndef ATROUS_KERNEL
#define ATROUS_KERNEL 2
#endif

#ifndef SRC_RADIANCE
#define SRC_RADIANCE indirect_specular
#endif

#ifndef OUT_RADIANCE
#define OUT_RADIANCE out_indirect_specular_denoised
#endif

#ifndef POSITION_T
#define POSITION_T position_t
#endif

#ifndef NORMALS_GS
#define NORMALS_GS normals_gs
#endif

#ifndef MATERIAL_RMXX
#define MATERIAL_RMXX material_rmxx
#endif

#ifndef ROUGHNESS_DIFF_THRESHOLD
#define ROUGHNESS_DIFF_THRESHOLD 0.12
#endif

#ifndef SHADING_NORMAL_DOT_THRESHOLD
#define SHADING_NORMAL_DOT_THRESHOLD 0.95
#endif

#ifndef ATROUS_NORMAL_GATE_SOFTNESS
#define ATROUS_NORMAL_GATE_SOFTNESS 0.05
#endif

#ifndef ATROUS_VARIANCE_RELAX_EDGE
#define ATROUS_VARIANCE_RELAX_EDGE 1.25
#endif

#ifndef ATROUS_MASK_GATE_ENABLE
#define ATROUS_MASK_GATE_ENABLE 1
#endif

#ifndef ATROUS_MASK_SOURCE
#define ATROUS_MASK_SOURCE asvgf_shadow_mask_normalized
#endif

#ifndef ATROUS_MASK_CHANNEL
#define ATROUS_MASK_CHANNEL 0
#endif

#ifndef ATROUS_MASK_DIFF_MIN
#define ATROUS_MASK_DIFF_MIN 0.01
#endif

#ifndef ATROUS_MASK_DIFF_MAX
#define ATROUS_MASK_DIFF_MAX 0.30
#endif

#ifndef ATROUS_MASK_GATE_STRENGTH
#define ATROUS_MASK_GATE_STRENGTH 1.0
#endif

#ifndef AGGRESSIVE_KILL_FIREFLYES
#define AGGRESSIVE_KILL_FIREFLYES 1
#endif

#ifndef MIRROR_FIX
#define MIRROR_FIX 0
#endif

#include "denoiser_config.glsl"
#include "debug.glsl"
#include "utils.glsl"
#include "color_spaces.glsl"
#include "brdf.glsl"

#define GLSL
#include "ray_interop.h"
#undef GLSL

#define LOCAL_SZ_X 8
#define LOCAL_SZ_Y 8
#define PAD (ATROUS_KERNEL + 1)
#define SHARED_W (LOCAL_SZ_X + 2 * PAD)
#define SHARED_H (LOCAL_SZ_Y + 2 * PAD)

layout(local_size_x = LOCAL_SZ_X, local_size_y = LOCAL_SZ_Y, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba16f) uniform image2D OUT_RADIANCE;
layout(set = 0, binding = 1, rgba16f) uniform readonly image2D SRC_RADIANCE;
layout(set = 0, binding = 2, rgba32f) uniform readonly image2D POSITION_T;
layout(set = 0, binding = 3, rgba16f) uniform readonly image2D NORMALS_GS;
layout(set = 0, binding = 4, rgba8) uniform readonly image2D MATERIAL_RMXX;
layout(set = 0, binding = 5) uniform UBO { UniformBuffer ubo; } ubo;
#if ATROUS_MASK_GATE_ENABLE
layout(set = 0, binding = 6, rgba16f) uniform readonly image2D ATROUS_MASK_SOURCE;
#endif

shared vec3 sRadiance[SHARED_H][SHARED_W];
shared vec3 sPos[SHARED_H][SHARED_W];
shared vec3 sGeomN[SHARED_H][SHARED_W];
shared vec3 sShadeN[SHARED_H][SHARED_W];
shared float sRough[SHARED_H][SHARED_W];
shared float sVar[SHARED_H][SHARED_W];
#if ATROUS_MASK_GATE_ENABLE
shared float sMask[SHARED_H][SHARED_W];
#endif

ivec2 clampPix(ivec2 p, ivec2 res) {
    return clamp(p, ivec2(0), res - 1);
}

vec3 safeRadiance(vec3 c) {
    bvec3 bad = bvec3(isnan(c.x) || isinf(c.x), isnan(c.y) || isinf(c.y), isnan(c.z) || isinf(c.z));
    vec3 safe = vec3(bad.x ? 0.0 : c.x, bad.y ? 0.0 : c.y, bad.z ? 0.0 : c.z);
    return max(safe, vec3(0.0));
}

float safeLuma(vec3 c) {
    return max(luminance(c), 1e-5);
}

float normalGateWeight(vec3 a, vec3 b, float threshold, float relax) {
    float nd = max(dot(a, b), 0.0);
    float soft = ATROUS_NORMAL_GATE_SOFTNESS * max(relax, 1.0);
    float t0 = clamp(threshold - soft, 0.0, 1.0);
    float t1 = clamp(threshold + soft * 0.5, t0 + 1e-4, 1.0);
    return smoothstep(t0, t1, nd);
}

float maskGateWeight(float m0, float m1) {
#if ATROUS_MASK_GATE_ENABLE
    float dm = abs(m1 - m0);
    float t = (dm - ATROUS_MASK_DIFF_MIN) / max(ATROUS_MASK_DIFF_MAX - ATROUS_MASK_DIFF_MIN, 1e-4);
    float raw_w = 1.0 - clamp(t, 0.0, 1.0);
    return mix(1.0, raw_w, clamp(ATROUS_MASK_GATE_STRENGTH, 0.0, 1.0));
#else
    return 1.0;
#endif
}

float spatialWeight(int dx, int dy) {
#if ATROUS_KERNEL == 2
    const float k5[5] = float[5](1.0, 4.0, 6.0, 4.0, 1.0);
    return k5[dx + 2] * k5[dy + 2];
#else
    float dist2 = float(dx * dx + dy * dy);
    float sigma = max(float(ATROUS_KERNEL) * 0.75, 1.0);
    return exp(-dist2 / (2.0 * sigma * sigma));
#endif
}

void loadSharedTexel(ivec2 tex, ivec2 res, int sx, int sy) {
    ivec2 p = clampPix(tex, res);
    sRadiance[sy][sx] = safeRadiance(imageLoad(SRC_RADIANCE, p).rgb);
    sPos[sy][sx] = imageLoad(POSITION_T, p).xyz;
    vec4 n = imageLoad(NORMALS_GS, p);
    sGeomN[sy][sx] = normalDecode(n.xy);
    sShadeN[sy][sx] = normalDecode(n.zw);
    sRough[sy][sx] = imageLoad(MATERIAL_RMXX, p).x;
#if ATROUS_MASK_GATE_ENABLE
    sMask[sy][sx] = imageLoad(ATROUS_MASK_SOURCE, p)[ATROUS_MASK_CHANNEL];
#endif
}

float computeVariance3x3(int sx, int sy) {
    float m1 = 0.0;
    float m2 = 0.0;
    float w = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float L = safeLuma(sRadiance[sy + y][sx + x]);
            m1 += L;
            m2 += L * L;
            w += 1.0;
        }
    }
    m1 /= max(w, 1.0);
    m2 /= max(w, 1.0);
    float var = max(m2 - m1 * m1, 0.0);
    return clamp(var / max(m1 * m1, 1e-4), 0.0, 1.0);
}

void main() {
    ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
    ivec2 pix = ivec2(gl_GlobalInvocationID.xy);
    if (any(greaterThanEqual(pix, res))) return;

    ivec2 local = ivec2(gl_LocalInvocationID.xy);
    ivec2 sharedOrigin = ivec2(gl_WorkGroupID.xy) * ivec2(LOCAL_SZ_X, LOCAL_SZ_Y) - ivec2(PAD);
    int lane = int(gl_LocalInvocationIndex);
    int lanes = LOCAL_SZ_X * LOCAL_SZ_Y;
    int sharedCount = SHARED_W * SHARED_H;

    for (int idx = lane; idx < sharedCount; idx += lanes) {
        int sy = idx / SHARED_W;
        int sx = idx - sy * SHARED_W;
        ivec2 tex = sharedOrigin + ivec2(sx, sy);
        loadSharedTexel(tex, res, sx, sy);
    }

    barrier();

    // Phase 1: local variance in shared memory.
    for (int idx = lane; idx < sharedCount; idx += lanes) {
        int sy = idx / SHARED_W;
        int sx = idx - sy * SHARED_W;
        if (sx <= 0 || sy <= 0 || sx >= SHARED_W - 1 || sy >= SHARED_H - 1) {
            sVar[sy][sx] = 1.0;
        } else {
            sVar[sy][sx] = computeVariance3x3(sx, sy);
        }
    }

    barrier();

    int cx = local.x + PAD;
    int cy = local.y + PAD;

    vec3 centerC = sRadiance[cy][cx];
    float centerRough = sRough[cy][cx];

    if (DENOISER_ENABLE_ATROUS == 0) {
        imageStore(OUT_RADIANCE, pix, vec4(centerC, 1.0));
        return;
    }

#if MIRROR_FIX
    if (centerRough < 0.02) {
        imageStore(OUT_RADIANCE, pix, vec4(centerC, 1.0));
        return;
    }
#endif

    vec3 P0 = sPos[cy][cx];
    vec3 G0 = sGeomN[cy][cx];
    vec3 N0 = sShadeN[cy][cx];
    float V0 = sVar[cy][cx];
#if ATROUS_MASK_GATE_ENABLE
    float M0 = sMask[cy][cx];
#endif

    vec3 camPos = (ubo.ubo.inv_view * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
    float invCenterDist = 1.0 / max(length(P0), 1.0);
    float relax = 1.0 + V0 * ATROUS_VARIANCE_RELAX_EDGE;
    float worldTexelSize = estimateWorldTexelSizeFromCenter(
        pix, res, camPos, P0, ubo.ubo.inv_proj, ubo.ubo.inv_view, DENOISER_POSITION_TEXEL_SIZE_MARGIN);
    float planeThreshold = DENOISER_POSITION_PLANE_THRESHOLD * relax;
    float roughnessThreshold = ROUGHNESS_DIFF_THRESHOLD * relax;

    // Phase 2: edge-aware smoothing.
    vec3 sumC = vec3(0.0);
    float sumW = 0.0;
    for (int ky = -ATROUS_KERNEL; ky <= ATROUS_KERNEL; ky++) {
        for (int kx = -ATROUS_KERNEL; kx <= ATROUS_KERNEL; kx++) {
            int sx = cx + kx;
            int sy = cy + ky;
            if (sx < 0 || sy < 0 || sx >= SHARED_W || sy >= SHARED_H) continue;

            vec3 P1 = sPos[sy][sx];
            float wPos = positionEdgeStopWithWorldTexel(
                P1 - P0, G0, invCenterDist, planeThreshold, worldTexelSize);
            if (wPos == 0.0) continue;

            vec3 N1 = sShadeN[sy][sx];
            float wN = normalGateWeight(N0, N1, SHADING_NORMAL_DOT_THRESHOLD, relax);
            if (wN <= 1e-4) continue;

            float R1 = sRough[sy][sx];
            float wR = step(abs(centerRough - R1), roughnessThreshold);
            if (wR == 0.0) continue;

            float w = spatialWeight(kx, ky) * wPos * wN * wR;
#if ATROUS_MASK_GATE_ENABLE
            w *= maskGateWeight(M0, sMask[sy][sx]);
#endif
            if (w <= 1e-6 || isnan(w) || isinf(w)) continue;

            sumC += sRadiance[sy][sx] * w;
            sumW += w;
        }
    }

    vec3 smoothC = (sumW > 1e-6) ? (sumC / sumW) : centerC;
    smoothC = safeRadiance(smoothC);

    sRadiance[cy][cx] = smoothC;
    barrier();

    // Phase 3: firefly suppression on smoothed neighborhood.
#if AGGRESSIVE_KILL_FIREFLYES
    float mu = 0.0;
    float m2 = 0.0;
    float cnt = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float L = safeLuma(sRadiance[cy + y][cx + x]);
            mu += L;
            m2 += L * L;
            cnt += 1.0;
        }
    }
    mu /= max(cnt, 1.0);
    m2 /= max(cnt, 1.0);
    float sigma = sqrt(max(m2 - mu * mu, 0.0));
    float lo = max(mu - 2.5 * sigma, 0.0);
    float hi = mu + 2.5 * sigma;

    float Ls = safeLuma(smoothC);
    float Lc = clamp(Ls, lo, hi);
    vec3 outC = smoothC * (Lc / max(Ls, 1e-6));
#else
    vec3 outC = smoothC;
#endif

    outC = safeRadiance(outC);
    imageStore(OUT_RADIANCE, pix, vec4(outC, 1.0));
}
