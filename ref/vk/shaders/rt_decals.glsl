#ifndef RT_DECALS_GLSL_INCLUDED
#define RT_DECALS_GLSL_INCLUDED

layout(set = 0, binding = 34, std430) readonly buffer RtDecals { RtDecal a[]; } rt_decals;
layout(set = 0, binding = 35, std430) readonly buffer RtDecalHeads { uint a[]; } rt_decal_heads;

void applyRtDecals(
	uint kusok_index,
	vec3 position_object,
	inout vec4 base_color_a,
	inout vec4 material_rmxx)
{
	uint decal_id = rt_decal_heads.a[kusok_index];
	for (uint iteration = 0u;
		decal_id != RT_DECAL_INVALID_ID && iteration < 4096u;
		++iteration) {
		const RtDecal decal = rt_decals.a[decal_id];
		decal_id = decal.next_decal_id;

		const vec2 uv = vec2(
			dot(position_object, decal.projection_u.xyz) + decal.projection_u.w,
			dot(position_object, decal.projection_v.xyz) + decal.projection_v.w);
		if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0))))
			continue;

		const vec4 texture_color = textureLod(
			textures[nonuniformEXT(decal.tex_base_color)], uv, 0.0);
		const float alpha = decal.base_color.a * texture_color.a;
		const vec3 color = decal.base_color.rgb * texture_color.rgb;

		base_color_a = mix(base_color_a, vec4(color, 1.0), alpha);
		material_rmxx = mix(
			material_rmxx,
			vec4(decal.roughness, decal.metalness, 0.0, 0.0),
			alpha);
	}
}

#endif
