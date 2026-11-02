#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
 float projection[16],previousProjection[16],view[16],previousView[16];
 float deltaMilliseconds,jitter[2],previousJitter[2];
 unsigned width,height,previousWidth,previousHeight,frame,reset,signal;
} NrdFrame;
void NrdPrepareConstants(const NrdFrame *frame,int relax,void *data);
#ifdef __cplusplus
}
#endif
