package particles

import "core:math/linalg"
import "core:testing"

@(test)
continuous_rate_spawns_exact_count :: proc(t: ^testing.T) {
	e: Emitter
	emitter_init(&e, Emitter_Desc{mode = .GPU, rate = 100})
	defer emitter_destroy(&e)

	total: u32
	for _ in 0 ..< 10 {
		emitter_step(&e, 0.01)
		total += e.spawn_count
	}
	testing.expect_value(t, total, u32(10))
}

@(test)
ring_wraps_and_clamps_burst :: proc(t: ^testing.T) {
	e: Emitter
	emitter_init(&e, Emitter_Desc{mode = .GPU, capacity = 4})
	defer emitter_destroy(&e)

	emitter_burst(&e, 6)
	emitter_step(&e, 0.01)
	testing.expect_value(t, e.spawn_count, u32(4))
	testing.expect_value(t, e.spawn_start, u32(0))
	testing.expect_value(t, e.head, u32(0))

	emitter_burst(&e, 3)
	emitter_step(&e, 0.01)
	testing.expect_value(t, e.spawn_start, u32(0))
	testing.expect_value(t, e.spawn_count, u32(3))
	testing.expect_value(t, e.head, u32(3))

	emitter_burst(&e, 2)
	emitter_step(&e, 0.01)
	testing.expect_value(t, e.spawn_start, u32(3))
	testing.expect_value(t, e.spawn_count, u32(2))
	testing.expect_value(t, e.head, u32(1))
}

@(test)
cpu_particle_dies_at_lifetime :: proc(t: ^testing.T) {
	e: Emitter
	emitter_init(
		&e,
		Emitter_Desc{mode = .CPU, capacity = 4, lifetime = {0.5, 0.5}, speed = {1, 1}, direction = {0, 1, 0}, color_start = {1, 1, 1, 1}},
	)
	defer emitter_destroy(&e)

	emitter_burst(&e, 1)
	emitter_step(&e, 0.1)
	for _ in 0 ..< 10 {
		emitter_step(&e, 0.1)
	}
	p := e.cpu[0]
	testing.expect(t, p.age >= p.lifetime)

	// Dead particles must stop integrating, so position is frozen after death.
	frozen := p.position
	emitter_step(&e, 0.1)
	testing.expect_value(t, e.cpu[0].position, frozen)
}

@(test)
cpu_gravity_and_drag_integrate :: proc(t: ^testing.T) {
	falling: Emitter
	emitter_init(
		&falling,
		Emitter_Desc{mode = .CPU, capacity = 4, lifetime = {10, 10}, speed = {2, 2}, direction = {1, 0, 0}, gravity = {0, -10, 0}},
	)
	defer emitter_destroy(&falling)

	emitter_burst(&falling, 1)
	emitter_step(&falling, 0.1)
	start_y := falling.cpu[0].position.y
	for _ in 0 ..< 10 {
		emitter_step(&falling, 0.1)
	}
	testing.expect(t, falling.cpu[0].position.y < start_y)
	testing.expect(t, falling.cpu[0].velocity.y < -9)

	damped: Emitter
	emitter_init(
		&damped,
		Emitter_Desc{mode = .CPU, capacity = 4, lifetime = {10, 10}, speed = {2, 2}, direction = {1, 0, 0}, drag = 1},
	)
	defer emitter_destroy(&damped)

	emitter_burst(&damped, 1)
	emitter_step(&damped, 0.1)
	emitter_step(&damped, 0.1)
	// One integration step: v = 2 / (1 + drag*dt) = 2 / 1.1
	speed := linalg.length(damped.cpu[0].velocity)
	testing.expect(t, abs(speed - 2.0 / 1.1) < 1e-4)
}

