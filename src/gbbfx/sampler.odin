package gbbfx

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

Sampler :: struct {
	handle: ^sdl.GPUSampler,
}

gfx_sampler_create :: proc(
	gfx: ^Gfx,
	create_info := sdl.GPUSamplerCreateInfo{},
) -> Sampler_Handle {
	resource := Sampler {
		handle = sdl.CreateGPUSampler(gfx.gpu, create_info),
	}
	assert(resource.handle != nil)
	handle := Sampler_Handle(handle_pool_acquire(&gfx.sampler_handles))
	index := Resource_Handle(handle).index
	if int(index) == len(gfx.samplers) {
		append(&gfx.samplers, resource)
	} else {
		gfx.samplers[index] = resource
	}
	return handle
}

gfx_sampler_get :: proc(gfx: ^Gfx, handle: Sampler_Handle) -> ^Sampler {
	raw := Resource_Handle(handle)
	assert(handle_pool_contains(&gfx.sampler_handles, raw), "stale sampler handle")
	return &gfx.samplers[raw.index]
}

gfx_sampler_destroy :: proc(gfx: ^Gfx, handle: Sampler_Handle) {
	raw := Resource_Handle(handle)
	if !handle_pool_contains(&gfx.sampler_handles, raw) do return
	resource := &gfx.samplers[raw.index]
	if resource.handle != nil do sdl.ReleaseGPUSampler(gfx.gpu, resource.handle)
	resource^ = {}
	assert(handle_pool_release(&gfx.sampler_handles, raw))
}
