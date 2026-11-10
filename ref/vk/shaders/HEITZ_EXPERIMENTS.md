# Shadow sampling and gamma filtering

Direct shadows use the static 128x128 joint UV mask
`bluenoise2d/joint_uv_128.png`. It is an ordinary service texture in `textures[]`,
loaded in linear color space with TF_NOMIPMAP | TF_NEAREST. Only its texture
index is passed in the UBO; no dedicated sampler binding is needed.
The mask is generated from scratch by `scripts/generate-shadow-noise.py`;
no input textures are used. See the asset's SOURCE.txt for generation details.

One integer texel fetch per pixel per direct-light dispatch is shared by all
lights. R/G supply the triangle sample pair through sqrt(u),v; B selects an
area-weighted polygon fan triangle. Point and sun lights use R/G for cone
sampling. The mask has no frame animation. Shared samples correlate lights,
and the 128-pixel period can still be visible. Joint optimization does not
guarantee blue-noise error for every BRDF or visibility function.

The original 3D blue-noise resource and bluenoise.glsl helper coexist unchanged.
The rand01 alternative and temporal shadow-mask experiment have been removed.
Other GI samplers and histories are unaffected.

`heitz_shadow_config.glsl` enables HEITZ_GAMMA_FILTER=1 by default. The paired
stochastic estimates are encoded with power 1/2.2 before spatial filtering and
their ratio is decoded with power 2.2. Analytic lighting stays linear. This is
a biased experiment, not the original linear Heitz estimator. Set the macro to
0 for linear filtering. Rebuild, install and restart after changing shaders:

    python waf build
    python waf install --destdir=build/xash-vk
