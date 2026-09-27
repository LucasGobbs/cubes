// Editor chrome: the window layout built each frame between editor_begin
// and editor_end. The game view is a widget: the Viewport window's body
// rect is recorded into Ui_State.viewport, and editor_draw later composites
// the post-processed scene texture there, so editor chrome never goes
// through the game's post-processing.
package editor

import "core:fmt"
import mu "vendor:microui"

Ui_State :: struct {
	// Out: body rect of the Viewport window in window pixels. The game
	// renders at this size and the overlay draws the result here.
	viewport:       mu.Rect,

	// Values displayed/edited by the Inspector window. Pointers so the
	// editor stays game-agnostic.
	fps:            f32,
	rotation_speed: ^f32,
	tint:           ^[4]f32,
}

editor_build_ui :: proc(ed: ^Editor, state: ^Ui_State) {
	ctx := editor_begin(ed)

	if mu.window(ctx, "Viewport", mu.Rect{10, 10, 800, 540}) {
		state.viewport = mu.get_current_container(ctx).body
	}

	if mu.window(ctx, "Inspector", mu.Rect{820, 10, 300, 180}) {
		mu.layout_row(ctx, []i32{90, -1}, 0)
		mu.label(ctx, "FPS")
		buffer: [16]byte
		mu.label(ctx, fmt.bprintf(buffer[:], "%.0f", state.fps))
		mu.label(ctx, "Rot speed")
		mu.slider(ctx, state.rotation_speed, 0, 3.2)
		mu.label(ctx, "Tint R")
		mu.slider(ctx, &state.tint.x, 0, 1)
		mu.label(ctx, "Tint G")
		mu.slider(ctx, &state.tint.y, 0, 1)
		mu.label(ctx, "Tint B")
		mu.slider(ctx, &state.tint.z, 0, 1)
	}

	editor_end(ed)
}
