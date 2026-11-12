// Scene transitions: the host consumes engine.change_scene requests. The screen
// is covered by a full-screen overlay (After_Post pass, drawn under the F1
// stats), the scene swaps when fully covered, then the overlay clears.
// The overlay reuses the stats font's white texel, pipelines and sampler.
package engine

import "core:log"
import "core:math"
import "core:math/linalg"
import gfx "gfx"
import sdl "vendor:sdl3"

Transition_Phase :: enum {
	None,
	Out, // covering the old scene
	In, // uncovering the new one
}

Transition :: struct {
	phase:    Transition_Phase,
	request:  Scene_Request,
	target:   int, // index into host_config.scenes
	elapsed:  f32,
	mesh:     gfx.Mesh,
	vertices: [dynamic]gfx.VertexData,
	draw:     bool,
}

transition: Transition

// Call before stats_create so the overlay draws under the stats panel.
transition_create :: proc(gfx_ctx: ^gfx.Device) {
	dummy := [6]gfx.VertexData{}
	transition.mesh = gfx.mesh_create_unindexed(gfx_ctx, dummy[:])
	gfx.mesh_upload(&gfx_ctx.renderer, &transition.mesh)
	gfx.renderer_add_pass(&gfx_ctx.renderer, .After_Post, {name = "transition", run = transition_draw})
}

// Passes are cleared by stats_destroy.
transition_destroy :: proc(gfx_ctx: ^gfx.Device) {
	gfx.mesh_destroy(gfx_ctx, &transition.mesh)
}

// Runs at the top of a tick. Returns true when it swapped the scene (the caller
// must skip ticking the old one).
transition_tick :: proc(ctx: ^Context, scene: ^Scene, delta_time: f32) -> bool {
	gfx_ctx := &ctx.gfx
	transition.draw = false
	if transition.phase == .None {
		request, ok := take_scene_request()
		if !ok do return false
		index := -1
		for entry, i in host_config.scenes do if entry.name == request.name do index = i
		if index < 0 {
			log.errorf("change_scene: unknown scene %q", request.name)
			return false
		}
		if index == current_scene do return false
		if request.transition == .Cut {
			host_scene_switch(ctx, scene, index)
			return true
		}
		if request.transition == .Flash || request.transition == .Blink {
			// Swap now; only the overlay lingers. The In phase lasts duration/2.
			host_scene_switch(ctx, scene, index)
			request.duration = 0.5 if request.transition == .Flash else 0.2
			transition.request, transition.target, transition.elapsed, transition.phase = request, index, 0, .In
			transition_build(gfx_ctx, 0)
			return true
		}
		transition.request, transition.target, transition.elapsed, transition.phase = request, index, 0, .Out
	}

	half := transition.request.duration / 2
	// Loading a scene can take long; clamp so the fade-in does not skip.
	transition.elapsed += delta_time if transition.phase == .Out else min(delta_time, 1.0 / 30)
	progress := min(transition.elapsed / half, 1)
	swapped := false
	if transition.phase == .Out && progress >= 1 {
		host_scene_switch(ctx, scene, transition.target)
		transition.phase, transition.elapsed, progress, swapped = .In, 0, 0, true
	} else if transition.phase == .In && progress >= 1 {
		transition.phase = .None
		return false
	}
	transition_build(gfx_ctx, progress)
	return swapped
}

transition_quad :: proc(x0, x1, y0, y1: f32, color: [4]f32) {
	uv := [2]f32{gfx.FONT_WHITE_U, gfx.FONT_WHITE_V}
	p0, p1, p2, p3 := [3]f32{x0, y1, 0}, [3]f32{x1, y1, 0}, [3]f32{x1, y0, 0}, [3]f32{x0, y0, 0}
	append(&transition.vertices, gfx.VertexData{position = p0, color = color, uv = uv}, {position = p1, color = color, uv = uv}, {position = p2, color = color, uv = uv}, {position = p0, color = color, uv = uv}, {position = p2, color = color, uv = uv}, {position = p3, color = color, uv = uv})
}

// Triangle fan of `sides` points around the centre, radius r in NDC (x scaled by aspect).
transition_polygon :: proc(sides: int, r, aspect, rotation: f32, color: [4]f32) {
	uv := [2]f32{gfx.FONT_WHITE_U, gfx.FONT_WHITE_V}
	point :: proc(i, sides: int, r, aspect, rotation: f32) -> [3]f32 {
		a := rotation + f32(i) / f32(sides) * 2 * math.PI
		return {math.cos(a) * r / aspect, math.sin(a) * r, 0}
	}
	for i in 0 ..< sides {
		append(&transition.vertices,
			gfx.VertexData{position = {0, 0, 0}, color = color, uv = uv},
			gfx.VertexData{position = point(i, sides, r, aspect, rotation), color = color, uv = uv},
			gfx.VertexData{position = point(i + 1, sides, r, aspect, rotation), color = color, uv = uv})
	}
}

