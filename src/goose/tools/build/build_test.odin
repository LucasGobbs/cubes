package main

import "core:strings"
import "core:testing"

@(test)
shader_generator_reads_graphics_and_compute_metadata :: proc(t: ^testing.T) {
	vertex := load_stage("src/goose/tests/generated/uniforms.vert.refl.json")
	testing.expect_value(t, vertex.stage, "vertex")
	testing.expect_value(t, vertex.entrypoint, "vertexMain")
	testing.expect_value(t, vertex.counts.uniform_buffers, 1)
	testing.expect_value(t, len(vertex.vertex_attributes), 1)
	testing.expect_value(t, vertex.vertex_attributes[0].name, "position")
	testing.expect_value(t, vertex.vertex_attributes[0].location, 0)
	testing.expect_value(t, vertex.vertex_attributes[0].format, ".Float3")
	testing.expect_value(t, len(vertex.uniform_blocks), 1)
	testing.expect_value(t, vertex.uniform_blocks[0].name, "UniformBlock")
	testing.expect_value(t, vertex.uniform_blocks[0].slot, 0)
	testing.expect_value(t, uniform_size(vertex.uniform_blocks[0].type_, "UniformBlock"), 240)
	fragment := load_stage("src/goose/tests/generated/graphics_pipeline.frag.refl.json")
	testing.expect_value(t, fragment.stage, "fragment")
	testing.expect_value(t, fragment.counts.samplers, 1)
	compute := load_stage("src/goose/tests/generated/compute_pipeline.compute.refl.json")
	testing.expect_value(t, len(fragment.textures), 1)
	testing.expect_value(t, fragment.textures[0].native_binding, 0)
	testing.expect_value(t, len(fragment.samplers), 1)
	testing.expect_value(t, fragment.samplers[0].native_binding, 0)
	testing.expect_value(t, compute.stage, "compute")
	testing.expect_value(t, compute.counts.readonly_storage_buffers, 1)
	testing.expect_value(t, compute.counts.readwrite_storage_buffers, 1)
	testing.expect_value(t, compute.thread_count, [3]int{8, 4, 1})
	testing.expect_value(t, len(compute.storage_resources), 2)
	testing.expect_value(t, compute.storage_resources[0].native_binding, 1)
	testing.expect_value(t, compute.storage_resources[1].native_binding, 2)
}

@(test)
shader_generator_is_deterministic :: proc(t: ^testing.T) {
	options := Options {
		name         = "triangle",
		package_name = "shader_parameters",
		goose_import = "../goose",
		output       = "src/shader_parameters/triangle_shader_parameters.odin",
		platform     = .Metal,
		platform_set = true,
	}
	defer delete(options.reflections)
	append_elem(&options.reflections, "src/goose/tests/generated/uniforms.vert.refl.json")
	append_elem(&options.reflections, "src/goose/tests/generated/graphics_pipeline.frag.refl.json")
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
	testing.expect(
		t,
		strings.contains(first, "TRIANGLE_VERTEX_UNIFORM_BLOCK :: goose.Uniform_Block"),
	)
	testing.expect(t, strings.contains(first, "TRIANGLE_FRAGMENT_TEX :: goose.Texture_Binding"))
	testing.expect(
		t,
		strings.contains(first, "TRIANGLE_FRAGMENT_TEX_SAMPLER :: goose.Sampler_Binding"),
	)
	testing.expect(
		t,
		strings.contains(first, "location = {space = 0, binding = 0, slot = 0, count = 1}"),
	)
	testing.expect(t, strings.contains(first, "platform = .Metal"))
	testing.expect(t, strings.contains(first, "format = .Metal_Source"))
	testing.expect(t, !strings.contains(first, ".spv"))
}
