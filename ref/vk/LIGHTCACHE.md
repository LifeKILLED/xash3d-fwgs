# Direct diffuse lightmap cache

Enable the experimental view with:

```
rt_debug_display_only DIRECT_DIFFUSE_CACHE
```

An empty `rt_debug_display_only` restores the usual rendering. Cache passes run
in ordinary rendering as well to seed RIS restarts; their images belong to the
ordinary screen-sized meatpipe graph.
In the cache view, the ordinary screen `light_direct_point` and
`light_direct_poly` shaders return before lighting or shadow rays. Their dispatch
labels remain in the graph. Changing debug views resets temporal history.

`rt_disable_direct 1` disables ordinary screen direct diffuse/specular and
flashlight lighting independently of the view. The existing RIS passes receive
inactive surfaces, write zero lighting and empty histories, and trace no light
or shadow rays. `rt_disable_direct 0` restores it. Toggling resets temporal
history. Lightmap cache lighting and secondary GI/reflection lighting remain
independent of this switch.

`rt_lightcache_gi 1` replaces point/poly lighting at compound GI path vertices
with the temporal SH lightmap cache. It also enables cache updates outside the
debug view. `0` restores the existing GI lighting. Switching resets history.
The existing path tracer, path reservoir, emissive/sky contributions and GI
denoiser remain in use. The local GI point/poly lighting shaders return before
sampling lights or tracing shadows while this option is enabled.

