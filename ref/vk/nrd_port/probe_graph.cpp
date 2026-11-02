// Build-time extraction of resource wiring from NVIDIA's pinned pass definitions.
// No code from this executable is linked into the renderer.
#include <cstdint>
#include <cstddef>
#include <array>
#include <vector>
#include <string>
#include <cstdio>
#include "../nrd_upstream/Include/NRD.h"
namespace ShaderMake { struct ShaderConstant { const char *name,*value; }; }
#define NRD_MAKE_SHADER_CONSTANT(a,b) {#a,#b}
#define REBLUR_HITDIST_RECONSTRUCTION_PERMUTATION_NUM 4
#define REBLUR_PREPASS_PERMUTATION_NUM 2
#define REBLUR_TEMPORAL_ACCUMULATION_PERMUTATION_NUM 8
#define REBLUR_POST_BLUR_PERMUTATION_NUM 2
#define REBLUR_FORMAT_PREV_VIEWZ Format::R32_SFLOAT
#define REBLUR_FORMAT_PREV_NORMAL_ROUGHNESS Format::R10_G10_B10_A2_UNORM
#define REBLUR_FORMAT_PREV_INTERNAL_DATA Format::R16_UINT
#define REBLUR_FORMAT Format::RGBA16_SFLOAT
#define REBLUR_FORMAT_FAST_HISTORY Format::R16_SFLOAT
#define REBLUR_FORMAT_HITDIST_FOR_TRACKING Format::R16_SFLOAT
#define REBLUR_FORMAT_TILES Format::R8_UNORM
#define REBLUR_DUMMY AsUint(ResourceType::IN_VIEWZ)
#define REBLUR_ADD_VALIDATION_DISPATCH(...)
#define AddDispatch(name,defines) Record(#name,defines)
#define AddDispatchWithArgs(name,defines,...) Record(#name,defines)
namespace nrd {
static constexpr uint32_t PERMANENT_POOL_START=1000,TRANSIENT_POOL_START=2000;
template<class T> uint32_t AsUint(T v){return uint32_t(v);}
struct DenoiserData { struct { ReblurSettings reblur; } settings; uint32_t settingsSize; };
struct InstanceImpl {
std::vector<int> in,inswap,out,outswap;
std::string pass;
void Add_ReblurDiffuse(DenoiserData&); void Add_ReblurSpecular(DenoiserData&);
struct Tex { Format format; uint32_t downsample; };
void AddTextureToPermanentPool(Tex t){printf("T P %u %u\n",uint32_t(t.format),t.downsample);}
void AddTextureToTransientPool(Tex t){printf("T T %u %u\n",uint32_t(t.format),t.downsample);}
void PushPass(const char* n){pass=n;in.clear();inswap.clear();out.clear();outswap.clear();}
void PushInput(uint32_t id,uint32_t swap=0){in.push_back(id);inswap.push_back(swap);}
void PushOutput(uint32_t id,uint32_t swap=0){out.push_back(id);outswap.push_back(swap);}
template<size_t N> void Record(const char* shader,const std::array<ShaderMake::ShaderConstant,N>& defs){
printf("P %s\n",shader);for(auto d:defs)printf("D %s %s\n",d.name,d.value);
for(size_t i=0;i<in.size();i++)printf("I %d %d\n",in[i],inswap[i]);
for(size_t i=0;i<out.size();i++)printf("O %d %d\n",out[i],outswap[i]);
printf("E\n");}
};
}
#include "../nrd_upstream/Source/Denoisers/Reblur_Diffuse.hpp"
#include "../nrd_upstream/Source/Denoisers/Reblur_Specular.hpp"
int main(){nrd::InstanceImpl i;nrd::DenoiserData d;
puts("METHOD REBLUR_DIFF");i.Add_ReblurDiffuse(d);
puts("METHOD REBLUR_SPEC");i.Add_ReblurSpecular(d);
}
