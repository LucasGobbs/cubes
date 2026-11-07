package gbbfx

import "core:math/linalg"
import loader "loader"

// Entities are plain scene objects: position/rotation/scale plus a list of
// components. The renderer never owns entities or the assets they point at;
// lifetimes stay with the game.

Renderable :: struct {
	// Borrowed: mesh and material must outlive this component.
	// Materials are meant to be shared between any number of entities.
	mesh:     ^Mesh,
	material: ^Material,
	layer:    Render_Layer,
	// Screen-space layers (skybox, UI, post-process) have no world position to test.
	cull:     bool,
	// Skinned only (skin nil = static): the borrowed skin, the clip index
	// (-1 = rest pose) and its time, and the pose sampled from them. The
	// entity owns pose.
	skin:      ^loader.Skin,
	clip:      int,
	clip_time: f32,
	pose:      ^Pose,
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
		Renderable{mesh = mesh, material = material, layer = layer, cull = layer == .WORLD || layer == .TRANSPARENT},
	)
}

entity_add_skinned_renderable :: proc(
	entity: ^Entity,
	mesh: ^Mesh,
	material: ^Material,
	skin: ^loader.Skin,
	layer: Render_Layer = .WORLD,
) {
	assert(mesh != nil && material != nil && skin != nil)
	pose := new(Pose)
	clip := -1
	if len(skin.clips) > 0 do clip = 0
	clip_sample(skin, clip, 0, pose)
	// Skinned meshes have no bounds (see mesh_set_bounds), so culling stays off.
	entity_add_component(
		entity,
		Renderable{mesh = mesh, material = material, layer = layer, skin = skin, clip = clip, pose = pose},
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

// Switches the skinned entity to the named clip, restarting it. Returns false
// and keeps the current clip when the skin has no clip with that name.
entity_play_clip :: proc(entity: ^Entity, name: string) -> bool {
	renderable := entity_renderable(entity)
	assert(renderable != nil && renderable.skin != nil)
	index, found := clip_find(renderable.skin, name)
	if !found do return false
	if index != renderable.clip {
		renderable.clip = index
		renderable.clip_time = 0
	}
	return true
}

// Advances the entity's skinned renderable clip and samples its pose palette.
entity_tick_animation :: proc(entity: ^Entity, dt: f32) {
	for &component in entity.components {
		#partial switch &renderable in component {
		case Renderable:
			if renderable.skin == nil do break
			renderable.clip_time += dt
			clip_sample(renderable.skin, renderable.clip, renderable.clip_time, renderable.pose)
		}
	}
}

entity_destroy :: proc(entity: ^Entity) {
	for component in entity.components {
		if renderable, ok := component.(Renderable); ok && renderable.pose != nil do free(renderable.pose)
	}
	delete(entity.components)
	entity^ = {}
}
