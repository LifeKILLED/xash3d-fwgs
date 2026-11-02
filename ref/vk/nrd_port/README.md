# REBLUR / RELAX test integration

This is a derivative port of NVIDIA NRD 4.18.0, commit
`8f12a22fc90e6a3c7f5da4c9c3103633c842963a`, with MathLib v11,
commit `aa432ad9a80691eb8c3ec4d576bbad5ac100fdc8`.
The NVIDIA license and MathLib notice are preserved in this directory.
Changing the implementation language does not remove those licenses.

## Running

Build using the existing `python waf build` workflow. Deploy both
`build/ref/vk/ref_vk.dll` and `build/ref/vk/shaders/rt.meat` together using
the normal renderer installation workflow. Restart the game after replacing
the renderer DLL. No NRD DLL, SDK installation, DXC or SPIRV-Cross is needed
to run the port. The ordinary build compiles the included GLSL using the
Vulkan SDK and embeds it into the renderer DLL.

Console switches are independent:

| Cvar | 0 | 1 | 2 |
| --- | --- | --- | --- |
| `rt_nrd_bounce` | Existing denoiser | REBLUR diffuse | RELAX diffuse |
| `rt_nrd_reflection` | Existing denoiser | REBLUR specular | RELAX specular |

Both default to 0. Switching a signal's method clears its denoiser history.
Map/camera discontinuity and resolution changes also restart denoiser history.
These resets do not reset the path reservoirs or light cache.

For REBLUR:

```text
rt_nrd_bounce 1
rt_nrd_reflection 1
rt_debug_display_only INDIRECT_DIFF
```

Switch the view with `rt_debug_display_only INDIRECT_SPEC`. For RELAX, set
both mode cvars to 2. Selected results also feed ordinary final composition;
the previous filters' indirect outputs are bypassed at composition for that
signal. Direct illumination and refraction retain their existing filters.

## Integration boundaries

* `vulkan/VNrdResources.c` owns the temporary native texture pools for the
  four methods, frontend images, and output images. Bounce has half width
  and half height; reflection uses full resolution. Pools are currently
  allocated together when either new denoiser is first enabled.
* `cpu.cpp` owns the CPU constant preparation. Its shared-field offsets are
  checked against the exported shader layouts with static assertions.
  Matrix conversion includes handedness, camera-relative coordinates and
  the engine/NRD clip-Y convention. Bounce's projection accounts for its
  primary sample position at `2*p`, rather than the center of a 2x2 block.
* `vulkan/VNrd.c` owns Vulkan pipelines, descriptors, frame-slot uniform
  storage, history switching and dispatch schedules. It calls no NRD runtime
  functions. `graphs.json` records the reference resource wiring;
  `embed.py` selects the default dense-radiance schedules.
* `VMeatpipe.c` prepares the frame inputs and invokes the native dispatch
  after the `nrd_resources` node in `shaders/rt.json`. The following
  `nrd_resolve` node decodes the filtered signal for the existing compositor.
  The individual internal dispatches are currently owned by the adapter,
  ready for a later migration to native graph nodes.

The GPU frontend consumes world position, previous world position, shading
normal, roughness, raw radiance and first-ray information. It produces
NRD-encoded normal/roughness, positive linear view depth, world-space motion
`previousPosition - currentPosition`, and radiance/hit-distance input.
REBLUR uses YCoCg and normalized first-hit distance; RELAX uses RGB and raw
first-hit distance. Hit-distance normalization uses A=118.11024 world units
(3 metres at 1 unit/inch), B=0.1, C=20 in both frontend and CPU constants.

Bounce resolves its primary angular factor as `2 * max(dot(Nshading,D),0)`
before filtering RGB. It does not use SH. First-hit distance is carried in
`first_bounce_direction.w`, coupled to the reservoir's selected path.
Reflection retains the existing separated-specular material coloring
contract, including its final compositor coloring. The current bounce
resolve expands the half-resolution result using nearest-neighbor sampling;
it does not use the old SH reconstruction.

## Checks

* `python ref/vk/tests/nrd_contract.py` checks the four schedules, descriptor
  indices, typed pool formats, transient initialization, history banks and
  half-resolution projection math, without compiling or starting Vulkan.
* `tests/nrd_vulkan.cpp` is an optional headless check which creates all 47
  native pipelines on available Vulkan devices. It needs the generated
  `build/ref/vk/nrd_kernels.h` include and the Vulkan loader library. It does
  not assess visual quality or run the game.
* `export_shaders.py` is only for regenerating the initial HLSL-to-GLSL
  translation from optional pinned upstream checkouts. Normal builds use the
  checked-in GLSL and vendored CPU headers, not those checkouts.
