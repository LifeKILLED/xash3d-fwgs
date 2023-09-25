#include "vk_devmem.h"
#include "alolcator.h"
#include "r_speeds.h"

#define MAX_DEVMEM_ALLOC_SLOTS 16
#define DEFAULT_ALLOCATION_SIZE (64 * 1024 * 1024)

#define MODULE_NAME "devmem"

typedef struct vk_device_memory_slot_s {
	uint32_t type_index;
	VkMemoryPropertyFlags property_flags; // device vs host
	VkMemoryAllocateFlags allocate_flags;
	VkDeviceMemory device_memory;
	VkDeviceSize size;

	void *mapped;
	int refcount;

	struct alo_pool_s *allocator;
} vk_device_memory_slot_t;

typedef struct vk_devmem_allocation_stats_s {
	// Note:
	// `..._current` - Current size or number of allocations which gets updated on every allocation and deallocation.
	// `..._total`   - Total size or number of allocations through the whole program runtime.

	int allocations_current;       // Current number of active (not freed) allocations.
	int allocated_current;         // Current size of allocated memory.
	int allocations_total;         // Total number of memory allocations.
	int allocated_total;           // Total size of allocated memory.
	int frees_total;               // Total number of memory deallocations (frees).
	int freed_total;               // Total size of deallocated (freed) memory.
	int align_holes_current;       // Current number of alignment holes in active (not freed) allocations.
	int align_holes_size_current;  // Current size of alignment holes in active (not freed) allocations.
	int align_holes_total;         // Total number of alignment holes in all of allocations made.
	int align_holes_size_total;    // Total size of alignment holes in all of allocations made.
} vk_devmem_allocation_stats_t;

static struct {
	vk_device_memory_slot_t alloc_slots[MAX_DEVMEM_ALLOC_SLOTS];
	int alloc_slots_count;

	// Size of memory allocated on logical device `VkDevice` 
	// (which is basically bound to physical device `VkPhysicalDevice`).
	int device_allocated;

	// Allocation statistics for each usage type.
	vk_devmem_allocation_stats_t stats[VK_DEVMEM_USAGE_TYPES_COUNT];

	qboolean verbose;
} g_vk_devmem;

// Register allocation in overall stats and for the corresponding type too.
// This is "scalable" approach, which can be simplified if needed.
#define REGISTER_ALLOCATION( type, size, alignment ) { \
	g_vk_devmem.stats[VK_DEVMEM_USAGE_TYPE_ALL].allocations_current += 1; \
	g_vk_devmem.stats[VK_DEVMEM_USAGE_TYPE_ALL].allocated_current   += size; \
	g_vk_devmem.stats[VK_DEVMEM_USAGE_TYPE_ALL].allocations_total   += 1; \
	g_vk_devmem.stats[VK_DEVMEM_USAGE_TYPE_ALL].allocated_total     += size; \
	int alignment_hole = size % alignment; \
	if ( alignment_hole > 0 ) { \
		g_vk_devmem.stats[VK_DEVMEM_USAGE_TYPE_ALL].align_holes_current      += 1; \
		g_vk_devmem.stats[VK_DEVMEM_USAGE_TYPE_ALL].align_holes_size_current += alignment_hole; \
		g_vk_devmem.stats[VK_DEVMEM_USAGE_TYPE_ALL].align_holes_total        += 1; \
		g_vk_devmem.stats[VK_DEVMEM_USAGE_TYPE_ALL].align_holes_size_total   += alignment_hole; \
	} \
	for ( int type_idx = VK_DEVMEM_USAGE_TYPE_ALL + 1; type_idx < VK_DEVMEM_USAGE_TYPES_COUNT; type_idx += 1 ) { \
		if ( type_idx == type ) { \
			g_vk_devmem.stats[type_idx].allocations_current += 1; \
			g_vk_devmem.stats[type_idx].allocated_current   += size; \
			g_vk_devmem.stats[type_idx].allocations_total   += 1; \
			g_vk_devmem.stats[type_idx].allocated_total     += size; \
			if ( alignment_hole > 0 ) { \
				g_vk_devmem.stats[type_idx].align_holes_current      += 1; \
				g_vk_devmem.stats[type_idx].align_holes_size_current += alignment_hole; \
				g_vk_devmem.stats[type_idx].align_holes_total        += 1; \
				g_vk_devmem.stats[type_idx].align_holes_size_total   += alignment_hole; \
			} \
			break; \
		} \
	} \
}

