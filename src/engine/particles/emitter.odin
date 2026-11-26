package particles

import "core:math"
import "core:math/linalg"

// Fixed seed: CPU spawns must be reproducible for tests and replays.
RNG_SEED :: 0x9E3779B9

// Absorbs f32 rounding in rate*dt so 100/s at 0.01s spawns exactly one per step.
SPAWN_EPSILON :: 1e-4

emitter_init :: proc(e: ^Emitter, desc: Emitter_Desc) {
	desc := desc
	if desc.capacity == 0 {
		desc.capacity = DEFAULT_CAPACITY
	}
	// Zero-initialized fields (JSON scenes omit them) must still produce visible particles.
	if desc.color_start == {} {
		desc.color_start = {1, 1, 1, 1}
	}
	if desc.lifetime == {} {
		desc.lifetime = {1, 1}
	}
	if desc.size == {} {
		desc.size = {0.1, 0.1}
	}
	desc.direction = unit_direction(desc.direction)

	e^ = Emitter{desc = desc, active = true, intensity = 1, alive = true, rng = RNG_SEED}
	_, wrap := desc.wrap_box.?
	assert(!wrap || desc.mode == .GPU, "wrap_box needs a GPU emitter")
	if desc.mode == .CPU || wrap {
		e.cpu = make([]Particle, desc.capacity)
	}
	if wrap do wrap_fill(desc, e.cpu)
}

emitter_destroy :: proc(e: ^Emitter) {
	delete(e.cpu)
	e.cpu = nil
	e.alive = false
}

emitter_burst :: proc(e: ^Emitter, count: u32) {
	e.pending_burst += count
}

emitter_step :: proc(e: ^Emitter, dt: f32) {
	if _, wrap := e.desc.wrap_box.?; wrap {
		e.spawn_count = 0 // wrap drops are fixed at creation: nothing spawns and nothing integrates
		return
	}
	capacity := e.desc.capacity

	spawns := e.pending_burst
	e.pending_burst = 0
	if e.active {
		e.accumulator += e.desc.rate * dt
		whole := math.floor(e.accumulator + SPAWN_EPSILON)
		// Keep only the fractional remainder; spawns beyond capacity are dropped, not carried.
		e.accumulator = max(0, e.accumulator - whole)
		spawns += u32(min(whole, f32(capacity)))
	} else {
		e.accumulator = 0
	}

	spawn_start := e.head
	spawn_count := min(spawns, capacity)
	e.spawn_start = spawn_start
	e.spawn_count = spawn_count
	e.head = (spawn_start + spawn_count) % capacity
	e.frame += 1

	if e.desc.mode == .CPU {
		// Integrate before spawning so new particles skip their first step, matching particle_sim.slang.
		cpu_integrate(e, dt)
		for k in 0 ..< spawn_count {
			e.cpu[(spawn_start + k) % capacity] = cpu_spawn(e)
		}
	}
}

unit_direction :: proc(d: Vec3) -> Vec3 {
	if linalg.length2(d) == 0 {
		return {0, 1, 0}
	}
	return linalg.normalize(d)
}

cpu_integrate :: proc(e: ^Emitter, dt: f32) {
	damping := 1.0 / (1.0 + e.desc.drag * dt)
	for &p in e.cpu {
		if p.age >= p.lifetime {
			continue
		}
		p.velocity += e.desc.gravity * dt
		p.velocity *= damping
		p.position += p.velocity * dt
		p.age += dt
	}
}

// Same sampling as spawn() in particle_sim.slang, driven by the CPU rng.
cpu_spawn :: proc(e: ^Emitter) -> Particle {
	d := &e.desc

	z := 2 * rng_float(&e.rng) - 1
	phi := 2 * math.PI * rng_float(&e.rng)
	rxy := math.sqrt(max(0, 1 - z * z))
	radius_t := math.pow(rng_float(&e.rng), 1.0 / 3.0)
	offset := Vec3{rxy * math.cos(phi), rxy * math.sin(phi), z} * (d.radius * radius_t)

	// Uniform in cos around the axis samples the cone uniformly by solid angle.
	cos_spread := math.cos(d.spread)
	cos_t := cos_spread + (1 - cos_spread) * rng_float(&e.rng)
	sin_t := math.sqrt(max(0, 1 - cos_t * cos_t))
	az := 2 * math.PI * rng_float(&e.rng)
	helper := Vec3{0, 1, 0}
	if abs(d.direction.y) >= 0.999 {
		helper = {1, 0, 0}
	}
	bx := linalg.normalize(linalg.cross(helper, d.direction))
	by := linalg.cross(d.direction, bx)
	dir := d.direction * cos_t + (bx * math.cos(az) + by * math.sin(az)) * sin_t

	speed := d.speed[0] + (d.speed[1] - d.speed[0]) * rng_float(&e.rng)
	life := d.lifetime[0] + (d.lifetime[1] - d.lifetime[0]) * rng_float(&e.rng)

	return Particle {
		position = d.position + offset,
		velocity = dir * speed,
		age      = 0,
		lifetime = life,
		color    = d.color_start,
	}
}

// PCG step, same mixing as pcg() in particle_sim.slang.
rng_next :: proc(state: ^u32) -> u32 {
	state^ = state^ * 747796405 + 2891336453
	word := ((state^ >> ((state^ >> 28) + 4)) ~ state^) * 277803737
	return (word >> 22) ~ word
}

// Uniform [0,1); 24 bits keep the result strictly below 1.0.
rng_float :: proc(state: ^u32) -> f32 {
	return f32(rng_next(state) >> 8) * (1.0 / 16777216.0)
}

// Mirrors wrap_axis() in particle_render.slang: folds x into [-b/2, b/2) with period b.
wrap_axis :: proc(x, b: f32) -> f32 {
	return x - b * math.floor(x / b + 0.5)
}

// Slots drawn this frame. Wrap emitters draw the first intensity*capacity slots, so lowering intensity removes slots
// without moving any drop; `active` = false hides them all.
draw_count :: proc(e: ^Emitter) -> u32 {
	if _, wrap := e.desc.wrap_box.?; !wrap do return e.desc.capacity
	if !e.active do return 0
	return u32(math.round(clamp(e.intensity, 0, 1) * f32(e.desc.capacity)))
}

// Wrap mode layout: each drop's fixed position in the box and its constant fall velocity, hashed from its slot.
wrap_fill :: proc(desc: Emitter_Desc, out: []Particle) {
	box, _ := desc.wrap_box.?
	dir := unit_direction(desc.direction)
	for &p, i in out {
		u := u32(i)
		p = Particle {
			position = (Vec3{wrap_hash(u, 1), wrap_hash(u, 2), wrap_hash(u, 3)} - 0.5) * box,
			velocity = dir * (desc.speed[0] + (desc.speed[1] - desc.speed[0]) * wrap_hash(u, 4)),
			lifetime = 1,
			color    = desc.color_start,
		}
	}
}

// Uniform [0,1) from (slot, salt): one PCG step after mixing the inputs.
wrap_hash :: proc(slot, salt: u32) -> f32 {
	state: u32 = slot ~ (salt * 0x9E3779B9)
	rng_next(&state)
	return rng_float(&state)
}
