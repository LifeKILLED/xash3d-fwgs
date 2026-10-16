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

## Zapas reservoir

Each direct-light lobe now has a second reservoir, `zapas`, built in the same
dispatch from the same fresh RIS result. Candidate generation, targets,
selection random numbers and initial shadow tests are shared; there is no
second ReGIR lookup or candidate loop. Zapas has its own canonical temporal
history and does not participate in the primary reservoir's XOR permutation.
Temporal combination uses the existing MIS arithmetic and M cap. If its
selected light ID/hash changes, discard the previous accumulation and start
from the current fresh estimator instead of retaining mixed old-source mass.

The selected zapas replay sample is checked for visibility every frame. Reuse
the initial shadow result, or the other lobe's result, when source and replay
point match exactly. Otherwise trace one additional ray per zapas reservoir
(at most four per pixel across diffuse/specular and point/polygon). An occluded
zapas is cleared, never stored with smoothed visibility. Its random lifetime
is 5-30 successful reprojections; primary lifetime is 1-200. Lifetimes are
chosen once at initialization, include frame counter even with fixed debug
RNG, and travel with the appropriate reservoir.

On a primary age reset, full-light transition, or many-to-one ownership
rejection, consume a currently visible zapas that has survived at least one
reprojection. If none is ready, use the fresh RIS result. Restart the consumed
zapas from fresh candidates; a many-to-one rejected receiver also restarts its
zapas after use to avoid keeping duplicate history as a growing pixel block.
Preserve the primary's bit window only if the replacement light matches.

A missing/invalid canonical reprojection or incompatible history tag is a
hard reset: neither old bank is restored. Surface/depth validation remains
the existing reprojection validation. No new shading-confidence heuristic is
introduced: the separate legacy shading-confidence function is still disabled.
Changing `rt_di_visibility_history` now advances a CPU history epoch and
invalidates both banks. The existing UBO uint carries enable plus epoch bits;
its size/layout and the standard build system remain unchanged.

Zapas adds eight RGBA32F images, each with a previous-frame partner: 256 bytes
per allocated framebuffer pixel, about 506 MiB at 1920x1080, before alignment.
Replay points, targets, M and mass retain full float32 precision. Primary age
uses spare bits in its packed light/count word; primary lifetime shares the
zapas hash word. All integer words fit within 24 exact float32 bits, and no
integer decode adds 0.5. Images remain allocated in the shared graph with reuse
disabled, but incompatible legacy history cannot import their contents.

Update both `ref_vk.dll` and `rt.meat`. Primary and zapas age resets are active
with reuse enabled; full-light transition detection still requires either
median or gradient. Scene-level behavior and GPU cost need in-game testing.

`rt_direct_visibility_median` defaults to `0`. Setting it to `1` enables the
user-proposed seven-frame, per-source visibility detector on top of reuse:

- After temporal selection, trace one independent fresh point on the selected
  light per frame and per lobe. The probe RNG does not change reservoir selection
  or replay random numbers; it advances even with a fixed debug RNG seed.
- Keep the last seven binary observations, a valid count (0-7), and the previous
  median separately for diffuse/specular reservoirs and point/polygon lights.
  Source identity is the resolved light ID plus the existing light hash.
  Selecting another replay point on that same light preserves the window;
  selecting another light or losing reprojection starts it again.
- Before seven valid observations, the detector never resets visibility.
  In a full rolling window, the median is 1 for at least four visible rays.
  A median change resets accumulated visibility to that binary median.
  All-zero or all-one windows also set visibility to their corresponding value.
- Positive median changes retain the reservoir ID, replay point, mass
  and M, except for the full-light transition described below. A zero visibility decision clears the whole reservoir, as explicitly
  requested. A single zero shadow ray cannot cause a detector reset on its own.
- This does not reset aSVGF, change
  target normals, add permutations, or change the existing optional W clamp.

Seven frames take about 117 ms at 60 FPS, but this is the measurement window,
not a guaranteed bound on image lag. An already-full window can change majority
after four contrary observations. A static penumbra can also change majority.
This detector is the user's experiment, not an algorithm attributed to Tokuyoshi.
The comparison mode remains available with `rt_direct_visibility_median 0`.
Changing this switch invalidates reservoir history through its format tag.

`rt_direct_visibility_gradient` defaults to `0` and selects a second experiment
on the same per-source seven-frame window. It has priority if both gradient
and median switches are enabled. No additional probe rays or storage are needed
beyond the median detector's window. Both methods wait for seven valid frames.

With bit 0 newest, the recent-weighted sum uses weights `7,6,5,4,3,2,1`, and
the older-weighted sum uses `1,2,3,4,5,6,7`. Divide both by 28; their difference
is the trend. For a positive trend, raise accumulated visibility to the recent
estimate only if it is below that estimate. For a negative trend, lower it to
the recent estimate only if it is above. Zero trend leaves mixed visibility
unchanged. All-zero/all-one windows explicitly set visibility to 0/1; zero
clears the reservoir as in the median experiment. The full-light transition
below restarts reservoir weights; otherwise W, M and selection
remain unchanged. This is the user's directional correction experiment, with
no tuned gradient threshold; static penumbra noise can also trigger correction.

