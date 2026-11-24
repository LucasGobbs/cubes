package benchmark

import engine "../../engine"
import "core:math"
import "core:testing"

@(test)
test_boat_step_flees_and_wraps :: proc(t: ^testing.T) {
	// Camera 10 units south of a boat heading toward it (inside the sail box): turns away and doubles speed.
	slot := Boat_Slot{x = 0, z = -100, heading = math.PI, speed = 4}
	boat_step(&slot, engine.Vec3{0, 0, -110}, 0.1, true)
	// turn clamped to FLEE_TURN_RATE * dt = 0.15 rad toward away-direction
	testing.expect(t, math.abs(slot.heading - (math.PI - 0.15)) < 1e-4, "heading should turn away at TURN_RATE")
	// speed doubled: 4 * 2 * 0.1 = 0.8 units travelled
	dist := math.sqrt(slot.x * slot.x + (slot.z + 100) * (slot.z + 100))
	testing.expectf(t, math.abs(dist - 0.8) < 1e-3, "fleeing boat should move at double speed, moved %v", dist)

	// Sailing off: nothing moves.
	still := Boat_Slot{x = 100, z = -100, heading = 1, speed = 4}
	boat_step(&still, engine.Vec3{0, 0, 0}, 1, false)
	testing.expect(t, still.x == 100 && still.z == -100, "sailing off must not move boats")

	// Past the x edge wraps to the opposite side.
	edge := Boat_Slot{x = 699.9, z = -300, heading = math.PI / 2, speed = 4}
	boat_step(&edge, engine.Vec3{-5000, 0, 0}, 1, true)
	testing.expect(t, edge.x < 0, "boat past +x edge should wrap to -x side")
}
