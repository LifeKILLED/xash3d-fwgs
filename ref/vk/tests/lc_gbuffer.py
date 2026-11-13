"""Exercise the actual GLSL triangle projection and check G-buffer pass ordering.

Run after configuring waf: python ref/vk/tests/lc_gbuffer.py
"""
import json
import os
from pathlib import Path
import re
import runpy
import subprocess

ROOT = Path(__file__).resolve().parents[3]
SHADERS = ROOT / "ref/vk/shaders"
source = (SHADERS / "lc_gbuffer_raster.comp").read_text()
helpers = source[source.index("float cross2("):source.index("void rasterizeTexel(")]
helpers = helpers.replace("vec2 v[3]=vec2[3](a,b,c);", "vec2 v[3]={a,b,c};")
geometry = (SHADERS / "lightcache_geometry.glsl").read_text()
init_frame = geometry[geometry.index("bool lightcacheIsInitFrame("):geometry.index("uint lightcacheEpoch(")]
surface = geometry[geometry.index("void lightcacheSurface("):geometry.index("bool lightcacheNeighbor(")]
surface = surface.replace("out vec3 P,out vec3 N", "vec3 &P,vec3 &N")
surface = surface.replace("imageLoad(lc_local_position,pix).xyz", "xyz(imageLoad(lc_local_position,pix))")
surface = re.sub(r"(\w+)\.xyz", r"xyz(\1)", surface)

graph = re.sub(r"//[^\n]*|/\*.*?\*/", "", (SHADERS / "rt.json").read_text(), flags=re.S)
passes = list(json.loads(re.sub(r",\s*([}\]])", r"\1", graph)))
chain = ["lc_gbuffer_clear", "lc_gbuffer_raster",
         "lc_update_point", "lc_update_polygon", "lc_filter"]
assert [passes.index(p) for p in chain] == sorted(passes.index(p) for p in chain)

