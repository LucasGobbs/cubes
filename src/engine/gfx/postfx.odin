package gfx

import "core:mem"

// Post-process effects. They live here, not in gfx, because `default`
// owns the generated shader parameters and imports 

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
	pipeline: Compute_Pipeline_Handle,
	radius:   i32,
}

blur_create :: proc(gfx_ctx: ^Device, radius: i32 = 4) -> Blur {
	return Blur {
		pipeline = compute_pipeline_create(gfx_ctx, default_postfx_blur_compute()),
		radius = min(max(radius, 1), BLUR_MAX_RADIUS),
	}
}

blur_pass :: proc(blur: ^Blur) -> Render_Pass {
	return Render_Pass{name = "blur", run = blur_run, user = blur}
}

blur_run :: proc(ctx: ^Pass_Ctx, user: rawptr) {
	blur := (^Blur)(user)
	tmp := pass_acquire(ctx)
	out := pass_acquire(ctx)
	blur_axis(ctx, blur.pipeline, blur.radius, ctx.color, tmp, {1, 0})
	blur_axis(ctx, blur.pipeline, blur.radius, tmp, out, {0, 1})
	ctx.color = out
}

// One separable blur pass: sample `src` along `direction` into `dst`.
blur_axis :: proc(
	ctx: ^Pass_Ctx,
	pipeline: Compute_Pipeline_Handle,
	radius: i32,
	src, dst: Texture_Handle,
	direction: [2]f32,
) {
	u := Blur_Uniforms{direction = direction, radius = radius}
	pass_compute(ctx, pipeline, []Texture_Handle{src}, dst, mem.ptr_to_bytes(&u))
}

Bloom :: struct {
	prefilter, blur, composite: Compute_Pipeline_Handle, // blur = postfx_blur
	threshold, knee, intensity: f32,
	radius:                     i32,
}

bloom_create :: proc(
	gfx_ctx: ^Device,
	threshold := f32(0.8),
	intensity := f32(0.6),
	radius := i32(6),
) -> Bloom {
	return Bloom {
		prefilter = compute_pipeline_create(gfx_ctx, default_postfx_bloom_prefilter_compute()),
		blur = compute_pipeline_create(gfx_ctx, default_postfx_blur_compute()),
		composite = compute_pipeline_create(gfx_ctx, default_postfx_bloom_composite_compute()),
		threshold = threshold,
		knee = 0.5 * threshold,
		intensity = intensity,
		radius = min(max(radius, 1), BLUR_MAX_RADIUS),
	}
}

bloom_pass :: proc(bloom: ^Bloom) -> Render_Pass {
	return Render_Pass{name = "bloom", run = bloom_run, user = bloom}
}

bloom_run :: proc(ctx: ^Pass_Ctx, user: rawptr) {
	bloom := (^Bloom)(user)
	half := pass_acquire(ctx, .Half)
	ping := pass_acquire(ctx, .Half)
	pong := pass_acquire(ctx, .Half)
	out := pass_acquire(ctx)

	pre := Bloom_Prefilter_Uniforms{threshold = bloom.threshold, knee = bloom.knee}
	pass_compute(
		ctx,
		bloom.prefilter,
		[]Texture_Handle{ctx.color},
		half,
		mem.ptr_to_bytes(&pre),
	)
	blur_axis(ctx, bloom.blur, bloom.radius, half, ping, {1, 0})
	blur_axis(ctx, bloom.blur, bloom.radius, ping, pong, {0, 1})

	comp := Bloom_Composite_Uniforms{intensity = bloom.intensity}
	pass_compute(
		ctx,
		bloom.composite,
		[]Texture_Handle{ctx.color, pong},
		out,
		mem.ptr_to_bytes(&comp),
	)
	ctx.color = out
}
