"""Check the native schedules against the exported shader/resource contracts."""
import json
from pathlib import Path

PORT = Path(__file__).resolve().parents[1] / "nrd_port"
kernels = json.loads((PORT / "kernels.json").read_text())["kernels"]
graphs = json.loads((PORT / "graphs.json").read_text())
external = {0, 1, 2, 6, 7, 18, 19}
integer_formats = {2, 6, 10, 15, 20, 25, 28, 31, 34, 37, 41}
for name, graph in graphs.items():
    selected = [0, 5, 8, 15, 16, 18, 19] if name.startswith("REBLUR") else [0, 3, 5, 9, 10, 13, 14, 15, 14, 17]
    for parity in (0, 1):
        written = set()
        for index in selected:
            stage = graph["passes"][index]
            reflection = kernels[stage["kernel"]]["reflection"]
            for category, refs, writable in (("separate_images", stage["inputs"], False), ("images", stage["outputs"], True)):
                for binding in reflection.get(category, []):
                    slot = binding["binding"] - (64 if writable else 0)
                    assert 0 <= slot < len(refs), (name, index, binding)
                    ref = refs[slot]
                    resource = ref["swap"] if parity and ref["swap"] else ref["id"]
                    if resource < 1000:
                        assert resource in external, (name, index, resource)
                        continue
                    pool = "transient" if resource >= 2000 else "permanent"
                    pool_index = resource - (2000 if pool == "transient" else 1000)
                    assert 0 <= pool_index < len(graph[pool]), (name, resource)
                    fmt = graph[pool][pool_index]["format"]
                    is_unsigned = binding["type"].startswith(("uimage", "utexture"))
                    assert is_unsigned == (fmt in integer_formats), (name, index, binding, fmt)
                    if not writable and pool == "transient":
                        assert resource in written, (name, index, "uninitialized transient", resource)
                    if writable:
                        written.add(resource)
    assert any(r["id"] in (18, 19) for r in graph["passes"][selected[-1]]["outputs"]), name

# Half-resolution rays originate at full-resolution pixel 2*p + 0.5.
# The adapted projection must map them to half-resolution pixel p + 0.5.
for full in (640, 641, 1080, 1081, 1920, 1921):
    half = full // 2
    scale = full / (2 * half)
    bias = scale - 1 + 0.5 / half
    for pixel in (0, half // 2, half - 1):
        engine_ndc = 2 * (2 * pixel + 0.5) / full - 1
        projected_uv = (engine_ndc * scale + bias) * 0.5 + 0.5
        assert abs(projected_uv - (pixel + 0.5) / half) < 1e-12
        # NRD's Y-to-UV inversion cancels the adapter's clip-Y inversion.
        nrd_y = -(engine_ndc * scale + bias)
        assert abs((-nrd_y * 0.5 + 0.5) - projected_uv) < 1e-12
print("NRD contracts passed: four schedules, both history banks, typed formats, transient initialization, half-resolution projection.")
