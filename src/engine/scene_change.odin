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
	Dots, // grid of black discs grow until they cover the screen, swap, shrink
	Dots_Wave, // same, discs start along a diagonal wave
	Squares, // grid of black squares grow to cover, swap, shrink
}

// What happens to a scene that is pushed under another one.
Stack_Policy :: enum {
	Keep, // stays alive in memory, not ticked or drawn; pop restores it instantly
	Disk, // Scene.suspend writes it to .cache/scene_stack/, it is destroyed; pop re-creates + Scene.resume
	Discard, // destroyed; pop re-creates it from scratch
}

Scene_Request_Kind :: enum {
	Change, // replace the running scene, clearing the stack
	Push, // put the running scene on the stack, run the target on top
	Pop, // drop the running scene, return to the one below
}

Scene_Request :: struct {
	kind:       Scene_Request_Kind,
	name:       string, // borrowed: must outlive the call (string literals do); empty for Pop
	transition: Scene_Transition,
	duration:   f32, // seconds for the whole out+in; Cut ignores it
	policy:     Stack_Policy, // Push only
}

@(private)
pending_request: Maybe(Scene_Request)
@(private)
pending_preload: Maybe(string)

// A later call before the host consumes the request replaces it.
change_scene :: proc(name: string, transition := Scene_Transition.Fade, duration := f32(0.6)) {
	pending_request = Scene_Request{.Change, name, transition, max(duration, 0.05), .Keep}
}

// Runs `name` on top of the current scene; pop_scene returns to the current one.
push_scene :: proc(name: string, policy := Stack_Policy.Keep, transition := Scene_Transition.Fade, duration := f32(0.6)) {
	pending_request = Scene_Request{.Push, name, transition, max(duration, 0.05), policy}
}

// Back to the scene below the running one. No-op (logged) when the stack is empty.
pop_scene :: proc(transition := Scene_Transition.Fade, duration := f32(0.6)) {
	pending_request = Scene_Request{.Pop, "", transition, max(duration, 0.05), .Keep}
}

// Starts loading `name` now (Scene.load on a job thread) so a later change_scene/push_scene to
// it skips the wait. One preload at a time: a different name drops the previous one.
preload_scene :: proc(name: string) {
	pending_preload = name
}

take_scene_request :: proc() -> (request: Scene_Request, ok: bool) {
	request, ok = pending_request.?
	pending_request = nil
	return
}

take_preload_request :: proc() -> (name: string, ok: bool) {
	name, ok = pending_preload.?
	pending_preload = nil
	return
}
