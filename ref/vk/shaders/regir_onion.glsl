#ifndef REGIR_ONION_GLSL_INCLUDED
#define REGIR_ONION_GLSL_INCLUDED

const uint REGIR_ONION_CELL_COUNT = 2253u;
const uint REGIR_ONION_SLOTS_PER_CELL = 512u;
const uint REGIR_ONION_BUILD_SAMPLES = 8u;
const uint REGIR_ONION_LOOKUP_CANDIDATES = 4u;
const uint REGIR_ONION_INVALID_LIGHT_ID = 1023u;
const float REGIR_ONION_NORMALIZED_RADIUS = 145.0550570;

struct RegirOnionLayer
{
	float innerRadius;
	float outerRadius;
	float invLogLayerScale;
	float invEquatorialCellAngle;
	float equatorialCellAngle;
	float layerScale;

	uint ringOffset;
	uint ringCount;
	uint cellsPerLayer;
	uint layerCount;
	uint layerCellOffset;
};

struct RegirOnionRing
{
	uint cellCount;
	uint cellOffset;

	float invCellAngle;
	float cellAngle;
};

const RegirOnionLayer regirOnionLayers[5] = RegirOnionLayer[](
	RegirOnionLayer(
		1.0, 2.2932603,
		1.2048563, 1.2732395,
		0.7853982, 2.2932603,
		0u, 3u, 20u, 1u, 1u),
	RegirOnionLayer(
		2.2932603, 3.9198483,
		1.8653986, 1.9098593,
		0.5235988, 1.7092906,
		3u, 4u, 46u, 1u, 21u),
	RegirOnionLayer(
		3.9198483, 5.8352592,
		2.5134108, 2.5464791,
		0.3926991, 1.4886441,
		7u, 5u, 80u, 1u, 67u),
	RegirOnionLayer(
		5.8352592, 8.0100800,
		3.1567444, 3.1830989,
		0.3141593, 1.3727034,
		12u, 6u, 126u, 1u, 147u),
	RegirOnionLayer(
		8.0100800, 145.0550570,
		3.7978014, 3.8197186,
		0.2617994, 1.3012303,
		18u, 7u, 180u, 11u, 273u)
);

const RegirOnionRing regirOnionRings[25] = RegirOnionRing[](
	RegirOnionRing(8u, 0u, 1.2732395, 0.7853982),
	RegirOnionRing(5u, 8u, 0.7957747, 1.2566371),
	RegirOnionRing(1u, 18u, 0.1591549, 6.2831853),

	RegirOnionRing(12u, 0u, 1.9098593, 0.5235988),
	RegirOnionRing(10u, 12u, 1.5915494, 0.6283185),
	RegirOnionRing(6u, 32u, 0.9549297, 1.0471976),
	RegirOnionRing(1u, 44u, 0.1591549, 6.2831853),

	RegirOnionRing(16u, 0u, 2.5464791, 0.3926991),
	RegirOnionRing(14u, 16u, 2.2281692, 0.4487990),
	RegirOnionRing(11u, 44u, 1.7507044, 0.5711987),
	RegirOnionRing(6u, 66u, 0.9549297, 1.0471976),
	RegirOnionRing(1u, 78u, 0.1591549, 6.2831853),

	RegirOnionRing(20u, 0u, 3.1830989, 0.3141593),
	RegirOnionRing(19u, 20u, 3.0239439, 0.3306940),
	RegirOnionRing(16u, 58u, 2.5464791, 0.3926991),
	RegirOnionRing(11u, 90u, 1.7507044, 0.5711987),
	RegirOnionRing(6u, 112u, 0.9549297, 1.0471976),
	RegirOnionRing(1u, 124u, 0.1591549, 6.2831853),

	RegirOnionRing(24u, 0u, 3.8197186, 0.2617994),
	RegirOnionRing(23u, 24u, 3.6605637, 0.2731820),
	RegirOnionRing(20u, 70u, 3.1830989, 0.3141593),
	RegirOnionRing(16u, 110u, 2.5464791, 0.3926991),
	RegirOnionRing(12u, 142u, 1.9098593, 0.5235988),
	RegirOnionRing(6u, 166u, 0.9549297, 1.0471976),
	RegirOnionRing(1u, 178u, 0.1591549, 6.2831853)
);

struct RegirOnionCellVolume
{
	vec3 center;
	float radius;
};

struct RegirOnionCandidate
{
	uint light_id;
	float inv_source_pdf;
};

float regirOnionCellSize()
{
	return
		max(ubo.ubo.regir_onion_radius, 1.0) /
		REGIR_ONION_NORMALIZED_RADIUS;
}

