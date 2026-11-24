package luajit

import "core:c"
import "core:fmt"
import "core:strings"
import "core:testing"

// Runs `src` as a chunk expecting one result on the stack. Returns LUA_OK or the error status.
exec :: proc(L: ^State, src: cstring) -> c.int {
	if st := loadstring(L, src); st != LUA_OK do return st
	return pcall(L, 0, 1, 0)
}

@(test)
arithmetic_returns_42 :: proc(t: ^testing.T) {
	L := newstate()
	defer close(L)
	openlibs(L)

	testing.expect_value(t, exec(L, "return 6*7"), LUA_OK)
	testing.expect_value(t, tonumber(L, -1), Number(42))
}

@(test)
ffi_sizeof_double_is_8 :: proc(t: ^testing.T) {
	L := newstate()
	defer close(L)
	openlibs(L)

	testing.expect_value(t, exec(L, "local ffi=require('ffi'); return ffi.sizeof('double')"), LUA_OK)
	testing.expect_value(t, tonumber(L, -1), Number(8))
}

@(test)
jit_status_is_true :: proc(t: ^testing.T) {
	L := newstate()
	defer close(L)
	openlibs(L)

	testing.expect_value(t, exec(L, "return jit.status()"), LUA_OK)
	status := toboolean(L, -1) != 0
	fmt.println("jit.status():", status)
	when ODIN_OS == .Darwin || ODIN_OS == .Linux {
		testing.expect(t, status)
	}
}

@(test)
lua_error_is_caught_and_state_survives :: proc(t: ^testing.T) {
	L := newstate()
	defer close(L)
	openlibs(L)

	st := exec(L, "error('boom')")
	testing.expect(t, st != LUA_OK)
	testing.expect(t, strings.contains(tostring(L, -1), "boom"))
	pop(L)

	testing.expect_value(t, exec(L, "return 1"), LUA_OK)
	testing.expect_value(t, tonumber(L, -1), Number(1))
}

@(test)
ref_round_trips_lua_function :: proc(t: ^testing.T) {
	L := newstate()
	defer close(L)
	openlibs(L)

	testing.expect_value(t, exec(L, "return function(x) return x*2 end"), LUA_OK)
	r := ref(L, LUA_REGISTRYINDEX)
	testing.expect(t, r != -1 && r != -2) // LUA_REFNIL / LUA_NOREF

	rawgeti(L, LUA_REGISTRYINDEX, r)
	pushnumber(L, 5)
	testing.expect_value(t, pcall(L, 1, 1, 0), LUA_OK)
	testing.expect_value(t, tonumber(L, -1), Number(10))
	pop(L)

	unref(L, LUA_REGISTRYINDEX, r)
}

@(test)
odin_proc_callable_from_ffi :: proc(t: ^testing.T) {
	L := newstate()
	defer close(L)
	openlibs(L)

	add_one :: proc "c" (x: i32) -> i32 {
		return x + 1
	}
	pushlightuserdata(L, transmute(rawptr)add_one)
	setglobal(L, "fp")

	src: cstring = "local ffi=require('ffi'); local f=ffi.cast('int(*)(int)', fp); return f(41)"
	testing.expect_value(t, exec(L, src), LUA_OK)
	testing.expect_value(t, tonumber(L, -1), Number(42))
}