// Register deallocation (freeing) in overall stats and for the corresponding type too.
// This is "scalable" approach, which can be simplified if needed.
#define REGISTER_FREE( type, size, alignment ) \
	g_vk_devmem.stats[VK_DEVMEM_USAGE_TYPE_ALL].allocations_current -= 1; \
	g_vk_devmem.stats[VK_DEVMEM_USAGE_TYPE_ALL].allocated_current   -= size; \
	g_vk_devmem.stats[VK_DEVMEM_USAGE_TYPE_ALL].frees_total         += 1; \
	g_vk_devmem.stats[VK_DEVMEM_USAGE_TYPE_ALL].freed_total         += size; \
	int alignment_hole = size % alignment; \
	if ( alignment_hole > 0 ) { \
		g_vk_devmem.stats[VK_DEVMEM_USAGE_TYPE_ALL].align_holes_current      -= 1; \
		g_vk_devmem.stats[VK_DEVMEM_USAGE_TYPE_ALL].align_holes_size_current -= alignment_hole; \
	} \
	for ( int type_idx = VK_DEVMEM_USAGE_TYPE_ALL + 1; type_idx < VK_DEVMEM_USAGE_TYPES_COUNT; type_idx += 1 ) { \
		if ( type_idx == type ) { \
			g_vk_devmem.stats[type_idx].allocations_current -= 1; \
			g_vk_devmem.stats[type_idx].allocated_current   -= size; \
			g_vk_devmem.stats[type_idx].frees_total         += 1; \
			g_vk_devmem.stats[type_idx].freed_total         += size; \
			break; \
			if ( alignment_hole > 0 ) { \
				g_vk_devmem.stats[type_idx].align_holes_current      -= 1; \
				g_vk_devmem.stats[type_idx].align_holes_size_current -= alignment_hole; \
			} \
		} \
	}


#define VKMEMPROPFLAGS_COUNT 5
#define VKMEMPROPFLAGS_MINSTRLEN (VKMEMPROPFLAGS_COUNT + 1)

// Fills string `out_flags` with characters at each corresponding flag slot.
// Returns number of flags set.
static int VK_MemoryPropertyFlags_String( VkMemoryPropertyFlags flags, char *out_flags, size_t out_flags_size ) {
	ASSERT( out_flags_size >= VKMEMPROPFLAGS_MINSTRLEN );
	int set_flags = 0;
	if ( out_flags_size < VKMEMPROPFLAGS_MINSTRLEN ) {
		out_flags[0] = '\0';
		return set_flags;
	}

	int flag = 0;
	if ( flags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT     )  {out_flags[flag] = 'D'; set_flags += 1;}  else  {out_flags[flag] = '-';}  flag += 1;
	if ( flags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT     )  {out_flags[flag] = 'V'; set_flags += 1;}  else  {out_flags[flag] = '-';}  flag += 1;
	if ( flags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT    )  {out_flags[flag] = 'C'; set_flags += 1;}  else  {out_flags[flag] = '-';}  flag += 1;
	if ( flags & VK_MEMORY_PROPERTY_HOST_CACHED_BIT      )  {out_flags[flag] = '$'; set_flags += 1;}  else  {out_flags[flag] = '-';}  flag += 1;
	if ( flags & VK_MEMORY_PROPERTY_LAZILY_ALLOCATED_BIT )  {out_flags[flag] = 'L'; set_flags += 1;}  else  {out_flags[flag] = '-';}  flag += 1;
	// VK_MEMORY_PROPERTY_PROTECTED_BIT
	// VK_MEMORY_PROPERTY_DEVICE_COHERENT_BIT_AMD
	// VK_MEMORY_PROPERTY_DEVICE_UNCACHED_BIT_AMD
	// VK_MEMORY_PROPERTY_RDMA_CAPABLE_BIT_NV
	out_flags[flag] = '\0';

	return set_flags;
}

