"""Check the actual SPIR-V bindings of the standard DI graph after waf build."""

import os
from pathlib import Path
import runpy
import sys


ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "ref/vk"))


def load_graph():
    previous_argv = sys.argv
    sys.argv = [
        str(ROOT / "ref/vk/sebastian.py"),
        str(ROOT / "ref/vk/shaders/rt.json"),
        "--path", str(ROOT / "build/ref/vk/shaders"),
        "-o", os.devnull,
    ]
    try:
        graph = runpy.run_path(str(ROOT / "ref/vk/sebastian.py"))
    finally:
        sys.argv = previous_argv
    graph["args"].output.close()
    graph["args"].pipelines.close()
    passes = list(graph["pipelines"])
    resources = {b.getResource().name: b.getResource()
                 for p in passes for b in p.bindings()}
    return graph, passes, resources


graph, passes, resources = load_graph()
assert not any(name.startswith("ris_visibility_") for name in resources)
assert not any(p.name.startswith("di_visibility_initial_") for p in passes)

for kind in ("point", "poly"):
    writer = "light_direct_" + kind
    for suffix in ("reservoir", "random", "specular_reservoir", "specular_random",
                   "diffuse_regir_inv_pdf"):
        name = "temporal_ris_" + kind + "_" + suffix
        writers = [p.name for p in passes for b in p.bindings()
                   if b.write and b.getResource().name == name]
        assert writers == [writer], (name, writers)

for name in ("position", "normals", "material"):
    resource_name = "temporal_ris_visibility_" + name
    writers = [p.name for p in passes for b in p.bindings()
               if b.write and b.getResource().name == resource_name]
    assert writers == ["light_direct_point"], (resource_name, writers)
    assert "prev_" + resource_name in resources

format_bytes = {graph["spv"]["ImageFormat"]["Rgba32f"]: 16,
                graph["spv"]["ImageFormat"]["Rgba16f"]: 8,
                graph["spv"]["ImageFormat"]["Rgba8"]: 4}
surface_bytes = sum(format_bytes[r.type.image_format] for name, r in resources.items()
                    if "temporal_ris_visibility_" in name)
assert surface_bytes == 56

print("PASS: standard graph has no initial dispatches or staging images; "
      "reservoirs and surface history have single writers (56 surface bytes/pixel)")
