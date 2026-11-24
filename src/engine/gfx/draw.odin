// Draw submission has two APIs; pick by who owns the list.
//  - Value API (engine.World, custom loops): you own a []Draw and pass it to
//    renderer_render_draws each frame. Build with draw_make; set Draw fields directly.
//  - Device-list API (demo scenes): draw_create appends to dev.draws and returns an
//    index; draw_move updates it; render(dev) draws the list. Entries live until scope_end.
// Do not mix the two for the same object.
package gfx

import "core:math/linalg"
import "../jobs"
import loader "loader"

// A Draw is one renderable object: mesh + material + transform, submitted
// every frame. Plain value; it borrows its assets, which must outlive it.
Draw :: struct {
	mesh:      ^Mesh,
	material:  ^Material,
	transform: matrix[4, 4]f32,
	layer:     Render_Layer,
	// Frustum and view-distance culling. Screen-space layers have no world position.
	cull:      bool,
	// Skipped on submit (use instead of a zero scale).
	hidden:    bool,
	// Skinned only: borrowed from a Playback.
	pose:      ^Pose,
}

transform_trs :: proc(
	position: Vec3,
	rotation: linalg.Quaternionf32 = linalg.QUATERNIONF32_IDENTITY,
	scale := Vec3{1, 1, 1},
) -> matrix[4, 4]f32 {
	return linalg.matrix4_translate_f32(position) *
		linalg.matrix4_from_quaternion(rotation) *
		linalg.matrix4_scale_f32(scale)
}

draw_make :: proc(
	mesh: ^Mesh,
	material: ^Material,
	position := Vec3{},
	rotation := linalg.QUATERNIONF32_IDENTITY,
	scale := Vec3{1, 1, 1},
	layer := Render_Layer.WORLD,
) -> Draw {
	assert(mesh != nil && material != nil)
	return Draw {
		mesh = mesh,
		material = material,
		transform = transform_trs(position, rotation, scale),
		layer = layer,
		cull = layer == .WORLD || layer == .TRANSPARENT,
	}
}

draw_move :: proc(dev: ^Device, index: int, position: Vec3, rotation: linalg.Quaternionf32, scale: Vec3) {
	dev.draws[index].transform = transform_trs(position, rotation, scale)
}


// Clip playback for a skinned Draw. The pose is heap-allocated so Draw.pose
// stays valid when the owner moves the Playback.
Playback :: struct {
	skin: ^loader.Skin, // borrowed
	clip: int, // -1 = rest pose
	time: f32,
	pose: ^Pose, // owned
}

playback_create :: proc(skin: ^loader.Skin) -> Playback {
	assert(skin != nil)
	playback := Playback{skin = skin, clip = -1, pose = new(Pose)}
	if len(skin.clips) > 0 do playback.clip = 0
	clip_sample(skin, playback.clip, 0, playback.pose)
	return playback
}

// Switches to the named clip, restarting it. Returns false and keeps the
// current clip when the skin has no clip with that name.
playback_play :: proc(p: ^Playback, name: string) -> bool {
	index, found := clip_find(p.skin, name)
	if !found do return false
	if index != p.clip {
		p.clip = index
		p.time = 0
	}
	return true
}

playback_tick :: proc(p: ^Playback, dt: f32) {
	p.time += dt
	clip_sample(p.skin, p.clip, p.time, p.pose)
}

playback_destroy :: proc(p: ^Playback) {
	if p.pose != nil do free(p.pose)
	p^ = {}
}

// Pure visibility test, safe on worker threads. Skipped when hidden; culled by frustum and view
// distance when d.cull. A draw the camera culls still counts as a shadow-only caster when it
// lies inside the sun box.
draw_visibility :: proc(view: ^Extract_View, eye: Vec3, d: ^Draw) -> (visible, shadow_only: bool) {
	if d.hidden do return
	if d.cull && renderable_culled(&view.planes, d.mesh, d.transform) {
		if !view.shadows || d.layer != .WORLD || renderable_culled(&view.light_planes, d.mesh, d.transform) do return
		return true, true
	}
	if d.cull && view.view_distance > 0 && renderable_beyond(eye, d.mesh, d.transform, view.view_distance) do return
	return true, false
}

renderer_submit_draw :: proc(renderer: ^Renderer, view: ^Extract_View, d: ^Draw) {
	visible, shadow_only := draw_visibility(view, renderer.camera.position, d)
	if visible do renderer_submit(renderer, d.mesh, d.material, d.transform, d.layer, d.pose, shadow_only)
}

// Below this many draws the serial loop beats the job round trip.
// shortcut: threshold is a guess; raise it to the measured break-even (see phase 3 bench).
PARALLEL_CULL_MIN :: 512

@(private = "file")
Cull_Range :: struct {
	last:    int, // zero = no range starts at this index
	visible: int,
}

@(private = "file")
Cull_Job :: struct {
	view:     ^Extract_View,
	eye:      Vec3,
	draws:    []Draw, // direct
	ptrs:     []^Draw, // indirect (indirect = true)
	indirect: bool,
	items:    []DrawItem, // range [first, last) writes its visible items from items[first]
	ranges:   []Cull_Range, // indexed by a range's first draw
}

