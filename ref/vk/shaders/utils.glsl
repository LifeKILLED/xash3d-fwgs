#ifndef UTILS_GLSL_INCLUDED
#define UTILS_GLSL_INCLUDED

// Compared to builtin GLSL sign() will be 1.0 if v == 0.
float signP(float v) { return v >= 0.f ? 1.f : -1.f; }
vec2 signP(vec2 v) { return vec2(signP(v.x), signP(v.y)); }

// https://knarkowicz.wordpress.com/2014/04/16/octahedron-normal-vector-encoding/
// https://www.shadertoy.com/view/Mtfyzl
vec2 OctWrap( vec2 v )
{
    return ( 1.0 - abs( v.yx ) ) * signP(v.xy);
}

vec2 normalEncode( vec3 n )
{
    n /= ( abs( n.x ) + abs( n.y ) + abs( n.z ) );
    n.xy = n.z >= 0.0 ? n.xy : OctWrap( n.xy );
    n.xy = n.xy * 0.5 + 0.5;
    return n.xy;
}

vec3 normalDecode( vec2 f )
{
    f = f * 2.0 - 1.0;

    // https://twitter.com/Stubbesaurus/status/937994790553227264
    vec3 n = vec3( f, 1.0 - abs( f.x ) - abs( f.y ) );
    const float t = max( -n.z, 0.f );
    n.xy -= t * signP(n.xy);
    return normalize( n );
}

vec2 baryMix(vec2 v1, vec2 v2, vec2 v3, vec2 bary) {
	return v1 * (1. - bary.x - bary.y) + v2 * bary.x + v3 * bary.y;
}

vec3 baryMix(vec3 v1, vec3 v2, vec3 v3, vec2 bary) {
	return v1 * (1. - bary.x - bary.y) + v2 * bary.x + v3 * bary.y;
}

vec4 baryMix(vec4 v1, vec4 v2, vec4 v3, vec2 bary) {
	return v1 * (1. - bary.x - bary.y) + v2 * bary.x + v3 * bary.y;
}

vec3 mixFinalColor(vec3 base_color, vec3 diffuse, vec3 specular, float metalness) {
		// Late base_color compositing with diffuse lighting
		// see brdf.glsl
		const vec3 diffuse_color = mix(base_color, vec3(0.), metalness);
		// Specular color is already computed-in as it is both view and light-source-direction dependent
		return diffuse * diffuse_color + specular;
}

// Shared position-based edge stop against center geometry plane.
// One unified scale is applied to both plane distance and texel distance.
#ifndef DENOISER_POSITION_GATE_SCALE
#define DENOISER_POSITION_GATE_SCALE (1.0 / 70.0)
#endif

float positionEdgeStopWithThresholds(vec3 delta_pos, vec3 geom_norm, float inv_center_dist, float plane_threshold, float dist2_threshold) {
	float gate_scale = clamp(DENOISER_POSITION_GATE_SCALE, 1e-4, 1.0);
	float plane_t = plane_threshold * gate_scale;
	float dist2_t = dist2_threshold * gate_scale * gate_scale;
	float n_plane_dist = abs(dot(delta_pos, geom_norm)) * inv_center_dist;
	float n_dist2 = dot(delta_pos, delta_pos) * (inv_center_dist * inv_center_dist);
	float w_plane = step(n_plane_dist, plane_t);
	float w_dist = step(n_dist2, dist2_t);
	return max(w_plane, w_dist);
}

#endif // UTILS_GLSL_INCLUDED
