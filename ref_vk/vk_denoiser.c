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

struct ray_pass_s* R_VkRayDenoiserNoDenoiseCreate(void) {
	PASS_CREATE_FUNC("denoiser_bypass", "denoiser.comp.spv", BYPASS, 9)
}


#undef BINDING_UBO
#undef SEMANTIC_UBO
#undef PASS_CREATE_FUNC
#undef BIND_IMAGE
#undef IN
#undef OUT
