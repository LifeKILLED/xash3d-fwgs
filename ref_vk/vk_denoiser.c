#include "vk_denoiser.h"

#include "ray_resources.h"
#include "ray_pass.h"

	// SIMPLE OUT PASS WITHOUT DENOISE

#define LIST_OUTPUTS(X) \
	X(0, denoised) \

#define LIST_INPUTS(X) \
	X(1, base_color_a) \
	X(2, light_poly_diffuse) \
	X(3, light_poly_specular) \
	X(4, light_point_diffuse) \
	X(5, light_point_specular) \
	X(6, emissive) \
	X(7, position_t) \
	X(8, normals_gs) \
	X(9, light_poly_reflection) \
	X(10, light_point_reflection) \
	X(11, light_poly_indirect) \
	X(12, light_point_indirect) \
	X(13, material_rmxx) \
	X(14, refl_emissive) \
	X(15, gi_emissive) \

static const VkDescriptorSetLayoutBinding bindings[] = {
#define BIND_IMAGE(index, name) \
	{ \
		.binding = index, \
		.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, \
		.descriptorCount = 1, \
		.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT, \
	},
	LIST_OUTPUTS(BIND_IMAGE)
	LIST_INPUTS(BIND_IMAGE)
#undef BIND_IMAGE
};

static const int semantics[] = {
#define IN(index, name, ...) (RayResource_##name + 1),
#define OUT(index, name, ...) -(RayResource_##name + 1),
	LIST_OUTPUTS(OUT)
	LIST_INPUTS(IN)
#undef IN
#undef OUT
};

struct ray_pass_s *R_VkRayDenoiserCreate( void ) {
	const ray_pass_create_compute_t rpcc = {
		.debug_name = "denoiser",
		.layout = {
			.bindings = bindings,
			.bindings_semantics = semantics,
			.bindings_count = COUNTOF(bindings),
			.push_constants = {0},
		},
		.shader = "denoiser.comp.spv",
		.specialization = NULL,
	};

	return RayPassCreateCompute( &rpcc );
}


		// PASS 1. ACCUMULATE

#define LIST_OUTPUTS_ACCUM(X) \
	X(0, specular_accum) \
	X(1, diffuse_accum) \
	X(2, gi_accum_sh1) \
	X(3, gi_accum_sh2) \

#define LIST_INPUTS_ACCUM(X) \
	X(4, base_color_a) \
	X(5, light_poly_diffuse) \
	X(6, light_poly_specular) \
	X(7, light_point_diffuse) \
	X(8, light_point_specular) \
	X(9, light_poly_reflection) \
	X(10, light_point_reflection) \
	X(11, light_poly_indirect) \
	X(12, light_point_indirect) \
	X(13, refl_emissive) \
	X(14, gi_emissive) \
	X(15, gi_direction) \

static const VkDescriptorSetLayoutBinding bindings_accum[] = {
#define BIND_IMAGE(index, name) \
	{ \
		.binding = index, \
		.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, \
		.descriptorCount = 1, \
		.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT, \
	},
	LIST_OUTPUTS_ACCUM(BIND_IMAGE)
	LIST_INPUTS_ACCUM(BIND_IMAGE)
#undef BIND_IMAGE
};

static const int semantics_accum[] = {
#define IN(index, name, ...) (RayResource_##name + 1),
#define OUT(index, name, ...) -(RayResource_##name + 1),
	LIST_OUTPUTS_ACCUM(OUT)
	LIST_INPUTS_ACCUM(IN)
#undef IN
#undef OUT
};

struct ray_pass_s* R_VkRayDenoiserAccumulateCreate(void) {
	const ray_pass_create_compute_t rpcc = {
		.debug_name = "denoiser accumulate",
		.layout = {
			.bindings = bindings_accum,
			.bindings_semantics = semantics_accum,
			.bindings_count = COUNTOF(bindings_accum),
			.push_constants = {0},
		},
		.shader = "denoiser_accumulate.comp.spv",
		.specialization = NULL,
	};

	return RayPassCreateCompute(&rpcc);
}
