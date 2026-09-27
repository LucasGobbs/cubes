package gbbfx

import "core:math/linalg"

Scene :: struct {
	entities: [dynamic]Entity,
}

// Append-only: the returned index stays valid for the scene's lifetime.
// Entities start at the origin with identity rotation and unit scale.
scene_add_entity :: proc(scene: ^Scene) -> int {
	entity := Entity {
		rotation = linalg.QUATERNIONF32_IDENTITY,
		scale    = {1, 1, 1},
	}
	entity_rebuild_transform(&entity)
	append(&scene.entities, entity)
	return len(scene.entities) - 1
}

scene_entity :: proc(scene: ^Scene, index: int) -> ^Entity {
	assert(index >= 0 && index < len(scene.entities))
	return &scene.entities[index]
}

// Convenience for loaded assets: one entity whose Renderable points at the
// model's mesh and material.
scene_add_model :: proc(
	scene: ^Scene,
	model: ^Model,
	position := Vec3{},
	scale := Vec3{1, 1, 1},
	rotation := linalg.QUATERNIONF32_IDENTITY,
	layer := Render_Layer.WORLD,
) -> int {
	assert(model != nil)
	index := scene_add_entity(scene)
	entity := &scene.entities[index]
	entity_set_position(entity, position)
	entity_set_scale(entity, scale)
	entity_set_rotation(entity, rotation)
	entity_add_renderable(entity, &model.mesh, &model.material, layer)
	return index
}

scene_destroy :: proc(scene: ^Scene) {
	for &entity in scene.entities do entity_destroy(&entity)
	delete(scene.entities)
	scene^ = {}
}