@(test)
zero_spread_velocities_parallel_to_direction :: proc(t: ^testing.T) {
	e: Emitter
	dir := Vec3{1, 2, 3}
	emitter_init(&e, Emitter_Desc{mode = .CPU, capacity = 8, lifetime = {10, 10}, speed = {1, 4}, direction = dir, spread = 0})
	defer emitter_destroy(&e)

	emitter_burst(&e, 8)
	emitter_step(&e, 0)

	axis := linalg.normalize(dir)
	for p in e.cpu {
		testing.expect(t, linalg.length(linalg.cross(linalg.normalize(p.velocity), axis)) < 1e-5)
		s := linalg.length(p.velocity)
		testing.expect(t, s >= 1 - 1e-5 && s <= 4 + 1e-5)
	}
}

@(test)
zero_desc_gets_visible_defaults :: proc(t: ^testing.T) {
	e: Emitter
	emitter_init(&e, Emitter_Desc{mode = .CPU})
	defer emitter_destroy(&e)

	testing.expect_value(t, e.desc.color_start, [4]f32{1, 1, 1, 1})
	testing.expect_value(t, e.desc.lifetime, [2]f32{1, 1})
	testing.expect_value(t, e.desc.size, [2]f32{0.1, 0.1})

	emitter_burst(&e, 1)
	emitter_step(&e, 0)
	testing.expect_value(t, e.cpu[0].color, [4]f32{1, 1, 1, 1})
	testing.expect_value(t, e.cpu[0].lifetime, f32(1))
}

@(test)
cpu_spawns_follow_the_emitter_position :: proc(t: ^testing.T) {
	e: Emitter
	emitter_init(&e, Emitter_Desc{mode = .CPU, capacity = 8, position = {0, 0, 0}, lifetime = {10, 10}})
	defer emitter_destroy(&e)

	emitter_burst(&e, 1)
	emitter_step(&e, 0.01)
	testing.expect_value(t, e.cpu[0].position, Vec3{0, 0, 0})

	e.desc.position = {100, 5, -40} // a camera-following emitter is moved every frame
	emitter_burst(&e, 1)
	emitter_step(&e, 0.01)
	testing.expect_value(t, e.cpu[1].position, Vec3{100, 5, -40})
}

@(test)
wrap_axis_folds_into_box_and_is_periodic :: proc(t: ^testing.T) {
	xs := [?]f32{-400, -90.5, -45, 0, 44.9, 89.9, 90, 277.3}
	for x in xs {
		w := wrap_axis(x, 180)
		testing.expect(t, w >= -90 && w < 90)
		testing.expect(t, abs(wrap_axis(x + 180, 180) - w) < 1e-3)
	}
}

@(test)
draw_count_follows_intensity_and_active :: proc(t: ^testing.T) {
	e: Emitter
	emitter_init(&e, Emitter_Desc{mode = .GPU, capacity = 1000, wrap_box = Vec3{180, 180, 180}})
	defer emitter_destroy(&e)
	testing.expect_value(t, draw_count(&e), u32(1000))
	e.intensity = 0.5
	testing.expect_value(t, draw_count(&e), u32(500))
	e.intensity = 0
	testing.expect_value(t, draw_count(&e), u32(0))
	e.intensity = 2
	testing.expect_value(t, draw_count(&e), u32(1000))
	e.intensity = 1
	e.active = false
	testing.expect_value(t, draw_count(&e), u32(0))

	plain: Emitter
	emitter_init(&plain, Emitter_Desc{mode = .GPU, capacity = 64})
	defer emitter_destroy(&plain)
	plain.intensity = 0
	testing.expect_value(t, draw_count(&plain), u32(64))
}

@(test)
wrap_fill_stays_in_box_with_speed_range :: proc(t: ^testing.T) {
	e: Emitter
	emitter_init(&e, Emitter_Desc{mode = .GPU, capacity = 256, wrap_box = Vec3{180, 40, 180}, direction = Vec3{0, -1, 0}, speed = {60, 80}})
	defer emitter_destroy(&e)
	for p in e.cpu {
		testing.expect(t, abs(p.position.x) <= 90 && abs(p.position.y) <= 20 && abs(p.position.z) <= 90)
		s := linalg.length(p.velocity)
		testing.expect(t, s >= 60 - 1e-3 && s <= 80 + 1e-3)
	}
	emitter_step(&e, 0.1)
	testing.expect_value(t, e.spawn_count, u32(0))
}
