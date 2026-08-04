#ifndef BOUNCE_PATH_CONFIG_GLSL_INCLUDED
#define BOUNCE_PATH_CONFIG_GLSL_INCLUDED

// Compile-time normal mode for compound bounce GI.
//
// GEOMETRY:
//   Stable low-frequency transport intended for SH accumulation/denoising.
// SHADING:
//   Bounce sampling and local light evaluation follow the normal map.
//   This preserves high-frequency normal detail but increases temporal noise;
//   it is most useful when the SH denoising path is disabled externally.
#define BOUNCE_PATH_NORMAL_MODE_GEOMETRY 0
#define BOUNCE_PATH_NORMAL_MODE_SHADING  1

#ifndef BOUNCE_PATH_NORMAL_MODE
#define BOUNCE_PATH_NORMAL_MODE BOUNCE_PATH_NORMAL_MODE_GEOMETRY
#endif

#if BOUNCE_PATH_NORMAL_MODE != BOUNCE_PATH_NORMAL_MODE_GEOMETRY && \
    BOUNCE_PATH_NORMAL_MODE != BOUNCE_PATH_NORMAL_MODE_SHADING
#error Unsupported BOUNCE_PATH_NORMAL_MODE
#endif

// Reject many-to-one temporal reprojection during camera magnification.
// Neighboring current half-resolution texels that map to the same history
// texel share its survival probability, preventing a single noisy reservoir
// from expanding into a larger block as the camera approaches the surface.
#ifndef BOUNCE_PATH_REJECT_MAG_REPROJECTION
#define BOUNCE_PATH_REJECT_MAG_REPROJECTION 1
#endif


// Temporal lifetime and effective reservoir size for compound bounce GI.
// These settings are intentionally independent from direct RIS. Dark indirect
// lighting may need several seconds of stable history before rare doorway or
// emissive paths form a smooth result.
//
// MAX_HISTORY_AGE == 0 disables age-only invalidation. Geometry changes are
// still handled by round-robin transport-segment validation, while point/poly
// light caches are refreshed independently.
#ifndef BOUNCE_PATH_MAX_HISTORY_AGE
#define BOUNCE_PATH_MAX_HISTORY_AGE 0u
#endif

// At equal target weights, 256 effective samples give a fresh path roughly a
// 1 / 257 replacement probability per frame once the reservoir is saturated.
#ifndef BOUNCE_PATH_MAX_EFFECTIVE_SAMPLES
#define BOUNCE_PATH_MAX_EFFECTIVE_SAMPLES 256.0
#endif

#ifndef BOUNCE_PATH_MAX_OUTPUT_WEIGHT
#define BOUNCE_PATH_MAX_OUTPUT_WEIGHT 32.0
#endif

// Ignore direct intersections with emissive opaque/alpha-tested surfaces when
// constructing the compound bounce contribution. Those surfaces are already
// represented by point/polygon light sampling, so accepting a rare BSDF hit
// can create bright, long-lived fireflies in the temporal path reservoir.
//
// This affects only emissive radiance returned by a committed geometry hit.
// Sky radiance on a miss is preserved, and the later legacy-blending pass may
// still add translucent/legacy emission into the same path lane.
#ifndef BOUNCE_PATH_EXCLUDE_EMISSIVE_SURFACE_HITS
#define BOUNCE_PATH_EXCLUDE_EMISSIVE_SURFACE_HITS 1
#endif

#endif // BOUNCE_PATH_CONFIG_GLSL_INCLUDED
