package default

import gfx "../gfx"

// Restores the camera and the offscreen targets to full-window defaults;
// demos call this in create because the editor demo shrinks both to its
// viewport widget.
camera_reset :: proc(gfx_ctx: ^gfx.Device, position := gfx.Vec3{0, 0, 3}, target := gfx.Vec3{}) {
	camera := gfx.camera(gfx_ctx)
	camera^ = gfx.camera_create(
		position = position,
		target = target,
		projection = gfx.camera_perspective(gfx.aspect_ratio(gfx_ctx)),
	)
	gfx.renderer_resize_targets(&gfx_ctx.renderer, u32(gfx_ctx.window_size.x), u32(gfx_ctx.window_size.y))
}
