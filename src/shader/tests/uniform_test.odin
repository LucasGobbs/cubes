package shader_tests

import "core:testing"

@(test)
shader_uniform_layout_is_reflected_independently :: proc(t: ^testing.T) {
	testing.expect_value(t, UNIFORMS_VERTEX_UNIFORM_BUFFERS, 1)
	testing.expect_value(t, UNIFORMS_VERTEX_UNIFORM_BLOCK_SLOT, 0)
	testing.expect_value(t, UNIFORMS_VERTEX_UNIFORM_BLOCK_SIZE, 128)
	testing.expect_value(t, size_of(Uniforms_Vertex_Lighting), 32)
	testing.expect_value(t, offset_of(Uniforms_Vertex_Lighting, intensity), 16)
	testing.expect_value(t, size_of(Uniforms_Vertex_Scene_Uniforms), 128)
	testing.expect_value(t, offset_of(Uniforms_Vertex_Scene_Uniforms, camera_position), 64)
	testing.expect_value(t, offset_of(Uniforms_Vertex_Scene_Uniforms, exposure), 80)
	testing.expect_value(t, offset_of(Uniforms_Vertex_Scene_Uniforms, lighting), 96)
	testing.expect_value(t, size_of(Uniforms_Vertex_Uniform_Block), 128)
}
