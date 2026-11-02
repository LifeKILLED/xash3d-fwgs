/* Native Vulkan execution of NVIDIA NRD-derived GLSL. See nrd_port/LICENSE.NVIDIA.txt. */
#include "VNrd.h"
#include "VBuffer.h"
#include "VBarrier.h"
#include "VDevice.h"
#include "VPipeline.h"
#include "vk_logs.h"
#include <stdio.h>
#include <string.h>
#define LOG_MODULE nrd
typedef struct { unsigned binding,write; } NrdBinding;
typedef struct { const char *name; const uint32_t *code; unsigned bytes; const NrdBinding *bindings; unsigned count,x,y; } NrdKernel;
typedef struct { unsigned id,swap; } NrdReference;
typedef struct { unsigned kernel,inputCount,outputCount; NrdReference inputs[24],outputs[16]; } NrdPass;
typedef struct { const char *name; const NrdPass *passes; unsigned count; } NrdMethod;
#include "nrd_kernels.h"
#define KERNEL_COUNT (sizeof(kernels)/sizeof(kernels[0]))
static struct {
 VkDescriptorSetLayout images[KERNEL_COUNT],common;
 VkPipelineLayout layouts[KERNEL_COUNT];
 VkPipeline pipelines[KERNEL_COUNT];
 VkDescriptorPool pools[2];
 VkSampler samplers[2];
 vk_buffer_t constants[2];
 unsigned cursor,stride,initialized,previousMode[2],previousWidth,previousHeight;
} state;

