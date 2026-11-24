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
import "jobs"

Transition_Phase :: enum {
	None,
	Out, // covering the old scene
	In, // uncovering the new one
}

Transition :: struct {
	phase:    Transition_Phase,
	request:  Scene_Request,
	target:   int, // index into host_config.scenes
	kind:     Scene_Request_Kind,
	policy:   Stack_Policy, // Push only
	pending:  Scene, // looked up on the main thread; used when it has no load hook
	lc:       ^Load_Context, // set when the target has a load hook: pending lives in lc.scene
	waiting:  bool, // covered and waiting for lc this tick: the overlay shows the loading screen
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
	gfx.renderer_add_pass(&gfx_ctx.renderer, .After_Post, {name = "transition", run = transition_draw})
}

// Passes are cleared by stats_destroy.
transition_destroy :: proc(gfx_ctx: ^gfx.Device) {
	gfx.mesh_destroy(gfx_ctx, &transition.mesh)
}

// Runs at the top of a tick. Returns true when it swapped the scene or showed the loading
// screen (the caller must skip ticking the old one).
transition_tick :: proc(ctx: ^Context, scene: ^Scene, delta_time: f32) -> bool {
	gfx_ctx := &ctx.gfx
	transition.draw = false
	transition.waiting = false
	if transition.phase == .None {
		request, ok := take_scene_request()
		if !ok do return false
		if !transition_begin(ctx, request) do return false
		if request.transition == .Cut {
			// shortcut: Cut/Flash/Blink have no cover to hide a load behind, so they block until it finishes.
			transition_commit(ctx, scene)
			return true
		}
		if request.transition == .Flash || request.transition == .Blink {
			// Swap now; only the overlay lingers. The In phase lasts duration/2.
			transition_commit(ctx, scene)
			request.duration = 0.5 if request.transition == .Flash else 0.2
			transition.request, transition.elapsed, transition.phase = request, 0, .In
			transition_build(gfx_ctx, 0)
			return true
		}
		transition.request, transition.elapsed, transition.phase = request, 0, .Out
	}

	half := transition.request.duration / 2
	// Loading a scene can take long; clamp so the fade-in does not skip.
	transition.elapsed += delta_time if transition.phase == .Out else min(delta_time, 1.0 / 30)
	progress := min(transition.elapsed / half, 1)
	swapped := false
	if transition.phase == .Out && progress >= 1 {
		if transition.lc != nil && !jobs.done(&transition.lc.group) {
			// Covered, load still running: the old scene stays un-ticked, a bare frame carries the overlay.
			transition.waiting = true
			transition_build(gfx_ctx, 1)
			gfx.renderer_render_frame(&gfx_ctx.renderer, transition_loading_extract, ctx)
			return true
		}
		if !transition_commit(ctx, scene) {
			transition.phase = .None
			return true
		}
		transition.phase, transition.elapsed, progress, swapped = .In, 0, 0, true
	} else if transition.phase == .In && progress >= 1 {
		transition.phase = .None
		return false
	}
	transition_build(gfx_ctx, progress)
	return swapped
}

// Resolves the request to a target scene and starts its load. False = nothing to do.
transition_begin :: proc(ctx: ^Context, request: Scene_Request) -> bool {
	index := -1
	switch request.kind {
	case .Change, .Push:
		for entry, i in host_config.scenes do if entry.name == request.name do index = i
		if index < 0 {
			log.errorf("%v scene: unknown scene %q", request.kind, request.name)
			return false
		}
		if request.kind == .Change && index == current_scene do return false
	case .Pop:
		if len(scene_stack) == 0 {
			log.infof("pop_scene: stack is empty")
			return false
		}
		index = scene_stack[len(scene_stack) - 1].index
	}
	transition.kind, transition.policy, transition.target = request.kind, request.policy, index
	transition.pending, transition.lc = {}, nil
	if request.kind == .Pop && scene_stack[len(scene_stack) - 1].policy == .Keep do return true // restored, not created

	name := host_config.scenes[index].name
	if lc := host_take_preload(name); lc != nil {
		transition.lc = lc
		return true
	}
	next, _ := scene_lookup(host_config.scenes, name)
	if next.load != nil do transition.lc = load_start(&ctx.jobs, next, name)
	else do transition.pending = next
	return true
}

// Swaps in the target (waiting for its load if it is still running). False = the load failed
// and the host is quitting.
transition_commit :: proc(ctx: ^Context, scene: ^Scene) -> bool {
	next := transition.pending
	if transition.lc != nil {
		name := transition.lc.name
		loaded, ok := load_finish(transition.lc)
		transition.lc = nil
		if !ok {
			log.errorf("scene %q failed to load", name)
			request_quit(ctx)
			return false
		}
		next = loaded
	}
	host_scene_swap(ctx, scene, transition.kind, transition.target, transition.policy, next)
	host_scene_shown(transition.target)
	return true
}

