#ifndef LIGHTING_UTILS_GLSL_INCLUDED
#define LIGHTING_UTILS_GLSL_INCLUDED

float pow5(float x) { float x2 = x*x; return x2*x2*x; }

// Geometry term (Schlick-GGX) for single direction
float Geometry_Schlick_GGX(float NdotV, float roughness)
{
    float r = roughness + 1.0;
    float k = (r*r) / 8.0;                  // remapping roughness -> k (UE4 style). Other remaps possible.
    return NdotV / (NdotV * (1.0 - k) + k + 1e-6);
}

// Smith G using Schlick-GGX G1 for V and L
float Geometry_Smith(float NdotV, float NdotL, float roughness)
{
    float ggxV = Geometry_Schlick_GGX(max(NdotV, 0.0), roughness);
    float ggxL = Geometry_Schlick_GGX(max(NdotL, 0.0), roughness);
    return ggxV * ggxL;
}

// GGX / Trowbridge-Reitz normal distribution function
float Distribution_GGX(float NdotH, float roughness)
{
    float a      = roughness*roughness;
    float a2     = a*a;
    float NdotH2 = NdotH*NdotH;
    float denom  = (NdotH2 * (a2 - 1.0) + 1.0);
    denom = 3.141592653589793 * denom * denom;
    return a2 / max(denom, 1e-6);
}

vec3 Fresnel_Schlick(float cosTheta, vec3 F0)
{
    float powTerm = pow5(clamp(1.0 - cosTheta, 0.0, 1.0));
    return F0 + (vec3(1.0) - F0) * powTerm;
}

float specularEnergyCompensation(float roughness)
{
    float t = smoothstep(0.25, 0.0, roughness); // 1 at roughness=0, 0 at roughness>=0.25
    float maxBoost = 1.12;
    return mix(1.0, maxBoost, t);
}

// Main per-light lobe evaluation
// Inputs:
//   N, V, L  - normalized vectors
//   radiance - incoming radiance from the light (vec3), i.e. light_color * intensity / distance^2 etc.
//   roughness - [0..1]
// Outputs (by reference or return struct):
//   diffuse_lobe  - the Lambertian contribution to outgoing radiance from this light (vec3)
//   specular_lobe - the microfacet specular contribution WITHOUT Fresnel (vec3)
// Notes:
//   Both outputs are radiance contributions (i.e. they are ready to accumulate into Lo and to be denoised).
void evalLightLobes(vec3 N, vec3 V, vec3 L, vec3 radiance, float roughness,
                    out vec3 diffuse_lobe, out vec3 specular_lobe)
{
    float NdotL = max(dot(N, L), 0.0);
    if (NdotL <= 0.0)
    {
        diffuse_lobe = vec3(0.0);
        specular_lobe = vec3(0.0);
        return;
    }

    float NdotV = max(dot(N, V), 1e-6);
    vec3 H = normalize(V + L);
    float NdotH = max(dot(N, H), 0.0);

    // Lambert diffuse (1/pi) * NdotL * radiance
    const float invPI = 0.31830988618;
    diffuse_lobe = radiance * (invPI * NdotL);

    // GGX microfacet BRDF WITHOUT Fresnel:
    // specular_brdf = D * G / (4 * NdotL * NdotV)
    // Outgoing radiance contribution (Lo) = radiance * specular_brdf * NdotL
    // => radiance * D * G / (4 * NdotV)  (NdotL cancels)
    float D = Distribution_GGX(NdotH, roughness);
    float G = Geometry_Smith(NdotV, NdotL, roughness);

    float denom = max(4.0 * NdotV, 1e-6);          // keep stable
    float specBRDF_per_NdotL = D * G / denom;      // equals specBRDF * NdotL (already)
    specular_lobe = radiance * specBRDF_per_NdotL; // ready to accumulate
}

// Compose final PBR color from denoised diffuse and specular lobes
// Inputs:
//   diffuseRadiance  - diffuse radiance lobe (without baseColor)
//   specularRadiance - specular lobe (without Fresnel or baseColor)
//   baseColor        - linear albedo
//   metallic         - [0..1], material metalness
//   roughness        - [0..1], material roughness
//   N, V             - normalized normal and view direction
// Output (by reference or return struct):
//   finalColor in linear color space
vec3 composePBRFromLobes(
    vec3 diffuseRadiance,
    vec3 specularRadiance,
    vec3 baseColor,
    float metallic,
    float roughness,
    vec3 N,
    vec3 V)
{
    // Clamp/guards
    float NdotV = clamp(dot(N, V), 0.0, 1.0);

    // Material F0: dielectric (0.04) blended with baseColor for metals
    const vec3 F0_dielectric = vec3(0.04, 0.04, 0.04);
    const vec3 F0 = mix(F0_dielectric, baseColor, metallic);

    // View-dependent Fresnel (Schlick) using N·V
    const vec3 F_view = Fresnel_Schlick(NdotV, F0);
    const vec3 oneMinusF = vec3(1.0) - F_view;

    // Totally destroy specular in max roughness for dielectric
    const float specDestroyFactor = 1.0 - mix(smoothstep(0.5, 1.0, roughness), 0.0, metallic);

    // Diffuse term:
    // diffuseRadiance is radiance-like (already includes NdotL and 1/pi if you used that convention).
    const vec3 diffuseColored = diffuseRadiance * baseColor;

    // Attenuate diffuse by (1 - F_view) per-channel to account for view-dependent Fresnel energy
    // (Schlick does per-channel for metals too).
    // Apply albedo and metallic (metals have no diffuse).
    const vec3 diffuseFinal = diffuseColored * (1.0 - metallic) * oneMinusF;

    // Specular term:
    // specularRadiance is radiance-like WITHOUT Fresnel: apply F_view now.
    // Apply small energy compensation for direct specular at very low roughness
    const vec3 specularColored = specularRadiance * F_view * specularEnergyCompensation(roughness);

    // Specular elimination factor for rough dielectrics (NightFox's fix)
    const float specEliminationFactor = mix(smoothstep(0.5, 1.0, roughness), 0.0, metallic);
    const vec3 finalColor = mix(diffuseFinal + specularColored, diffuseColored, specEliminationFactor);

    return finalColor;
}

#endif //ifndef LIGHTING_UTILS_GLSL_INCLUDED
