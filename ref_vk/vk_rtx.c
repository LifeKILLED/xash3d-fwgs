#include "vk_rtx.h"

#include "ray_pass.h"
#include "ray_resources.h"

#include "vk_ray_primary.h"
#include "vk_ray_light_direct.h"

#include "vk_core.h"
#include "vk_common.h"
#include "vk_buffer.h"
#include "vk_pipeline.h"
#include "vk_cvar.h"
#include "vk_textures.h"
#include "vk_light.h"
#include "vk_descriptor.h"
#include "vk_ray_internal.h"
#include "vk_denoiser.h"
#include "vk_math.h"

#include "alolcator.h"


#include "eiface.h"
#include "xash3d_mathlib.h"

#include <string.h>

#define MAX_SCRATCH_BUFFER (32*1024*1024)
#define MAX_ACCELS_BUFFER (64*1024*1024)

#define MAX_FRAMES_IN_FLIGHT 2

// TODO settings/realtime modifiable/adaptive
#if 1
#define FRAME_WIDTH 1280
#define FRAME_HEIGHT 720
#else
#define FRAME_WIDTH 2560
#define FRAME_HEIGHT 1440
#endif

// TODO sync with shaders
// TODO optimal values
#define WG_W 16
#define WG_H 8

typedef struct {
	vec3_t pos;
	float radius;
	vec3_t color;
	float padding_;
} vk_light_t;

typedef struct PushConstants vk_rtx_push_constants_t;

typedef struct {
	xvk_image_t denoised;

#define X(index, name, ...) xvk_image_t name;
	RAY_PRIMARY_OUTPUTS(X)
	RAY_LIGHT_DIRECT_POLY_OUTPUTS(X)
	RAY_LIGHT_DIRECT_POINT_OUTPUTS(X)
	RAY_LIGHT_REFLECT_POLY_OUTPUTS(X)
	RAY_LIGHT_REFLECT_POINT_OUTPUTS(X)
	RAY_LIGHT_INDIRECT_POLY_OUTPUTS(X)
	RAY_LIGHT_INDIRECT_POINT_OUTPUTS(X)
#undef X

} xvk_ray_frame_images_t;

static struct {
	// Holds UniformBuffer data
	vk_buffer_t uniform_buffer;
	uint32_t uniform_unit_size;

	// Stores AS built data. Lifetime similar to render buffer:
	// - some portion lives for entire map lifetime
	// - some portion lives only for a single frame (may have several frames in flight)
	// TODO: unify this with render buffer
	// Needs: AS_STORAGE_BIT, SHADER_DEVICE_ADDRESS_BIT
	vk_buffer_t accels_buffer;
	struct alo_pool_s *accels_buffer_alloc;

	// Temp: lives only during a single frame (may have many in flight)
	// Used for building ASes;
	// Needs: AS_STORAGE_BIT, SHADER_DEVICE_ADDRESS_BIT
	vk_buffer_t scratch_buffer;
	VkDeviceAddress accels_buffer_addr, scratch_buffer_addr;

	// Temp-ish: used for making TLAS, contains addressed to all used BLASes
	// Lifetime and nature of usage similar to scratch_buffer
	// TODO: unify them
	// Needs: SHADER_DEVICE_ADDRESS, STORAGE_BUFFER, AS_BUILD_INPUT_READ_ONLY
	vk_buffer_t tlas_geom_buffer;
	VkDeviceAddress tlas_geom_buffer_addr;
	r_flipping_buffer_t tlas_geom_buffer_alloc;

	// TODO need several TLASes for N frames in flight
	VkAccelerationStructureKHR tlas;

	// Per-frame data that is accumulated between RayFrameBegin and End calls
	struct {
		uint32_t scratch_offset; // for building dynamic blases
	} frame;

	// TODO with proper intra-cmdbuf sync we don't really need 2x images
	unsigned frame_number;
	xvk_ray_frame_images_t frames[MAX_FRAMES_IN_FLIGHT];

#define X(name, init_func)
#define PASSES_LIST(X) \
	X(primary_ray, R_VkRayPrimaryPassCreate) \
	X(light_direct_poly, R_VkRayLightDirectPolyPassCreate) \
	X(light_direct_point, R_VkRayLightDirectPointPassCreate) \
	X(light_reflect_poly, R_VkRayLightReflectPolyPassCreate) \
	X(light_reflect_point, R_VkRayLightReflectPointPassCreate) \
	X(light_indirect_poly, R_VkRayLightIndirectPolyPassCreate) \
	X(light_indirect_point, R_VkRayLightIndirectPointPassCreate) \
	X(denoiser_no_denoise, R_VkRayDenoiserNoDenoiseCreate) \

#undef X

	struct {
#define PASSES_DEFINE(name, init_func) \
		struct ray_pass_s* name;
		PASSES_LIST(PASSES_DEFINE)
	} pass;
#undef PASSES_DEFINE

	qboolean reload_pipeline;
	qboolean reload_lighting;
	qboolean denoiser_enabled;
	qboolean last_frame_buffers_inited;
} g_rtx = {0};

VkDeviceAddress getBufferDeviceAddress(VkBuffer buffer) {
	const VkBufferDeviceAddressInfo bdai = {.sType = VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO, .buffer = buffer};
	return vkGetBufferDeviceAddress(vk_core.device, &bdai);
}