#define VKMEMALLOCFLAGS_COUNT 3
#define VKMEMALLOCFLAGS_MINSTRLEN (VKMEMALLOCFLAGS_COUNT + 1)

// Fills string `out_flags` with characters at each corresponding flag slot.
// Returns number of flags set.
static int VK_MemoryAllocateFlags_String( VkMemoryAllocateFlags flags, char *out_flags, size_t out_flags_size ) {
	ASSERT( out_flags_size >= VKMEMALLOCFLAGS_MINSTRLEN );
	int set_flags = 0;
	if ( out_flags_size < VKMEMALLOCFLAGS_MINSTRLEN ) {
		out_flags[0] = '\0';
		return set_flags;
	}

	int flag = 0;
	if ( flags & VK_MEMORY_ALLOCATE_DEVICE_MASK_BIT                   )  {out_flags[flag] = 'M'; set_flags += 1;}  else  {out_flags[flag] = '-';}  flag += 1;
	if ( flags & VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT                )  {out_flags[flag] = 'A'; set_flags += 1;}  else  {out_flags[flag] = '-';}  flag += 1;
	if ( flags & VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_CAPTURE_REPLAY_BIT )  {out_flags[flag] = 'R'; set_flags += 1;}  else  {out_flags[flag] = '-';}  flag += 1;
	out_flags[flag] = '\0';

	return set_flags;
}

static int findMemoryWithType(uint32_t type_index_bits, VkMemoryPropertyFlags flags) {
	VkPhysicalDeviceMemoryProperties properties = vk_core.physical_device.memory_properties2.memoryProperties;
	for ( int type = 0; type < (int)properties.memoryTypeCount; type += 1 ) {
		if ( !( type_index_bits & ( 1 << type ) ) )
			continue;

		if ( ( properties.memoryTypes[type].propertyFlags & flags ) == flags )
			return type;
	}

	return UINT32_MAX;
}

static VkDeviceSize optimalSize(VkDeviceSize size) {
	if ( size < DEFAULT_ALLOCATION_SIZE )
		return DEFAULT_ALLOCATION_SIZE;

	// TODO:
	// 1. have a way to iterate for smaller sizes if allocation failed
	// 2. bump to nearest power-of-two-ish based size (e.g. a multiple of 32Mb or something)

	return size;
}

static int allocateDeviceMemory(VkMemoryRequirements req, int type_index, VkMemoryAllocateFlags allocate_flags) {
	if ( g_vk_devmem.alloc_slots_count == MAX_DEVMEM_ALLOC_SLOTS ) {
		gEngine.Host_Error( "Ran out of device memory allocation slots\n" );
		return -1;
	}

	{
		const VkMemoryAllocateFlagsInfo mafi = {
			.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO,
			.flags = allocate_flags,
		};

		const VkMemoryAllocateInfo mai = {
			.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
			.pNext = allocate_flags ? &mafi : NULL,
			.allocationSize = optimalSize(req.size),
			.memoryTypeIndex = type_index,
		};

		if ( g_vk_devmem.verbose ) {
			char allocate_flags_str[VKMEMALLOCFLAGS_MINSTRLEN];
			VK_MemoryAllocateFlags_String( allocate_flags, &allocate_flags_str[0], sizeof( allocate_flags_str ) );
			unsigned long long size = (unsigned long long) mai.allocationSize;
			gEngine.Con_Reportf( "  ^3->^7 ^6AllocateDeviceMemory:^7 { size: %llu, memoryTypeBits: 0x%x, allocate_flags: %s => typeIndex: %d }\n",
				size, req.memoryTypeBits, allocate_flags_str, mai.memoryTypeIndex );
		}
		ASSERT( mai.memoryTypeIndex != UINT32_MAX );

		vk_device_memory_slot_t *slot = &g_vk_devmem.alloc_slots[g_vk_devmem.alloc_slots_count];
		XVK_CHECK( vkAllocateMemory( vk_core.device, &mai, NULL, &slot->device_memory ) );

		VkPhysicalDeviceMemoryProperties properties = vk_core.physical_device.memory_properties2.memoryProperties;
		slot->property_flags = properties.memoryTypes[mai.memoryTypeIndex].propertyFlags;
		slot->allocate_flags = allocate_flags;
		slot->type_index     = mai.memoryTypeIndex;
		slot->refcount       = 0;
		slot->size           = mai.allocationSize;

		g_vk_devmem.device_allocated += mai.allocationSize;

		const int expected_allocations = 0;
		const int min_alignment = 16;
		slot->allocator = aloPoolCreate( slot->size, expected_allocations, min_alignment );

		if ( slot->property_flags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT ) {
			XVK_CHECK( vkMapMemory( vk_core.device, slot->device_memory, 0, slot->size, 0, &slot->mapped ) );
			if ( g_vk_devmem.verbose ) {
				size_t size          = (size_t) slot->size;
				size_t device        = (size_t) vk_core.device;
				size_t device_memory = (size_t) slot->device_memory;
				// `z` - specifies `size_t` length
				gEngine.Con_Reportf( "  ^3->^7 ^6Mapped:^7 { device: 0x%zx, device_memory: 0x%zx, size: %zu }\n",
					device, device_memory, size );
			}
		} else {
			slot->mapped = NULL;
		}
	}

	return g_vk_devmem.alloc_slots_count++;
}

