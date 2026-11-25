// Offline video, `./main <scene> --render-video out.mp4 [--fps N] [--seconds S] [--video-size WxH]`: every frame
// advances the clock by exactly 1/fps, its readback (gfx.readback_frame, taken before the overlays) is piped as
// raw RGBA into ffmpeg after the warm-up frames, and the run ends after fps*seconds frames. Overlays are not in the video.
package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/posix"
import engine "engine"
import gfx "engine/gfx"

Video_Run :: struct {
	path:    string,
	fps:     int,
	seconds: f64,
	w, h:    int,
	total:   int, // frames to write = fps * seconds
	frames:  int,
	pipe:    ^posix.FILE, // ffmpeg stdin; nil when not rendering
	warmup:   int, // frames before the first written one (VIDEO_WARMUP)
	rendered: int, // frames rendered so far, warm-up included
}

// Frames simulated and rendered but not written: on frame 0 the scene's atlas and sky are not ready yet.
VIDEO_WARMUP :: 3

video: Video_Run = {fps = 60, seconds = 10, w = 1280, h = 720, warmup = VIDEO_WARMUP}

// Starts ffmpeg reading raw RGBA frames on stdin. The path goes in single quotes: names with ' are not supported.
video_begin :: proc() {
	cmd := fmt.tprintf(
		"ffmpeg -y -loglevel error -f rawvideo -pix_fmt rgba -s %dx%d -r %d -i - -c:v libx264 -crf 20 -pix_fmt yuv420p '%s'",
		video.w,
		video.h,
		video.fps,
		video.path,
	)
	video.pipe = posix.popen(strings.clone_to_cstring(cmd, context.temp_allocator), "w")
	if video.pipe == nil {
		log.errorf("video: cannot start ffmpeg")
		os.exit(1)
	}
}

// Config.after_frame path (via frame_hook): writes the frame just rendered and ends the run at the last one.
video_after_frame :: proc(ctx: ^engine.Context) {
	if video.pipe == nil do return
	pixels, w, h := gfx.readback_frame(&ctx.gfx, &ctx.gfx.renderer)
	if pixels == nil {
		log.errorf("video: frame %d was not rendered", video.rendered)
		os.exit(1)
	}
	assert(int(w) == video.w && int(h) == video.h)
	video.rendered += 1
	if video.rendered <= video.warmup do return
	posix.fwrite(raw_data(pixels), 1, uint(len(pixels)), video.pipe)
	video.frames += 1
	if video.frames == video.total do engine.request_quit(ctx)
}

// Closes ffmpeg's input and waits for the file to be finalized. Also runs when the run ends early.
video_close :: proc() {
	if video.pipe == nil do return
	status := posix.pclose(video.pipe)
	video.pipe = nil
	if status != 0 do log.errorf("video: ffmpeg exit status %d", status)
	if video.frames != video.total do log.warnf("video: %d of %d frames written", video.frames, video.total)
	fmt.printfln("VIDEO %s frames %d", video.path, video.frames)
}

// Config.before_exit: finishes the video, then the benchmark report.
video_exit_hook :: proc(ctx: ^engine.Context, scene_name: string, user: rawptr) {
	video_close()
	bench_before_exit(ctx, scene_name, user)
}
