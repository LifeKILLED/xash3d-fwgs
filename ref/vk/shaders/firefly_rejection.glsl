#define GLSL
#include "ray_interop.h"

layout(local_size_x=8,local_size_y=8) in;
layout(set=0,binding=0) uniform UBO { UniformBuffer ubo; } ubo;
layout(set=0,binding=1,rgba16f) uniform readonly image2D FIREFLY_INPUT;
layout(set=0,binding=2,rgba16f) uniform writeonly image2D FIREFLY_OUTPUT;

float luminance(vec3 color) {
    return dot(max(color, vec3(0.0)), vec3(0.2126, 0.7152, 0.0722));
}

void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = ubo.ubo.res / FIREFLY_PIXEL_SCALE;
    if (any(greaterThanEqual(p, size))) return;

    vec4 signal = imageLoad(FIREFLY_INPUT, p);
    if ((ubo.ubo.renderer_flags & RENDERER_FLAG_FIREFLY_REJECTION) == 0u) {
        imageStore(FIREFLY_OUTPUT, p, signal);
        return;
    }

    float sum = 0.0;
    float sumSquared = 0.0;
    int count = 0;
    for (int y = -4; y <= 4; ++y) {
        for (int x = -4; x <= 4; ++x) {
            if (abs(x) <= 1 && abs(y) <= 1) continue;
            ivec2 q = p + ivec2(x, y);
            if (any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, size))) continue;

            float value = luminance(imageLoad(FIREFLY_INPUT, q).rgb);
            sum += value;
            sumSquared += value * value;
            ++count;
        }
    }

    if (count > 0) {
        float mean = sum / float(count);
        float sigma = sqrt(max(sumSquared / float(count) - mean * mean, 0.0));
        float limit = mean + 2.0 * sigma;
        float center = luminance(signal.rgb);
        if (center > limit) signal.rgb *= limit / center;
    }
    imageStore(FIREFLY_OUTPUT, p, signal);
}
