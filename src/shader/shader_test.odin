package shader

import "core:testing"
import sdl "vendor:sdl3"

@(test)
shader_selects_supported_backend_code :: proc(t: ^testing.T) {
	metal_bytes := [2]u8{1, 2}
	spirv_bytes := [2]u8{3, 4}
	code_parameters := Code {
		metal = {data = raw_data(metal_bytes[:]), size = len(metal_bytes)},
		spirv = {data = raw_data(spirv_bytes[:]), size = len(spirv_bytes)},
	}

	blob, format, ok := select_code(code_parameters, {.MSL})
	testing.expect(t, ok)
	testing.expect(t, blob.size == 2 && blob.data[0] == 1 && blob.data[1] == 2)
	testing.expect(t, format == sdl.GPUShaderFormat{.MSL})

	blob, format, ok = select_code(code_parameters, {.SPIRV})
	testing.expect(t, ok)
	testing.expect(t, blob.size == 2 && blob.data[0] == 3 && blob.data[1] == 4)
	testing.expect(t, format == sdl.GPUShaderFormat{.SPIRV})

	_, _, ok = select_code(code_parameters, {.DXIL})
	testing.expect(t, !ok)
}
