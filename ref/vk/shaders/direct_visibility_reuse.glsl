// Efficient Visibility Reuse for Real-time ReSTIR, Yusuke Tokuyoshi (2024).
// Paper DOI: 10.1145/3641233.3664320. Supplementary Algorithm 1 and Eqs. (1-4).
// Implemented from the published equations, without importing an SDK.
// The sample domain is (light ID, replay random numbers), hence T is identity
// and its Jacobian is one. Concrete contributions include the light's internal
// area/direction proposal correction; ReGIR supplies the discrete proposal PDF.

#include "direct_visibility_weights.glsl"
#include "direct_visibility_window.glsl"

#if !RIS_SPLIT_LOBE_RESERVOIRS || !RIS_DIRECT_DIFFUSE_REGIR_REVERT || !RIS_REGIR_ONLY
#error Direct visibility reuse requires the current split direct ReGIR layout
#endif

#if LIGHT_POINT
#define VIS_OUT_RESERVOIR RIS_POINT_OUT_TEMPORAL_RESERVOIR_IMAGE
#define VIS_OUT_RANDOM RIS_POINT_OUT_TEMPORAL_RANDOM_IMAGE
#define VIS_PREV_RESERVOIR RIS_POINT_PREV_TEMPORAL_RESERVOIR_IMAGE
#define VIS_PREV_RANDOM RIS_POINT_PREV_TEMPORAL_RANDOM_IMAGE
#define VIS_LIGHT_COUNT lights.m.num_point_lights
#else
#define VIS_OUT_RESERVOIR RIS_POLY_OUT_TEMPORAL_RESERVOIR_IMAGE
#define VIS_OUT_RANDOM RIS_POLY_OUT_TEMPORAL_RANDOM_IMAGE
#define VIS_PREV_RESERVOIR RIS_POLY_PREV_TEMPORAL_RESERVOIR_IMAGE
#define VIS_PREV_RANDOM RIS_POLY_PREV_TEMPORAL_RANDOM_IMAGE
#define VIS_LIGHT_COUNT lights.m.num_polygons
#endif

struct RisVisibilitySurface {
	vec3 P;
	vec3 geometry_N;
	vec3 shading_N;
	vec3 V;
	MaterialProperties material;
};

struct RisVisibilityReservoir {
	RisTemporalReservoir reservoir;
	float visibility;
	RisVisibilityWindow window;
};

RisVisibilityReservoir risVisibilityEmpty()
{
	RisVisibilityReservoir r;
	r.reservoir = risInvalidTemporalReservoir();
	r.visibility = 0.0;
	r.window = RisVisibilityWindow(0u, 0u, 0u);
	return r;
}

bool risVisibilityHasSample(RisVisibilityReservoir r)
{
	return r.reservoir.light_id != RIS_INVALID_LIGHT_ID &&
		r.reservoir.mixed_weight > 0.0 && r.reservoir.sample_count > 0.0 &&
		r.reservoir.weight_sum > 0.0;
}

bool risVisibilityTestInitialCandidates()
{
	return (ubo.ubo.renderer_flags & RENDERER_FLAG_DIRECT_VISIBILITY_CANDIDATES) != 0u;
}

bool risVisibilityMedianEnabled()
{
	return (ubo.ubo.renderer_flags & RENDERER_FLAG_DIRECT_VISIBILITY_MEDIAN) != 0u;
}

bool risVisibilityGradientEnabled()
{
	return (ubo.ubo.renderer_flags & RENDERER_FLAG_DIRECT_VISIBILITY_GRADIENT) != 0u;
}

float risVisibilityHistoryTag()
{
	// Isolate both diagnostic switches: neither candidate visibility nor the
	// ReGIR/uniform proposal comparison should inherit the other path's mass.
	const bool uniform_proposals = (ubo.ubo.renderer_flags & RENDERER_FLAG_DISABLE_REGIR) != 0u;
	const float window_method = risVisibilityGradientEnabled() ? 2.0 : (risVisibilityMedianEnabled() ? 1.0 : 0.0);
	return 96.0 + (risVisibilityTestInitialCandidates() ? 1.0 : 0.0) +
		(uniform_proposals ? 2.0 : 0.0) + 4.0 * window_method;
}

