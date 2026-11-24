// Minimal binding of the Lua 5.1 C API as implemented by LuaJIT (vendored static lib).
package luajit

import "core:c"

when ODIN_OS == .Windows {
	// Untested: Windows build of the vendored LuaJIT is not verified.
	foreign import lib "../../../third_party/luajit/src/lua51.lib"
} else when ODIN_OS == .Linux {
	foreign import lib {
		"../../../third_party/luajit/src/libluajit.a",
		"system:m",
		"system:dl",
	}
} else when ODIN_OS == .Darwin {
	foreign import lib "../../../third_party/luajit/src/libluajit.a"
} else {
	#panic("luajit: unsupported OS")
}

State :: struct {} // opaque
Number :: f64
Integer :: int // lua_Integer = ptrdiff_t

REGISTRYINDEX :: -10000
GLOBALSINDEX :: -10002
MULTRET :: -1
LUA_MULTRET :: MULTRET
LUA_REGISTRYINDEX :: REGISTRYINDEX
LUA_GLOBALSINDEX :: GLOBALSINDEX
LUA_OK :: 0

LUA_GCSTOP :: 0
LUA_GCRESTART :: 1
LUA_GCCOLLECT :: 2
LUA_GCCOUNT :: 3
LUA_GCCOUNTB :: 4
LUA_GCSTEP :: 5
LUA_GCSETPAUSE :: 6
LUA_GCSETSTEPMUL :: 7
LUA_GCISRUNNING :: 9

@(link_prefix = "lua_")
foreign lib {
	@(link_name = "luaL_newstate") newstate :: proc() -> ^State ---
	close :: proc(L: ^State) ---
	@(link_name = "luaL_openlibs") openlibs :: proc(L: ^State) ---
	@(link_name = "luaL_loadfile") loadfile :: proc(L: ^State, filename: cstring) -> c.int ---
	@(link_name = "luaL_loadstring") loadstring :: proc(L: ^State, s: cstring) -> c.int ---
	pcall :: proc(L: ^State, nargs, nresults, errfunc: c.int) -> c.int ---

	gettop :: proc(L: ^State) -> c.int ---
	settop :: proc(L: ^State, idx: c.int) ---
	pushnil :: proc(L: ^State) ---
	pushnumber :: proc(L: ^State, n: Number) ---
	pushinteger :: proc(L: ^State, n: Integer) ---
	pushboolean :: proc(L: ^State, b: c.int) ---
	pushstring :: proc(L: ^State, s: cstring) ---
	pushlstring :: proc(L: ^State, s: [^]byte, l: c.size_t) ---
	pushlightuserdata :: proc(L: ^State, p: rawptr) ---
	pushvalue :: proc(L: ^State, idx: c.int) ---

	tonumber :: proc(L: ^State, idx: c.int) -> Number ---
	tointeger :: proc(L: ^State, idx: c.int) -> Integer ---
	toboolean :: proc(L: ^State, idx: c.int) -> c.int ---
	tolstring :: proc(L: ^State, idx: c.int, len: ^c.size_t) -> cstring ---
	type :: proc(L: ^State, idx: c.int) -> c.int ---
	isnumber :: proc(L: ^State, idx: c.int) -> c.int ---
	isstring :: proc(L: ^State, idx: c.int) -> c.int ---

	getfield :: proc(L: ^State, idx: c.int, k: cstring) ---
	setfield :: proc(L: ^State, idx: c.int, k: cstring) ---
	rawgeti :: proc(L: ^State, idx: c.int, n: c.int) ---
	rawseti :: proc(L: ^State, idx: c.int, n: c.int) ---
	createtable :: proc(L: ^State, narr, nrec: c.int) ---
	remove :: proc(L: ^State, idx: c.int) ---
	insert :: proc(L: ^State, idx: c.int) ---

	@(link_name = "luaL_ref") ref :: proc(L: ^State, t: c.int) -> c.int ---
	@(link_name = "luaL_unref") unref :: proc(L: ^State, t: c.int, ref: c.int) ---

	gc :: proc(L: ^State, what: c.int, data: c.int) -> c.int ---
	@(link_name = "luaJIT_setmode") setmode :: proc(L: ^State, idx: c.int, mode: c.int) -> c.int ---
}

getglobal :: #force_inline proc(L: ^State, name: cstring) {
	getfield(L, GLOBALSINDEX, name)
}

setglobal :: #force_inline proc(L: ^State, name: cstring) {
	setfield(L, GLOBALSINDEX, name)
}

pop :: #force_inline proc(L: ^State, n: c.int = 1) {
	settop(L, -n - 1)
}

// Borrowed view: valid until the Lua string is popped/collected. "" if not a string/number.
tostring :: proc(L: ^State, idx: c.int) -> string {
	n: c.size_t
	p := tolstring(L, idx, &n)
	if p == nil do return ""
	return string(([^]byte)(rawptr(p))[:n])
}
