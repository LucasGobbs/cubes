// Scene title: a large centred line with an optional subtitle, shown for a few seconds
// when a scene becomes visible, plus a corner tag with the scene's group. The timer and
// layout run in the tick; the After_Post pass only draws, and nothing is drawn while a
// transition covers the screen (the timer also pauses then: the tick does not run).
package engine

import "core:strings"
import gfx "gfx"
import sdl "vendor:sdl3"

SCENE_TITLE_SECONDS :: 2.5
SCENE_TITLE_FADE :: 0.5 // the last seconds of the title fade out
SCENE_TITLE_PIXELS :: 44
SCENE_TITLE_SUB_PIXELS :: 20
SCENE_TITLE_TOP :: 40
SCENE_TITLE_COLOR :: [4]f32{1, 1, 1, 1}
SCENE_TITLE_SUB_COLOR :: [4]f32{0.85, 0.85, 0.85, 1}
SCENE_TITLE_TAG_COLOR :: [4]f32{1, 1, 1, 0.6}
SCENE_TITLE_SHADOW :: [4]f32{0, 0, 0, 0.6}

Title_Layer :: struct {
	font:      gfx.Font,
	materials: [2]gfx.Material,
	mesh:      gfx.Mesh,
	vertices:  [dynamic]gfx.VertexData,
}

Scene_Title :: struct {
	text, subtitle: string, // owned copies, freed by the next show or destroy
	active:         bool,
	elapsed:        f32,
	duration:       f32,
	big:            Title_Layer, // the title
	small:          Title_Layer, // subtitle and corner tag
}

scene_title: Scene_Title

// Alpha `elapsed` seconds into a `duration` run: full, then a linear fade over the last
// SCENE_TITLE_FADE seconds, 0 once the run is over.
scene_title_alpha :: proc(elapsed, duration: f32) -> f32 {
	left := duration - elapsed
	if left <= 0 do return 0
	return min(1, left / min(SCENE_TITLE_FADE, duration))
}

// Starts (or restarts) the title. The strings are copied: callers may pass temp strings.
scene_title_show :: proc(text: string, subtitle := "", seconds := f32(SCENE_TITLE_SECONDS)) {
	delete(scene_title.text)
	delete(scene_title.subtitle)
	scene_title.text = strings.clone(text)
	scene_title.subtitle = strings.clone(subtitle)
	scene_title.active = true
	scene_title.elapsed = 0
	scene_title.duration = seconds
	// Drop the previous layout: the pass may draw before the next tick rebuilds it.
	clear(&scene_title.big.vertices)
	clear(&scene_title.small.vertices)
}

// Advances the title timer. The text stays allocated until the next show or destroy.
scene_title_advance :: proc(delta: f32) {
	if !scene_title.active do return
	scene_title.elapsed += delta
	if scene_title.elapsed >= scene_title.duration do scene_title.active = false
}