bool risVisibilityUnshadowedWeights(RIS_LIGHT_SAMPLE light, vec3 sample_random,
	RisVisibilitySurface s, out vec2 weights)
{
	// User-requested direct diffuse proxy: geometry normal for selection and
	// all temporal cross-targets; specular keeps its shading-normal target.
	// Final shading still evaluates both lobes with the shading normal.
	vec3 geometry_diffuse;
	vec3 unused_geometry_specular;
	const bool geometry_valid = risEvaluateConcreteSample(light, sample_random,
		s.P, s.geometry_N, s.V, s.material, false,
		geometry_diffuse, unused_geometry_specular);
	vec3 unused_shading_diffuse;
	vec3 shading_specular;
	const bool shading_valid = risEvaluateConcreteSample(light, sample_random,
		s.P, s.shading_N, s.V, s.material, false,
		unused_shading_diffuse, shading_specular);
	const vec2 geometry_weights = geometry_valid
		? risContributionLobeWeights(geometry_diffuse, vec3(0.0)) : vec2(0.0);
	const vec2 shading_weights = shading_valid
		? risContributionLobeWeights(vec3(0.0), shading_specular) : vec2(0.0);
	weights = vec2(geometry_weights.x, shading_weights.y);
	return any(greaterThan(weights, vec2(0.0)));
}

float risVisibilityTarget(RisVisibilityReservoir r, RisVisibilitySurface s, int lobe)
{
	RIS_LIGHT_SAMPLE light;
	vec2 weights;
	if (r.reservoir.light_id == RIS_INVALID_LIGHT_ID || !RIS_LOAD_LIGHT(r.reservoir.light_id, light) ||
		!risVisibilityUnshadowedWeights(light, r.reservoir.sample_random, s, weights)) {
		return 0.0;
	}
	return risUnifiedTargetWeight(weights, s.material, lobe);
}

bool risVisibilityResolveLight(inout RisTemporalReservoir reservoir)
{
	if (RIS_LIGHT_HASH_MATCHES(reservoir.light_id, reservoir.light_hash)) {
		return true;
	}
	const uint original = reservoir.light_id;
	for (uint distance = 1u; distance <= uint(RIS_TEMPORAL_LIGHT_ID_SEARCH_RADIUS); ++distance) {
		if (original >= distance && RIS_LIGHT_HASH_MATCHES(original - distance, reservoir.light_hash)) {
			reservoir.light_id = original - distance;
			return true;
		}
		if (original + distance > original && RIS_LIGHT_HASH_MATCHES(original + distance, reservoir.light_hash)) {
			reservoir.light_id = original + distance;
			return true;
		}
	}
	// Reusing a different light with the old p_hat/W/V is not a valid mapping.
	// Unlike the legacy resolver, do not keep an unverified current array slot.
	return false;
}

float risVisibilityTrace(RisVisibilityReservoir r, RisVisibilitySurface s)
{
	RIS_LIGHT_SAMPLE light;
	return r.reservoir.light_id != RIS_INVALID_LIGHT_ID && RIS_LOAD_LIGHT(r.reservoir.light_id, light) &&
		RIS_CONCRETE_SAMPLE_VISIBLE(light, r.reservoir.sample_random, s.P, s.geometry_N) ? 1.0 : 0.0;
}

RisVisibilityReservoir risVisibilityDecode(vec4 encoded, vec4 random_count, float visibility)
{
	RisVisibilityReservoir r;
	r.reservoir = risInvalidTemporalReservoir();
	// Packed integers are exact in RGBA32F. Do not add 0.5: above 2^23
	// that would round odd integers up and corrupt the light hash.
	const uint light_count = uint(max(encoded.x, 0.0));
	const uint hash_window = uint(max(encoded.y, 0.0));
	r.reservoir.light_id = risDecodeLightId(float(light_count & 2047u));
	r.reservoir.light_hash = hash_window & RIS_TEMPORAL_HASH_MASK;
	r.window = risVisibilityUnpackWindow(light_count, hash_window);
	r.reservoir.mixed_weight = max(encoded.z, 0.0);
	r.reservoir.weight_sum = max(encoded.w, 0.0);
	r.reservoir.sample_random = clamp(random_count.xyz, vec3(0.0), vec3(1.0));
	// Preserve M even when W is zero, as required by Algorithm 1.
	r.reservoir.sample_count = max(random_count.w, 0.0);
	r.visibility = clamp(visibility, 0.0, 1.0);
	return r;
}

