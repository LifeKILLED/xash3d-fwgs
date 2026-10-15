// Tokuyoshi 2024, supplementary Eqs. (3) and (4).
// Kept scalar and C-compatible so the actual shader arithmetic can be tested
// on the CPU without duplicating the implementation in a reference model.
float risVisibilityMisWeight(float count, float target, float other_count, float other_target)
{
	const float numerator = count * target;
	const float denominator = numerator + other_count * other_target;
	return denominator > 0.0f ? numerator / denominator : 0.0f;
}

float risVisibilityAverage(float va, float wa, float vb, float wb)
{
	const float total = wa + wb;
	return total > 0.0f ? (va * wa + vb * wb) / total : 0.0f;
}

float risVisibilityResamplingWeight(float count, float source_target,
	float other_count, float other_target, float source_mass, float receiver_target)
{
	// m_i * p_c * W_i, with count * p_i cancelled before evaluating W_i.
	// source_mass is count * p_i * W_i in the engine's reservoir layout.
	const float denominator = count * source_target + other_count * other_target;
	return denominator > 0.0f ? source_mass * (receiver_target / denominator) : 0.0f;
}

float risVisibilityShade(float contribution, float target, float mass, float count, float visibility)
{
	// f * V * W = (f / p_hat) * (mass / M) * V. Avoid materializing 1/p_hat:
	// it can overflow for a very small, but valid, contribution and target.
	return target > 0.0f && count > 0.0f ? (contribution / target) * (mass / count) * visibility : 0.0f;
}
