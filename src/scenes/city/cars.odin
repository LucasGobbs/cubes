// Cars: every street has one lane per unit of its width; lanes in the first half drive +, the rest drive -. Each car
// is two lamp quads at its start pose, all in one mesh and one Raw_Draw. The vertex shader slides them along the lane
// from the time uniform (shaders/city_cars.slang), so the CPU does no per-frame work. Night view only.
package city

import engine "../../engine"
import gfx "../../engine/gfx"
import shader_parameters "../../shader_parameters"
import "core:log"

CAR_LANE_LENGTH :: CITY_SIZE // streets run edge to edge
CAR_SPEED_MIN :: 10 // units/s, one speed per lane
CAR_SPEED_MAX :: 20
CAR_GAP_MIN :: 12 // units between cars in a lane
CAR_GAP_MAX :: 44
CAR_LAMP_OFFSET :: 0.3 // lamps sit 0.6 apart across the lane, centred on it
CAR_LAMP_HEIGHT :: 0.35
CAR_VERTICES :: 8 // two lamp quads
CAR_INDICES :: 12
CAR_SEED_MIX :: 0x2545F491 // keeps car lanes independent of the building, sky, lamp and street streams

// Each car is emitted at its start pose: lane point at offset s0. The shader adds dir * (s - s0) for the time offset.
cars_build :: proc(p: ^Plan, seed: u32) -> Mesh_Builder {
	b: Mesh_Builder
	rng := rng_seed(seed ~ CAR_SEED_MIX)
	rng_u32(&rng) // first output of a near-zero xorshift state is weakly mixed
	for r in p.roads {
		along_z := r.z1 - r.z0 > r.x1 - r.x0
		lo, width := r.z0, r.z1 - r.z0
		if along_z do lo, width = r.x0, r.x1 - r.x0
		for lane in 0 ..< width {
			sign: f32 = 1 if lane < width / 2 else -1
			origin: f32 = 0 if sign > 0 else CAR_LANE_LENGTH
			across := f32(lo + lane) + 0.5
			speed := rng_range(&rng, CAR_SPEED_MIN, CAR_SPEED_MAX)
			s := rng_range(&rng, 0, CAR_GAP_MAX)
			for s < CAR_LANE_LENGTH {
				emit_car(&b, along_z, across, origin + sign * s, sign, s, speed)
				s += rng_range(&rng, CAR_GAP_MIN, CAR_GAP_MAX)
			}
		}
	}
	return b
}

// along: world coordinate of the car's start; s: distance travelled from the lane origin (uv.y).
emit_car :: proc(b: ^Mesh_Builder, along_z: bool, across, along, sign, s, speed: f32) {
	axis := Vec3{0, 0, 1} if along_z else Vec3{1, 0, 0}
	side := Vec3{1, 0, 0} if along_z else Vec3{0, 0, 1}
	dir := axis * sign
	centre := along * axis + across * side
	centre.y = CAR_LAMP_HEIGHT
	base := u32(len(b.vertices))
	corners := [4][2]f32{{-1, -1}, {1, -1}, {1, 1}, {-1, 1}}
	for k in ([2]f32{-1, 1}) {
		c := centre + side * (k * CAR_LAMP_OFFSET)
		for corner in corners {
			append(&b.vertices, gfx.VertexData{position = c, color = {corner.x, corner.y, 0, 1}, uv = {speed, s}, normal = {dir.x, 0, dir.z}})
		}
	}
	for q in u32(0) ..< 2 {
		i := base + 4 * q
		append(&b.indices, i, i + 1, i + 2, i, i + 2, i + 3)
	}
}

cars_pipeline_create :: proc(gfx_ctx: ^gfx.Device, state: ^City_State) -> gfx.Pipeline_Handle {
	attributes := shader_parameters.city_cars_vertex_attributes(gfx.VertexData)
	return gfx.pipeline_create(
		gfx_ctx,
		{
			vertex = shader_parameters.city_cars_vertex(),
			fragment = shader_parameters.city_cars_fragment(),
			vertex_attributes = attributes[:],
			vertex_stride = u32(size_of(gfx.VertexData)),
			depth_test = true,
			depth_write = false, // glows add into the scene and do not hide each other
			additive = true,
			cull_mode = .NONE, // billboards face the camera; either winding is fine
			bind_draw = cars_bind_draw,
			user_data = state,
		},
	)
}

cars_bind_draw :: proc(user_data: rawptr, draw_context: ^gfx.Draw_Context, parameters: gfx.Draw_Parameters) {
	state := cast(^City_State)user_data
	camera := parameters.camera_position
	uniforms := shader_parameters.CityCarsVertexUniforms {
		mvp             = parameters.view_projection * parameters.model_transform,
		camera_position = {camera.x, camera.y, camera.z, 1},
		time            = {state.time, 0, 0, 0},
	}
	gfx.draw_push_uniform(draw_context, shader_parameters.CITY_CARS_VERTEX_UNIFORM_BLOCK, &uniforms)
}

city_spawn_cars :: proc(state: ^City_State) {
	city_despawn_cars(state)
	b := cars_build(&state.plan, state.seed)
	state.cars = engine.spawn(&state.world, engine.Raw_Draw{mesh = builder_to_mesh_data(&b), material = &state.car_material})
	log.infof("city: %v cars, %v vertices", len(b.vertices) / CAR_VERTICES, len(b.vertices))
	builder_destroy(&b)
}

city_despawn_cars :: proc(state: ^City_State) {
	engine.world_destroy_actor(&state.world, state.cars)
}
