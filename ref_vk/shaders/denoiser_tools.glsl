#ifndef DENOISER_TOOLS_LK_12231312
#define DENOISER_TOOLS_LK_12231312 1


// denoising of global illumination on mirrors now works bad
//#define DONT_DENOISE_SPECULAR_GI

// Choose just single option to increacing perfomance:

// Balance perfomance and visual
//#define LIGHTS_QUARTER_REDUCION

// More perfomance, but not so beautiful
//#define LIGHTS_NINEFOLD_REDUCION

#define IMPORTANCE_SAMPLING_4X_SIMPLE 1

#define IMPORTANCE_SAMPLING_4X_SETUP(total_lights_count, random_light_id) \
	vec4 light0 = vec4(0.), light1 = vec4(0.), light2 = vec4(0.), light3 = vec4(0.), light_rnd = vec4(0.); \
	vec3 light0_pos = vec3(0.), light1_pos = vec3(0.), light2_pos = vec3(0.), light3_pos = vec3(0.); \
	const uint rnd_samples_count = total_lights_count; \
	const uint rnd_light_index = random_light_id;

#define IMPORTANCE_SAMPLING_4X_SORT(current_light_radiance, curr_pos) \
	vec4 curr_l = vec4(current_light_radiance, current_light_radiance.r + current_light_radiance.g + current_light_radiance.b); \
	if (curr_l.w > light0.w) { \
		light3 = light2; \
		light2 = light1; \
		light1 = light0; \
		light0 = curr_l; \
		light3_pos = light2_pos; \
		light2_pos = light1_pos; \
		light1_pos = light0_pos; \
		light0_pos = curr_pos; \
	} else if (curr_l.w > light1.w) { \
		light3 = light2; \
		light2 = light1; \
		light1 = curr_l; \
		light3_pos = light2_pos; \
		light2_pos = light1_pos; \
		light1_pos = curr_pos; \
	} else if (curr_l.w > light2.w) { \
		light3 = light2; \
		light2 = curr_l; \
		light3_pos = light2_pos; \
		light2_pos = curr_pos; \
	} else if (curr_l.w > light3.w) { \
		light3 = curr_l; \
		light3_pos = curr_pos; \
	} 

#define IMPORTANCE_SAMPLING_4X_ADD_RND_SAMPLE(current_light_radiance) \
	light_rnd = vec4(current_light_radiance, dot(current_light_radiance, vec3(1.)));

#define IMPORTANCE_SAMPLING_4X_LIGHT_POS_0 light0_pos
#define IMPORTANCE_SAMPLING_4X_LIGHT_POS_1 light1_pos
#define IMPORTANCE_SAMPLING_4X_LIGHT_POS_2 light2_pos
#define IMPORTANCE_SAMPLING_4X_LIGHT_POS_3 light3_pos

#define IMPORTANCE_SAMPLING_4X_LIGHT_VAL_0 light0
#define IMPORTANCE_SAMPLING_4X_LIGHT_VAL_1 light1
#define IMPORTANCE_SAMPLING_4X_LIGHT_VAL_2 light2
#define IMPORTANCE_SAMPLING_4X_LIGHT_VAL_3 light3
#define IMPORTANCE_SAMPLING_4X_LIGHT_VAL_RND light_rnd

#define IMPORTANCE_SAMPLING_4X_FINALIZE(final_radiance, shadow_0, shadow_1, shadow_2, shadow_3) \
	final_radiance += light0.rgb * shadow_0 + light1.rgb * shadow_1 + light2.rgb * shadow_2 + light3.rgb * shadow_3; \
	if (light_rnd.w != light0.w && light_rnd.w != light1.w && light_rnd.w != light2.w && light_rnd.w != light3.w ) { \
		final_radiance += light_rnd.rgb * float(rnd_samples_count); \
	}

// clamp light exposition without loosing of color
vec3 clamp_color(vec3 color, float clamp_value) {
	float max_color = max(max(color.r, color.g), color.b);
	return max_color > clamp_value ? (color / max_color) * clamp_value : color;
}

vec3 OriginWorldPosition(mat4 inv_view) {
	return (inv_view * vec4(0, 0, 0, 1)).xyz;
}

vec3 ScreenToWorldDirection(vec2 uv, mat4 inv_view, mat4 inv_proj) {
	vec4 target    = inv_proj * vec4(uv.x, uv.y, 1, 1);
	vec3 direction = (inv_view * vec4(normalize(target.xyz), 0)).xyz;
	return normalize(direction);
}

vec3 WorldPositionFromDirection(vec3 origin, vec3 direction, float depth) {
	return origin + normalize(direction) * depth;
}

vec3 FarPlaneDirectedVector(vec2 uv, vec3 forward, mat4 inv_view, mat4 inv_proj) {
	vec3 dir = ScreenToWorldDirection(uv, inv_view, inv_proj);
	float plane_length = dot(forward, dir);
	return dir / max(0.001, plane_length);
}

vec2 WorldPositionToUV(vec3 position, mat4 proj, mat4 view) {
	vec4 clip_space = proj * vec4((view * vec4(position, 1.)).xyz, 1.);
	return clip_space.xy / clip_space.w;
}

