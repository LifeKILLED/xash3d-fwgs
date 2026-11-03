// Common definitions for both shaders and native code
#ifndef RAY_INTEROP_H_INCLUDED
#define RAY_INTEROP_H_INCLUDED

#include "ris_config.h"

#define LIST_SPECIALIZATION_CONSTANTS(X) \
	X(0, uint, MAX_POINT_LIGHTS, 256) \
	X(1, uint, MAX_EMISSIVE_KUSOCHKI, 256) \
	X(2, uint, MAX_VISIBLE_POINT_LIGHTS, 63) \
	X(3, uint, MAX_VISIBLE_SURFACE_LIGHTS, 255) \
	X(4, float, LIGHT_GRID_CELL_SIZE, 128.) \
	X(5, uint, MAX_LIGHT_CLUSTERS, 262144) \
	X(6, uint, MAX_TEXTURES, 4096) \
	X(7, uint, SBT_RECORD_SIZE, 32) \

#ifndef GLSL
#include "xash3d_types.h"
#include "vk_const.h"
#define MAX_EMISSIVE_KUSOCHKI 256
#define uint uint32_t
#define vec2 vec2_t
#define vec3 vec3_t
#define vec4 vec4_t
#define mat4 matrix4x4
typedef int ivec3[3];
typedef int ivec2[2];
typedef int ivec4[4];
typedef uint32_t uvec2[2];
typedef uint32_t uvec4[4];
#define TOKENPASTE(x, y) x ## y
#define TOKENPASTE2(x, y) TOKENPASTE(x, y)
#define PAD(x) float TOKENPASTE2(pad_, __LINE__)[x];
#define STRUCT struct

enum {
#define DECLARE_SPECIALIZATION_CONSTANT(index, type, name, default_value) \
	SPEC_##name##_INDEX = index,
LIST_SPECIALIZATION_CONSTANTS(DECLARE_SPECIALIZATION_CONSTANT)
#undef DECLARE_SPECIALIZATION_CONSTANT
};

#else // if GLSL else
#extension GL_EXT_shader_8bit_storage : require

#define PAD(x)
#define STRUCT

#define DECLARE_SPECIALIZATION_CONSTANT(index, type, name, default_value) \
	layout (constant_id = index) const type name = default_value;
LIST_SPECIALIZATION_CONSTANTS(DECLARE_SPECIALIZATION_CONSTANT)
#undef DECLARE_SPECIALIZATION_CONSTANT

#endif // not GLSL

struct Vertex {
	vec3 pos;
	vec3 prev_pos;
	vec3 normal;
	vec3 tangent;
	vec2 gl_tc;
	vec2 lm_tc;
	uint color;
};

#define GEOMETRY_BIT_OPAQUE 0x01
#define GEOMETRY_BIT_ALPHA_TEST 0x02
#define GEOMETRY_BIT_BLEND 0x04
#define GEOMETRY_BIT_REFRACTIVE 0x08
#define GEOMETRY_BIT_CASTS_SHADOW 0x10

#define SHADER_OFFSET_MISS_REGULAR 0
#define SHADER_OFFSET_MISS_SHADOW 1
#define SHADER_OFFSET_MISS_EMPTY 2

#define SHADER_OFFSET_HIT_REGULAR 0
#define SHADER_OFFSET_HIT_ALPHA_TEST 1
#define SHADER_OFFSET_HIT_ADDITIVE 2

#define SHADER_OFFSET_HIT_REGULAR_BASE 0
#define SHADER_OFFSET_HIT_SHADOW_BASE 3

#define MATERIAL_MODE_OPAQUE 0
#define MATERIAL_MODE_OPAQUE_ALPHA_TEST 1
#define MATERIAL_MODE_TRANSLUCENT 2
#define MATERIAL_MODE_BLEND_ADD 3
#define MATERIAL_MODE_BLEND_MIX 4
#define MATERIAL_MODE_BLEND_GLOW 5
#define MATERIAL_MODE_DECAL 6
#define MATERIAL_MODE_COUNT 7

