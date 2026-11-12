package gfx

import "core:math/linalg"
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

draw_model :: proc(
	model: ^Model,
	position := Vec3{},
	scale := Vec3{1, 1, 1},
	rotation := linalg.QUATERNIONF32_IDENTITY,
	layer := Render_Layer.WORLD,
) -> Draw {
	assert(model != nil)
	return draw_make(&model.mesh, &model.material, position, rotation, scale, layer)
}

draw_set_transform :: proc(d: ^Draw, position: Vec3, rotation: linalg.Quaternionf32, scale: Vec3) {
	d.transform = transform_trs(position, rotation, scale)
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

// Skipped when hidden; culled by frustum and view distance when d.cull.
renderer_submit_draw :: proc(renderer: ^Renderer, view: ^Extract_View, d: ^Draw) {
	if d.hidden do return
	if d.cull && renderable_culled(&view.planes, d.mesh, d.transform) do return
	if d.cull && view.view_distance > 0 && renderable_beyond(renderer.camera.position, d.mesh, d.transform, view.view_distance) do return
	renderer_submit(renderer, d.mesh, d.material, d.transform, d.layer, d.pose)
}

renderer_extract_draws :: proc(renderer: ^Renderer, draws: []Draw) {
	view := renderer_begin_extract(renderer)
	for &d in draws do renderer_submit_draw(renderer, &view, &d)
}

renderer_render_draws :: proc(renderer: ^Renderer, draws: []Draw) {
	assert(renderer.gfx_ctx.frame_open)
	if renderer.gfx_ctx.swapchain == nil do return
	renderer_extract_draws(renderer, draws)
	renderer_draw_submitted(renderer)
}

// Simple frame: draws -> offscreen -> post passes -> blit to screen.
render :: proc(gfx_ctx: ^Device, draws: []Draw) {
	frame := Draw_Frame{draws}
	renderer_render_frame(&gfx_ctx.renderer, draws_extract_proc, &frame)
}

@(private = "file")
Draw_Frame :: struct {
	draws: []Draw,
}

@(private = "file")
draws_extract_proc :: proc(renderer: ^Renderer, user: rawptr) {
	renderer_extract_draws(renderer, (^Draw_Frame)(user).draws)
}
