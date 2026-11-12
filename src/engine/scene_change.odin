// Scene changes: game code asks for a scene by registry name, the host (main.odin)
// runs the transition and swaps the scene at the moment the screen is covered.
//   engine.change_scene("forest_instanced", .Fade, 0.6)
// The engine does not know the scene registry, so this only records the request;
// the host polls take_scene_request once per tick.
package engine

Scene_Transition :: enum {
	Cut, // instant swap, no overlay
	Flash, // instant swap with a white flash that decays (~0.25 s)
	Blink, // instant swap hidden by a short black frame (~0.1 s)
	Fade, // to black, swap, back from black
	Fade_White, // same through white
	Wipe, // black bar sweeps left to right, swap, sweeps off to the right
	Wipe_Left, // same, right to left
	Wipe_Up, // same, bottom to top
	Slide, // black panel enters from the left, swap, leaves through the right
	Diamond, // black diamond grows to cover the screen, swap, shrinks away
	Circle, // black disc grows, swap, shrinks
	Blinds, // 8 horizontal black bars grow to cover, swap, shrink
}

Scene_Request :: struct {
	name:       string, // borrowed: must outlive the call (string literals do)
	transition: Scene_Transition,
	duration:   f32, // seconds for the whole out+in; Cut ignores it
}

@(private)
pending_request: Maybe(Scene_Request)

// A later call before the host consumes the request replaces it.
change_scene :: proc(name: string, transition := Scene_Transition.Fade, duration := f32(0.6)) {
	pending_request = Scene_Request{name, transition, max(duration, 0.05)}
}

take_scene_request :: proc() -> (request: Scene_Request, ok: bool) {
	request, ok = pending_request.?
	pending_request = nil
	return
}
