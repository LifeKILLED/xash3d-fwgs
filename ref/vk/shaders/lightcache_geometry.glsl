#ifndef LIGHTCACHE_GEOMETRY_GLSL
#define LIGHTCACHE_GEOMETRY_GLSL
struct LightcacheProbe {
    vec3 position; uint brush;
    vec3 normal; uint island;
    uint first; uint width; uint height; uint local_index;
    uint lm_s; uint lm_t; uint lm_width; uint lm_height;
};
#ifndef LIGHTCACHE_GEOMETRY_BINDING
#define LIGHTCACHE_GEOMETRY_BINDING 60
#endif
layout(set = 0, binding = LIGHTCACHE_GEOMETRY_BINDING, std430) readonly buffer LightcacheGeometry {
    uvec4 info;
    uint lookup[1024 * 1024];
    mat4 transforms[512];
    LightcacheProbe probes[];
} lightcache_geometry;

bool lightcacheEnabled() {
    return ubo.ubo.debug_display_only == DEBUG_DISPLAY_DIRECT_DIFFUSE_CACHE ||
        (ubo.ubo.renderer_flags & RENDERER_FLAG_LIGHTCACHE_GI) != 0u;
}

bool lightcacheUpdateDisabled() {
    return (ubo.ubo.renderer_flags & RENDERER_FLAG_DISABLE_LIGHTCACHE_UPDATE) != 0u;
}

ivec2 lightcachePixel(uint index, ivec2 res) {
    return ivec2(index % uint(res.x), index / uint(res.x));
}
bool lightcacheInCapacity(uint index, ivec2 res) {
    return index < lightcache_geometry.info.x && index < uint(res.x) * uint(res.y);
}
uint lightcacheLookup(vec2 uv) {
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThanEqual(uv, vec2(1.0)))) return 0u;
    ivec2 p = ivec2(uv * 1024.0);
    return lightcache_geometry.lookup[p.y * 1024 + p.x];
}
void lightcacheSurface(uint index, out vec3 P, out vec3 N) {
    LightcacheProbe p = lightcache_geometry.probes[index];
    mat4 transform = lightcache_geometry.transforms[p.brush];
    N = normalize(mat3(transform) * p.normal);
    P = (transform * vec4(p.position, 1.0)).xyz + N * 0.01;
}
bool lightcacheNeighbor(uint index, ivec2 offset, out uint neighbor) {
    LightcacheProbe p = lightcache_geometry.probes[index];
    ivec2 xy = ivec2(p.local_index % p.width, p.local_index / p.width) + offset;
    neighbor = index;
    if (any(lessThan(xy, ivec2(0))) || any(greaterThanEqual(xy, ivec2(p.width, p.height)))) return false;
    neighbor = p.first + uint(xy.y) * p.width + uint(xy.x);
    return true;
}

// The final probe of an odd-sized island lies at the last source texel,
// rather than two texels after its predecessor. Match the CPU probe positions.
float lightcacheProbeCoordinate(float source, uint source_size, uint probe_size) {
    if (probe_size == 1u) return 0.0;
    float penultimate = 2.0 * float(probe_size - 2u) + 0.5;
    float last = min(2.0 * float(probe_size - 1u) + 0.5, float(source_size - 1u));
    if (source > penultimate)
        return float(probe_size - 2u) + (source - penultimate) / (last - penultimate);
    return (source - 0.5) * 0.5;
}

// Four taps always belong to this island. Clamping the base pair, but not
// its interpolation factor, extrapolates the boundary coefficients instead
// of reading padding or a neighboring island. A singleton axis is constant.
bool lightcacheBilinearFootprint(uint index, vec2 uv, ivec2 res,
                               out ivec2 taps[4], out vec4 weights) {
    LightcacheProbe p = lightcache_geometry.probes[index];
    vec2 source = uv * 1024.0 - vec2(0.5) - vec2(p.lm_s, p.lm_t);
    vec2 coordinate = vec2(lightcacheProbeCoordinate(source.x, p.lm_width, p.width),
                           lightcacheProbeCoordinate(source.y, p.lm_height, p.height));
    ivec2 extent = ivec2(p.width, p.height);
    ivec2 lo = clamp(ivec2(floor(coordinate)), ivec2(0), max(extent - 2, ivec2(0)));
    ivec2 hi = min(lo + 1, extent - 1);
    vec2 f = coordinate - vec2(lo);
    if (p.width == 1u) f.x = 0.0;
    if (p.height == 1u) f.y = 0.0;
    weights = vec4((1.0-f.x)*(1.0-f.y), f.x*(1.0-f.y), (1.0-f.x)*f.y, f.x*f.y);
    uint indices[4] = uint[4](p.first + uint(lo.y) * p.width + uint(lo.x),
                              p.first + uint(lo.y) * p.width + uint(hi.x),
                              p.first + uint(hi.y) * p.width + uint(lo.x),
                              p.first + uint(hi.y) * p.width + uint(hi.x));
    for (int i = 0; i < 4; ++i) {
        if (!lightcacheInCapacity(indices[i], res)) return false;
        taps[i] = lightcachePixel(indices[i], res);
    }
    return true;
}
#endif
