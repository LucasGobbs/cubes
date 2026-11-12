package gfx

import sdl "vendor:sdl3"

// Trilinear + 8x anisotropic, repeating: the default for mipmapped color
// textures (models, ground). The zero-value GPUSamplerCreateInfo is nearest /
// no mips, which suits pixel-exact data such as the font atlas.
SAMPLER_TRILINEAR :: sdl.GPUSamplerCreateInfo {
	min_filter        = .LINEAR,
	mag_filter        = .LINEAR,
	mipmap_mode       = .LINEAR,
	address_mode_u    = .REPEAT,
	address_mode_v    = .REPEAT,
	address_mode_w    = .REPEAT,
	enable_anisotropy = true,
	max_anisotropy    = 8,
	max_lod           = 1000, // zero would clamp sampling to mip 0
}

// Linear filtering with clamped edges, no mips: full-screen post-process reads.
SAMPLER_LINEAR_CLAMP :: sdl.GPUSamplerCreateInfo {
	min_filter     = .LINEAR,
	mag_filter     = .LINEAR,
	address_mode_u = .CLAMP_TO_EDGE,
	address_mode_v = .CLAMP_TO_EDGE,
	address_mode_w = .CLAMP_TO_EDGE,
}

// Nearest filtering with clamped edges, no mips: pixel-art sprites (2D batch).
SAMPLER_NEAREST_CLAMP :: sdl.GPUSamplerCreateInfo {
	address_mode_u = .CLAMP_TO_EDGE,
	address_mode_v = .CLAMP_TO_EDGE,
	address_mode_w = .CLAMP_TO_EDGE,
}

Sampler :: struct {
	handle: ^sdl.GPUSampler,
}

sampler_create :: proc(
	gfx_ctx: ^Device,
	create_info := sdl.GPUSamplerCreateInfo{},
) -> Sampler_Handle {
	resource := Sampler {
		handle = sdl.CreateGPUSampler(gfx_ctx.gpu, create_info),
	}
	assert(resource.handle != nil)
	handle := Sampler_Handle(handle_pool_acquire(&gfx_ctx.sampler_handles))
	index := Resource_Handle(handle).index
	if int(index) == len(gfx_ctx.samplers) {
		append(&gfx_ctx.samplers, resource)
	} else {
		gfx_ctx.samplers[index] = resource
	}
	return handle
}

sampler_get :: proc(gfx_ctx: ^Device, handle: Sampler_Handle) -> ^Sampler {
	raw := Resource_Handle(handle)
	assert(handle_pool_contains(&gfx_ctx.sampler_handles, raw), "stale sampler handle")
	return &gfx_ctx.samplers[raw.index]
}

sampler_destroy :: proc(gfx_ctx: ^Device, handle: Sampler_Handle) {
	raw := Resource_Handle(handle)
	if !handle_pool_contains(&gfx_ctx.sampler_handles, raw) do return
	resource := &gfx_ctx.samplers[raw.index]
	if resource.handle != nil do sdl.ReleaseGPUSampler(gfx_ctx.gpu, resource.handle)
	resource^ = {}
	assert(handle_pool_release(&gfx_ctx.sampler_handles, raw))
}
