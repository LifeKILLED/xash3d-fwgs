#include "light_weight.glsl"
#include "regir_onion.glsl"

#ifndef REGIR_ONION_ACCEPT_LIGHT
#define REGIR_ONION_ACCEPT_LIGHT(light_id_) true
#endif

float regirBuildTarget(uint light_id, RegirOnionCellVolume cell);
uint regirBuildLightCount();

float regirBuildCandidate(
	uint cell_index,
	uint slot,
	uint light_count,
	RegirOnionCellVolume cell)
{
	uint rnd = regirHash(
		ubo.ubo.random_seed ^
		cell_index * 0x9e3779b9u ^
		slot * 0x85ebca6bu);

	float weight_sum = 0.0;
	float selected_target = 0.0;
	uint selected_id = REGIR_ONION_INVALID_LIGHT_ID;

	for (uint sample_index = 0u; sample_index < REGIR_ONION_BUILD_SAMPLES && light_count > 0u; ++sample_index) {
		const uint light_id = min(
			uint(regirRandom(rnd) * float(light_count)),
			light_count - 1u);

		if (!REGIR_ONION_ACCEPT_LIGHT(light_id)) {
			continue;
		}

		const float target =
			max(regirBuildTarget(light_id, cell), 0.0);

		const float weight =
			target *
			float(light_count) /
			float(REGIR_ONION_BUILD_SAMPLES);

		weight_sum += weight;

		if (weight > 0.0 && regirRandom(rnd) * weight_sum < weight) {
			selected_id = light_id;
			selected_target = target;
		}
	}

	const float inv_pdf =
		selected_target > 0.0
			? weight_sum / selected_target
			: 0.0;

	return regirPackCandidate(selected_id, inv_pdf);
}

void main()
{
	if ((ubo.ubo.renderer_flags & RENDERER_FLAG_DISABLE_REGIR) != 0u) {
		return;
	}

	const uint cell_index =
		gl_WorkGroupID.x +
		gl_WorkGroupID.y * gl_NumWorkGroups.x;

	if (cell_index >= REGIR_ONION_CELL_COUNT) {
		return;
	}

	RegirOnionCellVolume cell;
	if (!regirOnionCellIndexToVolume(cell_index, cell)) {
		return;
	}

	const uint light_count =
		min(regirBuildLightCount(), REGIR_ONION_INVALID_LIGHT_ID);

	const uint texel_index = gl_LocalInvocationIndex;
	if (texel_index >= REGIR_ONION_TEXELS_PER_CELL) {
		return;
	}

	const uint first_slot = texel_index * 4u;
	const ivec2 image_size = imageSize(REGIR_ONION_OUTPUT);
	const ivec2 pix =
		regirOnionSlotCoord(cell_index, first_slot, image_size.x);

	const vec4 candidates = vec4(
		regirBuildCandidate(cell_index, first_slot + 0u, light_count, cell),
		regirBuildCandidate(cell_index, first_slot + 1u, light_count, cell),
		regirBuildCandidate(cell_index, first_slot + 2u, light_count, cell),
		regirBuildCandidate(cell_index, first_slot + 3u, light_count, cell));

	imageStore(REGIR_ONION_OUTPUT, pix, candidates);
}