#define TEX_BASE_SKYBOX 0x0f000000u

struct Material {
	uint tex_base_color;

	// TODO can be combined into a single texture
	uint tex_roughness;
	uint tex_metalness;
	uint tex_normalmap;

	// TODO:
	// uint tex_emissive;
	// uint tex_detail;

	float roughness;
	float metalness;
	float normal_scale;
	PAD(1)

	vec4 base_color;
};

struct ModelHeader {
	mat4 prev_transform;
	vec4 color;
	uint mode;
	uint lightmap_uv_valid;
	vec2 lightmap_uv;
};

struct Kusok {
	// Geometry data, static
	uint index_offset;
	uint vertex_offset;

	// material below consists of scalar fields only, so it's not aligned to vec4.
	// Alignt it here to vec4 explicitly, so that later vector fields are properly aligned (for simplicity).
	uint polygon_light; // Emissive brush surface; effects/beams retain emission.
	uint _padding0;

	// Per-kusok because individual surfaces can be patched
	// TODO? still move to material, or its own table? As this can be dynamic
	vec3 emissive;
	PAD(1)

	// TODO reference into material table
	STRUCT Material material;

};

#define RT_DECAL_INVALID_ID 0xffffffffu

struct RtDecal {
	uint next_decal_id;
	uint tex_base_color;
	float roughness;
	float metalness;

	vec4 base_color;
	vec4 projection_u;
	vec4 projection_v;
};

struct PointLight {
	vec4 origin_r2; // vec4(center.xyz, radius²)
	vec4 color_stopdot;
	vec4 dir_stopdot2;

	// TODO move to either dedicated array, or section of array (by-index type delimiter)
	uint environment; // Is directional-only environment light
	uint flashlight; // Is flashlight spotlight
	PAD(2)
};

struct PolygonLight {
	vec4 plane;

	vec3 center;
	float area;

	vec3 emissive;
	uint vertices_count_offset;
};

struct LightsMetadata {
	uint num_polygons;
	uint num_point_lights;
	PAD(2)
	ivec3 grid_min_cell;
	PAD(1)
	ivec3 grid_size;
	PAD(1)
	STRUCT PointLight point_lights[MAX_POINT_LIGHTS];
	STRUCT PolygonLight polygons[MAX_EMISSIVE_KUSOCHKI];
	vec4 polygon_vertices[MAX_EMISSIVE_KUSOCHKI * 7]; // vec3 but aligned
};

struct LightCluster {
	uint8_t num_point_lights;
	uint8_t num_polygons;
	uint8_t point_lights[MAX_VISIBLE_POINT_LIGHTS];
	uint8_t polygons[MAX_VISIBLE_SURFACE_LIGHTS];
};

#define PUSH_FLAG_LIGHTMAP_ONLY 0x01

#define DEBUG_DISPLAY_DISABLED 0
#define DEBUG_DISPLAY_BASECOLOR 1
#define DEBUG_DISPLAY_BASEALPHA 2
#define DEBUG_DISPLAY_EMISSIVE 3
#define DEBUG_DISPLAY_NSHADE 4
#define DEBUG_DISPLAY_NGEOM 5
#define DEBUG_DISPLAY_LIGHTING 6
#define DEBUG_DISPLAY_SURFHASH 7
#define DEBUG_DISPLAY_DIRECT 8
#define DEBUG_DISPLAY_DIRECT_DIFF 9
#define DEBUG_DISPLAY_DIRECT_SPEC 10
#define DEBUG_DISPLAY_INDIRECT 11
#define DEBUG_DISPLAY_INDIRECT_DIFF 12
#define DEBUG_DISPLAY_INDIRECT_SPEC 13
#define DEBUG_DISPLAY_TRIHASH 14
#define DEBUG_DISPLAY_MATERIAL 15
#define DEBUG_DISPLAY_DIFFUSE 16
#define DEBUG_DISPLAY_SPECULAR 17
#define DEBUG_DISPLAY_RESERVOIR_REUSING 18
#define DEBUG_DISPLAY_DIRECT_DIFFUSE_CACHE 19
#define DEBUG_DISPLAY_LIGHT_CACHE 20
// add more when needed

