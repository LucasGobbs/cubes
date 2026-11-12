package gfx

import loader "loader"
import sdl "vendor:sdl3"

Texture :: struct {
	handle:              ^sdl.GPUTexture,
	format:              sdl.GPUTextureFormat,
	usage:               sdl.GPUTextureUsageFlags,
	width, height:       u32,
	sample_count:        sdl.GPUSampleCount,
	mip_levels:          u32,
	_temporary_raw_data: []byte,
}

texture_create :: proc(
	dev: ^Device,
	width, height: u32,
	format: sdl.GPUTextureFormat,
	usage: sdl.GPUTextureUsageFlag,
) -> Texture_Handle {
	return texture_create_with_usage(dev, width, height, format, {usage})
}

texture_create_with_usage :: proc(
	dev: ^Device,
	width, height: u32,
	format: sdl.GPUTextureFormat,
	usage: sdl.GPUTextureUsageFlags,
	sample_count := sdl.GPUSampleCount._1,
	// > 1 needs usage to include .COLOR_TARGET (mip generation renders to the
	// levels). Level 0 is uploaded; uploader_flush* generates the rest.
	mip_levels := u32(1),
) -> Texture_Handle {
	assert(mip_levels >= 1)
	assert(mip_levels == 1 || .COLOR_TARGET in usage, "mipmapped textures need COLOR_TARGET")
	resource := Texture {
		handle = sdl.CreateGPUTexture(
			dev.gpu,
			{
				format = format,
				usage = usage,
				width = width,
				height = height,
				layer_count_or_depth = 1,
				num_levels = mip_levels,
				sample_count = sample_count,
			},
		),
		format = format,
		usage  = usage,
		width  = width,
		height = height,
		sample_count = sample_count,
		mip_levels = mip_levels,
	}
	assert(resource.handle != nil)
	handle := Texture_Handle(handle_pool_acquire(&dev.texture_handles))
	index := Resource_Handle(handle).index
	if int(index) == len(dev.textures) {
		append(&dev.textures, resource)
	} else {
		dev.textures[index] = resource
	}
	return handle
}

texture_get :: proc(dev: ^Device, handle: Texture_Handle) -> ^Texture {
	raw := Resource_Handle(handle)
	assert(handle_pool_contains(&dev.texture_handles, raw), "stale texture handle")
	return &dev.textures[raw.index]
}

// Reallocates a texture at a new size, preserving format and usage. Waits
// for GPU idle so the old texture can be released safely mid-session; call
// between frames, not inside a pass. Returns true when it recreated.
texture_resize :: proc(dev: ^Device, handle: ^Texture_Handle, width, height: u32) -> bool {
	if width == 0 || height == 0 do return false
	texture := texture_get(dev, handle^)
	if texture.width == width && texture.height == height do return false
	format := texture.format
	usage := texture.usage
	sample_count := texture.sample_count
	mip_levels := mip_level_count(width, height) if texture.mip_levels > 1 else 1
	_ = sdl.WaitForGPUIdle(dev.gpu)
	texture_destroy(dev, handle^)
	handle^ = texture_create_with_usage(dev, width, height, format, usage, sample_count, mip_levels)
	return true
}

texture_destroy :: proc(dev: ^Device, handle: Texture_Handle) {
	raw := Resource_Handle(handle)
	if !handle_pool_contains(&dev.texture_handles, raw) do return
	resource := &dev.textures[raw.index]
	if resource.handle != nil do sdl.ReleaseGPUTexture(dev.gpu, resource.handle)
	resource^ = {}
	assert(handle_pool_release(&dev.texture_handles, raw))
}

// Loads an image file (PNG/JPEG) into a sampled RGBA8 texture and uploads it
// (blocking). Standalone textures for ground planes, skyboxes, raw meshes.
// srgb: true for color art (albedo), false for data (normal/roughness maps),
// whose bytes are math and must not be gamma-decoded. mipmaps: build the full
// chain (pair with a sampler whose mipmap_mode is .LINEAR, see SAMPLER_TRILINEAR).
texture_load :: proc(dev: ^Device, path: string, srgb := true, mipmaps := true) -> Texture_Handle {
	image := loader.image_load(path)
	defer loader.image_destroy(&image)
	handle := texture_create_rgba8(dev, image.width, image.height, srgb, mipmaps)
	texture := texture_get(dev, handle)
	texture._temporary_raw_data = image.pixels
	uploader_begin(&dev.renderer.uploader)
	uploader_upload_texture(&dev.renderer.uploader, handle)
	uploader_flush_blocking(&dev.renderer.uploader)
	texture._temporary_raw_data = nil
	return handle
}

// Sampled RGBA8 texture, optionally with a full mip chain. Fill
// _temporary_raw_data with level 0 and upload through the Uploader.
texture_create_rgba8 :: proc(dev: ^Device, width, height: u32, srgb: bool, mipmaps: bool) -> Texture_Handle {
	format := sdl.GPUTextureFormat.R8G8B8A8_UNORM_SRGB if srgb else .R8G8B8A8_UNORM
	levels := mip_level_count(width, height) if mipmaps else 1
	usage := sdl.GPUTextureUsageFlags{.SAMPLER}
	if levels > 1 do usage += {.COLOR_TARGET}
	return texture_create_with_usage(dev, width, height, format, usage, ._1, levels)
}