@(private = "file")
cull_draw :: proc(job: ^Cull_Job, i: int) -> ^Draw {
	return job.ptrs[i] if job.indirect else &job.draws[i]
}

@(private = "file")
cull_range :: proc(data: rawptr, first, last: int) {
	job := (^Cull_Job)(data)
	n := first
	for i in first ..< last {
		d := cull_draw(job, i)
		visible, shadow_only := draw_visibility(job.view, job.eye, d)
		if !visible do continue
		job.items[n] = DrawItem{mesh = d.mesh, material = d.material, transform = d.transform, layer = d.layer, pose = d.pose, shadow_only = shadow_only}
		n += 1
	}
	job.ranges[first] = {last, n - first}
}

// Culls on the job pool when set and the list is large; items land in list order either way.
@(private = "file")
submit_culled :: proc(renderer: ^Renderer, view: ^Extract_View, job: ^Cull_Job) {
	count := len(job.ptrs) if job.indirect else len(job.draws)
	if renderer.jobs == nil || count < PARALLEL_CULL_MIN {
		for i in 0 ..< count do renderer_submit_draw(renderer, view, cull_draw(job, i))
		return
	}
	assert(renderer.pass == nil)
	job.view, job.eye = view, renderer.camera.position
	// Workers write straight into spare draw_items capacity; the visible prefixes are then packed down.
	base := len(renderer.draw_items)
	resize(&renderer.draw_items, base + count)
	job.items = renderer.draw_items[base:]
	job.ranges = make([]Cull_Range, count, context.temp_allocator)
	jobs.parallel_for(renderer.jobs, count, job, cull_range, 128)
	write := 0
	for i := 0; i < count; {
		r := job.ranges[i]
		if write != i do copy(job.items[write:], job.items[i:i + r.visible])
		write += r.visible
		i = r.last
	}
	resize(&renderer.draw_items, base + write)
}

renderer_submit_draws :: proc(renderer: ^Renderer, view: ^Extract_View, draws: []Draw) {
	job := Cull_Job{draws = draws}
	submit_culled(renderer, view, &job)
}

renderer_submit_draw_ptrs :: proc(renderer: ^Renderer, view: ^Extract_View, draws: []^Draw) {
	job := Cull_Job{ptrs = draws, indirect = true}
	submit_culled(renderer, view, &job)
}

renderer_extract_draws :: proc(renderer: ^Renderer, draws: []Draw) {
	view := renderer_begin_extract(renderer)
	renderer_submit_draws(renderer, &view, draws)
}

renderer_render_draws :: proc(renderer: ^Renderer, draws: []Draw) {
	assert(renderer.gfx_ctx.frame_open)
	if renderer.gfx_ctx.swapchain == nil do return
	renderer_extract_draws(renderer, draws)
	renderer_draw_submitted(renderer)
}

// Adds a Draw to gfx_ctx.draws and returns its index. Scope-owned: truncated at scope_end.
// Mesh_Data is uploaded into a scope-owned Mesh.
Mesh_Data :: struct {
	vertices: []VertexData,
	indices:  []u32, // empty = unindexed
}

Draw_Mesh :: union {
	Mesh_Data,
	^Mesh,
	^Model,
}

Draw_Desc :: struct {
	mesh:     Draw_Mesh,
	material: ^Material, // ^Model: defaults to the model's material
	position: Vec3,
	rotation: linalg.Quaternionf32, // zero = idactor
	scale:    Vec3, // zero = {1, 1, 1}
	layer:    Render_Layer, // zero = WORLD
}

draw_create :: proc(gfx_ctx: ^Device, desc: Draw_Desc) -> int {
	mesh: ^Mesh
	material := desc.material
	switch m in desc.mesh {
	case Mesh_Data:
		owned := new(Mesh)
		if len(m.indices) == 0 {
			owned^ = mesh_create_unindexed(gfx_ctx, m.vertices)
		} else {
			owned^ = mesh_create(gfx_ctx, m.vertices, m.indices)
		}
		scope_defer(gfx_ctx, mesh_release, owned)
		mesh = owned
	case ^Mesh:
		mesh = m
	case ^Model:
		mesh = &m.mesh
		if material == nil do material = &m.material
	}
	rotation := desc.rotation
	if rotation == {} do rotation = linalg.QUATERNIONF32_IDENTITY
	scale := desc.scale
	if scale == {} do scale = {1, 1, 1}
	layer := desc.layer
	if layer == Render_Layer(0) do layer = .WORLD
	append(&gfx_ctx.draws, draw_make(mesh, material, desc.position, rotation, scale, layer))
	return len(gfx_ctx.draws) - 1
}

@(private = "file")
mesh_release :: proc(gfx_ctx: ^Device, user: rawptr) {
	mesh := (^Mesh)(user)
	mesh_destroy(gfx_ctx, mesh)
	free(mesh)
}

// Simple frame: gfx_ctx.draws -> offscreen -> post passes -> blit to screen.
render :: proc(gfx_ctx: ^Device) {
	renderer_render_frame(&gfx_ctx.renderer, draws_extract_proc, gfx_ctx)
}

@(private = "file")
draws_extract_proc :: proc(renderer: ^Renderer, user: rawptr) {
	gfx_ctx := (^Device)(user)
	renderer_extract_draws(renderer, gfx_ctx.draws[scope_draw_base(gfx_ctx):])
}
