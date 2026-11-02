"""Reproducible HLSL -> SPIR-V -> GLSL port of NRD radiance kernels.
No NRD runtime is linked. Generated code remains covered by NVIDIA's license.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[3]
PIN="8f12a22fc90e6a3c7f5da4c9c3103633c842963a"
MATH_PIN="aa432ad9a80691eb8c3ec4d576bbad5ac100fdc8"
SOURCE=ROOT/"ref/vk/nrd_upstream"
MATH=ROOT/"ref/vk/nrd_mathlib"
OUTPUT=ROOT/"ref/vk/nrd_port/glsl"
BUILD=ROOT/"build/nrd_port"
TOOLS=Path(os.environ.get("VULKAN_SDK","C:/VulkanSDK/1.4.328.1"))/"Bin"
CONFIG="""#define NRD_NORMAL_ENCODING 2
#define NRD_ROUGHNESS_ENCODING 1
#define NRD_SUPPORTS_VIEWPORT_OFFSET 0
#define NRD_SUPPORTS_CHECKERBOARD 0
#define NRD_SUPPORTS_HISTORY_CONFIDENCE 0
#define NRD_SUPPORTS_DISOCCLUSION_THRESHOLD_MIX 0
#define NRD_SUPPORTS_ANTIFIREFLY 1
#define NRD_SUPPORTS_QUAD_INTRINSICS 0
#define REBLUR_PERFORMANCE_MODE 0
"""
NOTICE="""/*
Copyright (c) 2022, NVIDIA CORPORATION. All rights reserved.
This software contains source code provided by NVIDIA Corporation.
GLSL translation of NVIDIA NRD v4.18.0, commit %s.
Derived using DXC and SPIRV-Cross; not an independently licensed implementation.
See ../LICENSE.NVIDIA.txt and ../LICENSE.MathLib.txt.
*/
""" % PIN

def run(args):
    p=subprocess.run([str(a) for a in args],capture_output=True,text=True)
    if p.returncode:
        raise RuntimeError(" ".join(map(str,args))+"\n"+p.stdout+p.stderr)
    return p.stdout

def kernels():
    for algo in ("REBLUR","RELAX"):
        names=(["ClassifyTiles","HitDistReconstruction","PrePass","TemporalAccumulation","HistoryFix","Blur","PostBlur","TemporalStabilization","SplitScreen","Validation"] if algo=="REBLUR" else
               ["ClassifyTiles","HitDistReconstruction","PrePass","TemporalAccumulation","HistoryFix","HistoryClamping","Copy","AntiFirefly","AtrousSmem","Atrous","SplitScreen","Validation"])
        for stage in names:
            signals=(0,) if stage in ("ClassifyTiles","Validation") else (1,2)
            for signal in signals:
                variants=({"MODE_5X5":str(i)} for i in (0,1)) if stage=="HitDistReconstruction" else (({"TEMPORAL_STABILIZATION":str(i)} for i in (0,1)) if stage=="PostBlur" else ({},))
                for extra in variants:
                    defines={"NRD_SIGNAL":str(signal),"NRD_MODE":"0",**extra}
                    name=f"{algo.lower()}_{stage.lower()}_{signal}"+"".join("_"+v for v in extra.values())
                    yield name,algo+"_"+stage+".cs.hlsl",defines

def export(item):
    name,filename,defines=item
    source=SOURCE/"Shaders"/filename
    spv=BUILD/(name+".hlsl.spv")
    glsl=OUTPUT/(name+".comp")
    compiled=BUILD/(name+".glsl.spv")
    args=[TOOLS/"dxc.exe","-spirv","-fspv-target-env=vulkan1.2","-T","cs_6_0","-E","main","-O3",
          "-D","NRD_INTERNAL","-I",BUILD,"-I",MATH,"-fvk-use-dx-layout",
          "-fvk-t-shift","0","0","-fvk-u-shift","64","0","-fvk-b-shift","0","1","-fvk-s-shift","1","1"]
    for key,value in defines.items(): args += ["-D",key+"="+value]
    run(args+[source,"-Fo",spv])
    run([TOOLS/"spirv-val.exe","--target-env","vulkan1.2",spv])
    run([TOOLS/"spirv-cross.exe",spv,"--vulkan-semantics","--version","460","--output",glsl])
    glsl.write_text(NOTICE+glsl.read_text())
    run([TOOLS/"glslc.exe","--target-env=vulkan1.2",glsl,"-o",compiled])
    run([TOOLS/"spirv-val.exe","--target-env","vulkan1.2",compiled])
    reflection=json.loads(run([TOOLS/"spirv-cross.exe",spv,"--reflect"]))
    return {"name":name,"source":filename,"defines":defines,"sha256":hashlib.sha256(glsl.read_bytes()).hexdigest(),"reflection":reflection}

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--jobs",type=int,default=4)
    args=parser.parse_args()
    for directory,pin in ((SOURCE,PIN),(MATH,MATH_PIN)):
        if run(["git","-C",directory,"rev-parse","HEAD"]).strip()!=pin: raise RuntimeError("Wrong upstream revision: "+str(directory))
    OUTPUT.mkdir(exist_ok=True); BUILD.mkdir(parents=True,exist_ok=True)
    (BUILD/"NRDConfig.hlsli").write_text(CONFIG)
    (OUTPUT.parent/"LICENSE.NVIDIA.txt").write_bytes((SOURCE/"LICENSE.txt").read_bytes())
    licenses=list(MATH.glob("LICENSE*"))
    if not licenses: raise RuntimeError("MathLib license missing")
    (OUTPUT.parent/"LICENSE.MathLib.txt").write_bytes(licenses[0].read_bytes())
    items=list(kernels())
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results=list(pool.map(export,items))
    (OUTPUT.parent/"kernels.json").write_text(json.dumps({"nrd_commit":PIN,"mathlib_commit":MATH_PIN,"config":CONFIG,"kernels":results},indent=2)+"\n")
    print(f"Validated {len(results)} HLSL and GLSL kernels; manifest: {OUTPUT.parent/'kernels.json'}")

if __name__=="__main__": main()

