// User-proposed per-light seven-frame visibility detector. This is separate
// from Tokuyoshi's WIS estimator. Keep the integer logic C-compatible for tests.
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

uint risVisibilityWindowOnes(uint bits)
{
	uint ones = 0u;
	for (uint bit = 0u; bit < 7u; ++bit) {
		ones += (bits >> bit) & 1u;
	}
	return ones;
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

float risVisibilityWindowRecentMean(uint bits)
{
	uint sum = 0u;
	// Bit zero is newest: weights 7,6,...,1 sum to 28.
	for (uint bit = 0u; bit < 7u; ++bit) {
		sum += ((bits >> bit) & 1u) * (7u - bit);
	}
	return float(sum) / 28.0f;
}

float risVisibilityWindowOlderMean(uint bits)
{
	uint sum = 0u;
	for (uint bit = 0u; bit < 7u; ++bit) {
		sum += ((bits >> bit) & 1u) * (bit + 1u);
	}
	return float(sum) / 28.0f;
}

float risVisibilityWindowGradient(RisVisibilityWindow window)
{
	return window.count == 7u
		? risVisibilityWindowRecentMean(window.bits) - risVisibilityWindowOlderMean(window.bits)
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