vec3 WorldPositionToUV2(vec3 position, mat4 inv_proj, mat4 inv_view) {
	const vec3 out_of_bounds = vec3(0.,0.,-1.);
	const float near_plane_treshold = 1.;
	vec3 origin = OriginWorldPosition(inv_view);
	vec3 forwardDirection = normalize(ScreenToWorldDirection(vec2(0.), inv_view, inv_proj));
	float depth = dot(forwardDirection, position - origin);
	if (depth < near_plane_treshold) return out_of_bounds;
	vec3 positionNearPlane = (position - origin) / depth;
	vec3 rightForwardDirection = ScreenToWorldDirection(vec2(1., 0.), inv_view, inv_proj);
	vec3 upForwardDirection = ScreenToWorldDirection(vec2(0., 1.), inv_view, inv_proj);
	rightForwardDirection /= dot(forwardDirection, rightForwardDirection);
	upForwardDirection /= dot(forwardDirection, upForwardDirection);
	vec3 rightDirection = rightForwardDirection - forwardDirection;
	vec3 upDirection = upForwardDirection - forwardDirection;
	float x = dot(normalize(rightDirection), positionNearPlane - forwardDirection) / length(rightDirection);
	float y = dot(normalize(upDirection), positionNearPlane - forwardDirection) / length(upDirection);
	if (x < -1. || y < -1. || x > 1. || y > 1.) return out_of_bounds;
	return vec3(x, y, 1.);
}

float normpdf2(in float x2, in float sigma) { return 0.39894*exp(-0.5*x2/(sigma*sigma))/sigma; }
float normpdf(in float x, in float sigma) { return normpdf2(x*x, sigma); }

ivec2 UVToPix(vec2 uv, ivec2 res) {
	vec2 screen_uv = uv * 0.5 + vec2(0.5);
	return ivec2(screen_uv.x * float(res.x), screen_uv.y * float(res.y));
}

vec3 PBRMix(vec3 base_color, vec3 diffuse, vec3 specular, float metalness) {
	vec3 metal_colour = specular * base_color;
	vec3 dielectric_colour = mix(diffuse * base_color, specular, 0.2);
	return mix(dielectric_colour, metal_colour, metalness);
}

int per_frame_offset = 0;

int quarterPart(ivec2 pix_in) {
	ivec2 pix = pix_in % 2;
	return (pix.x + 2 * pix.y + per_frame_offset) % 4;
}

int ninefoldPart(ivec2 pix_in) {
	ivec2 pix = pix_in % 3;
	return (pix.x + 3 * pix.y + per_frame_offset) % 9;
}

int texel_transparent_type(float transparent_alpha) {
	return abs(transparent_alpha) < 0.05 ? 0 : transparent_alpha > 0. ? 2 : 3;
}

int checker_texel(ivec2 pix) {
	return (pix.x + pix.y) % 2;
}

ivec2 closest_checker_texel(ivec2 pix, int source_checker_texel) {
	return checker_texel(pix) == source_checker_texel ? pix : pix + ivec2(1, 0);
}

const float max_16bit_value = 65536.;

const float pack_multiplier = 0.98;

float Pack2Floats(vec2 v)
{
	return floor(clamp(v.x, 0., 1.) * pack_multiplier * max_16bit_value) + clamp(v.y, 0., 1.) * pack_multiplier; // stores A as integer, B as fractional
}

vec2 Unpack2Floats(float c)
{
	float a = floor(c) / max_16bit_value; // removes the fractional value and scales back to 0-1
	float b = fract(c); // removes the integer value, leaving B (0-1)
	return vec2(a, b) / pack_multiplier;
}

//float Pack2Floats(vec2 v)
//{
//	uint aScaled = uint(v.x * 0xFFFF);
//	uint bScaled = uint(v.y * 0xFFFF);
//	uint abPacked = (aScaled << 16) | (bScaled & 0xFFFF);
//	return float(abPacked);
//}
//
//vec2 Unpack2Floats(float inputFloat)
//{
//	uint uintInput = uint(inputFloat);
//	float aUnpacked = float(uintInput >> 16) / 65535.0f;
//	float bUnpacked = float(uintInput & 0xFFFF) / 65535.0f;
//	return vec2(aUnpacked, bUnpacked);
//}

vec4 PackMaterialValues(vec3 base_color, float roughness, float metalness, float alpha, float depth) {
	float valueX = Pack2Floats(base_color.rg);
	float valueY = Pack2Floats(vec2(base_color.b, alpha));
	float valueZ = Pack2Floats(vec2(roughness, metalness));
	float valueW = depth;
	return vec4(valueX, valueY, valueZ, valueW);
}

void UnpackMaterialValues(in vec4 packed, out vec3 base_color, out float roughness, out float metalness, out float alpha, out float depth) {
	vec2 valueX = Unpack2Floats(packed.x);
	vec2 valueY = Unpack2Floats(packed.y);
	vec2 valueZ = Unpack2Floats(packed.z);
	//vec2 valueW = Unpack2Floats(packed.w);
	base_color = vec3(valueX.xy, valueY.x);
	alpha = valueY.y;
	roughness = valueZ.x;
	metalness = valueZ.y;
	depth = packed.w;
}