static VkDeviceAddress getASAddress(VkAccelerationStructureKHR as) {
	VkAccelerationStructureDeviceAddressInfoKHR asdai = {
		.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_DEVICE_ADDRESS_INFO_KHR,
		.accelerationStructure = as,
	};
	return vkGetAccelerationStructureDeviceAddressKHR(vk_core.device, &asdai);
}

// TODO split this into smaller building blocks in a separate module
qboolean createOrUpdateAccelerationStructure(VkCommandBuffer cmdbuf, const as_build_args_t *args, vk_ray_model_t *model) {
	qboolean should_create = *args->p_accel == VK_NULL_HANDLE;
#if 1 // update does not work at all on AMD gpus
	qboolean is_update = false; // FIXME this crashes for some reason !should_create && args->dynamic;
#else
	qboolean is_update = !should_create && args->dynamic;
#endif

	VkAccelerationStructureBuildGeometryInfoKHR build_info = {
		.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_GEOMETRY_INFO_KHR,
		.type = args->type,
		.flags = VK_BUILD_ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT_KHR | ( args->dynamic ? VK_BUILD_ACCELERATION_STRUCTURE_ALLOW_UPDATE_BIT_KHR : 0),
		.mode =  is_update ? VK_BUILD_ACCELERATION_STRUCTURE_MODE_UPDATE_KHR : VK_BUILD_ACCELERATION_STRUCTURE_MODE_BUILD_KHR,
		.geometryCount = args->n_geoms,
		.pGeometries = args->geoms,
		.srcAccelerationStructure = is_update ? *args->p_accel : VK_NULL_HANDLE,
	};

	VkAccelerationStructureBuildSizesInfoKHR build_size = {
		.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR
	};

	uint32_t scratch_buffer_size = 0;

	ASSERT(args->geoms);
	ASSERT(args->n_geoms > 0);
	ASSERT(args->p_accel);

	vkGetAccelerationStructureBuildSizesKHR(
		vk_core.device, VK_ACCELERATION_STRUCTURE_BUILD_TYPE_DEVICE_KHR, &build_info, args->max_prim_counts, &build_size);

	scratch_buffer_size = is_update ? build_size.updateScratchSize : build_size.buildScratchSize;

#if 0
	{
		uint32_t max_prims = 0;
		for (int i = 0; i < args->n_geoms; ++i)
			max_prims += args->max_prim_counts[i];
		gEngine.Con_Reportf(
			"AS max_prims=%u, n_geoms=%u, build size: %d, scratch size: %d\n", max_prims, args->n_geoms, build_size.accelerationStructureSize, build_size.buildScratchSize);
	}
#endif

	if (MAX_SCRATCH_BUFFER < g_rtx.frame.scratch_offset + scratch_buffer_size) {
		gEngine.Con_Printf(S_ERROR "Scratch buffer overflow: left %u bytes, but need %u\n",
			MAX_SCRATCH_BUFFER - g_rtx.frame.scratch_offset,
			scratch_buffer_size);
		return false;
	}

	if (should_create) {
		const uint32_t as_size = build_size.accelerationStructureSize;
		const alo_block_t block = aloPoolAllocate(g_rtx.accels_buffer_alloc, as_size, /*TODO why? align=*/256);
		const uint32_t buffer_offset = block.offset;
		const VkAccelerationStructureCreateInfoKHR asci = {
			.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_CREATE_INFO_KHR,
			.buffer = g_rtx.accels_buffer.buffer,
			.offset = buffer_offset,
			.type = args->type,
			.size = as_size,
		};

		if (buffer_offset == ALO_ALLOC_FAILED) {
			gEngine.Con_Printf(S_ERROR "Failed to allocated %u bytes for accel buffer\n", asci.size);
			return false;
		}

		XVK_CHECK(vkCreateAccelerationStructureKHR(vk_core.device, &asci, NULL, args->p_accel));
		SET_DEBUG_NAME(*args->p_accel, VK_OBJECT_TYPE_ACCELERATION_STRUCTURE_KHR, args->debug_name);

		if (model) {
			model->size = asci.size;
			model->debug.as_offset = buffer_offset;
		}

		// gEngine.Con_Reportf("AS=%p, n_geoms=%u, build: %#x %d %#x\n", *args->p_accel, args->n_geoms, buffer_offset, asci.size, buffer_offset + asci.size);
	}

	// If not enough data for building, just create
	if (!cmdbuf || !args->build_ranges)
		return true;

	if (model) {
		ASSERT(model->size >= build_size.accelerationStructureSize);
	}

	build_info.dstAccelerationStructure = *args->p_accel;
	build_info.scratchData.deviceAddress = g_rtx.scratch_buffer_addr + g_rtx.frame.scratch_offset;
	//uint32_t scratch_offset_initial = g_rtx.frame.scratch_offset;
	g_rtx.frame.scratch_offset += scratch_buffer_size;
	g_rtx.frame.scratch_offset = ALIGN_UP(g_rtx.frame.scratch_offset, vk_core.physical_device.properties_accel.minAccelerationStructureScratchOffsetAlignment);

	//gEngine.Con_Reportf("AS=%p, n_geoms=%u, scratch: %#x %d %#x\n", *args->p_accel, args->n_geoms, scratch_offset_initial, scratch_buffer_size, scratch_offset_initial + scratch_buffer_size);

	vkCmdBuildAccelerationStructuresKHR(cmdbuf, 1, &build_info, &args->build_ranges);
	return true;
}