vk_devmem_t VK_DevMemAllocate(const char *name, vk_devmem_usage_type_t usage_type, vk_devmem_allocate_args_t devmem_allocate_args) {
	VkMemoryRequirements  req            = devmem_allocate_args.requirements;
	VkMemoryPropertyFlags property_flags = devmem_allocate_args.property_flags;
	VkMemoryAllocateFlags allocate_flags = devmem_allocate_args.allocate_flags;
	
	vk_devmem_t devmem = { .usage_type = usage_type };
	const int type_index = findMemoryWithType(req.memoryTypeBits, property_flags);

	if ( g_vk_devmem.verbose ) {
		char property_flags_str[VKMEMPROPFLAGS_MINSTRLEN];
		char allocate_flags_str[VKMEMALLOCFLAGS_MINSTRLEN];
		VK_MemoryPropertyFlags_String( property_flags, &property_flags_str[0], sizeof( property_flags_str ) );
		VK_MemoryAllocateFlags_String( allocate_flags, &allocate_flags_str[0], sizeof( allocate_flags_str ) );

		const char *usage_type_str = VK_DevMemUsageTypeString( usage_type );

		unsigned long long req_size      = (unsigned long long) req.size;
		unsigned long long req_alignment = (unsigned long long) req.alignment;
		gEngine.Con_Reportf( "^3VK_DevMemAllocate:^7 { name: \"%s\", usage: %s, size: %llu, alignment: %llu, memoryTypeBits: 0x%x, property_flags: %s, allocate_flags: %s => type_index: %d }\n",
			name, usage_type_str, req_size, req_alignment, req.memoryTypeBits, property_flags_str, allocate_flags_str, type_index );
	}

	if ( vk_core.rtx ) {
		// TODO this is needed only for the ray tracer and only while there's no proper staging
		// Once staging is established, we can avoid forcing this on every devmem allocation
		allocate_flags |= VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT_KHR;
	}

	alo_block_t block;
	int slot_index = -1;
	for ( int _slot_index = 0 ; _slot_index < g_vk_devmem.alloc_slots_count; _slot_index += 1 ) {
		vk_device_memory_slot_t *const slot = g_vk_devmem.alloc_slots + _slot_index;
		if ( slot->type_index != type_index )
			continue;

		if ( (slot->allocate_flags & allocate_flags ) != allocate_flags )
			continue;

		if ( ( slot->property_flags & property_flags ) != property_flags )
			continue;

		block = aloPoolAllocate( slot->allocator, req.size, req.alignment );
		if ( block.size == 0 )
			continue;

		slot_index = _slot_index;
		break;
	}

	if ( slot_index < 0 ) {
		slot_index = allocateDeviceMemory( req, type_index, allocate_flags );
		ASSERT( slot_index >= 0 );
		if ( slot_index < 0 )
			return devmem;

		struct alo_pool_s *allocator = g_vk_devmem.alloc_slots[slot_index].allocator;
		block = aloPoolAllocate( allocator, req.size, req.alignment );
		ASSERT( block.size != 0 );
	}

	{
		vk_device_memory_slot_t *const slot = g_vk_devmem.alloc_slots + slot_index;
		devmem.device_memory = slot->device_memory;
		devmem.offset        = block.offset;
		devmem.mapped        = slot->mapped ? (char *)slot->mapped + block.offset : NULL;

		if (g_vk_devmem.verbose) {
			gEngine.Con_Reportf("  ^3->^7 Allocated: { slot: %d, block: %d, offset: %d, size: %d }\n", 
			slot_index, block.index, (int)block.offset, (int)block.size);
		}

		slot->refcount++;
		devmem._slot_index      = slot_index;
		devmem._block_index     = block.index;
		devmem._block_size      = block.size;
		devmem._block_alignment = req.alignment;

		REGISTER_ALLOCATION( usage_type, block.size, req.alignment );

		return devmem;
	}
}

