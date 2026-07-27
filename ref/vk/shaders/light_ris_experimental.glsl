#ifndef LIGHT_RIS_EXPERIMENTAL_GLSL_INCLUDED
#define LIGHT_RIS_EXPERIMENTAL_GLSL_INCLUDED

// Reuse visibility results produced by neighboring init invocations through
// workgroup shared memory. Disabling this keeps the per-texel Bayer segment,
// but removes shared memory, workgroup barriers, and neighbor gathering.
#ifndef RIS_INIT_SHARED_NEIGHBOR_VISIBILITY_REUSE
#define RIS_INIT_SHARED_NEIGHBOR_VISIBILITY_REUSE 0
#endif

// Gather candidates from neighboring reservoirs during apply. Disable this to
// evaluate only the reservoir that belongs to the current logical texel.
#ifndef RIS_APPLY_SPATIAL_REUSE
#define RIS_APPLY_SPATIAL_REUSE 0
#endif

// Direct-light reservoirs are consumed by secondary RIS passes. Keep their
// addressing independent from the consumer's own resolution and default the
// producer/consumer contract to one reservoir per full-resolution texel.
#ifndef RIS_DIRECT_INIT_HALF_RES
#define RIS_DIRECT_INIT_HALF_RES 0
#endif

#ifndef RIS_INIT_HALF_RES
#define RIS_INIT_HALF_RES RIS_DIRECT_INIT_HALF_RES
#endif

#if RIS_DIRECT_INIT_HALF_RES
#define RIS_DIRECT_RESERVOIR_BLOCK_ORIGIN(pix_) ((pix_) * 2)
#define RIS_DIRECT_RESERVOIR_PIXEL_FROM_SURFACE(pix_) ((pix_) / 2)
#else
#define RIS_DIRECT_RESERVOIR_BLOCK_ORIGIN(pix_) (pix_)
#define RIS_DIRECT_RESERVOIR_PIXEL_FROM_SURFACE(pix_) (pix_)
#endif

// If normal temporal reprojection fails, try the reservoir at the same
// logical pixel from the previous frame and let the regular validation reject
// it when it is no longer suitable.
#ifndef RIS_SAME_PIXEL_HISTORY_FALLBACK
#define RIS_SAME_PIXEL_HISTORY_FALLBACK 0
#endif

#if RIS_INIT_HALF_RES
#define RIS_RESERVOIR_BLOCK_ORIGIN(pix_) ((pix_) * 2)
#define RIS_RESERVOIR_PIXEL_FROM_SURFACE(pix_) ((pix_) / 2)
#else
#define RIS_RESERVOIR_BLOCK_ORIGIN(pix_) (pix_)
#define RIS_RESERVOIR_PIXEL_FROM_SURFACE(pix_) (pix_)
#endif

#endif // LIGHT_RIS_EXPERIMENTAL_GLSL_INCLUDED
