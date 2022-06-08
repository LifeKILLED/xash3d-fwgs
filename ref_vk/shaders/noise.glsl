#ifndef NOISE_GLSL_INCLUDED
#define NOISE_GLSL_INCLUDED
// Copypasted from Mark Jarzynski and Marc Olano, Hash Functions for GPU Rendering, Journal of Computer Graphics Techniques (JCGT), vol. 9, no. 3, 21-38, 2020
// http://www.jcgt.org/published/0009/03/02/
// https://www.shadertoy.com/view/XlGcRh

// xxhash (https://github.com/Cyan4973/xxHash)
//   From https://www.shadertoy.com/view/Xt3cDn
uint xxhash32(uint p)
{
	const uint PRIME32_2 = 2246822519U, PRIME32_3 = 3266489917U;
	const uint PRIME32_4 = 668265263U, PRIME32_5 = 374761393U;
	uint h32 = p + PRIME32_5;
	h32 = PRIME32_4*((h32 << 17) | (h32 >> (32 - 17)));
    h32 = PRIME32_2*(h32^(h32 >> 15));
    h32 = PRIME32_3*(h32^(h32 >> 13));
    return h32^(h32 >> 16);
}

uint xxhash32(uvec2 p)
{
    const uint PRIME32_2 = 2246822519U, PRIME32_3 = 3266489917U;
	const uint PRIME32_4 = 668265263U, PRIME32_5 = 374761393U;
    uint h32 = p.y + PRIME32_5 + p.x*PRIME32_3;
    h32 = PRIME32_4*((h32 << 17) | (h32 >> (32 - 17)));
    h32 = PRIME32_2*(h32^(h32 >> 15));
    h32 = PRIME32_3*(h32^(h32 >> 13));
    return h32^(h32 >> 16);
}

uint xxhash32(uvec3 p)
{
    const uint PRIME32_2 = 2246822519U, PRIME32_3 = 3266489917U;
	const uint PRIME32_4 = 668265263U, PRIME32_5 = 374761393U;
	uint h32 =  p.z + PRIME32_5 + p.x*PRIME32_3;
	h32 = PRIME32_4*((h32 << 17) | (h32 >> (32 - 17)));
	h32 += p.y * PRIME32_3;
	h32 = PRIME32_4*((h32 << 17) | (h32 >> (32 - 17)));
    h32 = PRIME32_2*(h32^(h32 >> 15));
    h32 = PRIME32_3*(h32^(h32 >> 13));
    return h32^(h32 >> 16);
}

uint xxhash32(uvec4 p)
{
    const uint PRIME32_2 = 2246822519U, PRIME32_3 = 3266489917U;
	const uint PRIME32_4 = 668265263U, PRIME32_5 = 374761393U;
	uint h32 =  p.w + PRIME32_5 + p.x*PRIME32_3;
	h32 = PRIME32_4*((h32 << 17) | (h32 >> (32 - 17)));
	h32 += p.y * PRIME32_3;
	h32 = PRIME32_4*((h32 << 17) | (h32 >> (32 - 17)));
	h32 += p.z * PRIME32_3;
	h32 = PRIME32_4*((h32 << 17) | (h32 >> (32 - 17)));
    h32 = PRIME32_2*(h32^(h32 >> 15));
    h32 = PRIME32_3*(h32^(h32 >> 13));
    return h32^(h32 >> 16);
}

// https://www.pcg-random.org/
uint pcg(uint v)
{
	uint state = v * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return (word >> 22u) ^ word;
}

uvec2 pcg2d(uvec2 v)
{
    v = v * 1664525u + 1013904223u;

    v.x += v.y * 1664525u;
    v.y += v.x * 1664525u;

    v = v ^ (v>>16u);

    v.x += v.y * 1664525u;
    v.y += v.x * 1664525u;

    v = v ^ (v>>16u);

    return v;
}

// http://www.jcgt.org/published/0009/03/02/
uvec3 pcg3d(uvec3 v) {

    v = v * 1664525u + 1013904223u;

    v.x += v.y*v.z;
    v.y += v.z*v.x;
    v.z += v.x*v.y;

    v ^= v >> 16u;

    v.x += v.y*v.z;
    v.y += v.z*v.x;
    v.z += v.x*v.y;

    return v;
}

// http://www.jcgt.org/published/0009/03/02/
uvec3 pcg3d16(uvec3 v)
{
    v = v * 12829u + 47989u;

    v.x += v.y*v.z;
    v.y += v.z*v.x;
    v.z += v.x*v.y;

    v.x += v.y*v.z;
    v.y += v.z*v.x;
    v.z += v.x*v.y;

	v >>= 16u;

    return v;
}

// http://www.jcgt.org/published/0009/03/02/
uvec4 pcg4d(uvec4 v)
{
    v = v * 1664525u + 1013904223u;

    v.x += v.y*v.w;
    v.y += v.z*v.x;
    v.z += v.x*v.y;
    v.w += v.y*v.z;

    v ^= v >> 16u;

    v.x += v.y*v.w;
    v.y += v.z*v.x;
    v.z += v.x*v.y;
    v.w += v.y*v.z;

    return v;
}

uint rand01_state = 0;
uint rand() {
	return rand01_state = xxhash32(rand01_state);
}
uint rand_range(uint rmax) {
	return rand() % rmax;
}

float uintToFloat01(uint x) {
	return uintBitsToFloat(0x3f800000 | (x & 0x007fffff)) - 1.;
}

float rand01() {
	return uintToFloat01(rand());
}

vec3 rand3_f01(uvec3 seed) {
    uvec3 v = pcg3d(seed);
    return vec3(uintToFloat01(v.x), uintToFloat01(v.y), uintToFloat01(v.z));
}

// uniformity spaced points on sphere, not normalized
// distance between points nearly to 0.1 (use this for dither)
const vec3 points_on_sphere16x[16] = {
vec3(.2, .1, .99),
vec3(.05, .2, -.99),
vec3(-.7, -.78, -.15),
vec3(.64, .76, .45),
vec3(.24, -.99, -.25),
vec3(-.22, .65, .8),
vec3(.84, -.23, -.62),
vec3(-.89, -.05, -.6),
vec3(.83, -.52, .47),
vec3(-.9, -.18, .62),
vec3(-.08, .99, -.05),
vec3(-.26, -.71, -.73),
vec3(.99, .29, .12),
vec3(-.79, .77, -.14),
vec3(-.15, -.71, .79),
vec3(.71, .6, -.5)
};

const vec2 points_in_circle16x[16] = {
vec2(-.1, .88),
vec2(-.07, -.34),
vec2(.51, .37),
vec2(-.4, -.16),
vec2(.74, -.35),
vec2(-.085, .2),
vec2(-.7, -.22),
vec2(.34, -.27),
vec2(-.85, .13),
vec2(.57, .01),
vec2(-.54, -.63),
vec2(.14, .62),
vec2(.42, -.73),
vec2(-.52, .33),
vec2(.06, .08),
vec2(.45, .77)
};


vec3 patternDirection(ivec2 pix) {
	int id = pix.x % 4 + (pix.y % 4) * 4;
	return normalize(points_on_sphere16x[id]);
}

vec3 controlledRandomDirection(ivec2 pix, vec3 rndVec) {
	int id = pix.x % 4 + (pix.y % 4) * 4;
	float dither_scale = 0.1;
	return normalize(points_on_sphere16x[id] + rndVec * dither_scale);
}

#endif // NOISE_GLSL_INCLUDED
