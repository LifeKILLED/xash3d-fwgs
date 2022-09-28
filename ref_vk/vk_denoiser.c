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
/*

	// SIMPLE PASS WITHOUT DENOISE

#define LIST_OUTPUTS_BYPASS(X) \
	X(0, final_image) \

#define LIST_INPUTS_BYPASS(X) \
	X(1, base_color_a) \
	X(2, emissive) \
	X(3, position_t) \
	X(4, normals_gs) \
	X(5, material_rmxx) \
	X(6, diffuse_accum) \
	X(7, specular_accum) \
	X(8, gi_sh1_accum) \
	X(9, gi_sh2_accum) \
	X(10, refl_position_t) \

struct ray_pass_s* R_VkRayDenoiserNoDenoiseCreate(void) {
	PASS_CREATE_FUNC("denoiser compose", "denoiser_compose.comp.spv", BYPASS, 11)
}*/



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
	X(9, material_rmxx) \

struct ray_pass_s* R_VkRayDenoiserFakeMotionVectorsCreate(void) {
	PASS_CREATE_FUNC("denoiser fake reconstruction of motion vectors", "denoiser_fake_motion_vectors.comp.spv", MOTION_INIT, 10)
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


// PASS 3. SPECULAR SPREAD

#define LIST_OUTPUTS_SPREAD(X) \
	X(0, specular_accum) \

#define LIST_INPUTS_SPREAD(X) \
	X(1, specular_pre_spread) \
	X(2, position_t) \
	X(3, refl_position_t) \
	X(4, normals_gs) \
	X(5, material_rmxx) \
	X(6, refl_normals_gs) \


struct ray_pass_s* R_VkRayDenoiserSpecularSpreadCreate(void) {
	PASS_CREATE_FUNC("denoiser specular spread", "denoiser_specular_spread.comp.spv", SPREAD, 7)
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
	X(15, search_info_ktuv) \
	X(16, last_search_info_ktuv) \


struct ray_pass_s* R_VkRayDenoiserReprojectCreate(void) {
	PASS_CREATE_FUNC("denoiser reproject", "denoiser_reproject.comp.spv", REPROJ, 17)
}


	// GI BLUR PASS 1

#define LIST_OUTPUTS_GI_BLUR1(X) \
	X(0, gi_sh1_pass_1) \
	X(1, gi_sh2_pass_1) \

#define LIST_INPUTS_GI_BLUR1(X) \
	X(2, gi_sh1_accum) \
	X(3, gi_sh2_accum) \
	X(4, material_rmxx) \

struct ray_pass_s* R_VkRayDenoiserGIBlurPass1Create(void) {
	PASS_CREATE_FUNC("denoiser gi blur pass 1", "denoiser_gi_blur_pass_1.comp.spv", GI_BLUR1, 5)
}

	// GI BLUR PASS 2

#define LIST_OUTPUTS_GI_BLUR2(X) \
	X(0, gi_sh1_pass_2) \
	X(1, gi_sh2_pass_2) \

#define LIST_INPUTS_GI_BLUR2(X) \
	X(2, gi_sh1_pass_1) \
	X(3, gi_sh2_pass_1) \
	X(4, material_rmxx) \

struct ray_pass_s* R_VkRayDenoiserGIBlurPass2Create(void) {
	PASS_CREATE_FUNC("denoiser gi blur pass 2", "denoiser_gi_blur_pass_2.comp.spv", GI_BLUR2, 5)
}

	// GI BLUR PASS 3

#define LIST_OUTPUTS_GI_BLUR3(X) \
	X(0, gi_sh1_denoised) \
	X(1, gi_sh2_denoised) \

#define LIST_INPUTS_GI_BLUR3(X) \
	X(2, gi_sh1_pass_2) \
	X(3, gi_sh2_pass_2) \
	X(4, material_rmxx) \

struct ray_pass_s* R_VkRayDenoiserGIBlurPass3Create(void) {
	PASS_CREATE_FUNC("denoiser gi blur pass 3", "denoiser_gi_blur_pass_3.comp.spv", GI_BLUR3, 5)
}


	// PASS 5. ADD GI TO SPECULAR

#define LIST_OUTPUTS_ADD_GI(X) \
	X(0, specular_accum) \

#define LIST_INPUTS_ADD_GI(X) \
	X(1, material_rmxx) \
	X(2, refl_base_color_a) \
	X(3, normals_gs) \
	X(4, refl_normals_gs) \
	X(5, gi_sh1_pass_1) \
	X(6, gi_sh2_pass_1) \

struct ray_pass_s* R_VkRayDenoiserAddGIToSpecularCreate(void) {
	PASS_CREATE_FUNC("denoiser add gi to specular", "denoiser_add_gi_to_specular.comp.spv", ADD_GI, 7)
}


