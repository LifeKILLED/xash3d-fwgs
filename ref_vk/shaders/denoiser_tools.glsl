#ifndef DENOISER_TOOLS_LK_12231312
#define DENOISER_TOOLS_LK_12231312 1

// clamp light exposition without loosing of color
vec3 clamp_color(vec3 color, float clamp_value) {
	float max_color = max(max(color.r, color.g), color.b);
	return max_color > clamp_value ? (color / max_color) * clamp_value : color;
}

// 3-th component is transparent texel status 0 or 1
ivec3 PixToCheckerboard(ivec2 pix, ivec2 res) {
	int is_transparent_texel = (pix.x + pix.y) % 2;
	ivec2 out_pix = ivec2(pix.x / 2 + is_transparent_texel * (res.x / 2), pix.y);
	return ivec3(out_pix, is_transparent_texel);
}

// 3-th component is transparent texel status 0 or 1, targeted to nesessary texel status
ivec3 PixToCheckerboard(ivec2 pix, ivec2 res, int is_transparent_texel) {
	ivec2 out_pix = ivec2(pix.x / 2 + is_transparent_texel * (res.x / 2), pix.y);
	return ivec3(out_pix, is_transparent_texel);
}

// 3-th component is transparent texel status 0 or 1
ivec3 CheckerboardToPix(ivec2 pix, ivec2 res) {
	int half_res = res.x / 2;
	int is_transparent_texel = pix.x / half_res;
	int out_pix_x = (pix.x % half_res) * 2;
	int row_index = pix.y % 2;
	int checker_addition = is_transparent_texel + row_index - row_index*is_transparent_texel*2;
	ivec2 out_pix = ivec2(out_pix_x + checker_addition, pix.y);
	return ivec3(out_pix, is_transparent_texel);
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

vec2 PixToUV(ivec2 pix, ivec2 res) {
	return (vec2(pix) /*+ vec2(0.5)*/) / vec2(res) * 2. - vec2(1.);
}

vec3 PBRMix(vec3 base_color, vec3 diffuse, vec3 specular, float metalness) {
	vec3 metal_colour = specular * base_color;
	vec3 dielectric_colour = mix(diffuse * base_color, specular, 0.04); // like in Unreal
	return mix(dielectric_colour, metal_colour, metalness);
}

vec3 PBRMixFresnel(vec3 base_color, vec3 diffuse, vec3 specular, float metalness, float fresnel) {
	vec3 metal_colour = specular * base_color;
	float diffuse_specular_factor = mix(0.2, 0.04, fresnel);
	vec3 dielectric_colour = mix(diffuse * base_color, specular, diffuse_specular_factor);
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

#endif // #ifndef DENOISER_TOOLS_LK_12231312