static void createTlas( VkCommandBuffer cmdbuf, VkDeviceAddress instances_addr ) {
	const VkAccelerationStructureGeometryKHR tl_geom[] = {
		{
			.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_KHR,
			//.flags = VK_GEOMETRY_OPAQUE_BIT,
			.geometryType = VK_GEOMETRY_TYPE_INSTANCES_KHR,
			.geometry.instances =
				(VkAccelerationStructureGeometryInstancesDataKHR){
					.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_INSTANCES_DATA_KHR,
					.data.deviceAddress = instances_addr,
					.arrayOfPointers = VK_FALSE,
				},
		},
	};
	const uint32_t tl_max_prim_counts[ARRAYSIZE(tl_geom)] = { MAX_ACCELS }; //cmdbuf == VK_NULL_HANDLE ? MAX_ACCELS : g_ray_model_state.frame.num_models };
	const VkAccelerationStructureBuildRangeInfoKHR tl_build_range = {
		.primitiveCount = g_ray_model_state.frame.num_models,
	};
	const as_build_args_t asrgs = {
		.geoms = tl_geom,
		.max_prim_counts = tl_max_prim_counts,
		.build_ranges =  cmdbuf == VK_NULL_HANDLE ? NULL : &tl_build_range,
		.n_geoms = ARRAYSIZE(tl_geom),
		.type = VK_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL_KHR,
		// we can't really rebuild TLAS because instance count changes are not allowed .dynamic = true,
		.dynamic = false,
		.p_accel = &g_rtx.tlas,
		.debug_name = "TLAS",
	};
	if (!createOrUpdateAccelerationStructure(cmdbuf, &asrgs, NULL)) {
		gEngine.Host_Error("Could not create/update TLAS\n");
		return;
	}
}

void VK_RayNewMap( void ) {
	const int expected_accels = 512; // TODO actually get this from playing the game
	const int accels_alignment = 256; // TODO where does this come from?
	ASSERT(vk_core.rtx);

	if (g_rtx.accels_buffer_alloc)
		aloPoolDestroy(g_rtx.accels_buffer_alloc);
	g_rtx.accels_buffer_alloc = aloPoolCreate(MAX_ACCELS_BUFFER, expected_accels, accels_alignment);

	// Clear model cache
	for (int i = 0; i < ARRAYSIZE(g_ray_model_state.models_cache); ++i) {
		vk_ray_model_t *model = g_ray_model_state.models_cache + i;
		VK_RayModelDestroy(model);
	}

	// Recreate tlas
	// Why here and not in init: to make sure that its memory is preserved. Map init will clear all memory regions.
	{
		if (g_rtx.tlas != VK_NULL_HANDLE) {
			vkDestroyAccelerationStructureKHR(vk_core.device, g_rtx.tlas, NULL);
			g_rtx.tlas = VK_NULL_HANDLE;
		}

		createTlas(VK_NULL_HANDLE, g_rtx.tlas_geom_buffer_addr);
	}

	RT_RayModel_Clear();

	// mark to recreate temporal reprojection buffers
	g_rtx.last_frame_buffers_inited = false;

	// enable denoising for default
	g_rtx.denoiser_enabled = true;
}

void VK_RayFrameBegin( void )
{
	ASSERT(vk_core.rtx);

	g_rtx.frame.scratch_offset = 0;

	if (g_ray_model_state.freeze_models)
		return;

	XVK_RayModel_ClearForNextFrame();

	// TODO: move all lighting update to scene?
	if (g_rtx.reload_lighting) {
		g_rtx.reload_lighting = false;
		// FIXME temporarily not supported VK_LightsLoadMapStaticLights();
	}

	// TODO shouldn't we do this in freeze models mode anyway?
	RT_LightsFrameBegin();
}

