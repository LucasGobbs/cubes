// Night sky: a compute pass writes the sky texture (gradient, stars, clouds); an open cylinder around the camera
// samples it. Texture u is the angle around the cylinder (tiles), v is height (row 0 zenith, last row horizon).
package city

import engine "../../engine"
import gfx "../../engine/gfx"
import shader_parameters "../../shader_parameters"
import "core:math"
import "core:math/linalg"
import "core:mem"
import sdl "vendor:sdl3"

SKY_SEGMENTS :: 64
SKY_RADIUS :: 3500 // beyond the city and the sun shadow box; the far plane is infinite (reverse-Z)
SKY_DROP :: 150 // the horizon glow sits this far below eye level; the ground is dropped past 3300 units so this part of the sky shows under the horizon
SKY_BOTTOM :: -1500 // below eye level: the lampshade has no floor; it fades to dark blue-grey so no void shows
SKY_TOP :: 1800
SKY_ABOVE :: 30000 // zenith row stretched far up so the flat cap is never in view

SKY_SAMPLER :: sdl.GPUSamplerCreateInfo {
	min_filter     = .LINEAR,
	mag_filter     = .LINEAR,
	address_mode_u = .REPEAT,
	address_mode_v = .CLAMP_TO_EDGE,
	address_mode_w = .REPEAT,
}

Sky_Texture :: struct {
	pipeline: gfx.Compute_Pipeline_Handle,
	texture:  gfx.Texture_Handle,
}

sky_texture_create :: proc(gfx_ctx: ^gfx.Device) -> Sky_Texture {
	return {
		pipeline = gfx.compute_pipeline_create(gfx_ctx, shader_parameters.city_sky_gen_compute()),
		texture = gfx.texture_create_with_usage(gfx_ctx, SKY_W, SKY_H, .R8G8B8A8_UNORM, {.SAMPLER, .COMPUTE_STORAGE_WRITE}),
	}
}

// Must run outside a render pass with the frame open (scene before-hook).
sky_texture_generate :: proc(gfx_ctx: ^gfx.Device, sky: ^Sky_Texture, seed: u32) {
	params := shader_parameters.CitySkyGenComputeSkyParams{seed = seed}
	gfx.compute_dispatch(
		gfx_ctx,
		sky.pipeline,
		{sky.texture},
		nil,
		{},
		{SKY_W / shader_parameters.CITY_SKY_GEN_COMPUTE_THREAD_COUNT.x, SKY_H / shader_parameters.CITY_SKY_GEN_COMPUTE_THREAD_COUNT.y, 1},
		mem.ptr_to_bytes(&params),
	)
}

sky_texture_destroy :: proc(gfx_ctx: ^gfx.Device, sky: ^Sky_Texture) {
	gfx.compute_pipeline_destroy(gfx_ctx, sky.pipeline)
	gfx.texture_destroy(gfx_ctx, sky.texture)
	sky^ = {}
}

sky_pipeline_create :: proc(gfx_ctx: ^gfx.Device) -> gfx.Pipeline_Handle {
	attributes := shader_parameters.city_sky_vertex_attributes(gfx.VertexData)
	return gfx.pipeline_create(
		gfx_ctx,
		{
			vertex = shader_parameters.city_sky_vertex(),
			fragment = shader_parameters.city_sky_fragment(),
			vertex_attributes = attributes[:],
			vertex_stride = u32(size_of(gfx.VertexData)),
			depth_test = true,
			depth_write = false, // drawn first in spirit: never occludes the city
			cull_mode = .NONE, // the cap and walls are seen from inside
			bind_draw = sky_bind_draw,
		},
	)
}

// The lampshade follows the camera, so the horizon stays at eye level and at infinity.
sky_bind_draw :: proc(user_data: rawptr, draw_context: ^gfx.Draw_Context, parameters: gfx.Draw_Parameters) {
	c := parameters.camera_position
	uniforms := shader_parameters.CitySkyVertexUniforms {
		mvp = parameters.view_projection * linalg.matrix4_translate_f32({c.x, c.y, c.z}) * parameters.model_transform,
	}
	gfx.draw_push_uniform(draw_context, shader_parameters.CITY_SKY_VERTEX_UNIFORM_BLOCK, &uniforms)
}

// Open cylinder (rings: bottom fading to black, horizon, top, far above) plus a flat cap on the last ring.
sky_build_mesh :: proc() -> Mesh_Builder {
	b: Mesh_Builder
	rings := [4]struct {
		y, v, shade: f32,
	}{{SKY_BOTTOM, 1, 0}, {-SKY_DROP, 1, 1}, {SKY_TOP, 0, 1}, {SKY_ABOVE, 0, 1}}
	white := [4]f32{1, 1, 1, 1}
	for ring in rings {
		for i in 0 ..= SKY_SEGMENTS {
			t := f32(i) / SKY_SEGMENTS
			a := t * 2 * math.PI
			append(&b.vertices, gfx.VertexData{position = {SKY_RADIUS * math.cos(a), ring.y, SKY_RADIUS * math.sin(a)}, color = {ring.shade, ring.shade, ring.shade, 1}, uv = {t, ring.v}, normal = {-math.cos(a), 0, -math.sin(a)}})
		}
	}
	ring_index :: proc(row, i: u32) -> u32 {return row * (SKY_SEGMENTS + 1) + i}
	for row in u32(0) ..< 3 {
		for i in u32(0) ..< SKY_SEGMENTS {
			p0, p1 := ring_index(row, i), ring_index(row, i + 1)
			p2, p3 := ring_index(row + 1, i + 1), ring_index(row + 1, i)
			append(&b.indices, p0, p1, p2, p0, p2, p3)
		}
	}

	// Cap: fan from the centre over the top ring (row 3). Centre samples the zenith row at u = 0.5.
	centre := u32(len(b.vertices))
	append(&b.vertices, gfx.VertexData{position = {0, SKY_ABOVE, 0}, color = white, uv = {0.5, 0}, normal = {0, -1, 0}})
	for i in u32(0) ..< SKY_SEGMENTS {
		append(&b.indices, centre, ring_index(3, i), ring_index(3, i + 1))
	}
	return b
}

// Spawns the sky cylinder (replaces any existing one). Night view only.
city_spawn_sky :: proc(state: ^City_State) {
	city_despawn_sky(state)
	b := sky_build_mesh()
	state.sky = engine.world_add_actor(&state.world, City_Draw{draw = engine.Raw_Draw{mesh = builder_to_mesh_data(&b), material = &state.sky_material}})
	builder_destroy(&b)
}

city_despawn_sky :: proc(state: ^City_State) {
	if state.sky != nil do engine.world_destroy_actor(&state.world, state.sky.id)
	state.sky = nil
}