Both detectors now restart the reservoir on a confirmed transition to full
light: a full seven-bit window containing an occluded observation becomes
`1111111`. Replace the temporally merged result with mature visible zapas,
falling back to this frame's initial RIS reservoir. Copy its selected source,
replay point, target, mass, M and tested visibility. Do not manufacture a weight
from the detector's visibility.
Preserve the full detector window only if that fresh winner is the same source;
otherwise start its window anew. Empty or occluded fresh reservoirs remain so.
Initial all-lit warmup and continuing `1111111` do not trigger restarts. This
is an explicitly requested experiment for stale shadow weights, not part of
Tokuyoshi's algorithm, and may briefly increase noise when it discards history.
It adds no probe rays, image memory or console switches. The W clamp is unchanged.

With either detector active, full-light history pairs can now exchange their
temporal donors. Eligibility is the exact bit/count test `count == 7 && bits == 127`
at BOTH endpoints, independently of whether median or gradient is selected.
After each fresh probe, a full-light window also bypasses median popcount and
gradient sums entirely and sets visibility to one. Probes still run so a new
occlusion can leave the full-light state.

Median population count and the weighted visibility sums extract seven bits
into two vec4 values (with the eighth lane zero) and use dot products, without
shader loops. The gradient directly reduces the difference weights
`6,4,2,0,-2,-4,-6`, avoiding a repeated recent-mean calculation. Exhaustive CPU
checks compare these reductions against scalar reference sums. This arithmetic
change leaves visibility sampling unchanged.

The exchange uses the existing NVIDIA offset / XOR-3 / subtract-offset pairing
in the current pixel domain and the existing reciprocal plane validation
(plus the existing shading-normal check for specular). Both resolved sources
must reciprocally match the canonical histories. Read only previous-frame
reservoirs, never neighbors' in-progress writes. Require valid matching lights,
positive incoming targets. At the user's request, there are no additional
cross-visibility rays for the exchange; the existing per-frame detector probe
continues observing visibility after selection. The donor's
previous surface accompanies its reservoir into the existing temporal MIS;
target normals and final shading follow the normal split described below.
The receiving texel retains its own per-source bit window if the incoming light
is the same; a different source starts a new window. The two lobes and light
types make these decisions independently. The neither-detector baseline keeps
canonical reprojection without this exchange.

This is the user's conditional permutation experiment, not the paper's spatial
resampling pass. It adds no shadow rays, images, dispatches, build variants or
console switches. Paired history/surface reads and target evaluations remain. GPU cost and
scene behavior require in-game comparison.

To compare methods while keeping reuse and the tested W clamp enabled:

```text
rt_direct_visibility_reuse 1
rt_direct_visibility_weight_clamp 1

// Median
rt_direct_visibility_gradient 0
rt_direct_visibility_median 1

// Gradient
rt_direct_visibility_median 0
rt_direct_visibility_gradient 1

// Previous baseline (neither detector)
rt_direct_visibility_gradient 0
rt_direct_visibility_median 0
```

Changing the active method invalidates reservoir history. Keep the other
sampling and denoising settings unchanged for the comparison.

The visibility window adds no images. The existing RGBA32F reservoir's x channel
packs an 11-bit encoded light ID, a 3-bit observation count and an 8-bit primary age. Its y channel
packs the 16-bit light hash, 7 visibility bits and the previous median bit.
Both are numerical integers exactly representable in float32, including the
largest 24-bit y value. Decoding uses a direct uint cast, never `+ 0.5`.
The format tag is versioned so the legacy RIS path rejects packed histories.

`rt_direct_visibility_weight_clamp` defaults to `0`. When enabled, the reuse
path applies the existing legacy shading formula
`min(mass / max(M * target, RIS_WEIGHT_EPSILON), RIS_SHADE_RESERVOIR_WEIGHT_MAX)`
to the final contribution, also multiplied by reused visibility. The current
legacy limit is W=5. This is a diagnostic biased clamp, not a radiance cap.
Selection, targets, temporal MIS, visibility and stored reservoirs are unchanged,
and toggling this switch does not invalidate reservoir history. It applies only
to visibility reuse; the legacy path already uses its own clamp. Keep other
switches unchanged when comparing it, to isolate the effect of the clamp.

`rt_direct_visibility_candidates` defaults to `0` for a controlled comparison:

- `0`: the publication's initial RIS variant, with visibility tested only for
  each lobe's winner. An occluded candidate can still increase the initial
  weight sum when a different, visible candidate wins.
