/* NVIDIA NRD-derived pool layout; see ../nrd_port/LICENSE.NVIDIA.txt. */
#include "VNrdResources.h"
#include "VDevice.h"
#include <string.h>
typedef struct { const char *name; VkFormat format; unsigned scale,diffuse; } Description;
static const Description descriptions[]={
{"REBLUR_DIFF_permanent_0",VK_FORMAT_R32_SFLOAT,1,1},
{"REBLUR_DIFF_permanent_1",VK_FORMAT_A2B10G10R10_UNORM_PACK32,1,1},
{"REBLUR_DIFF_permanent_2",VK_FORMAT_R16_UINT,1,1},
{"REBLUR_DIFF_permanent_3",VK_FORMAT_R16G16B16A16_SFLOAT,1,1},
{"REBLUR_DIFF_permanent_4",VK_FORMAT_R16_SFLOAT,1,1},
{"REBLUR_DIFF_permanent_5",VK_FORMAT_R16_SFLOAT,1,1},
{"REBLUR_DIFF_permanent_6",VK_FORMAT_R16_SFLOAT,1,1},
{"REBLUR_DIFF_transient_0",VK_FORMAT_R8_UNORM,1,1},
{"REBLUR_DIFF_transient_1",VK_FORMAT_R8_UINT,1,1},
{"REBLUR_DIFF_transient_2",VK_FORMAT_R16G16B16A16_SFLOAT,1,1},
{"REBLUR_DIFF_transient_3",VK_FORMAT_R16_SFLOAT,1,1},
{"REBLUR_DIFF_transient_4",VK_FORMAT_R8_UNORM,16,1},
{"REBLUR_SPEC_permanent_0",VK_FORMAT_R32_SFLOAT,1,0},
{"REBLUR_SPEC_permanent_1",VK_FORMAT_A2B10G10R10_UNORM_PACK32,1,0},
{"REBLUR_SPEC_permanent_2",VK_FORMAT_R16_UINT,1,0},
{"REBLUR_SPEC_permanent_3",VK_FORMAT_R16G16B16A16_SFLOAT,1,0},
{"REBLUR_SPEC_permanent_4",VK_FORMAT_R16_SFLOAT,1,0},
{"REBLUR_SPEC_permanent_5",VK_FORMAT_R16_SFLOAT,1,0},
{"REBLUR_SPEC_permanent_6",VK_FORMAT_R16_SFLOAT,1,0},
{"REBLUR_SPEC_permanent_7",VK_FORMAT_R16_SFLOAT,1,0},
{"REBLUR_SPEC_permanent_8",VK_FORMAT_R16_SFLOAT,1,0},
{"REBLUR_SPEC_transient_0",VK_FORMAT_R8_UNORM,1,0},
{"REBLUR_SPEC_transient_1",VK_FORMAT_R32_UINT,1,0},
{"REBLUR_SPEC_transient_2",VK_FORMAT_R16_SFLOAT,1,0},
{"REBLUR_SPEC_transient_3",VK_FORMAT_R16G16B16A16_SFLOAT,1,0},
{"REBLUR_SPEC_transient_4",VK_FORMAT_R16_SFLOAT,1,0},
{"REBLUR_SPEC_transient_5",VK_FORMAT_R8_UNORM,16,0},
{"diff_normal",VK_FORMAT_A2B10G10R10_UNORM_PACK32,1,1},
{"diff_viewz",VK_FORMAT_R32_SFLOAT,1,1},
{"diff_motion",VK_FORMAT_R16G16B16A16_SFLOAT,1,1},
{"diff_signal",VK_FORMAT_R16G16B16A16_SFLOAT,1,1},
{"diff_output",VK_FORMAT_R16G16B16A16_SFLOAT,1,1},
{"spec_normal",VK_FORMAT_A2B10G10R10_UNORM_PACK32,1,0},
{"spec_viewz",VK_FORMAT_R32_SFLOAT,1,0},
{"spec_motion",VK_FORMAT_R16G16B16A16_SFLOAT,1,0},
{"spec_signal",VK_FORMAT_R16G16B16A16_SFLOAT,1,0},
{"spec_output",VK_FORMAT_R16G16B16A16_SFLOAT,1,0}
};
#define COUNT (sizeof(descriptions)/sizeof(descriptions[0]))
static r_vk_image_t images[COUNT];
static unsigned previousWidth,previousHeight;
void R_VkNrdResourcesShutdown(void) {
 unsigned i;
 for(i=0;i<COUNT;i++) if(images[i].image) R_VkImageDestroy(&images[i]);
 memset(images,0,sizeof(images)); previousWidth=previousHeight=0;
}
void R_VkNrdResourcesEnsure(unsigned width,unsigned height) {
 unsigned i;
 if(width==previousWidth && height==previousHeight) return;
 if(previousWidth) vkDeviceWaitIdle(v_device);
 R_VkNrdResourcesShutdown();
 for(i=0;i<COUNT;i++) {
 const Description *d=&descriptions[i];
 unsigned w=d->diffuse?width/2:width,h=d->diffuse?height/2:height;
 images[i]=R_VkImageCreate(&(r_vk_image_create_t){
 .debug_name=d->name,.width=(w+d->scale-1)/d->scale,.height=(h+d->scale-1)/d->scale,
 .depth=1,.mips=1,.layers=1,.format=d->format,.tiling=VK_IMAGE_TILING_OPTIMAL,
 .usage=VK_IMAGE_USAGE_SAMPLED_BIT|VK_IMAGE_USAGE_STORAGE_BIT|VK_IMAGE_USAGE_TRANSFER_DST_BIT|VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
 .memory_props=VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT});
 }
 previousWidth=width;previousHeight=height;
}
r_vk_image_t *R_VkNrdResource(const char *name) {
 unsigned i;for(i=0;i<COUNT;i++) if(!strcmp(name,descriptions[i].name)) return &images[i];return NULL;
}