void VK_DevMemFree(const vk_devmem_t *mem) {
	ASSERT( mem->_slot_index >= 0 );
	ASSERT( mem->_slot_index < g_vk_devmem.alloc_slots_count );

	int slot_index = mem->_slot_index;
	vk_device_memory_slot_t *const slot = g_vk_devmem.alloc_slots + slot_index;
	ASSERT( mem->device_memory == slot->device_memory );

	if ( g_vk_devmem.verbose ) {
		const char *usage_type = VK_DevMemUsageTypeString( mem->usage_type );
		int align_hole = mem->_block_size % mem->_block_alignment;
		gEngine.Con_Reportf( "^2VK_DevMemFree:^7 { slot: %d, block: %d, usage: %s, size: %d, alignment: %d, hole: %d }\n",
			slot_index, mem->_block_index, usage_type, mem->_block_size, mem->_block_alignment, align_hole );
	}

	aloPoolFree( slot->allocator, mem->_block_index );

	REGISTER_FREE( mem->usage_type, mem->_block_size, mem->_block_alignment );

	slot->refcount--;
}

// Little helper macro to turn anything into string.
#define STRING( str ) #str

// Register single stats variable.
#define REGISTER_STATS_METRIC( var, metric_name, var_name, metric_type ) \
	R_SpeedsRegisterMetric( &(var), MODULE_NAME, metric_name, metric_type, /*reset*/ false, var_name, __FILE__, __LINE__ );

