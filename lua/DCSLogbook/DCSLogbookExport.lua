--[[
	DCS Logbook - telemetry bridge for DCS World (Lua 5.1 export environment).

	What it does
	  Every ~3 seconds of model time, while the player is in an aircraft and the
	  simulation is not paused, send one compact JSON datagram to 127.0.0.1:

	    {"app":"dcslogbook","v":1,"mode":"SP","aircraft":"F-16C_50",
	     "model_time":123.456,"active":true}

	  Nothing else. No per-frame work, no world-object enumeration, no file I/O
	  in the steady state, no allocation when nothing is due. The receiver does
	  all flight-time accounting.

	Why LuaExportActivityNextEvent
	  It is DCS's model-time timer callback: we do the work at the scheduled
	  moment and return t + 3.0. That is the documented low-overhead way to
	  export at a fixed cadence (the stock Export.lua recommends it for reducing
	  traffic), and it avoids touching every render frame entirely.

	Chaining
	  Existing LuaExport* callbacks are captured and still invoked. All of our
	  work is pcall-protected so a bug here can never break another exporter.

	Assumptions (verified against the stock Scripts\Export.lua reference)
	  * LoGetSelfData() returns the LoGetObjectById table for the ownship, whose
	    `Name` is the DCS unit type id ("F-16C_50", "A-10C_2", ...). It returns nil
	    when not in an aircraft (spectator/menu); everything is nil-guarded.
	  * LoGetModelTime() is model time in seconds.
	  * LoSimulationOnPause() / LoSimulationOnActivePause() exist and report pause.
	  * LoGetNetIsRunning() reports whether the session is multiplayer.
	  * LoGetOwnshipExportAllowed() (LoIsOwnshipExportAllowed in some builds)
	    reports whether an MP server allows ownship export.
	  * LuaSocket is available in the export environment (DCS ships it).
--]]

-- Idempotency: the export Lua state persists across mission loads, and DCS
-- re-executes Export.lua for every mission. Without this guard the wrappers
-- would wrap themselves and double-send.
if _G.DCSLogbook_export_installed then
	return
end
_G.DCSLogbook_export_installed = true

local VERSION = "1.0.0"
local HOST = "127.0.0.1"
local PORT = 34900          -- must match DCSLogbook.exe --port (default 34900)
local INTERVAL = 1.0        -- seconds of model time between packets (distance fidelity)
local PAUSE_RECHECK = 0.5   -- re-poll cadence while paused

local udp = nil
local installed = false
local plane_id_seen = false
local last_active = false
local tick_count = 0
local DEBUG_STATE = true
local event_kind = nil
local event_unit = 0
local forced_inactive = false
local forced_plane = nil
local forced_reason = nil

-- Called from the Hooks script through net.dostring_in("export", ...).
-- The hook sees authoritative GameGUI events (eject/crash/pilot_dead/takeoff/
-- landing) that the export API does not expose directly.
function DCSLogbookEvent(kind, unit_id)
	event_kind = tostring(kind or "")
	event_unit = tonumber(unit_id) or 0
end

-- ---------------------------------------------------------------- utilities --

-- DCS's export log.write is fragile in two ways: it truncates the message at 64
-- characters (including the "DCSLogbook: " prefix), and it keeps only ONE write
-- per callback invocation - extra writes in the same tick silently disappear.
-- So messages are split to <=50 chars and queued; emit() flushes at most one per
-- tick (3 s), which never loses a line and is plenty for diagnostics.
local log_queue = {}
local LOG_PAYLOAD_MAX = 50
local LOG_QUEUE_MAX = 64

local function log_write(message)
	local ok = pcall(function()
		if log and log.write then
			log.write("DCSLogbook: " .. message, log.INFO)
		end
	end)
	if ok then
		return
	end
	pcall(function()
		if not (lfs and lfs.writedir) then
			return
		end
		local f = io.open(lfs.writedir() .. "Logs/DCSLogbook.log", "a")
		if f then
			f:write(os.date("%Y-%m-%d %H:%M:%S "), message, "\n")
			f:close()
		end
	end)
end