transition_build :: proc(gfx_ctx: ^gfx.Device, progress: f32) {
	out := transition.phase == .Out
	// cover: 0 = nothing, 1 = whole screen, in both phases.
	cover := progress if out else 1 - progress
	color := [4]f32{0, 0, 0, 1}
	aspect := f32(gfx_ctx.window_size.x) / f32(gfx_ctx.window_size.y)
	clear(&transition.vertices)
	switch transition.request.transition {
	case .Cut:
	case .Flash:
		transition_quad(-1, 1, -1, 1, {1, 1, 1, 1 - progress})
	case .Blink:
		transition_quad(-1, 1, -1, 1, {0, 0, 0, 1})
	case .Fade:
		transition_quad(-1, 1, -1, 1, {0, 0, 0, cover})
	case .Fade_White:
		transition_quad(-1, 1, -1, 1, {1, 1, 1, cover})
	case .Wipe: // leading edge sweeps right while covering, trailing edge sweeps right while uncovering
		if out do transition_quad(-1, -1 + 2 * progress, -1, 1, color)
		else do transition_quad(-1 + 2 * progress, 1, -1, 1, color)
	case .Wipe_Left:
		if out do transition_quad(1 - 2 * progress, 1, -1, 1, color)
		else do transition_quad(-1, 1 - 2 * progress, -1, 1, color)
	case .Wipe_Up:
		if out do transition_quad(-1, 1, -1, -1 + 2 * progress, color)
		else do transition_quad(-1, 1, -1 + 2 * progress, 1, color)
	case .Slide: // panel as wide as the screen moves across: edge at progress
		if out do transition_quad(-1, -1 + 2 * progress, -1, 1, color)
		else do transition_quad(-1 + 2 * progress, 1, -1, 1, color)
		// thin accent edge so the leading side reads as a shape
		edge := -1 + 2 * progress
		transition_quad(edge - 0.02, edge, -1, 1, {0.9, 0.7, 0.2, 1})
	case .Diamond: // radius that reaches the corners at cover = 1
		transition_polygon(4, (1 + aspect) * cover * 1.05, aspect, 0, color)
	case .Circle:
		transition_polygon(48, math.sqrt(1 + aspect * aspect) * cover * 1.02, aspect, 0, color)
	case .Blinds:
		for i in 0 ..< 8 {
			y0 := -1 + f32(i) * 0.25
			transition_quad(-1, 1, y0, y0 + 0.25 * min(cover * 1.05, 1), color)
		}
	}
	if len(transition.vertices) == 0 {
		transition.draw = false
		return
	}
	gfx.mesh_update_unindexed(&gfx_ctx.renderer, &transition.mesh, transition.vertices[:])
	transition.draw = true
}

transition_draw :: proc(ctx: ^gfx.Pass_Ctx, _: rawptr) {
	if !transition.draw do return
	gfx_ctx := ctx.gfx_ctx
	gfx.renderer_begin_overlay_pass(ctx.renderer, ctx.color)
	pass := ctx.renderer.pass
	target := 0 if ctx.color == ctx.renderer.scene_color else 1 // pipeline format must match the target
	pipeline := gfx.pipeline_get(gfx_ctx, stats.pipelines[target])
	sdl.BindGPUGraphicsPipeline(pass, pipeline.handle)
	gfx.pipeline_bind_material(gfx_ctx, pass, gfx_ctx.command_buffer, &stats.materials[target])
	gfx.pipeline_bind_draw(
		gfx_ctx,
		stats.pipelines[target],
		gfx_ctx.command_buffer,
		{
			view_projection = linalg.MATRIX4F32_IDENTITY,
			model_transform = linalg.MATRIX4F32_IDENTITY,
			material = &stats.materials[target],
		},
	)
	vertex_buffer := gfx.buffer_get(gfx_ctx, transition.mesh.vertex_buffer)
	sdl.BindGPUVertexBuffers(pass, 0, &(sdl.GPUBufferBinding{buffer = vertex_buffer.handle}), 1)
	sdl.DrawGPUPrimitives(pass, u32(len(transition.vertices)), 1, 0, 0)
	gfx.renderer_end_pass(ctx.renderer)
}
