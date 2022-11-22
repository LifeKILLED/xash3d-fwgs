#include "vk_denoiser.h"

#include "ray_resources.h"
#include "ray_pass.h"

#define LIST_OUTPUTS(X) \
	X(1, denoised) \
	X(2, reproj_diffuse) \
	X(3, reproj_specular) \

#define LIST_INPUTS(X) \
	X(4, base_color_a) \
	X(5, material_rmxx) \
	X(6, light_poly_diffuse) \
	X(7, light_poly_specular) \
	X(8, light_point_diffuse) \
	X(9, light_point_specular) \
	X(10, emissive) \
	X(11, position_t) \
	X(12, normals_gs) \
	X(13, prev_diffuse) \
	X(14, prev_specular) \
	X(15, prev_position_t) \

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

