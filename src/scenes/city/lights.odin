// Streetlights: one star-shaped emissive lamp per spot along both kerbs of every street, merged into one mesh.
// Lamps are night-only and are drawn unlit with an HDR tint, so bloom picks them up.
package city

import engine "../../engine"
import "core:log"

LAMP_SPACING :: 8 // units between posts along a street
LAMP_JITTER :: 1 // +- units along the street, from the seed
LAMP_KERB :: 0.5 // unit cell centre inside the road edge
LAMP_HEIGHT :: 4
LAMP_STAR :: 1.2 // size of each star quad
LAMP_TINT :: [4]f32{1, 0.5, 0.15, 1} // sodium orange, sRGB
LAMP_EMISSION :: 1.8 // HDR multiplier: above the bloom threshold
LAMP_SEED_MIX :: 0x7F4A7C15 // keeps lamp jitter independent of the building and sky streams

// Ground-level lamp spots as Vec3{x, LAMP_HEIGHT, z}, in road cells. Caller frees the array.
// Intersections are left unlit: a spot inside another road's rect is dropped.
lamp_positions :: proc(p: ^Plan, seed: u32) -> [dynamic]Vec3 {
	out: [dynamic]Vec3
	rng := rng_seed(seed ~ LAMP_SEED_MIX)
	rng_u32(&rng) // first output of a near-zero xorshift state is weakly mixed
	for r, i in p.roads {
		along_z := r.z1 - r.z0 > r.x1 - r.x0 // north-south street: runs the length of the city along z
		lo, hi := r.x0, r.x1
		if along_z do lo, hi = r.z0, r.z1
		for side in 0 ..< 2 {
			edge: f32
			if along_z {
				edge = f32(r.x0) + LAMP_KERB if side == 0 else f32(r.x1) - LAMP_KERB
			} else {
				edge = f32(r.z0) + LAMP_KERB if side == 0 else f32(r.z1) - LAMP_KERB
			}
			for k := 0; ; k += 1 {
				base := f32(lo) + LAMP_SPACING / 2 + f32(k * LAMP_SPACING)
				if base >= f32(hi) do break
				along := clamp(base + rng_range(&rng, -LAMP_JITTER, LAMP_JITTER), f32(lo) + LAMP_KERB, f32(hi) - LAMP_KERB)
				pos := Vec3{edge, LAMP_HEIGHT, along}
				if !along_z do pos = Vec3{along, LAMP_HEIGHT, edge}
				if lamp_in_other_road(p, pos, i) do continue
				append(&out, pos)
			}
		}
	}
	return out
}

lamp_in_other_road :: proc(p: ^Plan, pos: Vec3, own: int) -> bool {
	x, z := i32(pos.x), i32(pos.z)
	for r, i in p.roads {
		if i != own && x >= r.x0 && x < r.x1 && z >= r.z0 && z < r.z1 do return true
	}
	return false
}

// Star: a flat quad plus two crossed upright quads, each emitted with both windings (unlit draws cull BACK).
lamps_build_mesh :: proc(positions: []Vec3) -> Mesh_Builder {
	b: Mesh_Builder
	reserve(&b.vertices, len(positions) * 24)
	reserve(&b.indices, len(positions) * 36)
	h: f32 = LAMP_STAR / 2
	white := [4]f32{1, 1, 1, 1}
	for c in positions {
		quads := [3][4]Vec3 {
			{{c.x - h, c.y, c.z - h}, {c.x - h, c.y, c.z + h}, {c.x + h, c.y, c.z + h}, {c.x + h, c.y, c.z - h}},
			{{c.x - h, c.y - h, c.z}, {c.x - h, c.y + h, c.z}, {c.x + h, c.y + h, c.z}, {c.x + h, c.y - h, c.z}},
			{{c.x, c.y - h, c.z - h}, {c.x, c.y + h, c.z - h}, {c.x, c.y + h, c.z + h}, {c.x, c.y - h, c.z + h}},
		}
		for q in quads {
			builder_quad(&b, q[0], q[1], q[2], q[3], {}, {}, white)
			builder_quad(&b, q[3], q[2], q[1], q[0], {}, {}, white)
		}
	}
	return b
}

// Spawns the streetlights as one Raw_Draw. Night view only.
city_spawn_lamps :: proc(state: ^City_State) {
	positions := lamp_positions(&state.plan, state.seed)
	defer delete(positions)
	b := lamps_build_mesh(positions[:])
	state.lamps = engine.spawn(&state.world, engine.Raw_Draw{mesh = builder_to_mesh_data(&b), material = &state.lamp_material})
	log.infof("city: %v streetlights, %v vertices", len(positions), len(b.vertices))
	builder_destroy(&b)
}

city_despawn_lamps :: proc(state: ^City_State) {
	engine.world_destroy_actor(&state.world, state.lamps)
}
