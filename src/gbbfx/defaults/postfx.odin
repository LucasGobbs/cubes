package defaults

import "core:mem"
import gbbfx ".."

// Post-process effects. They live here, not in gbbfx, because `defaults`
// owns the generated shader parameters and imports gbbfx.

BLUR_MAX_RADIUS :: 16

Blur_Uniforms :: struct {
	direction: [2]f32,
	radius:    i32,
	pad:       f32,
}
#assert(size_of(Blur_Uniforms) == DEFAULT_POSTFX_BLUR_COMPUTE_UNIFORM_BLOCK_SIZE)

Bloom_Prefilter_Uniforms :: struct {
	threshold: f32,
	knee:      f32,
	pad:       [2]f32,
}
#assert(size_of(Bloom_Prefilter_Uniforms) == DEFAULT_POSTFX_BLOOM_PREFILTER_COMPUTE_UNIFORM_BLOCK_SIZE)

Bloom_Composite_Uniforms :: struct {
	intensity: f32,
	pad:       [3]f32,
}
#assert(size_of(Bloom_Composite_Uniforms) == DEFAULT_POSTFX_BLOOM_COMPOSITE_COMPUTE_UNIFORM_BLOCK_SIZE)

Blur :: struct {
	pipeline: gbbfx.Compute_Pipeline_Handle,
	radius:   i32,
}

blur_create :: proc(gfx: ^gbbfx.Gfx, radius: i32 = 4) -> Blur {
	return Blur {
		pipeline = gbbfx.gfx_compute_pipeline_create(gfx, default_postfx_blur_compute()),
		radius = min(max(radius, 1), BLUR_MAX_RADIUS),
	}
}

blur_pass :: proc(blur: ^Blur) -> gbbfx.Render_Pass {
	return gbbfx.Render_Pass{name = "blur", run = blur_run, user = blur}
}

blur_run :: proc(ctx: ^gbbfx.Pass_Ctx, user: rawptr) {
	blur := (^Blur)(user)
	tmp := gbbfx.pass_acquire(ctx)
	out := gbbfx.pass_acquire(ctx)
	blur_axis(ctx, blur.pipeline, blur.radius, ctx.color, tmp, {1, 0})
	blur_axis(ctx, blur.pipeline, blur.radius, tmp, out, {0, 1})
	ctx.color = out
}

// One separable blur pass: sample `src` along `direction` into `dst`.
blur_axis :: proc(
	ctx: ^gbbfx.Pass_Ctx,
	pipeline: gbbfx.Compute_Pipeline_Handle,
	radius: i32,
	src, dst: gbbfx.Texture_Handle,
	direction: [2]f32,
) {
	u := Blur_Uniforms{direction = direction, radius = radius}
	gbbfx.pass_compute(ctx, pipeline, []gbbfx.Texture_Handle{src}, dst, mem.ptr_to_bytes(&u))
}

Bloom :: struct {
	prefilter, blur, composite: gbbfx.Compute_Pipeline_Handle, // blur = postfx_blur
	threshold, knee, intensity: f32,
	radius:                     i32,
}

bloom_create :: proc(
	gfx: ^gbbfx.Gfx,
	threshold := f32(0.8),
	intensity := f32(0.6),
	radius := i32(6),
) -> Bloom {
	return Bloom {
		prefilter = gbbfx.gfx_compute_pipeline_create(gfx, default_postfx_bloom_prefilter_compute()),
		blur = gbbfx.gfx_compute_pipeline_create(gfx, default_postfx_blur_compute()),
		composite = gbbfx.gfx_compute_pipeline_create(gfx, default_postfx_bloom_composite_compute()),
		threshold = threshold,
		knee = 0.5 * threshold,
		intensity = intensity,
		radius = min(max(radius, 1), BLUR_MAX_RADIUS),
	}
}

bloom_pass :: proc(bloom: ^Bloom) -> gbbfx.Render_Pass {
	return gbbfx.Render_Pass{name = "bloom", run = bloom_run, user = bloom}
}

bloom_run :: proc(ctx: ^gbbfx.Pass_Ctx, user: rawptr) {
	bloom := (^Bloom)(user)
	half := gbbfx.pass_acquire(ctx, .Half)
	ping := gbbfx.pass_acquire(ctx, .Half)
	pong := gbbfx.pass_acquire(ctx, .Half)
	out := gbbfx.pass_acquire(ctx)

	pre := Bloom_Prefilter_Uniforms{threshold = bloom.threshold, knee = bloom.knee}
	gbbfx.pass_compute(
		ctx,
		bloom.prefilter,
		[]gbbfx.Texture_Handle{ctx.color},
		half,
		mem.ptr_to_bytes(&pre),
	)
	blur_axis(ctx, bloom.blur, bloom.radius, half, ping, {1, 0})
	blur_axis(ctx, bloom.blur, bloom.radius, ping, pong, {0, 1})

	comp := Bloom_Composite_Uniforms{intensity = bloom.intensity}
	gbbfx.pass_compute(
		ctx,
		bloom.composite,
		[]gbbfx.Texture_Handle{ctx.color, pong},
		out,
		mem.ptr_to_bytes(&comp),
	)
	ctx.color = out
}