static void prepareTlas( VkCommandBuffer cmdbuf ) {
	ASSERT(g_ray_model_state.frame.num_models > 0);
	DEBUG_BEGIN(cmdbuf, "prepare tlas");

	R_FlippingBuffer_Flip( &g_rtx.tlas_geom_buffer_alloc );

	const uint32_t instance_offset = R_FlippingBuffer_Alloc(&g_rtx.tlas_geom_buffer_alloc, g_ray_model_state.frame.num_models, 1);
	ASSERT(instance_offset != ALO_ALLOC_FAILED);

	// Upload all blas instances references to GPU mem
	{
		VkAccelerationStructureInstanceKHR* inst = ((VkAccelerationStructureInstanceKHR*)g_rtx.tlas_geom_buffer.mapped) + instance_offset;
		for (int i = 0; i < g_ray_model_state.frame.num_models; ++i) {
			const vk_ray_draw_model_t* const model = g_ray_model_state.frame.models + i;
			ASSERT(model->model);
			ASSERT(model->model->as != VK_NULL_HANDLE);
			inst[i] = (VkAccelerationStructureInstanceKHR){
				.instanceCustomIndex = model->model->kusochki_offset,
				.instanceShaderBindingTableRecordOffset = 0,
				.accelerationStructureReference = getASAddress(model->model->as), // TODO cache this addr
			};
			switch (model->material_mode) {
				case MaterialMode_Opaque:
					inst[i].mask = GEOMETRY_BIT_OPAQUE;
					inst[i].instanceShaderBindingTableRecordOffset = SHADER_OFFSET_HIT_REGULAR,
					inst[i].flags = VK_GEOMETRY_INSTANCE_FORCE_OPAQUE_BIT_KHR;
					break;
				case MaterialMode_Opaque_AlphaTest:
					inst[i].mask = GEOMETRY_BIT_OPAQUE;
					inst[i].instanceShaderBindingTableRecordOffset = SHADER_OFFSET_HIT_ALPHA_TEST,
					inst[i].flags = VK_GEOMETRY_INSTANCE_FORCE_NO_OPAQUE_BIT_KHR;
					break;
				case MaterialMode_Refractive:
					inst[i].mask = GEOMETRY_BIT_REFRACTIVE;
					inst[i].instanceShaderBindingTableRecordOffset = SHADER_OFFSET_HIT_REGULAR,
					inst[i].flags = VK_GEOMETRY_INSTANCE_FORCE_OPAQUE_BIT_KHR;
					break;
				case MaterialMode_Additive:
					inst[i].mask = GEOMETRY_BIT_ADDITIVE;
					inst[i].instanceShaderBindingTableRecordOffset = SHADER_OFFSET_HIT_ADDITIVE,
					inst[i].flags = VK_GEOMETRY_INSTANCE_FORCE_NO_OPAQUE_BIT_KHR;
					break;
			}
			memcpy(&inst[i].transform, model->transform_row, sizeof(VkTransformMatrixKHR));
		}
	}

	// Barrier for building all BLASes
	// BLAS building is now in cmdbuf, need to synchronize with results
	{
		VkBufferMemoryBarrier bmb[] = { {
			.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
			.srcAccessMask = VK_ACCESS_ACCELERATION_STRUCTURE_WRITE_BIT_KHR, // | VK_ACCESS_TRANSFER_WRITE_BIT,
			.dstAccessMask = VK_ACCESS_ACCELERATION_STRUCTURE_READ_BIT_KHR,
			.buffer = g_rtx.accels_buffer.buffer,
			.offset = instance_offset * sizeof(VkAccelerationStructureInstanceKHR),
			.size = g_ray_model_state.frame.num_models * sizeof(VkAccelerationStructureInstanceKHR),
		} };
		vkCmdPipelineBarrier(cmdbuf,
			VK_PIPELINE_STAGE_ACCELERATION_STRUCTURE_BUILD_BIT_KHR,
			VK_PIPELINE_STAGE_ACCELERATION_STRUCTURE_BUILD_BIT_KHR,
			0, 0, NULL, ARRAYSIZE(bmb), bmb, 0, NULL);
	}

	// 2. Build TLAS
	createTlas(cmdbuf, g_rtx.tlas_geom_buffer_addr + instance_offset * sizeof(VkAccelerationStructureInstanceKHR));
	DEBUG_END(cmdbuf);
}

static void clearVkImage( VkCommandBuffer cmdbuf, VkImage image ) {
	const VkImageMemoryBarrier image_barriers[] = { {
		.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
		.image = image,
		.srcAccessMask = 0,
		.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
		.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
		.newLayout = VK_IMAGE_LAYOUT_GENERAL,
		.subresourceRange = (VkImageSubresourceRange) {
			.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
			.baseMipLevel = 0,
			.levelCount = 1,
			.baseArrayLayer = 0,
			.layerCount = 1,
	}} };

	const VkClearColorValue clear_value = {0};

	vkCmdPipelineBarrier(cmdbuf, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
		0, NULL, 0, NULL, ARRAYSIZE(image_barriers), image_barriers);

	vkCmdClearColorImage(cmdbuf, image, VK_IMAGE_LAYOUT_GENERAL, &clear_value, 1, &image_barriers->subresourceRange);
}

typedef struct {
	VkCommandBuffer cmdbuf;

	VkPipelineStageFlags in_stage;
	struct {
		VkImage image;
		int width, height;
		VkImageLayout oldLayout;
		VkAccessFlags srcAccessMask;
	} src, dst;
} xvk_blit_args;

