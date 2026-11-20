package dcslogbook

import "core:bytes"
import "core:fmt"
import "core:os"
import "core:strings"

/*
	In-app Lua bridge installer.

	The Lua sources are embedded at compile time, so the single .exe can install
	or update the bridge in Saved Games\DCS\Scripts without the user hunting for
	files. This is what keeps "installed bridge version" and "app version" from
	drifting apart.

	What it does, in order:
	  1. find Saved Games\DCS (or DCS.openbeta, or create DCS)
	  2. write Scripts\DCSLogbook\DCSLogbookExport.lua  (atomic replace)
	  3. write Scripts\Hooks\DCSLogbookHook.lua         (atomic replace)
	  4. if Scripts\Export.lua is absent, create it from the loader
	     if it exists and has no DCS Logbook line, back it up and append the
	     self-contained loader line (never clobbers other exporters)

	The user must fully restart DCS afterwards: the export Lua state persists
	across mission restarts, so a running DCS keeps the old bridge in memory.
*/

BRIDGE_VERSION :: "1.0.0"

BRIDGE_LUA :: #load("../lua/DCSLogbook/DCSLogbookExport.lua")
HOOK_LUA :: #load("../lua/Hooks/DCSLogbookHook.lua")
LOADER_LUA :: #load("../lua/Export.lua")

Bridge_Install_Result :: struct {
	ok:      bool,
	message: string,
}

// Paths used by both the installer and the startup status check.
bridge_target_paths :: proc() -> (scripts: string, bridge: string, hook: string, export: string, ok: bool) {
	profile, found := os.lookup_env("USERPROFILE", context.allocator)
	if !found || len(profile) == 0 {
		return "", "", "", "", false
	}

	saved_games := join_path(profile, "Saved Games")
	dcs := join_path(saved_games, "DCS")
	openbeta := join_path(saved_games, "DCS.openbeta")
	if !os.exists(dcs) && os.exists(openbeta) {
		dcs = openbeta
	}

	scripts = join_path(dcs, "Scripts")
	bridge = join_path(scripts, "DCSLogbook\\DCSLogbookExport.lua")
	hook = join_path(scripts, "Hooks\\DCSLogbookHook.lua")
	export = join_path(scripts, "Export.lua")
	return scripts, bridge, hook, export, true
}

// True when DCS has already created its Saved Games folder. Startup auto-install
// uses this so a machine without DCS does not get an empty DCS tree created.
dcs_saved_games_present :: proc() -> bool {
	profile, found := os.lookup_env("USERPROFILE", context.allocator)
	if !found || len(profile) == 0 {
		return false
	}
	saved_games := join_path(profile, "Saved Games")
	return os.exists(join_path(saved_games, "DCS")) || os.exists(join_path(saved_games, "DCS.openbeta"))
}

// Used at startup to show "not installed" / "outdated" in the UI.
bridge_status :: proc() -> (installed: bool, current: bool, path: string) {
	_, bridge_path, _, _, ok := bridge_target_paths()
	if !ok {
		return false, false, ""
	}
	path = bridge_path
	if !os.exists(bridge_path) {
		return false, false, path
	}
	data, err := os.read_entire_file(bridge_path, context.allocator)
	if err != nil {
		return true, false, path
	}
	defer delete(data)
	return true, bytes.equal(data, BRIDGE_LUA), path
}

install_bridge :: proc() -> Bridge_Install_Result {
	scripts, bridge, hook, export, ok := bridge_target_paths()
	if !ok {
		return {false, "Could not find your user profile (USERPROFILE is not set)."}
	}

	if err := os.make_directory_all(join_path(scripts, "DCSLogbook")); err != nil {
		return {
			false,
			fmt.aprintf("Could not create %s:\n%v\n\nThe app may be running in a restricted sandbox.", join_path(scripts, "DCSLogbook"), err),
		}
	}
	if err := os.make_directory_all(join_path(scripts, "Hooks")); err != nil {
		return {
			false,
			fmt.aprintf("Could not create %s:\n%v\n\nThe app may be running in a restricted sandbox.", join_path(scripts, "Hooks"), err),
		}
	}

	if !atomic_write(bridge, BRIDGE_LUA) {
		return {
			false,
			fmt.aprintf("Could not write %s.\n\nThe app may be running in a restricted sandbox; run it from Explorer or a normal PowerShell.", bridge),
		}
	}
	if !atomic_write(hook, HOOK_LUA) {
		return {false, fmt.aprintf("Could not write %s.", hook)}
	}

	loader_line := "\r\n-- DCS Logbook telemetry bridge (added by DCSLogbook)\r\n" +
		"pcall(function() local l = require(\"lfs\"); dofile(l.writedir() .. \"Scripts/DCSLogbook/DCSLogbookExport.lua\") end)\r\n"

	if !os.exists(export) {
		if !atomic_write(export, LOADER_LUA) {
			return {false, fmt.aprintf("Could not create %s.", export)}
		}
	} else {
		data, read_err := os.read_entire_file(export, context.allocator)
		if read_err != nil {
			return {false, fmt.aprintf("Could not read %s:\n%v", export, read_err)}
		}
		has_loader := strings.contains(string(data), "DCSLogbookExport")

		if !has_loader {
			backup := fmt.aprintf("%s.dcslogbook-backup", export)
			if !os.exists(backup) {
				if !atomic_write(backup, data) {
					delete(data)
					return {false, fmt.aprintf("Could not back up %s.", export)}
				}
			}
			if !append_file(export, loader_line) {
				delete(data)
				return {false, fmt.aprintf("Could not append the loader to %s.", export)}
			}
		}
		delete(data)
	}

	return {
		true,
		fmt.aprintf("Lua bridge v%s installed. Fully restart DCS to load it.", BRIDGE_VERSION),
	}
}

append_file :: proc(path: string, text: string) -> bool {
	f, err := os.open(path, {.Write, .Append, .Create})
	if err != nil {
		return false
	}
	if _, write_err := os.write(f, transmute([]byte)text); write_err != nil {
		os.close(f)
		return false
	}
	if flush_err := os.flush(f); flush_err != nil {
		os.close(f)
		return false
	}
	return os.close(f) == nil
}
