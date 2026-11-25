// Auto-orbit for screen recording: a slow helicopter circle around the city centre, looking at a point over it. The
// fly camera keeps running underneath (the host updates it before the scene tick); while the orbit is on, the scene
// overwrites its pose each tick and zeroes its velocity, so WASD and the mouse do nothing. Toggling off keeps the pose.
package city

import engine "../../engine"
import gfx "../../engine/gfx"
import input "../../engine/input"
import "core:math"
import "core:math/linalg"

ORBIT_CENTRE :: [3]f32{1536, 0, 1024}
ORBIT_RADIUS :: 2000
ORBIT_HEIGHT :: 520
ORBIT_TARGET :: [3]f32{1536, 40, 1024}
ORBIT_SPEED :: 0.05 // rad/s: one lap in about 2 minutes
ORBIT_BLEND_TIME :: 1 // s to ease from the fly pose onto the orbit path
CITY_ORBIT_START :: false // orbit on at start; O toggles

City_Orbit :: struct {
	on:    bool,
	angle: f32, // radians around ORBIT_CENTRE, in the xz plane
	blend: f32, // seconds since the orbit turned on, capped at ORBIT_BLEND_TIME
	from:  gfx.Vec3, // camera position when the orbit turned on
}

orbit_point :: proc(angle: f32) -> gfx.Vec3 {
	return {
		ORBIT_CENTRE.x + ORBIT_RADIUS * math.cos(angle),
		ORBIT_HEIGHT,
		ORBIT_CENTRE.z + ORBIT_RADIUS * math.sin(angle),
	}
}

// Turning on starts at the angle nearest the current camera, so there is no jump; off keeps the current pose.
orbit_set :: proc(orbit: ^City_Orbit, ctx: ^engine.Context, on: bool) {
	if on && !orbit.on {
		cam := gfx.camera(&ctx.gfx)
		offset := cam.position.xz - ORBIT_CENTRE.xz
		orbit.angle = math.atan2(offset.y, offset.x)
		orbit.blend = 0
		orbit.from = cam.position
	}
	orbit.on = on
}

orbit_update :: proc(orbit: ^City_Orbit, ctx: ^engine.Context, dt: f32) {
	if !orbit.on do return
	if fly, ok := &ctx.camera.(engine.Camera_Fly); ok {
		fly.fly.velocity = {}
		fly.fly.look_velocity = {}
	}
	orbit.angle += ORBIT_SPEED * dt
	orbit.blend = min(orbit.blend + dt, ORBIT_BLEND_TIME)
	t := orbit.blend / ORBIT_BLEND_TIME
	s := t * t * (3 - 2 * t) // smoothstep: zero speed at both ends of the blend

	cam := gfx.camera(&ctx.gfx)
	target := orbit_point(orbit.angle)
	cam.position = orbit.from + (target - orbit.from) * s
	dir := linalg.normalize(ORBIT_TARGET - cam.position)
	gfx.camera_set_angles(cam, math.atan2(dir.z, dir.x), math.asin(dir.y))
}
