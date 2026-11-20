package main

/*
	Dev-only: runs a Lua 5.1 script (DCS's Lua version) and reports errors.

	Usage: luarun.exe tools\luatest\luatest.lua
*/

import "core:fmt"
import "core:os"
import lua "vendor:lua/5.1"

main :: proc() {
	if len(os.args) < 2 {
		fmt.println("usage: luarun <script.lua>")
		os.exit(2)
	}

	L := lua.L_newstate()
	if L == nil {
		fmt.println("luarun: cannot create Lua state")
		os.exit(2)
	}
	defer lua.close(L)
	lua.L_openlibs(L)

	name := fmt.aprintf("%s", os.args[1])
	defer delete(name)

	if status := lua.L_loadfile(L, cstring(raw_data(name))); status != .OK {
		fmt.println("luarun: load failed:", lua.tostring(L, -1))
		os.exit(1)
	}
	if lua.pcall(L, 0, 0, 0) != 0 {
		fmt.println("luarun: runtime error:", lua.tostring(L, -1))
		os.exit(1)
	}
}