local function queue_line(message)
	local text = tostring(message or "")
	while #text > LOG_PAYLOAD_MAX do
		local head = text:sub(1, LOG_PAYLOAD_MAX)
		local cut = head:match("^.*() ")
		if not cut or cut < 16 then
			cut = LOG_PAYLOAD_MAX + 1
		end
		log_queue[#log_queue + 1] = text:sub(1, cut - 1)
		text = text:sub(cut + 1):gsub("^%s+", "")
	end
	if #text > 0 then
		log_queue[#log_queue + 1] = text
	end
	while #log_queue > LOG_QUEUE_MAX do
		table.remove(log_queue, 1)
	end
end

local function flush_one()
	local message = table.remove(log_queue, 1)
	if message then
		log_write(message)
	end
end

-- For fatal startup paths with no following tick to flush the queue.
local function log_now(message)
	queue_line(message)
	flush_one()
end

local function call_ok(fn, ...)
	if type(fn) ~= "function" then
		return false, nil
	end
	local ok, result = pcall(fn, ...)
	if not ok then
		return false, nil
	end
	return true, result
end

local function json_escape(value)
	local s = tostring(value or "")
	s = s:gsub("\\", "\\\\")
	s = s:gsub('"', '\\"')
	s = s:gsub("[%z\1-\31]", " ")
	return s
end

-- ------------------------------------------------------------------- state ---

local function is_paused()
	local ok, paused = call_ok(LoSimulationOnPause)
	if ok and paused == true then
		return true
	end
	ok, paused = call_ok(LoSimulationOnActivePause)
	if ok and paused == true then
		return true
	end
	return false
end

local function ownship_export_allowed()
	local ok, allowed = call_ok(LoIsOwnshipExportAllowed)
	if not ok then
		ok, allowed = call_ok(LoGetOwnshipExportAllowed)
	end
	if ok and allowed == false then
		return false
	end
	return true
end

-- Multiplayer detection from the export environment. Prefer LoGetNetIsRunning
-- (documented in the stock Export.lua); fall back to the hook-state DCS table if
-- a future build exposes it here.
local function current_mode()
	local ok, running = call_ok(LoGetNetIsRunning)
	if ok and running ~= nil then
		if running then
			return "MP"
		end
		return "SP"
	end
	if DCS and DCS.isMultiplayer then
		local ok2, mp = pcall(DCS.isMultiplayer)
		if ok2 and mp ~= nil then
			if mp then
				return "MP"
			end
			return "SP"
		end
	end
	return "SP"
end

local function number_or_nil(fn)
	local ok, value = call_ok(fn)
	if ok and type(value) == "number" then
		return value
	end
	return nil
end

local function boolean_or_nil(fn)
	local ok, value = call_ok(fn)
	if ok and type(value) == "boolean" then
		return value
	end
	return nil
end

-- Returns ownship name, an inactive reason (or nil), and a diagnostic snapshot.
--
-- Flight time is only counted while the player is actually in control of an
-- aircraft and airborne. DCS export signals are inconsistent across modules and
-- after an ejection (the airframe can keep being reported), so several
-- independent checks are used; each is applied only when the build reports it:
--   * LoGetPlayerPlaneId() dropping to 0 after having been positive
--   * LoGetPlayerUnitId() different from the plane id (player left the aircraft)
--   * Flags.Human == false  (airframe no longer player-flown)
--   * Flags.Born == false   (unit not alive/spawned)
--   * LoGetInAir() == false (on the ground, taxiing, landed)
local function ownship_state()
	local info = {
		plane = number_or_nil(LoGetPlayerPlaneId),
		unit = number_or_nil(LoGetPlayerUnitId),
		in_air = boolean_or_nil(LoGetInAir),
		agl = number_or_nil(LoGetAltitudeAboveGroundLevel),
		alt = number_or_nil(LoGetAltitudeAboveSeaLevel),
		human = nil,
		born = nil,
		ai = nil,
		name = nil,
		px = nil,
		py = nil,
		pz = nil,
		tas = nil,
	}

	if info.plane then
		if info.plane > 0 then
			plane_id_seen = true
		elseif plane_id_seen then
			return nil, "left_aircraft", info
		end
	end

	if info.plane and info.unit and info.plane > 0 and info.unit > 0 and info.plane ~= info.unit then
		return nil, "not_in_aircraft", info
	end

	local ok, data = call_ok(LoGetSelfData)
	if not ok or type(data) ~= "table" then
		return nil, "no_self_data", info
	end
	info.name = data.Name
	-- Ownship position, in DCS internal coordinates (metres). LoGetSelfData is
	-- not gated by the object-export setting, so distance keeps working on MP
	-- servers that block object export. TAS is the fallback if Position is ever
	-- missing.
	if type(data.Position) == "table" then
		local p = data.Position
		if type(p.x) == "number" and type(p.y) == "number" and type(p.z) == "number" then
			info.px, info.py, info.pz = p.x, p.y, p.z
		end
	end
	info.tas = number_or_nil(LoGetTrueAirSpeed)
	if type(info.name) ~= "string" or #info.name == 0 then
		return nil, "no_aircraft", info
	end

	local flags = data.Flags
	if type(flags) == "table" then
		info.human = flags.Human
		info.born = flags.Born
		info.ai = flags.AI_ON
	end
	if info.human == false then
		return nil, "not_human", info
	end
	if info.born == false then
		return nil, "not_born", info
	end
	if info.in_air == false then
		return nil, "on_ground", info
	end
	return info.name, nil, info
end

local function consume_event(info)
	if not event_kind then
		return
	end
	local kind = event_kind
	local unit = event_unit
	event_kind = nil

	local plane = info and info.plane or nil
	-- The hook already filters to the local player. Its unit argument is the
	-- mission ID, which never equals the export object ID, so comparing them here
	-- would discard every valid event.
	if kind == "eject" or kind == "crash" or kind == "pilot_dead" or kind == "pilot_death" then
		forced_inactive = true
		forced_plane = plane
		forced_reason = kind
		queue_line(
			"event "
				.. kind
				.. " unit="
				.. tostring(unit)
				.. " plane="
				.. tostring(plane)
				.. " -> inactive"
		)
	elseif kind == "landing" then
		forced_inactive = true
		forced_plane = plane
		forced_reason = "landed"
		queue_line("event landing -> inactive (airborne-only)")
	elseif kind == "takeoff" then
		forced_inactive = false
		forced_plane = nil
		forced_reason = nil
		queue_line("event takeoff -> active")
	end
end

local function clear_stale_forced(info)
	if not forced_inactive or not forced_plane then
		return
	end
	if info and info.plane and info.plane > 0 and info.plane ~= forced_plane then
		forced_inactive = false
		forced_plane = nil
		forced_reason = nil
		queue_line("new aircraft id -> cleared forced inactive")
	end
end

local function state_text(info, reason)
	return string.format(
		"state reason=%s name=%s plane=%s unit=%s human=%s born=%s ai=%s inair=%s agl=%s alt=%s",
		tostring(reason or "ok"),
		tostring(info and info.name),
		tostring(info and info.plane),
		tostring(info and info.unit),
		tostring(info and info.human),
		tostring(info and info.born),
		tostring(info and info.ai),
		tostring(info and info.in_air),
		tostring(info and info.agl),
		tostring(info and info.alt)
	)
end

local function model_time()
	local ok, t = call_ok(LoGetModelTime)
	if ok and type(t) == "number" then
		return t
	end
	return nil
end

-- ------------------------------------------------------------------ sending --

local function send(payload)
	if not udp then
		return false
	end
	local ok = pcall(function()
		udp:sendto(payload, HOST, PORT)
	end)
	return ok
end

-- Builds and sends one packet. `want_active` is the player-state hint; the
-- packet is only marked active when an actual aircraft name is available.
local function emit(want_active)
	local mode = current_mode()
	local allowed = ownship_export_allowed()
	local aircraft = ""
	local reason = nil
	local info = nil
	if allowed then
		aircraft, reason, info = ownship_state()
		aircraft = aircraft or ""
	else
		reason = "export_blocked"
	end
	consume_event(info)
	clear_stale_forced(info)

	local t = model_time()
	if t == nil then
		return false
	end
	local active = (want_active == true) and allowed and (aircraft ~= "") and not forced_inactive
	if forced_inactive and forced_reason then
		reason = forced_reason
	end

	tick_count = tick_count + 1
	if active ~= last_active then
		last_active = active
		queue_line("active=" .. tostring(active) .. " (" .. tostring(reason or "ok") .. ")")
		queue_line(state_text(info, reason))
	elseif DEBUG_STATE and tick_count % 10 == 0 then
		queue_line(state_text(info, reason))
	end

	local extra = ""
	if info and info.px then
		extra = string.format(
			',"pos":true,"x":%.2f,"y":%.2f,"z":%.2f',
			info.px,
			info.py,
			info.pz
		)
	end
	if info and info.tas then
		extra = extra .. string.format(',"tas":%.2f', info.tas)
	end

	local payload = string.format(
		'{"app":"dcslogbook","v":1,"mode":"%s","aircraft":"%s","model_time":%.3f,"active":%s%s%s}',
		mode,
		json_escape(aircraft),
		t,
		active and "true" or "false",
		extra,
		(not allowed) and ',"blocked":true' or ""
	)
	local sent = send(payload)
	flush_one()
	return sent
end

-- ----------------------------------------------------------------- lifecycle -

-- LuaSocket loading.
--
-- DCS ships LuaSocket as a wrapper (LuaSocket\socket.lua) plus one
-- lua-socket.dll that exports only luaopen_socket_core. DCS's package.cpath
-- contains "lua-?.dll", so require("socket") resolves that DLL and then fails
-- with "specified procedure could not be found", while require("socket.core")
-- resolves the exported symbol and works. Try both, then the conventional
-- folder layouts, then an explicit package.loadlib.
local function load_socket_library()
	local ok, mod = pcall(require, "socket")
	if ok then
		if mod == true then
			mod = package.loaded["socket"]
		end
		if type(mod) == "table" and mod.udp then
			return mod
		end
	end

	local ok_core, core = pcall(require, "socket.core")
	if ok_core then
		if core == true then
			core = package.loaded["socket.core"]
		end
		if type(core) == "table" and core.udp then
			return core
		end
	end

	local cwd = nil
	pcall(function()
		cwd = require("lfs").currentdir()
	end)
	if not cwd then
		return nil
	end

	local lua_paths = {
		cwd .. "/LuaSocket/?.lua",
		cwd .. "/Scripts/LuaSocket/?.lua",
		cwd .. "/../Scripts/LuaSocket/?.lua",
		cwd .. "/../LuaSocket/?.lua",
	}
	for _, path in ipairs(lua_paths) do
		package.path = package.path .. ";" .. path
	end

	local c_paths = {
		cwd .. "/lua-?.dll",
		cwd .. "/?.dll",
		cwd .. "/LuaSocket/?.dll",
		cwd .. "/../bin-mt/lua-?.dll",
		cwd .. "/../bin/lua-?.dll",
	}
	for _, path in ipairs(c_paths) do
		package.cpath = package.cpath .. ";" .. path
	end

	ok, mod = pcall(require, "socket")
	if ok then
		if mod == true then
			mod = package.loaded["socket"]
		end
		if type(mod) == "table" and mod.udp then
			return mod
		end
	end

	ok_core, core = pcall(require, "socket.core")
	if ok_core and type(core) == "table" and core.udp then
		return core
	end

	local dlls = {
		cwd .. "/lua-socket.dll",
		cwd .. "/../bin-mt/lua-socket.dll",
		cwd .. "/../bin/lua-socket.dll",
	}
	for _, dll in ipairs(dlls) do
		local loader = package.loadlib(dll, "luaopen_socket_core")
		if loader then
			local loaded, lib = pcall(loader)
			if loaded and type(lib) == "table" and lib.udp then
				return lib
			end
		end
	end

	return nil
end

local function bridge_start()
	local socket_lib = load_socket_library()
	if not socket_lib then
		log_now("LuaSocket unavailable - telemetry disabled")
		return
	end

	local s = socket_lib.udp()
	if not s then
		log_now("could not create UDP socket - telemetry disabled")
		return
	end
	pcall(function()
		s:settimeout(0)          -- never block the simulation thread
	end)
	pcall(function()
		s:setsockname("*", 0)    -- ephemeral local port; avoids ICMP resets
	end)
	udp = s
	installed = true
	queue_line("bridge ready (v" .. VERSION .. ") -> " .. HOST .. ":" .. PORT)
	-- Immediate hello: lets the companion app show SP/MP before the first 3s tick.
	pcall(emit, false)
end

local function bridge_stop()
	if udp then
		pcall(emit, false)
		pcall(function()
			udp:close()
		end)
		udp = nil
	end
	installed = false
end

-- Timer callback: called by DCS at the model time we return.
local function bridge_tick(t)
	if not udp then
		return t + INTERVAL
	end
	if is_paused() then
		-- Do not accrue time while paused. Re-check soon; if model time is frozen
		-- DCS simply will not call us until it advances again.
		return t + PAUSE_RECHECK
	end
	pcall(emit, true)
	return t + INTERVAL
end

-- --------------------------------------------------------------- chaining ----

local prev = {
	start = LuaExportStart,
	stop = LuaExportStop,
	activity_next = LuaExportActivityNextEvent,
	human_start = LuaExportOnHumanStart,
	human_stop = LuaExportOnHumanStop,
}

function LuaExportStart()
	if type(prev.start) == "function" then
		pcall(prev.start)
	end
	pcall(bridge_start)
end

function LuaExportStop()
	pcall(bridge_stop)
	if type(prev.stop) == "function" then
		pcall(prev.stop)
	end
end

function LuaExportActivityNextEvent(t)
	local mine = t + INTERVAL
	if udp then
		local ok, next_t = pcall(bridge_tick, t)
		if ok and type(next_t) == "number" then
			mine = next_t
		end
	end
	if type(prev.activity_next) == "function" then
		local ok, theirs = pcall(prev.activity_next, t)
		if ok and type(theirs) == "number" and theirs > t and theirs < mine then
			mine = theirs
		end
	end
	return mine
end

function LuaExportOnHumanStart()
	if type(prev.human_start) == "function" then
		pcall(prev.human_start)
	end
	pcall(emit, true)
end

function LuaExportOnHumanStop()
	if type(prev.human_stop) == "function" then
		pcall(prev.human_stop)
	end
	-- Tell the app immediately, so the segment closes now instead of after the
	-- 20s stale timeout.
	pcall(emit, false)
end
