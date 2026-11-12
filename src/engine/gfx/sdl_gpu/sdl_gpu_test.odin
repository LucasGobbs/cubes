package sdl_gpu

import "core:testing"
import sdl "vendor:sdl3"

@(test)
shader_format_maps_goose_code_formats :: proc(t: ^testing.T) {
	testing.expect(t, shader_format(.MetalSource) == sdl.GPUShaderFormat{.MSL})
	testing.expect(t, shader_format(.Spirv) == sdl.GPUShaderFormat{.SPIRV})
	testing.expect(t, shader_format(.HlslSource) == sdl.GPUShaderFormat{})
}
