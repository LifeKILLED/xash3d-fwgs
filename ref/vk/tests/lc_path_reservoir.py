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
    ("primary_ray", "lc_bounce"), ("primary_ray", "reflection_path_prepare"),
    ("temporal_reprojection_resolve", "lc_bounce"),
    ("lc_filter", "lc_bounce"), ("lc_filter", "lc_reflection"),
    ("reflection_path_prepare", "reflection_path_claim"),
    ("reflection_path_claim", "lc_reflection"),
    ("lc_reflection", "spatial_reconstruction_pass1"),
    ("lc_bounce", "indiff_sh_init"), ("lc_bounce", "indiff_at1"),
    ("indiff_sh_save", "final_precombine"),
):
    assert passes.index(producer) < passes.index(consumer), (producer, consumer)


def function(name):
    start = source.rfind("\n", 0, source.index(name + "(")) + 1
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end].replace("inout LCReservoir r", "LCReservoir &r")


harness = r"""
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstdint>
using uint = uint32_t;
float min(float a,float b) { return a<b?a:b; }
float max(float a,float b) { return a>b?a:b; }
struct vec2 { float x,y; vec2(float a,float b):x(a),y(b){} };
struct vec4 { float x,y,z,w; vec4(float a,float b,float c,float d):x(a),y(b),z(c),w(d){} };
struct LCReservoir { float sum,count,target; };
__CONFIG__
__HELPERS__
bool close(float a,float b) { return std::abs(a-b)<2e-5f*max(1.f,max(std::abs(a),std::abs(b))); }
int main() {
    // The old selected path was uniform here. Reweight under changed lighting,
    // enumerate both selection outcomes exactly, and compare with the integral.
    const float before[3]={0.f,2.f,9.f}, after[3]={7.f,0.f,1.f};
    for (float oldM : {1.f,64.f,256.f,2560.f}) for (float cap : {1.f,4.f,256.f,640.f,2560.f}) {
        double mean=0;
        for (int old=0;old<3;++old) for (int fresh=0;fresh<3;++fresh) {
            float freshValue=3*after[fresh], historyValue=3*after[old];
            float freshTarget=max(freshValue,1e-6f), historyTarget=max(historyValue,1e-6f);
            float oldTarget=max(3*before[old],1e-6f);
            vec4 h(oldTarget,oldTarget*oldM,oldM,1);
            LCReservoir base{0,0,0};
            assert(lcOffer(base,freshTarget,1,0));
            float mass=h.y*(min(oldM,cap)/oldM)*(historyTarget/oldTarget);
            double probability=double(mass)/(double(base.sum)+mass);
            LCReservoir a=base,b=base;
            assert(lcMergePath(a,h,historyTarget,cap,mass<=base.sum?0.f:0.999999f));
            assert(!lcMergePath(b,h,historyTarget,cap,mass<=base.sum?0.999999f:0.f));
            mean+=(probability*historyValue*lcNormalization(a)+
                (1-probability)*freshValue*lcNormalization(b))/9;
            vec4 stored=lcEncodePath(a,cap);
            LCReservoir decoded{stored.y,stored.z,stored.x};
            assert(close(lcNormalization(a),lcNormalization(decoded)));
            assert(close(stored.w,lcNormalization(decoded)));
        }
        assert(std::abs(mean-8.0)<1e-4);
    }
    // Confidence limits cannot brighten constant estimators.
    LCReservoir r{0,0,0}; lcOffer(r,2,1,0);
    lcMergePath(r,vec4(2,512,256,1),2,4,0);
    assert(close(lcNormalization(r),1));
    // A seed carries the whole path without float bit-pattern/NaN corruption.
    for (uint seed : {0u,1u,65535u,65536u,0x7fc00000u,0xffffffffu})
        assert(lcUnpackPathSeed(lcPackPathSeed(seed))==seed);
    assert(lcMirrorPath(0,1));
    assert(lcMirrorPath(0.003f,0.98f));
    assert(!lcMirrorPath(0.004f,1));
    assert(!lcMirrorPath(0,0.979f));
    // Four-tap median, strict 1.5 ratio, independent 10% rejection boundary.
    assert(!lcRejectPathFirefly(4,vec4(1,100,2,3),0.05f,0));
    assert(!lcRejectPathFirefly(4,vec4(1,100,2,3),0.05f,4));
    assert(lcRejectPathFirefly(4,vec4(1,100,2,3),0.05f,5));
    assert(!lcRejectPathFirefly(3.75f,vec4(1,100,2,3),0.05f,5));
    assert(!lcRejectPathFirefly(4,vec4(1,100,2,3),0.1f,5));
    assert(lcRejectPathFirefly(1,vec4(0,0,0,0),0.05f,5));
    assert(!lcRejectPathFirefly(0,vec4(0,0,0,0),0.05f,5));
    assert(!lcRejectPathFirefly(10,vec4(10,10,10,10),0.05f,5));
    std::puts("Path reservoir tests passed: relighting, black paths, caps, normalization, seed identity.");
}
"""
harness = harness.replace("#include <cstdint>", "#include <cstdint>\n#include <initializer_list>")
harness = harness.replace("__CONFIG__", "\n".join(re.findall(r"^#define LC_PATH_FIREFLY_.*$", source, re.M)))
harness = harness.replace("__HELPERS__", "\n".join(function(name) for name in (
    "lcOffer", "lcNormalization", "lcMergePath", "lcEncodePath", "lcMirrorPath", "lcRejectPathFirefly",
    "lcPackPathSeed", "lcUnpackPathSeed")))
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
