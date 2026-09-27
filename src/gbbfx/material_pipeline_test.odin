package gbbfx

import goose "../goose"
import "core:math/linalg"
import "core:testing"

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
material_stores_backend_neutral_bindings :: proc(t: ^testing.T) {
	pipeline := Pipeline_Handle(Resource_Handle{index = 2, generation = 1})
	texture := Texture_Handle(Resource_Handle{index = 3, generation = 1})
	sampler := Sampler_Handle(Resource_Handle{index = 4, generation = 1})
	texture_parameter := goose.Texture_Binding {
		stage = .Fragment,
		location = {slot = 0, count = 1},
	}
	sampler_parameter := goose.Sampler_Binding {
		stage = .Fragment,
		location = {slot = 0, count = 1},
	}
	uniform_parameter := goose.Uniform_Block {
		stage = .Fragment,
		location = {slot = 0, count = 1},
		size = 16,
	}
	uniform := [4]f32{1, 0.5, 0.25, 1}
	material := material_create(pipeline)
	defer material_destroy(&material)
	material_bind_texture(&material, texture_parameter, sampler_parameter, texture, sampler)
	material_set_uniform(&material, uniform_parameter, &uniform)

	testing.expect_value(t, len(material.textures), 1)
	testing.expect_value(t, material.textures[0].texture, texture)
	testing.expect_value(t, material.textures[0].sampler, sampler)
	data, ok := material_uniform_data(&material, uniform_parameter)
	testing.expect(t, ok)
	testing.expect_value(t, len(data), 16)
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

	// Grouping, not pointer order: equal pipelines form contiguous runs.
	testing.expect(t, items[0].material.pipeline == items[1].material.pipeline)
	testing.expect(t, items[2].material.pipeline == items[3].material.pipeline)
	testing.expect(t, items[0].material.pipeline != items[2].material.pipeline)
}

@(test)
renderer_orders_layers_before_pipelines :: proc(t: ^testing.T) {
	first_pipeline := Pipeline_Handle(Resource_Handle{index = 0, generation = 1})
	second_pipeline := Pipeline_Handle(Resource_Handle{index = 1, generation = 1})
	world_material := Material {
		pipeline = second_pipeline,
	}
	ui_material := Material {
		pipeline = first_pipeline,
	}

	// Pipeline order alone would draw the UI item first; layer must win.
	items := [2]DrawItem {
		{material = &ui_material, layer = .UI},
		{material = &world_material, layer = .WORLD},
	}
	renderer_sort_draw_items(items[:])

	testing.expect_value(t, items[0].layer, Render_Layer.WORLD)
	testing.expect_value(t, items[1].layer, Render_Layer.UI)
	testing.expect(t, items[0].material == &world_material)
}

@(test)
entity_holds_shared_renderable :: proc(t: ^testing.T) {
	mesh: Mesh
	material := Material {
		pipeline = Pipeline_Handle(Resource_Handle{index = 1, generation = 1}),
	}

	scene: Scene
	defer scene_destroy(&scene)
	first := scene_add_entity(&scene)
	second := scene_add_entity(&scene)
	entity_add_renderable(scene_entity(&scene, first), &mesh, &material)
	entity_add_renderable(scene_entity(&scene, second), &mesh, &material, .UI)

	first_renderable := entity_renderable(scene_entity(&scene, first))
	second_renderable := entity_renderable(scene_entity(&scene, second))
	testing.expect(t, first_renderable != nil && second_renderable != nil)
	testing.expect(t, first_renderable.mesh == &mesh)
	testing.expect(t, first_renderable.material == second_renderable.material)
	testing.expect_value(t, first_renderable.layer, Render_Layer.WORLD)
	testing.expect_value(t, second_renderable.layer, Render_Layer.UI)
}

@(test)
entity_transform_rebuilds_from_trs :: proc(t: ^testing.T) {
	scene: Scene
	defer scene_destroy(&scene)
	entity := scene_entity(&scene, scene_add_entity(&scene))

	testing.expect_value(t, entity.transform, linalg.MATRIX4F32_IDENTITY)
	testing.expect_value(t, entity.scale, Vec3{1, 1, 1})

	entity_set_position(entity, {1, 2, 3})
	entity_set_scale(entity, {2, 2, 2})
	entity_set_rotation_euler(entity, 0, linalg.to_radians(f32(90)), 0)

	expected_rotation := linalg.quaternion_from_euler_angles_f32(
		0,
		linalg.to_radians(f32(90)),
		0,
		.XYZ,
	)
	expected :=
		linalg.matrix4_translate_f32({1, 2, 3}) *
		linalg.matrix4_from_quaternion(expected_rotation) *
		linalg.matrix4_scale_f32({2, 2, 2})
	testing.expect_value(t, entity.transform, expected)
	testing.expect_value(t, entity.position, Vec3{1, 2, 3})
	testing.expect_value(t, entity.rotation, expected_rotation)
}