vec4 PackIndirectLighting(vec3 irradiance, vec3 direction, float depth) {
	vec3 direction01 = direction * 0.5 + 0.5;
	float valueX = Pack2Floats(irradiance.rg);
	float valueY = Pack2Floats(vec2(irradiance.b, direction01.x));
	float valueZ = Pack2Floats(vec2(direction01.yz));
	float valueW = depth;
	return vec4(valueX, valueY, valueZ, valueW);
}

void UnpackIndirectLighting(in vec4 packed, out vec3 irradiance, out vec3 direction, out float depth) {
	vec2 valueX = Unpack2Floats(packed.x);
	vec2 valueY = Unpack2Floats(packed.y);
	vec2 valueZ = Unpack2Floats(packed.z);
	//vec2 valueW = Unpack2Floats(packed.w);
	irradiance = vec3(valueX.xy, valueY.x);
	direction = vec3(valueY.y, valueZ.xy) * 2. - 1.;
	depth = packed.w;
}


vec4 PackNormals(vec3 shadingNormals, vec3 geometryNormals) {
	vec3 shadingNormals01 = shadingNormals * 0.5 + 0.5;
	vec3 geometryNormals01 = geometryNormals * 0.5 + 0.5;
	float valueX = Pack2Floats(shadingNormals01.rg);
	float valueY = Pack2Floats(vec2(shadingNormals01.b, geometryNormals01.x));
	float valueZ = Pack2Floats(vec2(geometryNormals01.yz));
	float valueW = 0.;
	return vec4(valueX, valueY, valueZ, valueW);
}

void UnpackNormals(in vec4 packed, out vec3 shadingNormals, out vec3 geometryNormals) {
	vec2 valueX = Unpack2Floats(packed.x);
	vec2 valueY = Unpack2Floats(packed.y);
	vec2 valueZ = Unpack2Floats(packed.z);
	//vec2 valueW = Unpack2Floats(packed.w);
	shadingNormals = vec3(valueX.xy, valueY.x) * 2. - 1.;
	geometryNormals = vec3(valueY.y, valueZ.xy) * 2. - 1.;
}

// circle pattern of integer offsets without center texel
const ivec2 circle_7x7[36] = {
ivec2(-1, -3), ivec2(0, -3), ivec2(1, -3),
ivec2(-2, -2), ivec2(-1, -2), ivec2(0, -2), ivec2(1, -2), ivec2(2, -2),
ivec2(-3, -1), ivec2(-2, -1), ivec2(-1, -1), ivec2(0, -1), ivec2(1, -1), ivec2(2, -1), ivec2(3, -1),
ivec2(-3, 0), ivec2(-2, 0), ivec2(-1, 0), ivec2(1, 0), ivec2(2, 0), ivec2(3, 0),
ivec2(-3, 1), ivec2(-2, 1), ivec2(-1, 1), ivec2(0, 1), ivec2(1, 1), ivec2(2, 1), ivec2(3, 1),
ivec2(-2, 2), ivec2(-1, 2), ivec2(0, 2), ivec2(1, 2), ivec2(2, 2),
ivec2(-1, 3), ivec2(0, 3), ivec2(1, 3)
};


const vec3 directions6x[6] = {
vec3(0., 0., 1.),
vec3(0., 0., -1.),
vec3(-1., 0., 0.),
vec3(1., 0., 0.),
vec3(0., -1., 0.),
vec3(0., 1., 0.)
};

const vec2 uv_samples[5] = {
vec2(0., 0.),
vec2(1., 0.),
vec2(0., 1.),
vec2(1., 1.),
vec2(.5, .5)
};

