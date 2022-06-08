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


	// PASS 2. REFLECTIONS

#define LIST_OUTPUTS_REFL(X) \
	X(0, specular_denoised) \

#define LIST_INPUTS_REFL(X) \
	X(1, specular_accum) \
	X(2, position_t) \
	X(3, refl_position_t) \
	X(4, normals_gs) \
	X(5, material_rmxx) \
	X(6, refl_normals_gs) \
	X(7, refl_dir_dot) \
	X(8, last_reflection) \
	X(9, motion_offsets_uvs) \

static const VkDescriptorSetLayoutBinding bindings_refl[] = {
#define BIND_IMAGE(index, name) \
	{ \
		.binding = index, \
		.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, \
		.descriptorCount = 1, \
		.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT, \
	},
	LIST_OUTPUTS_REFL(BIND_IMAGE)
	LIST_INPUTS_REFL(BIND_IMAGE)
#undef BIND_IMAGE
};

static const int semantics_refl[] = {
#define IN(index, name, ...) (RayResource_##name + 1),
#define OUT(index, name, ...) -(RayResource_##name + 1),
	LIST_OUTPUTS_REFL(OUT)
	LIST_INPUTS_REFL(IN)
#undef IN
#undef OUT
};

struct ray_pass_s* R_VkRayDenoiserReflectionsCreate(void) {
	const ray_pass_create_compute_t rpcc = {
		.debug_name = "denoiser reflections",
		.layout = {
			.bindings = bindings_refl,
			.bindings_semantics = semantics_refl,
			.bindings_count = COUNTOF(bindings_refl),
			.push_constants = {0},
		},
		.shader = "denoiser_reflections.comp.spv",
		.specialization = NULL,
	};

	return RayPassCreateCompute(&rpcc);
}


	// PASS 3. DIFFUSE

#define LIST_OUTPUTS_DIFF(X) \
	X(0, diffuse_denoised) \
	X(1, gi_sh1_denoised) \
	X(2, gi_sh2_denoised) \

#define LIST_INPUTS_DIFF(X) \
	X(3, diffuse_accum) \
	X(4, gi_accum_sh1) \
	X(5, gi_accum_sh2) \
	X(6, position_t) \
	X(7, normals_gs) \
	X(8, refl_position_t) \
	X(9, last_diffuse) \
	X(10, last_gi_sh1) \
	X(11, last_gi_sh2) \
	X(12, motion_offsets_uvs) \


static const VkDescriptorSetLayoutBinding bindings_diff[] = {
#define BIND_IMAGE(index, name) \
	{ \
		.binding = index, \
		.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, \
		.descriptorCount = 1, \
		.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT, \
	},
	LIST_OUTPUTS_DIFF(BIND_IMAGE)
	LIST_INPUTS_DIFF(BIND_IMAGE)
#undef BIND_IMAGE
};

static const int semantics_diff[] = {
#define IN(index, name, ...) (RayResource_##name + 1),
#define OUT(index, name, ...) -(RayResource_##name + 1),
	LIST_OUTPUTS_DIFF(OUT)
	LIST_INPUTS_DIFF(IN)
#undef IN
#undef OUT
};

struct ray_pass_s* R_VkRayDenoiserDiffuseCreate(void) {
	const ray_pass_create_compute_t rpcc = {
		.debug_name = "denoiser reflections",
		.layout = {
			.bindings = bindings_diff,
			.bindings_semantics = semantics_diff,
			.bindings_count = COUNTOF(bindings_diff),
			.push_constants = {0},
		},
		.shader = "denoiser_diffuse.comp.spv",
		.specialization = NULL,
	};

	return RayPassCreateCompute(&rpcc);
}


	// PASS 4. COMPOSE

#define LIST_OUTPUTS_COMP(X) \
	X(0, final_image) \

#define LIST_INPUTS_COMP(X) \
	X(1, base_color_a) \
	X(2, emissive) \
	X(3, position_t) \
	X(4, normals_gs) \
	X(5, material_rmxx) \
	X(6, diffuse_denoised) \
	X(7, specular_denoised) \
	X(8, gi_sh1_denoised) \
	X(9, gi_sh2_denoised) \

static const VkDescriptorSetLayoutBinding bindings_comp[] = {
#define BIND_IMAGE(index, name) \
	{ \
		.binding = index, \
		.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, \
		.descriptorCount = 1, \
		.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT, \
	},
	LIST_OUTPUTS_COMP(BIND_IMAGE)
	LIST_INPUTS_COMP(BIND_IMAGE)
#undef BIND_IMAGE
};

static const int semantics_comp[] = {
#define IN(index, name, ...) (RayResource_##name + 1),
#define OUT(index, name, ...) -(RayResource_##name + 1),
	LIST_OUTPUTS_COMP(OUT)
	LIST_INPUTS_COMP(IN)
#undef IN
#undef OUT
};

struct ray_pass_s* R_VkRayDenoiserComposeCreate(void) {
	const ray_pass_create_compute_t rpcc = {
		.debug_name = "denoiser compose",
		.layout = {
			.bindings = bindings_comp,
			.bindings_semantics = semantics_comp,
			.bindings_count = COUNTOF(bindings_comp),
			.push_constants = {0},
		},
		.shader = "denoiser_compose.comp.spv",
		.specialization = NULL,
	};

	return RayPassCreateCompute(&rpcc);
}

// PASS 5. FXAA

#define LIST_OUTPUTS_FXAA(X) \
	X(0, denoised) \

#define LIST_INPUTS_FXAA(X) \
	X(1, final_image) \

static const VkDescriptorSetLayoutBinding bindings_fxaa[] = {
#define BIND_IMAGE(index, name) \
	{ \
		.binding = index, \
		.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, \
		.descriptorCount = 1, \
		.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT, \
	},
	LIST_OUTPUTS_FXAA(BIND_IMAGE)
	LIST_INPUTS_FXAA(BIND_IMAGE)
#undef BIND_IMAGE
};

static const int semantics_fxaa[] = {
#define IN(index, name, ...) (RayResource_##name + 1),
#define OUT(index, name, ...) -(RayResource_##name + 1),
	LIST_OUTPUTS_FXAA(OUT)
	LIST_INPUTS_FXAA(IN)
#undef IN
#undef OUT
};

struct ray_pass_s* R_VkRayDenoiserFXAACreate(void) {
	const ray_pass_create_compute_t rpcc = {
		.debug_name = "denoiser fxaa",
		.layout = {
			.bindings = bindings_fxaa,
			.bindings_semantics = semantics_fxaa,
			.bindings_count = COUNTOF(bindings_fxaa),
			.push_constants = {0},
		},
		.shader = "denoiser_fxaa.comp.spv",
		.specialization = NULL,
	};

	return RayPassCreateCompute(&rpcc);
}