vec4 risVisibilityEncode(RisVisibilityReservoir r)
{
	if (!risVisibilityHasSample(r)) {
		return vec4(0.0);
	}
	return vec4(float(risVisibilityPackLightCount(uint(risEncodeLightId(r.reservoir.light_id)), r.window.count)),
		float(risVisibilityPackHashWindow(r.reservoir.light_hash, r.window)),
		r.reservoir.mixed_weight, r.reservoir.weight_sum);
}

void risVisibilityStore(ivec2 pix, RisVisibilityReservoir r[2])
{
	imageStore(VIS_OUT_RESERVOIR, pix, risVisibilityEncode(r[0]));
	imageStore(VIS_OUT_RANDOM, pix, vec4(r[0].reservoir.sample_random, r[0].reservoir.sample_count));
	imageStore(RIS_SPLIT_OUT_SPECULAR_RESERVOIR_IMAGE, pix, risVisibilityEncode(r[1]));
	imageStore(RIS_SPLIT_OUT_SPECULAR_RANDOM_IMAGE, pix, vec4(r[1].reservoir.sample_random, r[1].reservoir.sample_count));
	// Existing RGBA16F auxiliary image: x is reserved for legacy ReGIR PDF,
	// y/z are diffuse/specular visibility, w tags incompatible history modes.
	imageStore(RIS_OUT_DIFFUSE_REGIR_INV_PDF_IMAGE, pix,
		vec4(0.0, r[0].visibility, r[1].visibility, risVisibilityHistoryTag()));
}

void risVisibilityLoad(ivec2 pix, out RisVisibilityReservoir r[2])
{
	r[0] = risVisibilityEmpty();
	r[1] = risVisibilityEmpty();
	const vec4 meta = imageLoad(RIS_PREV_DIFFUSE_REGIR_INV_PDF_IMAGE, pix);
	// Temporal-only format: do not import the former initial-only mode's history.
	if (meta.w != risVisibilityHistoryTag()) {
		return;
	}
	r[0] = risVisibilityDecode(imageLoad(VIS_PREV_RESERVOIR, pix), imageLoad(VIS_PREV_RANDOM, pix), meta.y);
	r[1] = risVisibilityDecode(imageLoad(RIS_SPLIT_PREV_SPECULAR_RESERVOIR_IMAGE, pix),
		imageLoad(RIS_SPLIT_PREV_SPECULAR_RANDOM_IMAGE, pix), meta.z);

}

RisVisibilityReservoir risVisibilityResample(
	RisVisibilityReservoir a, RisVisibilitySurface sa,
	RisVisibilityReservoir b, RisVisibilitySurface sb, int lobe, float random_select)
{
	// Talbot MIS, supplementary Eq. (3). Evaluate both source targets at both
	// samples; a is already expressed in the receiver's domain.
	const float paa = a.reservoir.mixed_weight;
	const float pba = risVisibilityTarget(a, sb, lobe);
	const float pab = risVisibilityTarget(b, sa, lobe);
	const float pbb = b.reservoir.mixed_weight;
	const float ma = a.reservoir.sample_count;
	const float mb = b.reservoir.sample_count;
	const float wa = risVisibilityResamplingWeight(ma, paa, mb, pba, a.reservoir.weight_sum, paa);
	const float wb = risVisibilityResamplingWeight(mb, pbb, ma, pab, b.reservoir.weight_sum, pab);
	const float total = wa + wb;
	RisVisibilityReservoir result = risVisibilityEmpty();
	result.reservoir.sample_count = ma + mb;
	if (!(total > 0.0) || isnan(total) || isinf(total)) {
		return result;
	}
	const bool select_b = wa == 0.0 || random_select * total < wb;
	result.reservoir = select_b ? b.reservoir : a.reservoir;
	result.reservoir.sample_count = ma + mb;
	result.reservoir.mixed_weight = select_b ? pab : paa;
	// Store M * p_hat(X) * W_X in the engine's existing reservoir layout.
	result.reservoir.weight_sum = total * result.reservoir.sample_count;
	result.visibility = risVisibilityAverage(a.visibility, wa, b.visibility, wb);
	// A new replay point on the same source must not erase its frame window.
	// A different selected source starts its own detector, independently of WIS.
	result.window = risVisibilityWindowSelect(result.reservoir.light_id, result.reservoir.light_hash,
		b.reservoir.light_id, b.reservoir.light_hash, b.window, result.visibility >= 0.5 ? 1u : 0u);
	return result;
}

