package goose

import "core:testing"

@(test)
goose_core_descriptors_are_backend_neutral :: proc(t: ^testing.T) {
	code := Code {
		name = "test.vertex",
		entrypoint = "vertexMain",
		platform = .Vulkan,
		format = .Spirv,
		blob = {size = 16},
	}
	parameters := Graphics_Parameters {
		code = code,
		stage = .Vertex,
		resources = {uniform_buffers = 1},
	}
	testing.expect_value(t, parameters.code.platform, Platform.Vulkan)
	testing.expect_value(t, parameters.code.format, Code_Format.Spirv)
	testing.expect_value(t, parameters.stage, Stage.Vertex)
	testing.expect_value(t, parameters.resources.uniform_buffers, u32(1))

	uniform := Uniform_Block {
		stage = .Fragment,
		location = {space = 2, binding = 5, slot = 1},
		size = 64,
	}
	testing.expect_value(t, uniform.stage, Stage.Fragment)
	testing.expect_value(t, uniform.location.space, u32(2))
	testing.expect_value(t, uniform.location.binding, u32(5))
	testing.expect_value(t, uniform.location.slot, u32(1))
	testing.expect_value(t, uniform.size, u32(64))
}