static void blitImage( const xvk_blit_args *blit_args ) {
	{
		const VkImageMemoryBarrier image_barriers[] = { {
			.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
			.image = blit_args->src.image,
			.srcAccessMask = blit_args->src.srcAccessMask,
			.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
			.oldLayout = blit_args->src.oldLayout,
			.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
			.subresourceRange =
				(VkImageSubresourceRange){
					.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
					.baseMipLevel = 0,
					.levelCount = 1,
					.baseArrayLayer = 0,
					.layerCount = 1,
				},
		}, {
			.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
			.image = blit_args->dst.image,
			.srcAccessMask = blit_args->dst.srcAccessMask,
			.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
			.oldLayout = blit_args->dst.oldLayout,
			.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
			.subresourceRange =
				(VkImageSubresourceRange){
					.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
					.baseMipLevel = 0,
					.levelCount = 1,
					.baseArrayLayer = 0,
					.layerCount = 1,
				},
		} };

		vkCmdPipelineBarrier(blit_args->cmdbuf,
			blit_args->in_stage,
			VK_PIPELINE_STAGE_TRANSFER_BIT,
			0, 0, NULL, 0, NULL, ARRAYSIZE(image_barriers), image_barriers);
	}

	{
		VkImageBlit region = {0};
		region.srcOffsets[1].x = blit_args->src.width;
		region.srcOffsets[1].y = blit_args->src.height;
		region.srcOffsets[1].z = 1;
		region.dstOffsets[1].x = blit_args->dst.width;
		region.dstOffsets[1].y = blit_args->dst.height;
		region.dstOffsets[1].z = 1;
		region.srcSubresource.aspectMask = region.dstSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
		region.srcSubresource.layerCount = region.dstSubresource.layerCount = 1;
		vkCmdBlitImage(blit_args->cmdbuf,
			blit_args->src.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
			blit_args->dst.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
			1, &region,
			VK_FILTER_NEAREST);
	}

	{
		VkImageMemoryBarrier image_barriers[] = {
		{
			.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
			.image = blit_args->dst.image,
			.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
			.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
			.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
			.newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
			.subresourceRange =
				(VkImageSubresourceRange){
					.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
					.baseMipLevel = 0,
					.levelCount = 1,
					.baseArrayLayer = 0,
					.layerCount = 1,
				},
		}};
		vkCmdPipelineBarrier(blit_args->cmdbuf,
			VK_PIPELINE_STAGE_TRANSFER_BIT,
			VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
			0, 0, NULL, 0, NULL, ARRAYSIZE(image_barriers), image_barriers);
	}
}

static void prepareUniformBuffer( const vk_ray_frame_render_args_t *args, int frame_index, float fov_angle_y ) {
	struct UniformBuffer *ubo = (struct UniformBuffer*)((char*)g_rtx.uniform_buffer.mapped + frame_index * g_rtx.uniform_unit_size);

	matrix4x4 proj_inv, view_inv;
	Matrix4x4_Invert_Full(proj_inv, *args->projection);
	Matrix4x4_ToArrayFloatGL(proj_inv, (float*)ubo->inv_proj);

	// TODO there's a more efficient way to construct an inverse view matrix
	// from vforward/right/up vectors and origin in g_camera
	Matrix4x4_Invert_Full(view_inv, *args->view);
	Matrix4x4_ToArrayFloatGL(view_inv, (float*)ubo->inv_view);

	// last frame matrices
	static matrix4x4 last_proj, last_view;
	Matrix4x4_ToArrayFloatGL(last_proj, (float*)ubo->last_proj);
	Matrix4x4_ToArrayFloatGL(last_view, (float*)ubo->last_view);
	Matrix4x4_Copy(last_view, *args->view);
	Matrix4x4_Copy(last_proj, *args->projection);

	ubo->ray_cone_width = atanf((2.0f*tanf(DEG2RAD(fov_angle_y) * 0.5f)) / (float)FRAME_HEIGHT);
	ubo->random_seed = (uint32_t)gEngine.COM_RandomLong(0, INT32_MAX);
}

typedef struct {
	const vk_ray_frame_render_args_t* render_args;
	int frame_index;
	const xvk_ray_frame_images_t *current_frame;
	const xvk_ray_frame_images_t *last_frame;
	float fov_angle_y;
	const vk_lights_bindings_t *light_bindings;
} perform_tracing_args_t;

