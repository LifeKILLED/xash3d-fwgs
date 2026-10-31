#include "lightcache_geometry.glsl"
#include "utils.glsl"
bool risLoadSpatialSurface(ivec2 pix, out vec3 P, out vec3 N);
// Cache history lives about 5000 frames on average; screen RIS keeps its own lifetime.
#define RIS_TEMPORAL_RANDOM_RESET_PROBABILITY (1.0 / 5000.0)
// Weight confidence is allowed to reject history; world-space geometry is not.
#define RIS_TEMPORAL_SHADING_CONFIDENCE 1
#include "light_ris_common.glsl"
#include "regir_onion.glsl"
// The cache has no screen-space surface; these functions only satisfy the
// shared RIS interface. Cache history is addressed by stable probe indices.
bool risLoadSpatialSurface(ivec2 pix, out vec3 P, out vec3 N) { P = vec3(0); N = vec3(0,0,1); return false; }
#include "light_ris_lights.glsl"
#include "direct_visibility_weights.glsl"
#include "direct_visibility_window.glsl"

uint lcLightCount() {
#if LIGHT_POINT
    return lights.m.num_point_lights;
#else
    return lights.m.num_polygons;
#endif
}
bool lcLoadLight(uint id, out RisLightSample light) {
    if (id >= lcLightCount()) return false;
    light.light_id = id;
#if LIGHT_POINT
    light.light = lights.m.point_lights[id];
#else
    light.light = lights.m.polygons[id];
#endif
    return true;
}
bool lcLightHashMatches(uint id, uint hash) {
    RisLightSample light;
    return lcLoadLight(id, light) && risLightHash(light) == hash;
}
bool lcLightSlotValid(uint id) { return id < lcLightCount(); }
#define RIS_ID_RECOVERY_FUNCTION lcRecoverLightId
#define RIS_ID_RECOVERY_HASH_MATCHES lcLightHashMatches
#define RIS_ID_RECOVERY_SLOT_VALID lcLightSlotValid
#include "light_id_recovery.glsl"

// Concrete emitter sample is fixed in lightmap space, independent of frame,
// random_seed, packed storage coordinates, and the brush's world transform.
vec3 lcStableSampleRandom(uint index, uint light_id) {
    LightcacheProbe probe = lightcache_geometry.probes[index];
    uvec2 local = uvec2(probe.local_index % probe.width, probe.local_index / probe.width);
    uvec2 lm_texel = uvec2(probe.lm_s, probe.lm_t) + 2u * local;
    uint seed = xxhash32(uvec4(lm_texel, light_id, uint(LIGHT_POINT)));
    return vec3(
        uintToFloat01(xxhash32(uvec2(seed, 0x6c637378u))),
        uintToFloat01(xxhash32(uvec2(seed, 0x6c637379u))),
        uintToFloat01(xxhash32(uvec2(seed, 0x6c63737au))));
}

MaterialProperties lcMaterial() {
    MaterialProperties m; m.base_color = vec3(1); m.metalness = 0; m.roughness = 1; return m;
}
// Exactly the saved concrete RIS sample direction, including finite-size lights.
bool lcSample(RisLightSample light, vec3 rnd, vec3 P, vec3 N,
              bool visibility, out vec3 diffuse, out vec3 direction) {
    vec3 specular;
#if LIGHT_POINT
    PointLight p = light.light;
    vec3 axis = p.environment != 0u ? p.dir_stopdot2.xyz : normalize(p.origin_r2.xyz - P);
    float d2 = dot(p.origin_r2.xyz - P, p.origin_r2.xyz - P);
    float cone = p.environment != 0u ? p.dir_stopdot2.w : sqrt(max(0.0, 1.0 - p.origin_r2.w / max(d2, 1e-8)));
    direction = normalize(orthonormalBasisZ(axis) * sampleConeZ(rnd.yz, cone));
#else
    vec3 pos; float inv_pdf;
    if (!risSampleAreaPolygon(light.light, rnd, pos, inv_pdf)) { diffuse = vec3(0); direction = N; return false; }
    direction = normalize(pos - P);
#endif
    return risEvaluateConcreteSample(light, rnd, P, N, N, lcMaterial(), visibility, diffuse, specular);
}

