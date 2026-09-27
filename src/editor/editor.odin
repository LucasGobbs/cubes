// Editor overlay UI: microui context rendered through gbbfx as NDC quads in
// a depth-less overlay pass. Text comes from a stb_truetype-baked atlas.
// Game code builds windows between editor_begin/editor_end and calls
// editor_draw after post processing, before present.
package editor

import gbbfx "../gbbfx"
import defaults "../gbbfx/defaults"
import goose_sdl "../goose/adapters/sdl_gpu"
import "core:math/linalg"
import sdl "vendor:sdl3"
import mu "vendor:microui"

Span_Texture :: enum {
	ATLAS,
	VIEWPORT,
}

Draw_Span :: struct {
	start, count: u32,
	clip:         mu.Rect,
	texture:      Span_Texture,
}

Editor :: struct {
	ctx:      mu.Context,
	gfx:      ^gbbfx.Gfx,
	font:     gbbfx.Font,
	pipeline: gbbfx.Pipeline_Handle,
	material: gbbfx.Material,
	sampler:  gbbfx.Sampler_Handle,
	mesh:     gbbfx.Mesh,
	vertices: [dynamic]gbbfx.VertexData,
	spans:    [dynamic]Draw_Span,
	visible:  bool,
}

// microui's text callbacks carry no user data; the editor is a singleton in
// practice, so they read this.
g_active_font: ^gbbfx.Font

editor_init :: proc(gfx: ^gbbfx.Gfx, ed: ^Editor, font_path := "static/fonts/andale-mono.ttf") -> bool {
	font, ok := gbbfx.font_create(gfx, font_path)
	if !ok do return false
	ed.gfx = gfx
	ed.font = font
	ed.visible = true
	g_active_font = &ed.font

	mu.init(&ed.ctx)
	ed.ctx.text_width = proc(font: mu.Font, text: string) -> i32 {
		return i32(gbbfx.font_text_width(g_active_font, text))
	}
	ed.ctx.text_height = proc(font: mu.Font) -> i32 {
		return g_active_font.line_height
	}

	ed.pipeline = defaults.create_textured_overlay_pipeline(gfx)
	ed.sampler = gbbfx.gfx_sampler_create(gfx)
	ed.material = gbbfx.material_create(ed.pipeline)
	defaults.bind_textured_material(&ed.material, ed.font.texture, ed.sampler)

	dummy := [6]gbbfx.VertexData{}
	ed.mesh = gbbfx.mesh_create_unindexed(gfx, dummy[:])
	gbbfx.mesh_upload(&gfx.renderer, &ed.mesh)
	return true
}

editor_destroy :: proc(gfx: ^gbbfx.Gfx, ed: ^Editor) {
	gbbfx.font_destroy(gfx, &ed.font)
	gbbfx.mesh_destroy(gfx, &ed.mesh)
	gbbfx.material_destroy(&ed.material)
	gbbfx.gfx_sampler_destroy(gfx, ed.sampler)
	gbbfx.gfx_pipeline_destroy(gfx, ed.pipeline)
	delete(ed.vertices)
	delete(ed.spans)
	ed^ = {}
}

// True when the mouse is inside the viewport body AND the Viewport window
// is the topmost hovered container, so clicks/drags on other editor windows
// never reach the game. When the editor is hidden the game owns the mouse.
editor_mouse_in_viewport :: proc(ed: ^Editor, viewport: mu.Rect) -> bool {
	if !ed.visible do return true
	pos := ed.ctx.mouse_pos
	if pos.x < viewport.x || pos.y < viewport.y do return false
	if pos.x >= viewport.x + viewport.w || pos.y >= viewport.y + viewport.h do return false
	return ed.ctx.hover_root == mu.get_container(&ed.ctx, "Viewport")
}

editor_begin :: proc(ed: ^Editor) -> ^mu.Context {
	mu.begin(&ed.ctx)
	return &ed.ctx
}

editor_end :: proc(ed: ^Editor) {
	mu.end(&ed.ctx)
}

// Feeds one SDL event to microui. TAB toggles visibility (and relative mouse
// mode) even while hidden, so it doubles as the editor on/off key.
editor_handle_event :: proc(ed: ^Editor, event: ^sdl.Event) {
	if event.type == .KEY_DOWN && event.key.scancode == .TAB && !event.key.repeat {
		ed.visible = !ed.visible
		_ = sdl.SetWindowRelativeMouseMode(ed.gfx.window, !ed.visible)
		return
	}
	if !ed.visible do return

	#partial switch event.type {
	case .MOUSE_MOTION:
		mu.input_mouse_move(&ed.ctx, i32(event.motion.x), i32(event.motion.y))
	case .MOUSE_BUTTON_DOWN:
		mu.input_mouse_down(
			&ed.ctx,
			i32(event.button.x),
			i32(event.button.y),
			to_mu_mouse(event.button.button),
		)
	case .MOUSE_BUTTON_UP:
		mu.input_mouse_up(
			&ed.ctx,
			i32(event.button.x),
			i32(event.button.y),
			to_mu_mouse(event.button.button),
		)
	case .MOUSE_WHEEL:
		mu.input_scroll(&ed.ctx, -i32(event.wheel.integer_x) * 30, -i32(event.wheel.integer_y) * 30)
	case .TEXT_INPUT:
		mu.input_text(&ed.ctx, string(event.text.text))
	case .KEY_DOWN:
		if key, ok := to_mu_key(event.key.scancode); ok do mu.input_key_down(&ed.ctx, key)
	case .KEY_UP:
		if key, ok := to_mu_key(event.key.scancode); ok do mu.input_key_up(&ed.ctx, key)
	}
}

