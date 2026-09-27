package main

SceneNode :: struct {
	model:     ^Model,
	transform: matrix[4, 4]f32,
}
Scene :: struct {
	nodes: [dynamic]SceneNode,
}

scene_add_model :: proc(scene: ^Scene, model: ^Model, transform: matrix[4, 4]f32) -> int {
	assert(model != nil)
	append_elem(&scene.nodes, SceneNode{model = model, transform = transform})

	return len(scene.nodes) - 1
}

scene_destroy :: proc(scene: ^Scene) {
	delete(scene.nodes)
	scene^ = {}
}
