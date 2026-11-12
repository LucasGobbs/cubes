// F1 stats overlay: dark panel with debug numbers at the bottom-left, available
// in every scene. It is an After_Post render pass, so any scene that runs
// renderer_run_post (gfx_render, renderer_render_frame) shows it; scenes never
// touch it. Text is laid out in the tick (mesh uploads must happen outside a
// frame) and the pass only draws.
package main

import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:time"
import gfx "engine/gfx"
import default "engine/default"
import input "engine/input"
import sdl "vendor:sdl3"
STATS_BUDGET_MS :: 1000.0 / 60.0 // frame quota at 60 fps

STATS_MARGIN :: 10
STATS_HISTORY :: 120
STATS_SAMPLE_SECONDS :: 0.25
STATS_GRAPH_HEIGHT :: 48
STATS_GRAPH_MIN_WIDTH :: 240
STATS_PADDING :: 8
STATS_BACKGROUND :: [4]f32{0, 0, 0, 0.7}

Stats :: struct {
	action:   input.Button_Action,
	dump_action: input.Button_Action,
	visible:  bool,
	font:     gfx.Font,
	// [0] draws into scene_color (swapchain format), [1] into postfx outputs.
	pipelines: [2]gfx.Pipeline_Handle,
	materials: [2]gfx.Material,
	sampler:  gfx.Sampler_Handle,
	mesh:     gfx.Mesh,
	vertices: [dynamic]gfx.VertexData,
	frame_ms: f32, // exponentially smoothed
	render_ms: f32, // CPU prepare+flush, exponentially smoothed
	history:  [STATS_HISTORY]f32, // fps ring buffer, oldest at `head`
	head:     int,
	sample_time:   f32,
	sample_frames: int,
}

stats: Stats

// Registers F1 and the draw pass. Call before the input mark is taken so scene
// switches keep the binding.
stats_create :: proc(dev: ^gfx.Device) {
	inputs := gfx.gfx_input(dev)
	stats.action = input.add_button(inputs, "app.stats")
	input.bind_key(inputs, stats.action, .F1)
	stats.dump_action = input.add_button(inputs, "app.stats_dump")
	input.bind_key(inputs, stats.dump_action, .P) // with the panel open, logs its lines

	font, ok := gfx.font_create(dev, "static/fonts/andale-mono.ttf")
	assert(ok)
	stats.font = font
	stats.pipelines[0] = default.create_textured_overlay_pipeline(dev)
	stats.pipelines[1] = default.create_textured_overlay_pipeline(dev, dev.renderer.post_format)
	stats.sampler = gfx.gfx_sampler_create(dev, gfx.SAMPLER_TRILINEAR)
	for index in 0 ..< 2 {
		stats.materials[index] = gfx.material_create(stats.pipelines[index])
		default.bind_textured_material(&stats.materials[index], stats.font.texture, stats.sampler)
	}
	dummy := [6]gfx.VertexData{}
	stats.mesh = gfx.mesh_create_unindexed(dev, dummy[:])
	gfx.mesh_upload(&dev.renderer, &stats.mesh)

	gfx.renderer_add_pass(&dev.renderer, .After_Post, {name = "stats", run = stats_draw})
}

stats_destroy :: proc(dev: ^gfx.Device) {
	gfx.renderer_clear_passes(&dev.renderer, .After_Post)
	gfx.mesh_destroy(dev, &stats.mesh)
	for index in 0 ..< 2 {
		gfx.material_destroy(&stats.materials[index])
		gfx.gfx_pipeline_destroy(dev, stats.pipelines[index])
	}
	gfx.gfx_sampler_destroy(dev, stats.sampler)
	gfx.font_destroy(dev, &stats.font)
	delete(stats.vertices)
}

