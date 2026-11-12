package default

import gfx "../gfx"
import "core:math/linalg"

// Owns everything a skybox needs: pipeline, panorama texture, sampler, the
// fullscreen triangle and its material. Submit skybox_draw() each frame; it
// draws on Render_Layer.SKYBOX behind all geometry.
Skybox :: struct {
	pipeline: gfx.Pipeline_Handle,
	texture:  gfx.Texture_Handle,
	sampler:  gfx.Sampler_Handle,
	mesh:     gfx.Mesh,
	material: gfx.Material,
}

// path: equirectangular (2:1) PNG/JPEG panorama, e.g. static/skybox/skybox-day.png.
skybox_create :: proc(gfx_ctx: ^gfx.Device, path: string) -> Skybox {
	skybox: Skybox
	attributes := default_skybox_vertex_attributes(gfx.VertexData)
	skybox.pipeline = gfx.pipeline_create(
		gfx_ctx,
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
	skybox.texture = gfx.texture_load(gfx_ctx, path, mipmaps = false) // shader samples level 0
	skybox.sampler = gfx.sampler_create(
		gfx_ctx,
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
	skybox.mesh = gfx.mesh_create_unindexed(gfx_ctx, triangle[:])
	gfx.mesh_upload(&gfx_ctx.renderer, &skybox.mesh)

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

// Submit each frame (e.g. in a Draw list). The transform is ignored by the shader.
skybox_draw :: proc(skybox: ^Skybox) -> gfx.Draw {
	return gfx.Draw{mesh = &skybox.mesh, material = &skybox.material, layer = .SKYBOX}
}

skybox_destroy :: proc(gfx_ctx: ^gfx.Device, skybox: ^Skybox) {
	gfx.mesh_destroy(gfx_ctx, &skybox.mesh)
	gfx.material_destroy(&skybox.material)
	gfx.texture_destroy(gfx_ctx, skybox.texture)
	gfx.sampler_destroy(gfx_ctx, skybox.sampler)
	gfx.pipeline_destroy(gfx_ctx, skybox.pipeline)
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
