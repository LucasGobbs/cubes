package engine

import "core:encoding/json"
import "core:log"
import "core:math/linalg"
import "core:os"

// Snapshot of the live world as a definition. Only named entities are written;
// unnamed ones were not loaded from the file. name, assets and clear_color come
// from base. Strings borrow from live components; slices use the temp allocator.
world_to_def :: proc(world: ^World, base: ^Scene_Def) -> Scene_Def {
	def := Scene_Def{name = base.name, assets = base.assets, clear_color = base.clear_color}
	entities := make([dynamic]Entity_Def, context.temp_allocator)
	for id in world_entities(world) {
		name := entity_get_component(world, id, Name)
		if name == nil do continue
		if name.value == CAMERA_NAME {
			def.camera = camera_to_def(world, id)
		} else {
			append(&entities, entity_to_def(world, id, name.value))
		}
	}
	def.entities = entities[:]
	return def
}

// Writes world_to_def as pretty JSON. Logs and returns false on failure.
world_save_scene :: proc(world: ^World, base: ^Scene_Def, path: string) -> bool {
	def := world_to_def(world, base)
	data, err := json.marshal(def, {pretty = true, use_spaces = true, spaces = 2}, context.temp_allocator)
	if err != nil {
		log.errorf("scene save %q: %v", path, err)
		return false
	}
	if write_err := os.write_entire_file(path, data); write_err != nil {
		log.errorf("scene save %q: %v", path, write_err)
		return false
	}
	return true
}

@(private = "file")
entity_to_def :: proc(world: ^World, id: Entity_Id, name: string) -> Entity_Def {
	entity := Entity_Def{name = name}
	transform := entity_get_component(world, id, Transform)
	entity.position = transform.position
	entity.rotation = euler_degrees(transform.rotation)
	if transform.scale != {1, 1, 1} do entity.scale = transform.scale
	if model := entity_get_component(world, id, Model); model != nil do entity.model = model.path
	if animator := entity_get_component(world, id, Animator); animator != nil do entity.clip = animator.clip
	if sprite := entity_get_component(world, id, Sprite); sprite != nil {
		entity.sprite = sprite.texture
		entity.grid = sprite.grid
		entity.frame = sprite.frame
		entity.color = sprite.color
		entity.layer = sprite.layer
		entity.flip_x = sprite.flip_x
		entity.flip_y = sprite.flip_y
		if anim := entity_get_component(world, id, Sprite_Anim); anim != nil {
			entity.anim = Sprite_Anim_Def{first = anim.first, last = anim.last, fps = anim.fps, loop = anim.loop}
		}
	}
	if health := entity_get_component(world, id, Health); health != nil do entity.health = Health_Def{current = health.current, max = health.max}
	return entity
}

@(private = "file")
camera_to_def :: proc(world: ^World, id: Entity_Id) -> Maybe(Camera_Def) {
	transform := entity_get_component(world, id, Transform)
	if cam2 := entity_get_component(world, id, Camera_2D); cam2 != nil {
		return Camera_Def{position = transform.position, mode = "2d", zoom = cam2.zoom, viewport = cam2.viewport, integer_scale = cam2.integer_scale}
	}
	cam := entity_get_component(world, id, Camera)
	if cam == nil do return nil
	def := Camera_Def{position = transform.position, fov_y = cam.fov_y, blur = cam.blur}
	if look_at, has := cam.look_at.?; has do def.look_at = look_at
	if bloom, has := cam.bloom.?; has do def.bloom = Bloom_Def{bloom.threshold, bloom.intensity, bloom.radius}
	return def
}

// Inverse of def_transform's rotation: quaternion to Euler degrees.
@(private = "file")
euler_degrees :: proc(q: linalg.Quaternionf32) -> [3]f32 {
	x, y, z := linalg.euler_angles_xyz_from_quaternion(q)
	return {x, y, z} * linalg.DEG_PER_RAD
}
