# Direct lighting: shadow-ray accounting

This report describes `rt_direct_visibility_reuse 1` after removing dedicated
zapas visibility rays. Counts below are logical visibility tests per active
full-resolution pixel per frame, across BOTH point and polygon light passes.
They are code-path upper bounds, not measured GPU counters. Missing candidates,
empty reservoirs, rejected light directions or backfaces can lower the count.

| Stage | Condition | Maximum tests per pixel |
| --- | --- | ---: |
| Fresh initial RIS winners | `rt_direct_visibility_candidates 0` | 4: two lobes per light type |
| Fresh RIS candidates | `rt_direct_visibility_candidates 1` | 8: four candidates per type, shared by both lobes |
| Initial winners with candidate checks enabled | Winners already checked | 0 additional |
| Primary visibility-window probe | Median OR gradient enabled | 4: one new random point per valid lobe/type |
| Primary visibility-window probe | Both detectors disabled | 0 |
| NVIDIA XOR-3 exchange | Both windows full-light and pair accepted | 0 additional |
| Temporal target evaluation / MIS / M cap | Either bank | 0 |
| Zapas accumulation and visibility observation | Reuses matching candidate ID/hash results only | 0 additional |
| Age reset / full-light reset / many-to-one hole replacement | Zapas or fresh replacement | 0 additional |
| Final reservoir shading / optional W clamp | Either lobe | 0 |
| ReGIR grid construction and lookup | Unshadowed proposals | 0 |

The two fresh-RIS modes are alternatives. Thus reservoir DI totals are:

| Candidate visibility | Median/gradient | Maximum logical shadow rays |
| --- | --- | ---: |
| 0 | Both off | 4 |
| 0 | Either/both on | 8 |
| 1 | Both off | 8 |
| 1 | Either/both on | 12 |

Four candidates are currently configured both for ReGIR lookup and the uniform
proposal fallback (`REGIR_ONION_LOOKUP_CANDIDATES`, `RIS_PRIMARY_CANDIDATES`).
Enabling both detectors does not double probes: gradient takes priority.
A `1111111` window skips median/gradient arithmetic but still takes its probe
to detect new occlusion. After a promotion, that same existing primary probe
can observe the promoted source on the NEXT frame; the promotion itself is
after the current frame's probe and does not issue another one. The probe tests
a fresh point on the source, not necessarily the reservoir's retained point.
With both detectors disabled, temporal reprojection has no independent shadow
test on the retained primary sample; only the fresh initial samples are tested.

Zapas observations do not scan or trace all proposals in winner-only mode.
Only candidates that actually received the already-existing visibility check
can update it. Negative matches discard old accumulation; positive matches
leave its assumed visibility unchanged. There is no extra ray for a missing
match, and no special verification on any replacement path.

Environment lights and flashlights have an additional unchanged always-sampled
point-light path. It may perform one logical shadow test per eligible light per
pixel (shared by diffuse/specular); these are NOT included in the fixed bounds
above. GI, reflection, refraction, the primary camera ray, and the legacy
`rt_direct_visibility_reuse 0` path are outside this report's totals.

At the ray-query level a logical test can perform up to TWO TLAS queries:
`shadowed` first checks opaque casters and, if unblocked, checks alpha-tested
geometry separately. `shadowedSky` likewise performs a sky/opaque query and may
continue to the alpha-mask query. Therefore the 4/8/12 logical-ray bounds can
correspond to up to 8/16/24 TLAS queries before always-sampled lights. Internal
`rayQueryProceedEXT` iterations are traversal work within a query, not new rays.

Relevant implementations: `shaders/direct_visibility_reuse.glsl`,
`shaders/light_ris_lights.glsl`, `shaders/light_common.glsl`.
