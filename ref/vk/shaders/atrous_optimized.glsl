#ifndef ATROUS_KERNEL
	#define ATROUS_KERNEL 7
#endif

#ifndef STEP_SIZE
	#define STEP_SIZE 1
#endif

#ifndef PHI_POS
	#define PHI_POS 100.0
#endif

#ifndef PHI_NORMAL
	#define PHI_NORMAL 0.5
#endif

#ifndef ROUGHNESS_THRESHOLD
	#define ROUGHNESS_THRESHOLD 0.1
#endif

#ifndef METALNESS_THRESHOLD
	#define METALNESS_THRESHOLD 0.2
#endif

#ifndef VARIANCE_SCALE
	#define VARIANCE_SCALE 350.0
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

#ifndef DISABLE_VARIANCE
	#define USE_VARIANCE
#endif

#include "debug.glsl"
#include "utils.glsl"
#include "color_spaces.glsl"

#define GLSL
#include "ray_interop.h"
#undef GLSL

#define LOCAL_SZ_X 8
#define LOCAL_SZ_Y 8

layout(local_size_x = LOCAL_SZ_X, local_size_y = LOCAL_SZ_Y, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba16f) uniform image2D OUT_RADIANCE;

layout(set = 0, binding = 1, rgba16f) uniform readonly image2D SRC_RADIANCE;
layout(set = 0, binding = 2, rgba32f) uniform readonly image2D POSITION_T;
layout(set = 0, binding = 3, rgba16f) uniform readonly image2D NORMALS_GS;
layout(set = 0, binding = 4, rgba8)   uniform readonly image2D MATERIAL_RMXX;

layout(set = 0, binding = 5) uniform UBO { UniformBuffer ubo; } ubo;

#include "utils.glsl"
#include "noise.glsl"
#include "brdf.glsl"

#ifdef USE_VARIANCE
	const int PADDING = ATROUS_KERNEL + 1;
#else
	const int PADDING = ATROUS_KERNEL;
#endif

const int SHARED_W = LOCAL_SZ_X + 2 * PADDING;
const int SHARED_H = LOCAL_SZ_Y + 2 * PADDING;
const float EPS = 1e-5;

struct TexelData {
    vec3 pos;
    vec3 normal;
	vec3 radiance;
    float roughness;
    float metalness;
#ifdef USE_VARIANCE
	float luminance;
    float variance;
#endif
};

shared TexelData s_tile[SHARED_H][SHARED_W];

float normpdf2(in float x2, in float sigma) { return 0.39894*exp(-0.5*x2/(sigma*sigma))/sigma; }
float normpdf(in float x, in float sigma) { return normpdf2(x*x, sigma); }

ivec2 clampCoord(ivec2 coord, ivec2 size) {
    return clamp(coord, ivec2(0), size - ivec2(1));
}

TexelData loadTexel(ivec2 pix, ivec2 res) {
    const ivec2 p = clampCoord(pix, res);

    TexelData t;
    t.pos = imageLoad(POSITION_T, p).xyz;
    t.normal = normalDecode(imageLoad(NORMALS_GS, p).zw);
    t.radiance = imageLoad(SRC_RADIANCE, p).rgb;

    const vec2 roughness_metalness = imageLoad(MATERIAL_RMXX, p).rg;
	t.roughness = roughness_metalness.r;
	t.metalness = roughness_metalness.g;

#ifdef USE_VARIANCE
	t.luminance = luminance(t.radiance);
    t.variance = 0.0;
#endif

    return t;
}

#ifdef USE_VARIANCE
float computeVariance(int sx, int sy) {
    float mean = 0.0;
    float sqmean = 0.0;
    int cnt = 0;
    for (int oy = -1; oy <= 1; ++oy) {
		for (int ox = -1; ox <= 1; ++ox) {
			const int nx = sx + ox, ny = sy + oy;

			if (nx >= 0 && nx < SHARED_W && ny >= 0 && ny < SHARED_H) {
				float v = s_tile[ny][nx].luminance;

				mean += v;
				sqmean += v * v;
				cnt++;
			}
		}
	}

    if (cnt == 0)
		return 0.0;

    mean /= float(cnt);
    sqmean /= float(cnt);

    return max(sqmean - mean * mean, 0.0);
}
#endif

vec3 rayDirFromUV(vec2 uv, mat4 invProj, mat4 invView) {
    vec2 ndc = uv * 2.0 - 1.0;
    vec4 clip = vec4(ndc, 1.0, 1.0);
    vec4 view = invProj * clip;
    view /= view.w;
    return normalize((invView * vec4(view.xyz, 0.0)).xyz);
}

vec3 rayOrigin(mat4 invView) {
    return (invView * vec4(0,0,0,1)).xyz;
}

vec3 intersectplane(vec3 ro, vec3 rd, vec3 p0, vec3 pn) {
    float d = dot(rd, pn);
    float t = dot(p0 - ro, pn) / d;
    return ro + rd * t;
}

vec3 planarOffset(ivec2 pix, ivec2 offset, vec3 centerPos, vec3 centerNormal, mat4 invProj, mat4 invView) {
    vec2 uv = (vec2(pix + offset) + 0.5) / vec2(ubo.ubo.res.xy * ubo.ubo.resScale);
    vec3 ro = rayOrigin(invView);
    vec3 rd = rayDirFromUV(uv, invProj, invView);
    return intersectplane(ro, rd, centerPos, centerNormal);
}

