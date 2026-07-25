#include "light_weight.glsl"
#include "regir_onion.glsl"

#ifndef REGIR_ONION_ACCEPT_LIGHT
#define REGIR_ONION_ACCEPT_LIGHT(light_id_) true
#endif

float regirBuildTarget(uint light_id, RegirOnionCellVolume cell);
uint regirBuildLightCount();

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

	const uint local_index =
		gl_LocalInvocationID.x +
		gl_LocalInvocationID.y * 8u;

	const uint first_slot = local_index * 8u;
	const ivec2 image_size = imageSize(REGIR_ONION_OUTPUT);

	for (uint output_index = 0u; output_index < 8u; ++output_index) {
		const uint slot = first_slot + output_index;

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

		const ivec2 coord =
			regirOnionSlotCoord(cell_index, slot, image_size.x);

		vec4 value = imageLoad(REGIR_ONION_OUTPUT, coord);
		const float packed = regirPackCandidate(selected_id, inv_pdf);
		const uint channel = slot & 3u;

		if (channel == 0u) {
			value.x = packed;
		} else if (channel == 1u) {
			value.y = packed;
		} else if (channel == 2u) {
			value.z = packed;
		} else {
			value.w = packed;
		}

		imageStore(REGIR_ONION_OUTPUT, coord, value);
	}
}
