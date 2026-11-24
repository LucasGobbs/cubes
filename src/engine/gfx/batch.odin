// 2D immediate batcher: sprites, rects, lines and text as triangles in one
// vertex buffer, drawn in a single overlay pass after the 3D scene. Vertices
// are converted to NDC on the CPU (world px, Y down -> NDC through the camera),
// so the shader runs with an idactor view-projection.
//
// Lifecycle per frame: batch_begin -> draw calls -> batch_end, all outside a
// frame (batch_end uploads the mesh). The pass body only reads the batch.
// Painter's order: draws in call order; the batch never sorts.
package gfx

import "core:math"
import "core:math/linalg"
import "core:slice"
import sdl "vendor:sdl3"

BATCH_INITIAL_VERTICES :: 6 * 8192 // allocated up front so growth never happens mid-game

Rect :: struct {
	x, y, w, h: f32,
}

Camera2D :: struct {
	position:      [2]f32, // view centre, world px
	zoom:          f32, // 0 = 1
	rotation:      f32, // radians
	viewport:      [2]f32, // logical resolution; {0,0} = window size
	integer_scale: bool, // pixel art: whole-number scale, letterboxed and centred
}

// World px -> NDC. The window is the target; the view is scaled to fit it
// (letterbox), centred on `position`, rotated by `rotation`.
camera2d_matrix :: proc(cam: Camera2D, window: [2]i32) -> matrix[4, 4]f32 {
	scale, win := camera2d_scale(cam, window)
	// NDC = (2s/win) * R(-rot) * (world - position), with y flipped.
	s, c := math.sincos(cam.rotation)
	kx := 2 * scale / win.x
	ky := 2 * scale / win.y
	m := linalg.MATRIX4F32_IDENTITY
	m[0, 0] = kx * c
	m[0, 1] = kx * s
	m[1, 0] = ky * s
	m[1, 1] = -ky * c
	m[0, 3] = -(m[0, 0] * cam.position.x + m[0, 1] * cam.position.y)
	m[1, 3] = -(m[1, 0] * cam.position.x + m[1, 1] * cam.position.y)
	return m
}

// Inverse of camera2d_matrix for a window px position (y down).
screen_to_world :: proc(cam: Camera2D, window: [2]i32, screen: [2]f32) -> [2]f32 {
	scale, win := camera2d_scale(cam, window)
	s, c := math.sincos(cam.rotation)
	view := [2]f32{(screen.x - win.x / 2) / scale, (screen.y - win.y / 2) / scale}
	// rel = R(rot) * view
	rel := [2]f32{c * view.x - s * view.y, s * view.x + c * view.y}
	return cam.position + rel
}

// Pixels-per-world-px and window size as floats, shared by both mappings.
camera2d_scale :: proc(cam: Camera2D, window: [2]i32) -> (scale: f32, win: [2]f32) {
	win = {f32(window.x), f32(window.y)}
	view := cam.viewport
	if view == {} do view = win
	scale = min(win.x / view.x, win.y / view.y)
	if cam.integer_scale do scale = max(math.floor(scale), 1)
	zoom := cam.zoom if cam.zoom != 0 else 1
	return scale * zoom, win
}

Batch_Run :: struct {
	texture:     Texture_Handle,
	first, count: u32, // vertex range in Batch.vertices
}

Batch :: struct {
	vertices: [dynamic]VertexData,
	runs:     [dynamic]Batch_Run,
	white:    Texture_Handle,
	sampler:  Sampler_Handle,
	pipeline: Pipeline_Handle,
	material: Material,
	mesh:     Mesh,
	camera:   matrix[4, 4]f32, // world px -> NDC, set by batch_begin
	sprites:  int, // quads pushed this frame
	draw:     bool, // set by batch_end; false = nothing to draw
}

