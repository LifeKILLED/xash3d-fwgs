#pragma once

#include "vk_core.h"
#include "vk_devmem.h"

typedef struct vk_buffer_s {
	vk_devmem_t devmem;
	VkBuffer buffer;

	void *mapped;
	uint32_t size;
} vk_buffer_t;

typedef struct {
	vk_buffer_t staging;
} vk_global_buffer_t;

extern vk_global_buffer_t g_vk_buffers;

qboolean VK_BuffersInit( void );
void VK_BuffersDestroy( void );

qboolean VK_BufferCreate(const char *debug_name, vk_buffer_t *buf, uint32_t size, VkBufferUsageFlags usage, VkMemoryPropertyFlags flags);
void VK_BufferDestroy(vk_buffer_t *buf);


//               v -- begin of ring buffer|permanent_size
// |XXXMAPLIFETME|<......|FRAME1|FRAME2|FRAMEN|......................>|
//            busy pos - ^      ^      ^      ^ -- write pos | offset_free
typedef struct {
	uint32_t size;
	uint32_t permanent_size;
	uint32_t offset_free;
	uint32_t free;

	// TODO per-frame offsets for many frames in flight
} vk_ring_buffer_t;

enum { AllocFailed = 0xffffffffu };

// Marks the entire buffer as free
void VK_RingBuffer_Clear(vk_ring_buffer_t* buf);

// Allocates a new aligned region and returns offset to it (-1 if allocation failed)
uint32_t VK_RingBuffer_Alloc(vk_ring_buffer_t* buf, uint32_t size, uint32_t align);

// Fixes everything that has been allocated since Clear as permanent, ring buffer will operate on the remainder only
// Can be called only once since Clear
void VK_RingBuffer_Fix(vk_ring_buffer_t* buf);

// Clears non-permantent part of the buffer
void VK_RingBuffer_ClearFrame(vk_ring_buffer_t* buf);
