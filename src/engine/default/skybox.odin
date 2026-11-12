package default

import gfx "../gfx"
import "core:math/linalg"

// Owns everything a skybox needs: pipeline, panorama texture, sampler, the
// fullscreen triangle and its material. Add it to a scene with
// skybox_add_to_scene; it draws on Render_Layer.SKYBOX behind all geometry.
Skybox :: struct {
	pipeline: gfx.Pipeline_Handle,
	texture:  gfx.Texture_Handle,
	sampler:  gfx.Sampler_Handle,
	mesh:     gfx.Mesh,
	material: gfx.Material,
}

// path: equirectangular (2:1) PNG/JPEG panorama, e.g. static/skybox/skybox-day.png.
skybox_create :: proc(dev: ^gfx.Device, path: string) -> Skybox {
	skybox: Skybox
	attributes := default_skybox_vertex_attributes(gfx.VertexData)
	skybox.pipeline = gfx.pipeline_create(
		dev,
		{
			vertex = default_skybox_vertex(),
			fragment = default_skybox_fragment(),
			vertex_attributes = attributes[:],
			vertex_stride = u32(size_of(gfx.VertexData)),
			depth_test = true,
			depth_write = false,
			depth_compare = .GREATER_OR_EQUAL, // sits exactly on the far plane
			bind_draw = bind_skybox_draw,
		},
	)
	skybox.texture = gfx.texture_load(dev, path, mipmaps = false) // shader samples level 0
	skybox.sampler = gfx.sampler_create(
		dev,
		{
			min_filter = .LINEAR,
			mag_filter = .LINEAR,
			address_mode_u = .REPEAT, // longitude wraps
			address_mode_v = .CLAMP_TO_EDGE, // poles do not
		},
	)

	// One triangle covering the whole screen in clip space.
	triangle := [3]gfx.VertexData {
		{position = {-1, -1, 0}, color = {1, 1, 1, 1}},
		{position = {3, -1, 0}, color = {1, 1, 1, 1}},
		{position = {-1, 3, 0}, color = {1, 1, 1, 1}},
	}
	skybox.mesh = gfx.mesh_create_unindexed(dev, triangle[:])
	gfx.mesh_upload(&dev.renderer, &skybox.mesh)

	skybox.material = gfx.material_create(skybox.pipeline)
	gfx.material_bind_texture(
		&skybox.material,
		DEFAULT_SKYBOX_FRAGMENT_TEX,
		DEFAULT_SKYBOX_FRAGMENT_TEX_SAMPLER,
		skybox.texture,
		skybox.sampler,
	)
	return skybox
}

// Returns the entity index. The entity's transform is ignored by the shader.
skybox_add_to_scene :: proc(scene: ^gfx.Scene, skybox: ^Skybox) -> int {
	index := gfx.scene_add_entity(scene)
	gfx.entity_add_renderable(
		gfx.scene_entity(scene, index),
		&skybox.mesh,
		&skybox.material,
		.SKYBOX,
	)
	return index
}

skybox_destroy :: proc(dev: ^gfx.Device, skybox: ^Skybox) {
	gfx.mesh_destroy(dev, &skybox.mesh)
	gfx.material_destroy(&skybox.material)
	gfx.texture_destroy(dev, skybox.texture)
	gfx.sampler_destroy(dev, skybox.sampler)
	gfx.pipeline_destroy(dev, skybox.pipeline)
	skybox^ = {}
}

bind_skybox_draw :: proc(
	user_data: rawptr,
	draw_context: ^gfx.Draw_Context,
	parameters: gfx.Draw_Parameters,
) {
	_ = user_data
	uniforms := DefaultSkyboxVertexUniformBlock {
		data = {inverse_view_projection = linalg.inverse(parameters.view_projection)},
	}
	gfx.draw_push_uniform(draw_context, DEFAULT_SKYBOX_VERTEX_UNIFORM_BLOCK, &uniforms)
}