harness = r"""
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstdint>
using uint = uint32_t;
struct vec2 {
    float x,y;
    vec2(float a,float b):x(a),y(b){}
};
struct vec3 {
    float v[3];
    explicit vec3(float a):v{a,a,a}{}
    vec3(float a,float b,float c):v{a,b,c}{}
    float& operator[](int i) { return v[i]; }
    float operator[](int i) const { return v[i]; }
};
struct vec4 {
    float x,y,z,w;
    explicit vec4(float a):x(a),y(a),z(a),w(a){}
    vec4(float a,float b,float c,float d):x(a),y(b),z(c),w(d){}
    vec4(vec3 a,float b):x(a[0]),y(a[1]),z(a[2]),w(b){}
};
struct ivec2 {
    int x,y;
    explicit ivec2(int a):x(a),y(a){}
    ivec2(int a,int b):x(a),y(b){}
};
vec3 xyz(vec4 a) { return {a.x,a.y,a.z}; }
float dot(vec3 a,vec3 b) { return a[0]*b[0]+a[1]*b[1]+a[2]*b[2]; }
float dot(vec4 a,vec4 b) { return a.x*b.x+a.y*b.y+a.z*b.z+a.w*b.w; }
vec3 operator*(vec3 a,float b) { return {a[0]*b,a[1]*b,a[2]*b}; }
void operator+=(vec3 &a,vec3 b) { for (int i=0;i<3;++i) a[i]+=b[i]; }
vec3 normalize(vec3 a) { return a*(1.0f/std::sqrt(dot(a,a))); }
enum { lc_local_position, lc_local_normal };
const int LIGHTCACHE_SIDE=512;
struct {
    struct { uint lightcache_init_frame, frame_counter; } ubo;
} ubo = {};
ivec2 lightcachePixel(uint index,ivec2) { return {int(index%512),int(index/512)}; }
vec4 test_position(0),test_normal(0),test_rows[3]={vec4(0),vec4(0),vec4(0)};
int expected_brush=0,transform_reads=0;
struct TestTransformRows {
    vec4 operator[](uint index) const {
        assert(index/3u==uint(expected_brush));
        ++transform_reads;
        return test_rows[index%3u];
    }
};
struct { TestTransformRows rows; } lc_brush_transforms;
vec4 imageLoad(int image,ivec2 pix) {
    assert(pix.x==0 && pix.y==0);
    return image==lc_local_position ? test_position : test_normal;
}
vec2 operator-(vec2 a,vec2 b) { return {a.x-b.x,a.y-b.y}; }
vec2 operator+(vec2 a,vec2 b) { return {a.x+b.x,a.y+b.y}; }
vec2 operator*(vec2 a,float b) { return {a.x*b,a.y*b}; }
vec3 operator/(vec3 a,float b) { return {a[0]/b,a[1]/b,a[2]/b}; }
float dot(vec2 a,vec2 b) { return a.x*b.x+a.y*b.y; }
float max(float a,float b) { return std::max(a,b); }
float clamp(float x,float a,float b) { return std::max(a,std::min(x,b)); }
vec2 mix(vec2 a,vec2 b,float t) { return a*(1-t)+b*t; }
bool greaterThanEqual(vec3 a,vec3 b) { return a[0]>=b[0] && a[1]>=b[1] && a[2]>=b[2]; }
bool all(bool a) { return a; }
__HELPERS__
__INIT_FRAME__
__SURFACE__
void check(vec2 p,vec2 a,vec2 b,vec2 c,vec2 expected) {
    vec3 w=closestBarycentric(p,a,b,c);
    assert(w[0]>=-1e-6f && w[1]>=-1e-6f && w[2]>=-1e-6f);
    assert(std::abs(w[0]+w[1]+w[2]-1)<1e-5f);
    vec2 q=a*w[0]+b*w[1]+c*w[2];
    assert(dot(q-expected,q-expected)<1e-9f);
    // Reversed winding must recover the same point.
    vec3 r=closestBarycentric(p,c,b,a);
    vec2 reversed=c*r[0]+b*r[1]+a*r[2];
    assert(dot(q-reversed,q-reversed)<1e-9f);
}
int main() {
    vec2 a(0,0),b(2,0),c(0,2);
    check({0.5f,0.5f},a,b,c,{0.5f,0.5f});
    check({1.5f,1.5f},a,b,c,{1,1});
    check({-1,1},a,b,c,{0,1});
    check({1,-1},a,b,c,{1,0});
    check({-1,-1},a,b,c,{0,0});
    check({3,-1},a,b,c,{2,0});
    check({-1,3},a,b,c,{0,2});
    // Subtexel geometry still produces a point on the real face.
    check({0.5f,0.5f},{0.1f,0.1f},{0.2f,0.1f},{0.1f,0.2f},{0.15f,0.15f});
    check({0.5f,0.5f},{0,0},{1,0},{0,0.001f},{0.4994995f,0.0005005005f});
    test_position=vec4(2,3,4,7);
    test_normal=vec4(0,1,0,5);
    expected_brush=5;
    test_rows[0]=vec4(0,-1,0,10);
    test_rows[1]=vec4(1,0,0,20);
    test_rows[2]=vec4(0,0,1,30);
    vec3 P(0),N(0);
    lightcacheSurface(0,P,N);
    assert(transform_reads==3);
    assert(std::abs(P[0]-6.99f)<1e-5f && P[1]==22 && P[2]==34);
    assert(N[0]==-1 && N[1]==0 && N[2]==0);
    test_normal=vec4(0,1,0,0);
    expected_brush=0; transform_reads=0;
    test_rows[0]=vec4(1,0,0,0);
    test_rows[1]=vec4(0,1,0,0);
    test_rows[2]=vec4(0,0,1,0);
    lightcacheSurface(0,P,N);
    assert(transform_reads==3 && P[0]==2 && std::abs(P[1]-3.01f)<1e-5f && P[2]==4);
    assert(N[0]==0 && N[1]==1 && N[2]==0);
    ubo.ubo.lightcache_init_frame=100;
    ubo.ubo.frame_counter=100;
    assert(lightcacheIsInitFrame());
    ubo.ubo.frame_counter=101;
    assert(!lightcacheIsInitFrame());
    ubo.ubo.lightcache_init_frame=102;
    assert(!lightcacheIsInitFrame());
    ubo.ubo.frame_counter=102;
    assert(lightcacheIsInitFrame());
    std::puts("LM G-buffer tests passed: triangle projection, graph order, direct brush lookup, affine transforms, init frame.");
}
""".replace("__HELPERS__", helpers).replace("__SURFACE__", surface).replace("__INIT_FRAME__", init_frame)

out = ROOT / "build/shader-test"
out.mkdir(parents=True, exist_ok=True)
cpp = out / "lc_gbuffer.cpp"
cpp.write_text(harness)
config = runpy.run_path(str(ROOT / "build/c4che/ref/vk_cache.py"))
env = os.environ.copy()
env["INCLUDE"] = ";".join(config["INCLUDES"])
env["LIB"] = ";".join(config["LIBPATH"])
exe = out / "lc_gbuffer.exe"
subprocess.run(config["CC"] + ["/nologo", "/EHsc", "/std:c++14", str(cpp),
               "/Fo" + str(out / "lc_gbuffer.obj"), "/Fe" + str(exe)],
               env=env, cwd=out, check=True)
subprocess.run([str(exe)], check=True)