// Creates GPU resources only. Call batch_register once the Batch sits at its
// final address: the pass keeps a pointer to it.
batch_create :: proc(gfx_ctx: ^Device) -> Batch {
	b: Batch
	b.white = texture_create_rgba8(gfx_ctx, 1, 1, false, false)
	white := texture_get(gfx_ctx, b.white)
	white._temporary_raw_data = []u8{255, 255, 255, 255}
	uploader_begin(&gfx_ctx.renderer.uploader)
	uploader_upload_texture(&gfx_ctx.renderer.uploader, b.white)
	uploader_flush_blocking(&gfx_ctx.renderer.uploader)
	white._temporary_raw_data = nil

	b.sampler = sampler_create(gfx_ctx, SAMPLER_NEAREST_CLAMP)
	b.pipeline = create_textured_overlay_pipeline(gfx_ctx)
	b.material = material_make(b.pipeline)
	bind_textured_material(&b.material, b.white, b.sampler)
	// Empty buffer of full capacity: no temp data, so mesh_update_unindexed reuses it.
	b.mesh = Mesh {
		vertex_buffer = buffer_create(gfx_ctx, u32(BATCH_INITIAL_VERTICES * size_of(VertexData)), .VERTEX),
	}
	return b
}

// Adds the batch pass to the After_Scene slot. `b` must not move afterwards.
batch_register :: proc(gfx_ctx: ^Device, b: ^Batch) {
	renderer_add_pass(&gfx_ctx.renderer, .After_Scene, {name = "batch", run = batch_draw, user = b})
}

batch_destroy :: proc(gfx_ctx: ^Device, b: ^Batch) {
	for pass, index in gfx_ctx.renderer.passes[.After_Scene] {
		if pass.user == rawptr(b) {
			ordered_remove(&gfx_ctx.renderer.passes[.After_Scene], index)
			break
		}
	}
	mesh_destroy(gfx_ctx, &b.mesh)
	material_destroy(&b.material)
	pipeline_destroy(gfx_ctx, b.pipeline)
	sampler_destroy(gfx_ctx, b.sampler)
	texture_destroy(gfx_ctx, b.white)
	delete(b.vertices)
	delete(b.runs)
	b^ = {}
}

batch_begin :: proc(b: ^Batch, gfx_ctx: ^Device, cam: Camera2D) {
	clear(&b.vertices)
	clear(&b.runs)
	b.sprites = 0
	b.draw = false
	b.camera = camera2d_matrix(cam, gfx_ctx.window_size)
}

// Rotated, flipped, origin-relative textured quad. `src` in texture px; {} = whole image.
batch_sprite :: proc(
	b: ^Batch,
	texture: Texture_Handle,
	texture_size: [2]f32,
	pos, size: [2]f32,
	src: Rect = {},
	color := [4]f32{1, 1, 1, 1},
	origin := [2]f32{0.5, 0.5},
	rotation: f32 = 0,
	flip_x := false,
	flip_y := false,
) {
	rect := src
	if rect == {} do rect = {0, 0, texture_size.x, texture_size.y}
	u0, u1 := rect.x / texture_size.x, (rect.x + rect.w) / texture_size.x
	v0, v1 := rect.y / texture_size.y, (rect.y + rect.h) / texture_size.y
	if flip_x do u0, u1 = u1, u0
	if flip_y do v0, v1 = v1, v0

	s, c := math.sincos(rotation)
	corners := [4][2]f32{{0, 0}, {1, 0}, {1, 1}, {0, 1}}
	uvs := [4][2]f32{{u0, v0}, {u1, v0}, {u1, v1}, {u0, v1}}
	world: [4][2]f32
	for corner, index in corners {
		local := (corner - origin) * size
		world[index] = pos + [2]f32{c * local.x - s * local.y, s * local.x + c * local.y}
	}
	batch_quad(b, texture, world, uvs, color)
}

batch_rect :: proc(b: ^Batch, pos, size: [2]f32, color: [4]f32, rotation: f32 = 0, origin := [2]f32{0.5, 0.5}) {
	batch_sprite(b, b.white, {1, 1}, pos, size, color = color, origin = origin, rotation = rotation)
}