vec3 regirOnionCenter()
{
	return ubo.ubo.inv_view[3].xyz;
}

vec3 regirSphericalToCartesian(float r, float azimuth, float elevation)
{
	return vec3(
		r * cos(azimuth) * cos(elevation),
		r * sin(elevation),
		r * sin(azimuth) * cos(elevation));
}

void regirCartesianToSpherical(vec3 p, out float r, out float azimuth, out float elevation)
{
	r = length(p);
	azimuth = atan(p.z, p.x);
	elevation = r > 0.0 ? asin(clamp(p.y / r, -1.0, 1.0)) : 0.0;
}

bool regirOnionCellIndexToVolume(uint cell_index, out RegirOnionCellVolume cell)
{
	const float scale = regirOnionCellSize();

	if (cell_index == 0u) {
		cell.center = regirOnionCenter();
		cell.radius = regirOnionLayers[0].innerRadius * scale;
		return true;
	}

	if (cell_index >= REGIR_ONION_CELL_COUNT) {
		return false;
	}

	uint local_index = cell_index - 1u;
	uint group_index = 0u;

	for (; group_index < 5u; ++group_index) {
		const uint count =
			regirOnionLayers[group_index].cellsPerLayer *
			regirOnionLayers[group_index].layerCount;

		if (local_index < count) {
			break;
		}

		local_index -= count;
	}

	const RegirOnionLayer group = regirOnionLayers[group_index];
	const uint layer_index = local_index / group.cellsPerLayer;
	local_index -= layer_index * group.cellsPerLayer;

	uint ring_index = 0u;
	RegirOnionRing ring;

	for (; ring_index < group.ringCount; ++ring_index) {
		ring = regirOnionRings[group.ringOffset + ring_index];

		const uint ring_end =
			ring.cellOffset +
			ring.cellCount * (ring_index > 0u ? 2u : 1u);

		if (local_index < ring_end) {
			break;
		}
	}

	local_index -= ring.cellOffset;

	float elevation = float(ring_index) * group.equatorialCellAngle;
	if (local_index >= ring.cellCount) {
		elevation = -elevation;
		local_index -= ring.cellCount;
	}

	float azimuth = (float(local_index) + 0.5) * ring.cellAngle;
	if ((layer_index & 1u) != 0u) {
		azimuth += ring.cellAngle * 0.5;
	}

	azimuth -= kPi;

	const float inner_radius =
		group.innerRadius *
		pow(group.layerScale, float(layer_index));

	const float outer_radius = inner_radius * group.layerScale;
	const float middle_radius = (inner_radius + outer_radius) * 0.5;

	const vec3 local_center =
		regirSphericalToCartesian(
			middle_radius,
			azimuth,
			elevation);

	const float corner_azimuth =
		azimuth + ring.cellAngle * 0.5;

	const float corner_elevation =
		elevation == 0.0
			? group.equatorialCellAngle * 0.5
			: (abs(elevation) - group.equatorialCellAngle * 0.5) *
				sign(elevation);

	const vec3 corner =
		regirSphericalToCartesian(
			outer_radius,
			corner_azimuth,
			corner_elevation);

	cell.center = regirOnionCenter() + local_center * scale;
	cell.radius = length(corner - local_center) * scale;

	return true;
}

int regirWorldPositionToOnionCell(vec3 world_pos)
{
	const float scale = regirOnionCellSize();
	const vec3 local_pos =
		(world_pos - regirOnionCenter()) / scale;

	float radius;
	float azimuth;
	float elevation;
	regirCartesianToSpherical(
		local_pos,
		radius,
		azimuth,
		elevation);

	azimuth += kPi;

	if (radius <= regirOnionLayers[0].innerRadius) {
		return 0;
	}

	uint group_index = 0u;

	for (; group_index < 5u; ++group_index) {
		if (radius <= regirOnionLayers[group_index].outerRadius) {
			break;
		}
	}

	if (group_index >= 5u) {
		return -1;
	}

	const RegirOnionLayer group = regirOnionLayers[group_index];

	const uint layer_index = min(
		uint(floor(max(
			0.0,
			log(radius / group.innerRadius) *
				group.invLogLayerScale))),
		group.layerCount - 1u);

	const uint ring_index = min(
		uint(floor(
			abs(elevation) *
			group.invEquatorialCellAngle +
			0.5)),
		group.ringCount - 1u);

	const RegirOnionRing ring =
		regirOnionRings[group.ringOffset + ring_index];

	if ((layer_index & 1u) != 0u) {
		azimuth -= ring.cellAngle * 0.5;

		if (azimuth < 0.0) {
			azimuth += 2.0 * kPi;
		}
	}

	const uint ring_offset =
		ring.cellOffset +
		((elevation < 0.0 && ring_index > 0u)
			? ring.cellCount
			: 0u);

	return int(
		uint(floor(azimuth * ring.invCellAngle)) +
		ring_offset +
		layer_index * group.cellsPerLayer +
		group.layerCellOffset);
}

