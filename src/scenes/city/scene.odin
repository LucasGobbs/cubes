// City step 1: an empty scene with a fly camera and a flat dev-green background.
package city

import engine "../../engine"

CITY_CLEAR_COLOR :: [4]f32{0.1, 0.45, 0.1, 1}
CITY_CAMERA_SPEED :: 100 // units/s: crossing the 1024-unit city takes ~10 s

City_State :: struct {
	world: engine.World,
}

city_scene :: proc() -> engine.Scene {
	return {
		name = "City",
		create = city_create,
		tick = city_tick,
		destroy = city_destroy,
	}
}

city_create :: proc(demo: ^engine.Scene, ctx: ^engine.Context) -> bool {
	state := new(City_State)
	demo.state = state
	state.world = engine.world_create(&ctx.gfx)
	ctx.gfx.renderer.clear_color = CITY_CLEAR_COLOR
	engine.camera_fly(ctx, {0, 60, 120}, {0, 20, 0}, CITY_CAMERA_SPEED)
	return true
}

city_tick :: proc(demo: ^engine.Scene, ctx: ^engine.Context, delta_time: f32) {
	state := cast(^City_State)demo.state
	engine.world_update(&state.world, delta_time)
	engine.world_render(&state.world, ctx.blend)
}

city_destroy :: proc(demo: ^engine.Scene, ctx: ^engine.Context) {
	state := cast(^City_State)demo.state
	engine.world_destroy(&state.world)
	free(state)
}
