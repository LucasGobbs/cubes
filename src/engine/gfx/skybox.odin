package gfx

import "core:math/linalg"

// Owns everything a skybox needs: pipeline, panorama texture, sampler, the
// fullscreen triangle and its material. Submit skybox_draw() each frame; it
// draws on Render_Layer.SKYBOX behind all geometry.
Skybox :: struct {
	pipeline: Pipeline_Handle,
	texture:  Texture_Handle,
	sampler:  Sampler_Handle,
	mesh:     Mesh,
	material: Material,
}

// path: equirectangular (2:1) PNG/JPEG panorama, e.g. static/skybox/skybox-day.png.
@(private = "file")
skybox_create :: proc(gfx_ctx: ^Device, path: string) -> Skybox {
	skybox: Skybox
	attributes := default_skybox_vertex_attributes(VertexData)
	skybox.pipeline = pipeline_create(
		gfx_ctx,
		{
			vertex = default_skybox_vertex(),
			fragment = default_skybox_fragment(),
			vertex_attributes = attributes[:],
			vertex_stride = u32(size_of(VertexData)),
			depth_test = true,
			depth_write = false,
			depth_compare = .GREATER_OR_EQUAL, // sits exactly on the far plane
			bind_draw = bind_skybox_draw,
		},
	)
	skybox.texture = texture_load(gfx_ctx, path, mipmaps = false) // shader samples level 0
	skybox.sampler = sampler_create(
		gfx_ctx,
		{
			min_filter = .LINEAR,
			mag_filter = .LINEAR,
			address_mode_u = .REPEAT, // longitude wraps
			address_mode_v = .CLAMP_TO_EDGE, // poles do not
		},
	)

	// One triangle covering the whole screen in clip space.
	triangle := [3]VertexData {
		{position = {-1, -1, 0}, color = {1, 1, 1, 1}},
		{position = {3, -1, 0}, color = {1, 1, 1, 1}},
		{position = {-1, 3, 0}, color = {1, 1, 1, 1}},
	}
	skybox.mesh = mesh_create_unindexed(gfx_ctx, triangle[:])
	mesh_upload(&gfx_ctx.renderer, &skybox.mesh)

	skybox.material = material_create(skybox.pipeline)
	material_bind_texture(
		&skybox.material,
		DEFAULT_SKYBOX_FRAGMENT_TEX,
		DEFAULT_SKYBOX_FRAGMENT_TEX_SAMPLER,
		skybox.texture,
		skybox.sampler,
	)
	return skybox
}

// Submit each frame (e.g. in a Draw list). The transform is ignored by the shader.
@(private = "file")
skybox_draw :: proc(skybox: ^Skybox) -> Draw {
	return Draw{mesh = &skybox.mesh, material = &skybox.material, layer = .SKYBOX}
}

@(private = "file")
skybox_destroy :: proc(gfx_ctx: ^Device, skybox: ^Skybox) {
	mesh_destroy(gfx_ctx, &skybox.mesh)
	material_destroy(&skybox.material)
	texture_destroy(gfx_ctx, skybox.texture)
	sampler_destroy(gfx_ctx, skybox.sampler)
	pipeline_destroy(gfx_ctx, skybox.pipeline)
	skybox^ = {}
}

// Loads a panorama skybox owned by the open scope; draws it behind everything.
// path: equirectangular (2:1) PNG/JPEG, e.g. static/skybox/skybox-day.png.
skybox_add :: proc(gfx_ctx: ^Device, path: string) -> int {
	skybox := new(Skybox)
	skybox^ = skybox_create(gfx_ctx, path)
	scope_defer(gfx_ctx, skybox_release, skybox)
	return draw_add(gfx_ctx, skybox_draw(skybox))
}

@(private = "file")
skybox_release :: proc(gfx_ctx: ^Device, user: rawptr) {
	skybox := (^Skybox)(user)
	skybox_destroy(gfx_ctx, skybox)
	free(skybox)
}

bind_skybox_draw :: proc(
	user_data: rawptr,
	draw_context: ^Draw_Context,
	parameters: Draw_Parameters,
) {
	_ = user_data
	uniforms := DefaultSkyboxVertexUniformBlock {
		data = {inverse_view_projection = linalg.inverse(parameters.view_projection)},
	}
	draw_push_uniform(draw_context, DEFAULT_SKYBOX_VERTEX_UNIFORM_BLOCK, &uniforms)
}
