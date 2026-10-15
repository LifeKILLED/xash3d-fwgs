# Direct-light visibility reuse

The experimental path implements Yusuke Tokuyoshi's *Efficient Visibility
Reuse for Real-time ReSTIR* (SIGGRAPH Talks 2024), DOI
https://doi.org/10.1145/3641233.3664320, especially supplementary Algorithm 1
and equations (1)-(4):
https://yusuketokuyoshi.com/papers/2024/Efficient_Visibility_Reuse_for_Real-time_ReSTIR_%28Supplementary_Document%29.pdf

## Console switch

`rt_direct_visibility_reuse` defaults to `1`:

| Value | Behavior |
| --- | --- |
| 0 | Existing direct-light RIS, with existing temporal permutations |
| 1 | Initial RIS plus temporal resampling and weighted visibility (formerly mode 2) |

`rt_di_visibility_history` defaults to `20`: the usual ReSTIR temporal
confidence cap, expressed as a multiple of the current initial candidate count.
The factor 20 comes from Bitterli et al. (2020), section 5:
https://research.nvidia.com/sites/default/files/pubs/2020-07_Spatiotemporal-reservoir-resampling/ReSTIR.pdf
Changing the switch invalidates direct-light reservoir history through a format tag.
The aSVGF history is controlled separately, as before.

For a raw-lighting visual check, enable `rt_direct_visibility_reuse 1` with the
existing commands to disable temporal denoising and `rt_disable_atrous 1`.
Value 0 selects the legacy direct RIS path. Other lighting passes keep their
existing RIS implementation regardless of this switch. Update the rebuilt DLL
and `rt.meat`. The old `rt_di_visibility_reuse` name is no longer registered.
The initial-only mode and spatial visibility-reuse path have been removed. The standard
pipeline compiler and build scripts are unchanged; there is only one graph,
`rt.json`, producing the usual `rt.meat`. The UBO field keeps its existing
name and layout; it now carries a boolean value.

## Correspondence with the publication

- Generate a fresh RIS reservoir without visibility in its target.
- Test the selected initial sample once and zero its contribution weight if
  blocked. Preserve its candidate count even when its weight is zero.
- Merge the temporal reservoir using Talbot MIS (supplementary equation 3).
  Previous surface position, normals and material are stored to evaluate the
  donor target at the fresh sample. The previous camera matrices reconstruct
  the donor's view direction.
- Keep the completed temporal reservoir local and shade that pixel directly.
  This implements the temporal-only subset of the supplementary algorithm;
  its spatial resampling step is omitted.
- Update visibility using the exact same resampling weights, independently of
  which candidate wins. Shade with `f(X) * visibility * W` without a second
  binary gate or the legacy shading-weight clamp.

The replay domain is light ID plus three primary random numbers. Contributions
include the internal area/direction proposal correction, so the replay shift
is identity with unit Jacobian. ReGIR provides the discrete proposal correction.
When ReGIR is explicitly disabled, visibility reuse uses uniform global light proposals.
Always-sampled environment lights and flashlights keep their existing path.

Visibility reuse uses the luminance of the exact unshadowed shaded contribution as the
target for each lobe, including its shading normal. The legacy path keeps its previous
geometry/shading-normal split. A geometry-normal target can approach zero while
the normal-mapped shading contribution stays large, amplifying rare selections;
using the same contribution in the target follows section 3 of the paper.
This is not a claim of unbiased RGB lighting. The paper discusses color
leak when the scalar target is not proportional to each color-channel integrand,
as well as lag under changing visibility. Initial visibility rejection retains
the biased ReSTIR variant described in the supplement.

The paper path does not apply the legacy random reset or ReGIR proposal revert.
It does not introduce A/B reservoirs, texel-fixed visibility, color similarity
rejection, or an independent visibility EMA.

Temporal light-index recovery requires a matching light hash, using the existing
index search window. An unresolved light is rejected instead of attaching the
old sample statistics to an unrelated light occupying its array slot. Animated
lights whose hashes change can therefore lose temporal history.

Both resampling and shading algebraically cancel the explicit inverse target
before evaluating it. This avoids intermediate overflow for very small targets
without clamping weights or radiance. History tags include a format version, so
the older geometry-target histories are not imported after a shader update.

## Resources and checks

With visibility reuse enabled, initial RIS, temporal resampling and final shading run in one
dispatch per light type. The reservoir stays local until its final history
write; there are no intermediate reservoir images or neighbor reads.
With it disabled, the legacy algorithm runs in these same two dispatches.

The metadata image's y/z channels hold
diffuse/specular visibility; w holds the mode tag. Its legacy inverse PDF stays
in x in mode 0. Current/previous metadata travel with their reservoir.

The fused graph retains only the added double-buffered surface metadata:
56 bytes per full-resolution pixel (about 111 MiB at 1920x1080, excluding driver
alignment). Compared with the removed spatial graph's 200 bytes/pixel (about 396 MiB),
this removes ten intermediate images, saving 144 bytes/pixel (about 285 MiB),
two dispatches and the corresponding reservoir writes/reads. Actual allocation
uses the renderer's maximum framebuffer extent, which can exceed the viewport.
Surface history remains allocated when reuse is disabled because both paths share one graph.

`tests/direct_visibility_weights.c` compiles the actual scalar GLSL arithmetic
as C. It checks empty inputs, MIS partition of unity, exact enumeration of a
two-light integral, variance reduction, chained visibility mass, small-target
overflow and the final f/target cancellation. Shader
compilation and SPIR-V validation additionally check both direct-light passes.
`python ref/vk/tests/direct_visibility_graph.py`, after building shaders,
checks their actual reflected bindings: no intermediate images or initial
dispatches, single writers for final reservoirs and surface history, and
56 bytes/pixel of added surface history. Memory savings follow from these
reflected image formats; GPU timing still requires in-game measurement.
GPU scene behavior still needs in-game testing: hard/contact shadows, penumbrae,
camera motion, moving occluders and differently colored lights with unequal
visibility. No scene-level correctness is inferred from compilation alone.