// Rotated rect from `from` to `to`, `thickness` px wide, centred on the segment.
batch_line :: proc(b: ^Batch, from, to: [2]f32, thickness: f32, color: [4]f32) {
	delta := to - from
	length := linalg.length(delta)
	angle := math.atan2(delta.y, delta.x)
	batch_rect(b, (from + to) / 2, {length, thickness}, color, rotation = angle)
}

// `pos` is the top-left of the first line; glyph quads come from font_layout.
batch_text :: proc(b: ^Batch, font: ^Font, text: string, pos: [2]f32, color: [4]f32) {
	x, y := pos.x, pos.y + f32(font.baseline)
	quads: [dynamic]Font_Quad
	quads.allocator = context.temp_allocator
	font_layout(font, text, &x, &y, &quads)
	for quad in quads {
		world := [4][2]f32{{quad.x0, quad.y0}, {quad.x1, quad.y0}, {quad.x1, quad.y1}, {quad.x0, quad.y1}}
		uvs := [4][2]f32{{quad.s0, quad.t0}, {quad.s1, quad.t0}, {quad.s1, quad.t1}, {quad.s0, quad.t1}}
		batch_quad(b, font.texture, world, uvs, color)
	}
}

batch_end :: proc(b: ^Batch, gfx_ctx: ^Device) {
	b.draw = len(b.vertices) > 0 // SDL rejects empty buffers; mesh_update asserts
	if b.draw do mesh_update_unindexed(&gfx_ctx.renderer, &b.mesh, b.vertices[:])
}

// Two triangles (0,1,2) and (0,2,3) from four world-px corners, converted to NDC.
batch_quad :: proc(b: ^Batch, texture: Texture_Handle, world: [4][2]f32, uv: [4][2]f32, color: [4]f32) {
	if len(b.runs) == 0 || b.runs[len(b.runs) - 1].texture != texture {
		append(&b.runs, Batch_Run{texture = texture, first = u32(len(b.vertices))})
	}
	order := [6]int{0, 1, 2, 0, 2, 3}
	for index in order {
		clip := b.camera * [4]f32{world[index].x, world[index].y, 0, 1}
		append(&b.vertices, VertexData{position = {clip.x, clip.y, 0}, color = color, uv = uv[index]})
	}
	b.runs[len(b.runs) - 1].count += 6
	b.sprites += 1
}

batch_draw :: proc(ctx: ^Pass_Ctx, user: rawptr) {
	b := cast(^Batch)user
	if !b.draw do return
	gfx_ctx := ctx.gfx_ctx
	renderer_begin_overlay_pass(ctx.renderer, ctx.color)
	pass := ctx.renderer.pass
	pipeline := pipeline_get(gfx_ctx, b.pipeline)
	pipeline_bind_native(pass, pipeline, false) // overlay pass is always 1x
	vertex_buffer := buffer_get(gfx_ctx, b.mesh.vertex_buffer)
	sdl.BindGPUVertexBuffers(pass, 0, &(sdl.GPUBufferBinding{buffer = vertex_buffer.handle}), 1)
	for run in b.runs {
		// Re-binding the texture replaces the material's entry, so each run samples its own.
		bind_textured_material(&b.material, run.texture, b.sampler)
		pipeline_bind_material(gfx_ctx, pass, gfx_ctx.command_buffer, &b.material)
		pipeline_bind_draw(
			gfx_ctx,
			b.pipeline,
			gfx_ctx.command_buffer,
			{
				view_projection = linalg.MATRIX4F32_IDENTITY,
				model_transform = linalg.MATRIX4F32_IDENTITY,
				material = &b.material,
			},
		)
		sdl.DrawGPUPrimitives(pass, run.count, 1, run.first, 0)
	}
	renderer_end_pass(ctx.renderer)
}