static void performTracing(VkCommandBuffer cmdbuf, const perform_tracing_args_t* args) {
	vk_ray_resources_t res = {
		.width = FRAME_WIDTH,
		.height = FRAME_HEIGHT,
		.resources = {
			[RayResource_tlas] = {
				.type = VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR,
				.value.accel = (VkWriteDescriptorSetAccelerationStructureKHR){
					.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET_ACCELERATION_STRUCTURE_KHR,
					.accelerationStructureCount = 1,
					.pAccelerationStructures = &g_rtx.tlas,
					.pNext = NULL,
				},
			},
#define RES_SET_BUFFER(name, type_, source_, offset_, size_) \
	[RayResource_##name] = { \
		.type = type_, \
		.value.buffer = (VkDescriptorBufferInfo) { \
			.buffer = (source_), \
			.offset = (offset_), \
			.range = (size_), \
		} \
	}
			RES_SET_BUFFER(ubo, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, g_rtx.uniform_buffer.buffer, args->frame_index * g_rtx.uniform_unit_size, sizeof(struct UniformBuffer)),

#define RES_SET_SBUFFER_FULL(name, source_) \
	RES_SET_BUFFER(name, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, source_.buffer, 0, source_.size)
			RES_SET_SBUFFER_FULL(kusochki, g_ray_model_state.kusochki_buffer),
			RES_SET_SBUFFER_FULL(indices, args->render_args->geometry_data),
			RES_SET_SBUFFER_FULL(vertices, args->render_args->geometry_data),
			RES_SET_BUFFER(lights, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, args->light_bindings->buffer, args->light_bindings->metadata.offset, args->light_bindings->metadata.size),
			RES_SET_BUFFER(light_clusters, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, args->light_bindings->buffer, args->light_bindings->grid.offset, args->light_bindings->grid.size),
#undef RES_SET_SBUFFER_FULL
#undef RES_SET_BUFFER

			[RayResource_all_textures] = {
				.type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
				.value.image_array = tglob.dii_all_textures,
			},

			[RayResource_skybox] = {
				.type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
				.value.image = {
					.sampler = vk_core.default_sampler,
					.imageView = tglob.skybox_cube.vk.image.view ? tglob.skybox_cube.vk.image.view : tglob.cubemap_placeholder.vk.image.view,
					.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
				},
			},

#define RES_SET_IMAGE(index, name, ...) \
	[RayResource_##name] = { \
		.type = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, \
		.write = {0}, \
		.read = {0}, \
		.image = &args->current_frame->name, \
	},
			RAY_PRIMARY_OUTPUTS(RES_SET_IMAGE)
			RAY_LIGHT_DIRECT_POLY_OUTPUTS(RES_SET_IMAGE)
			RAY_LIGHT_DIRECT_POINT_OUTPUTS(RES_SET_IMAGE)
			RAY_LIGHT_REFLECT_POLY_OUTPUTS(RES_SET_IMAGE)
			RAY_LIGHT_REFLECT_POINT_OUTPUTS(RES_SET_IMAGE)
			RAY_LIGHT_INDIRECT_POLY_OUTPUTS(RES_SET_IMAGE)
			RAY_LIGHT_INDIRECT_POINT_OUTPUTS(RES_SET_IMAGE)
			RES_SET_IMAGE(-1, denoised)
#undef RES_SET_IMAGE
		},
	};


	DEBUG_BEGIN(cmdbuf, "yay tracing");
	prepareTlas(cmdbuf);
	prepareUniformBuffer(args->render_args, args->frame_index, args->fov_angle_y);

	// 4. Barrier for TLAS build and dest image layout transfer
	{
		VkBufferMemoryBarrier bmb[] = { {
			.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
			.srcAccessMask = VK_ACCESS_ACCELERATION_STRUCTURE_WRITE_BIT_KHR,
			.dstAccessMask = VK_ACCESS_SHADER_READ_BIT,
			.buffer = g_rtx.accels_buffer.buffer,
			.offset = 0,
			.size = VK_WHOLE_SIZE,
		} };
		vkCmdPipelineBarrier(cmdbuf,
			VK_PIPELINE_STAGE_ACCELERATION_STRUCTURE_BUILD_BIT_KHR,
			VK_PIPELINE_STAGE_RAY_TRACING_SHADER_BIT_KHR,
			0, 0, NULL, ARRAYSIZE(bmb), bmb, 0, NULL);
	}


#define BLIT_IMAGES(destination_name, source_name, width_dest, height_dest)\
	{\
		const xvk_blit_args blit_args = {\
			.cmdbuf = cmdbuf,\
			.in_stage = VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,\
			.src = {\
				.image = source_name,\
				.width = FRAME_WIDTH,\
				.height = FRAME_HEIGHT,\
				.oldLayout = VK_IMAGE_LAYOUT_GENERAL,\
				.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,\
			},\
			.dst = {\
				.image = destination_name,\
				.width = width_dest,\
				.height = height_dest,\
				.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,\
				.srcAccessMask = 0,\
			},\
		};\
		blitImage( &blit_args );\
	}

	// blit images from last frame, now for test this is just simple
	if (g_rtx.last_frame_buffers_inited == false && args->frame_index == (MAX_FRAMES_IN_FLIGHT - 1)) {
		g_rtx.last_frame_buffers_inited = true;
	}

	RayPassPerform( cmdbuf, args->frame_index, g_rtx.pass.primary_ray, &res );
	
	{
		//const uint32_t size = sizeof(struct Lights);
		//const uint32_t size = sizeof(struct LightsMetadata); // + 8 * sizeof(uint32_t);
		const VkBufferMemoryBarrier bmb[] = {{
			.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
			.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
			.dstAccessMask = VK_ACCESS_SHADER_READ_BIT,
			.buffer = args->light_bindings->buffer,
			.offset = 0,
			.size = VK_WHOLE_SIZE,
		}};
		vkCmdPipelineBarrier(cmdbuf,
			VK_PIPELINE_STAGE_TRANSFER_BIT,
			VK_PIPELINE_STAGE_RAY_TRACING_SHADER_BIT_KHR,
			0, 0, NULL, ARRAYSIZE(bmb), bmb, 0, NULL);
	}

	RayPassPerform( cmdbuf, args->frame_index, g_rtx.pass.light_direct_poly, &res );
	RayPassPerform( cmdbuf, args->frame_index, g_rtx.pass.light_direct_point, &res );
	RayPassPerform( cmdbuf, args->frame_index, g_rtx.pass.light_reflect_poly, &res );
	RayPassPerform( cmdbuf, args->frame_index, g_rtx.pass.light_reflect_point, &res );
	RayPassPerform( cmdbuf, args->frame_index, g_rtx.pass.light_indirect_poly, &res );
	RayPassPerform( cmdbuf, args->frame_index, g_rtx.pass.light_indirect_point, &res );
	RayPassPerform( cmdbuf, args->frame_index, g_rtx.pass.denoiser_no_denoise, &res );

	BLIT_IMAGES(args->render_args->dst.image, args->current_frame->denoised.image, args->render_args->dst.width, args->render_args->dst.height)

	DEBUG_END(cmdbuf);
}