to_mu_mouse :: proc(button: u8) -> mu.Mouse {
	switch button {
	case sdl.BUTTON_LEFT:
		return .LEFT
	case sdl.BUTTON_RIGHT:
		return .RIGHT
	case sdl.BUTTON_MIDDLE:
		return .MIDDLE
	}
	return .LEFT
}

to_mu_key :: proc(scancode: sdl.Scancode) -> (mu.Key, bool) {
	#partial switch scancode {
	case .LSHIFT, .RSHIFT:
		return .SHIFT, true
	case .LCTRL, .RCTRL:
		return .CTRL, true
	case .LALT, .RALT:
		return .ALT, true
	case .BACKSPACE:
		return .BACKSPACE, true
	case .DELETE:
		return .DELETE, true
	case .RETURN, .KP_ENTER:
		return .RETURN, true
	case .LEFT:
		return .LEFT, true
	case .RIGHT:
		return .RIGHT, true
	case .HOME:
		return .HOME, true
	case .END:
		return .END, true
	case .A:
		return .A, true
	case .X:
		return .X, true
	case .C:
		return .C, true
	case .V:
		return .V, true
	}
	return {}, false
}

ndc_position :: proc(x, y, width, height: f32) -> [3]f32 {
	return {x / width * 2 - 1, 1 - y / height * 2, 0}
}

push_quad :: proc(
	ed: ^Editor,
	x0, y0, x1, y1: f32,
	uv0, uv1: [2]f32,
	color: [4]f32,
) {
	w := f32(ed.gfx.window_size.x)
	h := f32(ed.gfx.window_size.y)
	p0 := ndc_position(x0, y0, w, h)
	p1 := ndc_position(x1, y0, w, h)
	p2 := ndc_position(x1, y1, w, h)
	p3 := ndc_position(x0, y1, w, h)
	uv00 := uv0
	uv10 := [2]f32{uv1.x, uv0.y}
	uv11 := uv1
	uv01 := [2]f32{uv0.x, uv1.y}
	append(
		&ed.vertices,
		gbbfx.VertexData{position = p0, color = color, uv = uv00},
		gbbfx.VertexData{position = p1, color = color, uv = uv10},
		gbbfx.VertexData{position = p2, color = color, uv = uv11},
		gbbfx.VertexData{position = p0, color = color, uv = uv00},
		gbbfx.VertexData{position = p2, color = color, uv = uv11},
		gbbfx.VertexData{position = p3, color = color, uv = uv01},
	)
}

color01 :: proc(color: mu.Color) -> [4]f32 {
	return {f32(color.r), f32(color.g), f32(color.b), f32(color.a)} / 255
}

push_glyph :: proc(ed: ^Editor, ch: rune, x, y: ^f32, color: [4]f32) {
	quad, ok := gbbfx.font_glyph_quad(&ed.font, ch, x, y)
	if !ok do return
	push_quad(
		ed,
		quad.x0, quad.y0, quad.x1, quad.y1,
		{quad.s0, quad.t0}, {quad.s1, quad.t1},
		color,
	)
}

push_text :: proc(ed: ^Editor, pos: mu.Vec2, color: mu.Color, text: string) {
	x := f32(pos.x)
	y := f32(pos.y) + f32(ed.font.baseline) // mu gives top-left; layout wants the baseline
	for ch in text {
		push_glyph(ed, ch, &x, &y, color01(color))
	}
}

// The baked atlas has no icon glyphs; ASCII stand-ins are enough for the
// editor (close, check, collapsed, expanded, resize).
push_icon :: proc(ed: ^Editor, cmd: ^mu.Command_Icon) {
	glyph: rune
	#partial switch cmd.id {
	case .CLOSE:
		glyph = 'x'
	case .CHECK:
		glyph = '*'
	case .COLLAPSED:
		glyph = '+'
	case .EXPANDED:
		glyph = '-'
	case .RESIZE:
		glyph = '='
	case:
		return
	}
	x := f32(cmd.rect.x) + 2
	y := f32(cmd.rect.y) + 1
	push_glyph(ed, glyph, &x, &y, color01(cmd.color))
}