bool lcHistoryReady(ivec2 hp, ivec2 res) {
    vec4 state = imageLoad(prev_temporal_lightcache_state, hp);
    return state.x == float(lightcache_geometry.info.y) && all(equal(state.yz, vec2(res))) &&
        state.w + 1.0 == float(ubo.ubo.frame_counter);
}
RisVisibilityWindow lcWindow(vec4 meta) {
    return RisVisibilityWindow(uint(meta.y), uint(meta.z), uint(meta.w));
}
void main() {
    ivec2 pix = ivec2(gl_GlobalInvocationID.xy), res = ubo.ubo.res;
    if (any(greaterThanEqual(pix, res)) || !lightcacheEnabled()) return;
    if (lightcacheUpdateDisabled()) {
        // Carry history through the normal ping-pong without tracing or RIS.
        bool valid = lcHistoryReady(pix, res);
        imageStore(LC_OUT_RESERVOIR, pix, valid ? imageLoad(LC_PREV_RESERVOIR, pix) : vec4(0));
        imageStore(LC_OUT_RANDOM, pix, valid ? imageLoad(LC_PREV_RANDOM, pix) : vec4(0));
        imageStore(LC_OUT_VISIBILITY, pix, valid ? imageLoad(LC_PREV_VISIBILITY, pix) : vec4(0));
#if LIGHT_POINT
        vec4 state = valid ? imageLoad(prev_temporal_lightcache_state, pix) : vec4(0);
        if (valid) state.w = float(ubo.ubo.frame_counter);
        imageStore(out_temporal_lightcache_state, pix, state);
#endif
        return;
    }
    uint index = uint(pix.y * res.x + pix.x);
    bool cache_active = lightcacheEnabled() && lightcacheInCapacity(index, res);
    RisTemporalReservoir r = risInvalidTemporalReservoir();
    RisVisibilityWindow window = RisVisibilityWindow(0u, 0u, 0u);
    float visibility = 0.0;
    vec3 radiance = vec3(0), direction = vec3(0,0,1);
    rand01_state = xxhash32(uvec4(index, ubo.ubo.random_seed, ubo.ubo.frame_counter, uint(LIGHT_POINT)));
    if (cache_active) {
        vec3 P, N; lightcacheSurface(index, P, N);
        // Identity reprojection: a lightmap texel always inherits itself.
        // Brush motion/rotation changes only current P/N and the target weight,
        // never the history address or surface eligibility. No permutations.
        const ivec2 hp = pix;
        RisTemporalReservoir history = risInvalidTemporalReservoir();
        float history_visibility = 0.0;
        if (lcHistoryReady(hp, res)) {
            history = risDecodeTemporalReservoir(imageLoad(LC_PREV_RESERVOIR, hp));
            vec4 random_count = imageLoad(LC_PREV_RANDOM, hp);
            history.sample_random = random_count.xyz;
            history.sample_count = random_count.w;
            vec4 meta = imageLoad(LC_PREV_VISIBILITY, hp);
            history_visibility = meta.x;
            window = lcWindow(meta);
            if (risTemporalReservoirValid(history))
                history.light_id = lcRecoverLightId(history.light_id, history.light_hash);
            RisLightSample old; vec3 d, l;
            if (risTemporalReservoirValid(history) && lcLoadLight(history.light_id, old) &&
                lcSample(old, history.sample_random, P, N, false, d, l)) {
                float target = luminance(d);
                // Hash changes (e.g. moving light geometry) are not surface
                // rejection. Re-evaluate the current slot, then apply only
                // target-weight confidence and the independent lifetime test.
                const uint current_hash = risLightHash(old);
                window = risVisibilityWindowSelect(history.light_id, current_hash,
                    history.light_id, history.light_hash, window, history_visibility >= 0.5 ? 1u : 0u);
                history.light_hash = current_hash;
                history = risReweightTemporalReservoir(history, target, target, rand01());
                float cap = max(4.0, 4.0 * ubo.ubo.di_visibility_history);
                if (history.sample_count > cap) { history.weight_sum *= cap / history.sample_count; history.sample_count = cap; }
            } else history = risInvalidTemporalReservoir();
        }
        uint count = lcLightCount();
#if !RIS_UNIFORM_LIGHT_CANDIDATES
        uint proposal_rng = rand01_state;
        uint cell = 0u;
        bool use_regir = (ubo.ubo.renderer_flags & RENDERER_FLAG_DISABLE_REGIR) == 0u &&
            regirSelectOnionCell(P, proposal_rng, cell);
#endif
        // Includes sky and flashlights in the same uniform proposal domain.
        for (uint i = 0u; i < uint(RIS_PRIMARY_CANDIDATES) && count > 0u; ++i) {
            RegirOnionCandidate proposal;
#if !RIS_UNIFORM_LIGHT_CANDIDATES
            if (use_regir) {
                if (!regirLoadOnionCandidate(cell, i, proposal_rng, proposal)) { r.sample_count += 1.0; continue; }
            } else
#endif
            {
            proposal.light_id = min(uint(rand01() * float(count)), count - 1u);
            proposal.inv_source_pdf = float(count);
            }
            RisLightSample light; vec3 d, l; vec3 rnd = lcStableSampleRandom(index, proposal.light_id);
            if (!lcLoadLight(proposal.light_id, light) || !lcSample(light, rnd, P, N, false, d, l) || luminance(d) <= RIS_WEIGHT_EPSILON) {
                r.sample_count += 1.0; continue;
            }
            RisTemporalCandidate candidate;
            candidate.light_id = proposal.light_id; candidate.light_hash = risLightHash(light);
            candidate.mixed_weight = luminance(d);
            candidate.sample_random = rnd; candidate.sample_count = 1.0;
            r = risMergeTemporalCandidateWeighted(r, candidate, candidate.mixed_weight * proposal.inv_source_pdf, rand01());
        }
#if LIGHT_POINT && !RIS_UNIFORM_LIGHT_CANDIDATES
        // ReGIR excludes sky/flashlight sources: add their separate stratum.
        if (use_regir) for (uint id = 0u; id < count; ++id) {
            PointLight point = lights.m.point_lights[id];
            if (point.environment == 0u && point.flashlight == 0u) continue;
            RisLightSample light; vec3 d, l; vec3 rnd = lcStableSampleRandom(index, id);
            if (!lcLoadLight(id, light) || !lcSample(light, rnd, P, N, false, d, l) || luminance(d) <= RIS_WEIGHT_EPSILON) continue;
            RisTemporalCandidate candidate;
            candidate.light_id = id; candidate.light_hash = risLightHash(light);
            candidate.mixed_weight = luminance(d);
            candidate.sample_random = rnd; candidate.sample_count = 1.0;
            r = risMergeTemporalCandidateWeighted(r, candidate,
                candidate.mixed_weight * float(REGIR_ONION_LOOKUP_CANDIDATES), rand01());
            r.sample_count -= 1.0;
        }
#endif
        // Winner-only visibility for the fresh estimator, as in DI Algorithm 1.
        RisLightSample fresh; vec3 d, l;
        float fresh_visibility = risTemporalReservoirValid(r) && lcLoadLight(r.light_id, fresh) &&
            lcSample(fresh, r.sample_random, P, N, true, d, l) ? 1.0 : 0.0;
        if (fresh_visibility == 0.0) r.weight_sum = 0.0;
        float fresh_mass = r.weight_sum;
        float history_mass = risTemporalReservoirValid(history) ? history.weight_sum : 0.0;
        float total_mass = fresh_mass + history_mass;
        float total_count = r.sample_count + (history_mass > 0.0 ? history.sample_count : 0.0);
        if (total_mass > 0.0) {
            // Both reservoirs have been expressed in the current receiver domain.
            // Eq. (3) then reduces to mass-proportional selection; Eq. (4) reuses
            // visibility with the same weights. Reservoir and SH data stay separate.
            bool select_history = fresh_mass == 0.0 || rand01() * total_mass < history_mass;
            r = select_history ? history : r;
            r.weight_sum = total_mass; r.sample_count = total_count;
            visibility = risVisibilityAverage(fresh_visibility, fresh_mass, history_visibility, history_mass);
            window = risVisibilityWindowSelect(r.light_id, r.light_hash, history.light_id, history.light_hash,
                window, visibility >= 0.5 ? 1u : 0u);
            // Observe the same concrete point used by selection and shading.
            // Moving geometry still changes visibility; frames do not move the
            // sample on the emitter for an otherwise unchanged texel/source.
            RisLightSample selected;
            if (lcLoadLight(r.light_id, selected)) {
                bool visible = lcSample(selected, r.sample_random, P, N, true, d, l);
                window = risVisibilityWindowPush(window, visible ? 1u : 0u);
                if ((ubo.ubo.renderer_flags & RENDERER_FLAG_DIRECT_VISIBILITY_GRADIENT) != 0u)
                    visibility = risVisibilityWindowGradientUpdate(window, visibility);
                else if ((ubo.ubo.renderer_flags & RENDERER_FLAG_DIRECT_VISIBILITY_MEDIAN) != 0u && risVisibilityWindowShouldReset(window)) {
                    window.median = risVisibilityWindowOnes(window.bits) >= 4u ? 1u : 0u;
                    visibility = float(window.median);
                }
                visibility = risVisibilityWindowSelectVisibility(window, visibility);
                if (window.count == 7u && window.bits == 0u) { r = risInvalidTemporalReservoir(); visibility = 0.0; }
                if (risTemporalReservoirValid(r) && lcSample(selected, r.sample_random, P, N, false, d, direction)) {
                    // Remove the receiver cosine: SH projection supplies the angular response.
                    radiance = d * min(r.weight_sum / max(r.sample_count * r.mixed_weight, RIS_WEIGHT_EPSILON),
                        float(RIS_SHADE_RESERVOIR_WEIGHT_MAX)) * visibility / max(dot(N, direction), 1e-5);
                }
            }
        } else r = risInvalidTemporalReservoir();
    }
    imageStore(LC_OUT_RESERVOIR, pix, risEncodeTemporalReservoir(r));
    imageStore(LC_OUT_RANDOM, pix, risTemporalReservoirValid(r) ? vec4(r.sample_random, r.sample_count) : vec4(0));
    imageStore(LC_OUT_VISIBILITY, pix, vec4(visibility, float(window.bits), float(window.count), float(window.median)));
    imageStore(LC_OUT_RADIANCE, pix, vec4(min(radiance, vec3(60000)), 0));
    imageStore(LC_OUT_DIRECTION, pix, vec4(direction, 0));
#if LIGHT_POINT
    imageStore(out_temporal_lightcache_state, pix, cache_active ?
        vec4(float(lightcache_geometry.info.y), vec2(res), float(ubo.ubo.frame_counter)) : vec4(0));
#endif
}