stats_tick :: proc(dev: ^gfx.Device, delta_time: f32, scene_name: string) {
	if input.pressed(gfx.gfx_input(dev), stats.action) do stats.visible = !stats.visible
	ms := delta_time * 1000
	stats.frame_ms = ms if stats.frame_ms == 0 else stats.frame_ms * 0.95 + ms * 0.05
	render_ms := f32(time.duration_microseconds(dev.renderer.prepare_time + dev.renderer.flush_time)) / 1000
	stats.render_ms = render_ms if stats.render_ms == 0 else stats.render_ms * 0.95 + render_ms * 0.05
	if stats.frame_ms == ms do stats.history = 1 / max(delta_time, 1e-4) // first frame: no zero-filled history
	// One graph sample per STATS_SAMPLE_SECONDS (mean fps of that window) keeps the curve calm.
	stats.sample_time += delta_time
	stats.sample_frames += 1
	if stats.sample_time >= STATS_SAMPLE_SECONDS {
		stats.history[stats.head] = f32(stats.sample_frames) / stats.sample_time
		stats.head = (stats.head + 1) % STATS_HISTORY
		stats.sample_time, stats.sample_frames = 0, 0
	}
	if !stats.visible do return

	renderer := &dev.renderer
	camera := gfx.gfx_camera(dev).position
	lo, hi, sum := f32(1e9), f32(0), f32(0)
	for fps in stats.history {
		lo, hi, sum = min(lo, fps), max(hi, fps), sum + fps
	}
	avg := sum / STATS_HISTORY
	lines := [?]string {
		fmt.tprintf("scene   %s", scene_name),
		fmt.tprintf("fps     %.0f (%.2f ms)  min %.0f  avg %.0f  max %.0f", 1000 / stats.frame_ms, stats.frame_ms, lo, avg, hi),
		fmt.tprintf("draws   %d  (instanced %d, %d instances)", renderer.draw_calls, renderer.instanced_draws, renderer.instance_count),
		fmt.tprintf("binds   pipelines %d  materials %d", renderer.pipeline_binds, renderer.material_binds),
		fmt.tprintf("tris    %d", renderer.triangles),
		fmt.tprintf(
			"cpu     prepare %.2f  flush %.2f ms",
			f32(time.duration_microseconds(renderer.prepare_time)) / 1000,
			f32(time.duration_microseconds(renderer.flush_time)) / 1000,
		),
		fmt.tprintf(
			"render  %.2f ms avg = %.0f%% of %.2f ms (60 fps) budget",
			stats.render_ms,
			stats.render_ms / STATS_BUDGET_MS * 100,
			f32(STATS_BUDGET_MS),
		),
		fmt.tprintf("window  %dx%d  msaa %s", dev.window_size.x, dev.window_size.y, renderer.msaa_enabled ? "4x" : "off"),
		fmt.tprintf("camera  %.1f %.1f %.1f", camera.x, camera.y, camera.z),
	}
	if input.pressed(gfx.gfx_input(dev), stats.dump_action) {
		for line in lines do log.infof("stats| %s", line)
	}

	text_width: f32
	for line in lines do text_width = max(text_width, gfx.font_text_width(&stats.font, line))
	inner_width := max(text_width, STATS_GRAPH_MIN_WIDTH)
	line_height := f32(stats.font.line_height)
	panel_width := inner_width + 2 * STATS_PADDING
	panel_height := line_height * len(lines) + STATS_GRAPH_HEIGHT + 3 * STATS_PADDING
	// The window can be smaller than the targets sized at startup (fullscreen
	// transitions, menu bar), and the blit crops to it: anchor to what is visible.
	visible_height: i32
	_ = sdl.GetWindowSize(dev.window, nil, &visible_height)
	visible_height = min(visible_height, dev.window_size.y)
	left := f32(STATS_MARGIN)
	top := f32(visible_height) - STATS_MARGIN - panel_height

	clear(&stats.vertices)
	// Solid rect: sample the atlas's white block.
	solid := [2]f32{gfx.FONT_WHITE_U, gfx.FONT_WHITE_V}
	stats_push_rect(dev, left, top, left + panel_width, top + panel_height, solid, STATS_BACKGROUND)
	for line, index in lines {
		y := top + STATS_PADDING + line_height * f32(index) + f32(stats.font.baseline)
		x := left + STATS_PADDING
		quads: [dynamic]gfx.Font_Quad
		quads.allocator = context.temp_allocator
		gfx.font_layout(&stats.font, line, &x, &y, &quads)
		for quad in quads {
			stats_push_rect(dev, quad.x0, quad.y0, quad.x1, quad.y1, {}, {1, 1, 1, 1}, quad)
		}
	}

	// Graph: solid frame lines on top/bottom, dotted average, fps polyline.
	gx0 := left + STATS_PADDING
	gx1 := gx0 + inner_width
	gy0 := top + 2 * STATS_PADDING + line_height * len(lines)
	gy1 := gy0 + STATS_GRAPH_HEIGHT
	frame := [4]f32{0.8, 0.8, 0.8, 0.9}
	stats_push_rect(dev, gx0, gy0, gx1, gy0 + 1, solid, frame)
	stats_push_rect(dev, gx0, gy1 - 1, gx1, gy1, solid, frame)
	range := max(hi - lo, 1) // flat history would otherwise divide by zero
	y_of := proc(fps, lo, range, gy0, gy1: f32) -> f32 {return gy1 - 3 - (fps - lo) / range * (gy1 - gy0 - 6)}
	mid := y_of(avg, lo, range, gy0, gy1)
	step := inner_width / (STATS_HISTORY - 1)
	prev: [2]f32
	for i in 0 ..< STATS_HISTORY {
		point := [2]f32{gx0 + f32(i) * step, y_of(stats.history[(stats.head + i) % STATS_HISTORY], lo, range, gy0, gy1)}
		if i > 0 do stats_push_line(dev, prev, point, solid, {0.4, 1, 0.5, 1})
		prev = point
	}
	for x := gx0; x < gx1; x += 8 { // dotted average, drawn over the curve
		stats_push_rect(dev, x, mid - 0.5, min(x + 4, gx1), mid + 1.5, solid, {1, 0.85, 0.3, 1})
	}
	gfx.mesh_update_unindexed(&dev.renderer, &stats.mesh, stats.vertices[:])
}

