package main

import "core:strings"
import "core:testing"

@(test)
shader_generator_reads_graphics_and_compute_metadata :: proc(t: ^testing.T) {
	vertex := load_stage("shaders/generated/triangle.vert.refl.json")
	testing.expect_value(t, vertex.stage, "vertex")
	testing.expect_value(t, vertex.entrypoint, "vertexMain")
	testing.expect_value(t, vertex.counts.uniform_buffers, 1)
	testing.expect_value(t, len(vertex.vertex_attributes), 3)
	testing.expect_value(t, vertex.vertex_attributes[0].name, "position")
	testing.expect_value(t, vertex.vertex_attributes[0].location, 0)
	testing.expect_value(t, vertex.vertex_attributes[0].format, ".FLOAT3")
	testing.expect_value(t, vertex.vertex_attributes[1].format, ".FLOAT4")
	testing.expect_value(t, vertex.vertex_attributes[2].format, ".FLOAT2")
	testing.expect_value(t, len(vertex.uniform_blocks), 1)
	testing.expect_value(t, vertex.uniform_blocks[0].name, "UniformBlock")
	testing.expect_value(t, vertex.uniform_blocks[0].slot, 0)
	testing.expect_value(t, uniform_size(vertex.uniform_blocks[0].type_, "UniformBlock"), 64)
	fragment := load_stage("shaders/generated/triangle.frag.refl.json")
	testing.expect_value(t, fragment.stage, "fragment")
	testing.expect_value(t, fragment.counts.samplers, 1)
	compute := load_stage("shaders/generated/compute.refl.json")
	testing.expect_value(t, compute.stage, "compute")
	testing.expect_value(t, compute.counts.readonly_storage_buffers, 1)
	testing.expect_value(t, compute.counts.readwrite_storage_buffers, 1)
	testing.expect_value(t, compute.thread_count, [3]int{64, 1, 1})
}

@(test)
shader_generator_is_deterministic :: proc(t: ^testing.T) {
	options := Options {
		name          = "triangle",
		package_name  = "shader_parameters",
		shader_import = "../shader",
		output        = "src/shader_parameters/triangle_shader_parameters.odin",
	}
	defer delete(options.reflections)
	append_elem(&options.reflections, "shaders/generated/triangle.vert.refl.json")
	append_elem(&options.reflections, "shaders/generated/triangle.frag.refl.json")
	first := generate(options)
	defer delete(first)
	second := generate(options)
	defer delete(second)
	testing.expect_value(t, first, second)
	testing.expect(t, strings.contains(first, "TRIANGLE_VERTEX_UNIFORM_BUFFERS :: 1"))
	testing.expect(t, strings.contains(first, "TRIANGLE_FRAGMENT_SAMPLERS :: 1"))
	testing.expect(t, strings.contains(first, "triangle_vertex_attributes"))
	testing.expect(t, strings.contains(first, "offset_of(Vertex, position)"))
	testing.expect(t, strings.contains(first, "Triangle_Vertex_Uniform_Block"))
	testing.expect(t, strings.contains(first, "TRIANGLE_VERTEX_UNIFORM_BLOCK_SLOT :: 0"))
	testing.expect(t, strings.contains(first, "triangle_vertex_push_uniform_block"))
}