//#define USE_KERNEL_8_FULL_WEIGHTS 1
#ifdef USE_KERNEL_8_FULL_WEIGHTS
const float blur_kernel8_full_weights[289] = {
0.0002, 0.0003, 0.0004, 0.0006, 0.0008, 0.0010, 0.0012, 0.0013, 0.0013, 0.0013, 0.0012, 0.0010, 0.0008, 0.0006,
0.0004, 0.0003, 0.0002, 0.0003, 0.0005, 0.0007, 0.0010, 0.0013, 0.0016, 0.0019, 0.0021, 0.0022, 0.0021, 0.0019,
0.0016, 0.0013, 0.0010, 0.0007, 0.0005, 0.0003, 0.0004, 0.0007, 0.0010, 0.0015, 0.0020, 0.0024, 0.0028, 0.0031,
0.0032, 0.0031, 0.0028, 0.0024, 0.0020, 0.0015, 0.0010, 0.0007, 0.0004, 0.0006, 0.0010, 0.0015, 0.0021, 0.0028,
0.0034, 0.0040, 0.0044, 0.0046, 0.0044, 0.0040, 0.0034, 0.0028, 0.0021, 0.0015, 0.0010, 0.0006, 0.0008, 0.0013,
0.0020, 0.0028, 0.0037, 0.0046, 0.0053, 0.0058, 0.0060, 0.0058, 0.0053, 0.0046, 0.0037, 0.0028, 0.0020, 0.0013,
0.0008, 0.0010, 0.0016, 0.0024, 0.0034, 0.0046, 0.0057, 0.0066, 0.0073, 0.0075, 0.0073, 0.0066, 0.0057, 0.0046,
0.0034, 0.0024, 0.0016, 0.0010, 0.0012, 0.0019, 0.0028, 0.0040, 0.0053, 0.0066, 0.0077, 0.0085, 0.0088, 0.0085,
0.0077, 0.0066, 0.0053, 0.0040, 0.0028, 0.0019, 0.0012, 0.0013, 0.0021, 0.0031, 0.0044, 0.0058, 0.0073, 0.0085,
0.0093, 0.0096, 0.0093, 0.0085, 0.0073, 0.0058, 0.0044, 0.0031, 0.0021, 0.0013, 0.0013, 0.0022, 0.0032, 0.0046,
0.0060, 0.0075, 0.0088, 0.0096, 0.0099, 0.0096, 0.0088, 0.0075, 0.0060, 0.0046, 0.0032, 0.0022, 0.0013, 0.0013,
0.0021, 0.0031, 0.0044, 0.0058, 0.0073, 0.0085, 0.0093, 0.0096, 0.0093, 0.0085, 0.0073, 0.0058, 0.0044, 0.0031,
0.0021, 0.0013, 0.0012, 0.0019, 0.0028, 0.0040, 0.0053, 0.0066, 0.0077, 0.0085, 0.0088, 0.0085, 0.0077, 0.0066,
0.0053, 0.0040, 0.0028, 0.0019, 0.0012, 0.0010, 0.0016, 0.0024, 0.0034, 0.0046, 0.0057, 0.0066, 0.0073, 0.0075,
0.0073, 0.0066, 0.0057, 0.0046, 0.0034, 0.0024, 0.0016, 0.0010, 0.0008, 0.0013, 0.0020, 0.0028, 0.0037, 0.0046,
0.0053, 0.0058, 0.0060, 0.0058, 0.0053, 0.0046, 0.0037, 0.0028, 0.0020, 0.0013, 0.0008, 0.0006, 0.0010, 0.0015,
0.0021, 0.0028, 0.0034, 0.0040, 0.0044, 0.0046, 0.0044, 0.0040, 0.0034, 0.0028, 0.0021, 0.0015, 0.0010, 0.0006,
0.0004, 0.0007, 0.0010, 0.0015, 0.0020, 0.0024, 0.0028, 0.0031, 0.0032, 0.0031, 0.0028, 0.0024, 0.0020, 0.0015,
0.0010, 0.0007, 0.0004, 0.0003, 0.0005, 0.0007, 0.0010, 0.0013, 0.0016, 0.0019, 0.0021, 0.0022, 0.0021, 0.0019,
0.0016, 0.0013, 0.0010, 0.0007, 0.0005, 0.0003, 0.0002, 0.0003, 0.0004, 0.0006, 0.0008, 0.0010, 0.0012, 0.0013,
0.0013, 0.0013, 0.0012, 0.0010, 0.0008, 0.0006, 0.0004, 0.0003, 0.0002
};
#endif

// optimized count of precomputed samples tresholded by low value
// without center (0, 0) because it'is always need to sample before

//#define USE_KERNEL_4_OPTIMIZED 1
#ifdef USE_KERNEL_4_OPTIMIZED
#define blur_kernel4_samples_count 48
const float blur_kernel4_center_weight = .0397;
const ivec2 blur_kernel4_offsets[48] = {
	ivec2( -4, 0), ivec2( -3, -2), ivec2( -3, -1), ivec2( -3, 0), ivec2( -3, 1), ivec2( -3, 2), ivec2( -2, -3),
	ivec2( -2, -2), ivec2( -2, -1), ivec2( -2, 0), ivec2( -2, 1), ivec2( -2, 2), ivec2( -2, 3), ivec2( -1, -3),
	ivec2( -1, -2), ivec2( -1, -1), ivec2( -1, 0), ivec2( -1, 1), ivec2( -1, 2), ivec2( -1, 3), ivec2( 0, -4),
	ivec2( 0, -3), ivec2( 0, -2), ivec2( 0, -1), ivec2( 0, 1), ivec2( 0, 2), ivec2( 0, 3), ivec2( 0, 4), ivec2( 1, -3),
	ivec2( 1, -2), ivec2( 1, -1), ivec2( 1, 0), ivec2( 1, 1), ivec2( 1, 2), ivec2( 1, 3), ivec2( 2, -3), ivec2( 2, -2),
	ivec2( 2, -1), ivec2( 2, 0), ivec2( 2, 1), ivec2( 2, 2), ivec2( 2, 3), ivec2( 3, -2), ivec2( 3, -1), ivec2( 3, 0),
	ivec2( 3, 1), ivec2( 3, 2), ivec2( 4, 0)
};

const float blur_kernel4_weights[48] = {
	0.0054, 0.0078, 0.0114, 0.0129, 0.0114, 0.0078, 0.0078, 0.0146, 0.0213, 0.0241, 0.0213, 0.0146, 0.0078, 0.0114,
	0.0213, 0.0310, 0.0351, 0.0310, 0.0213, 0.0114, 0.0054, 0.0129, 0.0241, 0.0351, 0.0351, 0.0241, 0.0129, 0.0054,
	0.0114, 0.0213, 0.0310, 0.0351, 0.0310, 0.0213, 0.0114, 0.0078, 0.0146, 0.0213, 0.0241, 0.0213, 0.0146, 0.0078,
	0.0078, 0.0114, 0.0129, 0.0114, 0.0078, 0.0054
};
#endif

