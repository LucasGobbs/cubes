// Streetlights: one camera-facing soft glow per spot along both kerbs of every street, merged into one mesh. The
// glow is a billboard (shaders/city_lights.slang): a round falloff, HDR, drawn additively so bloom picks it up.
// Lamps are night-only.
package city

import engine "../../engine"
import gfx "../../engine/gfx"
import shader_parameters "../../shader_parameters"
import "core:log"

LAMP_SPACING :: 8 // units between posts along a street
LAMP_JITTER :: 1 // +- units along the street, from the seed
LAMP_KERB :: 0.5 // unit cell centre inside the road edge
LAMP_HEIGHT :: 4
LAMP_SEED_MIX :: 0x7F4A7C15 // keeps lamp jitter independent of the building and sky streams
LAMP_VERTICES :: 4 // one billboard quad per lamp
LAMP_INDICES :: 6

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

// One quad per lamp. Every corner keeps the lamp centre as position; colour.rg carries the corner, which the shader
// expands into a camera-facing billboard.
lamps_build_mesh :: proc(positions: []Vec3) -> Mesh_Builder {
	b: Mesh_Builder
	reserve(&b.vertices, len(positions) * LAMP_VERTICES)
	reserve(&b.indices, len(positions) * LAMP_INDICES)
	corners := [4][2]f32{{-1, -1}, {1, -1}, {1, 1}, {-1, 1}}
	for c in positions {
		base := u32(len(b.vertices))
		for corner in corners {
			append(&b.vertices, gfx.VertexData{position = c, color = {corner.x, corner.y, 0, 1}})
		}
		append(&b.indices, base, base + 1, base + 2, base, base + 2, base + 3)
	}
	return b
}

lights_pipeline_create :: proc(gfx_ctx: ^gfx.Device, state: ^City_State) -> gfx.Pipeline_Handle {
	attributes := shader_parameters.city_lights_vertex_attributes(gfx.VertexData)
	return gfx.pipeline_create(
		gfx_ctx,
		{
			vertex = shader_parameters.city_lights_vertex(),
			fragment = shader_parameters.city_lights_fragment(),
			vertex_attributes = attributes[:],
			vertex_stride = u32(size_of(gfx.VertexData)),
			depth_test = true,
			depth_write = false, // glows add into the scene and do not hide each other
			additive = true,
			cull_mode = .NONE, // billboards face the camera; either winding is fine
			bind_draw = lights_bind_draw,
			user_data = state,
		},
	)
}

lights_bind_draw :: proc(user_data: rawptr, draw_context: ^gfx.Draw_Context, parameters: gfx.Draw_Parameters) {
	camera := parameters.camera_position
	uniforms := shader_parameters.CityLightsVertexUniforms {
		mvp             = parameters.view_projection * parameters.model_transform,
		camera_position = {camera.x, camera.y, camera.z, 1},
	}
	gfx.draw_push_uniform(draw_context, shader_parameters.CITY_LIGHTS_VERTEX_UNIFORM_BLOCK, &uniforms)
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
