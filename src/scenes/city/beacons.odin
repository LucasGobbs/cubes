// Beacons and roof lights: the mesh from roof_lights.odin drawn as billboards (shaders/city_beacons.slang). The blink
// runs on the GPU from state.time, so the CPU does no per-frame work. Night view only.
package city

import engine "../../engine"
import gfx "../../engine/gfx"
import shader_parameters "../../shader_parameters"
import "core:log"

beacons_pipeline_create :: proc(gfx_ctx: ^gfx.Device, state: ^City_State) -> gfx.Pipeline_Handle {
	attributes := shader_parameters.city_beacons_vertex_attributes(gfx.VertexData)
	return gfx.light_sprite_pipeline_create(
		gfx_ctx,
		shader_parameters.city_beacons_vertex(),
		shader_parameters.city_beacons_fragment(),
		attributes[:],
		beacons_bind_draw,
		state,
	)
}

beacons_bind_draw :: proc(user_data: rawptr, draw_context: ^gfx.Draw_Context, parameters: gfx.Draw_Parameters) {
	state := cast(^City_State)user_data
	camera := parameters.camera_position
	uniforms := shader_parameters.CityBeaconsVertexUniforms {
		mvp             = parameters.view_projection * parameters.model_transform,
		camera_position = {camera.x, camera.y, camera.z, 1},
		time            = {state.time, 0, 0, 0},
		gain            = {1 - state.day.daylight, 0, 0, 0},
	}
	gfx.draw_push_uniform(draw_context, shader_parameters.CITY_BEACONS_VERTEX_UNIFORM_BLOCK, &uniforms)
}

city_spawn_beacons :: proc(state: ^City_State) {
	city_despawn_beacons(state)
	b, beacons := roof_lights_build(&state.plan, state.seed)
	state.beacons = engine.world_add_actor(&state.world, City_Draw{draw = engine.Raw_Draw{mesh = builder_to_mesh_data(&b), material = &state.beacon_material}})
	log.infof("city: %v beacons, %v roof lights", beacons, len(b.vertices) / 4 - beacons)
	builder_destroy(&b)
}

city_despawn_beacons :: proc(state: ^City_State) {
	if state.beacons != nil do engine.world_destroy_actor(&state.world, state.beacons.id)
	state.beacons = nil
}
