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

struct ray_pass_s *R_VkRayDenoiserNoDenoiseCreate( void ) {
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
	X(2, gi_sh1_accum) \
	X(3, gi_sh2_accum) \

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

//// Aliases for maps reusing
//#define DENOISER_IMAGE_0 light_poly_diffuse
//#define DENOISER_IMAGE_1 light_poly_specular
//#define DENOISER_IMAGE_2 light_point_diffuse
//#define DENOISER_IMAGE_3 light_point_specular
//#define DENOISER_IMAGE_4 light_poly_reflection
//#define DENOISER_IMAGE_5 light_point_reflection
//#define DENOISER_IMAGE_6 light_poly_indirect
//#define DENOISER_IMAGE_7 light_point_indirect
//#define DENOISER_IMAGE_8 refl_emissive
//#define DENOISER_IMAGE_9 gi_emissive
//#define DENOISER_IMAGE_10 gi_direction

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


// PASS 3. REPROJECT

#define LIST_OUTPUTS_REPROJ(X) \
	X(0, diffuse_accum) \
	X(1, specular_accum) \
	X(2, gi_sh1_accum) \
	X(3, gi_sh2_accum) \

#define LIST_INPUTS_REPROJ(X) \
	X(4, last_diffuse) \
	X(5, last_specular) \
	X(6, last_gi_sh1) \
	X(7, last_gi_sh2) \
	X(8, position_t) \
	X(9, normals_gs) \
	X(10, material_rmxx) \
	X(11, motion_offsets_uvs) \
	X(12, refl_normals_gs) \
	X(13, refl_dir_length) \
	X(14, last_position_t) \
	X(15, last_normals_gs) \


static const VkDescriptorSetLayoutBinding bindings_reproj[] = {
#define BIND_IMAGE(index, name) \
	{ \
		.binding = index, \
		.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, \
		.descriptorCount = 1, \
		.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT, \
	},
	LIST_OUTPUTS_REPROJ(BIND_IMAGE)
	LIST_INPUTS_REPROJ(BIND_IMAGE)
#undef BIND_IMAGE
};

static const int semantics_reproj[] = {
#define IN(index, name, ...) (RayResource_##name + 1),
#define OUT(index, name, ...) -(RayResource_##name + 1),
	LIST_OUTPUTS_REPROJ(OUT)
	LIST_INPUTS_REPROJ(IN)
#undef IN
#undef OUT
};

struct ray_pass_s* R_VkRayDenoiserReprojectCreate(void) {
	const ray_pass_create_compute_t rpcc = {
		.debug_name = "denoiser reproject",
		.layout = {
			.bindings = bindings_reproj,
			.bindings_semantics = semantics_reproj,
			.bindings_count = COUNTOF(bindings_reproj),
			.push_constants = {0},
		},
		.shader = "denoiser_reproject.comp.spv",
		.specialization = NULL,
	};

	return RayPassCreateCompute(&rpcc);
}


	// PASS 2. SPREAD

//// Aliases for maps reusing
//#define DENOISER_IMAGE_0 specular_spread
//#define DENOISER_IMAGE_1 specular_reproject

#define LIST_OUTPUTS_SPREAD(X) \
	X(0, specular_spread) \
	X(1, gi_sh1_spread) \
	X(2, gi_sh2_spread) \

#define LIST_INPUTS_SPREAD(X) \
	X(3, specular_accum) \
	X(4, gi_sh1_accum) \
	X(5, gi_sh2_accum) \
	X(6, position_t) \
	X(7, refl_position_t) \
	X(8, normals_gs) \
	X(9, material_rmxx) \
	X(10, refl_normals_gs) \
	X(11, refl_dir_length) \
	X(12, refl_base_color_a) \
	

static const VkDescriptorSetLayoutBinding bindings_spread[] = {
#define BIND_IMAGE(index, name) \
	{ \
		.binding = index, \
		.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, \
		.descriptorCount = 1, \
		.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT, \
	},
	LIST_OUTPUTS_SPREAD(BIND_IMAGE)
	LIST_INPUTS_SPREAD(BIND_IMAGE)
#undef BIND_IMAGE
};

static const int semantics_spread[] = {
#define IN(index, name, ...) (RayResource_##name + 1),
#define OUT(index, name, ...) -(RayResource_##name + 1),
	LIST_OUTPUTS_SPREAD(OUT)
	LIST_INPUTS_SPREAD(IN)
#undef IN
#undef OUT
};

struct ray_pass_s* R_VkRayDenoiserSpreadCreate(void) {
	const ray_pass_create_compute_t rpcc = {
		.debug_name = "denoiser spread",
		.layout = {
			.bindings = bindings_spread,
			.bindings_semantics = semantics_spread,
			.bindings_count = COUNTOF(bindings_spread),
			.push_constants = {0},
		},
		.shader = "denoiser_spread.comp.spv",
		.specialization = NULL,
	};

	return RayPassCreateCompute(&rpcc);
}


// PASS 4. REFINE

#define LIST_OUTPUTS_REFINE(X) \
	X(0, diffuse_denoised) \
	X(1, specular_denoised) \
	X(2, gi_sh1_denoised) \
	X(3, gi_sh2_denoised) \

#define LIST_INPUTS_REFINE(X) \
	X(4, diffuse_accum) \
	X(5, specular_spread) \
	X(6, gi_sh1_spread) \
	X(7, gi_sh2_spread) \
	X(8, position_t) \
	X(9, normals_gs) \
	X(10, material_rmxx) \


static const VkDescriptorSetLayoutBinding bindings_refine[] = {
#define BIND_IMAGE(index, name) \
	{ \
		.binding = index, \
		.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, \
		.descriptorCount = 1, \
		.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT, \
	},
	LIST_OUTPUTS_REFINE(BIND_IMAGE)
	LIST_INPUTS_REFINE(BIND_IMAGE)
#undef BIND_IMAGE
};

static const int semantics_refine[] = {
#define IN(index, name, ...) (RayResource_##name + 1),
#define OUT(index, name, ...) -(RayResource_##name + 1),
	LIST_OUTPUTS_REFINE(OUT)
	LIST_INPUTS_REFINE(IN)
#undef IN
#undef OUT
};

struct ray_pass_s* R_VkRayDenoiserRefineCreate(void) {
	const ray_pass_create_compute_t rpcc = {
		.debug_name = "denoiser refine",
		.layout = {
			.bindings = bindings_refine,
			.bindings_semantics = semantics_refine,
			.bindings_count = COUNTOF(bindings_refine),
			.push_constants = {0},
		},
		.shader = "denoiser_refine.comp.spv",
		.specialization = NULL,
	};

	return RayPassCreateCompute(&rpcc);
}


	// PASS 5. COMPOSE

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
	X(10, refl_dir_length) \

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

// PASS 6. FXAA

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
