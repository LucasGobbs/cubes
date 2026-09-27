package goose_runtime_tests

import fixtures ".."
import goose_sdl "../../adapters/sdl_gpu"
import "core:fmt"
import "core:os"
import sdl "vendor:sdl3"

Graphics_Test_Vertex :: struct {
	position: [3]f32,
	color:    [4]f32,
}

fail :: proc(format: string, args: ..any) -> ! {
	fmt.eprintfln(format, ..args)
	os.exit(1)
}

test_compute_pipeline :: proc(device: ^sdl.GPUDevice) {
	parameters := fixtures.compute_pipeline_compute()
	expected_threads := [3]u32{8, 4, 1}
	if parameters.thread_count != expected_threads do fail("compute thread count was not reflected")
	if parameters.resources.readonly_storage_buffers != 1 do fail("compute read-only buffer count was not reflected")
	if parameters.resources.readwrite_storage_buffers != 1 do fail("compute read-write buffer count was not reflected")
	if parameters.resources.uniform_buffers != 1 do fail("compute uniform count was not reflected")
	if fixtures.COMPUTE_PIPELINE_COMPUTE_UNIFORM_BLOCK_SLOT != 0 do fail("compute uniform slot was not reflected")

	pipeline := goose_sdl.create_compute_pipeline(device, parameters)
	if pipeline == nil do fail("compute pipeline creation failed: %s", sdl.GetError())
	sdl.ReleaseGPUComputePipeline(device, pipeline)
	fmt.println("PASS: compute pipeline")
}

test_graphics_pipeline :: proc(device: ^sdl.GPUDevice) {
	vertex_shader := goose_sdl.create_graphics_shader(device, fixtures.graphics_pipeline_vertex())
	if vertex_shader == nil do fail("vertex shader creation failed: %s", sdl.GetError())
	defer sdl.ReleaseGPUShader(device, vertex_shader)

	fragment_shader := goose_sdl.create_graphics_shader(
		device,
		fixtures.graphics_pipeline_fragment(),
	)
	if fragment_shader == nil do fail("fragment shader creation failed: %s", sdl.GetError())
	defer sdl.ReleaseGPUShader(device, fragment_shader)

	goose_attributes := fixtures.graphics_pipeline_vertex_attributes(Graphics_Test_Vertex)
	attributes := goose_sdl.convert_vertex_attributes(goose_attributes[:], context.temp_allocator)
	pipeline := sdl.CreateGPUGraphicsPipeline(
		device,
		{
			vertex_shader = vertex_shader,
			fragment_shader = fragment_shader,
			primitive_type = .TRIANGLELIST,
			vertex_input_state = {
				num_vertex_buffers = 1,
				vertex_buffer_descriptions = &(sdl.GPUVertexBufferDescription {
						slot = 0,
						pitch = size_of(Graphics_Test_Vertex),
					}),
				num_vertex_attributes = u32(len(attributes)),
				vertex_attributes = &attributes[0],
			},
			target_info = {
				num_color_targets = 1,
				color_target_descriptions = &(sdl.GPUColorTargetDescription {
						format = .R8G8B8A8_UNORM,
					}),
			},
		},
	)
	if pipeline == nil do fail("graphics pipeline creation failed: %s", sdl.GetError())
	sdl.ReleaseGPUGraphicsPipeline(device, pipeline)
	fmt.println("PASS: graphics pipeline")
}

main :: proc() {
	if !sdl.Init({.VIDEO}) do fail("SDL initialization failed: %s", sdl.GetError())
	defer sdl.Quit()

	device := sdl.CreateGPUDevice({.MSL, .SPIRV}, true, nil)
	if device == nil do fail("GPU device creation failed: %s", sdl.GetError())
	defer sdl.DestroyGPUDevice(device)

	selection := "all"
	if len(os.args) > 1 do selection = os.args[1]
	switch selection {
	case "compute":
		test_compute_pipeline(device)
	case "graphics":
		test_graphics_pipeline(device)
	case "all":
		test_compute_pipeline(device)
		test_graphics_pipeline(device)
	case:
		fail("unknown shader runtime test: %s", selection)
	}
}
