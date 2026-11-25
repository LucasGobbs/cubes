// City bloom: a wide, soft glow round every light and lit window (the article's look). Bright pass at half
// resolution, then three blur levels (half, quarter, eighth), added over the scene in one composite. Each level
// blurs the one above it, so the glow widens with the level: tight halos from the half level, a broad haze from
// the eighth.
package city

import gfx "../../engine/gfx"
import shader_parameters "../../shader_parameters"
import "core:mem"

CITY_BLOOM_THRESHOLD :: 0.45 // lit windows, lamps and car lights pass; the dark sky, roofs and street do not
CITY_BLOOM_KNEE :: 0.2 // soft knee: the threshold ramps in over this band
CITY_BLOOM_INTENSITY :: 1.0
// Level weights added to the scene: half (tight halo), quarter, eighth (widest glow).
CITY_BLOOM_WEIGHTS :: [3]f32{1.4, 1.0, 0.7}
// Blur radii in texels of each level: sigma = radius / 2. Eighth-res texels are 8 full-res pixels wide.
CITY_BLOOM_RADIUS_HALF :: 3
CITY_BLOOM_RADIUS_QUARTER :: 6
CITY_BLOOM_RADIUS_EIGHTH :: 8

City_Bloom :: struct {
	prefilter, blur, composite: gfx.Compute_Pipeline_Handle,
}

// Matches CityBloomParams in shaders/city_bloom_composite.slang.
City_Bloom_Composite_Uniforms :: struct {
	weights: [4]f32, // xyz level weights, w intensity
}
#assert(size_of(City_Bloom_Composite_Uniforms) == 16)

city_bloom_create :: proc(gfx_ctx: ^gfx.Device) -> City_Bloom {
	return City_Bloom {
		prefilter = gfx.compute_pipeline_create(gfx_ctx, gfx.default_postfx_bloom_prefilter_compute()),
		blur = gfx.compute_pipeline_create(gfx_ctx, gfx.default_postfx_blur_compute()),
		composite = gfx.compute_pipeline_create(gfx_ctx, shader_parameters.city_bloom_composite_compute()),
	}
}

city_bloom_destroy :: proc(gfx_ctx: ^gfx.Device, bloom: ^City_Bloom) {
	gfx.compute_pipeline_destroy(gfx_ctx, bloom.prefilter)
	gfx.compute_pipeline_destroy(gfx_ctx, bloom.blur)
	gfx.compute_pipeline_destroy(gfx_ctx, bloom.composite)
	bloom^ = {}
}

city_bloom_pass :: proc(bloom: ^City_Bloom) -> gfx.Render_Pass {
	return gfx.Render_Pass{name = "city_bloom", run = city_bloom_run, user = bloom}
}

// Transient 1/8 target: the engine's Pass_Size stops at Quarter.
city_bloom_acquire_eighth :: proc(ctx: ^gfx.Pass_Ctx) -> gfx.Texture_Handle {
	return gfx.pool_acquire(ctx.renderer, max(1, (ctx.width + 7) / 8), max(1, (ctx.height + 7) / 8))
}

city_bloom_run :: proc(ctx: ^gfx.Pass_Ctx, user: rawptr) {
	bloom := (^City_Bloom)(user)

	// Bright pass into half res.
	half := gfx.pass_acquire(ctx, .Half)
	pre := gfx.Bloom_Prefilter_Uniforms{threshold = CITY_BLOOM_THRESHOLD, knee = CITY_BLOOM_KNEE}
	gfx.pass_compute(ctx, bloom.prefilter, []gfx.Texture_Handle{ctx.color}, half, mem.ptr_to_bytes(&pre))

	// Level 1: half res, tight halo.
	half_tmp := gfx.pass_acquire(ctx, .Half)
	level_half := gfx.pass_acquire(ctx, .Half)
	gfx.blur_axis(ctx, bloom.blur, CITY_BLOOM_RADIUS_HALF, half, half_tmp, {1, 0})
	gfx.blur_axis(ctx, bloom.blur, CITY_BLOOM_RADIUS_HALF, half_tmp, level_half, {0, 1})

	// Level 2: quarter res, blurred from level 1.
	quarter_tmp := gfx.pass_acquire(ctx, .Quarter)
	level_quarter := gfx.pass_acquire(ctx, .Quarter)
	gfx.blur_axis(ctx, bloom.blur, CITY_BLOOM_RADIUS_QUARTER, level_half, quarter_tmp, {1, 0})
	gfx.blur_axis(ctx, bloom.blur, CITY_BLOOM_RADIUS_QUARTER, quarter_tmp, level_quarter, {0, 1})

	// Level 3: eighth res, blurred from level 2. The widest glow.
	eighth_tmp := city_bloom_acquire_eighth(ctx)
	level_eighth := city_bloom_acquire_eighth(ctx)
	gfx.blur_axis(ctx, bloom.blur, CITY_BLOOM_RADIUS_EIGHTH, level_quarter, eighth_tmp, {1, 0})
	gfx.blur_axis(ctx, bloom.blur, CITY_BLOOM_RADIUS_EIGHTH, eighth_tmp, level_eighth, {0, 1})

	out := gfx.pass_acquire(ctx)
	w := CITY_BLOOM_WEIGHTS
	comp := City_Bloom_Composite_Uniforms{weights = {w.x, w.y, w.z, CITY_BLOOM_INTENSITY}}
	gfx.pass_compute(
		ctx,
		bloom.composite,
		[]gfx.Texture_Handle{ctx.color, level_half, level_quarter, level_eighth},
		out,
		mem.ptr_to_bytes(&comp),
	)
	ctx.color = out
}