//#define USE_KERNEL_8_OPTIMIZED 1
#ifdef USE_KERNEL_8_OPTIMIZED
#define blur_kernel8_samples_count 128
const float blur_kernel8_center_weight = .00994;
const ivec2 blur_kernel8_offsets[128] = {
	ivec2( -6, -2), ivec2( -6, -1), ivec2( -6, 0), ivec2( -6, 1), ivec2( -6, 2), ivec2( -5, -3), ivec2( -5, -2),
	ivec2( -5, -1), ivec2( -5, 0), ivec2( -5, 1), ivec2( -5, 2), ivec2( -5, 3), ivec2( -4, -4), ivec2( -4, -3),
	ivec2( -4, -2), ivec2( -4, -1), ivec2( -4, 0), ivec2( -4, 1), ivec2( -4, 2), ivec2( -4, 3), ivec2( -4, 4),
	ivec2( -3, -5), ivec2( -3, -4), ivec2( -3, -3), ivec2( -3, -2), ivec2( -3, -1), ivec2( -3, 0), ivec2( -3, 1),
	ivec2( -3, 2), ivec2( -3, 3), ivec2( -3, 4), ivec2( -3, 5), ivec2( -2, -6), ivec2( -2, -5), ivec2( -2, -4),
	ivec2( -2, -3), ivec2( -2, -2), ivec2( -2, -1), ivec2( -2, 0), ivec2( -2, 1), ivec2( -2, 2), ivec2( -2, 3),
	ivec2( -2, 4), ivec2( -2, 5), ivec2( -2, 6), ivec2( -1, -6), ivec2( -1, -5), ivec2( -1, -4), ivec2( -1, -3),
	ivec2( -1, -2), ivec2( -1, -1), ivec2( -1, 0), ivec2( -1, 1), ivec2( -1, 2), ivec2( -1, 3), ivec2( -1, 4),
	ivec2( -1, 5), ivec2( -1, 6), ivec2( 0, -6), ivec2( 0, -5), ivec2( 0, -4), ivec2( 0, -3), ivec2( 0, -2),
	ivec2( 0, -1), ivec2( 0, 1), ivec2( 0, 2), ivec2( 0, 3), ivec2( 0, 4), ivec2( 0, 5), ivec2( 0, 6), ivec2( 1, -6),
	ivec2( 1, -5), ivec2( 1, -4), ivec2( 1, -3), ivec2( 1, -2), ivec2( 1, -1), ivec2( 1, 0), ivec2( 1, 1), ivec2( 1, 2),
	ivec2( 1, 3), ivec2( 1, 4), ivec2( 1, 5), ivec2( 1, 6), ivec2( 2, -6), ivec2( 2, -5), ivec2( 2, -4), ivec2( 2, -3),
	ivec2( 2, -2), ivec2( 2, -1), ivec2( 2, 0), ivec2( 2, 1), ivec2( 2, 2), ivec2( 2, 3), ivec2( 2, 4), ivec2( 2, 5),
	ivec2( 2, 6), ivec2( 3, -5), ivec2( 3, -4), ivec2( 3, -3), ivec2( 3, -2), ivec2( 3, -1), ivec2( 3, 0), ivec2( 3, 1),
	ivec2( 3, 2), ivec2( 3, 3), ivec2( 3, 4), ivec2( 3, 5), ivec2( 4, -4), ivec2( 4, -3), ivec2( 4, -2), ivec2( 4, -1),
	ivec2( 4, 0), ivec2( 4, 1), ivec2( 4, 2), ivec2( 4, 3), ivec2( 4, 4), ivec2( 5, -3), ivec2( 5, -2), ivec2( 5, -1),
	ivec2( 5, 0), ivec2( 5, 1), ivec2( 5, 2), ivec2( 5, 3), ivec2( 6, -2), ivec2( 6, -1), ivec2( 6, 0), ivec2( 6, 1), ivec2( 6, 2)
};

const float blur_kernel8_weights[128] = {
	 0.0028, 0.0031, 0.0032, 0.0031, 0.0028, 0.0034, 0.0040, 0.0044, 0.0046, 0.0044, 0.0040, 0.0034, 0.0037, 0.0046,
	 0.0053, 0.0058, 0.0060, 0.0058, 0.0053, 0.0046, 0.0037, 0.0034, 0.0046, 0.0057, 0.0066, 0.0073, 0.0075, 0.0073,
	 0.0066, 0.0057, 0.0046, 0.0034, 0.0028, 0.0040, 0.0053, 0.0066, 0.0077, 0.0085, 0.0088, 0.0085, 0.0077, 0.0066,
	 0.0053, 0.0040, 0.0028, 0.0031, 0.0044, 0.0058, 0.0073, 0.0085, 0.0093, 0.0096, 0.0093, 0.0085, 0.0073, 0.0058,
	 0.0044, 0.0031, 0.0032, 0.0046, 0.0060, 0.0075, 0.0088, 0.0096, 0.0096, 0.0088, 0.0075, 0.0060, 0.0046, 0.0032,
	 0.0031, 0.0044, 0.0058, 0.0073, 0.0085, 0.0093, 0.0096, 0.0093, 0.0085, 0.0073, 0.0058, 0.0044, 0.0031, 0.0028,
	 0.0040, 0.0053, 0.0066, 0.0077, 0.0085, 0.0088, 0.0085, 0.0077, 0.0066, 0.0053, 0.0040, 0.0028, 0.0034, 0.0046,
	 0.0057, 0.0066, 0.0073, 0.0075, 0.0073, 0.0066, 0.0057, 0.0046, 0.0034, 0.0037, 0.0046, 0.0053, 0.0058, 0.0060,
	 0.0058, 0.0053, 0.0046, 0.0037, 0.0034, 0.0040, 0.0044, 0.0046, 0.0044, 0.0040, 0.0034, 0.0028, 0.0031, 0.0032,
	 0.0031, 0.0028
 };
 #endif