void computeDdXY(ivec2 pix, vec3 centerPos, vec3 centerNormal, mat4 invProj, mat4 invView, out vec3 ddx, out vec3 ddy, out float depthThreshold) {
    vec3 posR = planarOffset(pix, ivec2(STEP_SIZE,0), centerPos, centerNormal, invProj, invView);
    vec3 posL = planarOffset(pix, ivec2(-STEP_SIZE,0), centerPos, centerNormal, invProj, invView);
    ddx = 0.5 * (posR - posL);
    depthThreshold = length(ddx);

    vec3 posU = planarOffset(pix, ivec2(0,STEP_SIZE), centerPos, centerNormal, invProj, invView);
    vec3 posD = planarOffset(pix, ivec2(0,-STEP_SIZE), centerPos, centerNormal, invProj, invView);
    ddy = 0.5 * (posU - posD);
}

void main() {
	const ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
    const ivec2 pix = ivec2(gl_GlobalInvocationID.xy);
    const ivec2 localID = ivec2(gl_LocalInvocationID.xy);
    const ivec2 sharedOrigin = ivec2(gl_WorkGroupID.xy) * ivec2(LOCAL_SZ_X, LOCAL_SZ_Y) - ivec2(PADDING, PADDING);

	if (sharedOrigin.x >= res.x || sharedOrigin.y >= res.x)
		return;

	// Fill shader memory (one thread reading 3x3 texels)

    const int localThreadIndex = int(gl_LocalInvocationIndex);
    const int localThreadCount = LOCAL_SZ_X * LOCAL_SZ_Y;
    const int totalSharedCount = SHARED_W * SHARED_H;
    for (int idx = localThreadIndex; idx < totalSharedCount; idx += localThreadCount) {
        int sy = idx / SHARED_W;
        int sx = idx - sy * SHARED_W;
        ivec2 tex = sharedOrigin + ivec2(sx, sy) * STEP_SIZE;
        s_tile[sy][sx] = loadTexel(tex, res);
    }

#ifdef USE_VARIANCE
    memoryBarrierShared();
    barrier();

	// Calculate variance

    for (int idx = localThreadIndex; idx < totalSharedCount; idx += localThreadCount) {
        int sy = idx / SHARED_W;
        int sx = idx - sy * SHARED_W;
        s_tile[sy][sx].variance = computeVariance(sx, sy);
    }
#endif

    memoryBarrierShared();
    barrier();

    if (pix.x >= res.x || pix.y >= res.y)
		return;

	// Apply aTrous

    const int centerSX = localID.x + PADDING;
    const int centerSY = localID.y + PADDING;

    TexelData center = s_tile[centerSY][centerSX];

    vec3 center_geom_normal = normalDecode(imageLoad(NORMALS_GS, pix).xy);

    vec3 ddx, ddy;
    float depthThreshold;
    computeDdXY(pix, center.pos, center_geom_normal, ubo.ubo.inv_proj, ubo.ubo.inv_view, ddx, ddy, depthThreshold);

#ifdef MIRROR_FIX
	if (center.roughness == 0.0) {
		imageStore(OUT_RADIANCE, pix, vec4(center.radiance, 1.0));
		return;
	}
#endif

    vec3 accum = vec3(0.0);
	float wsum = 0.0;
    for (int ky = -ATROUS_KERNEL; ky <= ATROUS_KERNEL; ++ky) {
    	for (int kx = -ATROUS_KERNEL; kx <= ATROUS_KERNEL; ++kx) {
			const int sx = centerSX + kx;
			const int sy = centerSY + ky;

			if (sx < 0 || sy < 0 || sx >= SHARED_W || sy >= SHARED_H)
				continue;

			TexelData n = s_tile[sy][sx];

			// Roughness edge stopping
            if (abs(center.roughness - n.roughness) > ROUGHNESS_THRESHOLD)
				continue;

			// Metalness edge stopping
			if (abs(center.metalness - n.metalness) > METALNESS_THRESHOLD)
				continue;

			// Weight shading normals
			const vec3 sn_diff = center.normal - n.normal;
			const float sn_dist2 = dot(sn_diff,sn_diff);
			const float w_normal = min(exp(-(sn_dist2)/PHI_NORMAL), 1.0);
			if (w_normal <= 0.0)
				continue;

            // Edge pos
            vec3 idealPos = center.pos + ddx * float(kx) + ddy * float(ky);
            vec3 planarDiff = n.pos - idealPos;
            float planarDist2 = dot(planarDiff, planarDiff);
            float w_pos = exp(-planarDist2 / (depthThreshold * depthThreshold));
            if (w_pos <= 0.001)
                continue;

			//const float w_sigma = normpdf(float(kx), ATROUS_KERNEL) * normpdf(float(ky), ATROUS_KERNEL);
            const float w_sigma = 1.0f;
            float w = w_normal * w_pos * w_sigma;

			// Weight luminance 
#ifdef USE_VARIANCE
            const float lumDiff = n.luminance - center.luminance;
			const float lumSigma = sqrt(center.variance) + 1e-3;
            const float w_lum = 1.0;//exp(- (lumDiff * lumDiff) / (2.0 * lumSigma * lumSigma + EPS));
			const float w_var = 1.0 / (1.0 + n.variance * VARIANCE_SCALE);
			const float dist2 = float(kx*kx + ky*ky);
			const float w_spatial = 1.0 / (1.0 + dist2);

			w *= w_lum * w_var * w_spatial;
#endif

			accum += n.radiance * w;
			wsum += w;
		}
	}

    vec3 result = accum / max(wsum, EPS);
    imageStore(OUT_RADIANCE, pix, vec4(result, 1.0));
}