#define DEBUG_FLAG_WHITE_FURNACE (1<<0)

#define RENDERER_FLAG_ONLY_DIFFUSE_GI (1<<0)
#define RENDERER_FLAG_SEPARATED_REFLECTION (1<<1)
#define RENDERER_FLAG_DENOISE_GI_BY_SH (1<<2)
#define RENDERER_FLAG_DISABLE_GI (1<<3)
#define RENDERER_FLAG_SPATIAL_RECONSTRUCTION (1<<4)
#define RENDERER_FLAG_DISABLE_RESERVOIR_REUSING (1<<5)
#define RENDERER_FLAG_DISABLE_REPROJECTION (1<<6) // ASVGF history only; not reservoir/cache reuse.
#define RENDERER_FLAG_DISABLE_REFLECTION (1<<7)
#define RENDERER_FLAG_DISABLE_REFRACTION (1<<8)
#define RENDERER_FLAG_DISABLE_REGIR (1<<9)
#define RENDERER_FLAG_DISABLE_ATROUS (1<<10)
#define RENDERER_FLAG_DIRECT_VISIBILITY_CANDIDATES (1<<11)
#define RENDERER_FLAG_DIRECT_VISIBILITY_WEIGHT_CLAMP (1<<12)
#define RENDERER_FLAG_DIRECT_VISIBILITY_MEDIAN (1<<13)
#define RENDERER_FLAG_DIRECT_VISIBILITY_GRADIENT (1<<14)
#define RENDERER_FLAG_DISABLE_DIRECT (1<<15)
#define RENDERER_FLAG_LIGHTCACHE_GI (1<<16)
#define RENDERER_FLAG_DISABLE_LIGHTCACHE_UPDATE (1<<17)

#define ASVGF_COMPATIBILITY_STATS 0u
#define ASVGF_COMPATIBILITY_LUMA_DELTA 1u

#define ASVGF_HISTORY_FILTER_NONE 0u
#define ASVGF_HISTORY_FILTER_LUMA_OUTLIER_CLAMP 1u

#define ASVGF_DEPENDENCY_NONE 0u
#define ASVGF_DEPENDENCY_COMBINE_MIN 1u
#define ASVGF_DEPENDENCY_RELIGHT_CARRY 2u
#define ASVGF_DEPENDENCY_VARIANCE_CARRY 3u

#define ASVGF_REPROJECTION_STRATEGY_SURFACE 0u
#define ASVGF_REPROJECTION_STRATEGY_REFLECTION_PARALLAX 1u
#define ASVGF_REPROJECTION_STRATEGY_REFRACTION_PLANE 2u

struct AsvgfReprojectionParams {
	float history_samples_max;
	float history_current_weight_min;
	float reprojection_depth_threshold_scale;
	float parallax_depth_threshold_scale;

	float variance_compatibility_luma_scale;
	float variance_compatibility_delta_floor;
	float variance_compatibility_signal_floor;
	float variance_compatibility_smooth_min;
	float variance_compatibility_smooth_max;
	float variance_compatibility_floor;

	float variance_gate_min;
	float variance_gate_max;
	float variance_gate_floor;
	float variance_soften_threshold;
	float variance_soften_mix;
	float variance_stage_mix;

	float reset_min_scale;
	float reset_hard_variance_gate;
	float reset_hard_compatibility;
	float reset_hard_factor;
	float variance_reset_boost_smooth_min;
	float variance_reset_boost_smooth_max;

	float analytical_variance_signal_floor;
	float analytical_variance_floor_base;
	float analytical_variance_floor_signal_scale;
	float analytical_variance_ratio_min;
	float analytical_variance_ratio_max;
	float analytical_variance_mean_min;
	float analytical_variance_mean_max;

