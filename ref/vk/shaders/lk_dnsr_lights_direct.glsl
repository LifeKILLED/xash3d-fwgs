layout(set = 0, binding = 10, rgba32f) uniform readonly image2D SRC_FIRST_POSITION;
layout(set = 0, binding = 11, rgba32f) uniform readonly image2D SRC_POSITION;
layout(set = 0, binding = 12, rgba16f) uniform readonly image2D SRC_NORMALS;
layout(set = 0, binding = 13, rgba8) uniform readonly image2D SRC_MATERIAL;
layout(set = 0, binding = 14, rgba8) uniform readonly image2D SRC_BASE_COLOR;

#if OUT_SEPARATELY
	layout(set=0, binding=20, rgba16f) uniform writeonly image2D OUT_DIFFUSE;
	layout(set=0, binding=21, rgba16f) uniform writeonly image2D OUT_SPECULAR;
#else
	layout(set=0, binding=20, rgba16f) uniform writeonly image2D OUT_LIGHTING;
#endif

#define GLSL
#include "ray_interop.h"
#undef GLSL

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 1) uniform accelerationStructureEXT tlas;
layout(set = 0, binding = 2) uniform UBO { UniformBuffer ubo; } ubo;

layout(set = 0, binding = 6) uniform sampler2D textures[MAX_TEXTURES];

layout (set = 0, binding = 7) readonly buffer SBOLights { LightsMetadata m; } lights;
layout (set = 0, binding = 8, align = 1) readonly buffer UBOLightClusters {
	LightCluster clusters_[MAX_LIGHT_CLUSTERS];
} light_grid;

layout(set = 0, binding = 30, std430) readonly buffer ModelHeaders { ModelHeader a[]; } model_headers;
layout(set = 0, binding = 31, std430) readonly buffer Kusochki { Kusok a[]; } kusochki;
layout(set = 0, binding = 32, std430) readonly buffer Indices { uint16_t a[]; } indices;
layout(set = 0, binding = 33, std430) readonly buffer Vertices { Vertex a[]; } vertices;

#include "lk_dnsr_utils.glsl"

#include "utils.glsl"
#include "noise.glsl"

#include "ray_kusochki.glsl"
#include "color_spaces.glsl"

#include "light.glsl"

void readNormals(ivec2 uv, out vec3 geometry_normal, out vec3 shading_normal) {
	const vec4 n = imageLoad(SRC_NORMALS, uv);
	geometry_normal = normalDecode(n.xy);
	shading_normal = normalDecode(n.zw);
}

void main() {
#ifdef RAY_TRACE
	const vec2 uv = (gl_LaunchIDEXT.xy + .5) / gl_LaunchSizeEXT.xy * 2. - 1.;
	const ivec2 pix = ivec2(gl_LaunchIDEXT.xy);
#elif defined(RAY_QUERY)
	const ivec2 pix = ivec2(gl_GlobalInvocationID);
	const ivec2 res = ubo.ubo.res;
	if (any(greaterThanEqual(pix, res))) {
		return;
	}
	const vec2 uv = (gl_GlobalInvocationID.xy + .5) / res * 2. - 1.;
#else
#error You have two choices here. Ray trace, or Rake Yuri. So what it's gonna be, huh? Choose wisely.
#endif

	rand01_state = ubo.ubo.random_seed + pix.x * 1833 + pix.y * 31337;

	// FIXME incorrect for reflection/refraction
	const vec4 target    = ubo.ubo.inv_proj * vec4(uv.x, uv.y, 1, 1);
	const vec3 direction = normalize((ubo.ubo.inv_view * vec4(target.xyz, 0)).xyz);

	const vec4 material_data = imageLoad(SRC_MATERIAL, pix);
	const vec3 base_color_a = SRGBtoLINEAR(imageLoad(SRC_BASE_COLOR, pix).rgb);

	MaterialProperties material;
#ifdef GRAY_MATERIAL
	material.base_color = vec3(1.);
#else
	material.base_color = base_color_a;
#endif
#ifdef GLOBAL_ILLUMINATION
	material.metalness = 0.;
	material.roughness = 1.;
#else
	material.metalness = material_data.g;
	material.roughness = material_data.r;
#endif

#ifdef BRDF_COMPARE
	g_mat_gltf2 = pix.x > ubo.ubo.res.x / 2.;
#endif

	const vec4 pos_t = imageLoad(SRC_POSITION, pix);

	vec3 diffuse = vec3(0.), specular = vec3(0.);

	if (pos_t.w > 0. && any(greaterThan(material.base_color, vec3(0.)))) {
		vec3 geometry_normal, shading_normal;
		readNormals(pix, geometry_normal, shading_normal);
#if PRIMARY_VIEW
		const vec3 V = -direction;
#else
		const vec3 primary_pos = imageLoad(SRC_FIRST_POSITION, pix).xyz;
		const vec3 V = normalize(primary_pos - pos_t.xyz);
#endif

		const vec3 throughput = vec3(1.);
		computeLighting(pos_t.xyz + geometry_normal * .001, shading_normal, -direction, material, diffuse, specular);
	}

#if OUT_SEPARATELY
	imageStore(OUT_DIFFUSE, pix, vec4(diffuse, 0.));
	imageStore(OUT_SPECULAR, pix, vec4(specular, 0.));
#else
	imageStore(OUT_LIGHTING, pix, vec4(diffuse + specular, 0.));
#endif
}
