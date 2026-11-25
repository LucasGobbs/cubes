// Odin baseline for scriptdemo: the same actors and motion as spinner.lua, ticked by an
// actor tick hook. No Script prop and no Lua host.
package scriptdemo

import "core:math"
import engine "../../engine"

Odin_Spinner :: struct {
	using actor:     engine.Actor,
	using transform: engine.Transform,
	t, yaw, base_y:  f32,
}

scriptdemo_odin_scene :: proc() -> engine.Scene {
	return {
		name = "Scriptdemo Odin",
		create = scriptdemo_odin_create,
		tick = scriptdemo_tick,
		destroy = scriptdemo_destroy,
	}
}

scriptdemo_odin_create :: proc(demo: ^engine.Scene, ctx: ^engine.Context) -> bool {
	count, ok := scriptdemo_count()
	if !ok do return false
	nomodel := scriptdemo_nomodel()
	state := new(Scriptdemo_State)
	demo.state = state
	state.world = engine.world_create(&ctx.gfx)
	engine.camera_fly(ctx)
	for i in 0 ..< count {
		position := scriptdemo_position(i, count)
		spinner := engine.world_add_actor(&state.world, Odin_Spinner{
			actor     = engine.actor_hooks(Odin_Spinner, tick = odin_spinner_tick),
			transform = engine.transform_create(position = position),
			base_y    = position.y,
		})
		if !nomodel do engine.model_set(spinner, SCRIPTDEMO_MODEL_PATH)
	}
	return true
}

// Mirrors spinner.lua tick: same clocks, same formulas, same rotation (x = z = 0).
odin_spinner_tick :: proc(self: ^Odin_Spinner, dt: f32) {
	self.t += dt
	self.yaw += dt
	half := self.yaw * 0.5
	self.position.y = self.base_y + math.sin(self.t * 2) * 0.25
	self.rotation = quaternion(w = math.cos(half), x = 0, y = math.sin(half), z = 0)
}