	float luma_delta_gate_signal_floor;
	float luma_delta_gate_denominator_offset;
	float luma_delta_gate_smooth_min;
	float luma_delta_gate_smooth_max;
	float luma_delta_gate_mix;

	float external_gate_floor;
	float external_gate_mix;
	float external_gate_hard_threshold;

	float dependency_gate_floor;
	float dependency_gate_soft_min;
	float dependency_gate_soft_max;
	float dependency_gate_mix;

	float dependency_luma_signal_floor;
	float dependency_luma_denominator_offset;
	float dependency_luma_smooth_min;
	float dependency_luma_smooth_max;
	float dependency_luma_mix;

	float dependency_off_history_min;
	float dependency_off_current_max;
	float dependency_off_ratio_min;

	float history_luma_clamp;
	float history_outlier_noise_mean_floor;
	float history_outlier_noise_gate_min;
	float history_outlier_noise_gate_max;
	float history_outlier_envelope_sigma_min;
	float history_outlier_envelope_sigma_max;
	float history_outlier_envelope_mean_min;
	float history_outlier_envelope_mean_max;
	float history_outlier_envelope_min;
	float history_outlier_threshold_low_min;
	float history_outlier_threshold_low_max;
	float history_outlier_threshold_high_min;
	float history_outlier_threshold_high_max;
	float history_outlier_luma_cap_min;
	float history_outlier_luma_cap_scale_min;
	float history_outlier_luma_cap_scale_max;
	float history_outlier_external_gate_attenuation_min;
	float history_outlier_external_gate_attenuation_max;
	float history_outlier_accumulated_luma_scale_min;
	float history_outlier_accumulated_luma_scale_max;

	float deflicker_threshold_min;
	float deflicker_threshold_max;

	float parallax_roughness_threshold;
	float parallax_shading_normal_threshold;
	float refraction_eta_ratio;

	uint variance_compatibility_strategy;
	uint history_filter_strategy;
	uint dependency_strategy;
	uint reprojection_strategy;
	uint use_dependency_reset_as_gate;

	uint deflicker_enabled;
};

#ifndef GLSL
STATIC_ASSERT((sizeof(struct AsvgfReprojectionParams) % 16) == 0, "AsvgfReprojectionParams size must be aligned to vec4");
#endif

struct AsvgfParams {
	STRUCT AsvgfReprojectionParams direct_diffuse;
	STRUCT AsvgfReprojectionParams direct_specular;
	STRUCT AsvgfReprojectionParams indirect_diffuse;
	STRUCT AsvgfReprojectionParams indirect_specular;
	STRUCT AsvgfReprojectionParams refraction;
};

struct UniformBuffer {
	mat4 proj, view;
	mat4 inv_proj, inv_view;
	mat4 prev_proj, prev_view;
	mat4 prev_inv_proj, prev_inv_view;
	ivec2 res;
	float ray_cone_width;
	uint random_seed;
	uint frame_counter;
	float skybox_exposure;

	uint debug_display_only;
	uint debug_flags;

	uint renderer_flags;
	float regir_onion_radius;
	uint di_visibility_reuse; // Zero = legacy; bit 0 = reuse, upper bits = confidence-cap history epoch.
	float di_visibility_history;

	STRUCT AsvgfParams asvgf;

	uint bounce_count; // rt_bounces; independent GI keeps the entire path in one pixel.
	uint nrd_bounce, nrd_reflection;
	PAD(1)
	// REBLUR fields: signal 0 = bounce, signal 1 = reflection.

	vec4 reblur_rotator_pre[2];
	vec4 reblur_rotator[2];
	vec4 reblur_rotator_post[2];
	vec4 reblur_frustum[2];
	vec4 reblur_frustum_prev[2];

	vec4 reblur_hit_dist_settings[2];

