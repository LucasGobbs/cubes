// Scene definitions: a JSON file describes a scene's name, camera and the
// entities spawned at load. Example (src/scenes/postfx/scene.json):
//   { "name": "Postfx",
//     "camera": { "position": [0,1,1.9], "look_at": [0,0.8,0], "bloom": {"threshold":0.5,"intensity":1.5,"radius":12} },
//     "entities": [ { "name": "hero", "model": "static/models/rigged_cesiumman.glb", "clip": "clip_0" } ] }
// Omitted fields are zero, which the World reads as defaults (scale 1, identity rotation).
// rotation is Euler degrees (x, y, z). Strings live in the Scene_File arena, which
// must outlive the entities (Model.path is borrowed).
package engine

import "core:encoding/json"
import "core:log"
import "core:math/linalg"
import "core:mem/virtual"
import "core:os"

Bloom_Def :: struct {
	threshold, intensity: f32,
	radius:               i32,
}

Camera_Def :: struct {
	position: [3]f32,
	look_at:  Maybe([3]f32),
	fov_y:    f32,
	bloom:    Maybe(Bloom_Def),
	blur:     Maybe(i32),
}

Entity_Def :: struct {
	name:     string,
	model:    string,
	clip:     string,
	position: [3]f32,
	rotation: [3]f32, // degrees
	scale:    [3]f32,
}

// Everything the scene needs resident; assets_load_all loads it in one go.
Assets_Def :: struct {
	models:   []string, // .glb/.gltf, static or skinned (detected)
	textures: []string, // png/jpg, sRGB
}

Scene_Def :: struct {
	name:     string,
	assets:   Assets_Def,
	camera:   Maybe(Camera_Def),
	entities: []Entity_Def,
}

Scene_File :: struct {
	arena: virtual.Arena,
	def:   Scene_Def,
}

scene_file_load :: proc(file: ^Scene_File, path: string) -> bool {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		log.errorf("scene file %q: cannot read", path)
		return false
	}
	if virtual.arena_init_growing(&file.arena) != nil do return false
	if json_err := json.unmarshal(data, &file.def, allocator = virtual.arena_allocator(&file.arena)); json_err != nil {
		log.errorf("scene file %q: %v", path, json_err)
		virtual.arena_destroy(&file.arena)
		return false
	}
	return true
}

scene_file_destroy :: proc(file: ^Scene_File) {
	virtual.arena_destroy(&file.arena)
	file^ = {}
}

// Spawns the camera (if any) and every entity. Returns the entity ids in
// definition order (camera excluded); the slice uses the temp allocator.
world_spawn_scene :: proc(world: ^World, def: ^Scene_Def) -> []Entity_Id {
	assets_load_all(world, def.assets) // before spawning: spawns then hit the cache
	if camera, ok := def.camera.?; ok {
		c := Camera{fov_y = camera.fov_y, blur = camera.blur}
		if look_at, has := camera.look_at.?; has do c.look_at = Vec3(look_at)
		if bloom, has := camera.bloom.?; has do c.bloom = Bloom{bloom.threshold, bloom.intensity, bloom.radius}
		world_spawn(world, c, Transform{position = camera.position})
	}
	ids := make([]Entity_Id, len(def.entities), context.temp_allocator)
	for entity, index in def.entities {
		transform := Transform{position = entity.position, scale = entity.scale}
		if entity.rotation != {} {
			r := entity.rotation * linalg.RAD_PER_DEG
			transform.rotation = linalg.quaternion_from_euler_angles_f32(r.x, r.y, r.z, .XYZ)
		}
		id := world_spawn(world, transform)
		if entity.model != "" do world_add(world, id, Model{path = entity.model})
		if entity.clip != "" do world_add(world, id, Animator{clip = entity.clip})
		ids[index] = id
	}
	return ids
}
