// Async scene loading: Scene.load runs on a job thread while the host keeps the
// transition overlay and the loading screen going; the swap waits for it.
package engine

import "base:intrinsics"
import "core:log"
import "jobs"

Load_Context :: struct {
	progress: f32, // atomic, 0..1; read with load_fraction
	ok:       bool, // load's result; valid once group is done
	group:    jobs.Group, // the load job and every job it spawned (asset prefetch)
	jobs:     ^jobs.Pool,
	scene:    Scene, // looked up on the main thread; Scene.load runs on it
	name:     string, // registry name (borrowed from Config.scenes)

	// Prefetch counters (atomic): progress = 0.1 parse + 0.9 * done/total.
	prefetch_total, prefetch_done: int,
}

// Call from Scene.load; p in 0..1.
load_progress :: proc(lc: ^Load_Context, p: f32) {
	intrinsics.atomic_store(&lc.progress, clamp(p, 0, 1))
}

// 1 once the load and everything it spawned finished.
load_fraction :: proc(lc: ^Load_Context) -> f32 {
	if jobs.done(&lc.group) do return 1
	return min(intrinsics.atomic_load(&lc.progress), 0.99)
}

// Heap-allocates a Load_Context for a looked-up scene that has a load hook and starts it.
load_start :: proc(pool: ^jobs.Pool, scene: Scene, name: string) -> ^Load_Context {
	lc := new(Load_Context)
	lc.scene, lc.name, lc.jobs, lc.ok = scene, name, pool, true
	log.infof("scene %q: load started", name)
	jobs.run(pool, &lc.group, load_main, lc)
	return lc
}

@(private = "file")
load_main :: proc(data: rawptr) {
	lc := (^Load_Context)(data)
	if !lc.scene.load(&lc.scene, lc) do intrinsics.atomic_store(&lc.ok, false)
}

// Waits for the load (helping run jobs), then hands the scene over and frees the context.
// ok = false: the load failed; the scene's own state is whatever load left (unload is called).
load_finish :: proc(lc: ^Load_Context) -> (scene: Scene, ok: bool) {
	jobs.wait(lc.jobs, &lc.group)
	scene, ok = lc.scene, lc.ok
	if !ok && scene.unload != nil && scene.state != nil do scene.unload(&scene)
	free(lc)
	return
}

// A load nobody will consume (replaced preload): finish it in the background, free its state.
// shortcut: no unload hook = the state load allocated leaks (warned); add one to the scene.
load_discard :: proc(lc: ^Load_Context) {
	jobs.wait(lc.jobs, &lc.group)
	if lc.scene.unload != nil {
		if lc.scene.state != nil do lc.scene.unload(&lc.scene)
	} else if lc.scene.state != nil {
		log.warnf("scene %q: preload dropped and the scene has no unload hook; its load state leaks", lc.name)
	}
	free(lc)
}
