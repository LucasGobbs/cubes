// Fixed worker pool for CPU-only work. The thread that waits helps run queued jobs.
//
// Job procs MUST NOT call gfx.*, sdl.*GPU*, b3.*, scope_*, and MUST NOT touch World
// slots outside the range they were given: the GPU device, Box3D worlds and the scope
// stack are single-threaded. Workers only fill CPU arrays; the main thread finishes.
//
// Each worker has its own temp allocator, freed after every job: scratch only, never
// memory the caller reads after `wait`.
package jobs

import "base:intrinsics"
import "core:mem/virtual"
import "core:os"
import "core:sync"
import "core:thread"

Job_Proc :: #type proc(data: rawptr)

// Atomic in-flight counter; the zero value means nothing is running.
Group :: struct {
	pending: int,
}

Job :: struct {
	fn:    Job_Proc,
	data:  rawptr,
	group: ^Group,
}

// FIFO under one mutex; no work stealing.
Pool :: struct {
	threads: [dynamic]^thread.Thread,
	queue:   [dynamic]Job,
	head:    int, // next job to pop
	mutex:   sync.Mutex,
	cond:    sync.Cond,
	quit:    bool,
}

// workers = 0: one per core, minus the calling thread (at least 1).
init :: proc(pool: ^Pool, workers := 0) {
	count := workers if workers > 0 else max(1, os.get_processor_core_count() - 1)
	for _ in 0 ..< count {
		t := thread.create(worker_main)
		t.data = pool
		t.init_context = context
		append(&pool.threads, t)
		thread.start(t)
	}
}

destroy :: proc(pool: ^Pool) {
	sync.mutex_lock(&pool.mutex)
	pool.quit = true
	sync.mutex_unlock(&pool.mutex)
	sync.cond_broadcast(&pool.cond)
	for t in pool.threads {
		thread.join(t)
		thread.destroy(t)
	}
	delete(pool.threads)
	delete(pool.queue)
	pool^ = {}
}

run :: proc(pool: ^Pool, group: ^Group, fn: Job_Proc, data: rawptr) {
	intrinsics.atomic_add(&group.pending, 1) // before enqueue: wait never sees a queued job as done
	sync.mutex_lock(&pool.mutex)
	append(&pool.queue, Job{fn, data, group})
	sync.mutex_unlock(&pool.mutex)
	sync.cond_signal(&pool.cond)
}

done :: proc(group: ^Group) -> bool {
	return intrinsics.atomic_load(&group.pending) == 0
}

// Runs queued jobs on the calling thread until the group has drained.
wait :: proc(pool: ^Pool, group: ^Group) {
	for !done(group) {
		sync.mutex_lock(&pool.mutex)
		job, ok := pop_locked(pool)
		sync.mutex_unlock(&pool.mutex)
		if ok {
			execute(job)
		} else {
			thread.yield() // the rest is running on workers
		}
	}
}

// Splits [0, count) into contiguous ranges and calls `body` for each, in parallel.
// count <= min_batch, or a nil pool, runs inline.
parallel_for :: proc(
	pool: ^Pool,
	count: int,
	data: rawptr,
	body: proc(data: rawptr, first, last: int),
	min_batch := 64,
) {
	if count <= 0 do return
	batch := max(min_batch, 1)
	if count <= batch || pool == nil || len(pool.threads) == 0 {
		body(data, 0, count)
		return
	}
	ranges := min(len(pool.threads) + 1, (count + batch - 1) / batch)
	jobs := make([]Range_Job, ranges, context.temp_allocator)
	group: Group
	for i in 0 ..< ranges {
		jobs[i] = {body, data, count * i / ranges, count * (i + 1) / ranges}
		if i > 0 do run(pool, &group, range_main, &jobs[i])
	}
	body(data, jobs[0].first, jobs[0].last) // the caller takes the first range
	wait(pool, &group)
}

@(private)
Range_Job :: struct {
	body:        proc(data: rawptr, first, last: int),
	data:        rawptr,
	first, last: int,
}

@(private)
range_main :: proc(data: rawptr) {
	r := (^Range_Job)(data)
	r.body(r.data, r.first, r.last)
}

@(private)
pop_locked :: proc(pool: ^Pool) -> (job: Job, ok: bool) {
	if pool.head >= len(pool.queue) do return {}, false
	job = pool.queue[pool.head]
	pool.head += 1
	if pool.head == len(pool.queue) {
		clear(&pool.queue)
		pool.head = 0
	}
	return job, true
}

@(private)
execute :: proc(job: Job) {
	job.fn(job.data)
	intrinsics.atomic_sub(&job.group.pending, 1)
}

@(private)
worker_main :: proc(t: ^thread.Thread) {
	pool := (^Pool)(t.data)
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	for {
		sync.mutex_lock(&pool.mutex)
		job: Job
		ok: bool
		for {
			job, ok = pop_locked(pool)
			if ok || pool.quit do break
			sync.cond_wait(&pool.cond, &pool.mutex)
		}
		sync.mutex_unlock(&pool.mutex)
		if !ok do return
		execute(job)
		free_all(context.temp_allocator)
	}
}
