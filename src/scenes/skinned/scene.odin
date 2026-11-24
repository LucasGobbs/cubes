// Skinned: one rigged glTF character playing its first animation clip.
package skinned

import engine "../../engine"

SKINNED_MODEL_PATH :: "static/models/rigged_cesiumman.glb"
SKINNED_CLIP :: "clip_0"

Skinned_State :: struct {
	world: engine.World,
}

skinned_scene :: proc() -> engine.Scene {
	return {
		name = "Skinned",
		create = skinned_create,
		tick = skinned_tick,
		destroy = skinned_destroy,
	}
}

skinned_create :: proc(demo: ^engine.Scene, ctx: ^engine.Context) -> bool {
	state := new(Skinned_State)
	demo.state = state
	state.world = engine.world_create(&ctx.gfx)
	engine.camera_fly(ctx)
	engine.spawn(&state.world, engine.Model{path = SKINNED_MODEL_PATH}, engine.Animator{clip = SKINNED_CLIP})
	return true
}

skinned_tick :: proc(demo: ^engine.Scene, ctx: ^engine.Context, delta_time: f32) {
	state := cast(^Skinned_State)demo.state
	engine.world_update(&state.world, delta_time)
	engine.world_render(&state.world, ctx.blend)
}

skinned_destroy :: proc(demo: ^engine.Scene, ctx: ^engine.Context) {
	state := cast(^Skinned_State)demo.state
	engine.world_destroy(&state.world)
	free(state)
}