static void reloadPass( struct ray_pass_s **slot, struct ray_pass_s *new_pass ) {
	if (!new_pass)
		return;

	RayPassDestroy( *slot );
	*slot = new_pass;
}

void VK_RayFrameEnd(const vk_ray_frame_render_args_t* args)
{
	const VkCommandBuffer cmdbuf = args->cmdbuf;
	const xvk_ray_frame_images_t* current_frame = g_rtx.frames + (g_rtx.frame_number % MAX_FRAMES_IN_FLIGHT);
	const xvk_ray_frame_images_t* last_frame = g_rtx.frames + ((g_rtx.frame_number + MAX_FRAMES_IN_FLIGHT - 1) % MAX_FRAMES_IN_FLIGHT);

	ASSERT(vk_core.rtx);
	// ubo should contain two matrices
	// FIXME pass these matrices explicitly to let RTX module handle ubo itself

	RT_LightsFrameEnd();
	const vk_lights_bindings_t light_bindings = VK_LightsUpload(cmdbuf);

	g_rtx.frame_number++;

	// if (vk_core.debug)
	// 	XVK_RayModel_Validate();

	if (g_rtx.reload_pipeline) {
		gEngine.Con_Printf(S_WARN "Reloading RTX shaders/pipelines\n");
		XVK_CHECK(vkDeviceWaitIdle(vk_core.device));


#define PASSES_RELOAD(name, init_func) \
		reloadPass( &g_rtx.pass.name, init_func());
		PASSES_LIST(PASSES_RELOAD)
#undef PASSES_RELOAD

		g_rtx.reload_pipeline = false;
		g_rtx.last_frame_buffers_inited = false;
	}

	if (g_ray_model_state.frame.num_models == 0) {
		const xvk_blit_args blit_args = {
			.cmdbuf = args->cmdbuf,
			.in_stage = VK_PIPELINE_STAGE_TRANSFER_BIT,
			.src = {
				.image = current_frame->denoised.image,
				.width = FRAME_WIDTH,
				.height = FRAME_HEIGHT,
				.oldLayout = VK_IMAGE_LAYOUT_GENERAL,
				.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
			},
			.dst = {
				.image = args->dst.image,
				.width = args->dst.width,
				.height = args->dst.height,
				.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
				.srcAccessMask = 0,
			},
		};

		clearVkImage( cmdbuf, current_frame->denoised.image );
		blitImage( &blit_args );
	} else {
		const perform_tracing_args_t trace_args = {
			.render_args = args,
			.frame_index = (g_rtx.frame_number % MAX_FRAMES_IN_FLIGHT),
			.current_frame = current_frame,
			.last_frame = last_frame,
			.fov_angle_y = args->fov_angle_y,
			.light_bindings = &light_bindings,
		};
		performTracing( cmdbuf, &trace_args );
	}
}

static void denoiserSwitch(void) {
	g_rtx.denoiser_enabled = !g_rtx.denoiser_enabled;
}

static void reloadPipeline( void ) {
	g_rtx.reload_pipeline = true;
}

static void reloadLighting( void ) {
	g_rtx.reload_lighting = true;
}

static void freezeModels( void ) {
	g_ray_model_state.freeze_models = !g_ray_model_state.freeze_models;
}

