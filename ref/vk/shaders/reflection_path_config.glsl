#ifndef REFLECTION_PATH_CONFIG_GLSL_INCLUDED
#define REFLECTION_PATH_CONFIG_GLSL_INCLUDED

// Resample in GGX's uniform random-number domain. Replaying the winning pair
// traces a current-frame path even on mirrors; no secondary-point reconnection
// or solid-angle/area Jacobian is involved.
#ifndef REFLECTION_PATH_TEMPORAL_REUSE
#define REFLECTION_PATH_TEMPORAL_REUSE 1
#endif

// Validate transport in the saved sampling frame, then shade in today's frame.
#ifndef REFLECTION_PATH_VALIDATE_SAVED_FRAME
#define REFLECTION_PATH_VALIDATE_SAVED_FRAME 1
#endif

#ifndef REFLECTION_PATH_MAX_EFFECTIVE_SAMPLES
#define REFLECTION_PATH_MAX_EFFECTIVE_SAMPLES 640.0
#endif

// Reject local copies of the same historical random pair before ray tracing.
#ifndef REFLECTION_PATH_DEDUPLICATION
#define REFLECTION_PATH_DEDUPLICATION 1
#endif

// Motion caps confidence, rather than multiplying the final radiance.
#ifndef REFLECTION_PATH_MOVING_HISTORY_CAP
#define REFLECTION_PATH_MOVING_HISTORY_CAP 40.0
#endif
#ifndef REFLECTION_PATH_MOTION_PIXELS
#define REFLECTION_PATH_MOTION_PIXELS 2.0
#endif
#ifndef REFLECTION_PATH_RELATIVE_CAMERA_MOTION
#define REFLECTION_PATH_RELATIVE_CAMERA_MOTION 0.01
#endif
#ifndef REFLECTION_PATH_RELATIVE_HIT_CHANGE
#define REFLECTION_PATH_RELATIVE_HIT_CHANGE 0.025
#endif

// Independent restarts prevent an old path surviving indefinitely, even while
// stationary. This RNG is separate from the path's target and selection RNG.
#ifndef REFLECTION_PATH_RESTART_PROBABILITY
#define REFLECTION_PATH_RESTART_PROBABILITY (1.0 / 1280.0)
#endif

// Keep black samples in the reservoir domain/count, including GGX samples
// rejected by the geometric hemisphere. Never retry or drop their mass/count.
#ifndef REFLECTION_PATH_TARGET_FLOOR
#define REFLECTION_PATH_TARGET_FLOOR 1e-6
#endif

#ifndef REFLECTION_PATH_TARGET_LUMINANCE_MAX
#define REFLECTION_PATH_TARGET_LUMINANCE_MAX 1.3
#endif
#ifndef REFLECTION_PATH_FINAL_LUMINANCE_MAX
#define REFLECTION_PATH_FINAL_LUMINANCE_MAX 1.3
#endif

float reflectionPathTarget(vec3 contribution)
{
	return clamp(dot(contribution, vec3(0.2126, 0.7152, 0.0722)),
		REFLECTION_PATH_TARGET_FLOOR, REFLECTION_PATH_TARGET_LUMINANCE_MAX);
}

vec3 reflectionPathClampFinalLighting(vec3 lighting)
{
	const float Y = dot(lighting, vec3(0.2126, 0.7152, 0.0722));
	return lighting * min(1.0, REFLECTION_PATH_FINAL_LUMINANCE_MAX / max(Y, 1e-6));
}

#endif
