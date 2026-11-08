# Spatial Heitz shadows

Implements the spatial ratio-estimator architecture described by Heitz, Hill and McGuire,
[Combining Analytic Direct Illumination and Stochastic Shadows (I3D 2018)](https://research.nvidia.com/publication/2018-05_combining-analytic-direct-illumination-and-stochastic-shadows),
sections 4.1 and 4.2. This is an adaptation, not a verbatim port of the authors'
reference implementation. Temporal integration is deliberately disabled in
`denoiser.comp` with `DISABLE_TEMPORAL_DENOISER` for this experiment.

Primary polygon and sphere/spot/environment lighting now produces three RGB
signals for each of diffuse and specular:

- `light_{poly,point}_{diffuse,specular}`: stochastic shadowed lighting S_N.
- `heitz_{poly,point}_unshadowed_{diffuse,specular}`: stochastic unshadowed U_N,
  using exactly the same sample, BRDF and PDF as S_N.
- `heitz_{poly,point}_analytic_{diffuse,specular}`: unshadowed LTC lighting U.

The noise pass estimates total variation of the gradient of S_N/U_N along four
rotated lines (eleven taps per line). The rotation is stable per pixel. Geometry
discontinuities break the lines. A 3x3 box pass smooths the estimate. A horizontal
joint-bilateral pass filters S_N and U_N with identical weights; the matching
vertical pass is fused into `denoiser.comp`, which reconstructs
`U * filtered(S_N) / filtered(U_N)`. Point and polygon contributions are summed
before filtering. Diffuse and specular have independent noise estimates and
filter radii; RGB ratios preserve colored-light visibility.

The bilateral weights use geometric normals and symmetric tangent-plane distances.
Analytic light, textures, material parameters and normal-map shading are not
spatially averaged. Zero-energy denominator channels use visibility 1, as in the
paper. Polygon fan triangles are sampled proportional to area, with the
area-to-solid-angle PDF conversion included in both stochastic estimates.

## Blue-noise shadow sampling

Primary direct lighting fetches one RGBA texel from the existing linear UNORM8
`blue_noise_texture` per pixel per dispatch. Polygon and point lighting are
separate dispatches; both read the same pixel and frame slice, so the random
vector is identical across all lights. The existing 64 spatial masks cycle with
`frame_counter`; this does not read or accumulate previous lighting frames.
It does not claim a spatiotemporal blue-noise distribution.

UNORM values are mapped to the centers of 256 bins, keeping variates strictly
inside (0,1). The common XY pair samples the polygon triangle / light cone, and
Z selects the polygon's area-weighted fan triangle. No per-light hash, random
seed advancement or texture offset scrambles the spatial mask. Light positions,
orientations and extents map the common variates into different world-space rays.
The shadowed and unshadowed estimates still use the very same ray sample.

Shared samples correlate errors across lights. Geometry alone does not guarantee
independent rays or a blue-noise spectrum after every visibility/BRDF mapping;
coincident lights can have strongly correlated errors. Blue noise targets the
low-frequency clumps in sampling error, but cannot guarantee removal of all
penumbra artifacts. Bounce lighting retains its existing sampler.

## Tuning and limits

`heitz_shadow_common.glsl` contains the experimental filter settings:

- `HEITZ_NOISE_TO_SIGMA = 16`: proportional conversion from variation to sigma.
- `HEITZ_MAX_SIGMA = 8`, `HEITZ_MAX_RADIUS = 24`: cost and blur limits in pixels.

There is no subtractive noise threshold. The initial implementation used
`max(E - 0.15, 0)`, which could switch off filtering of sparse penumbra samples.
The current conversion follows the paper's proportional sigma rule. The larger
scale and cap are experimental settings for the requested spatial-only test;
they can increase shadow blur and filtering cost.

The paper's full real-time pipeline includes temporal reverse reprojection to
suppress residual low-frequency noise. Removing that stage cannot guarantee the
same image quality. The current uniform light sampler also does not implement
the paper's BRDF-aware importance-sampling strategy for narrow specular lobes.

These are initial settings, not parameters fitted to the game's scenes. The
implementation uses the existing approximate LTC integrals for U and one shadow
sample per light. Spatial filtering is biased near shadow boundaries and can
leave residual noise, especially on narrow specular lobes. Screen-space filtering
cannot recover geometry outside the current view. GI/reconstructed reflections
retain their existing paths; disabling the final compositor's reprojection does
not disable temporal operations internal to other GI passes.

There are three new compute dispatches (noise, noise box filter, horizontal
filter); the vertical filter runs in the compositor. Fourteen extra full-size
RGBA16F images require about 221.5 MiB at 1920x1080, excluding allocation overhead.
GPU time and image quality still need in-game measurement; compilation and graph
tests do not establish real-time performance.

## Verification

From the repository root:

```text
python waf build
python ref/vk/tests/test_heitz_pipeline.py
```

The tests inspect actual compiled SPIR-V bindings for producer/consumer order,
all three lighting signals, one blue-noise fetch before the light loops, the
final filtered ratio, and absence of history
accesses in the shadow passes and compositor. Additional tests compile the actual
GLSL sigma function with constant inputs and inspect its constant-folded SPIR-V
results, including sparse-noise, proportionality and zero-noise cases.

Use these console commands for visual diagnostics:

```text
rt_debug_display_only SHADOW_DIFF
rt_debug_display_only SHADOW_SPEC
rt_debug_display_only SHADOW_SIGMA_DIFF
rt_debug_display_only SHADOW_SIGMA_SPEC
rt_debug_display_only ""
```

The shadow views show filtered RGB visibility without analytic lighting or GI.
The sigma views show sigma divided by its cap: black means no spatial filtering,
white means maximum filtering. The empty value returns to normal rendering. Comment out
`DISABLE_TEMPORAL_DENOISER` only when returning to temporal compositor tests.