bool risVisibilityMeasureWindow(inout RisVisibilityReservoir r,
	RisVisibilitySurface surface, ivec2 pix, int lobe)
{
	if (!risVisibilityHasSample(r)) {
		return false;
	}
	RIS_LIGHT_SAMPLE light;
	if (!RIS_LOAD_LIGHT(r.reservoir.light_id, light)) {
		r = risVisibilityEmpty();
		return false;
	}
	// Track the source, not a frozen replay point. Each frame gets a fresh point
	// even with rt_debug_fixed_random_seed, without modifying the lighting RNG.
	uint probe_rng = xxhash32(uvec4(uint(pix.x), uint(pix.y), ubo.ubo.frame_counter,
		r.reservoir.light_id ^ RIS_PRIMARY_MERGE_RANDOM_SALT ^ (uint(lobe) * 0x9e3779b9u)));
	const vec3 probe_random = vec3(regirRandom(probe_rng), regirRandom(probe_rng), regirRandom(probe_rng));
	const uint visible = RIS_CONCRETE_SAMPLE_VISIBLE(light, probe_random, surface.P, surface.geometry_N) ? 1u : 0u;
	if (r.window.count == 0u) {
		r.window.median = r.visibility >= 0.5 ? 1u : 0u;
	}
	const RisVisibilityWindow previous_window = r.window;
	r.window = risVisibilityWindowPush(r.window, visible);
	const bool entered_full_light = risVisibilityWindowEnteredFullLight(previous_window, r.window);
	if (risVisibilityGradientEnabled()) {
		r.visibility = risVisibilityWindowGradientUpdate(r.window, r.visibility);
	} else if (risVisibilityWindowShouldReset(r.window)) {
		r.window.median = risVisibilityWindowOnes(r.window.bits) >= 4u ? 1u : 0u;
		r.visibility = float(r.window.median);
	}
	if (r.window.count == 7u && r.visibility == 0.0) {
		// Explicitly permitted full reset after the seven-frame decision.
		r = risVisibilityEmpty();
	}
	return entered_full_light;
}

vec3 risVisibilityView(ivec2 pix, mat4 inv_proj, mat4 inv_view)
{
	const vec2 uv = (vec2(pix) + vec2(0.5)) / vec2(ubo.ubo.res) * 2.0 - 1.0;
	const vec4 target = inv_proj * vec4(uv, 1.0, 1.0);
	return -normalize((inv_view * vec4(target.xyz, 0.0)).xyz);
}

RisVisibilitySurface risVisibilityPreviousSurface(ivec2 pix)
{
	RisVisibilitySurface s;
	const vec4 position_roughness = imageLoad(prev_temporal_ris_visibility_position, pix);
	const vec4 packed = imageLoad(prev_temporal_ris_visibility_normals, pix);
	const vec4 material = imageLoad(prev_temporal_ris_visibility_material, pix);
	s.geometry_N = normalDecode(packed.xy);
	s.shading_N = normalDecode(packed.zw);
	s.P = position_roughness.xyz + s.geometry_N * 0.001;
	s.V = risVisibilityView(pix, ubo.ubo.prev_inv_proj, ubo.ubo.prev_inv_view);
	s.material.roughness = position_roughness.w;
	s.material.base_color = SRGBtoLINEAR(material.rgb);
	s.material.metalness = material.a;
	return s;
}

