package engine

import "core:testing"

@(test)
stage_applied_follows_stage_without_device :: proc(t: ^testing.T) {
	world := world_create(nil)
	defer world_destroy(&world)

	world_update(&world, 0.1)
	testing.expect(t, !world.stage_applied, "untouched stage is not applied")

	world.stage.fog = Fog{color = {0.5, 0.5, 0.6}, distance = 100}
	world_update(&world, 0.1)
	testing.expect(t, world.stage_applied, "set stage is applied")

	world.stage = {}
	world_update(&world, 0.1)
	testing.expect(t, !world.stage_applied, "reset stage clears applied flag after one more update")
}
