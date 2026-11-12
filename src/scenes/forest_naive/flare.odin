// Solar lens flare: a glow at the sun's screen position plus ghosts mirrored
// through the screen centre. Runs as an After_Scene overlay pass, so bloom
// also catches it. Quads are laid out in the tick (mesh uploads must happen
// outside a frame); the pass only draws.
package forest_naive

import "core:math"
import "core:math/linalg"
import gfx "../../engine/gfx"
import default "../../engine/default"
import sdl "vendor:sdl3"

FLARE_TEXTURE_SIZE :: 64
FLARE_MAX_QUADS :: 6

Flare :: struct {
	texture:  gfx.Texture_Handle,
	sampler:  gfx.Sampler_Handle,
	pipeline: gfx.Pipeline_Handle,
	material: gfx.Material,
	mesh:     gfx.Mesh,
	vertices: [dynamic]gfx.VertexData,
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

flare_create :: proc(gfx_ctx: ^gfx.Device, flare: ^Flare) {
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
	flare.texture = gfx.texture_create(gfx_ctx, FLARE_TEXTURE_SIZE, FLARE_TEXTURE_SIZE, .R8G8B8A8_UNORM, .SAMPLER)
	gfx.texture_get(gfx_ctx, flare.texture)._temporary_raw_data = pixels
	uploader := &gfx_ctx.renderer.uploader
	gfx.uploader_begin(uploader)
	gfx.uploader_upload_texture(uploader, flare.texture)
	gfx.uploader_flush_blocking(uploader)
	gfx.texture_get(gfx_ctx, flare.texture)._temporary_raw_data = nil

	flare.sampler = gfx.sampler_create(gfx_ctx, gfx.SAMPLER_LINEAR_CLAMP)
	flare.pipeline = default.create_textured_overlay_pipeline(gfx_ctx)
	flare.material = gfx.material_create(flare.pipeline)
	default.bind_textured_material(&flare.material, flare.texture, flare.sampler)
	dummy := [6]gfx.VertexData{}
	flare.mesh = gfx.mesh_create_unindexed(gfx_ctx, dummy[:])
	gfx.mesh_upload(&gfx_ctx.renderer, &flare.mesh)
	gfx.renderer_set_passes(&gfx_ctx.renderer, .After_Scene, []gfx.Render_Pass{{name = "flare", run = flare_draw, user = flare}})
}

flare_destroy :: proc(gfx_ctx: ^gfx.Device, flare: ^Flare) {
	gfx.renderer_clear_passes(&gfx_ctx.renderer, .After_Scene)
	gfx.mesh_destroy(gfx_ctx, &flare.mesh)
	gfx.material_destroy(&flare.material)
	gfx.pipeline_destroy(gfx_ctx, flare.pipeline)
	gfx.sampler_destroy(gfx_ctx, flare.sampler)
	gfx.texture_destroy(gfx_ctx, flare.texture)
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

flare_update :: proc(gfx_ctx: ^gfx.Device, flare: ^Flare, sun: [3]f32) {
	clear(&flare.vertices)
	flare.draw = false
	camera := gfx.camera(gfx_ctx)
	clip := gfx.camera_view_projection(camera) * [4]f32{camera.position.x + sun.x * 1000, camera.position.y + sun.y * 1000, camera.position.z + sun.z * 1000, 1}
	if clip.w > 0 && !flare_sun_blocked(camera.position, sun) {
		ndc := clip.xy / clip.w
		// Fade out as the sun leaves the screen.
		edge := max(abs(ndc.x), abs(ndc.y))
		fade := 1 - math.smoothstep(f32(0.7), f32(1.3), edge)
		if fade > 0 {
			flare.draw = true
			scale := f32(gfx_ctx.window_size.y) / 720
			size := [2]f32{f32(gfx_ctx.window_size.x), f32(gfx_ctx.window_size.y)}
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
					gfx.VertexData{position = p0, color = color, uv = {0, 0}},
					gfx.VertexData{position = p1, color = color, uv = {1, 0}},
					gfx.VertexData{position = p2, color = color, uv = {1, 1}},
					gfx.VertexData{position = p0, color = color, uv = {0, 0}},
					gfx.VertexData{position = p2, color = color, uv = {1, 1}},
					gfx.VertexData{position = p3, color = color, uv = {0, 1}},
				)
			}
			gfx.mesh_update_unindexed(&gfx_ctx.renderer, &flare.mesh, flare.vertices[:])
		}
	}
}

flare_draw :: proc(ctx: ^gfx.Pass_Ctx, user: rawptr) {
	flare := cast(^Flare)user
	if !flare.draw do return
	gfx_ctx := ctx.gfx_ctx
	gfx.renderer_begin_overlay_pass(ctx.renderer, ctx.color)
	pass := ctx.renderer.pass
	pipeline := gfx.pipeline_get(gfx_ctx, flare.pipeline)
	sdl.BindGPUGraphicsPipeline(pass, pipeline.handle)
	gfx.pipeline_bind_material(gfx_ctx, pass, gfx_ctx.command_buffer, &flare.material)
	gfx.pipeline_bind_draw(
		gfx_ctx,
		flare.pipeline,
		gfx_ctx.command_buffer,
		{
			view_projection = linalg.MATRIX4F32_IDENTITY,
			model_transform = linalg.MATRIX4F32_IDENTITY,
			material = &flare.material,
		},
	)
	vertex_buffer := gfx.buffer_get(gfx_ctx, flare.mesh.vertex_buffer)
	sdl.BindGPUVertexBuffers(pass, 0, &(sdl.GPUBufferBinding{buffer = vertex_buffer.handle}), 1)
	sdl.DrawGPUPrimitives(pass, u32(len(flare.vertices)), 1, 0, 0)
	gfx.renderer_end_pass(ctx.renderer)
}
