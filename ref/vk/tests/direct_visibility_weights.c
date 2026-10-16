#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdbool.h>
#include <stdint.h>

// Test the same scalar functions that are compiled into the GLSL shaders.
#include "../shaders/direct_visibility_weights.glsl"

typedef uint32_t uint;
typedef struct RisVisibilityWindow RisVisibilityWindow;
typedef struct { float x, y, z, w; } vec4;

static vec4 visibilityTestVec4(float x, float y, float z, float w)
{
	const vec4 v = {x, y, z, w};
	return v;
}

static float visibilityTestDot(vec4 a, vec4 b)
{
	return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
}

#define vec4(x, y, z, w) visibilityTestVec4(x, y, z, w)
#define dot(a, b) visibilityTestDot(a, b)
#define uint(value) ((uint)(value))
#define float(value) ((float)(value))
#include "../shaders/direct_visibility_window.glsl"
#undef float
#undef uint
#undef dot
#undef vec4

static int near(double a, double b)
{
	return fabs(a - b) < 0.00002;
}

int main(void)
{
	// Compare the loop-free vector reductions against a scalar reference for
	// every seven-bit pattern. An unused eighth bit must not affect the result.
	for (uint bits = 0; bits < 256; ++bits) {
		uint ones = 0, recent = 0, older = 0;
		for (uint bit = 0; bit < 7; ++bit) {
			const uint value = (bits >> bit) & 1u;
			ones += value;
			recent += value * (7u - bit);
			older += value * (bit + 1u);
		}
		RisVisibilityWindow measured = {bits, 7, 0};
		assert(risVisibilityWindowOnes(bits) == ones);
		assert(near(risVisibilityWindowRecentMean(bits), recent / 28.0));
		assert(near(risVisibilityWindowOlderMean(bits), older / 28.0));
		assert(near(risVisibilityWindowGradient(measured), ((int)recent - (int)older) / 28.0));
	}

	// Full-light exchange requires BOTH complete windows, without cross-rays.
	// Exhaust all masks/counts, and check that either endpoint makes the same
	// accept/reject decision. Seven stored ones with an incomplete count fail.
	for (uint ac = 0; ac <= 7; ++ac) {
		for (uint ab = 0; ab < 128; ++ab) {
			RisVisibilityWindow a = {ab, ac, 0};
			assert(risVisibilityWindowFullLight(a) == (ac == 7 && ab == 127));
			for (uint bc = 0; bc <= 7; ++bc) {
				for (uint bb = 0; bb < 128; ++bb) {
					RisVisibilityWindow b = {bb, bc, 1};
					const bool swap = risVisibilityWindowsPermitSwap(a, b);
					assert(swap == (ac == 7 && ab == 127 && bc == 7 && bb == 127));
					assert(swap == risVisibilityWindowsPermitSwap(b, a));
				}
			}
		}
	}

	// One restart on shadow-to-full-light, none during all-lit warmup or
	// continuing full light. The last occluded bit must leave the window.
	RisVisibilityWindow lit_window = {0, 0, 1};
	for (uint frame = 0; frame < 40; ++frame) {
		RisVisibilityWindow next = risVisibilityWindowPush(lit_window, 1);
		assert(!risVisibilityWindowEnteredFullLight(lit_window, next));
		lit_window = next;
	}
	lit_window = risVisibilityWindowPush(lit_window, 0);
	for (uint frame = 0; frame < 20; ++frame) {
		RisVisibilityWindow next = risVisibilityWindowPush(lit_window, 1);
		assert(risVisibilityWindowEnteredFullLight(lit_window, next) == (frame == 6));
		lit_window = next;
	}
	for (uint bits = 0; bits < 128; ++bits) {
		RisVisibilityWindow previous = {bits, 7, 0};
		RisVisibilityWindow next = risVisibilityWindowPush(previous, 1);
		assert(risVisibilityWindowEnteredFullLight(previous, next) == (bits == 63));
	}

	// No median-based reset before seven observations, even for six zero rays.
	RisVisibilityWindow window = {0, 0, 1};
	for (uint frame = 0; frame < 6; ++frame) {
		window = risVisibilityWindowPush(window, 0);
		assert(!risVisibilityWindowShouldReset(window));
	}
	window = risVisibilityWindowPush(window, 0);
	assert(window.count == 7 && risVisibilityWindowShouldReset(window));
	assert(risVisibilityWindowOnes(window.bits) == 0);

	// In a full rolling window, a 4/7 majority switch is detected on the fourth
	// occluded observation. One occluded ray must not discard a lit reservoir.
	window = (RisVisibilityWindow){127, 7, 1};
	for (uint frame = 0; frame < 3; ++frame) {
		window = risVisibilityWindowPush(window, 0);
		assert(!risVisibilityWindowShouldReset(window));
	}
	window = risVisibilityWindowPush(window, 0);
	assert(risVisibilityWindowShouldReset(window));
	assert(risVisibilityWindowOnes(window.bits) == 3);
	for (uint bits = 0; bits < 128; ++bits) {
		for (uint median = 0; median < 2; ++median) {
			window = (RisVisibilityWindow){bits, 7, median};
			uint ones = 0;
			for (uint b = bits; b; b >>= 1) ones += b & 1u;
			assert(risVisibilityWindowOnes(bits) == ones);
			assert(risVisibilityWindowShouldReset(window) ==
				((ones >= 4 ? 1u : 0u) != median || bits == 0 || bits == 127));
		}
	}

	// Gradient alternative: both methods observe exactly the same seven bits.
	window = (RisVisibilityWindow){15, 7, 0}; // oldest 000, newest 1111
	assert(risVisibilityWindowGradient(window) > 0);
	assert(near(risVisibilityWindowGradientUpdate(window, 0.2f), 22.0 / 28.0));
	assert(near(risVisibilityWindowGradientUpdate(window, 0.9f), 0.9));
	window.bits = 120; // oldest 1111, newest 000
	assert(risVisibilityWindowGradient(window) < 0);
	assert(near(risVisibilityWindowGradientUpdate(window, 0.9f), 10.0 / 28.0));
	assert(near(risVisibilityWindowGradientUpdate(window, 0.2f), 0.2));
	window.count = 6;
	assert(risVisibilityWindowGradient(window) == 0);
	assert(near(risVisibilityWindowGradientUpdate(window, 0.9f), 0.9));
	window = (RisVisibilityWindow){0, 7, 1};
	assert(risVisibilityWindowGradientUpdate(window, 1) == 0);
	window.bits = 127;
	assert(risVisibilityWindowGradientUpdate(window, 0) == 1);
	for (uint bits = 0; bits < 128; ++bits) {
		uint reversed = 0;
		for (uint bit = 0; bit < 7; ++bit) reversed |= ((bits >> bit) & 1u) << (6u - bit);
		window = (RisVisibilityWindow){bits, 7, 0};
		RisVisibilityWindow reverse_window = {reversed, 7, 0};
		assert(near(risVisibilityWindowGradient(window), -risVisibilityWindowGradient(reverse_window)));
		assert(near(risVisibilityWindowRecentMean(bits), risVisibilityWindowOlderMean(reversed)));
		const float result = risVisibilityWindowGradientUpdate(window, 0.5f);
		assert(result >= 0 && result <= 1);
		assert(near(result, 0.5) || risVisibilityWindowGradient(window) != 0 || bits == 0 || bits == 127);
	}

	// New replay points on one light keep the window; a different ID or hash
	// starts a new one. A source cannot inherit another source's measurements.
	window = (RisVisibilityWindow){85, 7, 1};
	RisVisibilityWindow selected = risVisibilityWindowSelect(11, 23, 11, 23, window, 0);
	assert(selected.bits == 85 && selected.count == 7 && selected.median == 1);
	selected = risVisibilityWindowSelect(12, 23, 11, 23, window, 0);
	assert(selected.bits == 0 && selected.count == 0 && selected.median == 0);
	selected = risVisibilityWindowSelect(11, 24, 11, 23, window, 1);
	assert(selected.bits == 0 && selected.count == 0 && selected.median == 1);

	// Exhaustive FP32 round trip of all hash/window words, including odd values
	// above 2^23 that the previous '+ 0.5' packing bug would corrupt.
	for (uint packed = 0; packed < 16777216u; ++packed) {
		volatile float stored = (float)packed;
		const uint restored = (uint)stored;
		window = risVisibilityUnpackWindow(7u << 11u, restored);
		assert(risVisibilityPackHashWindow(restored & 65535u, window) == packed);
	}
	for (uint light = 0; light < 2048; ++light) {
		for (uint count = 0; count < 8; ++count) {
			volatile float stored = (float)risVisibilityPackLightCount(light, count);
			const uint restored = (uint)stored;
			assert((restored & 2047u) == light);
			assert(risVisibilityUnpackWindow(restored, 0).count == count);
		}
	}

	// Regression: an always-occluded million-times-brighter light must not
	// inflate a visible winner's mass in full-visibility initial RIS.
	const float targets[] = {1, 1000000};
	const float visibilities[] = {1, 0};
	double initial_expectation = 0;
	for (int a = 0; a < 2; ++a) {
		for (int b = 0; b < 2; ++b) {
			const float mass = risVisibilityInitialCandidateMass(targets[a], 2, visibilities[a]) +
				risVisibilityInitialCandidateMass(targets[b], 2, visibilities[b]);
			const float estimate = risVisibilityShade(1, 1, mass, 2, 1);
			assert(estimate >= 0 && estimate <= 2);
			initial_expectation += 0.25 * estimate;
		}
	}
	assert(near(initial_expectation, 1));
	const float unchecked_mass = risVisibilityInitialCandidateMass(1, 2, 1) +
		risVisibilityInitialCandidateMass(1000000, 2, 1);
	assert(risVisibilityShade(1, 1, unchecked_mass, 2, 1) == 1000001);
	assert(risVisibilityInitialCandidateMass(1000000, 2, 0) == 0);

	// Empty inputs must remain black and finite, with no 0/0.
	assert(risVisibilityAverage(0, 0, 0, 0) == 0);
	assert(risVisibilityMisWeight(0, 0, 0, 0) == 0);
	assert(risVisibilityAverage(1, 0, 0, 9) == 0);
	assert(risVisibilityAverage(0, 0, 1, 9) == 1);
	assert(risVisibilityMisWeight(3, 2, 0, 0) == 1);

	// MIS partition of unity for unequal targets and confidence counts.
	for (int ma = 1; ma <= 20; ++ma) {
		for (int mb = 1; mb <= 20; ++mb) {
			assert(near(risVisibilityMisWeight((float)ma, 2, (float)mb, 7) +
				risVisibilityMisWeight((float)mb, 7, (float)ma, 2), 1));
		}
	}

	// Enumerate every pair of samples from two unequal proposal PDFs.
	// With f = receiver target, WIS cancellation (supplement Eq. 7) must
	// recover the exact visible integral, without Monte Carlo tolerance.
	const float pc[] = {2, 5};
	const float pi[] = {7, 1};
	const float visibility[] = {0, 1};
	double expectation = 0;
	double weighted_second_moment = 0;
	double binary_second_moment = 0;
	for (int a = 0; a < 2; ++a) {
		for (int b = 0; b < 2; ++b) {
			const float qa = pc[a] / 7;
			const float qb = pi[b] / 8;
			const float wa = risVisibilityResamplingWeight(1, pc[a], 4, pi[a], pc[a] / qa, pc[a]);
			const float wb = risVisibilityResamplingWeight(4, pi[b], 1, pc[b], 4 * pi[b] / qb, pc[b]);
			const float total = wa + wb;
			const float v = risVisibilityAverage(visibility[a], wa, visibility[b], wb);
			const double probability = (double)qa * qb;
			const double estimate = total * v;
			expectation += probability * estimate;
			weighted_second_moment += probability * estimate * estimate;
			binary_second_moment += probability * total *
				(wa * visibility[a] + wb * visibility[b]);
			assert(v >= 0 && v <= 1);
		}
	}
	assert(near(expectation, 5));
	assert(weighted_second_moment < binary_second_moment);

	// Chained WIS must preserve weighted visibility mass at each merge.
	const float first = risVisibilityAverage(1, 2, 0, 3);
	const float chained = risVisibilityAverage(first, 5, 1, 7);
	assert(near(chained * 12, 9));
	assert(risVisibilityAverage(1, 2, 1, 5000) == 1);

	// Regression: a finite reservoir mass can yield an overflowing W = mass /
	// (M * target), although both the resampling weight and shaded result fit.
	volatile float tiny_target = 1e-30f;
	volatile float large_mass = 1e10f;
	const float explicit_w = large_mass / tiny_target;
	assert(!isfinite(explicit_w));
	const float stable = risVisibilityResamplingWeight(1, tiny_target, 0, 0, large_mass, tiny_target);
	assert(isfinite(stable) && near(stable / large_mass, 1));
	assert(near(risVisibilityShade(tiny_target, tiny_target, large_mass, 1, 1) / large_mass, 1));
	assert(risVisibilityShade(0, 0, 0, 0, 0) == 0);

	// With f == target, shading gain must not increase as the target approaches
	// zero. This is the paper's f/p_hat cancellation, not a brightness clamp.
	for (int exponent = -30; exponent <= 20; ++exponent) {
		const float target = powf(10.0f, (float)exponent);
		assert(near(risVisibilityShade(target, target, 3, 2, 1), 1.5));
	}
	// The optional diagnostic uses the old shading formula, including its
	// denominator floor; it must not clamp radiance or accumulated mass instead.
	assert(near(risVisibilityShadeLegacyClamp(2, 1, 6, 2, 1, 1e-6f, 5), 6));
	assert(near(risVisibilityShadeLegacyClamp(2, 1, 40, 2, 1, 1e-6f, 5), 10));
	assert(near(risVisibilityShadeLegacyClamp(2, 1, 40, 2, 0.25f, 1e-6f, 5), 2.5));
	assert(risVisibilityShadeLegacyClamp(0, 0, 0, 0, 0, 1e-6f, 5) == 0);
	for (int exponent = -12; exponent <= 12; ++exponent) {
		const float target = powf(10.0f, (float)exponent);
		const float contribution = target * 2;
		const float mass = 7;
		const float expected = contribution * fminf(mass / fmaxf(3 * target, 1e-6f), 5) * 0.75f;
		const float actual = risVisibilityShadeLegacyClamp(contribution, target, mass, 3, 0.75f, 1e-6f, 5);
		assert(near(actual, expected));
	}
	puts("PASS: seven-frame visibility/source tracking and exhaustive packing; initial RIS, MIS, stable shading and W clamp");
	return 0;
}