// NOTE(nilsoncore): I know, this is a mess... Sorry.
// It could have been avoided by having short `VK_DevMemUsageTypes` enum names,
// but I have done it this way because I want those enum names to be as descriptive as possible.
// This basically replaces those enum names with ones provided by suffixes, which are just their endings. 
#define REGISTER_STATS_METRICS( usage_type, usage_suffix ) { \
 	REGISTER_STATS_METRIC( g_vk_devmem.stats[usage_type].allocations_current, STRING( allocations_current##usage_suffix ), STRING( g_vk_devmem.stats[usage_suffix].allocations_current ), kSpeedsMetricCount ); \
 	REGISTER_STATS_METRIC( g_vk_devmem.stats[usage_type].allocated_current, STRING( allocated_current##usage_suffix ), STRING( g_vk_devmem.stats[usage_suffix].allocated_current ), kSpeedsMetricBytes ); \
 	REGISTER_STATS_METRIC( g_vk_devmem.stats[usage_type].allocations_total, STRING( allocations_total##usage_suffix ), STRING( g_vk_devmem.stats[usage_suffix].allocations_total ), kSpeedsMetricCount ); \
 	REGISTER_STATS_METRIC( g_vk_devmem.stats[usage_type].allocated_total, STRING( allocated_total##usage_suffix ), STRING( g_vk_devmem.stats[usage_suffix].allocated_total ), kSpeedsMetricBytes ); \
 	REGISTER_STATS_METRIC( g_vk_devmem.stats[usage_type].frees_total, STRING( frees_total##usage_suffix ), STRING( g_vk_devmem.stats[usage_suffix].frees_total ), kSpeedsMetricCount ); \
 	REGISTER_STATS_METRIC( g_vk_devmem.stats[usage_type].freed_total, STRING( freed_total##usage_suffix ), STRING( g_vk_devmem.stats[usage_suffix].freed_total ), kSpeedsMetricBytes ); \
 	REGISTER_STATS_METRIC( g_vk_devmem.stats[usage_type].align_holes_current, STRING( align_holes_current##usage_suffix ), STRING( g_vk_devmem.stats[usage_suffix].align_holes_current ), kSpeedsMetricCount ); \
 	REGISTER_STATS_METRIC( g_vk_devmem.stats[usage_type].align_holes_size_current, STRING( align_holes_size_current##usage_suffix ), STRING( g_vk_devmem.stats[usage_suffix].align_holes_size_current ), kSpeedsMetricBytes ); \
 	REGISTER_STATS_METRIC( g_vk_devmem.stats[usage_type].align_holes_total, STRING( align_holes_total##usage_suffix ), STRING( g_vk_devmem.stats[usage_suffix].align_holes_total ), kSpeedsMetricCount ); \
 	REGISTER_STATS_METRIC( g_vk_devmem.stats[usage_type].align_holes_size_total, STRING( align_holes_size_total##usage_suffix ), STRING( g_vk_devmem.stats[usage_suffix].align_holes_size_total ), kSpeedsMetricBytes ); \
}

qboolean VK_DevMemInit( void ) {
	g_vk_devmem.verbose = gEngine.Sys_CheckParm( "-vkdebugmem" );

	// Register standalone metrics.
	R_SPEEDS_METRIC( g_vk_devmem.alloc_slots_count, "allocated_slots", kSpeedsMetricCount );
	R_SPEEDS_METRIC( g_vk_devmem.device_allocated, "device_allocated", kSpeedsMetricBytes );
	
	// Register stats metrics for each usage type.
	// Maybe these metrics should be enabled by `-vkdebugmem` too?
	REGISTER_STATS_METRICS( VK_DEVMEM_USAGE_TYPE_ALL, _ALL );
	REGISTER_STATS_METRICS( VK_DEVMEM_USAGE_TYPE_BUFFER, _BUFFER );
	REGISTER_STATS_METRICS( VK_DEVMEM_USAGE_TYPE_IMAGE, _IMAGE );
	
	return true;
}

// NOTE(nilsoncore):
// It has to be undefined only after `VK_DevMemInit` because
// otherwise the function would not know what this is.
#undef STRING

void VK_DevMemDestroy( void ) {
	for ( int slot_index = 0; slot_index < g_vk_devmem.alloc_slots_count; slot_index += 1 ) {
		const vk_device_memory_slot_t *const slot = g_vk_devmem.alloc_slots + slot_index;
		ASSERT( slot->refcount == 0 );

		// TODO check that everything has been freed
		aloPoolDestroy( slot->allocator );

		if ( slot->mapped )
			vkUnmapMemory( vk_core.device, slot->device_memory );

		vkFreeMemory( vk_core.device, slot->device_memory, NULL );
	}

	g_vk_devmem.alloc_slots_count = 0;
}

const char *VK_DevMemUsageTypeString( vk_devmem_usage_type_t type ) {
	ASSERT( type >= VK_DEVMEM_USAGE_TYPE_ALL );
	ASSERT( type < VK_DEVMEM_USAGE_TYPES_COUNT );

	switch ( type ) {
		case VK_DEVMEM_USAGE_TYPE_ALL:     return "ALL";
		case VK_DEVMEM_USAGE_TYPE_BUFFER:  return "BUFFER";
		case VK_DEVMEM_USAGE_TYPE_IMAGE:   return "IMAGE";
	}

	return "(unknown)";
}