- `1`: test each fresh candidate's concrete visibility before accumulating its
  weight. One shadow test is shared by both lobes. Occluded candidates contribute
  zero mass but still count toward M; visible winners keep their unshadowed
  target, which equals the visibility-inclusive target at those samples.
  Winner shadow tests are then redundant and omitted.

This switch applies only when `rt_direct_visibility_reuse 1` is enabled. It
changes initial RIS, not the temporal MIS or the normal used by its targets.
Both variants use separate history tags, so changing the switch discards old
reservoir statistics. In ReGIR mode, this costs up to four candidate shadow
tests per light type instead of up to two winner tests. It does not change
ReGIR's candidate distribution, refresh temporal visibility, or add a clamp.
The full-candidate variant is a diagnostic alternative to the paper's initial
visibility shortcut, not an exact reproduction of that shortcut.

To isolate large contribution weights originating in ReGIR's own reservoirs,
compare `rt_disable_regir 0` with `rt_disable_regir 1` while keeping visibility
reuse and full candidate visibility enabled. Uniform proposals bypass ReGIR
and use a constant inverse source probability equal to the light count.
Switching ReGIR also invalidates direct visibility-reuse reservoir history;
this prevents weights from the previous proposal path from contaminating the
comparison. ReGIR output weights can already reflect high unshadowed energy
from lights not selected into its reservoir; a later visibility test cannot
remove that energy if ReGIR's selected light itself is visible.

For a raw-lighting visual check, enable `rt_direct_visibility_reuse 1` with the
existing commands to disable temporal denoising and `rt_disable_atrous 1`.
Value 0 selects the legacy direct RIS path. Other lighting passes keep their
existing RIS implementation regardless of this switch. Update the rebuilt DLL
and `rt.meat`. The old `rt_di_visibility_reuse` name is no longer registered.
The initial-only mode and spatial visibility-reuse path have been removed. The standard
pipeline compiler and build scripts are unchanged; there is only one graph,
`rt.json`, producing the usual `rt.meat`. The UBO field keeps its existing
name and layout; it carries enable and history-epoch bits.

## Correspondence with the publication

- Generate a fresh RIS reservoir without visibility in its target.
- Test the selected initial sample once and zero its contribution weight if
  blocked. Preserve its candidate count even when its weight is zero.
- Merge the temporal reservoir using Talbot MIS (supplementary equation 3).
  Previous surface position, normals and material are stored to evaluate the
  donor target at the fresh sample. The previous camera matrices reconstruct
  the donor's view direction.
- Keep the completed temporal reservoir local and shade that pixel directly.
  The supplementary algorithm's spatial resampling step is omitted; the
  optional per-source detectors enable the full-light donor exchange above.
- Update visibility using the exact same resampling weights, independently of
  which candidate wins. Shade with `f(X) * visibility * W` without a second
  binary gate. The legacy shading-weight clamp is an optional diagnostic,
  disabled by default.

The replay domain is light ID plus three primary random numbers. Contributions
include the internal area/direction proposal correction, so the replay shift
is identity with unit Jacobian. ReGIR provides the discrete proposal correction.
When ReGIR is explicitly disabled, visibility reuse uses uniform global light proposals.
Always-sampled environment lights and flashlights keep their existing path.

At the user's request, visibility reuse now uses a geometry-normal diffuse
target for initial candidate weights and every temporal cross-target, including
evaluation on the previous surface. Specular targets retain the shading normal.
Final shading retains the shading normal for both lobes. This matches the
legacy path's normal split and is an experiment departing from the paper's
same-integrand target. A geometry-normal target can approach zero while the
normal-mapped shaded contribution stays large; the existing optional W clamp
is unchanged. The format tag rejects histories made with the previous target.
This is not a claim of unbiased RGB lighting. The paper discusses color
leak when the scalar target is not proportional to each color-channel integrand,
as well as lag under changing visibility. Initial visibility rejection retains
the biased ReSTIR variant described in the supplement.

The base paper path is extended by the user's zapas bank, explicit age lifetimes
and full-light permutations. It does not apply the legacy random-reset
probability or ReGIR proposal revert, texel-fixed visibility, color similarity
rejection, or an independent visibility EMA.

Temporal light-index recovery requires a matching light hash, using the existing
index search window. An unresolved light is rejected instead of attaching the
old sample statistics to an unrelated light occupying its array slot. Animated
lights whose hashes change can therefore lose temporal history.

Both resampling and shading algebraically cancel the explicit inverse target
before evaluating it. This avoids intermediate overflow for very small targets
without clamping weights or radiance when the diagnostic clamp is disabled.
History tags include a format version, so
the older geometry-target histories are not imported after a shader update.

## Resources and checks

With visibility reuse enabled, initial RIS, temporal resampling and final shading run in one
dispatch per light type. The reservoir stays local until its final history
write; there are no intermediate reservoir images. Full-light exchange reads
the paired previous reservoir and the partner's current surface.
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
