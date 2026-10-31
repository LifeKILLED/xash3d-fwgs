// Shared C/GLSL switches. Keep the original paths available for comparison.
#ifndef RIS_CONFIG_H_INCLUDED
#define RIS_CONFIG_H_INCLUDED

// ReGIR producers in rt.json must also be enabled when switching this to 1.
#ifndef RIS_ENABLE_REGIR
#define RIS_ENABLE_REGIR 0
#endif

#ifndef RIS_UNIFORM_LIGHT_CANDIDATES
#if RIS_ENABLE_REGIR
#define RIS_UNIFORM_LIGHT_CANDIDATES 0
#else
#define RIS_UNIFORM_LIGHT_CANDIDATES 1
#endif
#endif

#ifndef RIS_RESERVOIR_PERMUTATIONS
#define RIS_RESERVOIR_PERMUTATIONS 0
#endif

#endif
