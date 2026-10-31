#ifndef REFLECTION_PATH_WEIGHTS_GLSL_INCLUDED
#define REFLECTION_PATH_WEIGHTS_GLSL_INCLUDED

// Scalar helpers shared with the CPU estimator tests. Callers validate positive
// targets/counts; a positive target floor preserves support for black paths.
float reflectionPathCappedCount(float count, float cap)
{
	return count < cap ? count : cap;
}

float reflectionPathHistoryMass(float old_target, float old_sum, float old_count,
	float new_target, float cap)
{
	const float count = reflectionPathCappedCount(old_count, cap);
	return old_sum * (count / old_count) * (new_target / old_target);
}

float reflectionPathOutputWeight(float weight_sum, float count, float target)
{
	return weight_sum / (count * target);
}

// Compare the RNG against the smaller branch directly. Computing 1 - p for
// a tiny branch in fp32 can erase black samples, then bias later brightening.
float reflectionPathSmallProbability(float fresh_mass, float history_mass)
{
	const float smaller = fresh_mass < history_mass ? fresh_mass : history_mass;
	return smaller / (fresh_mass + history_mass);
}

float reflectionPathCappedMass(float weight_sum, float count, float cap)
{
	return weight_sum * (reflectionPathCappedCount(count, cap) / count);
}

float reflectionPathConfidenceCap(float change, float maximum, float minimum)
{
	const float cap = maximum / (1.0f + change * change);
	return cap > minimum ? cap : minimum;
}

#endif
