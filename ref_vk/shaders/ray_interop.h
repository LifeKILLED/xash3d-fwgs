// Common definitions for both shaders and native code
#ifndef RAY_INTEROP_H_INCLUDED
#define RAY_INTEROP_H_INCLUDED

#define LIST_SPECIALIZATION_CONSTANTS(X) \
	X(0, uint, MAX_POINT_LIGHTS, 256) \
	X(1, uint, MAX_EMISSIVE_KUSOCHKI, 256) \
	X(2, uint, MAX_VISIBLE_POINT_LIGHTS, 63) \
	X(3, uint, MAX_VISIBLE_SURFACE_LIGHTS, 255) \
	X(4, float, LIGHT_GRID_CELL_SIZE, 128.) \
	X(5, uint, MAX_LIGHT_CLUSTERS, 262144) \
	X(6, uint, MAX_TEXTURES, 4096) \
	X(7, uint, SBT_RECORD_SIZE, 32) \

#define RAY_PRIMARY_OUTPUTS(X) \
	X(10, base_color_a, rgba8) \
	X(11, position_t, rgba32f) \
	X(12, normals_gs, rgba16f) \
	X(13, material_rmxx, rgba8) \
	X(14, emissive, rgba16f) \
	X(15, search_info_ktuv, rgba32f) \
	X(16, refl_base_color_a, rgba8) \
	X(17, refl_position_t, rgba32f) \
	X(18, refl_normals_gs, rgba16f) \
	X(19, refl_material_rmxx, rgba8) \
	X(20, refl_emissive, rgba16f) \
	X(21, gi_base_color_a, rgba8) \
	X(22, gi_position_t, rgba32f) \
	X(23, gi_normals_gs, rgba16f) \
	X(24, gi_emissive, rgba16f) \


#define RAY_LIGHT_DIRECT_INPUTS(X) \
	X(10, position_t, rgba32f) \
	X(11, position_t, rgba32f) \
	X(12, normals_gs, rgba16f) \
	X(13, material_rmxx, rgba8) \
	X(14, base_color_a, rgba8) \
	X(15, motion_offsets_uvs, rgba16f) \

#define RAY_LIGHT_DIRECT_POLY_OUTPUTS(X) \
	X(20, light_poly_diffuse, rgba16f) \
	X(21, light_poly_specular, rgba16f) \

#define RAY_LIGHT_DIRECT_POINT_OUTPUTS(X) \
	X(20, light_point_diffuse, rgba16f) \
	X(21, light_point_specular, rgba16f) \


#define RAY_LIGHT_REFLECT_INPUTS(X) \
	X(10, position_t, rgba32f) \
	X(11, refl_position_t, rgba32f) \
	X(12, refl_normals_gs, rgba16f) \
	X(13, refl_material_rmxx, rgba8) \
	X(14, refl_base_color_a, rgba8) \
	X(15, motion_offsets_uvs, rgba16f) \

#define RAY_LIGHT_REFLECT_POLY_OUTPUTS(X) \
	X(20, light_poly_reflection, rgba16f) \
	
#define RAY_LIGHT_REFLECT_POINT_OUTPUTS(X) \
	X(20, light_point_reflection, rgba16f) \



#define RAY_LIGHT_INDIRECT_INPUTS(X) \
	X(10, position_t, rgba32f) \
	X(11, gi_position_t, rgba32f) \
	X(12, gi_normals_gs, rgba16f) \
	X(13, material_rmxx, rgba8) \
	X(14, gi_base_color_a, rgba8) \
	X(15, motion_offsets_uvs, rgba16f) \

#define RAY_LIGHT_INDIRECT_POLY_OUTPUTS(X) \
	X(20, light_poly_indirect, rgba16f) \
	
#define RAY_LIGHT_INDIRECT_POINT_OUTPUTS(X) \
	X(20, light_point_indirect, rgba16f) \



