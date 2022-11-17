#include "vk_denoiser.h"

#include "ray_resources.h"
#include "ray_pass.h"

#define LIST_OUTPUTS(X) \
	X(1, denoised) \
	X(2, reproj_lighting) \

#define LIST_INPUTS(X) \
	X(3, base_color_a) \
	X(4, light_poly_diffuse) \
	X(5, light_poly_specular) \
	X(6, light_point_diffuse) \
	X(7, light_point_specular) \
	X(8, emissive) \
	X(9, position_t) \
	X(10, normals_gs) \
	X(11, prev_lighting) \
	X(12, prev_position_t) \

static const VkDescriptorSetLayoutBinding bindings[] = {
#define BIND_IMAGE(index, name) \
	{ \
		.binding = index, \
		.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, \
		.descriptorCount = 1, \
		.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT, \
	},
	{ // UBO
		.binding = 0,
		.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
		.descriptorCount = 1,
		.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT,
	},
	LIST_OUTPUTS(BIND_IMAGE)
	LIST_INPUTS(BIND_IMAGE)
#undef BIND_IMAGE
};

static const int semantics[] = {
#define IN(index, name, ...) (RayResource_##name + 1),
#define OUT(index, name, ...) -(RayResource_##name + 1),
	RayResource_ubo + 1,
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

