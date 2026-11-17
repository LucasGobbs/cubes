// Screen-centre crosshair drawn through the 2D batcher after the scene.
// Batch px are relative to the view centre, so {0, 0} is the window centre at any size.
package forest_naive

import gfx "../../engine/gfx"
import input "../../engine/input"

CROSSHAIR_ARM :: 10.0 // half-length of each bar, px
CROSSHAIR_THICKNESS :: 2.0 // bar width, px
CROSSHAIR_OUTLINE :: 1.0 // dark border around each bar, px

Crosshair :: struct {
	batch:   gfx.Batch,
	action:  input.Button_Action,
	visible: bool,
}

// Must run after flare_create: flare's set_passes replaces the After_Scene slot.
crosshair_create :: proc(gfx_ctx: ^gfx.Device, crosshair: ^Crosshair, action: input.Button_Action) {
	crosshair.batch = gfx.batch_create(gfx_ctx)
	gfx.batch_register(gfx_ctx, &crosshair.batch)
	crosshair.action = action
	crosshair.visible = true
}

crosshair_destroy :: proc(gfx_ctx: ^gfx.Device, crosshair: ^Crosshair) {
	gfx.batch_destroy(gfx_ctx, &crosshair.batch)
}

// Edge-toggles on the action and rebuilds the cross for this frame's window size.
crosshair_update :: proc(gfx_ctx: ^gfx.Device, crosshair: ^Crosshair, inputs: ^input.System) {
	if input.pressed(inputs, crosshair.action) do crosshair.visible = !crosshair.visible
	b := &crosshair.batch
	gfx.batch_begin(b, gfx_ctx, gfx.Camera2D{})
	if crosshair.visible {
		outline_arm: f32 = CROSSHAIR_ARM + CROSSHAIR_OUTLINE
		outline_thickness: f32 = CROSSHAIR_THICKNESS + 2 * CROSSHAIR_OUTLINE
		black := [4]f32{0, 0, 0, 0.8}
		white := [4]f32{1, 1, 1, 1}
		gfx.batch_rect(b, {0, 0}, {2 * outline_arm, outline_thickness}, black)
		gfx.batch_rect(b, {0, 0}, {outline_thickness, 2 * outline_arm}, black)
		gfx.batch_rect(b, {0, 0}, {2 * CROSSHAIR_ARM, CROSSHAIR_THICKNESS}, white)
		gfx.batch_rect(b, {0, 0}, {CROSSHAIR_THICKNESS, 2 * CROSSHAIR_ARM}, white)
	}
	gfx.batch_end(b, gfx_ctx)
}
