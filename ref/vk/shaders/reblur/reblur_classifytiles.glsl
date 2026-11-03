/* Shared REBLUR pass derived from NVIDIA NRD 4.18.
	* See ../../nrd_port/LICENSE.NVIDIA.txt and ../../nrd_port/LICENSE.MathLib.txt. */

layout(set=0,binding=1,rgba32f) uniform readonly image2D VIEWZ_IMAGE;
layout(set=0,binding=2,rgba8) uniform writeonly image2D TILES_OUTPUT_IMAGE;

vec4 reblurFetch_viewz(ivec2 p) {
	if(any(lessThan(p,ivec2(0))) || any(greaterThanEqual(p,reblurExtent()))) return vec4(0);
	return imageLoad(VIEWZ_IMAGE, p);
}

void reblurStore_out_tiles(ivec2 p,vec4 v) { imageStore(TILES_OUTPUT_IMAGE, p,vec4(v.x,0.0,0.0,1.0)); }
layout(local_size_x = 8, local_size_y = 4, local_size_z = 1) in;

shared int sharedSkyPixelCount;

void main() {
	if (!reblurEnabled()) return;
	if (any(greaterThanEqual(gl_WorkGroupID.xy, ubo.ubo.reblur_groups_16x16[REBLUR_SIGNAL].xy))) return;
	bool isFirstThread = gl_LocalInvocationIndex == 0u;
	if (isFirstThread)
		sharedSkyPixelCount = 0;
	barrier();

	ivec2 pixelBase = ivec2(gl_WorkGroupID.xy * 16u + gl_LocalInvocationID.xy * uvec2(2u, 4u));
	int skyPixelCount = 0;
	for (int x = 0; x < 2; ++x) {
		for (int y = 0; y < 4; ++y) {
			ivec2 p = pixelBase + ivec2(x, y);
			bool isSky = true;
			if (!any(greaterThan(p, ubo.ubo.reblur_rect_size_minus_one[REBLUR_SIGNAL].xy))) {
				float viewDepth = abs(reblurFetch_viewz(min(p, ubo.ubo.reblur_rect_size_minus_one[REBLUR_SIGNAL].xy)).x * ubo.ubo.reblur_view_z_scale[REBLUR_SIGNAL]);
				isSky = !(viewDepth < ubo.ubo.reblur_denoising_range[REBLUR_SIGNAL]);
			}
			skyPixelCount += int(isSky);
		}
	}
	atomicAdd(sharedSkyPixelCount, skyPixelCount);
	barrier();
	if (isFirstThread)
		reblurStore_out_tiles(ivec2(gl_WorkGroupID.xy), vec4(float(sharedSkyPixelCount == 256)));
}
