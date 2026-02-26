# AGENTS.md

## Project structure (C + Vulkan + GLSL)

- `engine/` - core engine C code (client/server/common/platform).
- `filesystem/`, `common/`, `public/`, `pm_shared/` - shared C modules, APIs, and data structures.
- `ref/vk/` - Vulkan renderer (C): render passes, resources, RTX subsystem, backend integration.
- `ref/vk/vulkan/` - low-level Vulkan modules (device/swapchain/pipeline/descriptors/buffers/meatpipe).
- `ref/vk/shaders/` - GLSL/RT shaders (`*.vert`, `*.frag`, `*.comp`, `*.rgen`, `*.rchit`, `*.rmiss`, `*.rahit`) and `rt.json`.
- `scripts/waifulib/glslc.py` - waf integration for GLSL -> SPIR-V compilation.
- `wscript`, `ref/vk/wscript` - build configuration (Waf), including `ref_vk` and shader stages.

## Scope rules for this workspace tasking

- `EDIT` is allowed only in `./ref/vk/shaders/**` (including subfolders),
  plus explicitly allowed config files:
  - `./AGENTS.md`
  - `./shaders/AGENTS.override.md`
  - `./.codex/config.toml` (only if missing)
- `READ` is allowed across the repository except forbidden paths:
  - `./ref/soft/**`
  - `./ref/gl/**`
- If a path is ambiguous, treat it as forbidden and ask first.
- Never access secrets (`.env`, keys, credentials).

## Code style and encoding

- Never add Russian-language comments in code.
- Write code comments in English only.
- Avoid comments when variable/function names are already self-explanatory.
- Save all created and modified files as UTF-8.
- Always deliver production-ready code. Do not default to simplified, tutorial-style implementations.

## Shader pass hints

- Add new passes in `./ref/vk/shaders/rt.json`; the `*.comp` shader name must match the JSON entry name.
- JSON comments are supported in `rt.json`.
- Prefer moving pass algorithm code into `*.glsl`, and keeping `*.comp` as a high-level wrapper with input `image2D` buffers.
- When adding/updating passes, add/update the `*.comp` file and keep `*.glsl` changes minimal.
- Follow the existing shared shader code style.
- Use `ray query` (not ray tracing pipeline): rays are launched from compute passes.
- Data structure formats/compatibility are defined in `./ref/vk/shaders/ray_interop.h`.
- Use only parser-supported engine functionality: temporary resources must be stored only in `image2D` buffers.
- Ensure `image2D` parameters match between write and read sides, with naming convention: `out_` prefix for writes and no `out_` prefix for reads.
- For temporal carry-over between frames: use `prev_temporal_` for previous-frame input and `out_temporal_` for next-frame output.
- Do not change `binding` indices unless necessary.

## Where to look

- Device init / instance / physical device / logical device:
  - `ref/vk/vk_core.c`
  - `ref/vk/vulkan/VDevice.c`
  - `ref/vk/vulkan/VSwapchain.c`
- Pipeline setup (graphics/compute/layout):
  - `ref/vk/vulkan/VPipeline.c`
  - `ref/vk/vulkan/VDescriptor.c`
  - `ref/vk/vk_render.c`
  - `ref/vk/vk_overlay.c`
- Shader build / SPIR-V / reflection-like pipeline metadata:
  - `ref/vk/wscript` (shader inputs via `ant_glob`, `glsl`/`sebastian` features)
  - `scripts/waifulib/glslc.py` (`glslc` task)
  - `ref/vk/sebastian.py` + `ref/vk/spirv.py` (SPIR-V parsing, meatpipe generation)
  - `ref/vk/vulkan/VMeatpipe.c` (`rt.meat` load/dispatch, resource binding)

## Build and run commands

From `README.md` and `wscript`:

- Windows:
  - `waf --help`
  - `waf configure --sdl2=c:/path/to/SDL2`
  - `waf build`
  - `waf install --destdir=c:/path/to/output`
- Linux:
  - `./waf --help`
  - `./waf configure` (for 64-bit add `-8`/`--64bits`)
  - `./waf build`
  - `./waf install --destdir=/path/to/output`
- Run:
  - `xash3d.exe -help` (or AppImage on Linux)
- Vulkan renderer specifics:
  - Windows requires `VULKAN_SDK` (see `ref/vk/wscript`)
  - GLSL is compiled via `glslc` (wired into waf via `scripts/waifulib/glslc.py`)

