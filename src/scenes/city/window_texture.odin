// Window atlas: a compute pass writes the 3072x3072 texture of 6x6 tiles that the buildings sample.
package city

import gfx "../../engine/gfx"
import shader_parameters "../../shader_parameters"
import "core:mem"
import sdl "vendor:sdl3"

WINDOW_PX :: 8 // one window in the atlas, see shaders/city_windows.slang
TILE_PX :: 512
TILE_COUNT_SIDE :: 6 // shaders/city.slang decodes the tile from this value, keep in step
TILE_COUNT :: TILE_COUNT_SIDE * TILE_COUNT_SIDE
TILE_WINDOWS :: TILE_PX / WINDOW_PX // windows per tile side: uv of one window is 1 / TILE_WINDOWS
ATLAS_SIZE :: TILE_COUNT_SIDE * TILE_PX

// Mips for the far field (windows average to a colour instead of shimmering). Mag stays NEAREST so near
// windows keep their 8 px blocks. max_lod 5 = 32 texels = 4x4 windows: tiles are 16 such blocks, so the
// clamp stops colour bleeding between tiles at coarse levels.
WINDOW_SAMPLER :: sdl.GPUSamplerCreateInfo {
	min_filter        = .LINEAR,
	mag_filter        = .NEAREST,
	mipmap_mode       = .LINEAR,
	address_mode_u    = .REPEAT,
	address_mode_v    = .REPEAT,
	address_mode_w    = .REPEAT,
	enable_anisotropy = true,
	max_anisotropy    = 8,
	max_lod           = 5,
}

Window_Texture :: struct {
	pipeline: gfx.Compute_Pipeline_Handle,
	texture:  gfx.Texture_Handle,
}

window_texture_create :: proc(gfx_ctx: ^gfx.Device) -> Window_Texture {
	return {
		pipeline = gfx.compute_pipeline_create(gfx_ctx, shader_parameters.city_windows_compute()),
		texture = gfx.texture_create_storage(gfx_ctx, ATLAS_SIZE, ATLAS_SIZE),
	}
}

// Must run outside a render pass with the frame open (scene before-hook).
window_texture_generate :: proc(gfx_ctx: ^gfx.Device, window: ^Window_Texture, seed: u32) {
	params := shader_parameters.CityWindowsComputeWindowParams{seed = seed}
	groups := ATLAS_SIZE / shader_parameters.CITY_WINDOWS_COMPUTE_THREAD_COUNT.x
	gfx.compute_dispatch(
		gfx_ctx,
		window.pipeline,
		{window.texture},
		nil,
		{},
		{groups, groups, 1},
		mem.ptr_to_bytes(&params),
	)
	gfx.texture_generate_mips(gfx_ctx, window.texture)
}

window_texture_destroy :: proc(gfx_ctx: ^gfx.Device, window: ^Window_Texture) {
	gfx.compute_pipeline_destroy(gfx_ctx, window.pipeline)
	gfx.texture_destroy(gfx_ctx, window.texture)
	window^ = {}
}