qboolean VK_RayInit( void )
{
	ASSERT(vk_core.rtx);
	// TODO complain and cleanup on failure

#define PASSES_ASSERT(name, init_func) \
	g_rtx.pass.name = init_func(); \
	ASSERT(g_rtx.pass.name);
	PASSES_LIST(PASSES_ASSERT)
#undef PASSES_ASSERT

	g_rtx.uniform_unit_size = ALIGN_UP(sizeof(struct UniformBuffer), vk_core.physical_device.properties.limits.minUniformBufferOffsetAlignment);

	if (!VK_BufferCreate("ray uniform_buffer", &g_rtx.uniform_buffer, g_rtx.uniform_unit_size * MAX_FRAMES_IN_FLIGHT,
		VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
		VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT | VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT))
	{
		return false;
	}

	if (!VK_BufferCreate("ray accels_buffer", &g_rtx.accels_buffer, MAX_ACCELS_BUFFER,
			VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_STORAGE_BIT_KHR | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
			VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT
		))
	{
		return false;
	}
	g_rtx.accels_buffer_addr = getBufferDeviceAddress(g_rtx.accels_buffer.buffer);
	
	if (!VK_BufferCreate("ray scratch_buffer", &g_rtx.scratch_buffer, MAX_SCRATCH_BUFFER,
			VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_STORAGE_BIT_KHR | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
			VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT
		)) {
		return false;
	}
	g_rtx.scratch_buffer_addr = getBufferDeviceAddress(g_rtx.scratch_buffer.buffer);

	if (!VK_BufferCreate("ray tlas_geom_buffer", &g_rtx.tlas_geom_buffer, sizeof(VkAccelerationStructureInstanceKHR) * MAX_ACCELS * 2,
			VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT |
			VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT_KHR,
			VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT | VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) {
		// FIXME complain, handle
		return false;
	}
	g_rtx.tlas_geom_buffer_addr = getBufferDeviceAddress(g_rtx.tlas_geom_buffer.buffer);
	R_FlippingBuffer_Init(&g_rtx.tlas_geom_buffer_alloc, MAX_ACCELS * 2);

	if (!VK_BufferCreate("ray kusochki_buffer", &g_ray_model_state.kusochki_buffer, sizeof(vk_kusok_data_t) * MAX_KUSOCHKI,
		VK_BUFFER_USAGE_STORAGE_BUFFER_BIT /* | VK_BUFFER_USAGE_TRANSFER_DST_BIT */,
		VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT | VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) {
		// FIXME complain, handle
		return false;
	}
	RT_RayModel_Clear();

	for (int i = 0; i < ARRAYSIZE(g_rtx.frames); ++i) {
#define CREATE_GBUFFER_IMAGE(name, format_, add_usage_bits) \
		do { \
			char debug_name[64]; \
			const xvk_image_create_t create = { \
				.debug_name = debug_name, \
				.width = FRAME_WIDTH, \
				.height = FRAME_HEIGHT, \
				.mips = 1, \
				.layers = 1, \
				.format = format_, \
				.tiling = VK_IMAGE_TILING_OPTIMAL, \
				.usage = VK_IMAGE_USAGE_STORAGE_BIT | add_usage_bits, \
				.has_alpha = true, \
				.is_cubemap = false, \
			}; \
			Q_snprintf(debug_name, sizeof(debug_name), "rtx frames[%d] " # name, i); \
			g_rtx.frames[i].name = XVK_ImageCreate(&create); \
		} while(0)

		CREATE_GBUFFER_IMAGE(denoised, VK_FORMAT_R16G16B16A16_SFLOAT, VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT);

#define rgba8 VK_FORMAT_R8G8B8A8_UNORM
#define rgba32f VK_FORMAT_R32G32B32A32_SFLOAT
#define rgba16f VK_FORMAT_R16G16B16A16_SFLOAT
#define X(index, name, format) CREATE_GBUFFER_IMAGE(name, format, 0);
// TODO better format for normals VK_FORMAT_R16G16B16A16_SNORM
// TODO make sure this format and usage is suppported
		RAY_PRIMARY_OUTPUTS(X)
		RAY_LIGHT_DIRECT_POLY_OUTPUTS(X)
		RAY_LIGHT_DIRECT_POINT_OUTPUTS(X)
		RAY_LIGHT_REFLECT_POLY_OUTPUTS(X)
		RAY_LIGHT_REFLECT_POINT_OUTPUTS(X)
		RAY_LIGHT_INDIRECT_POLY_OUTPUTS(X)
		RAY_LIGHT_INDIRECT_POINT_OUTPUTS(X)
#undef X
#undef rgba8
#undef rgba32f
#undef rgba16f
#undef CREATE_GBUFFER_IMAGE
	}

	gEngine.Cmd_AddCommand("vk_rtx_reload", reloadPipeline, "Reload RTX shader");
	gEngine.Cmd_AddCommand("vk_rtx_reload_rad", reloadLighting, "Reload RAD files for static lights");
	gEngine.Cmd_AddCommand("vk_rtx_freeze", freezeModels, "Freeze models, do not update/add/delete models from to-draw list");
	gEngine.Cmd_AddCommand("vk_rtx_denoiser", denoiserSwitch, "Enable or disable denoiser");

	return true;
}

void VK_RayShutdown( void ) {
	ASSERT(vk_core.rtx);

#define PASSES_DESTROY(name, init_func) \
		RayPassDestroy(g_rtx.pass.name);
	PASSES_LIST(PASSES_DESTROY)
#undef PASSES_DESTROY

	for (int i = 0; i < ARRAYSIZE(g_rtx.frames); ++i) {
		XVK_ImageDestroy(&g_rtx.frames[i].denoised);
#define X(index, name, ...) XVK_ImageDestroy(&g_rtx.frames[i].name);
		RAY_PRIMARY_OUTPUTS(X)
		RAY_LIGHT_DIRECT_POLY_OUTPUTS(X)
		RAY_LIGHT_DIRECT_POINT_OUTPUTS(X)
		RAY_LIGHT_REFLECT_POLY_OUTPUTS(X)
		RAY_LIGHT_REFLECT_POINT_OUTPUTS(X)
		RAY_LIGHT_INDIRECT_POLY_OUTPUTS(X)
		RAY_LIGHT_INDIRECT_POINT_OUTPUTS(X)
#undef X
	}

	if (g_rtx.tlas != VK_NULL_HANDLE)
		vkDestroyAccelerationStructureKHR(vk_core.device, g_rtx.tlas, NULL);

	for (int i = 0; i < ARRAYSIZE(g_ray_model_state.models_cache); ++i) {
		vk_ray_model_t *model = g_ray_model_state.models_cache + i;
		if (model->as != VK_NULL_HANDLE)
			vkDestroyAccelerationStructureKHR(vk_core.device, model->as, NULL);
		model->as = VK_NULL_HANDLE;
	}

	VK_BufferDestroy(&g_rtx.scratch_buffer);
	VK_BufferDestroy(&g_rtx.accels_buffer);
	VK_BufferDestroy(&g_rtx.tlas_geom_buffer);
	VK_BufferDestroy(&g_ray_model_state.kusochki_buffer);
	VK_BufferDestroy(&g_rtx.uniform_buffer);

	if (g_rtx.accels_buffer_alloc)
		aloPoolDestroy(g_rtx.accels_buffer_alloc);
}