// Per-frame: advances the timer and lays out the title and the corner tag (`corner` ""
// = none). Called from the host tick only when no transition covers the screen.
scene_title_tick :: proc(gfx_ctx: ^gfx.Device, delta_time: f32, corner := "") {
	scene_title_advance(delta_time)
	visible_width, visible_height: i32
	_ = sdl.GetWindowSize(gfx_ctx.window, &visible_width, &visible_height)
	visible_width = min(visible_width, gfx_ctx.window_size.x)
	visible_height = min(visible_height, gfx_ctx.window_size.y)
	width, height := f32(visible_width), f32(visible_height)

	big, small := &scene_title.big, &scene_title.small
	clear(&big.vertices)
	clear(&small.vertices)
	if scene_title.active {
		alpha := scene_title_alpha(scene_title.elapsed, scene_title.duration)
		title_width := gfx.font_text_width(&big.font, scene_title.text)
		title_x := (width - title_width) / 2
		title_top := f32(SCENE_TITLE_TOP)
		overlay_push_text(gfx_ctx, &big.vertices, &big.font, title_x + 2, title_top + 2, scene_title.text, faded(SCENE_TITLE_SHADOW, alpha))
		overlay_push_text(gfx_ctx, &big.vertices, &big.font, title_x, title_top, scene_title.text, faded(SCENE_TITLE_COLOR, alpha))
		if scene_title.subtitle != "" {
			sub_width := gfx.font_text_width(&small.font, scene_title.subtitle)
			sub_x := (width - sub_width) / 2
			sub_top := title_top + f32(big.font.line_height) + 4
			overlay_push_text(gfx_ctx, &small.vertices, &small.font, sub_x + 1, sub_top + 1, scene_title.subtitle, faded(SCENE_TITLE_SHADOW, alpha))
			overlay_push_text(gfx_ctx, &small.vertices, &small.font, sub_x, sub_top, scene_title.subtitle, faded(SCENE_TITLE_SUB_COLOR, alpha))
		}
	}
	if corner != "" {
		tag_width := gfx.font_text_width(&small.font, corner)
		tag_x := width - STATS_MARGIN - tag_width
		overlay_push_text(gfx_ctx, &small.vertices, &small.font, tag_x + 1, STATS_MARGIN + 1, corner, SCENE_TITLE_SHADOW)
		overlay_push_text(gfx_ctx, &small.vertices, &small.font, tag_x, STATS_MARGIN, corner, SCENE_TITLE_TAG_COLOR)
	}
	if len(big.vertices) > 0 do gfx.mesh_update_unindexed(&gfx_ctx.renderer, &big.mesh, big.vertices[:])
	if len(small.vertices) > 0 do gfx.mesh_update_unindexed(&gfx_ctx.renderer, &small.mesh, small.vertices[:])
}

faded :: proc(color: [4]f32, alpha: f32) -> [4]f32 {
	result := color
	result.a *= alpha
	return result
}

// After_Post pass: draws the title and tag over the scene, unless a transition covers it.
scene_title_draw :: proc(ctx: ^gfx.Pass_Ctx, _: rawptr) {
	if transition.phase != .None do return
	if len(scene_title.big.vertices) > 0 do overlay_draw(ctx, stats.pipelines, &scene_title.big.materials, &scene_title.big.mesh, len(scene_title.big.vertices))
	if len(scene_title.small.vertices) > 0 do overlay_draw(ctx, stats.pipelines, &scene_title.small.materials, &scene_title.small.mesh, len(scene_title.small.vertices))
}

// Needs stats_create first: the overlay pipelines and sampler are shared with the stats panel.
scene_title_create :: proc(gfx_ctx: ^gfx.Device) {
	scene_title.big = title_layer_create(gfx_ctx, SCENE_TITLE_PIXELS)
	scene_title.small = title_layer_create(gfx_ctx, SCENE_TITLE_SUB_PIXELS)
	gfx.renderer_add_pass(&gfx_ctx.renderer, .After_Post, {name = "scene_title", run = scene_title_draw})
}

// Call before stats_destroy, which clears the After_Post passes.
scene_title_destroy :: proc(gfx_ctx: ^gfx.Device) {
	title_layer_destroy(gfx_ctx, &scene_title.big)
	title_layer_destroy(gfx_ctx, &scene_title.small)
	delete(scene_title.text)
	delete(scene_title.subtitle)
	scene_title = {}
}

title_layer_create :: proc(gfx_ctx: ^gfx.Device, pixels: f32) -> Title_Layer {
	layer: Title_Layer
	font, ok := gfx.font_create(gfx_ctx, "static/fonts/andale-mono.ttf", pixels)
	assert(ok)
	layer.font = font
	for index in 0 ..< 2 {
		layer.materials[index] = gfx.material_make(stats.pipelines[index])
		gfx.bind_textured_material(&layer.materials[index], font.texture, stats.sampler)
	}
	dummy := [6]gfx.VertexData{}
	layer.mesh = gfx.mesh_create_unindexed(gfx_ctx, dummy[:])
	return layer
}

title_layer_destroy :: proc(gfx_ctx: ^gfx.Device, layer: ^Title_Layer) {
	gfx.mesh_destroy(gfx_ctx, &layer.mesh)
	for index in 0 ..< 2 do gfx.material_destroy(&layer.materials[index])
	gfx.font_destroy(gfx_ctx, &layer.font)
	delete(layer.vertices)
	layer^ = {}
}
