
#define RAY_QUERY

#define LIGHT_POINT 1
#define LIGHT_POLYGON 1

#include "utils.glsl"
#include "noise.glsl"

#include "ray_kusochki.glsl"
#include "color_spaces.glsl"
#include "poisson-disk-8x8.glsl"

//#include "light.glsl"

#define UNIFIED_LIGHTS_IMPORTANCE 1
#include "lights_unified.glsl"

#define POISSON_NOISE_DITHER_SCALE 0.25

void readNormals(ivec2 uv, out vec3 geometry_normal, out vec3 shading_normal) {
	const vec4 n = imageLoad(normals_gs, uv);
	geometry_normal = normalDecode(n.xy);
	shading_normal = normalDecode(n.zw);
}

void main() {
#ifdef RAY_TRACE
	const vec2 uv = (gl_LaunchIDEXT.xy + .5) / gl_LaunchSizeEXT.xy * 2. - 1.;
	const ivec2 pix = ivec2(gl_LaunchIDEXT.xy);
#elif defined(RAY_QUERY)
	const ivec2 pix = ivec2(gl_GlobalInvocationID);
	const ivec2 res = ivec2(vec2(ubo.ubo.res) * ubo.ubo.resScale);
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

	const vec4 material_data = imageLoad(material_rmxx, pix);

	MaterialProperties material;
	material.base_color = SRGBtoLINEAR(imageLoad(base_color_a, pix).rgb);
	material.metalness = material_data.g;
	material.roughness = material_data.r;

	const vec4 pos_t = imageLoad(position_t, pix);

	vec3 diffuse = vec3(0.), specular = vec3(0.);

	if (pos_t.w > 0.) {
		const vec4 packed_normal = imageLoad(normals_gs, pix);
		const vec3 geometry_normal = normalDecode(packed_normal.xy);
		const vec3 shading_normal = normalDecode(packed_normal.zw);

		const vec2 poissonNoiseDither = mix(getPoissonCoord(pix) * 0.5 + vec2(0.5), vec2(rand01(),rand01()), POISSON_NOISE_DITHER_SCALE);
		const vec3 rnd = vec3(poissonNoiseDither, rand01());

		const vec3 P = pos_t.xyz + geometry_normal * .001;
		const vec3 N = shading_normal;
		const vec3 V = -direction;

		const SampleContext ctx = buildSampleContext(P, N, V);

		LightResult r = calculateUnifiedLightImportance(
    		P,
			N,
			V,
    		material,
			ctx,
			rnd,
			true,
			pix);

		diffuse += r.diffuse;
		specular += r.specular;
	}

	// diffuse = 0.5;
	// specular = 0.0;

	DEBUG_VALIDATE_RANGE_VEC3("direct.diffuse", diffuse, 0., 1e6);
	DEBUG_VALIDATE_RANGE_VEC3("direct.specular", specular, 0., 1e6);

	imageStore(OUT_DIFFUSE, pix, vec4(diffuse, 0.f));
	imageStore(OUT_SPECULAR, pix, vec4(specular, 0.f));
}
