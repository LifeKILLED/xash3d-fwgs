// Shared arithmetic recovered from the flattened NRD 4.18 shaders.
// See ../../nrd_port/LICENSE.NVIDIA.txt and ../../nrd_port/LICENSE.MathLib.txt.
#ifndef REBLUR_FILTER_MATH_GLSL
#define REBLUR_FILTER_MATH_GLSL

vec3 reblurSafeNormalize(vec3 direction)
{
    return direction * inversesqrt(spvNMax(dot(direction, direction), 9.999999717180685365747194737196e-10));
}

vec3 reblurDecodeNormalUnnormalized(vec4 packedNormalRoughness)
{
    float octX = packedNormalRoughness.x - packedNormalRoughness.y;
    float octY = (packedNormalRoughness.x + packedNormalRoughness.y) - 1.0;
    float signedRoughness = (packedNormalRoughness.z * 2.0) - 1.0;
    float normalZ = float((signedRoughness < 0.0) ? (-1) : 1) * ((1.0 - abs(octX)) - abs(octY));
    return vec3(octX, octY, normalZ);
}

uint reblurHash(uint value)
{
    uint mix0 = (value ^ (value >> 16u)) * 2146121005u;
    uint mix1 = (mix0 ^ (mix0 >> 15u)) * 2221713035u;
    return mix1 ^ (mix1 >> 16u);
}

float reblurNormalAngle(float normalDot)
{
    return mix(1.5675890445709228515625, 1.39933097362518310546875, clamp(normalDot, 0.0, 1.0)) * sqrt(clamp(1.0 - normalDot, 0.0, 1.0));
}
#endif
