--[[
	DCS Logbook - Hooks diagnostics and flight-state events.

	Saved Games\DCS\Scripts\Hooks\DCSLogbookHook.lua

	Hooks scripts load once per DCS process (not per mission) in DCS's GUI Lua
	state. That state is separate from Export.lua, so this script cannot install
	the telemetry bridge itself. Its jobs are:

	  * report the install state and callback registration in one dcs.log line
	  * forward authoritative player events (eject/crash/pilot death/takeoff/
	    landing) into the export Lua state with net.dostring_in

	Registration went through DCS.setUserCallbacks in v1.2.0 and silently did
	nothing: DCS's own Sim_ControlAPI.md says hooks call Sim.setUserCallbacks.
	This version tries Sim first, then both DCS spellings, and reports which one
	took effect.

	DCS's log.write keeps only ONE message per callback invocation, so this file
	writes exactly one line at load and one line per event.
--]]

local VERSION = "1.0.0"

local function log_line(message)
	local ok = pcall(function()
		local level = (log and log.INFO) or 0
		log.write("DCSLogbook: " .. message, level)
	end)
	if not ok then
		pcall(function()
			if lfs and lfs.writedir then
				local f = io.open(lfs.writedir() .. "Logs\\DCSLogbook.log", "a")
				if f then
					f:write(os.date("%Y-%m-%d %H:%M:%S "), message, "\n")
					f:close()
				end
			end
		end)
	end
end

-- Returns a short status token instead of logging, so the whole load emits one
-- line: ok | no_lfs | no_bridge | no_export | no_loader.
local function install_status()
	local ok, lfs_lib = pcall(require, "lfs")
	if not ok or not lfs_lib or not lfs_lib.writedir then
		return "no_lfs"
	end

	local scripts = lfs_lib.writedir() .. "Scripts\\"
	local bridge = scripts .. "DCSLogbook\\DCSLogbookExport.lua"
	local export = scripts .. "Export.lua"

	local bridge_file = io.open(bridge, "r")
	if not bridge_file then
		return "no_bridge"
	end
	bridge_file:close()

	local export_file = io.open(export, "r")
	if not export_file then
		return "no_export"
	end
	local contents = export_file:read("*a")
	export_file:close()

	if not contents:find("DCSLogbookExport", 1, true) then
		return "no_loader"
	end
	return "ok"
end

local install_state = "unknown"
pcall(function()
	install_state = install_status()
end)

--[[
	Simulation callbacks (DCS Sim_ControlAPI.md):

	  onGameEvent(eventName, arg1, arg2, arg3, arg4)

	  "eject",       playerID, unit_missionID
	  "crash",       playerID, unit_missionID
	  "pilot_death", playerID, unit_missionID
	  "takeoff",     playerID, unit_missionID, airdromeName
	  "landing",     playerID, unit_missionID, airdromeName

	The export API cannot see these directly and can keep reporting the airframe
	after an ejection, so they are forwarded into the export state and the bridge
	closes the segment immediately.
--]]

local RELEVANT_EVENTS = {
	eject = true,
	crash = true,
	pilot_dead = true,
	pilot_death = true,
	takeoff = true,
	landing = true,
}

local function my_player_id()
	local ok, id = pcall(function()
		if net and net.get_my_player_id then
			return net.get_my_player_id()
		end
	end)
	if ok then
		return tonumber(id)
	end
	return nil
end

local function multiplayer()
	local ok, value = pcall(function()
		if DCS and DCS.isMultiplayer then
			return DCS.isMultiplayer()
		end
	end)
	return ok and value == true
end

local function notify_export(kind, unit_id)
	local code = string.format(
		"if DCSLogbookEvent then DCSLogbookEvent(%q, %d) end",
		kind,
		tonumber(unit_id) or 0
	)
	pcall(function()
		if net and net.dostring_in then
			net.dostring_in("export", code)
		end
	end)
end

local handler = {}
local seen_events = {}

function handler.onGameEvent(eventName, arg1, arg2, arg3, arg4)
	local name = tostring(eventName)

	if not RELEVANT_EVENTS[name] then
		if not seen_events[name] then
			seen_events[name] = true
			log_line("ev " .. name)
		end
		return
	end

	local player_id = tonumber(arg1)
	local unit_id = tonumber(arg2) or 0
	if multiplayer() then
		local me = my_player_id()
		if me and player_id and me ~= player_id then
			return
		end
	end
	log_line("event " .. name .. " p=" .. tostring(player_id) .. " u=" .. tostring(unit_id))
	notify_export(name, unit_id)
end

-- Hooks register with Sim.setUserCallbacks (DCS's Sim_ControlAPI.md). Some
-- builds/community notes expose DCS.setUserCallbacks instead, and the wiki also
-- spells it setUserCallBacks, so try all three and report which one took.
local registered_via = nil
pcall(function()
	if type(Sim) == "table" and type(Sim.setUserCallbacks) == "function" then
		Sim.setUserCallbacks(handler)
		registered_via = "Sim"
	elseif type(DCS) == "table" and type(DCS.setUserCallbacks) == "function" then
		DCS.setUserCallbacks(handler)
		registered_via = "DCS"
	elseif type(DCS) == "table" and type(DCS.setUserCallBacks) == "function" then
		DCS.setUserCallBacks(handler)
		registered_via = "DCS2"
	end
end)

local has_dostring = false
pcall(function()
	has_dostring = (net and type(net.dostring_in) == "function") or false
end)

log_line(
	"hook v"
		.. VERSION
		.. " cb="
		.. tostring(registered_via or "NONE")
		.. " ds="
		.. (has_dostring and "1" or "0")
		.. " br="
		.. install_state
)
