// Shared sea: the flat grid shaders/sea.slang displaces, its pipeline, and the
// CPU wave height (sea_wave.odin) that boats ride on.
package sea

import "core:math"
import "core:math/linalg"
import gfx "../../engine/gfx"
import shader_parameters "../../shader_parameters"

// Flat unlit sea, far larger than the view so its edge never shows at the horizon.
HALF :: 2000
Y :: -0.6
CELLS :: 400 // 10-unit cells: coarser aliases the 32-unit waves the mesh displaces

// Time the wave field advances on; the sea pipeline reads it through user_data.
State :: struct {
	time: f32,
}

mesh_data :: proc() -> gfx.Mesh_Data {
	n :: CELLS + 1
	cell :: f32(2 * HALF) / CELLS
	vertices := make([dynamic]gfx.VertexData, 0, n * n, context.temp_allocator)
	for z in 0 ..< n {
		for x in 0 ..< n {
			position := gfx.Vec3{-HALF + f32(x) * cell, Y, -HALF + f32(z) * cell}
			append(&vertices, gfx.VertexData{position = position})
		}
	}
	indices := make([dynamic]u32, 0, CELLS * CELLS * 6, context.temp_allocator)
	stride := u32(n)
	for z in 0 ..< CELLS {
		for x in 0 ..< CELLS {
			i := u32(z * n + x)
			append(&indices, i, i + stride, i + 1, i + 1, i + stride, i + stride + 1)
		}
	}
	return gfx.Mesh_Data{vertices = vertices[:], indices = indices[:]}
}

pipeline_create :: proc(gfx_ctx: ^gfx.Device, state: ^State) -> gfx.Pipeline_Handle {
	attributes := shader_parameters.sea_vertex_attributes(gfx.VertexData)
	return gfx.pipeline_create(
		gfx_ctx,
		{
			vertex = shader_parameters.sea_vertex(),
			fragment = shader_parameters.sea_fragment(),
			vertex_attributes = attributes[:],
			vertex_stride = u32(size_of(gfx.VertexData)),
			depth_test = true,
			depth_write = true,
			cull_mode = .BACK,
			bind_draw = bind_draw,
			user_data = state,
		},
	)
}

// Pushes per-draw transforms and the time the wave field advances on.
bind_draw :: proc(
	user_data: rawptr,
	draw_context: ^gfx.Draw_Context,
	parameters: gfx.Draw_Parameters,
) {
	state := cast(^State)user_data
	camera := parameters.camera_position
	uniforms := shader_parameters.SeaVertexUniformBlock {
		data = {
			mvp = parameters.view_projection * parameters.model_transform,
			model = parameters.model_transform,
			camera_position = {camera.x, camera.y, camera.z, 1},
			time = {state.time, 0, 0, 0},
			fog = parameters.fog,
		},
	}
	gfx.draw_push_uniform(draw_context, shader_parameters.SEA_VERTEX_UNIFORM_BLOCK, &uniforms)
}

// Hull rotation that lays a boat along the surface normal from the horizontal gradient.
tilt :: proc(grad: [2]f32) -> linalg.Quaternionf32 {
	normal := linalg.normalize(gfx.Vec3{-grad.x, 1, -grad.y})
	return linalg.quaternion_angle_axis_f32(
		math.acos(clamp(normal.y, -1, 1)),
		linalg.normalize0(linalg.cross(gfx.Vec3{0, 1, 0}, normal)),
	)
}