void risVisibilityInitial(vec3 P, vec3 geometry_N, vec3 N, vec3 V,
	MaterialProperties material, ivec2 pix, bool ris_active, out RisVisibilityReservoir r[2])
{
	r[0] = risVisibilityEmpty();
	r[1] = risVisibilityEmpty();
	if (ubo.ubo.di_visibility_reuse == 0u || !risReservoirPixelInBounds(pix)) {
		return;
	}
	RisVisibilitySurface s = RisVisibilitySurface(P, geometry_N, N, V, material);
	if (ris_active) {
		uint rng = regirHash(ubo.ubo.random_seed ^ uint(pix.x) * 1833u ^
			uint(pix.y) * 31337u ^ RIS_PRIMARY_MERGE_RANDOM_SALT);
		uint cell = 0u;
		const bool use_regir = (ubo.ubo.renderer_flags & RENDERER_FLAG_DISABLE_REGIR) == 0u;
		const bool have_cell = use_regir && regirSelectOnionCell(P, rng, cell);
		const uint candidate_count = use_regir ? uint(REGIR_ONION_LOOKUP_CANDIDATES) : uint(RIS_PRIMARY_CANDIDATES);
		const bool test_candidate_visibility = risVisibilityTestInitialCandidates();
		for (uint j = 0u; j < candidate_count; ++j) {
			RegirOnionCandidate proposal;
			if (use_regir) {
				if (!have_cell || !regirLoadOnionCandidate(cell, j, rng, proposal)) {
					continue;
				}
			} else {
				if (VIS_LIGHT_COUNT == 0u) {
					break;
				}
				proposal.light_id = min(uint(regirRandom(rng) * float(VIS_LIGHT_COUNT)), VIS_LIGHT_COUNT - 1u);
				proposal.inv_source_pdf = float(VIS_LIGHT_COUNT);
			}
			RIS_LIGHT_SAMPLE light;
			const vec3 sample_random = vec3(regirRandom(rng), regirRandom(rng), regirRandom(rng));
			const bool loaded = RIS_LOAD_LIGHT(proposal.light_id, light);
			vec2 candidate_weights = vec2(0.0);
			if (loaded) {
				risVisibilityUnshadowedWeights(light, sample_random, s, candidate_weights);
			}
			// Full-visibility initial RIS: trace once per candidate, shared by both
			// lobes, before its mass can enter either reservoir's weight sum.
			const bool candidate_visible = !test_candidate_visibility ||
				(loaded && any(greaterThan(candidate_weights, vec2(0.0))) &&
				 RIS_CONCRETE_SAMPLE_VISIBLE(light, sample_random, s.P, s.geometry_N));
			for (int lobe = 0; lobe < 2; ++lobe) {
				r[lobe].reservoir.sample_count += 1.0;
				const float target = risUnifiedTargetWeight(candidate_weights, material, lobe);
				const float mass = risVisibilityInitialCandidateMass(target, proposal.inv_source_pdf,
					candidate_visible ? 1.0 : 0.0);
				if (!(mass > 0.0) || isnan(mass) || isinf(mass)) {
					continue;
				}
				const float total = r[lobe].reservoir.weight_sum + mass;
				if (r[lobe].reservoir.weight_sum == 0.0 || regirRandom(rng) * total < mass) {
					r[lobe].reservoir.light_id = proposal.light_id;
					r[lobe].reservoir.light_hash = RIS_LIGHT_HASH(light);
					r[lobe].reservoir.sample_random = sample_random;
					r[lobe].reservoir.mixed_weight = target;
				}
				r[lobe].reservoir.weight_sum = total;
			}
		}
		// Algorithm 1 uses winner-only visibility. With full candidate visibility,
		// every selectable winner has already passed the same shadow test.
		for (int lobe = 0; lobe < 2; ++lobe) {
			r[lobe].visibility = test_candidate_visibility
				? (risVisibilityHasSample(r[lobe]) ? 1.0 : 0.0)
				: risVisibilityTrace(r[lobe], s);
			if (r[lobe].visibility == 0.0) {
				r[lobe].reservoir.weight_sum = 0.0;
			}
		}
		// Keep the actual fresh estimator, including visibility rejection and M.
		// A detector-triggered restart must not synthesize W from visibility.
		RisVisibilityReservoir initial[2];
		initial[0] = r[0];
		initial[1] = r[1];
		ivec2 history_pix;
		if (imageLoad(temporal_reprojection_ready, pix).r > 0.5 &&
			temporalReprojectionDecodePixel(imageLoad(temporal_reprojection_map, pix).rg, ubo.ubo.res, history_pix)) {
			RisVisibilityReservoir history[2];
			risVisibilityLoad(history_pix, history);
			const RisVisibilitySurface hs = risVisibilityPreviousSurface(history_pix);
			for (int lobe = 0; lobe < 2; ++lobe) {
				if (history[lobe].reservoir.sample_count <= 0.0) {
					continue;
				}
				if (risVisibilityHasSample(history[lobe]) &&
					!risVisibilityResolveLight(history[lobe].reservoir)) {
					continue;
				}
				// Standard ReSTIR temporal confidence cap; rescale stored mass so W
				// stays unchanged. No random reset or ReGIR revert in the paper path.
				const float old_count = history[lobe].reservoir.sample_count;
				const float capped = min(old_count,
					ubo.ubo.di_visibility_history * max(r[lobe].reservoir.sample_count, 1.0));
				history[lobe].reservoir.weight_sum *= capped / old_count;
				history[lobe].reservoir.sample_count = capped;
				r[lobe] = risVisibilityResample(r[lobe], s, history[lobe], hs, lobe, regirRandom(rng));
			}
		}
		if (risVisibilityMedianEnabled() || risVisibilityGradientEnabled()) {
			for (int lobe = 0; lobe < 2; ++lobe) {
				if (risVisibilityMeasureWindow(r[lobe], s, pix, lobe)) {
					// Confirmed shadow-to-light transition: discard old mass and M.
					// Keep the full window only if the fresh winner is the same source;
					// another source must not inherit these visibility measurements.
					initial[lobe].window = risVisibilityWindowSelect(
						initial[lobe].reservoir.light_id, initial[lobe].reservoir.light_hash,
						r[lobe].reservoir.light_id, r[lobe].reservoir.light_hash,
						r[lobe].window, initial[lobe].visibility >= 0.5 ? 1u : 0u);
					r[lobe] = initial[lobe];
				}
			}
		}
	}
	risVisibilityStore(pix, r);
}

