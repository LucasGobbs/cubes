package defaults

import gbbfx ".."
import "core:math/linalg"

// Owns everything a skybox needs: pipeline, panorama texture, sampler, the
// fullscreen triangle and its material. Add it to a scene with
// skybox_add_to_scene; it draws on Render_Layer.SKYBOX behind all geometry.
Skybox :: struct {
	pipeline: gbbfx.Pipeline_Handle,
	texture:  gbbfx.Texture_Handle,
	sampler:  gbbfx.Sampler_Handle,
	mesh:     gbbfx.Mesh,
	material: gbbfx.Material,
}

// path: equirectangular (2:1) PNG/JPEG panorama, e.g. static/skybox/skybox-day.png.
skybox_create :: proc(gfx: ^gbbfx.Gfx, path: string) -> Skybox {
	skybox: Skybox
	attributes := default_skybox_vertex_attributes(gbbfx.VertexData)
	skybox.pipeline = gbbfx.gfx_pipeline_create(
		gfx,
		{
			vertex = default_skybox_vertex(),
			fragment = default_skybox_fragment(),
			vertex_attributes = attributes[:],
			vertex_stride = u32(size_of(gbbfx.VertexData)),
			depth_test = true,
			depth_write = false,
			depth_compare = .GREATER_OR_EQUAL, // sits exactly on the far plane
			bind_draw = bind_skybox_draw,
		},
	)
	skybox.texture = gbbfx.gfx_texture_load(gfx, path)
	skybox.sampler = gbbfx.gfx_sampler_create(
		gfx,
		{
			min_filter = .LINEAR,
			mag_filter = .LINEAR,
			address_mode_u = .REPEAT, // longitude wraps
			address_mode_v = .CLAMP_TO_EDGE, // poles do not
		},
	)

	// One triangle covering the whole screen in clip space.
	triangle := [3]gbbfx.VertexData {
		{position = {-1, -1, 0}, color = {1, 1, 1, 1}},
		{position = {3, -1, 0}, color = {1, 1, 1, 1}},
		{position = {-1, 3, 0}, color = {1, 1, 1, 1}},
	}
	skybox.mesh = gbbfx.mesh_create_unindexed(gfx, triangle[:])
	gbbfx.mesh_upload(&gfx.renderer, &skybox.mesh)

	skybox.material = gbbfx.material_create(skybox.pipeline)
	gbbfx.material_bind_texture(
		&skybox.material,
		DEFAULT_SKYBOX_FRAGMENT_TEX,
		DEFAULT_SKYBOX_FRAGMENT_TEX_SAMPLER,
		skybox.texture,
		skybox.sampler,
	)
	return skybox
}

// Returns the entity index. The entity's transform is ignored by the shader.
skybox_add_to_scene :: proc(scene: ^gbbfx.Scene, skybox: ^Skybox) -> int {
	index := gbbfx.scene_add_entity(scene)
	gbbfx.entity_add_renderable(
		gbbfx.scene_entity(scene, index),
		&skybox.mesh,
		&skybox.material,
		.SKYBOX,
	)
	return index
}

skybox_destroy :: proc(gfx: ^gbbfx.Gfx, skybox: ^Skybox) {
	gbbfx.mesh_destroy(gfx, &skybox.mesh)
	gbbfx.material_destroy(&skybox.material)
	gbbfx.gfx_texture_destroy(gfx, skybox.texture)
	gbbfx.gfx_sampler_destroy(gfx, skybox.sampler)
	gbbfx.gfx_pipeline_destroy(gfx, skybox.pipeline)
	skybox^ = {}
}

bind_skybox_draw :: proc(
	user_data: rawptr,
	draw_context: ^gbbfx.Draw_Context,
	parameters: gbbfx.Draw_Parameters,
) {
	_ = user_data
	uniforms := DefaultSkyboxVertexUniformBlock {
		data = {inverse_view_projection = linalg.inverse(parameters.view_projection)},
	}
	gbbfx.draw_push_uniform(draw_context, DEFAULT_SKYBOX_VERTEX_UNIFORM_BLOCK, &uniforms)
}
