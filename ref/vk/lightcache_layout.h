#pragma once

// Shared CPU layout arithmetic, independent of renderer and Vulkan state.
static inline unsigned lcIslandExtent(unsigned original) { return (original + 1u) / 2u; }
static inline unsigned lcIslandIndex(unsigned first, unsigned width, unsigned x, unsigned y) {
    return first + (y / 2u) * width + x / 2u;
}
static inline float lcSampleCoordinate(unsigned probe, unsigned original) {
    float coordinate = (float)(probe * 2u) + 0.5f;
    return coordinate < (float)(original - 1u) ? coordinate : (float)(original - 1u);
}