void risVisibilityShadeReservoirs(RisVisibilityReservoir r[2], vec3 P, vec3 N, vec3 V,
	MaterialProperties material, out vec3 diffuse, out vec3 specular)
{
	diffuse = vec3(0.0);
	specular = vec3(0.0);
	for (int lobe = 0; lobe < 2; ++lobe) {
		RIS_LIGHT_SAMPLE light;
		vec3 d;
		vec3 sp;
		if (!risVisibilityHasSample(r[lobe]) || !RIS_LOAD_LIGHT(r[lobe].reservoir.light_id, light) ||
			!risEvaluateConcreteSample(light, r[lobe].reservoir.sample_random, P, N, V, material, false, d, sp)) {
			continue;
		}
		// Eq. (5), with an optional legacy W clamp for the diagnostic comparison.
		const float target = r[lobe].reservoir.mixed_weight;
		const float mass = r[lobe].reservoir.weight_sum;
		const float count = r[lobe].reservoir.sample_count;
		const float visibility = r[lobe].visibility;
		const vec3 contribution = lobe == 0 ? d : sp;
		vec3 shaded = vec3(
			risVisibilityShade(contribution.r, target, mass, count, visibility),
			risVisibilityShade(contribution.g, target, mass, count, visibility),
			risVisibilityShade(contribution.b, target, mass, count, visibility));
		if ((ubo.ubo.renderer_flags & RENDERER_FLAG_DIRECT_VISIBILITY_WEIGHT_CLAMP) != 0u) {
			shaded = vec3(
				risVisibilityShadeLegacyClamp(contribution.r, target, mass, count, visibility,
					RIS_WEIGHT_EPSILON, float(RIS_SHADE_RESERVOIR_WEIGHT_MAX)),
				risVisibilityShadeLegacyClamp(contribution.g, target, mass, count, visibility,
					RIS_WEIGHT_EPSILON, float(RIS_SHADE_RESERVOIR_WEIGHT_MAX)),
				risVisibilityShadeLegacyClamp(contribution.b, target, mass, count, visibility,
					RIS_WEIGHT_EPSILON, float(RIS_SHADE_RESERVOIR_WEIGHT_MAX)));
		}
		if (lobe == 0) {
			diffuse = shaded;
		} else {
			specular = shaded;
		}
	}
}

#undef VIS_OUT_RESERVOIR
#undef VIS_OUT_RANDOM
#undef VIS_PREV_RESERVOIR
#undef VIS_PREV_RANDOM
#undef VIS_LIGHT_COUNT
