// Odin baseline for scriptdemo: the same actors and motion as spinner.lua, ticked by a
// register_type proc. No Script prop and no Lua host.
package scriptdemo

import "core:math"
import engine "../../engine"

Odin_Spinner :: struct {
	t, yaw, base_y: f32,
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
	spinner := engine.register_type(&state.world, Odin_Spinner, odin_spinner_create, odin_spinner_tick, nil)
	for i in 0 ..< count {
		transform := engine.Transform{position = scriptdemo_position(i, count)}
		if nomodel {
			engine.spawn_typed(&state.world, spinner, Odin_Spinner{}, transform)
		} else {
			engine.spawn_typed(&state.world, spinner, Odin_Spinner{}, transform, engine.Model{path = SCRIPTDEMO_MODEL_PATH})
		}
	}
	return true
}

odin_spinner_create :: proc(world: ^engine.World, id: engine.Actor_Id, self: ^Odin_Spinner) {
	self.base_y = engine.actor_props(world, id, engine.Transform).position.y
}

// Mirrors spinner.lua tick: same clocks, same formulas, same rotation (x = z = 0).
odin_spinner_tick :: proc(world: ^engine.World, id: engine.Actor_Id, self: ^Odin_Spinner, dt: f32) {
	t := engine.actor_props(world, id, engine.Transform)
	self.t += dt
	self.yaw += dt
	half := self.yaw * 0.5
	t.position.y = self.base_y + math.sin(self.t * 2) * 0.25
	t.rotation = quaternion(w = math.cos(half), x = 0, y = math.sin(half), z = 0)
}
