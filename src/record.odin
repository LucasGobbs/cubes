// Recording mode, `./main <scene> --WINDOWED --record ex,ey,ez,tx,ty,tz[,fly]` or `--record path.json`. Pose form: after a short
// settle time the camera is placed at eye e looking at target t and arcs around t for RECORD_SECONDS with eased motion
// (with the 7th field `fly` it travels in a straight line from e through t instead) (smooth fly camera on), then the run
// quits. Path form: the camera holds the first key during the settle, follows the keyframed path file (camera_path_io.odin;
// made with J/K in the fly camera) for its length, then holds the last key. Meant for screen capture (scripts/record.sh);
// the pose is given per recording because every step of the series frames its content differently. Prints
// RECORD_START/RECORD_END with unix timestamps so the capture can be trimmed.
package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strconv"
import "core:strings"
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
	use_path:       bool, // true = follow path (keyframes from a .json file) instead of the pose
	path:           gfx.Camera_Path,
	fly:            bool, // false = arc around target; true = straight travelling from eye through target
	eye, target:    gfx.Vec3, // start pose; the arc is around target
	total:          f64,
	started, ended: bool,
	start_offset:   gfx.Vec3, // camera position relative to the pivot
}

record: Record_Run

// Parses the --record argument (pose or path file). Returns false after logging an error.
record_set_from_arg :: proc(arg: string) -> bool {
	if strings.has_suffix(arg, ".json") {
		path, ok := engine.camera_path_load(arg)
		if !ok do return false
		record.use_path, record.path = true, path
		return true
	}
	parts: [6]f32
	fields := strings.split(arg, ",", context.temp_allocator)
	ok := len(fields) == 6 || (len(fields) == 7 && fields[6] == "fly")
	record.fly = len(fields) == 7
	for f, k in fields[:min(len(fields), 6)] do if ok && k < 6 do parts[k], ok = strconv.parse_f32(f)
	if !ok do return false
	record.eye, record.target = {parts[0], parts[1], parts[2]}, {parts[3], parts[4], parts[5]}
	return true
}

// Motion length in seconds: the last key time for a path, else RECORD_SECONDS.
record_seconds :: proc() -> f64 {
	if record.use_path do return f64(record.path.keys[len(record.path.keys) - 1].time)
	return RECORD_SECONDS
}

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
	camera := gfx.camera(&ctx.gfx)
	if record.use_path {
		position, target := gfx.camera_path_sample(record.path, f32(max(record.total - RECORD_SETTLE, 0)))
		gfx.camera_look_at_pose(camera, position, target)
	}
	if record.total < RECORD_SETTLE do return
	if !record.started {
		record.started = true
		record.start_offset = record.eye - record.target
		if fly, ok := &ctx.camera.(engine.Camera_Fly); ok do fly.fly.smooth = true // smooth fly configuration
		fmt.printfln("RECORD_START %.3f", unix_seconds())
	}
	seconds := record_seconds()
	if !record.use_path {
		u := smootherstep(clamp(f32((record.total - RECORD_SETTLE) / seconds), 0, 1))
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
	}
	if !record.ended && record.total >= RECORD_SETTLE + seconds {
		record.ended = true
		fmt.printfln("RECORD_END %.3f", unix_seconds())
	}
	// Render-video ends by its frame count (video.total, set from the path length in main); quit only for live capture.
	if video.path == "" && record.total >= RECORD_SETTLE + seconds + RECORD_TAIL do engine.request_quit(ctx)
}

// Combined hook: benchmark stats and recording.
frame_hook :: proc(ctx: ^engine.Context, scene_name: string, dt: f32, user: rawptr) {
	bench_after_frame(ctx, scene_name, dt, user)
	record_after_frame(ctx, dt)
	video_after_frame(ctx)
}
