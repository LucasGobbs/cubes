package gfx

import "core:testing"

// Device with only buffer pools: buffer_add needs no GPU.
@(private = "file")
scope_test_device :: proc() -> Device {
	return {}
}

@(private = "file")
scope_test_free :: proc(dev: ^Device) {
	delete(dev.buffers)
	handle_pool_destroy(&dev.buffer_handles)
	delete(dev.scopes)
	delete(dev.scope_draw_marks)
	delete(dev.draws)
	delete(dev.unscoped_entries)
}

@(test)
scope_end_destroys_reverse_order :: proc(t: ^testing.T) {
	dev := scope_test_device()
	defer scope_test_free(&dev)

	scope_begin(&dev)
	a := buffer_add(&dev, Buffer{})
	b := buffer_add(&dev, Buffer{})
	c := buffer_add(&dev, Buffer{})
	scope_end(&dev)

	// release appends to the free list: destroyed c, b, a in that order
	testing.expect_value(t, len(dev.buffer_handles.free), 3)
	testing.expect_value(t, dev.buffer_handles.free[0], Resource_Handle(c).index)
	testing.expect_value(t, dev.buffer_handles.free[1], Resource_Handle(b).index)
	testing.expect_value(t, dev.buffer_handles.free[2], Resource_Handle(a).index)
	testing.expect(t, !handle_pool_contains(&dev.buffer_handles, Resource_Handle(a)))
}

@(test)
scope_manual_destroy_unregisters :: proc(t: ^testing.T) {
	dev := scope_test_device()
	defer scope_test_free(&dev)

	scope_begin(&dev)
	a := buffer_add(&dev, Buffer{})
	buffer_destroy(&dev, a)
	testing.expect_value(t, len(dev.scopes[0]), 0)
	buffer_destroy(&dev, a) // stale second destroy is a no-op
	scope_end(&dev)

	testing.expect_value(t, len(dev.buffer_handles.free), 1)
}

@(test)
scope_paused_and_unscoped_not_tracked :: proc(t: ^testing.T) {
	dev := scope_test_device()
	defer scope_test_free(&dev)

	unscoped := buffer_add(&dev, Buffer{}) // no scope open: not tracked, no panic

	scope_begin(&dev)
	dev.scope_paused += 1
	paused := buffer_add(&dev, Buffer{})
	dev.scope_paused -= 1
	testing.expect_value(t, len(dev.scopes[0]), 0)
	scope_end(&dev)

	testing.expect(t, handle_pool_contains(&dev.buffer_handles, Resource_Handle(paused)))
	testing.expect(t, handle_pool_contains(&dev.buffer_handles, Resource_Handle(unscoped)))
}
