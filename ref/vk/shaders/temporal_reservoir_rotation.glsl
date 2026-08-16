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
// Alternative frame-local permutation used by the new reservoir experiments.
// The screen is tiled into 2x2 cells with one global (0/1, 0/1) phase per
// frame. Each complete cell independently chooses one of the three pairings
// (horizontal, vertical, diagonal), then each of its two disjoint pairs makes
// an independent deterministic stay/swap decision. The mapping is still an
// involution: if A chooses B, B necessarily chooses A.
ivec2 temporalReservoirPairPermutationPixel(
	ivec2 pix,
	ivec2 res,
	uint frame_seed,
	uint salt,
	float swap_probability)
{
	if (any(lessThan(pix, ivec2(0))) || any(greaterThanEqual(pix, res))) {
		return pix;
	}

	const uint phase_hash = xxhash32(uvec4(
		frame_seed, salt, 0x32783270u, 0x70686173u));
	const ivec2 phase = ivec2(
		int(phase_hash & 1u),
		int((phase_hash >> 1u) & 1u));

	// Conceptual 2x2 cells are allowed to straddle the viewport border. Since
	// phase is only 0/1 and pix is in bounds, shifted can be negative only by
	// exactly one texel. GLSL integer division truncates toward zero, so handle
	// that one negative case explicitly to obtain floor(shifted / 2).
	const ivec2 shifted = pix - phase;
	const ivec2 block_coord = ivec2(
		shifted.x < 0 ? -1 : shifted.x / 2,
		shifted.y < 0 ? -1 : shifted.y / 2);
	const ivec2 block_origin = block_coord * 2 + phase;

	// Clip the conceptual cell to the viewport. Rectangular clipping of a 2x2
	// cell can leave 4, 2, or 1 texels (never 3). A half-cell contains one
	// unique pair; swap that pair with exactly 50% probability. A one-texel
	// corner fragment is always identity. This keeps the mapping bijective even
	// when the globally randomized grid phase moves cells across frame edges.
	const ivec2 clipped_min = max(block_origin, ivec2(0));
	const ivec2 clipped_max = min(block_origin + ivec2(1), res - ivec2(1));
	const ivec2 clipped_extent = clipped_max - clipped_min + ivec2(1);
	const int clipped_count = clipped_extent.x * clipped_extent.y;

	if (clipped_count <= 1) {
		return pix;
	}

	if (clipped_count == 2) {
		ivec2 edge_partner = pix;
		if (clipped_extent.x == 2) {
			edge_partner.x = clipped_min.x + clipped_max.x - pix.x;
		} else {
			edge_partner.y = clipped_min.y + clipped_max.y - pix.y;
		}

		const uint edge_pair_hash = xxhash32(uvec4(
			uint(block_coord.x), uint(block_coord.y),
			frame_seed, salt ^ 0x65646765u));
		if ((edge_pair_hash & 0x80000000u) == 0u) {
			return pix;
		}
		return edge_partner;
	}

	const ivec2 local = pix - block_origin;
	const uint topology_hash = xxhash32(uvec4(
		uint(block_coord.x), uint(block_coord.y),
		frame_seed, salt ^ 0x746f706fu));
	const uint topology = topology_hash % 3u;

	ivec2 partner_local;
	if (topology == 0u) {
		partner_local = local ^ ivec2(1, 0); // horizontal pairs
	} else if (topology == 1u) {
		partner_local = local ^ ivec2(0, 1); // vertical pairs
	} else {
		partner_local = local ^ ivec2(1, 1); // diagonal pairs
	}

	// Both endpoints derive exactly the same pair id, so stay/swap is decided
	// once per pair rather than independently per texel.
	const uint local_index = uint(local.x + local.y * 2);
	const uint partner_index = uint(partner_local.x + partner_local.y * 2);
	const uint pair_index = min(local_index, partner_index);
	const uint pair_hash = xxhash32(uvec4(
		uint(block_coord.x), uint(block_coord.y),
		frame_seed ^ pair_index, salt ^ 0x70616972u));
	const float pair_random = float(pair_hash) * (1.0 / 4294967296.0);
	if (pair_random >= clamp(swap_probability, 0.0, 1.0)) {
		return pix;
	}

	return block_origin + partner_local;
}

#define TEMPORAL_RESERVOIR_PERMUTATION_MODE_XOR 0u
#define TEMPORAL_RESERVOIR_PERMUTATION_MODE_PAIR_2X2 1u

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

ivec2 temporalReservoirPermutationPixel(
	ivec2 pix,
	ivec2 res,
	uint frame_seed,
	uint salt,
	uint mode,
	uint xor_mask_bits,
	float pair_swap_probability)
{
	// Keep mask_bits == 0 as the legacy master-off switch. This lets direct
	// temporal rotation remain disabled while selecting the 2x2 algorithm as
	// the default mode for experiments that are enabled.
	if (xor_mask_bits == 0u) {
		return pix;
	}
	if (mode == TEMPORAL_RESERVOIR_PERMUTATION_MODE_PAIR_2X2) {
		return temporalReservoirPairPermutationPixel(
			pix, res, frame_seed, salt, pair_swap_probability);
	}
	return temporalReservoirRotationPixel(
		pix, res, frame_seed, salt, xor_mask_bits);
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
