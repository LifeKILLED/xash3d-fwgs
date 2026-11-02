/* NVIDIA NRD front-end helpers; LICENSE.NVIDIA.txt applies. */
#include "ml.hlsli"
#include "../nrd_upstream/Shaders/NRD.hlsli"
[[vk::binding(0,0)]] Texture2D<float4> position;
[[vk::binding(1,0)]] Texture2D<float4> normals;
[[vk::binding(2,0)]] Texture2D<float4> material;
[[vk::binding(3,0)]] Texture2D<float4> previousPosition;
[[vk::binding(4,0)]] Texture2D<float4> radiance;
[[vk::binding(5,0)]] Texture2D<float4> direction;
[[vk::binding(64,0)]] RWTexture2D<float4> packedNormal;
[[vk::binding(65,0)]] RWTexture2D<float> packedDepth;
[[vk::binding(66,0)]] RWTexture2D<float4> packedMotion;
[[vk::binding(67,0)]] RWTexture2D<float4> packedSignal;
[[vk::binding(0,1)]] cbuffer Frame { column_major float4x4 view; uint4 dimensions; };
float3 Decode(float2 f) {
 f=f*2-1; float3 n=float3(f,1-abs(f.x)-abs(f.y));
 float t=max(-n.z,0); n.xy-=t*float2(n.x>=0?1:-1,n.y>=0?1:-1); return normalize(n);
}
[numthreads(8,8,1)] void main(uint2 pixel:SV_DispatchThreadID) {
 if(any(pixel>=dimensions.xy))return;
 bool diffuse=dimensions.z!=0; bool relax=dimensions.w==2;
 uint2 source=diffuse?pixel*2:pixel;
 float4 pos=position[source];
 float3 n=Decode(normals[source].zw);
 float roughness=diffuse?1:material[source].x;
 float z=abs(mul(view,float4(pos.xyz,1)).z);
 if(pos.w<=0)z=1e8;
 float4 ray=direction[pixel];
 float hit=diffuse?ray.w:length(ray.xyz);
 float3 color=radiance[pixel].xyz;
 if(diffuse)color*=2*max(dot(n,ray.xyz),0);
 color=clamp(color,0,65504);
 float normHit=REBLUR_FrontEnd_GetNormHitDist(hit,z,float3(118.11024,0.1,20),roughness);
 packedNormal[pixel]=NRD_FrontEnd_PackNormalAndRoughness(n,roughness,0);
 packedDepth[pixel]=z;
 packedMotion[pixel]=float4(previousPosition[source].xyz-pos.xyz,0);
 packedSignal[pixel]=relax?float4(color,min(hit,65504)):REBLUR_FrontEnd_PackRadianceAndNormHitDist(color,normHit,true);
}
