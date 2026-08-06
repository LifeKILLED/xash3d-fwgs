#ifndef TEMPORAL_RESERVOIR_ROTATION_GLSL_INCLUDED
#define TEMPORAL_RESERVOIR_ROTATION_GLSL_INCLUDED

// All reprojection metadata is stored in the image formats already supported by
// sebastian.py. Integer pixel coordinates are represented numerically in
// RGBA32F channels; no integer image format is required.

vec2 temporalReprojectionEncodePixel(ivec2 pix)
{
	return vec2(pix) + vec2(1.0);
}

bool temporalReprojectionDecodePixel(vec2 encoded, ivec2 res, out ivec2 pix)
{
	pix = ivec2(-1);
	if (any(lessThanEqual(encoded, vec2(0.0))) ||
		any(isnan(encoded)) || any(isinf(encoded))) {
		return false;
	}

	pix = ivec2(floor(encoded + vec2(0.5))) - ivec2(1);
	return all(greaterThanEqual(pix, ivec2(0))) && all(lessThan(pix, res));
}

vec2 temporalReprojectionEncodeSource(ivec2 history_pix, bool rotated)
{
	vec2 encoded = temporalReprojectionEncodePixel(history_pix);
	if (rotated) {
		encoded.x = -encoded.x;
	}
	return encoded;
}

bool temporalReprojectionDecodeSource(
	vec2 encoded,
	ivec2 history_res,
	out ivec2 history_pix,
	out bool rotated)
{
	rotated = encoded.x < 0.0;
	return temporalReprojectionDecodePixel(
		vec2(abs(encoded.x), encoded.y), history_res, history_pix);
}

// Reservoir rotation is performed in the current-frame pixel domain before
// reading the canonical reprojection map. The transform is an involution:
// applying it twice returns the original pixel. Therefore each complete pair
// either swaps both histories or keeps both histories, and the rotation itself
// cannot duplicate or cluster reservoirs.
ivec2 temporalReservoirRotationPixel(
	ivec2 pix,
	ivec2 res,
	uint frame_seed,
	uint salt,
	uint mask_bits)
{
	if (mask_bits == 0u) {
		return pix;
	}

	const uint bit_mask = (1u << min(mask_bits, 15u)) - 1u;
	const uint hx = xxhash32(uvec4(frame_seed, salt, 0x726f7478u, 0x70686173u));
	const uint hy = xxhash32(uvec4(frame_seed, salt, 0x726f7479u, 0x70686173u));

	ivec2 phase = ivec2(int(hx & bit_mask), int(hy & bit_mask));
	ivec2 xor_mask = ivec2(
		int((hx >> 16u) & bit_mask),
		int((hy >> 16u) & bit_mask));

	if (all(equal(xor_mask, ivec2(0)))) {
		xor_mask.x = 1;
	}

	const ivec2 shifted = pix + phase;
	const ivec2 rotated = (shifted ^ xor_mask) - phase;
	if (any(lessThan(rotated, ivec2(0))) || any(greaterThanEqual(rotated, res))) {
		return pix;
	}
	return rotated;
}

uint temporalReprojectionOwnerKey(
	ivec2 owner_pix,
	uint frame_seed,
	uint salt)
{
	return xxhash32(uvec4(
		uint(owner_pix.x), uint(owner_pix.y), frame_seed, salt));
}

bool temporalReprojectionOwnerKeyLess(
	uint candidate_key,
	ivec2 candidate_pix,
	uint owner_key,
	ivec2 owner_pix)
{
	if (candidate_key != owner_key) {
		return candidate_key < owner_key;
	}
	return candidate_pix.y < owner_pix.y ||
		(candidate_pix.y == owner_pix.y && candidate_pix.x < owner_pix.x);
}

float temporalReprojectionRandom01(ivec2 pix, uint frame_seed, uint salt)
{
	return uintToFloat01(xxhash32(uvec4(
		uint(pix.x), uint(pix.y), frame_seed, salt)));
}

#endif // TEMPORAL_RESERVOIR_ROTATION_GLSL_INCLUDED
