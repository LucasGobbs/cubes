// Compute example: doubles 1024 floats on the GPU (out[i] = in[i]*2 + 1)
// and verifies the result on the CPU after readback.
//
// Run from the project root: `make compute`
//
// SDL_GPU can work without a window entirely — this demo never creates one.
// It exercises the full compute flow:
//   create storage buffers -> upload input (transfer buffer) -> compute pass
//   (bind pipeline, bind buffers, dispatch) -> download output -> CPU verify.
package main

import goose_sdl "../src/goose/adapters/sdl_gpu"
import shader_parameters "../src/shader_parameters"
import "core:fmt"
import "core:mem"
import "core:os"
import sdl "vendor:sdl3"

ELEMENTS :: 1024
THREADS :: 64 // numthreads(64,1,1) in shaders/compute.slang
GROUPS :: ELEMENTS / THREADS
BUFFER_SIZE :: ELEMENTS * size_of(f32)

device: ^sdl.GPUDevice

fail :: proc(msg: cstring) -> ! {
	fmt.eprintfln("%s", msg)
	os.exit(1)
}

load_compute_pipeline :: proc() -> ^sdl.GPUComputePipeline {
	pipeline := goose_sdl.create_compute_pipeline(device, shader_parameters.compute())
	if pipeline == nil {
		fail(sdl.GetError())
	}
	return pipeline
}

create_storage_buffer :: proc(size: u32, usage: sdl.GPUBufferUsageFlags) -> ^sdl.GPUBuffer {
	buf := sdl.CreateGPUBuffer(device, sdl.GPUBufferCreateInfo{usage = usage, size = size})
	if buf == nil {
		fail(sdl.GetError())
	}
	return buf
}

// CPU data -> GPU storage buffer, via an upload transfer buffer.
upload_buffer :: proc(buf: ^sdl.GPUBuffer, data: []f32) {
	size := u32(len(data) * size_of(f32))

	transfer := sdl.CreateGPUTransferBuffer(
		device,
		sdl.GPUTransferBufferCreateInfo{usage = .UPLOAD, size = size},
	)
	if transfer == nil {
		fail(sdl.GetError())
	}
	defer sdl.ReleaseGPUTransferBuffer(device, transfer)

	mapped := sdl.MapGPUTransferBuffer(device, transfer, false)
	mem.copy(mapped, raw_data(data), int(size))
	sdl.UnmapGPUTransferBuffer(device, transfer)

	cmd := sdl.AcquireGPUCommandBuffer(device)
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUBuffer(
		copy_pass,
		sdl.GPUTransferBufferLocation{transfer_buffer = transfer, offset = 0},
		sdl.GPUBufferRegion{buffer = buf, offset = 0, size = size},
		false,
	)
	sdl.EndGPUCopyPass(copy_pass)
	if !sdl.SubmitGPUCommandBuffer(cmd) {
		fail(sdl.GetError())
	}
}

// One dispatch: binds the pipeline and storage buffers, launches workgroups.
run_compute :: proc(pipeline: ^sdl.GPUComputePipeline, input, output: ^sdl.GPUBuffer) {
	cmd := sdl.AcquireGPUCommandBuffer(device)

	// Read-write storage buffers are bound at pass creation time.
	rw := sdl.GPUStorageBufferReadWriteBinding {
		buffer = output,
		cycle  = false,
	}
	pass := sdl.BeginGPUComputePass(cmd, nil, 0, &rw, 1)

	sdl.BindGPUComputePipeline(pass, pipeline)

	// Read-only storage buffers go on slots starting at 0.
	ro := [1]^sdl.GPUBuffer{input}
	sdl.BindGPUComputeStorageBuffers(pass, 0, &ro[0], 1)

	sdl.DispatchGPUCompute(pass, GROUPS, 1, 1)
	sdl.EndGPUComputePass(pass)

	if !sdl.SubmitGPUCommandBuffer(cmd) {
		fail(sdl.GetError())
	}
}

// GPU storage buffer -> CPU slice, waiting on a fence.
download_buffer :: proc(buf: ^sdl.GPUBuffer, out: []f32) {
	size := u32(len(out) * size_of(f32))

	transfer := sdl.CreateGPUTransferBuffer(
		device,
		sdl.GPUTransferBufferCreateInfo{usage = .DOWNLOAD, size = size},
	)
	if transfer == nil {
		fail(sdl.GetError())
	}
	defer sdl.ReleaseGPUTransferBuffer(device, transfer)

	cmd := sdl.AcquireGPUCommandBuffer(device)
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.DownloadFromGPUBuffer(
		copy_pass,
		sdl.GPUBufferRegion{buffer = buf, offset = 0, size = size},
		sdl.GPUTransferBufferLocation{transfer_buffer = transfer, offset = 0},
	)
	sdl.EndGPUCopyPass(copy_pass)

	// Downloads are async; a fence tells us when the data is readable.
	fence := sdl.SubmitGPUCommandBufferAndAcquireFence(cmd)
	if fence == nil {
		fail(sdl.GetError())
	}
	fences := [1]^sdl.GPUFence{fence}
	if !sdl.WaitForGPUFences(device, true, &fences[0], 1) {
		fail(sdl.GetError())
	}
	sdl.ReleaseGPUFence(device, fence)

	mapped := ([^]f32)(sdl.MapGPUTransferBuffer(device, transfer, false))
	mem.copy(raw_data(out), mapped, int(size))
	sdl.UnmapGPUTransferBuffer(device, transfer)
}

main :: proc() {
	if !sdl.Init(sdl.INIT_VIDEO) {
		fail(sdl.GetError())
	}
	defer sdl.Quit()

	device = sdl.CreateGPUDevice({.MSL, .SPIRV}, true, nil)
	if device == nil {
		fail(sdl.GetError())
	}
	defer sdl.DestroyGPUDevice(device)

	pipeline := load_compute_pipeline()
	defer sdl.ReleaseGPUComputePipeline(device, pipeline)

	// Input: 0, 1, 2, ..., ELEMENTS-1
	input := make([]f32, ELEMENTS)
	defer delete(input)
	for i in 0 ..< ELEMENTS {
		input[i] = f32(i)
	}

	in_buf := create_storage_buffer(BUFFER_SIZE, {.COMPUTE_STORAGE_READ})
	defer sdl.ReleaseGPUBuffer(device, in_buf)
	upload_buffer(in_buf, input)

	out_buf := create_storage_buffer(BUFFER_SIZE, {.COMPUTE_STORAGE_WRITE})
	defer sdl.ReleaseGPUBuffer(device, out_buf)

	run_compute(pipeline, in_buf, out_buf)

	output := make([]f32, ELEMENTS)
	defer delete(output)
	download_buffer(out_buf, output)

	// CPU-side verification of every element.
	mismatches := 0
	for i in 0 ..< ELEMENTS {
		expected := f32(i) * 2.0 + 1.0
		if output[i] != expected {
			mismatches += 1
			if mismatches <= 4 {
				fmt.printfln("MISMATCH in[%d]: got %v, want %v", i, output[i], expected)
			}
		}
	}

	fmt.printfln("input[0..3]  = %v", input[:4])
	fmt.printfln("output[0..3] = %v", output[:4])
	if mismatches == 0 {
		fmt.printfln(
			"PASS: all %d elements computed by the GPU match out[i] = in[i]*2 + 1",
			ELEMENTS,
		)
	} else {
		fmt.printfln("FAIL: %d/%d mismatches", mismatches, ELEMENTS)
		os.exit(1)
	}
}
