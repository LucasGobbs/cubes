// Solar lens flare: a glow at the sun's screen position plus ghosts mirrored
// through the screen centre. Runs as an After_Scene overlay pass, so bloom
// also catches it. Quads are laid out in the tick (mesh uploads must happen
// outside a frame); the pass only draws.
package forest_naive

import "core:math"
import "core:math/linalg"
import gbbfx "../../gbbfx"
import defaults "../../gbbfx/defaults"
import sdl "vendor:sdl3"

FLARE_TEXTURE_SIZE :: 64
FLARE_MAX_QUADS :: 6

Flare :: struct {
	texture:  gbbfx.Texture_Handle,
	sampler:  gbbfx.Sampler_Handle,
	pipeline: gbbfx.Pipeline_Handle,
	material: gbbfx.Material,
	mesh:     gbbfx.Mesh,
	vertices: [dynamic]gbbfx.VertexData,
	draw:     bool,
}

// Ghost = position along the sun->centre axis (1 = sun, -1 = mirrored), size in
// pixels at 720p height, tint, strength.
FLARE_GHOSTS :: [FLARE_MAX_QUADS]struct {
	axis, size, strength: f32,
	tint:                 [3]f32,
} {
	{1.0, 900, 0.55, {1.0, 0.9, 0.65}},
	{1.0, 260, 0.9, {1.0, 0.97, 0.85}},
	{0.45, 90, 0.25, {0.6, 0.8, 1.0}},
	{-0.35, 150, 0.2, {1.0, 0.75, 0.4}},
	{-0.8, 60, 0.3, {0.7, 1.0, 0.7}},
	{-1.3, 220, 0.15, {0.6, 0.7, 1.0}},
}

flare_create :: proc(dev: ^gbbfx.Device, flare: ^Flare) {
	// Radial falloff, alpha only meaningful: white rgb with smooth alpha.
	pixels := make([]u8, FLARE_TEXTURE_SIZE * FLARE_TEXTURE_SIZE * 4, context.temp_allocator)
	for y in 0 ..< FLARE_TEXTURE_SIZE {
		for x in 0 ..< FLARE_TEXTURE_SIZE {
			dx := (f32(x) + 0.5) / FLARE_TEXTURE_SIZE * 2 - 1
			dy := (f32(y) + 0.5) / FLARE_TEXTURE_SIZE * 2 - 1
			falloff := max(0, 1 - math.sqrt(dx * dx + dy * dy))
			alpha := falloff * falloff * (3 - 2 * falloff)
			i := (y * FLARE_TEXTURE_SIZE + x) * 4
			pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3] = 255, 255, 255, u8(alpha * 255)
		}
	}
	flare.texture = gbbfx.gfx_texture_create(dev, FLARE_TEXTURE_SIZE, FLARE_TEXTURE_SIZE, .R8G8B8A8_UNORM, .SAMPLER)
	gbbfx.gfx_texture_get(dev, flare.texture)._temporary_raw_data = pixels
	uploader := &dev.renderer.uploader
	gbbfx.uploader_begin(uploader)
	gbbfx.uploader_upload_texture(uploader, flare.texture)
	gbbfx.uploader_flush_blocking(uploader)
	gbbfx.gfx_texture_get(dev, flare.texture)._temporary_raw_data = nil

	flare.sampler = gbbfx.gfx_sampler_create(dev, gbbfx.SAMPLER_LINEAR_CLAMP)
	flare.pipeline = defaults.create_textured_overlay_pipeline(dev)
	flare.material = gbbfx.material_create(flare.pipeline)
	defaults.bind_textured_material(&flare.material, flare.texture, flare.sampler)
	dummy := [6]gbbfx.VertexData{}
	flare.mesh = gbbfx.mesh_create_unindexed(dev, dummy[:])
	gbbfx.mesh_upload(&dev.renderer, &flare.mesh)
	gbbfx.renderer_set_passes(&dev.renderer, .After_Scene, []gbbfx.Render_Pass{{name = "flare", run = flare_draw, user = flare}})
}

