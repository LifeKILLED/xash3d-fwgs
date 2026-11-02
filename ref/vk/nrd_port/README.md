# REBLUR graph integration

This is a derivative port of NVIDIA NRD 4.18.0, commit
`8f12a22fc90e6a3c7f5da4c9c3103633c842963a`, with MathLib v11,
commit `aa432ad9a80691eb8c3ec4d576bbad5ac100fdc8`.
The NVIDIA license and MathLib notice are preserved in this directory.

## Running

Use the existing renderer build workflow. Update `ref_vk.dll` and
`valve/rt.meat` together: the graph now stores image extent divisors and
compute dispatch geometry (binary version `MEA2`). The normal shader build
compiles `shaders/reblur/*.comp` and includes them in `rt.meat`.
There is no embedded SPIR-V header, native NRD dispatcher, or NRD runtime DLL.

`rt_nrd_bounce 1` selects REBLUR diffuse; `rt_nrd_reflection 1` selects REBLUR
specular. Zero selects the previous denoiser. Results feed ordinary final
composition and `rt_debug_display_only INDIRECT_DIFF` / `INDIRECT_SPEC`.

## Resources and passes

`shaders/rt.json` explicitly lists two independent chains, with prefixes
`reblur_bounce` and `reblur_reflection`:

1. Prepare normal/roughness, view depth, world-space motion, YCoCg radiance
   and normalized first-ray distance.
2. Classify tiles.
3. Prepass.
4. Temporal accumulation.
5. History fix.
6. Blur.
7. Postblur.
8. Temporal stabilization.

The existing `nrd_resolve` node decodes YCoCg and expands the half-resolution
bounce output for the compositor. Bounce applies its primary angular factor
before filtering RGB; it does not use SH. Reflection keeps the existing
separated-specular coloring contract.

All images are declared as formatted float `image2D` in those shaders, using
only the existing `rgba8`, `rgba16f` and `rgba32f` formats.
The ordinary shader parser creates them and the ordinary graph dispatcher
handles descriptors, barriers and launches. There are no REBLUR-specific
texture tables, allocation functions, sampler objects or descriptor pools.

History uses `out_temporal_reblur_bounce_*` / `prev_temporal_reblur_bounce_*`
and `out_temporal_reblur_reflection_*` / `prev_temporal_reblur_reflection_*`.
The normal graph history swapping replaces the former explicit ping/pong
selection. Current-frame consumers read `temporal_*` after its producer.

Point reads use imageLoad. Explicit nearest, bilinear and gather helpers
preserve the reference sampling footprint, channel ordering and clamp-to-edge
behavior. Logical sampling extents come from the frame constants, independently
of the graph image allocation capacity.

## Generic graph metadata

The parser reads the format and name from shader declarations.
Scalar R8 UNORM signals use the red channel of RGBA8. Scalar half-precision
signals and packed normals use RGBA16F. Depth uses RGBA32F. Expanded scalar
writes retain the original missing-channel defaults (0, 0, 1).
Unsigned 8-bit values are stored numerically in RGBA16F; unsigned 16-bit
values are stored numerically in RGBA32F. Full 32-bit bitfields are split
into two numeric 16-bit halves in RGBA32F.x/y and reconstructed on load.
All integer bits remain exact, without encoding arbitrary bit patterns as
floating-point NaNs. Original 8/16-bit truncation is preserved on store.
 Optional
per-pass JSON fields describe the dimensions of created images and launches:

* `image_divisor: [x,y]` divides allocation width/height, rounding up.
* `dispatch_divisor: [x,y]` divides logical frame width/height, rounding down.
* `group_span: [x,y]` overrides pixels covered by one workgroup. Otherwise the
  parser obtains the actual local size from SPIR-V.

All fields default to the existing full-resolution behavior. Bounce uses
image/dispatch divisors of 2. Tile maps use image divisors of 32 for bounce
and 16 for reflection. Tile classification covers 16x16 pixels per group;
its physical local size is 8x4. Regular passes retain their original local sizes.

## CPU constants

`cpu.cpp` only prepares numeric frame constants. The existing `vk_rtx.c`
frame preparation stores them in the existing engine UBO, as two arrays of
64 uvec4 values. Integer bits are preserved. `shaders/reblur/common.glsl`
decodes fields using the exported offsets, including the original row-major
matrix interpretation. No separate GPU constant buffers are created.

Projection preparation retains handedness conversion, camera-relative
coordinates, clip-Y conversion and the exact half-resolution sample position
at primary pixel `2*p`. Enabling a signal, frame discontinuity, or resolution
change restarts its denoiser history without touching the path reservoirs.
Hit-distance normalization uses A=118.11024 world units (3 metres at 1 unit/inch),
B=0.1 and C=20 in both CPU constants and the GPU frontend.

## Checks and regeneration

`python ref/vk/tests/reblur_graph.py` exercises the actual graph serializer
using declaration-only shader stand-ins. It checks formats, dimensions,
producer order, dispatch geometry and all 13 history pairs without compiling
shaders or starting Vulkan. It does not validate shader compilation or image quality.

`python ref/vk/tests/nrd_contract.py` checks the reference schedules and
half-resolution projection math.

`graph_shaders.py` regenerates the graph GLSL from the pinned translations
and reference metadata. It is an offline development tool, not a build/runtime
dependency. `export_shaders.py` can regenerate the original translation using
optional upstream checkouts and DXC/SPIRV-Cross; normal builds need neither.
