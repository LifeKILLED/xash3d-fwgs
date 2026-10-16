// User-proposed per-light seven-frame visibility detector. This is separate
// from Tokuyoshi's WIS estimator. Tests provide C equivalents of vec4 and dot.
struct RisVisibilityWindow {
	uint bits;
	uint count;
	uint median;
};

RisVisibilityWindow risVisibilityWindowSelect(uint selected_id, uint selected_hash,
	uint history_id, uint history_hash, RisVisibilityWindow history, uint initial_median)
{
	if (selected_id == history_id && selected_hash == history_hash) {
		return history;
	}
	RisVisibilityWindow window;
	window.bits = 0u;
	window.count = 0u;
	window.median = initial_median;
	return window;
}

float risVisibilityWindowSum(uint bits, vec4 low_weights, vec4 high_weights)
{
	// Bit zero is newest. The last lane is padding, not an eighth sample.
	const vec4 low = vec4(float(bits & 1u), float((bits >> 1u) & 1u),
		float((bits >> 2u) & 1u), float((bits >> 3u) & 1u));
	const vec4 high = vec4(float((bits >> 4u) & 1u),
		float((bits >> 5u) & 1u), float((bits >> 6u) & 1u), 0.0f);
	return dot(low, low_weights) + dot(high, high_weights);
}

uint risVisibilityWindowOnes(uint bits)
{
	return uint(risVisibilityWindowSum(bits,
		vec4(1.0f, 1.0f, 1.0f, 1.0f), vec4(1.0f, 1.0f, 1.0f, 0.0f)));
}

RisVisibilityWindow risVisibilityWindowPush(RisVisibilityWindow window, uint visible)
{
	window.bits = ((window.bits << 1u) | (visible & 1u)) & 127u;
	window.count = window.count < 7u ? window.count + 1u : 7u;
	return window;
}

bool risVisibilityWindowShouldReset(RisVisibilityWindow window)
{
	if (window.count < 7u) {
		return false;
	}
	const uint median = risVisibilityWindowOnes(window.bits) >= 4u ? 1u : 0u;
	return median != window.median || window.bits == 0u || window.bits == 127u;
}

bool risVisibilityWindowEnteredFullLight(RisVisibilityWindow previous, RisVisibilityWindow current)
{
	// Require an observed occlusion on this source, followed by seven lit rays.
	// Initial all-lit warmup and a persistently lit window are not transitions.
	return previous.count == 7u && previous.bits != 127u &&
		current.count == 7u && current.bits == 127u;
}

bool risVisibilityWindowFullLight(RisVisibilityWindow window)
{
	return window.count == 7u && window.bits == 127u;
}

bool risVisibilityWindowsPermitSwap(RisVisibilityWindow a, RisVisibilityWindow b)
{
	return risVisibilityWindowFullLight(a) && risVisibilityWindowFullLight(b);
}

float risVisibilityWindowRecentMean(uint bits)
{
	return risVisibilityWindowSum(bits,
		vec4(7.0f, 6.0f, 5.0f, 4.0f), vec4(3.0f, 2.0f, 1.0f, 0.0f)) / 28.0f;
}

float risVisibilityWindowOlderMean(uint bits)
{
	return risVisibilityWindowSum(bits,
		vec4(1.0f, 2.0f, 3.0f, 4.0f), vec4(5.0f, 6.0f, 7.0f, 0.0f)) / 28.0f;
}

float risVisibilityWindowGradient(RisVisibilityWindow window)
{
	return window.count == 7u
		? risVisibilityWindowSum(window.bits,
			vec4(6.0f, 4.0f, 2.0f, 0.0f), vec4(-2.0f, -4.0f, -6.0f, 0.0f)) / 28.0f
		: 0.0f;
}

float risVisibilityWindowGradientUpdate(RisVisibilityWindow window, float visibility)
{
	if (window.count < 7u) {
		return visibility;
	}
	if (window.bits == 0u) {
		return 0.0f;
	}
	if (window.bits == 127u) {
		return 1.0f;
	}
	const float recent = risVisibilityWindowRecentMean(window.bits);
	const float gradient = risVisibilityWindowGradient(window);
	// User-proposed trend experiment: catch up only in the observed direction.
	// No magnitude threshold, fitted constants, or change to reservoir W/M.
	if ((gradient > 0.0f && visibility < recent) ||
		(gradient < 0.0f && visibility > recent)) {
		return recent;
	}
	return visibility;
}

uint risVisibilityPackLightCount(uint encoded_light, uint count)
{
	return (encoded_light & 2047u) | ((count & 7u) << 11u);
}

uint risVisibilityPackZapasLight(uint encoded_light, uint age, uint lifetime)
{
	return (encoded_light & 2047u) | ((age & 31u) << 11u) | ((lifetime & 31u) << 16u);
}

bool risVisibilityLifetimeExpired(uint age, uint lifetime)
{
	return lifetime > 0u && age + 1u >= lifetime;
}

bool risVisibilitySameSource(uint a_id, uint a_hash, uint b_id, uint b_hash)
{
	return a_id == b_id && a_hash == b_hash;
}

bool risZapasCandidateRejects(uint zapas_id, uint zapas_hash,
	uint candidate_id, uint candidate_hash, bool visible)
{
	return !visible && risVisibilitySameSource(zapas_id, zapas_hash, candidate_id, candidate_hash);
}

bool risVisibilityMayUseZapas(bool reprojected, bool compatible, bool soft_reset,
	bool has_sample, uint age)
{
	return reprojected && compatible && soft_reset && has_sample && age > 0u;
}

uint risVisibilityPackZapasHash(uint light_hash, uint main_lifetime)
{
	return (light_hash & 65535u) | ((main_lifetime & 255u) << 16u);
}

uint risVisibilityPackHashWindow(uint light_hash, RisVisibilityWindow window)
{
	// 16 hash bits + 7 observations + 1 median bit = 24 exact float32 bits.
	return (light_hash & 65535u) | ((window.bits & 127u) << 16u) |
		((window.median & 1u) << 23u);
}

RisVisibilityWindow risVisibilityUnpackWindow(uint light_count, uint hash_window)
{
	RisVisibilityWindow window;
	window.bits = (hash_window >> 16u) & 127u;
	window.count = (light_count >> 11u) & 7u;
	window.median = (hash_window >> 23u) & 1u;
	return window;
}
