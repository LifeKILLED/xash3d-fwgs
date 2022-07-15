#include "vk_denoiser.h"

#include "ray_resources.h"
#include "ray_pass.h"


#define BIND_IMAGE(index, name) \
	{ \
		.binding = index, \
		.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, \
		.descriptorCount = 1, \
		.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT, \
	},

#define BIND_UBO(index) \
	{ \
		.binding = index, \
		.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, \
		.descriptorCount = 1, \
		.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT, \
	},

#define IN(index, name, ...) (RayResource_##name + 1),
#define OUT(index, name, ...) -(RayResource_##name + 1),
#define SEMANTIC_UBO() (RayResource_ubo + 1),

#define PASS_CREATE_FUNC(debug_text, shader_name, postfix, ubo_index) \
	static const VkDescriptorSetLayoutBinding bindings_##postfix[] = {\
		LIST_OUTPUTS_##postfix(BIND_IMAGE)\
		LIST_INPUTS_##postfix(BIND_IMAGE)\
		BIND_UBO(ubo_index)\
	};\
	static const int semantics_##postfix[] = {\
		LIST_OUTPUTS_##postfix(OUT)\
		LIST_INPUTS_##postfix(IN)\
		SEMANTIC_UBO()\
	};\
	const ray_pass_create_compute_t rpcc = {\
		.debug_name = debug_text,\
		.layout = {\
			.bindings = bindings_##postfix,\
			.bindings_semantics = semantics_##postfix,\
			.bindings_count = COUNTOF(bindings_##postfix),\
			.push_constants = {0},\
		},\
		.shader = shader_name,\
		.specialization = NULL,\
	};\
	return RayPassCreateCompute( &rpcc );




	// SIMPLE PASS WITHOUT DENOISE

#define LIST_OUTPUTS_BYPASS(X) \
	X(0, denoised) \

#define LIST_INPUTS_BYPASS(X) \
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

struct ray_pass_s* R_VkRayDenoiserNoDenoiseCreate(void) {
	PASS_CREATE_FUNC("denoiser_bypass", "denoiser.comp.spv", BYPASS, 16)
}



	// LAST FRAME BUFFERS INIT

#define LIST_OUTPUTS_LAST_INIT(X) \
	X(0, last_position_t) \
	X(1, last_normals_gs) \
	X(2, last_search_info_ktuv) \
	X(3, last_diffuse) \
	X(4, last_specular) \
	X(5, last_gi_sh1) \
	X(6, last_gi_sh2) \

#define LIST_INPUTS_LAST_INIT(X) \

struct ray_pass_s* R_VkRayDenoiserLastFrameBuffersCreate(void) {
	PASS_CREATE_FUNC("denoiser last frame buffers init", "denoiser_frame_buffers_init.comp.spv", LAST_INIT, 7)
}


	// FAKE RECONSTRUCTION OF MOTION VECTORS

#define LIST_OUTPUTS_MOTION_INIT(X) \
	X(0, motion_offsets_uvs) \

#define LIST_INPUTS_MOTION_INIT(X) \
	X(1, position_t) \
	X(2, refl_position_t) \
	X(3, normals_gs) \
	X(4, search_info_ktuv) \
	X(5, last_position_t) \
	X(6, last_normals_gs) \
	X(7, last_search_info_ktuv) \
	X(8, last_gi_sh2) \

struct ray_pass_s* R_VkRayDenoiserFakeMotionVectorsCreate(void) {
	PASS_CREATE_FUNC("denoiser fake reconstruction of motion vectors", "denoiser_fake_motion_vectors.comp.spv", MOTION_INIT, 9)
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
	X(15, gi_position_t) \
	X(16, position_t) \

struct ray_pass_s* R_VkRayDenoiserAccumulateCreate(void) {
	PASS_CREATE_FUNC("denoiser accumulate", "denoiser_accumulate.comp.spv", ACCUM, 17)
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
	X(13, refl_position_t) \
	X(14, last_position_t) \


struct ray_pass_s* R_VkRayDenoiserReprojectCreate(void) {
	PASS_CREATE_FUNC("denoiser reproject", "denoiser_reproject.comp.spv", REPROJ, 15)
}


	// PASS 2. SPREAD


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
	X(11, refl_base_color_a) \

struct ray_pass_s* R_VkRayDenoiserSpreadCreate(void) {
	PASS_CREATE_FUNC("denoiser spread", "denoiser_spread.comp.spv", SPREAD, 12)
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

struct ray_pass_s* R_VkRayDenoiserRefineCreate(void) {
	PASS_CREATE_FUNC("denoiser refine", "denoiser_refine.comp.spv", REFINE, 11)
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
	X(10, refl_position_t) \

struct ray_pass_s* R_VkRayDenoiserComposeCreate(void) {
	PASS_CREATE_FUNC("denoiser compose", "denoiser_compose.comp.spv", COMP, 11)
}

// PASS 6. FXAA

#define LIST_OUTPUTS_FXAA(X) \
	X(0, denoised) \

#define LIST_INPUTS_FXAA(X) \
	X(1, final_image) \

struct ray_pass_s* R_VkRayDenoiserFXAACreate(void) {
	PASS_CREATE_FUNC("denoiser fxaa", "denoiser_fxaa.comp.spv", FXAA, 2)
}



#undef BINDING_UBO
#undef SEMANTIC_UBO
#undef PASS_CREATE_FUNC
#undef BIND_IMAGE
#undef IN
#undef OUT
