package engine

import "core:encoding/json"
import "core:log"
import "core:math/linalg"
import "core:os"

// Snapshot of the live world as a definition. Only named actors are written;
// unnamed ones were not loaded from the file. name, assets and clear_color come
// from base. Strings borrow from live Props; slices use the temp allocator.
world_to_def :: proc(world: ^World, base: ^Scene_Def) -> Scene_Def {
	def := Scene_Def{name = base.name, assets = base.assets, clear_color = base.clear_color}
	actors := make([dynamic]Actor_Def, context.temp_allocator)
	for id in world_actors(world) {
		name := actor_props(world, id, Name)
		if name == nil do continue
		if name.value == CAMERA_NAME {
			def.camera = camera_to_def(world, id)
		} else {
			append(&actors, actor_to_def(world, id, name.value))
		}
	}
	def.actors = actors[:]
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
actor_to_def :: proc(world: ^World, id: Actor_Id, name: string) -> Actor_Def {
	actor := Actor_Def{name = name}
	transform := actor_props(world, id, Transform)
	actor.position = transform.position
	actor.rotation = euler_degrees(transform.rotation)
	if transform.scale != {1, 1, 1} do actor.scale = transform.scale
	if model := actor_props(world, id, Model); model != nil do actor.model = model.path
	if animator := actor_props(world, id, Animator); animator != nil do actor.clip = animator.clip
	if sprite := actor_props(world, id, Sprite); sprite != nil {
		actor.sprite = sprite.texture
		actor.grid = sprite.grid
		actor.frame = sprite.frame
		actor.color = sprite.color
		actor.layer = sprite.layer
		actor.flip_x = sprite.flip_x
		actor.flip_y = sprite.flip_y
		if anim := actor_props(world, id, Sprite_Anim); anim != nil {
			actor.anim = Sprite_Anim_Def{first = anim.first, last = anim.last, fps = anim.fps, loop = anim.loop}
		}
	}
	if health := actor_props(world, id, Health); health != nil do actor.health = Health_Def{current = health.current, max = health.max}
	if collider := actor_props(world, id, Collider); collider != nil && collider.shape != nil do actor.collider = collider_to_def(collider^)
	if environment := actor_props(world, id, Environment); environment != nil do actor.environment = environment_to_def(environment^)
	return actor
}

@(private = "file")
camera_to_def :: proc(world: ^World, id: Actor_Id) -> Maybe(Camera_Def) {
	transform := actor_props(world, id, Transform)
	if cam2 := actor_props(world, id, Camera_2D); cam2 != nil {
		return Camera_Def{position = transform.position, mode = "2d", zoom = cam2.zoom, viewport = cam2.viewport, integer_scale = cam2.integer_scale}
	}
	cam := actor_props(world, id, Camera)
	if cam == nil do return nil
	def := Camera_Def{position = transform.position, fov_y = cam.fov_y, blur = cam.blur}
	if look_at, has := cam.look_at.?; has do def.look_at = look_at
	if bloom, has := cam.bloom.?; has do def.bloom = Bloom_Def{bloom.threshold, bloom.intensity, bloom.radius}
	return def
}

@(private = "file")
collider_to_def :: proc(collider: Collider) -> Collider_Def {
	def := Collider_Def{density = collider.density}
	if collider.body == .Static do def.body = "static"
	switch shape in collider.shape {
	case Box:
		def.shape = "box"
		def.half = shape.half
	case Sphere:
		def.shape = "sphere"
		def.radius = shape.radius
	case nil:
	}
	return def
}

@(private = "file")
environment_to_def :: proc(env: Environment) -> Environment_Def {
	def := Environment_Def{skybox = env.skybox, shadows = env.shadows, sun_direction = env.sun_direction, uncapped = env.uncapped}
	if fog, has := env.fog.?; has do def.fog = Fog_Def{fog.color, fog.distance}
	if grade, has := env.grade.?; has do def.grade = Grade_Def{exposure = grade.exposure, contrast = grade.contrast, saturation = grade.saturation}
	return def
}

// Inverse of def_transform's rotation: quaternion to Euler degrees.
@(private = "file")
euler_degrees :: proc(q: linalg.Quaternionf32) -> [3]f32 {
	x, y, z := linalg.euler_angles_xyz_from_quaternion(q)
	return {x, y, z} * linalg.DEG_PER_RAD
}
