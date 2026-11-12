package gfx

// Restores the camera and the offscreen targets to full-window defaults;
// demos call this in create because the editor demo shrinks both to its
// viewport widget.
camera_reset :: proc(gfx_ctx: ^Device, position := Vec3{0, 0, 3}, target := Vec3{}) {
	cam := camera(gfx_ctx)
	cam^ = camera_create(
		position = position,
		target = target,
		projection = camera_perspective(aspect_ratio(gfx_ctx)),
	)
	renderer_resize_targets(&gfx_ctx.renderer, u32(gfx_ctx.window_size.x), u32(gfx_ctx.window_size.y))
}
