# REBLUR graph integration

This is a derivative port of NVIDIA NRD 4.18.0, commit
`8f12a22fc90e6a3c7f5da4c9c3103633c842963a`, with MathLib v11,
commit `aa432ad9a80691eb8c3ec4d576bbad5ac100fdc8`.
The NVIDIA license and MathLib notice are preserved in this directory.

## Running

Use the existing renderer build workflow. Update `ref_vk.dll` and
`valve/rt.meat` together. The graph uses its original `MEAT` binary format
and the unchanged full-screen dispatch. The normal shader build
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

## Full-screen resources and dispatch

The parser reads image formats and names from shader declarations using the
existing formats only. Every image is allocated at the engine's full-screen
allocation size, including bounce buffers and tile maps. The logical used
region comes from the UBO. No per-image or per-pass size fields are added to
`sebastian`, `rt.json` or the `MEAT` binary format.

Scalar R8 UNORM signals use the red channel of RGBA8. Scalar half-precision
signals and packed normals use RGBA16F. Depth uses RGBA32F. Expanded scalar
writes retain the original missing-channel defaults (0, 0, 1).
Unsigned 8-bit values are stored numerically in RGBA16F; unsigned 16-bit
values are stored numerically in RGBA32F. Full 32-bit bitfields are split
into two numeric 16-bit halves in RGBA32F.x/y and reconstructed on load.
All integer bits remain exact, without encoding arbitrary bit patterns as
floating-point NaNs. Original 8/16-bit truncation is preserved on store.

The dispatcher retains `ceil(screenWidth/8) x ceil(screenHeight/8)` groups.
REBLUR retains each kernel's original local size, shared-memory layout and
barriers. CPU-prepared UBO values restrict the active workgroups:

* `reblur_groups_8x8_8x16[signal].xy`: counts for 8x8 pixel coverage (frontend).
* `reblur_groups_8x8_8x16[signal].zw`: counts for 8x16 pixel coverage (regular filter passes).
* `reblur_groups_16x16[signal].xy`: counts for 16x16 pixel coverage (prepass and tile classifier).

Bounce counts use half the logical width and height; reflection uses full
logical resolution. Every surplus workgroup returns uniformly before any
shared-memory operation or barrier. The limits are named fields of the existing engine UBO. No active workgroup
is split or remapped.

## CPU constants

`cpu.cpp` provides `R_VkReblurPrepare`, which fills the existing engine
`UniformBuffer` directly. It creates no constant packet, GPU buffer or local
shader constant object. The shaders read named `ubo.ubo.reblur_*` fields
without decoding or copying an opaque array.

Matrix and vector fields have two entries: signal 0 is bounce, signal 1 is
reflection. Per-signal float/uint scalars are stored as vec2/uvec2 pairs.
Two-component vectors occupy vec4/ivec4/uvec4 array entries to preserve the
same array stride in C and std140. Explicit C padding matches GLSL alignment.
The matrix store helper retains the transposed interpretation expected by
the ported shader arithmetic.

The only persistent calculation state is two smoothed frame-time values.
Camera matrices and filter parameters are calculation locals, written straight
to the UBO rather than accumulated in a separate constants structure.

Projection preparation retains handedness conversion, camera-relative
coordinates, clip-Y conversion and the exact half-resolution sample position
at primary pixel `2*p`. Enabling a signal, frame discontinuity, or resolution
change restarts its denoiser history without touching the path reservoirs.
Hit-distance normalization uses A=118.11024 world units (3 metres at 1 unit/inch),
B=0.1 and C=20 in both CPU constants and the GPU frontend.

## Checks and regeneration

`python ref/vk/tests/reblur_graph.py` exercises the actual graph serializer
using declaration-only shader stand-ins. It checks the original MEAT format,
producer order, UBO group limits and all 13 history pairs without compiling
shaders or starting Vulkan. It does not validate shader compilation or image quality.

`python ref/vk/tests/nrd_contract.py` checks the reference schedules and
half-resolution projection math.

`graph_shaders.py` regenerates the graph GLSL from the pinned translations
and reference metadata. It is an offline development tool, not a build/runtime
dependency. `export_shaders.py` can regenerate the original translation using
optional upstream checkouts and DXC/SPIRV-Cross; normal builds need neither.