// 1.5 px thick segment as a quad, offset along the perpendicular.
stats_push_line :: proc(dev: ^gfx.Device, a, b: [2]f32, solid: [2]f32, color: [4]f32) {
	d := linalg.normalize0(b - a)
	n := [2]f32{-d.y, d.x} * 0.75
	width, height := f32(dev.window_size.x), f32(dev.window_size.y)
	ndc := proc(p: [2]f32, w, h: f32) -> [3]f32 {return {p.x / w * 2 - 1, 1 - p.y / h * 2, 0}}
	p0, p1, p2, p3 := ndc(a + n, width, height), ndc(b + n, width, height), ndc(b - n, width, height), ndc(a - n, width, height)
	append(
		&stats.vertices,
		gfx.VertexData{position = p0, color = color, uv = solid},
		gfx.VertexData{position = p1, color = color, uv = solid},
		gfx.VertexData{position = p2, color = color, uv = solid},
		gfx.VertexData{position = p0, color = color, uv = solid},
		gfx.VertexData{position = p2, color = color, uv = solid},
		gfx.VertexData{position = p3, color = color, uv = solid},
	)
}

// Pixel-space rect (y-down) to two clip-space triangles. With `quad`, UVs come
// from the glyph; otherwise both corners sample the single `solid` texel.
stats_push_rect :: proc(
	dev: ^gfx.Device,
	x0, y0, x1, y1: f32,
	solid: [2]f32,
	color: [4]f32,
	quad: Maybe(gfx.Font_Quad) = nil,
) {
	width, height := f32(dev.window_size.x), f32(dev.window_size.y)
	ndc := proc(x, y, w, h: f32) -> [3]f32 {return {x / w * 2 - 1, 1 - y / h * 2, 0}}
	uv0, uv1, uv2, uv3 := solid, solid, solid, solid
	if glyph, ok := quad.?; ok {
		uv0 = {glyph.s0, glyph.t0}
		uv1 = {glyph.s1, glyph.t0}
		uv2 = {glyph.s1, glyph.t1}
		uv3 = {glyph.s0, glyph.t1}
	}
	p0, p1, p2, p3 := ndc(x0, y0, width, height), ndc(x1, y0, width, height), ndc(x1, y1, width, height), ndc(x0, y1, width, height)
	append(
		&stats.vertices,
		gfx.VertexData{position = p0, color = color, uv = uv0},
		gfx.VertexData{position = p1, color = color, uv = uv1},
		gfx.VertexData{position = p2, color = color, uv = uv2},
		gfx.VertexData{position = p0, color = color, uv = uv0},
		gfx.VertexData{position = p2, color = color, uv = uv2},
		gfx.VertexData{position = p3, color = color, uv = uv3},
	)
}

stats_draw :: proc(ctx: ^gfx.Pass_Ctx, _: rawptr) {
	if !stats.visible || len(stats.vertices) == 0 do return
	dev := ctx.dev
	gfx.renderer_begin_overlay_pass(ctx.renderer, ctx.color)
	pass := ctx.renderer.pass
	target := 0 if ctx.color == ctx.renderer.scene_color else 1 // pipeline color format must match the target
	pipeline := gfx.gfx_pipeline_get(dev, stats.pipelines[target])
	sdl.BindGPUGraphicsPipeline(pass, pipeline.handle)
	gfx.gfx_pipeline_bind_material(dev, pass, dev.command_buffer, &stats.materials[target])
	gfx.gfx_pipeline_bind_draw(
		dev,
		stats.pipelines[target],
		dev.command_buffer,
		{
			view_projection = linalg.MATRIX4F32_IDENTITY,
			model_transform = linalg.MATRIX4F32_IDENTITY,
			material = &stats.materials[target],
		},
	)
	vertex_buffer := gfx.gfx_buffer_get(dev, stats.mesh.vertex_buffer)
	sdl.BindGPUVertexBuffers(pass, 0, &(sdl.GPUBufferBinding{buffer = vertex_buffer.handle}), 1)
	sdl.DrawGPUPrimitives(pass, u32(len(stats.vertices)), 1, 0, 0)
	gfx.renderer_end_pass(ctx.renderer)
}
