// Window atlas: a compute pass writes the 512x512 lit/dark texture the buildings sample.
package city

import gfx "../../engine/gfx"
import shader_parameters "../../shader_parameters"
import "core:mem"
import sdl "vendor:sdl3"

WINDOW_TEXTURE_SIZE :: 512

WINDOW_SAMPLER :: sdl.GPUSamplerCreateInfo {
	min_filter     = .NEAREST,
	mag_filter     = .NEAREST,
	address_mode_u = .REPEAT,
	address_mode_v = .REPEAT,
	address_mode_w = .REPEAT,
}

Window_Texture :: struct {
	pipeline: gfx.Compute_Pipeline_Handle,
	texture:  gfx.Texture_Handle,
}

window_texture_create :: proc(gfx_ctx: ^gfx.Device) -> Window_Texture {
	return {
		pipeline = gfx.compute_pipeline_create(gfx_ctx, shader_parameters.city_windows_compute()),
		texture = gfx.texture_create_with_usage(
			gfx_ctx,
			WINDOW_TEXTURE_SIZE,
			WINDOW_TEXTURE_SIZE,
			.R8G8B8A8_UNORM,
			{.SAMPLER, .COMPUTE_STORAGE_WRITE},
		),
	}
}

// Must run outside a render pass with the frame open (scene before-hook).
window_texture_generate :: proc(gfx_ctx: ^gfx.Device, window: ^Window_Texture, seed: u32) {
	params := shader_parameters.CityWindowsComputeWindowParams{seed = seed}
	groups := WINDOW_TEXTURE_SIZE / shader_parameters.CITY_WINDOWS_COMPUTE_THREAD_COUNT.x
	gfx.compute_dispatch(
		gfx_ctx,
		window.pipeline,
		{window.texture},
		nil,
		{},
		{groups, groups, 1},
		mem.ptr_to_bytes(&params),
	)
}

window_texture_destroy :: proc(gfx_ctx: ^gfx.Device, window: ^Window_Texture) {
	gfx.compute_pipeline_destroy(gfx_ctx, window.pipeline)
	gfx.texture_destroy(gfx_ctx, window.texture)
	window^ = {}
}
