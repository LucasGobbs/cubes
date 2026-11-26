package engine

import "core:strings"
import gfx "gfx"

// Applies World.stage to the renderer. world_update calls it after the particles and before the camera.
// Untouched stages (Stage{} and never set) return early, so the renderer stays with its owner.
// The frame the stage returns to Stage{} is still applied once: that clears fog, grade and sky.
update_stage :: proc(world: ^World) {
	if world.stage == (Stage{}) && !world.stage_applied do return
	world.stage_applied = world.stage != (Stage{})
	if world.gfx_ctx == nil {
		_, has_grade := world.stage.grade.?
		assert(world.stage.skybox == "" && !has_grade, "engine: Stage skybox and grade need a world with a Device")
		return
	}
	stage_apply(world)
}

// Every field is written, nil taking its default, so nothing from the previous stage lingers.
@(private = "file")
stage_apply :: proc(world: ^World) {
	stage := world.stage
	gfx_ctx := world.gfx_ctx
	if fog, ok := stage.fog.?; ok {
		rgb := gfx.color_srgb_to_linear({fog.color.x, fog.color.y, fog.color.z, 1})
		gfx_ctx.renderer.fog = {rgb.x, rgb.y, rgb.z, fog.distance}
	} else {
		gfx_ctx.renderer.fog = {}
	}
	if grade, ok := stage.grade.?; ok {
		if world.tonemap == nil {
			world.tonemap = new(gfx.Tonemap)
			world.tonemap^ = gfx.tonemap_create(gfx_ctx)
		}
		gfx.tonemap_set(world.tonemap, grade.exposure, grade.contrast, grade.saturation)
		gfx.renderer_set_passes(
			&gfx_ctx.renderer,
			.Final,
			[]gfx.Render_Pass{gfx.tonemap_pass(world.tonemap)},
		)
	} else {
		gfx.renderer_clear_passes(&gfx_ctx.renderer, .Final)
	}
	shadows, shadows_set := stage.shadows.?
	gfx_ctx.renderer.shadow_enabled = shadows if shadows_set else true
	sun, sun_set := stage.sun_direction.?
	if !sun_set do sun = gfx.DEFAULT_LIGHT_DIRECTION
	gfx.renderer_update_light(&gfx_ctx.renderer, sun)
	if color, ok := stage.clear_color.?; ok {
		gfx_ctx.renderer.clear_color = {color.x, color.y, color.z, 1}
	} else {
		gfx_ctx.renderer.clear_color = gfx.DEFAULT_CLEAR_COLOR
	}
	if stage.uncapped != world.uncapped {
		world.uncapped = stage.uncapped
		gfx.set_present_mode(gfx_ctx, .IMMEDIATE if stage.uncapped else .VSYNC)
	}
	update_sky(world, stage.skybox)
}

// Rebuilds the skybox when its path changes; "" means no skybox.
@(private = "file")
update_sky :: proc(world: ^World, path: string) {
	if path == world.sky_path do return
	if sky, ok := &world.sky.?; ok do gfx.skybox_destroy(world.gfx_ctx, sky)
	world.sky = nil
	if len(world.sky_path) > 0 do delete(world.sky_path)
	world.sky_path = ""
	if path == "" do return
	world.sky = gfx.skybox_create(world.gfx_ctx, path)
	world.sky_path = strings.clone(path)
}
