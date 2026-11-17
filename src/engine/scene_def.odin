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
import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:mem/virtual"
import "core:os"
import "particles"

// Name of the camera entity in the World. The file's camera is keyed by it.
CAMERA_NAME :: "__camera"

Bloom_Def :: struct {
	threshold, intensity: f32,
	radius:               i32,
}

Camera_Def :: struct {
	position:      [3]f32 `json:"position,omitempty"`,
	look_at:       Maybe([3]f32) `json:"look_at,omitempty"`,
	fov_y:         f32 `json:"fov_y,omitempty"`,
	bloom:         Maybe(Bloom_Def) `json:"bloom,omitempty"`,
	blur:          Maybe(i32) `json:"blur,omitempty"`,
	mode:          string `json:"mode,omitempty"`, // "3d" (default) or "2d": Camera_2D, position.xy is the view centre
	zoom:          f32 `json:"zoom,omitempty"`,
	viewport:      [2]f32 `json:"viewport,omitempty"`,
	integer_scale: bool `json:"integer_scale,omitempty"`,
}

Health_Def :: struct {
	current, max: f32,
}

Entity_Def :: struct {
	name:           string `json:"name,omitempty"`,
	model:          string `json:"model,omitempty"`,
	clip:           string `json:"clip,omitempty"`,
	position:       [3]f32 `json:"position,omitempty"`,
	rotation:       [3]f32 `json:"rotation,omitempty"`, // degrees
	scale:          [3]f32 `json:"scale,omitempty"`,
	sprite:         string `json:"sprite,omitempty"`, // texture path; makes a Sprite
	grid:           [2]i32 `json:"grid,omitempty"`, // columns, rows of the sheet; {0,0} = whole image
	frame:          i32 `json:"frame,omitempty"`,
	color:          [4]f32 `json:"color,omitempty"`, // {0,0,0,0} = white
	layer:          i32 `json:"layer,omitempty"`,
	flip_x:         bool `json:"flip_x,omitempty"`,
	flip_y:         bool `json:"flip_y,omitempty"`,
	anim:           Maybe(Sprite_Anim_Def) `json:"anim,omitempty"`,
	health:         Maybe(Health_Def) `json:"health,omitempty"`,
	particles:      Maybe(particles.Emitter_Desc) `json:"particles,omitempty"`,
}

Sprite_Anim_Def :: struct {
	first, last: i32,
	fps:         f32,
	loop:        bool,
}

// Everything the scene needs resident; assets_load loads it in one go.
Assets_Def :: struct {
	models:   []string `json:"models,omitempty"`, // .glb/.gltf, static or skinned (detected)
	textures: []string `json:"textures,omitempty"`, // png/jpg, sRGB
}

Scene_Def :: struct {
	name:        string `json:"name,omitempty"`,
	assets:      Assets_Def `json:"assets,omitempty"`,
	camera:      Maybe(Camera_Def) `json:"camera,omitempty"`,
	entities:    []Entity_Def `json:"entities,omitempty"`,
	clear_color: Maybe([3]f32) `json:"clear_color,omitempty"`, // sRGB background; the renderer default when omitted
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

// Key an entity is matched by: its name, or "#<index>" when it has none.
entity_key :: proc(entity: Entity_Def, index: int) -> string {
	if entity.name != "" do return entity.name
	return fmt.tprintf("#%d", index)
}

// Applies the definition to an (usually empty) world and returns the entity ids
// in definition order (camera excluded). A duplicate name gets the id of the
// first entity with that name. The slice uses the temp allocator.
world_spawn_scene :: proc(world: ^World, def: ^Scene_Def) -> []Entity_Id {
	world_apply_scene(world, def)
	ids := make([]Entity_Id, len(def.entities), context.temp_allocator)
	for entity, index in def.entities do ids[index], _ = world_find_by_name(world, entity_key(entity, index))
	return ids
}

// Transform of a definition: zero fields get the World defaults, so the result
// compares equal to the live Transform.
@(private)
def_transform :: proc(position, rotation, scale: [3]f32) -> Transform {
	transform := Transform{position = position, rotation = linalg.QUATERNIONF32_IDENTITY, scale = {1, 1, 1}}
	if scale != {} do transform.scale = scale
	if rotation != {} {
		r := rotation * linalg.RAD_PER_DEG
		transform.rotation = linalg.quaternion_from_euler_angles_f32(r.x, r.y, r.z, .XYZ)
	}
	return transform
}

// Components of one definition entity, Name first.
@(private)
entity_components :: proc(entity: Entity_Def, key: string) -> []Component {
	list := make([dynamic]Component, context.temp_allocator)
	append(&list, Name{key}, def_transform(entity.position, entity.rotation, entity.scale))
	if entity.model != "" do append(&list, Model{path = entity.model})
	if entity.clip != "" do append(&list, Animator{clip = entity.clip})
	if entity.sprite != "" {
		append(&list, Sprite{texture = entity.sprite, grid = entity.grid, frame = entity.frame, color = entity.color, layer = entity.layer, flip_x = entity.flip_x, flip_y = entity.flip_y})
		if anim, has := entity.anim.?; has do append(&list, Sprite_Anim{first = anim.first, last = anim.last, fps = anim.fps, loop = anim.loop})
	}
	if health, has := entity.health.?; has do append(&list, Health{current = health.current, max = health.max})
	if emitter, has := entity.particles.?; has {
		emitter.position = {} // World overrides from Transform
		append(&list, Particle_Emitter(emitter))
	}
	return list[:]
}

// Components of the camera entity, Name first; mode picks Camera_2D or Camera.
@(private)
camera_components :: proc(camera: Camera_Def) -> []Component {
	list := make([dynamic]Component, context.temp_allocator)
	append(&list, Name{CAMERA_NAME}, def_transform(camera.position, {}, {}))
	if camera.mode == "2d" {
		append(&list, Camera_2D{zoom = camera.zoom, viewport = camera.viewport, integer_scale = camera.integer_scale})
		return list[:]
	}
	if camera.mode != "" && camera.mode != "3d" do log.errorf("scene: unknown camera mode %q", camera.mode)
	c := Camera{fov_y = camera.fov_y, blur = camera.blur}
	if look_at, has := camera.look_at.?; has do c.look_at = Vec3(look_at)
	if bloom, has := camera.bloom.?; has do c.bloom = Bloom{bloom.threshold, bloom.intensity, bloom.radius}
	append(&list, c)
	return list[:]
}
