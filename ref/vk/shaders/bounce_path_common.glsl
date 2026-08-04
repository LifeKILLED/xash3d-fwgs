#ifndef BOUNCE_PATH_COMMON_GLSL_INCLUDED
#define BOUNCE_PATH_COMMON_GLSL_INCLUDED

// Shared packing, atlas addressing, and configurable transport-normal access.

#include "bounce_path_config.glsl"
#include "utils.glsl"
#include "color_spaces.glsl"
#include "noise.glsl"
#include "brdf.glsl"

const uint BOUNCE_PATH_MAX_VERTICES = 4u;
const uint BOUNCE_PATH_POINT_SLOT_BASE = 0u;
const uint BOUNCE_PATH_POLY_SLOT_BASE = BOUNCE_PATH_MAX_VERTICES;
const uint BOUNCE_PATH_TOTAL_LIGHT_SLOTS = BOUNCE_PATH_MAX_VERTICES * 2u;
const uint BOUNCE_PATH_INVALID_LIGHT_SLOT = 255u;

#ifndef BOUNCE_PATH_LIGHTING_NORMAL_OFFSET
#define BOUNCE_PATH_LIGHTING_NORMAL_OFFSET 0.01
#endif

vec3 bouncePathSafeNormal(vec3 normal, vec3 fallback_normal)
{
	if (dot(normal, normal) <= 1e-6 || any(isnan(normal))) {
		return normalize(fallback_normal);
	}
	return normalize(normal);
}

vec3 bouncePathTransportNormal(vec3 geometry_normal, vec3 shading_normal)
{
	const vec3 geometry_N = bouncePathSafeNormal(geometry_normal, vec3(0.0, 0.0, 1.0));
#if BOUNCE_PATH_NORMAL_MODE == BOUNCE_PATH_NORMAL_MODE_SHADING
	vec3 shading_N = bouncePathSafeNormal(shading_normal, geometry_N);
	// Keep the shading frame on the same side as the actual surface. The ray
	// origin is still offset with geometry_N in every mode.
	if (dot(shading_N, geometry_N) <= 1e-4) {
		shading_N = geometry_N;
	}
	return shading_N;
#else
	return geometry_N;
#endif
}

ivec2 bouncePathLaneSize()
{
	return ubo.ubo.res / 2;
}

ivec2 bouncePathLaneOrigin(uint lane)
{
	const ivec2 lane_size = bouncePathLaneSize();
	return ivec2(int(lane & 1u), int((lane >> 1u) & 1u)) * lane_size;
}

ivec2 bouncePathAtlasPixel(ivec2 local_pix, uint lane)
{
	return bouncePathLaneOrigin(lane) + local_pix;
}

bool bouncePathLocalPixelInBounds(ivec2 local_pix)
{
	return all(greaterThanEqual(local_pix, ivec2(0))) &&
		all(lessThan(local_pix, bouncePathLaneSize()));
}

bool bouncePathAtlasPixelInBounds(ivec2 atlas_pix)
{
	return all(greaterThanEqual(atlas_pix, ivec2(0))) &&
		all(lessThan(atlas_pix, ubo.ubo.res));
}

vec2 bouncePathPackSeed(uint seed)
{
	return vec2(float(seed & 0xffffu), float(seed >> 16u));
}

uint bouncePathUnpackSeed(vec2 packed)
{
	return uint(clamp(floor(packed.x + 0.5), 0.0, 65535.0)) |
		(uint(clamp(floor(packed.y + 0.5), 0.0, 65535.0)) << 16u);
}

uint bouncePathLengthFromMeta(vec4 meta)
{
	return min(uint(max(floor(meta.z + 0.5), 0.0)), BOUNCE_PATH_MAX_VERTICES);
}

uint bouncePathAgeFromMeta(vec4 meta)
{
	return uint(max(floor(meta.w + 0.5), 0.0));
}

bool bouncePathMetaValid(vec4 meta)
{
	return bouncePathLengthFromMeta(meta) > 0u;
}

ivec2 bouncePathHistoryLocalPixel(vec4 history_ref)
{
	return ivec2(floor(history_ref.xy + vec2(0.5)));
}

bool bouncePathHistoryRefValid(vec4 history_ref)
{
	return history_ref.z > 0.5 && bouncePathLocalPixelInBounds(bouncePathHistoryLocalPixel(history_ref));
}

uint bouncePathRefreshSlot(vec4 history_ref)
{
	return uint(clamp(
		floor(history_ref.w + 0.5),
		0.0,
		float(BOUNCE_PATH_INVALID_LIGHT_SLOT)));
}

uint bouncePathPixelHash(ivec2 local_pix)
{
	return xxhash32(uvec4(uint(local_pix.x), uint(local_pix.y), 0x62706174u, 0x68706978u));
}

uint bouncePathScheduledLightSlot(uint path_seed, ivec2 local_pix, uint age, uint light_vertex_count)
{
	if (light_vertex_count == 0u) {
		return BOUNCE_PATH_INVALID_LIGHT_SLOT;
	}
	light_vertex_count = min(light_vertex_count, BOUNCE_PATH_MAX_VERTICES);
	const uint slot_count = light_vertex_count * 2u;
	const uint offset = xxhash32(uvec4(path_seed, bouncePathPixelHash(local_pix), 0x6c736c74u, 0u)) % slot_count;
	const uint ordinal = (offset + age) % slot_count;
	return ordinal < light_vertex_count
		? BOUNCE_PATH_POINT_SLOT_BASE + ordinal
		: BOUNCE_PATH_POLY_SLOT_BASE + (ordinal - light_vertex_count);
}