static void initialize(void) {
 VkDescriptorSetLayoutBinding bindings[3]={
  {0,VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,1,VK_SHADER_STAGE_COMPUTE_BIT,NULL},
  {1,VK_DESCRIPTOR_TYPE_SAMPLER,1,VK_SHADER_STAGE_COMPUTE_BIT,NULL},
  {2,VK_DESCRIPTOR_TYPE_SAMPLER,1,VK_SHADER_STAGE_COMPUTE_BIT,NULL}};
 VkDescriptorSetLayoutCreateInfo li={.sType=VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,.bindingCount=3,.pBindings=bindings};
 XVK_CHECK(vkCreateDescriptorSetLayout(v_device,&li,NULL,&state.common));
 for(unsigned i=0;i<2;i++) {
  VkSamplerCreateInfo si={.sType=VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,.magFilter=i?VK_FILTER_LINEAR:VK_FILTER_NEAREST,.minFilter=i?VK_FILTER_LINEAR:VK_FILTER_NEAREST,.mipmapMode=VK_SAMPLER_MIPMAP_MODE_NEAREST,.addressModeU=VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,.addressModeV=VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,.addressModeW=VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,.maxLod=0};
  XVK_CHECK(vkCreateSampler(v_device,&si,NULL,&state.samplers[i]));
  VkDescriptorPoolSize sizes[]={{VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,1024},{VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,1024},{VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,128},{VK_DESCRIPTOR_TYPE_SAMPLER,256}};
  VkDescriptorPoolCreateInfo pi={.sType=VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,.maxSets=256,.poolSizeCount=4,.pPoolSizes=sizes};
  XVK_CHECK(vkCreateDescriptorPool(v_device,&pi,NULL,&state.pools[i]));
 }
 unsigned alignment=(unsigned)v_device_info.properties.limits.minUniformBufferOffsetAlignment;
 state.stride=(2048+alignment-1)/alignment*alignment;
 for(unsigned i=0;i<2;i++) VK_BufferCreate("NRD constants",&state.constants[i],state.stride*64,VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
 for(unsigned i=0;i<KERNEL_COUNT;i++) {
  const NrdKernel *k=&kernels[i]; VkDescriptorSetLayoutBinding b[64];
  for(unsigned j=0;j<k->count;j++) b[j]=(VkDescriptorSetLayoutBinding){k->bindings[j].binding,k->bindings[j].write?VK_DESCRIPTOR_TYPE_STORAGE_IMAGE:VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,1,VK_SHADER_STAGE_COMPUTE_BIT,NULL};
  li.bindingCount=k->count;li.pBindings=b;
  XVK_CHECK(vkCreateDescriptorSetLayout(v_device,&li,NULL,&state.images[i]));
  VkDescriptorSetLayout sets[]={state.images[i],state.common};
  VkPipelineLayoutCreateInfo pl={.sType=VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,.setLayoutCount=2,.pSetLayouts=sets};
  XVK_CHECK(vkCreatePipelineLayout(v_device,&pl,NULL,&state.layouts[i]));
  VkShaderModule shader=R_VkShaderLoadFromMem(k->code,k->bytes,k->name);
  VkComputePipelineCreateInfo ci={.sType=VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,.stage={.sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,.stage=VK_SHADER_STAGE_COMPUTE_BIT,.module=shader,.pName="main"},.layout=state.layouts[i]};
  XVK_CHECK(vkCreateComputePipelines(v_device,g_pipeline_cache,1,&ci,NULL,&state.pipelines[i]));
  vkDestroyShaderModule(v_device,shader,NULL);
 }
 state.initialized=1;
}

static void dispatch(vk_combuf_t *combuf,unsigned kernel,unsigned slot,unsigned width,unsigned height,const void *constants,r_vk_image_t **input,r_vk_image_t **output) {
 const NrdKernel *k=&kernels[kernel];
 VkDescriptorSetLayout layouts[]={state.images[kernel],state.common}; VkDescriptorSet sets[2];
 VkDescriptorSetAllocateInfo ai={.sType=VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,.descriptorPool=state.pools[slot],.descriptorSetCount=2,.pSetLayouts=layouts};
 XVK_CHECK(vkAllocateDescriptorSets(v_device,&ai,sets));
 VkDescriptorImageInfo images[64]; VkWriteDescriptorSet writes[67];
 Barrier barrier=barrierMake(VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT);
 for(unsigned i=0;i<k->count;i++) {
  const NrdBinding *b=&k->bindings[i]; r_vk_image_t *image=b->write?output[b->binding-64]:input[b->binding];
  ASSERT(image && image->image);
  /* GENERAL permits the read/write aliases used by the original schedules. */
  barrierAddImage(&barrier,(r_vkcombuf_barrier_image_t){image,VK_IMAGE_LAYOUT_GENERAL,b->write?VK_ACCESS_2_SHADER_STORAGE_READ_BIT|VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT:VK_ACCESS_2_SHADER_SAMPLED_READ_BIT});
  images[i]=(VkDescriptorImageInfo){.imageView=image->view,.imageLayout=VK_IMAGE_LAYOUT_GENERAL};
  writes[i]=(VkWriteDescriptorSet){.sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,.dstSet=sets[0],.dstBinding=b->binding,.descriptorCount=1,.descriptorType=b->write?VK_DESCRIPTOR_TYPE_STORAGE_IMAGE:VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,.pImageInfo=&images[i]};
 }
 unsigned offset=state.cursor++*state.stride; ASSERT(state.cursor<=64);
 memcpy((char*)state.constants[slot].mapped+offset,constants,1024);
 VkDescriptorBufferInfo buffer={state.constants[slot].buffer,offset,1024};
 writes[k->count]=(VkWriteDescriptorSet){.sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,.dstSet=sets[1],.dstBinding=0,.descriptorCount=1,.descriptorType=VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,.pBufferInfo=&buffer};
 VkDescriptorImageInfo samplers[2]={{.sampler=state.samplers[0]},{.sampler=state.samplers[1]}};
 for(unsigned i=0;i<2;i++) writes[k->count+1+i]=(VkWriteDescriptorSet){.sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,.dstSet=sets[1],.dstBinding=1+i,.descriptorCount=1,.descriptorType=VK_DESCRIPTOR_TYPE_SAMPLER,.pImageInfo=&samplers[i]};
 vkUpdateDescriptorSets(v_device,k->count+3,writes,0,NULL);
 barrierCommit(&barrier,combuf);
 vkCmdBindPipeline(combuf->cmdbuf,VK_PIPELINE_BIND_POINT_COMPUTE,state.pipelines[kernel]);
 vkCmdBindDescriptorSets(combuf->cmdbuf,VK_PIPELINE_BIND_POINT_COMPUTE,state.layouts[kernel],0,2,sets,0,NULL);
 vkCmdDispatch(combuf->cmdbuf,(width+k->x-1)/k->x,(height+k->y-1)/k->y,1);
}

static r_vk_image_t *resource(const NrdMethod *method,NrdReference reference,unsigned parity,const char *lobe) {
 char name[80]; unsigned id=parity && reference.swap?reference.swap:reference.id;
 if(id>=1000) { snprintf(name,sizeof(name),"%s_%s_%u",method->name,id>=2000?"transient":"permanent",id>=2000?id-2000:id-1000); }
 else { const char *field=NULL;
  switch(id) {case 0:field="motion";break;case 1:field="normal";break;case 2:field="viewz";break;case 6:case 7:field="signal";break;case 18:case 19:field="output";break;default:ASSERT(0);return NULL;}
  snprintf(name,sizeof(name),"%s_%s",lobe,field);
 }
 return R_VkNrdResource(name);
}

/* Bounce pixels represent primary pixels 2*p, not the center of a 2x2 block.
 * Adjust the projection so NRD reconstructs those exact sample positions. */
static void halfProjection(float *projection,unsigned width,unsigned height) {
 float scaleX=(float)width/(2*(width/2)),scaleY=(float)height/(2*(height/2));
 float biasX=scaleX-1.0f+0.5f/(width/2),biasY=scaleY-1.0f+0.5f/(height/2);
 for(unsigned column=0;column<4;column++) {
  projection[column*4]=projection[column*4]*scaleX+projection[column*4+3]*biasX;
  projection[column*4+1]=projection[column*4+1]*scaleY+projection[column*4+3]*biasY;
 }
}

void R_VkNrdDispatch(vk_combuf_t *combuf,const NrdDispatch *args) {
 if(!args->diffuseMode && !args->specularMode) { state.previousMode[0]=state.previousMode[1]=0; return; }
 if(!state.initialized) initialize();
 unsigned slot=args->frameSlot&1;
 XVK_CHECK(vkResetDescriptorPool(v_device,state.pools[slot],0));state.cursor=0;
 R_VkNrdResourcesEnsure(args->frame.width,args->frame.height);
 for(unsigned lobe=0;lobe<2;lobe++) {
  unsigned mode=lobe?args->specularMode:args->diffuseMode;
  if(!mode) {state.previousMode[lobe]=0;continue;}
  const NrdMethod *method=&methods[(mode==2?2:0)+lobe];const char *name=lobe?"spec":"diff";
  NrdFrame frame=args->frame;frame.signal=lobe;
  if(!lobe) {
   halfProjection(frame.projection,frame.width,frame.height);
   halfProjection(frame.previousProjection,frame.previousWidth,frame.previousHeight);
   frame.width/=2;frame.height/=2;frame.previousWidth/=2;frame.previousHeight/=2;
  }
  frame.reset|=state.previousMode[lobe]!=mode || state.previousWidth!=args->frame.width || state.previousHeight!=args->frame.height;
  unsigned char constants[1024]={0};NrdPrepareConstants(&frame,mode==2,constants);
  if(frame.reset) {
   for(unsigned kind=0;kind<2;kind++) for(unsigned i=0;i<32;i++) {
    char poolName[80];snprintf(poolName,sizeof(poolName),"%s_%s_%u",method->name,kind?"transient":"permanent",i);
    r_vk_image_t *image=R_VkNrdResource(poolName);if(!image)break;R_VkImageClear(image,combuf,NULL);
   }
   R_VkImageClear(resource(method,(NrdReference){18,0},0,name),combuf,NULL);
  }
  r_vk_image_t *inputs[32]={args->position,args->normals,args->material,args->previousPosition,lobe?args->specular:args->diffuse,lobe?args->specularRay:args->diffuseRay};
  r_vk_image_t *outputs[16]={resource(method,(NrdReference){1,0},0,name),resource(method,(NrdReference){2,0},0,name),resource(method,(NrdReference){0,0},0,name),resource(method,(NrdReference){6,0},0,name)};
  unsigned char packing[1024]={0};memcpy(packing,args->frame.view,64);unsigned dimensions[]={frame.width,frame.height,!lobe,mode};memcpy(packing+64,dimensions,16);
  dispatch(combuf,KERNEL_COUNT-1,slot,frame.width,frame.height,packing,inputs,outputs);
  for(unsigned i=0;i<method->count;i++) {
   const NrdPass *pass=&method->passes[i];
   for(unsigned j=0;j<pass->inputCount;j++) inputs[j]=resource(method,pass->inputs[j],frame.frame&1,name);
   for(unsigned j=0;j<pass->outputCount;j++) outputs[j]=resource(method,pass->outputs[j],frame.frame&1,name);
   if(mode==2 && i>=5) {unsigned step=1u<<(i-5),last=i+1==method->count;memcpy(constants+744,&step,4);memcpy(constants+748,&last,4);}
   unsigned w=frame.width,h=frame.height;
   if(i==0) {w=((w+15)/16)*kernels[pass->kernel].x;h=((h+15)/16)*kernels[pass->kernel].y;}
   dispatch(combuf,pass->kernel,slot,w,h,constants,inputs,outputs);
  }
  r_vk_image_t *source=resource(method,(NrdReference){18,0},0,name),*dest=lobe?args->specularDestination:args->diffuseDestination;
  Barrier copy=barrierMake(VK_PIPELINE_STAGE_2_TRANSFER_BIT);
  barrierAddImage(&copy,(r_vkcombuf_barrier_image_t){source,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,VK_ACCESS_2_TRANSFER_READ_BIT});
  barrierAddImage(&copy,(r_vkcombuf_barrier_image_t){dest,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,VK_ACCESS_2_TRANSFER_WRITE_BIT});barrierCommit(&copy,combuf);
  VkImageCopy region={.srcSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1},.dstSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1},.extent={frame.width,frame.height,1}};
  vkCmdCopyImage(combuf->cmdbuf,source->image,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,dest->image,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,1,&region);
  state.previousMode[lobe]=mode;
 }
 state.previousWidth=args->frame.width;state.previousHeight=args->frame.height;
}

void R_VkNrdShutdown(void) {
 if(!state.initialized)return;
 vkDeviceWaitIdle(v_device);
 for(unsigned i=0;i<KERNEL_COUNT;i++) {vkDestroyPipeline(v_device,state.pipelines[i],NULL);vkDestroyPipelineLayout(v_device,state.layouts[i],NULL);vkDestroyDescriptorSetLayout(v_device,state.images[i],NULL);}
 for(unsigned i=0;i<2;i++) {vkDestroyDescriptorPool(v_device,state.pools[i],NULL);vkDestroySampler(v_device,state.samplers[i],NULL);VK_BufferDestroy(&state.constants[i]);}
 vkDestroyDescriptorSetLayout(v_device,state.common,NULL);memset(&state,0,sizeof(state));R_VkNrdResourcesShutdown();
}
