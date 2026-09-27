package main

import "core:testing"
import shader_parameters "shader_parameters"

@(test)
material_pipeline_generated_bindings_match_reflection :: proc(t: ^testing.T) {
	testing.expect_value(t, shader_parameters.TRIANGLE_FRAGMENT_TEX.location.slot, u32(0))
	testing.expect_value(t, shader_parameters.TRIANGLE_FRAGMENT_TEX_SAMPLER.location.slot, u32(0))
	testing.expect_value(t, shader_parameters.UNLIT_COLOR_VERTEX_UNIFORM_BLOCK_SLOT, 0)
	testing.expect_value(t, shader_parameters.UNLIT_COLOR_FRAGMENT_UNIFORM_BLOCK_SLOT, 0)
	testing.expect_value(t, shader_parameters.UNLIT_COLOR_VERTEX_UNIFORM_BLOCK_SIZE, 80)
	testing.expect_value(t, shader_parameters.UNLIT_COLOR_FRAGMENT_UNIFORM_BLOCK_SIZE, 80)
}

@(test)
generation_handles_reject_released_slots :: proc(t: ^testing.T) {
	pool: Handle_Pool
	defer handle_pool_destroy(&pool)
	first := handle_pool_acquire(&pool)
	testing.expect(t, handle_pool_contains(&pool, first))
	testing.expect(t, handle_pool_release(&pool, first))
	testing.expect(t, !handle_pool_contains(&pool, first))

	second := handle_pool_acquire(&pool)
	testing.expect_value(t, second.index, first.index)
	testing.expect(t, second.generation != first.generation)
}

@(test)
material_stores_reflected_texture_bindings :: proc(t: ^testing.T) {
	pipeline := Pipeline_Handle(Resource_Handle{index = 2, generation = 1})
	texture := Texture_Handle(Resource_Handle{index = 3, generation = 1})
	sampler := Sampler_Handle(Resource_Handle{index = 4, generation = 1})
	material := material_create(pipeline)
	defer material_destroy(&material)
	material_bind_texture(
		&material,
		shader_parameters.TRIANGLE_FRAGMENT_TEX,
		shader_parameters.TRIANGLE_FRAGMENT_TEX_SAMPLER,
		texture,
		sampler,
	)

	binding, ok := material_find_texture(&material, shader_parameters.TRIANGLE_FRAGMENT_TEX)
	testing.expect(t, ok)
	testing.expect_value(t, binding.texture, texture)
	testing.expect_value(t, binding.sampler, sampler)
}

@(test)
renderer_groups_draws_by_pipeline_and_material :: proc(t: ^testing.T) {
	first_pipeline := Pipeline_Handle(Resource_Handle{index = 0, generation = 1})
	second_pipeline := Pipeline_Handle(Resource_Handle{index = 1, generation = 1})
	first_material := Material {
		pipeline = first_pipeline,
	}
	second_material := Material {
		pipeline = first_pipeline,
	}
	third_material := Material {
		pipeline = second_pipeline,
	}

	items := [4]DrawItem {
		{material = &third_material},
		{material = &second_material},
		{material = &first_material},
		{material = &third_material},
	}
	renderer_sort_draw_items(items[:])

	for index in 1 ..< len(items) {
		testing.expect(t, !draw_item_less(items[index], items[index - 1]))
	}
	testing.expect(t, items[0].material.pipeline == items[1].material.pipeline)
	testing.expect(t, items[2].material.pipeline == items[3].material.pipeline)
	testing.expect(t, items[0].material.pipeline != items[2].material.pipeline)
}