uint bouncePathScheduledSegment(uint path_seed, ivec2 local_pix, uint age, uint path_length)
{
	path_length = clamp(path_length, 1u, BOUNCE_PATH_MAX_VERTICES);
	const uint offset = xxhash32(uvec4(path_seed, bouncePathPixelHash(local_pix), 0x7365676du, 0u)) % path_length;
	return (offset + age) % path_length;
}

#ifndef BOUNCE_PATH_COORDS_ONLY

struct BouncePathSurface {
	vec3 P;
	vec3 geometry_N;
	vec3 shading_N;
	vec3 transport_N;
	vec3 V;
	MaterialProperties material;
	vec3 stage_throughput;
	vec3 emissive;
	bool hit;
	bool contributes;
};

BouncePathSurface bouncePathEmptySurface()
{
	BouncePathSurface surface;
	surface.P = vec3(0.0);
	surface.geometry_N = vec3(0.0, 0.0, 1.0);
	surface.shading_N = vec3(0.0, 0.0, 1.0);
	surface.transport_N = vec3(0.0, 0.0, 1.0);
	surface.V = vec3(0.0, 0.0, 1.0);
	surface.material.base_color = vec3(0.0);
	surface.material.metalness = 0.0;
	surface.material.roughness = 1.0;
	surface.stage_throughput = vec3(0.0);
	surface.emissive = vec3(0.0);
	surface.hit = false;
	surface.contributes = false;
	return surface;
}

BouncePathSurface bouncePathLoadFreshSurface(ivec2 local_pix, uint lane)
{
	BouncePathSurface surface = bouncePathEmptySurface();
	const ivec2 pix = bouncePathAtlasPixel(local_pix, lane);
	if (!bouncePathAtlasPixelInBounds(pix)) {
		return surface;
	}

	const vec4 stage = imageLoad(bounce_path_fresh_throughput, pix);
	surface.stage_throughput = max(stage.rgb, vec3(0.0));
	surface.emissive = max(imageLoad(bounce_path_fresh_emissive, pix).rgb, vec3(0.0));
	const vec4 pos_t = imageLoad(bounce_path_fresh_hit_pos, pix);
	surface.hit = pos_t.w > 0.0;
	if (!surface.hit) {
		return surface;
	}

	const vec4 packed_normal = imageLoad(bounce_path_fresh_normals_gs, pix);
	surface.geometry_N = normalDecode(packed_normal.xy);
	surface.shading_N = normalDecode(packed_normal.zw);
	surface.transport_N = bouncePathTransportNormal(surface.geometry_N, surface.shading_N);
	surface.P = pos_t.xyz + surface.geometry_N * BOUNCE_PATH_LIGHTING_NORMAL_OFFSET;
	const vec3 stored_view = imageLoad(bounce_path_fresh_view_dir, pix).xyz;
	surface.V = dot(stored_view, stored_view) > 1e-6 ? normalize(stored_view) : surface.transport_N;
	surface.material.base_color = SRGBtoLINEAR(imageLoad(bounce_path_fresh_base_color_a, pix).rgb);
	surface.material.metalness = 0.0;
	surface.material.roughness = 1.0;
	surface.contributes = any(greaterThan(surface.stage_throughput, vec3(1e-6)));
	return surface;
}

BouncePathSurface bouncePathLoadHistorySurface(ivec2 history_local_pix, uint lane)
{
	BouncePathSurface surface = bouncePathEmptySurface();
	const ivec2 pix = bouncePathAtlasPixel(history_local_pix, lane);
	if (!bouncePathAtlasPixelInBounds(pix)) {
		return surface;
	}

	const vec4 stage = imageLoad(prev_temporal_bounce_path_throughput, pix);
	surface.stage_throughput = max(stage.rgb, vec3(0.0));
	surface.emissive = max(imageLoad(prev_temporal_bounce_path_emissive, pix).rgb, vec3(0.0));
	const vec4 pos_t = imageLoad(prev_temporal_bounce_path_hit_pos, pix);
	surface.hit = pos_t.w > 0.0;
	if (!surface.hit) {
		return surface;
	}

	const vec4 packed_normal = imageLoad(prev_temporal_bounce_path_normals_gs, pix);
	surface.geometry_N = normalDecode(packed_normal.xy);
	surface.shading_N = normalDecode(packed_normal.zw);
	surface.transport_N = bouncePathTransportNormal(surface.geometry_N, surface.shading_N);
	surface.P = pos_t.xyz + surface.geometry_N * BOUNCE_PATH_LIGHTING_NORMAL_OFFSET;
	const vec3 stored_view = imageLoad(prev_temporal_bounce_path_view_dir, pix).xyz;
	surface.V = dot(stored_view, stored_view) > 1e-6 ? normalize(stored_view) : surface.transport_N;
	surface.material.base_color = SRGBtoLINEAR(imageLoad(prev_temporal_bounce_path_base_color_a, pix).rgb);
	surface.material.metalness = 0.0;
	surface.material.roughness = 1.0;
	surface.contributes = any(greaterThan(surface.stage_throughput, vec3(1e-6)));
	return surface;
}

#endif // BOUNCE_PATH_COORDS_ONLY

#endif // BOUNCE_PATH_COMMON_GLSL_INCLUDED
