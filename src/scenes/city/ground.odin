// Street ground: a compute pass paints the road plan into a CITY_W x CITY_D texture (1 texel = 1 unit) under the whole city.
// The plan reaches the GPU as one bit per cell in a read-only storage buffer. The night view draws one quad with it.
package city

import engine "../../engine"
import gfx "../../engine/gfx"
import shader_parameters "../../shader_parameters"
import sdl "vendor:sdl3"

GROUND_Y :: -0.02 // just under the buildings' floor and the streets' ROAD_HEIGHT; the quad is never seen from below
GROUND_MARGIN :: 60000 // the quad reaches this far past the city on every side (far beyond the sky dome); uv outside 0..1 is dark outskirts
GROUND_MASK_WORDS :: CITY_CELLS / 32
// Trilinear + 8x aniso: lanes (1 texel) fade to an average at a distance instead of shimmering.
GROUND_SAMPLER :: sdl.GPUSamplerCreateInfo {
	min_filter        = .LINEAR,
	mag_filter        = .LINEAR,
	mipmap_mode       = .LINEAR,
	address_mode_u    = .CLAMP_TO_EDGE,
	address_mode_v    = .CLAMP_TO_EDGE,
	address_mode_w    = .CLAMP_TO_EDGE,
	enable_anisotropy = true,
	max_anisotropy    = 8,
	max_lod           = 1000,
}

Ground_Texture :: struct {
	pipeline: gfx.Compute_Pipeline_Handle,
	texture:  gfx.Texture_Handle,
	mask:     gfx.Buffer_Handle, // packed road bits, read by the compute pass
}

// One bit per cell, row-major by z, to match Plan.claimed. Bit set = road.
ground_pack_roads :: proc(claimed: []u8) -> []u32 {
	words := make([]u32, GROUND_MASK_WORDS)
	for c, i in claimed {
		if c == CLAIM_ROAD do words[i >> 5] |= u32(1) << u32(i & 31)
	}
	return words
}

ground_texture_create :: proc(gfx_ctx: ^gfx.Device) -> Ground_Texture {
	return {
		pipeline = gfx.compute_pipeline_create(gfx_ctx, shader_parameters.city_ground_gen_compute()),
		texture = gfx.texture_create_storage(gfx_ctx, CITY_W, CITY_D),
		mask = gfx.buffer_create(gfx_ctx, u32(GROUND_MASK_WORDS * size_of(u32)), .COMPUTE_STORAGE_READ),
	}
}

ground_texture_destroy :: proc(gfx_ctx: ^gfx.Device, ground: ^Ground_Texture) {
	gfx.compute_pipeline_destroy(gfx_ctx, ground.pipeline)
	gfx.texture_destroy(gfx_ctx, ground.texture)
	gfx.buffer_destroy(gfx_ctx, ground.mask)
	ground^ = {}
}

// Stages the road mask and uploads it now; the GPU copy is done before this frame's compute pass.
ground_upload_roads :: proc(renderer: ^gfx.Renderer, ground: ^Ground_Texture, claimed: []u8) {
	packed := ground_pack_roads(claimed)
	defer delete(packed)
	ground.mask = gfx.buffer_stage(renderer.gfx_ctx, ground.mask, packed, .COMPUTE_STORAGE_READ)
	gfx.uploader_begin(&renderer.uploader)
	gfx.uploader_upload_buffer(&renderer.uploader, ground.mask)
	gfx.uploader_flush(&renderer.uploader)
	gfx.buffer_get(renderer.gfx_ctx, ground.mask)._temporary_raw_data = nil
}

// Must run outside a render pass with the frame open (scene before-hook).
ground_texture_generate :: proc(gfx_ctx: ^gfx.Device, ground: ^Ground_Texture) {
	gfx.compute_dispatch(
		gfx_ctx,
		ground.pipeline,
		{ground.texture},
		nil,
		{},
		{CITY_W / shader_parameters.CITY_GROUND_GEN_COMPUTE_THREAD_COUNT.x, CITY_D / shader_parameters.CITY_GROUND_GEN_COMPUTE_THREAD_COUNT.y, 1},
		nil,
		{ground.mask},
	)
	gfx.texture_generate_mips(gfx_ctx, ground.texture)
}

ground_pipeline_create :: proc(gfx_ctx: ^gfx.Device) -> gfx.Pipeline_Handle {
	attributes := shader_parameters.city_ground_vertex_attributes(gfx.VertexData)
	return gfx.pipeline_create(
		gfx_ctx,
		{
			vertex = shader_parameters.city_ground_vertex(),
			fragment = shader_parameters.city_ground_fragment(),
			vertex_attributes = attributes[:],
			vertex_stride = u32(size_of(gfx.VertexData)),
			depth_test = true,
			depth_write = true,
			cull_mode = .NONE, // one plane; winding not worth matching
			bind_draw = ground_bind_draw,
		},
	)
}

ground_bind_draw :: proc(user_data: rawptr, draw_context: ^gfx.Draw_Context, parameters: gfx.Draw_Parameters) {
	camera := parameters.camera_position
	uniforms := shader_parameters.CityGroundVertexUniforms {
		mvp             = parameters.view_projection * parameters.model_transform,
		camera_position = {camera.x, camera.y, camera.z, 1},
		fog             = parameters.fog,
	}
	gfx.draw_push_uniform(draw_context, shader_parameters.CITY_GROUND_VERTEX_UNIFORM_BLOCK, &uniforms)
}

// The city plus GROUND_MARGIN on every side as one quad; uv = world / city size, so the texture covers 0..1.
ground_build_mesh :: proc() -> Mesh_Builder {
	b: Mesh_Builder
	sx, sz := f32(CITY_W), f32(CITY_D)
	lo_x, hi_x := -f32(GROUND_MARGIN), sx + f32(GROUND_MARGIN)
	lo_z, hi_z := -f32(GROUND_MARGIN), sz + f32(GROUND_MARGIN)
	builder_quad(&b, {lo_x, GROUND_Y, lo_z}, {lo_x, GROUND_Y, hi_z}, {hi_x, GROUND_Y, hi_z}, {hi_x, GROUND_Y, lo_z}, {lo_x / sx, lo_z / sz}, {hi_x / sx, hi_z / sz}, {1, 1, 1, 1})
	return b
}

// Night view only: the dev view is the flat street overlay on the clear colour.
city_spawn_ground :: proc(state: ^City_State) {
	b := ground_build_mesh()
	state.ground_draw = engine.spawn(&state.world, engine.Raw_Draw{mesh = builder_to_mesh_data(&b), material = &state.ground_material})
	builder_destroy(&b)
}

city_despawn_ground :: proc(state: ^City_State) {
	engine.world_destroy_actor(&state.world, state.ground_draw)
}
