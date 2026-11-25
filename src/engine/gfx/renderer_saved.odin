package gfx

// Scene-owned renderer state, parked while another scene sits on top of it (scene stack,
// Keep policy). Host-owned passes (After_Post: transition, stats) are not part of it.
Renderer_Saved :: struct {
	camera:         Camera,
	after_scene:    [dynamic]Render_Pass,
	post:           [dynamic]Render_Pass,
	final:          [dynamic]Render_Pass,
	scene_hooks:    [dynamic]Scene_Hook,
	light_direction: [3]f32,
	fog:            [4]f32,
	clear_color:    [4]f32,
	shadow_enabled: bool,
}

// Copies the scene's renderer state, then resets it to what a fresh scene expects.
renderer_scene_save :: proc(renderer: ^Renderer) -> Renderer_Saved {
	saved := Renderer_Saved {
		camera          = renderer.camera,
		after_scene     = make([dynamic]Render_Pass, 0, len(renderer.passes[.After_Scene])),
		post            = make([dynamic]Render_Pass, 0, len(renderer.passes[.Post])),
		final           = make([dynamic]Render_Pass, 0, len(renderer.passes[.Final])),
		scene_hooks     = make([dynamic]Scene_Hook, 0, len(renderer.scene_hooks)),
		light_direction = renderer.light_direction,
		fog             = renderer.fog,
		clear_color     = renderer.clear_color,
		shadow_enabled  = renderer.shadow_enabled,
	}
	append(&saved.after_scene, ..renderer.passes[.After_Scene][:])
	append(&saved.post, ..renderer.passes[.Post][:])
	append(&saved.final, ..renderer.passes[.Final][:])
	append(&saved.scene_hooks, ..renderer.scene_hooks[:])

	clear(&renderer.passes[.After_Scene])
	clear(&renderer.passes[.Post])
	clear(&renderer.passes[.Final])
	clear(&renderer.scene_hooks)
	renderer.fog = {}
	renderer.clear_color = DEFAULT_CLEAR_COLOR
	renderer.shadow_enabled = true
	renderer_update_light(renderer, DEFAULT_LIGHT_DIRECTION)
	return saved
}

// Puts the saved state back (after the scene on top has been destroyed) and frees the copy.
renderer_scene_restore :: proc(renderer: ^Renderer, saved: ^Renderer_Saved) {
	renderer.camera = saved.camera
	renderer_set_passes(renderer, .After_Scene, saved.after_scene[:])
	renderer_set_passes(renderer, .Post, saved.post[:])
	renderer_set_passes(renderer, .Final, saved.final[:])
	clear(&renderer.scene_hooks)
	append(&renderer.scene_hooks, ..saved.scene_hooks[:])
	renderer.light_direction = saved.light_direction
	renderer.fog = saved.fog
	renderer.clear_color = saved.clear_color
	renderer.shadow_enabled = saved.shadow_enabled
	renderer_scene_saved_destroy(saved)
}

renderer_scene_saved_destroy :: proc(saved: ^Renderer_Saved) {
	delete(saved.after_scene)
	delete(saved.post)
	delete(saved.final)
	delete(saved.scene_hooks)
	saved^ = {}
}
