package engine

import "gfx"
import "input"

// Orbit tuning: radians per drag pixel, distance factor per wheel notch, distance range.
ORBIT_DRAG_RATE :: 0.005
ORBIT_ZOOM_PER_NOTCH :: 0.1
ORBIT_MIN_DISTANCE :: 0.5
ORBIT_MAX_DISTANCE :: 1000

// Host-driven camera, updated every frame before Scene.tick. nil = scene drives the camera itself.
Camera_Fly :: struct {
	fly:  gfx.Fly_Camera,
	look: bool, // mouse look on; see camera_mouse_look
}

Camera_Orbit :: struct {
	orbit: gfx.Orbit_Camera,
}

Camera_Controller :: union {
	Camera_Fly,
	Camera_Orbit,
}

// Registers the fly key actions once per scene; the host rewinds them on scene switch.
@(private) camera_ensure_keys :: proc(ctx: ^Context) {
	if ctx.camera_keys == nil do ctx.camera_keys = fly_controls_create(&ctx.input, "camera")
}

// WASD fly camera. nil position/look_at keep the view the host already applied (the
// scene's JSON camera, or the default); given values reset the view. speed 0 = default;
// fov_y 0 = default lens. Full-window targets are reset either way, so call from scene create.
camera_fly :: proc(
	ctx: ^Context,
	position: Maybe(gfx.Vec3) = nil,
	look_at: Maybe(gfx.Vec3) = nil,
	speed := f32(0),
	fov_y := f32(0),
) {
	if position != nil || look_at != nil {
		eye := gfx.Vec3{0, 0, 3}
		if p, ok := position.?; ok do eye = p
		target: gfx.Vec3
		if t, ok := look_at.?; ok do target = t
		gfx.camera_reset(&ctx.gfx, eye, target)
	} else {
		gfx.renderer_resize_targets(&ctx.gfx.renderer, u32(ctx.gfx.window_size.x), u32(ctx.gfx.window_size.y))
	}
	fly := Camera_Fly{fly = gfx.fly_camera_create(), look = true}
	if speed > 0 do fly.fly.speed = speed
	ctx.camera = fly
	camera_ensure_keys(ctx)
	if fov_y > 0 do camera_perspective(ctx, fov_y)
}

// Gates mouse look for the fly camera (editor passes whether the pointer is over the viewport).
// No-op for other camera kinds.
camera_mouse_look :: proc(ctx: ^Context, enabled: bool) {
	if fly, ok := &ctx.camera.(Camera_Fly); ok do fly.look = enabled
}

// Right-drag orbit around target at distance; wheel zooms. Resets like camera_fly.
camera_orbit :: proc(ctx: ^Context, target := gfx.Vec3{}, distance := f32(5)) {
	gfx.camera_reset(&ctx.gfx, target + gfx.Vec3{0, 0, distance}, target)
	cam := gfx.camera(&ctx.gfx)
	ctx.camera = Camera_Orbit {
		orbit = {
			target       = target,
			distance     = distance,
			min_distance = ORBIT_MIN_DISTANCE,
			max_distance = ORBIT_MAX_DISTANCE,
			yaw          = cam.yaw,
			pitch        = cam.pitch,
		},
	}
}

// Lens setting for the current camera; call after camera_fly/camera_orbit (they reset the lens).
camera_perspective :: proc(ctx: ^Context, fov_y := f32(gfx.CAMERA_FOV_Y), near := f32(gfx.CAMERA_NEAR), far := f32(0)) {
	lens := gfx.Perspective{fov_y = fov_y, near = near, far = far}
	gfx.camera_set_projection(gfx.camera(&ctx.gfx), lens, gfx.aspect_ratio(&ctx.gfx))
}

// height = full view height in world units.
camera_orthographic :: proc(ctx: ^Context, height, near, far: f32) {
	lens := gfx.Orthographic{size = height / 2, near = near, far = far}
	gfx.camera_set_projection(gfx.camera(&ctx.gfx), lens, gfx.aspect_ratio(&ctx.gfx))
}

@(private) camera_update :: proc(ctx: ^Context, dt: f32) {
	switch &c in ctx.camera {
	case nil:
	case Camera_Fly:
		keys, _ := ctx.camera_keys.?
		fly := fly_controls_read(&ctx.input, &keys, c.look)
		gfx.fly_camera_update(gfx.camera(&ctx.gfx), &c.fly, fly, dt)
	case Camera_Orbit:
		if dt <= 0 do return
		drag: [2]f32
		if input.mouse_down(&ctx.input, .Left) do drag = input.mouse_delta(&ctx.input) * ORBIT_DRAG_RATE
		zoom := input.mouse_wheel(&ctx.input).y * ORBIT_ZOOM_PER_NOTCH
		// orbit_camera_update takes rates; the per-frame amounts above become rates here.
		gfx.orbit_camera_update(gfx.camera(&ctx.gfx), &c.orbit, drag / dt, zoom / dt, dt)
	}
}