// Turns the microui command list into quads, split into one span per clip
// rect so each span gets its own scissor.
editor_build :: proc(ed: ^Editor) {
	clear(&ed.vertices)
	clear(&ed.spans)
	clip := mu.Rect{0, 0, ed.gfx.window_size.x, ed.gfx.window_size.y}
	span_start := u32(0)

	finish_span :: proc(ed: ^Editor, start: ^u32, clip: mu.Rect) {
		if u32(len(ed.vertices)) > start^ {
			append(&ed.spans, Draw_Span{start^, u32(len(ed.vertices)) - start^, clip, .ATLAS})
			start^ = u32(len(ed.vertices))
		}
	}

	cmd: ^mu.Command
	for mu.next_command(&ed.ctx, &cmd) {
		#partial switch c in cmd.variant {
		case ^mu.Command_Clip:
			finish_span(ed, &span_start, clip)
			clip = c.rect
		case ^mu.Command_Rect:
			push_quad(
				ed,
				f32(c.rect.x), f32(c.rect.y),
				f32(c.rect.x + c.rect.w), f32(c.rect.y + c.rect.h),
				{gbbfx.FONT_WHITE_U, gbbfx.FONT_WHITE_V},
				{gbbfx.FONT_WHITE_U, gbbfx.FONT_WHITE_V},
				color01(c.color),
			)
		case ^mu.Command_Text:
			push_text(ed, c.pos, c.color, c.str)
		case ^mu.Command_Icon:
			push_icon(ed, c)
		}
	}
	finish_span(ed, &span_start, clip)
}

// Appends the game-view quad: samples the whole viewport texture into the
// Viewport window's body rect, clipped to it.
push_viewport_quad :: proc(
	ed: ^Editor,
	rect: mu.Rect,
) {
	push_quad(
		ed,
		f32(rect.x), f32(rect.y),
		f32(rect.x + rect.w), f32(rect.y + rect.h),
		{0, 0}, {1, 1},
		{1, 1, 1, 1},
	)
	start := u32(len(ed.vertices)) - 6
	append(&ed.spans, Draw_Span{start, 6, rect, .VIEWPORT})
}

// Rebuilds the overlay geometry, uploads it, and composites the final frame
// directly on the swapchain: editor chrome (atlas) plus the post-processed
// scene inside the viewport rect. Editor pixels never go through the game's
// post-processing because the post chain finished before this pass.
editor_draw :: proc(
	ed: ^Editor,
	gfx: ^gbbfx.Gfx,
	viewport_texture: gbbfx.Texture_Handle,
	viewport_rect: mu.Rect,
) {
	if !ed.visible do return
	editor_build(ed)
	if viewport_rect.w > 0 && viewport_rect.h > 0 {
		push_viewport_quad(ed, viewport_rect)
	}
	if len(ed.vertices) == 0 do return

	renderer := &gfx.renderer
	gbbfx.mesh_update_unindexed(renderer, &ed.mesh, ed.vertices[:])

	gbbfx.renderer_begin_present_pass(renderer)
	pass := renderer.pass
	pipeline := gbbfx.gfx_pipeline_get(gfx, ed.pipeline)
	sdl.BindGPUGraphicsPipeline(pass, pipeline.handle)
	gbbfx.gfx_pipeline_bind_material(gfx, pass, gfx.command_buffer, &ed.material)
	gbbfx.gfx_pipeline_bind_draw(
		gfx,
		ed.pipeline,
		gfx.command_buffer,
		{
			view_projection = linalg.MATRIX4F32_IDENTITY,
			model_transform = linalg.MATRIX4F32_IDENTITY,
			material = &ed.material,
		},
	)
	bound := Span_Texture.ATLAS
	viewport_texture_resource := gbbfx.gfx_texture_get(gfx, viewport_texture)
	sampler := gbbfx.gfx_sampler_get(gfx, ed.sampler)
	vertex_buffer := gbbfx.gfx_buffer_get(gfx, ed.mesh.vertex_buffer)
	for span in ed.spans {
		if span.texture != bound {
			if span.texture == .VIEWPORT {
				goose_sdl.bind_sampler(
					pass,
					defaults.DEFAULT_TEXTURED_FRAGMENT_TEX,
					defaults.DEFAULT_TEXTURED_FRAGMENT_TEX_SAMPLER,
					viewport_texture_resource.handle,
					sampler.handle,
				)
			} else {
				gbbfx.gfx_pipeline_bind_material(gfx, pass, gfx.command_buffer, &ed.material)
			}
			bound = span.texture
		}
		clip := sdl.Rect{span.clip.x, span.clip.y, span.clip.w, span.clip.h}
		sdl.SetGPUScissor(pass, clip)
		sdl.BindGPUVertexBuffers(
			pass,
			0,
			&(sdl.GPUBufferBinding{buffer = vertex_buffer.handle}),
			1,
		)
		sdl.DrawGPUPrimitives(pass, span.count, 1, span.start, 0)
	}
	gbbfx.renderer_end_pass(renderer)
}