	// DIFFUSE SVGF VARIANCE

#define LIST_OUTPUTS_DIFFUSE_VARIANCE(X) \
	X(0, diffuse_variance) \

#define LIST_INPUTS_DIFFUSE_VARIANCE(X) \
	X(1, diffuse_accum) \

struct ray_pass_s* R_VkRayDenoiserDiffuseSVGFVarianceCreate(void) {
	PASS_CREATE_FUNC("denoiser diffuse init variance", "denoiser_svgf_variance.comp.spv", DIFFUSE_VARIANCE, 2)
}


	// DIFFUSE SVGF PASS 1

#define LIST_OUTPUTS_DIFFUSE_SVGF1(X) \
	X(0, diffuse_svgf1) \

#define LIST_INPUTS_DIFFUSE_SVGF1(X) \
	X(1, diffuse_accum) \
	X(2, diffuse_variance) \
	X(3, normals_gs) \
	X(4, position_t) \

struct ray_pass_s* R_VkRayDenoiserDiffuseSVGFPass1Create(void) {
	PASS_CREATE_FUNC("denoiser diffuse svgf pass 1", "denoiser_svgf_pass_1.comp.spv", DIFFUSE_SVGF1, 5)
}


	// DIFFUSE SVGF PASS 2

#define LIST_OUTPUTS_DIFFUSE_SVGF2(X) \
	X(0, diffuse_svgf2) \

#define LIST_INPUTS_DIFFUSE_SVGF2(X) \
	X(1, diffuse_svgf1) \
	X(2, diffuse_variance) \
	X(3, normals_gs) \
	X(4, position_t) \

struct ray_pass_s* R_VkRayDenoiserDiffuseSVGFPass2Create(void) {
	PASS_CREATE_FUNC("denoiser diffuse svgf pass 2", "denoiser_svgf_pass_2.comp.spv", DIFFUSE_SVGF2, 5)
}




	// DIFFUSE SVGF PASS 3

#define LIST_OUTPUTS_DIFFUSE_SVGF3(X) \
	X(0, diffuse_denoised) \

#define LIST_INPUTS_DIFFUSE_SVGF3(X) \
	X(1, diffuse_svgf2) \
	X(2, diffuse_variance) \
	X(3, normals_gs) \
	X(4, position_t) \

struct ray_pass_s* R_VkRayDenoiserDiffuseSVGFPass3Create(void) {
	PASS_CREATE_FUNC("denoiser diffuse svgf pass 3", "denoiser_svgf_pass_3.comp.spv", DIFFUSE_SVGF3, 5)
}






	// SPECULAR SVGF VARIANCE

#define LIST_OUTPUTS_SPECULAR_VARIANCE(X) \
	X(0, specular_variance) \

#define LIST_INPUTS_SPECULAR_VARIANCE(X) \
	X(1, specular_accum) \

struct ray_pass_s* R_VkRayDenoiserSpecularSVGFVarianceCreate(void) {
	PASS_CREATE_FUNC("denoiser specular init variance", "denoiser_svgf_variance.comp.spv", SPECULAR_VARIANCE, 2)
}


	// SPECULAR SVGF PASS 1

#define LIST_OUTPUTS_SPECULAR_SVGF1(X) \
	X(0, specular_svgf1) \

#define LIST_INPUTS_SPECULAR_SVGF1(X) \
	X(1, specular_accum) \
	X(2, specular_variance) \
	X(3, normals_gs) \
	X(4, position_t) \

struct ray_pass_s* R_VkRayDenoiserSpecularSVGFPass1Create(void) {
	PASS_CREATE_FUNC("denoiser specular svgf pass 1", "denoiser_svgf_pass_1.comp.spv", SPECULAR_SVGF1, 5)
}


	// SPECULAR SVGF PASS 2

#define LIST_OUTPUTS_SPECULAR_SVGF2(X) \
	X(0, specular_svgf2) \

#define LIST_INPUTS_SPECULAR_SVGF2(X) \
	X(1, specular_svgf1) \
	X(2, specular_variance) \
	X(3, normals_gs) \
	X(4, position_t) \

struct ray_pass_s* R_VkRayDenoiserSpecularSVGFPass2Create(void) {
	PASS_CREATE_FUNC("denoiser specular svgf pass 2", "denoiser_svgf_pass_2.comp.spv", SPECULAR_SVGF2, 5)
}




	// SPECULAR SVGF PASS 3

#define LIST_OUTPUTS_SPECULAR_SVGF3(X) \
	X(0, specular_denoised) \

#define LIST_INPUTS_SPECULAR_SVGF3(X) \
	X(1, specular_svgf2) \
	X(2, specular_variance) \
	X(3, normals_gs) \
	X(4, position_t) \

struct ray_pass_s* R_VkRayDenoiserSpecularSVGFPass3Create(void) {
	PASS_CREATE_FUNC("denoiser specular svgf pass 3", "denoiser_svgf_pass_3.comp.spv", SPECULAR_SVGF3, 5)
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
	X(8, gi_sh1_pass_2) \
	X(9, gi_sh2_pass_2) \
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
