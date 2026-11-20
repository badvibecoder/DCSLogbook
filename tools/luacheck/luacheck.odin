package main

/*
	Dev-only: compile-checks Lua files with the exact Lua 5.1 runtime DCS uses
	(Odin's bundled vendor:lua/5.1). It loads each chunk but never executes it.

	Usage: luacheck.exe file1.lua file2.lua ...
*/

import "core:fmt"
import "core:os"
import lua "vendor:lua/5.1"

main :: proc() {
	if len(os.args) < 2 {
		fmt.println("usage: luacheck <file.lua> ...")
		os.exit(2)
	}

	L := lua.L_newstate()
	if L == nil {
		fmt.println("luacheck: cannot create Lua state")
		os.exit(2)
	}
	defer lua.close(L)
	lua.L_openlibs(L)

	failed := false
	for path in os.args[1:] {
		name := fmt.aprintf("%s", path)
		status := lua.L_loadfile(L, cstring(raw_data(name)))
		if status != .OK {
			message := lua.tostring(L, -1)
			fmt.printf("FAIL %s\n  %s\n", path, message)
			failed = true
		} else {
			fmt.printf("OK   %s\n", path)
		}
		lua.settop(L, 0)
		delete(name)
	}

	if failed {
		os.exit(1)
	}
}
