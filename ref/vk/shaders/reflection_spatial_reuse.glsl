#define GLSL
#include "ray_interop.h"
#include "utils.glsl"
#include "noise.glsl"
#include "color_spaces.glsl"
#include "brdf.glsl"

layout(local_size_x=8,local_size_y=8) in;
layout(set=0,binding=0) uniform UBO { UniformBuffer ubo; } ubo;
layout(set=0,binding=1,rgba16f) uniform readonly image2D indirect_specular;
layout(set=0,binding=2,rgba32f) uniform readonly image2D reflection_reuse_radiance;
layout(set=0,binding=3,rgba32f) uniform readonly image2D reflection_hit_pos;
layout(set=0,binding=4,rgba32f) uniform readonly image2D position_t;
layout(set=0,binding=5,rgba16f) uniform readonly image2D normals_gs;
layout(set=0,binding=6,rgba8) uniform readonly image2D material_rmxx;
layout(set=0,binding=7,rgba8) uniform readonly image2D base_color_a;
layout(set=0,binding=8,rgba16f) uniform writeonly image2D out_reflection_reused_specular;

const vec2 poisson[8] = vec2[8](
    vec2(-0.47,-0.44), vec2(-0.91,0.30), vec2(-0.35,0.40), vec2(0.10,0.64),
    vec2(0.57,0.35), vec2(0.29,-0.11), vec2(0.78,-0.42), vec2(0.16,-0.82));

float viewDepth(vec3 p) {
    return abs((ubo.ubo.view * vec4(p,1.0)).z);
}

bool inFrame(ivec2 p) {
    return all(greaterThanEqual(p,ivec2(0))) && all(lessThan(p,ubo.ubo.res));
}

vec3 reconstruct(ivec2 p, vec3 center) {
    vec4 surface = imageLoad(position_t,p);
    vec2 rm = imageLoad(material_rmxx,p).rg;
    vec4 centerHit = imageLoad(reflection_hit_pos,p);
    if (surface.w <= 0.0 || rm.x < 0.004 || centerHit.w <= 0.0 ||
        (ubo.ubo.renderer_flags & RENDERER_FLAG_REFLECTION_RECONSTRUCTION) == 0u)
        return center;

    vec4 normals = imageLoad(normals_gs,p);
    vec3 G = normalDecode(normals.xy);
    vec3 N = normalDecode(normals.zw);
    vec3 V = normalize(ubo.ubo.inv_view[3].xyz - surface.xyz);
    bool separated = (ubo.ubo.renderer_flags & RENDERER_FLAG_SEPARATED_REFLECTION) != 0u;
    MaterialProperties material = MaterialProperties(separated ? vec3(1) :
        SRGBtoLINEAR(imageLoad(base_color_a,p).rgb), separated ? 1.0 : rm.y, rm.x);
    float depth = max(viewDepth(surface.xyz),1e-5);
    float alpha = rm.x * rm.x;
    float pixelsPerWorld = abs(ubo.ubo.proj[1][1]) * float(ubo.ubo.res.y) / (2.0 * depth);
    float radius = min(2.0 * alpha * centerHit.w * pixelsPerWorld, RECON_MAX_RADIUS);
    if (radius < 1.0) return center;

    // Rotate the gather between frames while keeping adjacent texels decorrelated.
    float angle = 2.0*kPi*uintToFloat01(xxhash32(uvec4(uvec2(p),ubo.ubo.random_seed,0x706f6973u)));
    float c = cos(angle), s = sin(angle);
    mat2 rotation = mat2(c,s,-s,c);

#if RECON_USE_HIT_BOUNDS
    vec3 lower = centerHit.xyz, upper = centerHit.xyz;
    int hitCount = 1;
    for (int y=0; y<2; ++y) {
        for (int x=0; x<2; ++x) {
            ivec2 q = p + ivec2(x,y)*ivec2((p.x & 1)==0 ? 1 : -1, (p.y & 1)==0 ? 1 : -1);
            if (all(equal(p,q)) || !inFrame(q)) continue;
            vec4 hit = imageLoad(reflection_hit_pos,q);
            if (hit.w <= 0.0) continue;
            lower = min(lower,hit.xyz);
            upper = max(upper,hit.xyz);
            ++hitCount;
        }
    }
#endif

    vec3 sum = center;
    float weightSum = 1.0;
    ivec2 visited[8];
    for (int i=0; i<8; ++i) {
        ivec2 q = p + ivec2(round(rotation * poisson[i] * radius));
        visited[i] = q;
        if (all(equal(p,q)) || !inFrame(q)) continue;
        bool duplicate = false;
        for (int j=0; j<i; ++j) duplicate = duplicate || all(equal(q,visited[j]));
        if (duplicate) continue;
        vec4 source = imageLoad(reflection_reuse_radiance,q);
        vec4 hit = imageLoad(reflection_hit_pos,q);
        vec4 neighbor = imageLoad(position_t,q);
        if (source.w <= 0.0 || hit.w <= 0.0 || neighbor.w <= 0.0) continue;

        float weight = 1.0;
#if RECON_USE_DEPTH_WEIGHT
        float relativeError = abs(viewDepth(neighbor.xyz)/depth - 1.0);
        weight *= 1.0-smoothstep(RECON_DEPTH_FADE_START,RECON_DEPTH_FADE_END,relativeError);
#endif
        vec4 neighborNormals = imageLoad(normals_gs,q);
#if RECON_USE_NORMAL_WEIGHT
        float normalWidth = mix(0.005,0.25,alpha);
        weight *= 1.0-smoothstep(0.0,normalWidth,1.0-dot(N,normalDecode(neighborNormals.zw)));
#endif
#if RECON_USE_ROUGHNESS_WEIGHT
        float roughness = imageLoad(material_rmxx,q).x;
        float alphaError = abs(roughness*roughness-alpha)/max(alpha,0.02);
        weight *= 1.0-smoothstep(0.1,0.7,alphaError);
#endif
#if RECON_USE_MUTUAL_HORIZONS
        vec3 delta = neighbor.xyz-surface.xyz;
        vec3 D = delta/max(length(delta),1e-6);
        weight *= smoothstep(-0.15,-0.02,dot(G,D));
        weight *= smoothstep(-0.15,-0.02,dot(normalDecode(neighborNormals.xy),-D));
#endif
#if RECON_USE_HIT_BOUNDS
        if (hitCount >= 3) {
            float outside = length(hit.xyz-clamp(hit.xyz,lower,upper));
            float margin = max(0.02*centerHit.w,0.5*length(upper-lower));
            weight *= 1.0-smoothstep(margin,2.0*margin,outside);
        }
#endif
        if (weight <= 0.0) continue;

        vec3 toHit = hit.xyz-surface.xyz;
        float distanceToHit = length(toHit);
        if (distanceToHit <= 1e-6) continue;
        vec3 L = toHit/distanceToHit;
#if RECON_USE_HIT_HORIZON
        if (dot(G,L) <= 0.0) continue;
#endif
        if (dot(N,L) <= 0.0) continue;
        vec3 diffuse, specular;
        evalSplitBRDF(N,L,V,material,diffuse,specular);
        vec3 contribution = source.rgb*specular;
        if (any(isnan(contribution)) || any(isinf(contribution))) continue;
        sum += contribution*weight;
        weightSum += weight;
    }
    return sum/weightSum;
}

void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    if (!inFrame(p)) return;
    vec4 signal = imageLoad(indirect_specular,p);
    signal.rgb = clamp(reconstruct(p,signal.rgb),vec3(0.0),vec3(65504.0));
    imageStore(out_reflection_reused_specular,p,signal);
}
