// Headless pipeline smoke test. Does not launch the game or assess image quality.
#include <vulkan/vulkan.h>
#include <cstdio>
#include <cstdint>
#include <vector>
#include <cstdlib>
struct NrdBinding {unsigned binding,write;};
struct NrdKernel {const char *name;const uint32_t *code;unsigned bytes;const NrdBinding *bindings;unsigned count,x,y;};
struct NrdReference {unsigned id,swap;};
struct NrdPass {unsigned kernel,inputCount,outputCount;NrdReference inputs[24],outputs[16];};
struct NrdMethod {const char *name;const NrdPass *passes;unsigned count;};
#include "nrd_kernels.h"
static void check(VkResult r,const char *where) {if(r!=VK_SUCCESS){std::printf("%s: Vulkan error %d\n",where,r);std::exit(1);}}
int main() {
 VkApplicationInfo application={VK_STRUCTURE_TYPE_APPLICATION_INFO};application.apiVersion=VK_API_VERSION_1_3;
 VkInstanceCreateInfo instanceInfo={VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};instanceInfo.pApplicationInfo=&application;
 VkInstance instance;check(vkCreateInstance(&instanceInfo,nullptr,&instance),"instance");
 uint32_t count=0;check(vkEnumeratePhysicalDevices(instance,&count,nullptr),"devices");
 std::vector<VkPhysicalDevice> physical(count);check(vkEnumeratePhysicalDevices(instance,&count,physical.data()),"devices");
 for(auto gpu:physical) {
  VkPhysicalDeviceProperties properties;vkGetPhysicalDeviceProperties(gpu,&properties);
  std::printf("GPU: %s\n",properties.deviceName);
  VkPhysicalDeviceFeatures supported;vkGetPhysicalDeviceFeatures(gpu,&supported);
  if(!supported.shaderStorageImageWriteWithoutFormat || !supported.shaderStorageImageReadWithoutFormat || !supported.shaderStorageImageExtendedFormats) {std::puts("Required format features unavailable");return 1;}
  uint32_t queues=0;vkGetPhysicalDeviceQueueFamilyProperties(gpu,&queues,nullptr);std::vector<VkQueueFamilyProperties> queueProperties(queues);vkGetPhysicalDeviceQueueFamilyProperties(gpu,&queues,queueProperties.data());
  uint32_t family=0;while(family<queues && !(queueProperties[family].queueFlags&VK_QUEUE_COMPUTE_BIT))family++;
  float priority=1;VkDeviceQueueCreateInfo queue={VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};queue.queueFamilyIndex=family;queue.queueCount=1;queue.pQueuePriorities=&priority;
  VkPhysicalDeviceFeatures features={};features.shaderStorageImageReadWithoutFormat=features.shaderStorageImageWriteWithoutFormat=features.shaderStorageImageExtendedFormats=VK_TRUE;
  VkDeviceCreateInfo deviceInfo={VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};deviceInfo.queueCreateInfoCount=1;deviceInfo.pQueueCreateInfos=&queue;deviceInfo.pEnabledFeatures=&features;
  VkDevice device;check(vkCreateDevice(gpu,&deviceInfo,nullptr,&device),"device");
  VkDescriptorSetLayoutBinding commonBindings[]={{0,VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,1,VK_SHADER_STAGE_COMPUTE_BIT,nullptr},{1,VK_DESCRIPTOR_TYPE_SAMPLER,1,VK_SHADER_STAGE_COMPUTE_BIT,nullptr},{2,VK_DESCRIPTOR_TYPE_SAMPLER,1,VK_SHADER_STAGE_COMPUTE_BIT,nullptr}};
  VkDescriptorSetLayoutCreateInfo layoutInfo={VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};layoutInfo.bindingCount=3;layoutInfo.pBindings=commonBindings;
  VkDescriptorSetLayout common;check(vkCreateDescriptorSetLayout(device,&layoutInfo,nullptr,&common),"common layout");
  for(const auto& kernel:kernels) {
   std::vector<VkDescriptorSetLayoutBinding> bindings;
   for(unsigned i=0;i<kernel.count;i++) bindings.push_back({kernel.bindings[i].binding,kernel.bindings[i].write?VK_DESCRIPTOR_TYPE_STORAGE_IMAGE:VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,1,VK_SHADER_STAGE_COMPUTE_BIT,nullptr});
   layoutInfo.bindingCount=(uint32_t)bindings.size();layoutInfo.pBindings=bindings.data();
   VkDescriptorSetLayout images;check(vkCreateDescriptorSetLayout(device,&layoutInfo,nullptr,&images),kernel.name);
   VkDescriptorSetLayout sets[]={images,common};VkPipelineLayoutCreateInfo pipelineLayoutInfo={VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};pipelineLayoutInfo.setLayoutCount=2;pipelineLayoutInfo.pSetLayouts=sets;
   VkPipelineLayout layout;check(vkCreatePipelineLayout(device,&pipelineLayoutInfo,nullptr,&layout),kernel.name);
   VkShaderModuleCreateInfo shaderInfo={VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};shaderInfo.codeSize=kernel.bytes;shaderInfo.pCode=kernel.code;
   VkShaderModule shader;check(vkCreateShaderModule(device,&shaderInfo,nullptr,&shader),kernel.name);
   VkComputePipelineCreateInfo pipelineInfo={VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};pipelineInfo.layout=layout;pipelineInfo.stage.sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;pipelineInfo.stage.stage=VK_SHADER_STAGE_COMPUTE_BIT;pipelineInfo.stage.module=shader;pipelineInfo.stage.pName="main";
   VkPipeline pipeline;check(vkCreateComputePipelines(device,VK_NULL_HANDLE,1,&pipelineInfo,nullptr,&pipeline),kernel.name);
   vkDestroyPipeline(device,pipeline,nullptr);vkDestroyShaderModule(device,shader,nullptr);vkDestroyPipelineLayout(device,layout,nullptr);vkDestroyDescriptorSetLayout(device,images,nullptr);
  }
  vkDestroyDescriptorSetLayout(device,common,nullptr);vkDestroyDevice(device,nullptr);
 }
 vkDestroyInstance(instance,nullptr);std::puts("All 47 native pipelines created successfully.");return count?0:1;
}