//#define USE_KERNEL_12_OPTIMIZED 1
#ifdef USE_KERNEL_12_OPTIMIZED
 #define blur_kernel12_samples_count 340
 const float blur_kernel12_center_weight = .00442;
 const ivec2 blur_kernel12_offsets[340] = {
	ivec2( -10, -2), ivec2( -10, -1), ivec2( -10, 0), ivec2( -10, 1), ivec2( -10, 2), ivec2( -9, -5), ivec2( -9, -4),
	ivec2( -9, -3), ivec2( -9, -2), ivec2( -9, -1), ivec2( -9, 0), ivec2( -9, 1), ivec2( -9, 2), ivec2( -9, 3),
	ivec2( -9, 4), ivec2( -9, 5), ivec2( -8, -6), ivec2( -8, -5), ivec2( -8, -4), ivec2( -8, -3), ivec2( -8, -2),
	ivec2( -8, -1), ivec2( -8, 0), ivec2( -8, 1), ivec2( -8, 2), ivec2( -8, 3), ivec2( -8, 4), ivec2( -8, 5),
	ivec2( -8, 6), ivec2( -7, -7), ivec2( -7, -6), ivec2( -7, -5), ivec2( -7, -4), ivec2( -7, -3), ivec2( -7, -2),
	ivec2( -7, -1), ivec2( -7, 0), ivec2( -7, 1), ivec2( -7, 2), ivec2( -7, 3), ivec2( -7, 4), ivec2( -7, 5),
	ivec2( -7, 6), ivec2( -7, 7), ivec2( -6, -8), ivec2( -6, -7), ivec2( -6, -6), ivec2( -6, -5), ivec2( -6, -4),
	ivec2( -6, -3), ivec2( -6, -2), ivec2( -6, -1), ivec2( -6, 0), ivec2( -6, 1), ivec2( -6, 2), ivec2( -6, 3),
	ivec2( -6, 4), ivec2( -6, 5), ivec2( -6, 6), ivec2( -6, 7), ivec2( -6, 8), ivec2( -5, -9), ivec2( -5, -8),
	ivec2( -5, -7), ivec2( -5, -6), ivec2( -5, -5), ivec2( -5, -4), ivec2( -5, -3), ivec2( -5, -2), ivec2( -5, -1),
	ivec2( -5, 0), ivec2( -5, 1), ivec2( -5, 2), ivec2( -5, 3), ivec2( -5, 4), ivec2( -5, 5), ivec2( -5, 6), ivec2( -5, 7),
	ivec2( -5, 8), ivec2( -5, 9), ivec2( -4, -9), ivec2( -4, -8), ivec2( -4, -7), ivec2( -4, -6), ivec2( -4, -5),
	ivec2( -4, -4), ivec2( -4, -3), ivec2( -4, -2), ivec2( -4, -1), ivec2( -4, 0), ivec2( -4, 1), ivec2( -4, 2),
	ivec2( -4, 3), ivec2( -4, 4), ivec2( -4, 5), ivec2( -4, 6), ivec2( -4, 7), ivec2( -4, 8), ivec2( -4, 9),
	ivec2( -3, -9), ivec2( -3, -8), ivec2( -3, -7), ivec2( -3, -6), ivec2( -3, -5), ivec2( -3, -4), ivec2( -3, -3),
	ivec2( -3, -2), ivec2( -3, -1), ivec2( -3, 0), ivec2( -3, 1), ivec2( -3, 2), ivec2( -3, 3), ivec2( -3, 4),
	ivec2( -3, 5), ivec2( -3, 6), ivec2( -3, 7), ivec2( -3, 8), ivec2( -3, 9), ivec2( -2, -10), ivec2( -2, -9),
	ivec2( -2, -8), ivec2( -2, -7), ivec2( -2, -6), ivec2( -2, -5), ivec2( -2, -4), ivec2( -2, -3), ivec2( -2, -2),
	ivec2( -2, -1), ivec2( -2, 0), ivec2( -2, 1), ivec2( -2, 2), ivec2( -2, 3), ivec2( -2, 4), ivec2( -2, 5),
	ivec2( -2, 6), ivec2( -2, 7), ivec2( -2, 8), ivec2( -2, 9), ivec2( -2, 10), ivec2( -1, -10), ivec2( -1, -9),
	ivec2( -1, -8), ivec2( -1, -7), ivec2( -1, -6), ivec2( -1, -5), ivec2( -1, -4), ivec2( -1, -3), ivec2( -1, -2),
	ivec2( -1, -1), ivec2( -1, 0), ivec2( -1, 1), ivec2( -1, 2), ivec2( -1, 3), ivec2( -1, 4), ivec2( -1, 5),
	ivec2( -1, 6), ivec2( -1, 7), ivec2( -1, 8), ivec2( -1, 9), ivec2( -1, 10), ivec2( 0, -10), ivec2( 0, -9),
	ivec2( 0, -8), ivec2( 0, -7), ivec2( 0, -6), ivec2( 0, -5), ivec2( 0, -4), ivec2( 0, -3), ivec2( 0, -2),
	ivec2( 0, -1), ivec2( 0, 1), ivec2( 0, 2), ivec2( 0, 3), ivec2( 0, 4), ivec2( 0, 5), ivec2( 0, 6), ivec2( 0, 7),
	ivec2( 0, 8), ivec2( 0, 9), ivec2( 0, 10), ivec2( 1, -10), ivec2( 1, -9), ivec2( 1, -8), ivec2( 1, -7),
	ivec2( 1, -6), ivec2( 1, -5), ivec2( 1, -4), ivec2( 1, -3), ivec2( 1, -2), ivec2( 1, -1), ivec2( 1, 0),
	ivec2( 1, 1), ivec2( 1, 2), ivec2( 1, 3), ivec2( 1, 4), ivec2( 1, 5), ivec2( 1, 6), ivec2( 1, 7), ivec2( 1, 8),
	ivec2( 1, 9), ivec2( 1, 10), ivec2( 2, -10), ivec2( 2, -9), ivec2( 2, -8), ivec2( 2, -7), ivec2( 2, -6),
	ivec2( 2, -5), ivec2( 2, -4), ivec2( 2, -3), ivec2( 2, -2), ivec2( 2, -1), ivec2( 2, 0), ivec2( 2, 1), ivec2( 2, 2),
	ivec2( 2, 3), ivec2( 2, 4), ivec2( 2, 5), ivec2( 2, 6), ivec2( 2, 7), ivec2( 2, 8), ivec2( 2, 9), ivec2( 2, 10),
	ivec2( 3, -9), ivec2( 3, -8), ivec2( 3, -7), ivec2( 3, -6), ivec2( 3, -5), ivec2( 3, -4), ivec2( 3, -3), ivec2( 3, -2),
	ivec2( 3, -1), ivec2( 3, 0), ivec2( 3, 1), ivec2( 3, 2), ivec2( 3, 3), ivec2( 3, 4), ivec2( 3, 5), ivec2( 3, 6),
	ivec2( 3, 7), ivec2( 3, 8), ivec2( 3, 9), ivec2( 4, -9), ivec2( 4, -8), ivec2( 4, -7), ivec2( 4, -6), ivec2( 4, -5),
	ivec2( 4, -4), ivec2( 4, -3), ivec2( 4, -2), ivec2( 4, -1), ivec2( 4, 0), ivec2( 4, 1), ivec2( 4, 2), ivec2( 4, 3),
	ivec2( 4, 4), ivec2( 4, 5), ivec2( 4, 6), ivec2( 4, 7), ivec2( 4, 8), ivec2( 4, 9), ivec2( 5, -9), ivec2( 5, -8),
	ivec2( 5, -7), ivec2( 5, -6), ivec2( 5, -5), ivec2( 5, -4), ivec2( 5, -3), ivec2( 5, -2), ivec2( 5, -1), ivec2( 5, 0),
	ivec2( 5, 1), ivec2( 5, 2), ivec2( 5, 3), ivec2( 5, 4), ivec2( 5, 5), ivec2( 5, 6), ivec2( 5, 7), ivec2( 5, 8),
	ivec2( 5, 9), ivec2( 6, -8), ivec2( 6, -7), ivec2( 6, -6), ivec2( 6, -5), ivec2( 6, -4), ivec2( 6, -3), ivec2( 6, -2),
	ivec2( 6, -1), ivec2( 6, 0), ivec2( 6, 1), ivec2( 6, 2), ivec2( 6, 3), ivec2( 6, 4), ivec2( 6, 5), ivec2( 6, 6),
	ivec2( 6, 7), ivec2( 6, 8), ivec2( 7, -7), ivec2( 7, -6), ivec2( 7, -5), ivec2( 7, -4), ivec2( 7, -3), ivec2( 7, -2),
	ivec2( 7, -1), ivec2( 7, 0), ivec2( 7, 1), ivec2( 7, 2), ivec2( 7, 3), ivec2( 7, 4), ivec2( 7, 5), ivec2( 7, 6),
	ivec2( 7, 7), ivec2( 8, -6), ivec2( 8, -5), ivec2( 8, -4), ivec2( 8, -3), ivec2( 8, -2), ivec2( 8, -1), ivec2( 8, 0),
	ivec2( 8, 1), ivec2( 8, 2), ivec2( 8, 3), ivec2( 8, 4), ivec2( 8, 5), ivec2( 8, 6), ivec2( 9, -5), ivec2( 9, -4),
	ivec2( 9, -3), ivec2( 9, -2), ivec2( 9, -1), ivec2( 9, 0), ivec2( 9, 1), ivec2( 9, 2), ivec2( 9, 3), ivec2( 9, 4),
	ivec2( 9, 5), ivec2( 10, -2), ivec2( 10, -1), ivec2( 10, 0), ivec2( 10, 1), ivec2( 10, 2)
};

