"""Compile the checked-in GLSL and embed the native schedules, without NRD tools."""
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[3]
PORT = Path(__file__).resolve().parent

def generate(output):
    sdk = Path(os.environ["VULKAN_SDK"]) / "Bin"
    build = ROOT / "build/nrd_port"
    build.mkdir(parents=True, exist_ok=True)
    kernels = json.loads((PORT / "kernels.json").read_text())["kernels"]
    kernels.append(json.loads((PORT / "frontend.json").read_text()))
    graphs = json.loads((PORT / "graphs.json").read_text())
    lines = ["/* Generated from NRD-derived GLSL. LICENSE.NVIDIA.txt applies. */"]
    definitions = []
    for index, kernel in enumerate(kernels):
        binary = build / (kernel["name"] + ".glsl.spv")
        subprocess.run([str(sdk / "glslc.exe"), "--target-env=vulkan1.2", str(PORT / "glsl" / (kernel["name"] + ".comp")), "-o", str(binary)], check=True)
        subprocess.run([str(sdk / "spirv-val.exe"), "--target-env", "vulkan1.2", str(binary)], check=True)
        code = binary.read_bytes()
        words = struct.unpack("<%dI" % (len(code) // 4), code)
        lines.append("static const uint32_t code%d[]={%s};" % (index, ",".join(hex(w) for w in words)))
        reflection = kernel["reflection"]
        bindings = [(x["binding"], 0) for x in reflection.get("separate_images", [])]
        bindings += [(x["binding"], 1) for x in reflection.get("images", [])]
        lines.append("static const NrdBinding bindings%d[]={%s};" % (index, ",".join("{%d,%d}" % b for b in bindings)))
        group = reflection["entryPoints"][0]["workgroup_size"]
        definitions.append('{"%s",code%d,sizeof(code%d),bindings%d,%d,%d,%d}' % (kernel["name"], index, index, index, len(bindings), group[0], group[1]))
    lines.append("static const NrdKernel kernels[]={" + ",".join(definitions) + "};")
    counts = []
    for index, (name, graph) in enumerate(graphs.items()):
        sequence = [0, 5, 8, 15, 16, 18, 19] if name.startswith("REBLUR") else [0, 3, 5, 9, 10, 13, 14, 15, 14, 17]
        counts.append(len(sequence))
        lines.append("static const NrdPass passes%d[]={" % index)
        for selected in sequence:
            dispatch = graph["passes"][selected]
            encode = lambda refs: ",".join("{%d,%d}" % (r["id"], r["swap"]) for r in refs)
            lines.append("{%d,%d,%d,{%s},{%s}}," % (dispatch["kernel"], len(dispatch["inputs"]), len(dispatch["outputs"]), encode(dispatch["inputs"]), encode(dispatch["outputs"])))
        lines.append("};")
    lines.append("static const NrdMethod methods[]={" + ",".join('{"%s",passes%d,%d}' % (name, i, counts[i]) for i, name in enumerate(graphs)) + "};")
    Path(output).write_text("\n".join(lines))

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    generate(parser.parse_args().output)