	vec4 reblur_mv_scale[2];
	vec4 reblur_mv_bias[2];
	vec4 reblur_convergence_settings[2];
	vec4 reblur_antilag_settings[2];
	vec4 reblur_resource_size[2];
	vec4 reblur_resource_size_inv[2];
	vec4 reblur_resource_size_inv_prev[2];
	vec4 reblur_rect_size[2];
	vec4 reblur_rect_size_inv[2];
	vec4 reblur_rect_size_prev[2];
	vec4 reblur_resolution_scale[2];
	vec4 reblur_resolution_scale_prev[2];
	vec4 reblur_jitter[2];
	uvec4 reblur_printf_at[2];
	ivec4 reblur_input_rect_origin[2];
	ivec4 reblur_output_rect_origin[2];
	ivec4 reblur_dispatch_input_rect_origin[2];
	ivec4 reblur_dispatch_output_rect_origin[2];
	ivec4 reblur_rect_size_minus_one[2];
	vec2 reblur_disocclusion_threshold;
	vec2 reblur_disocclusion_threshold_alternate;
	vec2 reblur_camera_attached_reflection_material_id;
	vec2 reblur_strand_material_id;
	vec2 reblur_strand_thickness;
	vec2 reblur_stabilization_strength;
	vec2 reblur_debug;
	vec2 reblur_ortho_mode;
	vec2 reblur_unproject;
	vec2 reblur_denoising_range;
	vec2 reblur_plane_dist_sensitivity;
	vec2 reblur_frame_rate_scale;
	vec2 reblur_frame_rate_scale_smoothed;
	vec2 reblur_min_blur_radius;
	vec2 reblur_max_blur_radius;
	vec2 reblur_diff_prepass_blur_radius;
	vec2 reblur_spec_prepass_blur_radius;
	vec2 reblur_max_accumulated_frame_num;
	vec2 reblur_max_fast_accumulated_frame_num;
	vec2 reblur_anti_firefly;
	vec2 reblur_lobe_angle_fraction;
	vec2 reblur_roughness_fraction;
	vec2 reblur_history_fix_frame_num;
	vec2 reblur_history_fix_base_pixel_stride;
	vec2 reblur_history_fix_alternate_pixel_stride;
	vec2 reblur_history_fix_alternate_pixel_stride_material_id;
	vec2 reblur_fast_history_clamping_sigma_scale;
	vec2 reblur_min_rect_dim_mul_unproject;
	vec2 reblur_use_prepass_not_only_for_specular_motion_estimation;
	vec2 reblur_split_screen;
	vec2 reblur_split_screen_prev;
	vec2 reblur_checkerboard_resolve_accum_speed;
	vec2 reblur_view_z_scale;
	vec2 reblur_firefly_suppressor_min_relative_scale;
	vec2 reblur_min_hit_distance_weight;
	vec2 reblur_diff_min_material;
	vec2 reblur_spec_min_material;
	vec2 reblur_responsive_accumulation_inv_roughness_threshold;
	uvec2 reblur_responsive_accumulation_min_accumulated_frame_num;
	uvec2 reblur_has_history_confidence;
	uvec2 reblur_has_disocclusion_threshold_mix;
	uvec2 reblur_diff_checkerboard;
	uvec2 reblur_spec_checkerboard;
	uvec2 reblur_frame_index;
	uvec2 reblur_is_rect_changed;
	uvec2 reblur_reset_history;
	uvec2 reblur_return_history_length_instead_of_occlusion;
	PAD(2)
	uvec4 reblur_groups_8x8_8x16[2];
	uvec4 reblur_groups_16x16[2];
};

#undef PAD
#undef STRUCT

#ifndef GLSL
#undef uint
STATIC_ASSERT((sizeof(struct UniformBuffer) % 16) == 0, "UniformBuffer size must be aligned to vec4");
#undef vec3
#undef vec4
#undef TOKENPASTE
#undef TOKENPASTE2
#endif

#endif // RAY_INTEROP_H_INCLUDED