const float blur_kernel12_weights[340] = {
	 0.0010, 0.0011, 0.0011, 0.0011, 0.0010, 0.0010, 0.0011, 0.0013, 0.0014, 0.0014, 0.0014, 0.0014, 0.0014, 0.0013,
	 0.0011, 0.0010, 0.0011, 0.0013, 0.0015, 0.0016, 0.0017, 0.0018, 0.0018, 0.0018, 0.0017, 0.0016, 0.0015, 0.0013,
	 0.0011, 0.0011, 0.0014, 0.0016, 0.0018, 0.0020, 0.0021, 0.0022, 0.0022, 0.0022, 0.0021, 0.0020, 0.0018, 0.0016,
	 0.0014, 0.0011, 0.0011, 0.0014, 0.0016, 0.0019, 0.0021, 0.0024, 0.0025, 0.0026, 0.0027, 0.0026, 0.0025, 0.0024,
	 0.0021, 0.0019, 0.0016, 0.0014, 0.0011, 0.0010, 0.0013, 0.0016, 0.0019, 0.0022, 0.0025, 0.0028, 0.0030, 0.0031,
	 0.0031, 0.0031, 0.0030, 0.0028, 0.0025, 0.0022, 0.0019, 0.0016, 0.0013, 0.0010, 0.0011, 0.0015, 0.0018, 0.0021,
	 0.0025, 0.0028, 0.0031, 0.0033, 0.0035, 0.0035, 0.0035, 0.0033, 0.0031, 0.0028, 0.0025, 0.0021, 0.0018, 0.0015,
	 0.0011, 0.0013, 0.0016, 0.0020, 0.0024, 0.0028, 0.0031, 0.0034, 0.0037, 0.0038, 0.0039, 0.0038, 0.0037, 0.0034,
	 0.0031, 0.0028, 0.0024, 0.0020, 0.0016, 0.0013, 0.0010, 0.0014, 0.0017, 0.0021, 0.0025, 0.0030, 0.0033, 0.0037,
	 0.0040, 0.0041, 0.0042, 0.0041, 0.0040, 0.0037, 0.0033, 0.0030, 0.0025, 0.0021, 0.0017, 0.0014, 0.0010, 0.0011,
	 0.0014, 0.0018, 0.0022, 0.0026, 0.0031, 0.0035, 0.0038, 0.0041, 0.0043, 0.0044, 0.0043, 0.0041, 0.0038, 0.0035,
	 0.0031, 0.0026, 0.0022, 0.0018, 0.0014, 0.0011, 0.0011, 0.0014, 0.0018, 0.0022, 0.0027, 0.0031, 0.0035, 0.0039,
	 0.0042, 0.0044, 0.0044, 0.0042, 0.0039, 0.0035, 0.0031, 0.0027, 0.0022, 0.0018, 0.0014, 0.0011, 0.0011, 0.0014,
	 0.0018, 0.0022, 0.0026, 0.0031, 0.0035, 0.0038, 0.0041, 0.0043, 0.0044, 0.0043, 0.0041, 0.0038, 0.0035, 0.0031,
	 0.0026, 0.0022, 0.0018, 0.0014, 0.0011, 0.0010, 0.0014, 0.0017, 0.0021, 0.0025, 0.0030, 0.0033, 0.0037, 0.0040,
	 0.0041, 0.0042, 0.0041, 0.0040, 0.0037, 0.0033, 0.0030, 0.0025, 0.0021, 0.0017, 0.0014, 0.0010, 0.0013, 0.0016,
	 0.0020, 0.0024, 0.0028, 0.0031, 0.0034, 0.0037, 0.0038, 0.0039, 0.0038, 0.0037, 0.0034, 0.0031, 0.0028, 0.0024,
	 0.0020, 0.0016, 0.0013, 0.0011, 0.0015, 0.0018, 0.0021, 0.0025, 0.0028, 0.0031, 0.0033, 0.0035, 0.0035, 0.0035,
	 0.0033, 0.0031, 0.0028, 0.0025, 0.0021, 0.0018, 0.0015, 0.0011, 0.0010, 0.0013, 0.0016, 0.0019, 0.0022, 0.0025,
	 0.0028, 0.0030, 0.0031, 0.0031, 0.0031, 0.0030, 0.0028, 0.0025, 0.0022, 0.0019, 0.0016, 0.0013, 0.0010, 0.0011,
	 0.0014, 0.0016, 0.0019, 0.0021, 0.0024, 0.0025, 0.0026, 0.0027, 0.0026, 0.0025, 0.0024, 0.0021, 0.0019, 0.0016,
	 0.0014, 0.0011, 0.0011, 0.0014, 0.0016, 0.0018, 0.0020, 0.0021, 0.0022, 0.0022, 0.0022, 0.0021, 0.0020, 0.0018,
	 0.0016, 0.0014, 0.0011, 0.0011, 0.0013, 0.0015, 0.0016, 0.0017, 0.0018, 0.0018, 0.0018, 0.0017, 0.0016, 0.0015,
	 0.0013, 0.0011, 0.0010, 0.0011, 0.0013, 0.0014, 0.0014, 0.0014, 0.0014, 0.0014, 0.0013, 0.0011, 0.0010, 0.0010,
	 0.0011, 0.0011, 0.0011, 0.0010
};
#endif

#endif // #ifndef DENOISER_TOOLS_LK_12231312