uint regirHash(uint value)
{
	value ^= value >> 16;
	value *= 0x7feb352du;
	value ^= value >> 15;
	value *= 0x846ca68bu;
	return value ^ (value >> 16);
}

float regirRandom(inout uint state)
{
	state = regirHash(state);
	return float(state) * (1.0 / 4294967296.0);
}

float regirOnionJitterScale(vec3 world_pos)
{
	const float normalized_distance =
		length(world_pos - regirOnionCenter()) /
		regirOnionCellSize();

	return
		regirOnionCellSize() *
		max(1.0, normalized_distance * 0.17);
}

uint regirEncodeInvPdf(float value)
{
	if (!(value > 0.0) || isnan(value) || isinf(value)) {
		return 0u;
	}

	const float normalized =
		clamp(
			(log2(value) + 16.0) / 48.0,
			0.0,
			1.0);

	return 1u + uint(round(normalized * 16382.0));
}

float regirDecodeInvPdf(uint encoded)
{
	if (encoded == 0u) {
		return 0.0;
	}

	return exp2(
		(float(encoded - 1u) / 16382.0) *
		48.0 -
		16.0);
}

float regirPackCandidate(uint light_id, float inv_pdf)
{
	const uint encoded_inv_pdf = regirEncodeInvPdf(inv_pdf);
	const uint encoded_light_id =
		min(light_id, REGIR_ONION_INVALID_LIGHT_ID);

	return float(
		(encoded_inv_pdf << 10u) |
		encoded_light_id);
}

RegirOnionCandidate regirUnpackCandidate(float stored)
{
	const uint packed = uint(stored + 0.5);

	RegirOnionCandidate result;
	result.light_id = packed & 1023u;
	result.inv_source_pdf = regirDecodeInvPdf(packed >> 10u);

	return result;
}

ivec2 regirOnionSlotCoord(uint cell_index, uint slot_index, int width)
{
	const uint texel_linear =
		cell_index * (REGIR_ONION_SLOTS_PER_CELL / 4u) +
		slot_index / 4u;

	return ivec2(
		int(texel_linear % uint(width)),
		int(texel_linear / uint(width)));
}

#ifdef REGIR_ONION_IMAGE
bool regirSelectOnionCell(vec3 world_pos, inout uint rnd, out uint cell_index)
{
	const vec3 jitter =
		vec3(
			regirRandom(rnd),
			regirRandom(rnd),
			regirRandom(rnd)) -
		0.5;

	const vec3 lookup_pos =
		world_pos +
		jitter * regirOnionJitterScale(world_pos);

	const int selected =
		regirWorldPositionToOnionCell(lookup_pos);

	if (selected < 0) {
		return false;
	}

	cell_index = uint(selected);
	return true;
}

bool regirLoadOnionCandidate(uint cell_index, uint ordinal, inout uint rnd, out RegirOnionCandidate candidate)
{
	const float stratified_pos =
		(float(ordinal) + regirRandom(rnd)) /
		float(REGIR_ONION_LOOKUP_CANDIDATES);

	const uint slot = min(
		uint(
			stratified_pos *
			float(REGIR_ONION_SLOTS_PER_CELL)),
		REGIR_ONION_SLOTS_PER_CELL - 1u);

	const ivec2 onion_image_size = imageSize(REGIR_ONION_IMAGE);
	const ivec2 coord =
		regirOnionSlotCoord(
			cell_index,
			slot,
			onion_image_size.x);

	if (any(greaterThanEqual(coord, onion_image_size))) {
		return false;
	}

	const vec4 texel =
		imageLoad(REGIR_ONION_IMAGE, coord);

	const uint channel = slot & 3u;
	const float stored =
		channel == 0u ? texel.x :
		channel == 1u ? texel.y :
		channel == 2u ? texel.z :
		texel.w;

	candidate = regirUnpackCandidate(stored);

	return
		candidate.light_id != REGIR_ONION_INVALID_LIGHT_ID &&
		candidate.inv_source_pdf > 0.0;
}
#endif

#endif
