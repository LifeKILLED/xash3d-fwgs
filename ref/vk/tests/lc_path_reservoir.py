"""Compile the actual GLSL reservoir helpers and enumerate temporal outcomes.

Run after configuring waf: python ref/vk/tests/lc_path_reservoir.py
Only the inout syntax is translated; selection/normalization code is unchanged.
"""
import os
import json
from pathlib import Path
import re
import runpy
import subprocess

ROOT = Path(__file__).resolve().parents[3]
source = (ROOT / "ref/vk/shaders/lc_independent.glsl").read_text()

# The denoiser toggle must never disable temporal reservoir/cache transport,
# including indirectly through shared history-map generation.
for shader in (ROOT / "ref/vk/shaders").iterdir():
    if shader.suffix in (".glsl", ".comp", ".rgen", ".h") and shader.name not in (
        "asvgf.comp", "ray_interop.h"
    ):
        assert "RENDERER_FLAG_DISABLE_REPROJECTION" not in shader.read_text(), shader

# VMeatpipe dispatches JSON order, not a topological sort. This is a runtime
# dependency regression: reading primary/history maps before their producers
# made the indirect diffuse chain black despite successful SPIR-V compilation.
graph = (ROOT / "ref/vk/shaders/rt.json").read_text()
graph = re.sub(r"//[^\n]*|/\*.*?\*/", "", graph, flags=re.S)
passes = list(json.loads(re.sub(r",\s*([}\]])", r"\1", graph)))
for producer, consumer in (
    ("primary_ray", "lc_bounce"), ("primary_ray", "lc_reflection"),
    ("temporal_reprojection_resolve", "lc_bounce"),
    ("lc_filter", "lc_bounce"), ("lc_filter", "lc_reflection"),
    ("lc_reflection", "spatial_reconstruction_pass1"),
    ("lc_bounce", "indiff_sh_init"), ("lc_bounce", "indiff_at1"),
    ("indiff_sh_save", "final_precombine"),
):
    assert passes.index(producer) < passes.index(consumer), (producer, consumer)


def function(name, code=source):
    start = code.rfind("\n", 0, code.index(name + "(")) + 1
    brace = code.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (code[end] == "{") - (code[end] == "}")
        end += 1
    return code[start:end].replace("inout LCReservoir r", "LCReservoir &r")


harness = r"""
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstdint>
using uint = uint32_t;
using std::isnan;
using std::isinf;
float min(float a,float b) { return a<b?a:b; }
float max(float a,float b) { return a>b?a:b; }
struct vec2 { float x,y; vec2(float a,float b):x(a),y(b){} };
struct vec4 { float x,y,z,w; vec4(float a,float b,float c,float d):x(a),y(b),z(c),w(d){} };
struct LCReservoir { float sum,count,target; };
__CONFIG__
__HELPERS__
bool close(float a,float b) { return std::abs(a-b)<2e-5f*max(1.f,max(std::abs(a),std::abs(b))); }
int main() {
    for (float cap : {1.f,4.f,500.f,2560.f}) {
        LCReservoir r{21,7,3};
        vec4 h=lcEncodePath(r,cap);
        LCReservoir decoded{h.y,h.z,h.x};
        assert(close(lcNormalization(r),lcNormalization(decoded)));
        assert(close(h.w,lcNormalization(decoded)));
    }
    for (uint seed : {0u,1u,8388607u}) assert(uint(float(seed))==seed);
    assert(lcMirrorPath(0,1));
    assert(lcMirrorPath(0.003f,0.98f));
    assert(!lcMirrorPath(0.004f,1));
    assert(!lcMirrorPath(0,0.979f));
    // Normal-incidence, white GGX cannot return per-sample energy above one
    // with a matching NDF proposal. The old roughness-vs-roughness^2 mismatch
    // breaks this bound by tens/hundreds even before temporal reuse.
    for (float roughness : {0.1f,0.2f,0.5f,0.9f}) {
        float alpha=roughness*roughness, brdfA2=alpha*alpha;
        float proposalA2=lcReflectionProposalAlpha2(roughness);
        for (int i=0;i<2048;++i) {
            float u=(i+0.5f)/2048;
            float h2=(1-u)/(1+(proposalA2-1)*u);
            float NoL=2*h2-1;
            if (NoL<=0) continue;
            float proposalDenom=1+(proposalA2-1)*h2;
            float brdfDenom=1+(brdfA2-1)*h2;
            float dRatio=(brdfA2/(brdfDenom*brdfDenom))/
                (proposalA2/(proposalDenom*proposalDenom));
            float G1=2*NoL/(NoL+std::sqrt(brdfA2+(1-brdfA2)*NoL*NoL));
            assert(dRatio*G1<=1.0001f);
        }
    }
    // History replacement is centered on the reprojected texel. Every valid
    // 3x3 neighbor appears exactly once; edges never clamp a choice to center.
    for (int width=1;width<=7;++width) for (int height=1;height<=7;++height)
    for (int y=0;y<height;++y) for (int x=0;x<width;++x) {
        int count=0;
        for (int dy=-1;dy<=1;++dy) for (int dx=-1;dx<=1;++dx)
            if ((dx||dy) && x+dx>=0 && x+dx<width && y+dy>=0 && y+dy<height) ++count;
        if (!count) {
            assert(temporalHistoryNeighbor3x3Index(x,y,width,height,0)==y*width+x);
            continue;
        }
        bool seen[49]={};
        for (int choice=0;choice<count;++choice) {
            int index=temporalHistoryNeighbor3x3Index(x,y,width,height,uint(choice));
            assert(index>=0 && index<width*height && index!=y*width+x && !seen[index]);
            assert(std::abs(index%width-x)<=1 && std::abs(index/width-y)<=1);
            seen[index]=true;
        }
    }
    std::puts("Path reservoir tests passed: caps, normalization, seed identity, GGX PDF, history neighbors.");
}
"""
harness = harness.replace("#include <cstdint>", "#include <cstdint>\n#include <initializer_list>")
harness = harness.replace("__CONFIG__", "\n".join(re.findall(r"^#define LC_PATH_(?:FIREFLY|RELIGHT)_.*$", source, re.M)))
harness = harness.replace("__HELPERS__", "\n".join(function(name) for name in (
    "lcOffer", "lcNormalization", "lcEncodePath", "lcMirrorPath", "lcReflectionProposalAlpha2")) + "\n" +
    function("temporalHistoryNeighbor3x3Index",
             (ROOT / "ref/vk/shaders/temporal_reservoir_rotation.glsl").read_text()))
out = ROOT / "build/shader-test"
out.mkdir(parents=True, exist_ok=True)
cpp = out / "lc_path_reservoir.cpp"
cpp.write_text(harness)
config = runpy.run_path(str(ROOT / "build/c4che/ref/vk_cache.py"))
exe = out / "lc_path_reservoir.exe"
env = os.environ.copy()
env["INCLUDE"] = ";".join(config["INCLUDES"])
env["LIB"] = ";".join(config["LIBPATH"])
subprocess.run(config["CC"] + ["/nologo", "/EHsc", "/std:c++14", str(cpp),
               "/Fo" + str(out / "lc_path_reservoir.obj"), "/Fe" + str(exe)],
               env=env, cwd=out, check=True)
subprocess.run([str(exe)], check=True)
