package gbbfx

import sdl "vendor:sdl3"

// Post-processing passes. Passes register per slot on the Renderer and run in
// renderer_run_post, in slot order then registration order. Transient textures
// come from a pool, so effects never touch command buffers, auxiliary targets
// or resize logic.

Pass_Slot :: enum u8 {
	After_Scene, // ctx.color = scene_color (COLOR_TARGET | SAMPLER); overlay passes allowed
	Post,        // effect chain
	After_Post,  // ctx.color = chain output (transient, COLOR_TARGET)
}

Pass_Size :: enum u8 {
	Full,
	Half,
	Quarter,
}

Render_Pass :: struct {
	name: string, // for logs
	run:  proc(ctx: ^Pass_Ctx, user: rawptr),
	user: rawptr, // borrowed; must outlive the renderer/camera that registered it
}

Pass_Ctx :: struct {
	renderer: ^Renderer,
	gfx:      ^Gfx,
	// Current frame color. Starts as scene_color. A compute pass producing new
	// output sets ctx.color = output; a graphics pass drawing into it
	// (renderer_begin_overlay_pass(ctx.renderer, ctx.color)) leaves it unchanged.
	color:    Texture_Handle,
	width:    u32, // dimensions of scene_color
	height:   u32,
}

// Every postfx shader declares [numthreads(8, 8, 1)].
PASS_GROUP_SIZE :: 8

renderer_add_pass :: proc(renderer: ^Renderer, slot: Pass_Slot, pass: Render_Pass) {
	append(&renderer.passes[slot], pass)
}

renderer_clear_passes :: proc(renderer: ^Renderer, slot: Pass_Slot) {
	clear(&renderer.passes[slot])
}

renderer_set_passes :: proc(renderer: ^Renderer, slot: Pass_Slot, passes: []Render_Pass) {
	clear(&renderer.passes[slot])
	append(&renderer.passes[slot], ..passes)
}

// Runs every registered pass and returns the frame's final color. With no
// passes it returns scene_color and allocates nothing.
renderer_run_post :: proc(renderer: ^Renderer) -> Texture_Handle {
	assert(renderer.gfx.frame_open)
	assert(renderer.pass == nil)
	total := 0
	for slot in Pass_Slot do total += len(renderer.passes[slot])
	if total == 0 do return renderer.scene_color

	pool_begin_frame(renderer)
	scene := gfx_texture_get(renderer.gfx, renderer.scene_color)
	ctx := Pass_Ctx {
		renderer = renderer,
		gfx      = renderer.gfx,
		color    = renderer.scene_color,
		width    = scene.width,
		height   = scene.height,
	}
	for slot in Pass_Slot {
		for pass in renderer.passes[slot] do pass.run(&ctx, pass.user)
	}
	return ctx.color
}

// Pure: the dimensions of a transient texture of `size` derived from the
// frame size. Never returns zero.
pass_size_dims :: proc(size: Pass_Size, width, height: u32) -> (u32, u32) {
	divisor: u32
	switch size {
	case .Full:    divisor = 1
	case .Half:    divisor = 2
	case .Quarter: divisor = 4
	}
	return max(1, (width + divisor - 1) / divisor), max(1, (height + divisor - 1) / divisor)
}

// Pure: compute dispatch groups covering a width x height output.
groups_for :: proc(width, height: u32) -> [3]u32 {
	return {(width + PASS_GROUP_SIZE - 1) / PASS_GROUP_SIZE, (height + PASS_GROUP_SIZE - 1) / PASS_GROUP_SIZE, 1}
}

// Transient texture valid only for the current frame.
pass_acquire :: proc(ctx: ^Pass_Ctx, size := Pass_Size.Full) -> Texture_Handle {
	width, height := pass_size_dims(size, ctx.width, ctx.height)
	return pool_acquire(ctx.renderer, width, height)
}

// Dispatches a postfx compute shader writing `out`, sized to out.
pass_compute :: proc(
	ctx: ^Pass_Ctx,
	pipeline: Compute_Pipeline_Handle,
	sampled: []Texture_Handle,
	out: Texture_Handle,
	uniforms: []byte = nil,
) {
	target := gfx_texture_get(ctx.gfx, out)
	gfx_compute_dispatch(
		ctx.gfx,
		pipeline,
		[]Texture_Handle{out},
		sampled,
		ctx.renderer.post_sampler,
		groups_for(target.width, target.height),
		uniforms,
	)
}

Pool_Entry :: struct {
	texture:       Texture_Handle,
	width, height: u32,
	in_use:        bool,
}

Texture_Pool :: struct {
	entries:       [dynamic]Pool_Entry,
	width, height: u32, // scene_color size the entries were created for
}

// Frees every transient for the frame; rebuilds the pool when the scene resizes.
pool_begin_frame :: proc(renderer: ^Renderer) {
	pool := &renderer.pool
	for &entry in pool.entries do entry.in_use = false
	scene := gfx_texture_get(renderer.gfx, renderer.scene_color)
	if scene.width == pool.width && scene.height == pool.height do return
	// The last submitted frame may still read these textures.
	_ = sdl.WaitForGPUIdle(renderer.gfx.gpu) // the last submitted frame may still read these textures
	for entry in pool.entries do gfx_texture_destroy(renderer.gfx, entry.texture)
	clear(&pool.entries)
	pool.width, pool.height = scene.width, scene.height
}

pool_acquire :: proc(renderer: ^Renderer, width, height: u32) -> Texture_Handle {
	pool := &renderer.pool
	for &entry in pool.entries {
		if !entry.in_use && entry.width == width && entry.height == height {
			entry.in_use = true
			return entry.texture
		}
	}
	// shortcut: no memory aliasing within a frame, every acquire gets its own
	// texture; add lifetime tracking when a chain passes ~8 transients.
	assert(len(pool.entries) < 16, "too many transient textures")
	texture := gfx_texture_create_with_usage(
		renderer.gfx,
		width,
		height,
		renderer.post_format,
		{.COMPUTE_STORAGE_WRITE, .SAMPLER, .COLOR_TARGET},
	)
	append(&pool.entries, Pool_Entry{texture = texture, width = width, height = height, in_use = true})
	return texture
}
