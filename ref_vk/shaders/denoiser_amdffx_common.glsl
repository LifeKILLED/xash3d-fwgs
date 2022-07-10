/**********************************************************************
Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
********************************************************************/

#ifndef FFX_DNSR_REFLECTIONS_CONFIG
#define FFX_DNSR_REFLECTIONS_CONFIG

#define FFX_DNSR_REFLECTIONS_GAUSSIAN_K 3.0
#define FFX_DNSR_REFLECTIONS_RADIANCE_WEIGHT_BIAS 0.6
#define FFX_DNSR_REFLECTIONS_RADIANCE_WEIGHT_VARIANCE_K 0.1
#define FFX_DNSR_REFLECTIONS_AVG_RADIANCE_LUMINANCE_WEIGHT 0.3
#define FFX_DNSR_REFLECTIONS_PREFILTER_VARIANCE_WEIGHT 4.4
#define FFX_DNSR_REFLECTIONS_REPROJECT_SURFACE_DISCARD_VARIANCE_WEIGHT 1.5
#define FFX_DNSR_REFLECTIONS_PREFILTER_VARIANCE_BIAS 0.1
#define FFX_DNSR_REFLECTIONS_PREFILTER_NORMAL_SIGMA 512.0
#define FFX_DNSR_REFLECTIONS_PREFILTER_DEPTH_SIGMA 4.0
#define FFX_DNSR_REFLECTIONS_DISOCCLUSION_NORMAL_WEIGHT 1.4
#define FFX_DNSR_REFLECTIONS_DISOCCLUSION_DEPTH_WEIGHT 1.0
#define FFX_DNSR_REFLECTIONS_DISOCCLUSION_THRESHOLD 0.9
#define FFX_DNSR_REFLECTIONS_REPROJECTION_NORMAL_SIMILARITY_THRESHOLD 0.9999
#define FFX_DNSR_REFLECTIONS_SAMPLES_FOR_ROUGHNESS(r) (1.0 - exp(-r * 100.0))

#endif // FFX_DNSR_REFLECTIONS_CONFIG

#ifndef AMDFFX_TYPES
#define AMDFFX_TYPES

#define min16float float
#define min16float2 vec2
#define min16float3 vec3
#define min16float4 vec4

#define mul(a, b) (a * b)
#define lerp(a, b, c) mix(a, b, c)

#define float2 vec2
#define float3 vec3
#define float4 vec4

#define uint2 uvec2
#define uint3 uvec3
#define uint4 uvec4

#define int2 ivec2
#define int3 ivec3
#define int4 ivec4

#endif // AMDFFX_TYPES

/**********************************************************************
Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
********************************************************************/


#ifndef FFX_DNSR_REFLECTIONS_COMMON
#define FFX_DNSR_REFLECTIONS_COMMON

min16float FFX_DNSR_Reflections_Luminance(min16float3 color) { return max(dot(color, float3(0.299, 0.587, 0.114)), 0.001); }

min16float FFX_DNSR_Reflections_ComputeTemporalVariance(min16float3 history_radiance, min16float3 radiance) {
    min16float history_luminance = FFX_DNSR_Reflections_Luminance(history_radiance);
    min16float luminance         = FFX_DNSR_Reflections_Luminance(radiance);
    min16float diff              = abs(history_luminance - luminance) / max(max(history_luminance, luminance), 0.5);
    return diff * diff;
}


// From "Temporal Reprojection Anti-Aliasing"
// https://github.com/playdeadgames/temporal
/**********************************************************************
Copyright (c) [2015] [Playdead]

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
********************************************************************/
min16float3 FFX_DNSR_Reflections_ClipAABB(min16float3 aabb_min, min16float3 aabb_max, min16float3 prev_sample) {
    // Main idea behind clipping - it prevents clustering when neighbor color space
    // is distant from history sample

    // Here we find intersection between color vector and aabb color box

    // Note: only clips towards aabb center
    float3 aabb_center = 0.5 * (aabb_max + aabb_min);
    float3 extent_clip = 0.5 * (aabb_max - aabb_min) + 0.001;

    // Find color vector
    float3 color_vector = prev_sample - aabb_center;
    // Transform into clip space
    float3 color_vector_clip = color_vector / extent_clip;
    // Find max absolute component
    color_vector_clip       = abs(color_vector_clip);
    min16float max_abs_unit = max(max(color_vector_clip.x, color_vector_clip.y), color_vector_clip.z);

    if (max_abs_unit > 1.0) {
        return aabb_center + color_vector / max_abs_unit; // clip towards color vector
    } else {
        return prev_sample; // point is inside aabb
    }
}

#ifdef FFX_DNSR_REFLECTIONS_ESTIMATES_LOCAL_NEIGHBORHOOD

#    ifndef FFX_DNSR_REFLECTIONS_LOCAL_NEIGHBORHOOD_RADIUS
#        define FFX_DNSR_REFLECTIONS_LOCAL_NEIGHBORHOOD_RADIUS 4
#    endif

min16float FFX_DNSR_Reflections_LocalNeighborhoodKernelWeight(min16float i) {
    const min16float radius = FFX_DNSR_REFLECTIONS_LOCAL_NEIGHBORHOOD_RADIUS + 1.0;
    return exp(-FFX_DNSR_REFLECTIONS_GAUSSIAN_K * (i * i) / (radius * radius));
}

#endif // FFX_DNSR_REFLECTIONS_ESTIMATES_LOCAL_NEIGHBORHOOD

#endif // FFX_DNSR_REFLECTIONS_COMMON