The committed GI hit supplies LM UV without a second ray, using the same helper
as primary hits (including studio's vanilla UV binding). UV is stored with each
fresh and historical path vertex. Resolve samples the current temporal cache
for both candidate paths, using the shared four-tap SH coefficient filter and
island-edge extrapolation. Missing cache bindings contribute no direct light;
they do not fall back to full point/poly lighting. All added path images use
the ordinary screen extent and existing resource discovery.

## Current reservoir debug view

`rt_debug_display_only LIGHT_CACHE` displays the current-frame point and polygon
cache reservoir estimator outputs at the visible surface's shading normal.
It reads raw cache radiance/direction images directly, with nearest-texel lookup:
no SH conversion, cache spatial filter, SH temporal filter, material base color,
or metalness-dependent reflection projection. Reservoir temporal reuse inside
the cache updater remains active. Missing UV is black; capacity overflow is
magenta. Screen direct-light evaluation is skipped in this debug view.

## RIS restart seeding

When temporal validation leaves a lobe without a reservoir (including missing
reprojection and lifetime expiry), direct and secondary RIS consume the four
same-island lightmap cache taps before their ordinary candidates. Secondary passes use the LM UV of their own ray hit to address the same diffuse
cache; reflection/refraction do not have separate lighting caches. Compound GI
path slots do the same whenever rebuilt. Valid history is retained without
cache seeding. Missing UV, stale cache state, invalid lights and empty reservoirs
are skipped. Taps outside the original island are rejected, not clamped or
replaced by edge texels.

LM UV remain fractional: brush UV are barycentrically interpolated at the ray
hit, studio bindings use float coordinates, and UV images are RGBA32F. Before
selecting the 2x2 footprint, RIS jitters the hit UV independently in X/Y by
[-0.5, 0.5) source-lightmap texels (1/1024 in normalized atlas coordinates).
The random offset changes with the frame seed. Island lookup uses the original
UV, so jitter cannot cross into another packed island. Stored UV are unchanged.

The four taps are adjacent texels in the island-local lightmap cache grid,
not screen-space neighbors. Each valid neighbor contributes one proposal (M = 1),
using its normalized estimator W = weight_sum / (source_M * source_target).
Cache confidence is 0.3 for diffuse and 0.1 for specular: both selection mass
and effective M are multiplied by this factor, preserving normalized brightness
W while making the seed easier to replace. Unsplit reservoirs combine the
factors using the current BRDF lobe targets. The stored target and normalized
inverse proposal weight remain unchanged, including diffuse ReGIR reversion.
The source's temporal
sample count and total mass are not imported, so four cache taps cannot bring
hundreds of historical candidates into a newly reset screen reservoir. All four neighbors
enter without bilinear attenuation; only UV dithering varies the footprint. The target is evaluated
at the current receiver without a shadow ray. Unlike SH coefficients, reservoir
proposals do not use interpolation or signed edge extrapolation. Normal candidates and final
shading keep their existing behavior. Cache updates can still be frozen with
`rt_disable_lightcache_update`.

## Geometry and addressing

`vk_lightcache.c` prepares material-independent local positions and geometric
normals on the CPU while the existing brush lightmap is allocated. Each surface
is an island. Its cache extent is `ceil(width/2) x ceil(height/2)`, so 1-texel-wide
and 1x1 islands survive. Islands are packed consecutively without padding; a
1024x1024 source-LM lookup table maps each original texel to its own island's
probe. Freed atlas padding does not consume cache slots. Nine-tap neighbors and
permutations use island coordinates, never neighboring packed pixels.

Positions are clamped to their convex BSP face. The external
`lightcache_geometry` SSBO holds the lookup, probe geometry, and current brush
transforms. No geometry G-buffer images or geometry-update dispatch are needed.
Transforms are refreshed each frame, including brushes outside the draw list.
Only map/geometry changes upload the static table. Map reload increments a cache
epoch. Physical cache images use the screen extent and linear probe addresses;
resolution changes invalidate reservoir history. If the active viewport cannot
hold a probe, its debug sample is magenta rather than aliasing another probe.

## Studio binding

The Vulkan renderer's vanilla search is in `rlight.c`. `R_LightVecSurface`
returns the selected surface and its local hit point, using exactly the existing
color search and fallback decisions. `R_LightmapCoord` converts that hit to atlas
UV. UV and validity travel through the existing model draw/instance path and
replace the padding in the 96-byte `ModelHeader`. No second trace is introduced.
All rendered submodels of the entity use that same binding. Vanilla branches
that return sky/fullbright without a lightmap hit have no cache binding.

## Lighting

Cache reservoirs use an independent random lifetime reset with probability
`1/5000` per frame (mean lifetime 5000 frames). Invalid lights and visibility
failures still invalidate history. Screen RIS lifetimes are independent.

Point and polygon passes use the existing concrete light samplers, reservoir
encoding/merge/reweight helpers, paired permutations, visibility arithmetic, and
seven-frame visibility source detector. The cache has one diffuse reservoir per
light type, with independent random/count and visibility histories. It uses the existing ReGIR onion proposals, with uniform proposals when ReGIR
is disabled or the probe is outside its camera-centered coverage. Environment
and flashlight sources, excluded from ReGIR, enter as separate proposal strata
in the same diffuse reservoir. Concrete sampling and weighting are independent
of the receiving surface's material and view.

Concrete emitter sample coordinates are hashed from the texel's lightmap
address and light ID/type, independently of frame number, frame random seed,
and brush world transform. Fresh candidate shading, winner visibility, and the
selected source's visibility detector all replay that same stable sample.
Proposal selection, reservoir merging and lifetime retain their changing RNG.
UV dithering when reading cache reservoirs remains independent.

Visibility is measured for the fresh RIS winner and the saved concrete point on
the selected source. History reuses scalar visibility; the shared median/gradient
controls update its seven-frame detector. Reservoir and lighting history always
reproject to the identical lightmap texel ID, including moving/rotating brushes.
There are no history permutations or world-position, normal, depth, plane,
material, or screen-reprojection gates. Old samples are evaluated using current
probe geometry; position and normal history are not stored. Changed light hashes
do not reject the reservoir: all point/poly RIS paths first check the current
slot, then ID + 1 and ID - 1 for the saved hash. If neither neighbor matches,
the original ID is retained, re-evaluated, and its hash refreshed. A missing
original slot can still be recovered from a matching immediate neighbor. History can reset on target-weight confidence, shadow rejection, or
its independent lifetime. History count is capped using `di_visibility_history`.
Cache epoch, allocation capacity, resolution and ping-pong frame validity still
protect against reading incompatible storage.

The SH pass accumulates nine same-island taps, keeping each light's concrete RIS
sample direction. Outputs are two RGBA16F images (`shY` and `CoCg`); RIS data is
never stored in SH. A separate temporal SH pass mixes 90% previous coefficients
with 10% current coefficients at the same stable lightmap address. New/invalid
history uses the current result directly; map changes, viewport changes and
gaps in the debug view invalidate history through the existing cache state.

Debug resolve reads the temporal result with a manual four-tap bilinear SH
filter. Taps are selected in the source island, before linear address packing.
Edge coefficients are linearly extrapolated from the last two probes rather
than mixing with padding or other islands; singleton axes repeat their sole
probe. The final, shortened probe interval of odd-sized islands is respected.
Only after coefficient interpolation does debug resolve project on the shaded
normal for diffuse and reflection direction for metal, without base color.

## Checks

- `python waf build`
- Validate generated SPIR-V with Vulkan SDK `spirv-val`.

Runtime visual checks still need to cover moving/rotating brushes, studio on a
lit floor, one-texel islands, and switching the view/resolution. The two-image
SH representation is the existing luminance SH plus CoCg approximation.