// Frame content while covered and loading: the host's loading_screen (or nothing; the default bar is in the overlay).
transition_loading_extract :: proc(_: ^gfx.Renderer, user: rawptr) {
	if host_config.loading_screen == nil || transition.lc == nil do return
	host_config.loading_screen((^Context)(user), load_fraction(transition.lc), host_config.user)
}

// Default loading screen: a centred bar over the covered screen.
transition_loading_bar :: proc(progress: f32) {
	half_width, half_height := f32(0.3), f32(0.015)
	transition_quad(-half_width - 0.005, half_width + 0.005, -half_height - 0.01, half_height + 0.01, {0.25, 0.25, 0.25, 1})
	transition_quad(-half_width, -half_width + 2 * half_width * progress, -half_height, half_height, {0.95, 0.95, 0.95, 1})
}

transition_quad :: proc(x0, x1, y0, y1: f32, color: [4]f32) {
	uv := [2]f32{gfx.FONT_WHITE_U, gfx.FONT_WHITE_V}
	p0, p1, p2, p3 := [3]f32{x0, y1, 0}, [3]f32{x1, y1, 0}, [3]f32{x1, y0, 0}, [3]f32{x0, y0, 0}
	append(&transition.vertices, gfx.VertexData{position = p0, color = color, uv = uv}, {position = p1, color = color, uv = uv}, {position = p2, color = color, uv = uv}, {position = p0, color = color, uv = uv}, {position = p2, color = color, uv = uv}, {position = p3, color = color, uv = uv})
}

// Triangle fan of `sides` points around (cx, cy) in NDC, radius r in NDC y units (x scaled by aspect).
transition_polygon :: proc(sides: int, r, aspect, rotation: f32, color: [4]f32, cx := f32(0), cy := f32(0)) {
	uv := [2]f32{gfx.FONT_WHITE_U, gfx.FONT_WHITE_V}
	point :: proc(i, sides: int, r, aspect, rotation, cx, cy: f32) -> [3]f32 {
		a := rotation + f32(i) / f32(sides) * 2 * math.PI
		return {cx + math.cos(a) * r / aspect, cy + math.sin(a) * r, 0}
	}
	for i in 0 ..< sides {
		append(&transition.vertices,
			gfx.VertexData{position = {cx, cy, 0}, color = color, uv = uv},
			gfx.VertexData{position = point(i, sides, r, aspect, rotation, cx, cy), color = color, uv = uv},
			gfx.VertexData{position = point(i + 1, sides, r, aspect, rotation, cx, cy), color = color, uv = uv})
	}
}

// Grid of shapes (discs or squares) that grow from each cell centre until the cells
// touch and cover the screen. stagger > 0 delays cells along the diagonal (wave).
transition_grid :: proc(cover, aspect, stagger: f32, disc: bool, color: [4]f32) {
	cols := 12
	rows := max(1, int(math.round(f32(cols) / aspect)))
	w, h := 2 / f32(cols), 2 / f32(rows)
	half_diag := math.sqrt(w * aspect * w * aspect + h * h) / 2 // in NDC y units
	for j in 0 ..< rows {
		for i in 0 ..< cols {
			cx, cy := -1 + (f32(i) + 0.5) * w, -1 + (f32(j) + 0.5) * h
			d := (f32(i) / f32(cols - 1) + f32(j) / f32(max(rows - 1, 1))) / 2
			if transition.phase == .In do d = 1 - d // wave keeps sweeping the same way while uncovering
			local := math.clamp(cover * (1 + stagger) - d * stagger, 0, 1)
			if local <= 0 do continue
			if disc {
				transition_polygon(20, half_diag * local * 1.02, aspect, 0, color, cx, cy)
			} else {
				hw, hh := w / 2 * min(local * 1.02, 1), h / 2 * min(local * 1.02, 1)
				transition_quad(cx - hw, cx + hw, cy - hh, cy + hh, color)
			}
		}
	}
}

transition_build :: proc(gfx_ctx: ^gfx.Device, progress: f32) {
	out := transition.phase == .Out
	// cover: 0 = nothing, 1 = whole screen, in both phases.
	eased := progress * progress * (3 - 2 * progress) // smoothstep: soft start and end instead of linear
	cover := eased if out else 1 - eased
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
	case .Dots:
		transition_grid(cover, aspect, 0, true, color)
	case .Dots_Wave:
		transition_grid(cover, aspect, 0.8, true, color)
	case .Squares:
		transition_grid(cover, aspect, 0.8, false, color)
	}
	if transition.waiting && host_config.loading_screen == nil && transition.lc != nil {
		transition_loading_bar(load_fraction(transition.lc))
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
	gfx.pipeline_bind_native(pass, pipeline, false) // overlay pass is always 1x
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
