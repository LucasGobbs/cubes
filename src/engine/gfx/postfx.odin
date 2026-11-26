package gfx

import "core:math"
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

// Level weights (xyz) and intensity (w); black floor (x) subtracted from the summed glow.
Bloom_Composite_Uniforms :: struct {
	weights:     [4]f32,
	black_floor: [4]f32,
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
	threshold, knee, intensity, floor: f32, // floor: black floor, subtracted from the summed glow
	levels:                            int, // 1 (half res) or 3 (half, quarter, eighth)
	radius:                            [3]i32, // blur radius per level, in that level's texels
	weights:                           [3]f32, // composite weight per level; unused levels zero
}

// One-level bloom: the half-res bright pass, blurred once.
bloom_create :: proc(
	gfx_ctx: ^Device,
	threshold := f32(0.8),
	intensity := f32(0.6),
	radius := i32(6),
) -> Bloom {
	return bloom_create_multi(gfx_ctx, threshold, 0.5 * threshold, intensity, 0, 1, {radius, 0, 0}, {1, 0, 0})
}

// levels 1 or 3. Level i blurs the one above it (level 0 blurs the bright pass), so the glow widens with the level.
bloom_create_multi :: proc(
	gfx_ctx: ^Device,
	threshold, knee, intensity, floor: f32,
	levels: int,
	radius: [3]i32,
	weights: [3]f32,
) -> Bloom {
	assert(levels >= 1 && levels <= 3)
	bloom := Bloom {
		prefilter = compute_pipeline_create(gfx_ctx, default_postfx_bloom_prefilter_compute()),
		blur = compute_pipeline_create(gfx_ctx, default_postfx_blur_compute()),
		composite = compute_pipeline_create(gfx_ctx, default_postfx_bloom_composite_compute()),
		threshold = threshold,
		knee = knee,
		intensity = intensity,
		floor = floor,
		levels = levels,
		weights = weights,
	}
	for r, i in radius do bloom.radius[i] = min(max(r, 1), BLUR_MAX_RADIUS)
	return bloom
}

bloom_destroy :: proc(gfx_ctx: ^Device, bloom: ^Bloom) {
	compute_pipeline_destroy(gfx_ctx, bloom.prefilter)
	compute_pipeline_destroy(gfx_ctx, bloom.blur)
	compute_pipeline_destroy(gfx_ctx, bloom.composite)
	bloom^ = {}
}

bloom_pass :: proc(bloom: ^Bloom) -> Render_Pass {
	return Render_Pass{name = "bloom", run = bloom_run, user = bloom}
}

// Size of blur level 0 (half), 1 (quarter), 2 (eighth). Pass_Size stops at quarter, so eighth divides here.
bloom_level_size :: proc(level: int, width, height: u32) -> (u32, u32) {
	if level < 2 do return pass_size_dims(Pass_Size(level + 1), width, height)
	return max((width + 7) / 8, 1), max((height + 7) / 8, 1)
}

bloom_run :: proc(ctx: ^Pass_Ctx, user: rawptr) {
	bloom := (^Bloom)(user)

	// Bright pass into half res.
	half := pass_acquire(ctx, .Half)
	pre := Bloom_Prefilter_Uniforms{threshold = bloom.threshold, knee = bloom.knee}
	pass_compute(ctx, bloom.prefilter, []Texture_Handle{ctx.color}, half, mem.ptr_to_bytes(&pre))

	// Each level blurs the one above it, so the glow widens with the level.
	levels := [3]Texture_Handle{}
	src := half
	for i in 0 ..< bloom.levels {
		w, h := bloom_level_size(i, ctx.width, ctx.height)
		tmp := pool_acquire(ctx.renderer, w, h)
		levels[i] = pool_acquire(ctx.renderer, w, h)
		blur_axis(ctx, bloom.blur, bloom.radius[i], src, tmp, {1, 0})
		blur_axis(ctx, bloom.blur, bloom.radius[i], tmp, levels[i], {0, 1})
		src = levels[i]
	}
	// Unused levels bind level 0 with weight zero.
	for i in bloom.levels ..< 3 do levels[i] = levels[0]

	out := pass_acquire(ctx)
	comp := Bloom_Composite_Uniforms {
		weights     = {bloom.weights[0], bloom.weights[1], bloom.weights[2], bloom.intensity},
		black_floor = {bloom.floor, 0, 0, 0},
	}
	pass_compute(
		ctx,
		bloom.composite,
		[]Texture_Handle{ctx.color, levels[0], levels[1], levels[2]},
		out,
		mem.ptr_to_bytes(&comp),
	)
	ctx.color = out
}

// ACES filmic tonemap with exposure, contrast and saturation (postfx_tonemap.slang). Input HDR linear, output display linear.
Tonemap_Uniforms :: struct {
	exposure_scale: f32, // 2^EV
	contrast:       f32,
	saturation:     f32,
	pad:            f32,
}
#assert(size_of(Tonemap_Uniforms) == DEFAULT_POSTFX_TONEMAP_COMPUTE_UNIFORM_BLOCK_SIZE)

Tonemap :: struct {
	pipeline: Compute_Pipeline_Handle,
	params:   Tonemap_Uniforms,
}

tonemap_create :: proc(gfx_ctx: ^Device) -> Tonemap {
	return Tonemap {
		pipeline = compute_pipeline_create(gfx_ctx, default_postfx_tonemap_compute()),
		params = {exposure_scale = 1, contrast = 1, saturation = 1},
	}
}

tonemap_pass :: proc(tonemap: ^Tonemap) -> Render_Pass {
	return Render_Pass{name = "tonemap", run = tonemap_run, user = tonemap}
}

tonemap_run :: proc(ctx: ^Pass_Ctx, user: rawptr) {
	tonemap := (^Tonemap)(user)
	out := pass_acquire(ctx)
	pass_compute(ctx, tonemap.pipeline, []Texture_Handle{ctx.color}, out, mem.ptr_to_bytes(&tonemap.params))
	ctx.color = out
}

// Grade in artist units: exposure in EV stops.
tonemap_set :: proc(tonemap: ^Tonemap, exposure_ev, contrast, saturation: f32) {
	tonemap.params = {exposure_scale = math.pow(2, exposure_ev), contrast = contrast, saturation = saturation}
}
