# AGENTS.override.md

## Scope (strict)

- `EDITS ONLY HERE`: `./ref/vk/shaders/**`
- Do not edit source files outside `./ref/vk/shaders/**`.
- Do not commit.

## READ policy

- Reading is allowed across the repository, EXCEPT:
  - `./ref/soft/**`
  - `./ref/gl/**`
- If a path is unclear or may overlap forbidden areas, treat it as forbidden and ask first.

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

## Workflow

1. Before editing, explicitly list target files in `./ref/vk/shaders/**`.
2. Apply changes only to the listed files.
3. Diff output after edits is optional (review in IDE/Git view is acceptable).
4. Do not run commit/amend/rebase/reset.

