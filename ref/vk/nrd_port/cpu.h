#pragma once
#ifdef __cplusplus
extern "C" {
#endif
struct UniformBuffer;
void R_VkReblurPrepare(struct UniformBuffer *ubo,unsigned signal,unsigned previousWidth,
 unsigned previousHeight,float deltaMilliseconds,int reset);
#ifdef __cplusplus
}
#endif
