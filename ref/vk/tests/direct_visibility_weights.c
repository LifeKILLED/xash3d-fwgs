#include <assert.h>
#include <math.h>
#include <stdio.h>

// Test the same scalar functions that are compiled into the GLSL shaders.
#include "../shaders/direct_visibility_weights.glsl"

static int near(double a, double b)
{
	return fabs(a - b) < 0.00002;
}

int main(void)
{
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
	puts("PASS: initial visibility, MIS/integral/variance, stable shading and legacy W clamp");
	return 0;
}
