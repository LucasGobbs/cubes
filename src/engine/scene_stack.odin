// Scene switching and the scene stack. Every swap (change, push, pop) goes through
// host_scene_swap at the top of a tick, when the screen is covered and no frame is open.
//
// The stack is LIFO and matches the gfx scope stack: a Keep frame leaves its scope open and
// the scene above opens a nested one. Only the top scene ticks and draws.
package engine

import "core:fmt"
import "core:log"
import "core:os"
import gfx "gfx"
import "input"
import sdl "vendor:sdl3"

STACK_CACHE_DIR :: ".cache/scene_stack"

// A scene parked under the running one. Keep holds the live scene and the host state it
// needs back on pop; Disk and Discard hold nothing but the registry index.
Stack_Frame :: struct {
	scene:       Scene, // Keep only
	index:       int, // into host_config.scenes
	policy:      Stack_Policy,
	input_mark:  input.Mark, // input actions registered before the scene (Keep only)
	camera:      Camera_Controller, // Keep only
	camera_keys: Maybe(Fly_Controls), // Keep only
	accumulator: f32, // fixed-step leftover (Keep only)
	renderer:    gfx.Renderer_Saved, // Keep only
	disk_path:   string, // Disk only; owned
}

@(private) scene_stack: [dynamic]Stack_Frame

// Replaces the running scene with `next` (already loaded when it has a load hook).
// Change clears the stack; Push parks the running scene under it; Pop returns to the frame below.
host_scene_swap :: proc(ctx: ^Context, scene: ^Scene, kind: Scene_Request_Kind, index: int, policy: Stack_Policy, next: Scene) {
	log.infof("switching scene: %s -> %s (%v)", host_config.scenes[current_scene].name, host_config.scenes[index].name, kind)
	_ = sdl.WaitForGPUIdle(ctx.gfx.gpu) // the old scene's buffers may still be in flight
	resumed: Maybe(Stack_Frame) // Disk frame waiting for resume after create

	switch kind {
	case .Change:
		host_scene_destroy(ctx, scene)
		input.system_rewind(&ctx.input, scene_input_mark)
		for len(scene_stack) > 0 {
			frame := pop(&scene_stack)
			host_frame_release(ctx, &frame)
			input.system_rewind(&ctx.input, frame.input_mark)
		}
	case .Push:
		frame := Stack_Frame {
			scene       = scene^,
			index       = current_scene,
			policy      = policy,
			input_mark  = scene_input_mark,
			accumulator = fixed_accumulator,
		}
		switch policy {
		case .Keep:
			frame.camera, frame.camera_keys = ctx.camera, ctx.camera_keys
			frame.renderer = gfx.renderer_scene_save(&ctx.gfx.renderer)
		case .Disk, .Discard:
			if policy == .Disk {
				frame.disk_path = host_scene_suspend(ctx, scene, len(scene_stack) + 1)
				if frame.disk_path == "" do frame.policy = .Discard
			}
			frame.scene = {}
			host_scene_destroy(ctx, scene)
			input.system_rewind(&ctx.input, scene_input_mark)
		}
		append(&scene_stack, frame)
	case .Pop:
		frame := pop(&scene_stack)
		host_scene_destroy(ctx, scene)
		input.system_rewind(&ctx.input, scene_input_mark)
		if frame.policy == .Keep {
			scene_input_mark = frame.input_mark
			scene^ = frame.scene
			current_scene = frame.index
			fixed_accumulator = frame.accumulator
			ctx.camera, ctx.camera_keys = frame.camera, frame.camera_keys
			gfx.renderer_scene_restore(&ctx.gfx.renderer, &frame.renderer)
			return
		}
		resumed = frame
	}

	fixed_accumulator = 0
	gfx.set_present_mode(&ctx.gfx, .IMMEDIATE)
	scene_input_mark = input.system_mark(&ctx.input)
	scene^ = next
	current_scene = index
	created := host_scene_create(ctx, scene)
	if frame, ok := resumed.?; ok {
		if created && frame.policy == .Disk do host_scene_resume(ctx, scene, frame.disk_path)
		frame := frame
		host_frame_release(ctx, &frame)
	}
	if !created {
		log.errorf("scene %q failed to create", host_config.scenes[index].name)
		request_quit(ctx)
	}
}

// Frees what a frame holds: the live scene (Keep) or its disk file.
host_frame_release :: proc(ctx: ^Context, frame: ^Stack_Frame) {
	if frame.policy == .Keep {
		host_scene_destroy(ctx, &frame.scene)
		gfx.renderer_scene_saved_destroy(&frame.renderer)
	}
	if frame.disk_path != "" {
		_ = os.remove(frame.disk_path)
		delete(frame.disk_path)
	}
	frame^ = {}
}

// Destroys every parked scene, top first. Used at exit.
host_stack_destroy :: proc(ctx: ^Context) {
	for len(scene_stack) > 0 {
		frame := pop(&scene_stack)
		host_frame_release(ctx, &frame)
	}
	delete(scene_stack)
}

// Writes the scene to the cache dir. "" (with a warning) when it cannot, so the caller acts as Discard.
host_scene_suspend :: proc(ctx: ^Context, scene: ^Scene, depth: int) -> string {
	if scene.suspend == nil {
		log.warnf("scene %q has no suspend hook; Disk acts as Discard", scene.name)
		return ""
	}
	if err := os.make_directory_all(STACK_CACHE_DIR); err != nil && !os.exists(STACK_CACHE_DIR) {
		log.errorf("scene stack: cannot create %s: %v; Disk acts as Discard", STACK_CACHE_DIR, err)
		return ""
	}
	path := fmt.aprintf("%s/%d_%s.bin", STACK_CACHE_DIR, depth, host_config.scenes[current_scene].name)
	if !scene.suspend(scene, ctx, path) {
		log.errorf("scene %q: suspend failed; Disk acts as Discard", scene.name)
		delete(path)
		return ""
	}
	return path
}

// A failed resume keeps the freshly created scene.
host_scene_resume :: proc(ctx: ^Context, scene: ^Scene, path: string) {
	if scene.resume == nil {
		log.warnf("scene %q has no resume hook; its suspended state is dropped", scene.name)
		return
	}
	if !scene.resume(scene, ctx, path) do log.errorf("scene %q: resume from %s failed; keeping the new scene", scene.name, path)
}
