package gbbfx

import "core:math/linalg"

// Entities are plain scene objects: position/rotation/scale plus a list of
// components. The renderer never owns entities or the assets they point at;
// lifetimes stay with the game.

Renderable :: struct {
	// Borrowed: mesh and material must outlive this component.
	// Materials are meant to be shared between any number of entities.
	mesh:     ^Mesh,
	material: ^Material,
	layer:    Render_Layer,
}

Component :: union {
	Renderable,
}

Entity :: struct {
	position:   Vec3,
	rotation:   linalg.Quaternionf32,
	scale:      Vec3,

	// Cached from the TRS above. Read by the renderer; never write directly —
	// use the entity_set_* procs, which rebuild it.
	transform:  matrix[4, 4]f32,
	components: [dynamic]Component,
}

entity_rebuild_transform :: proc(entity: ^Entity) {
	entity.transform =
		linalg.matrix4_translate_f32(entity.position) *
		linalg.matrix4_from_quaternion(entity.rotation) *
		linalg.matrix4_scale_f32(entity.scale)
}

entity_set_position :: proc(entity: ^Entity, position: Vec3) {
	entity.position = position
	entity_rebuild_transform(entity)
}

entity_set_rotation :: proc(entity: ^Entity, rotation: linalg.Quaternionf32) {
	entity.rotation = rotation
	entity_rebuild_transform(entity)
}

// Angles in radians, applied yaw-pitch-roll (.XYZ order).
entity_set_rotation_euler :: proc(entity: ^Entity, x, y, z: f32) {
	entity_set_rotation(entity, linalg.quaternion_from_euler_angles_f32(x, y, z, .XYZ))
}

entity_set_scale :: proc(entity: ^Entity, scale: Vec3) {
	entity.scale = scale
	entity_rebuild_transform(entity)
}

entity_add_component :: proc(entity: ^Entity, component: Component) {
	append(&entity.components, component)
}

entity_add_renderable :: proc(
	entity: ^Entity,
	mesh: ^Mesh,
	material: ^Material,
	layer: Render_Layer = .WORLD,
) {
	assert(mesh != nil && material != nil)
	entity_add_component(
		entity,
		Renderable{mesh = mesh, material = material, layer = layer},
	)
}

entity_renderable :: proc(entity: ^Entity) -> ^Renderable {
	for &component in entity.components {
		if _, is_renderable := component.(Renderable); is_renderable {
			return &component.(Renderable)
		}
	}
	return nil
}

entity_destroy :: proc(entity: ^Entity) {
	delete(entity.components)
	entity^ = {}
}