#define RAY_DENOISER_TEXTURES(X) \
	X(-1, last_position_t, rgba32f) \
	X(-1, last_normals_gs, rgba16f) \
	X(-1, last_search_info_ktuv, rgba32f) \
	X(-1, last_diffuse, rgba16f) \
	X(-1, last_specular, rgba16f) \
	X(-1, last_gi_sh1, rgba16f) \
	X(-1, last_gi_sh2, rgba16f) \
	X(-1, motion_offsets_uvs, rgba16f) \
	X(-1, diffuse_accum, rgba16f) \
	X(-1, specular_accum, rgba16f) \
	X(-1, gi_sh1_accum, rgba16f) \
	X(-1, gi_sh2_accum, rgba16f) \
	X(-1, gi_sh1_pass_1, rgba16f) \
	X(-1, gi_sh2_pass_1, rgba16f) \
	X(-1, gi_sh1_pass_2, rgba16f) \
	X(-1, gi_sh2_pass_2, rgba16f) \
	X(-1, gi_sh1_denoised, rgba16f) \
	X(-1, gi_sh2_denoised, rgba16f) \
	X(-1, diffuse_variance, rgba16f) \
	X(-1, diffuse_svgf1, rgba16f) \
	X(-1, diffuse_svgf2, rgba16f) \
	X(-1, diffuse_svgf3, rgba16f) \
	X(-1, diffuse_denoised, rgba16f) \
	X(-1, specular_variance, rgba16f) \
	X(-1, specular_svgf1, rgba16f) \
	X(-1, specular_svgf2, rgba16f) \
	X(-1, specular_svgf3, rgba16f) \
	X(-1, specular_svgf4, rgba16f) \
	X(-1, specular_denoised, rgba16f) \
	X(-1, composed_image, rgba16f) \
	X(-1, final_image, rgba16f) \


#ifndef GLSL
#include "xash3d_types.h"
#define MAX_EMISSIVE_KUSOCHKI 256
#define uint uint32_t
#define vec2 vec2_t
#define vec3 vec3_t
#define vec4 vec4_t
#define mat4 matrix4x4
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

#define GEOMETRY_BIT_OPAQUE 0x01
#define GEOMETRY_BIT_ADDITIVE 0x02
#define GEOMETRY_BIT_REFRACTIVE 0x04

#define SHADER_OFFSET_MISS_REGULAR 0
#define SHADER_OFFSET_MISS_SHADOW 1
#define SHADER_OFFSET_MISS_EMPTY 2

#define SHADER_OFFSET_HIT_REGULAR 0
#define SHADER_OFFSET_HIT_ALPHA_TEST 1
#define SHADER_OFFSET_HIT_ADDITIVE 2

#define SHADER_OFFSET_HIT_REGULAR_BASE 0
#define SHADER_OFFSET_HIT_SHADOW_BASE 3

#define KUSOK_MATERIAL_FLAG_SKYBOX 0x80000000

#define KUSOK_FLAG_DINAMIC_MODEL 1

struct Kusok {
	uint index_offset;
	uint vertex_offset;
	uint triangles;

	// Material
	uint tex_base_color;

	// TODO the color is per-model, not per-kusok
	vec4 color;

	vec3 emissive;
	uint tex_roughness;

	vec2 uv_speed; // for conveyors; TODO this can definitely be done in software more efficiently (there only a handful of these per map)
	uint tex_metalness;
	uint tex_normalmap;

	float roughness;
	float metalness;
	uint flags;
	PAD(1)
};

struct PointLight {
	vec4 origin_r;
	vec4 color_stopdot;
	vec4 dir_stopdot2;
	uint environment; // Is directional-only environment light
	PAD(3)
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

struct PushConstants {
	float time;
	uint random_seed;
	int bounces;
	float prev_frame_blend_factor;
	float pixel_cone_spread_angle;
	uint debug_light_index_begin, debug_light_index_end;
	uint flags;
};

struct UniformBuffer {
	mat4 inv_proj, inv_view;
	mat4 last_inv_proj, last_inv_view;
	float ray_cone_width;
	uint random_seed;
	PAD(2)
};


#undef PAD
#undef STRUCT

#ifndef GLSL
#undef uint
#undef vec3
#undef vec4
#undef TOKENPASTE
#undef TOKENPASTE2
#endif

#endif // RAY_INTEROP_H_INCLUDED
