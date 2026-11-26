package particles

import gfx "../gfx"

Vec3 :: gfx.Vec3

Mode :: enum u8 {
	GPU,
	CPU,
}

Blend :: enum u8 {
	Additive,
	Alpha,
}

DEFAULT_CAPACITY :: 1024

// Layout mirrors struct Particle in shaders/particle_sim.slang; the CPU path uploads it as-is.
Particle :: struct {
	position: Vec3,
	age:      f32,
	velocity: Vec3,
	lifetime: f32,
	color:    [4]f32,
}
#assert(size_of(Particle) == 48)

Emitter_Desc :: struct {
	mode:        Mode,
	blend:       Blend,
	capacity:    u32, // 0 = DEFAULT_CAPACITY
	rate:        f32, // particles per second (continuous)
	position:    Vec3,
	direction:   Vec3, // zero = +Y; normalized internally
	spread:      f32, // cone half-angle in radians; 0 = straight, PI = sphere
	radius:      f32, // spawn sphere radius, 0 = point
	lifetime:    [2]f32, // min, max; {0,0} = {1,1}
	speed:       [2]f32, // min, max
	gravity:     Vec3,
	drag:        f32,
	size:        [2]f32, // start, end billboard size (world units); {0,0} = {0.1,0.1}
	color_start: [4]f32, // zero = white {1,1,1,1}
	color_end:   [4]f32, // zero = fade to transparent (intended)
	fade_in:     f32,
	stretch:     f32, // 0 = round billboard; > 0 = streak along the velocity, this many seconds of travel long (rain)
	wrap_box:    Maybe(Vec3), // set = wrap mode (GPU, render-only): nothing spawns, drops stay fixed in a box centred on the camera
	floor_y:     Maybe(f32), // wrap mode: drops whose streak reaches below this world y are hidden
}

Emitter :: struct {
	desc:         Emitter_Desc, // capacity already resolved (never 0)
	active:       bool, // false = no continuous spawning (bursts still work); wrap mode: nothing drawn
	intensity:    f32, // wrap mode: fraction of slots drawn (0..1), the first ones in the ring
	alive:        bool, // slot in use
	generation:   u32,
	accumulator:  f32,
	head:         u32, // next ring slot to spawn into
	spawn_start:  u32,
	spawn_count:  u32, // this frame's spawn window (GPU mode reads these)
	pending_burst: u32,
	frame:        u32, // increments per step; GPU seed
	rng:          u32,
	cpu:          []Particle, // CPU mode only, len == capacity
	buffer:       gfx.Buffer_Handle, // GPU storage buffer (owned by system.odin)
}
