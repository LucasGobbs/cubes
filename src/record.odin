// Recording mode, `./main <scene> --WINDOWED --record ex,ey,ez,tx,ty,tz[,fly]`: after a short settle time the camera is
// placed at eye e looking at target t and arcs around t for RECORD_SECONDS with eased motion (with the 7th field `fly` it travels in a straight line from e through t instead) (smooth fly camera
// on), then the run quits. Meant for screen capture (scripts/record.sh); the pose is given per recording because
// every step of the series frames its content differently. Prints RECORD_START/RECORD_END with unix timestamps
// so the capture can be trimmed.
package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:time"
import engine "engine"
import gfx "engine/gfx"

RECORD_SETTLE :: 3.0 // s before the motion: loading, shader warm-up, first compute passes
RECORD_SECONDS :: 10.0
RECORD_TAIL :: 1.0 // s kept after the motion so the capture end is not cut
RECORD_ARC :: 50 * math.RAD_PER_DEG // total yaw swept around the pivot
RECORD_DOLLY :: 0.25 // fraction of the pivot distance travelled toward it

Record_Run :: struct {
	on:             bool,
	fly:            bool, // false = arc around target; true = straight travelling from eye through target
	eye, target:    gfx.Vec3, // start pose; the arc is around target
	total:          f64,
	started, ended: bool,
	start_offset:   gfx.Vec3, // camera position relative to the pivot
}

record: Record_Run

unix_seconds :: proc() -> f64 {
	return f64(time.to_unix_nanoseconds(time.now())) / 1e9
}

smootherstep :: proc(u: f32) -> f32 {
	return u * u * u * (u * (u * 6 - 15) + 10)
}

// Config.after_frame hook for recording; the camera pose is absolute, so engine fly input cannot drift it.
record_after_frame :: proc(ctx: ^engine.Context, dt: f32) {
	if !record.on || dt <= 0 do return
	record.total += f64(dt)
	if record.total < RECORD_SETTLE do return
	camera := gfx.camera(&ctx.gfx)
	if !record.started {
		record.started = true
		record.start_offset = record.eye - record.target
		if fly, ok := &ctx.camera.(engine.Camera_Fly); ok do fly.fly.smooth = true // smooth fly configuration
		fmt.printfln("RECORD_START %.3f", unix_seconds())
	}
	u := smootherstep(clamp(f32((record.total - RECORD_SETTLE) / RECORD_SECONDS), 0, 1))
	if record.fly {
		// Travelling: the camera flies in a straight line from eye to target (eased), looking along that line at a
		// point as far beyond the target as the target is from the eye, so the view direction stays steady.
		path := record.target - record.eye
		camera.position = record.eye + path * u
		look := linalg.normalize(record.target + path - camera.position)
		gfx.camera_set_angles(camera, math.atan2(look.z, look.x), math.asin(look.y))
	} else {
		// Rotate the start offset about the vertical axis through the target and move it toward the target.
		angle := RECORD_ARC * u
		c, s := math.cos(angle), math.sin(angle)
		o := record.start_offset
		offset := gfx.Vec3{o.x * c - o.z * s, o.y, o.x * s + o.z * c} * (1 - RECORD_DOLLY * u)
		camera.position = record.target + offset
		look := linalg.normalize(record.target - camera.position)
		gfx.camera_set_angles(camera, math.atan2(look.z, look.x), math.asin(look.y))
	}
	if !record.ended && record.total >= RECORD_SETTLE + RECORD_SECONDS {
		record.ended = true
		fmt.printfln("RECORD_END %.3f", unix_seconds())
	}
	if record.total >= RECORD_SETTLE + RECORD_SECONDS + RECORD_TAIL do engine.request_quit(ctx)
}

// Combined hook: benchmark stats and recording.
frame_hook :: proc(ctx: ^engine.Context, scene_name: string, dt: f32, user: rawptr) {
	bench_after_frame(ctx, scene_name, dt, user)
	record_after_frame(ctx, dt)
	video_after_frame(ctx)
}
