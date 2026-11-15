package jobs

import "base:intrinsics"
import "core:testing"

@(test)
parallel_for_writes_every_index :: proc(t: ^testing.T) {
	pool: Pool
	init(&pool, 3)
	defer destroy(&pool)

	out := make([]int, 100_000)
	defer delete(out)
	parallel_for(&pool, len(out), raw_data(out), proc(data: rawptr, first, last: int) {
		out := ([^]int)(data)
		for i in first ..< last do out[i] = i * 2
	})
	for v, i in out do testing.expect_value(t, v, i * 2)
}

@(test)
run_counts_every_job :: proc(t: ^testing.T) {
	pool: Pool
	init(&pool, 3)
	defer destroy(&pool)

	counter: int
	group: Group
	for _ in 0 ..< 1000 {
		run(&pool, &group, proc(data: rawptr) {
			intrinsics.atomic_add((^int)(data), 1)
		}, &counter)
	}
	wait(&pool, &group)
	testing.expect_value(t, counter, 1000)
	testing.expect(t, done(&group))
}

@(test)
parallel_for_empty_is_noop :: proc(t: ^testing.T) {
	pool: Pool
	init(&pool, 2)
	defer destroy(&pool)

	called := false
	parallel_for(&pool, 0, &called, proc(data: rawptr, first, last: int) {
		(^bool)(data)^ = true
	})
	testing.expect(t, !called)
}
