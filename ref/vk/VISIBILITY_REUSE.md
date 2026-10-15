# Direct-light visibility reuse

The experimental path implements Yusuke Tokuyoshi's *Efficient Visibility
Reuse for Real-time ReSTIR* (SIGGRAPH Talks 2024), DOI
https://doi.org/10.1145/3641233.3664320, especially supplementary Algorithm 1
and equations (1)-(4):
https://yusuketokuyoshi.com/papers/2024/Efficient_Visibility_Reuse_for_Real-time_ReSTIR_%28Supplementary_Document%29.pdf

## Console modes

`rt_di_visibility_reuse` defaults to `0`:

| Value | Behavior |
| --- | --- |
| 0 | Existing direct-light RIS, with existing temporal permutations |
| 1 | Unshadowed initial RIS, shadow ray for each lobe's winner, no history |
| 2 | Mode 1 plus temporal resampling and weighted visibility |
| 3 | Mode 2 plus spatial resampling and a fresh spatial shadow ray |

`rt_di_visibility_history` defaults to `20`: the usual ReSTIR temporal
confidence cap, expressed as a multiple of the current initial candidate count.
The factor 20 comes from Bitterli et al. (2020), section 5:
https://research.nvidia.com/sites/default/files/pubs/2020-07_Spatiotemporal-reservoir-resampling/ReSTIR.pdf
Changing modes invalidates direct-light reservoir history through a mode tag.
The aSVGF history is controlled separately, as before.

For the first visual check, use mode 1, then 2, then 3, with the existing
commands to disable temporal denoising and `rt_disable_atrous 1`.
Mode 0 is the comparison/fallback. Reload both the rebuilt DLL and `rt.meat`.

## Correspondence with the publication

- Generate a fresh RIS reservoir without visibility in its target.
- Test the selected initial sample once and zero its contribution weight if
  blocked. Preserve its candidate count even when its weight is zero.
- Merge the temporal reservoir using Talbot MIS (supplementary equation 3).
  Previous surface position, normals and material are stored to evaluate the
  donor target at the fresh sample. The previous camera matrices reconstruct
  the donor's view direction.
- Read completed temporal reservoirs in a second GPU dispatch. Choose one
  spatial neighbor with the existing shifted XOR-3 permutation. Reuse the
  existing geometry compatibility check. This is candidate resampling, not an
  image-space blur or the old apply-pass neighbor gather.
- Always refresh the spatial candidate's visibility at the receiver, including
  blocked candidates. Do not zero its contribution weight at this point.
  Supplementary section C states that `Distant(c,i)` is always true in the
  author's experiments; this implementation follows that choice.
- Update visibility using the exact same resampling weights, independently of
  which candidate wins. Shade with `f(X) * visibility * W` without a second
  binary gate or the legacy shading-weight clamp.

The replay domain is light ID plus three primary random numbers. Contributions
include the internal area/direction proposal correction, so the replay shift
is identity with unit Jacobian. ReGIR provides the discrete proposal correction.
When ReGIR is explicitly disabled, mode 1-3 uses uniform global light proposals.
Always-sampled environment lights and flashlights keep their existing path.

Modes 1-3 use the luminance of the exact unshadowed shaded contribution as the
target for each lobe, including its shading normal. Mode 0 keeps its previous
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

Two new initial/temporal passes precede both direct-light final passes in
`rt.json`. Intermediate and final reservoirs are distinct images, so spatial
reads never race neighboring writes. The metadata image's y/z channels hold
diffuse/specular visibility; w holds the mode tag. Its legacy inverse PDF stays
in x in mode 0. Current/previous metadata travel with their reservoir.

New images cost about 200 bytes per full-resolution pixel, including both
light types' intermediate reservoirs and double-buffered surface metadata
(roughly 396 MiB at 1920x1080, excluding driver alignment). They are allocated
even in mode 0 by the current static pipeline resource allocator.

`tests/direct_visibility_weights.c` compiles the actual scalar GLSL arithmetic
as C. It checks empty inputs, MIS partition of unity, exact enumeration of a
two-light integral, variance reduction, chained visibility mass, small-target
overflow and the final f/target cancellation. Shader
compilation and SPIR-V validation additionally check all four direct passes.
GPU scene behavior still needs in-game testing: hard/contact shadows, penumbrae,
camera motion, moving occluders and differently colored lights with unequal
visibility. No scene-level correctness is inferred from compilation alone.