flare_destroy :: proc(dev: ^gbbfx.Device, flare: ^Flare) {
	gbbfx.renderer_clear_passes(&dev.renderer, .After_Scene)
	gbbfx.mesh_destroy(dev, &flare.mesh)
	gbbfx.material_destroy(&flare.material)
	gbbfx.gfx_pipeline_destroy(dev, flare.pipeline)
	gbbfx.gfx_sampler_destroy(dev, flare.sampler)
	gbbfx.gfx_texture_destroy(dev, flare.texture)
	delete(flare.vertices)
}

// True when terrain between the camera and the sun blocks it. Coarse march:
// trees do not occlude (they are baked per chunk and not sampled here).
flare_sun_blocked :: proc(origin, sun: [3]f32) -> bool {
	for step in 1 ..= 48 {
		distance := f32(step) * 8
		p := origin + sun * distance
		if p.y < terrain_height(p.x, p.z) do return true
	}
	return false
}

flare_update :: proc(dev: ^gbbfx.Device, flare: ^Flare, sun: [3]f32) {
	clear(&flare.vertices)
	flare.draw = false
	camera := gbbfx.gfx_camera(dev)
	clip := gbbfx.camera_view_projection(camera) * [4]f32{camera.position.x + sun.x * 1000, camera.position.y + sun.y * 1000, camera.position.z + sun.z * 1000, 1}
	if clip.w > 0 && !flare_sun_blocked(camera.position, sun) {
		ndc := clip.xy / clip.w
		// Fade out as the sun leaves the screen.
		edge := max(abs(ndc.x), abs(ndc.y))
		fade := 1 - math.smoothstep(f32(0.7), f32(1.3), edge)
		if fade > 0 {
			flare.draw = true
			scale := f32(dev.window_size.y) / 720
			size := [2]f32{f32(dev.window_size.x), f32(dev.window_size.y)}
			for ghost in FLARE_GHOSTS {
				center := ndc * ghost.axis
				half := [2]f32{ghost.size * scale / size.x, ghost.size * scale / size.y} // ndc half extent = size/2 * 2/dim
				color := [4]f32{ghost.tint.r, ghost.tint.g, ghost.tint.b, ghost.strength * fade}
				p0 := [3]f32{center.x - half.x, center.y + half.y, 0}
				p1 := [3]f32{center.x + half.x, center.y + half.y, 0}
				p2 := [3]f32{center.x + half.x, center.y - half.y, 0}
				p3 := [3]f32{center.x - half.x, center.y - half.y, 0}
				append(
					&flare.vertices,
					gbbfx.VertexData{position = p0, color = color, uv = {0, 0}},
					gbbfx.VertexData{position = p1, color = color, uv = {1, 0}},
					gbbfx.VertexData{position = p2, color = color, uv = {1, 1}},
					gbbfx.VertexData{position = p0, color = color, uv = {0, 0}},
					gbbfx.VertexData{position = p2, color = color, uv = {1, 1}},
					gbbfx.VertexData{position = p3, color = color, uv = {0, 1}},
				)
			}
			gbbfx.mesh_update_unindexed(&dev.renderer, &flare.mesh, flare.vertices[:])
		}
	}
}

flare_draw :: proc(ctx: ^gbbfx.Pass_Ctx, user: rawptr) {
	flare := cast(^Flare)user
	if !flare.draw do return
	dev := ctx.dev
	gbbfx.renderer_begin_overlay_pass(ctx.renderer, ctx.color)
	pass := ctx.renderer.pass
	pipeline := gbbfx.gfx_pipeline_get(dev, flare.pipeline)
	sdl.BindGPUGraphicsPipeline(pass, pipeline.handle)
	gbbfx.gfx_pipeline_bind_material(dev, pass, dev.command_buffer, &flare.material)
	gbbfx.gfx_pipeline_bind_draw(
		dev,
		flare.pipeline,
		dev.command_buffer,
		{
			view_projection = linalg.MATRIX4F32_IDENTITY,
			model_transform = linalg.MATRIX4F32_IDENTITY,
			material = &flare.material,
		},
	)
	vertex_buffer := gbbfx.gfx_buffer_get(dev, flare.mesh.vertex_buffer)
	sdl.BindGPUVertexBuffers(pass, 0, &(sdl.GPUBufferBinding{buffer = vertex_buffer.handle}), 1)
	sdl.DrawGPUPrimitives(pass, u32(len(flare.vertices)), 1, 0, 0)
	gbbfx.renderer_end_pass(ctx.renderer)
}
