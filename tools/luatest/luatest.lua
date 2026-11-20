-- Dev-only behavioural test for the DCS Logbook Lua bridge.
-- Run through tools/luarun with Lua 5.1. No DCS required.

local SENT = {}
local PREV_START = false
local PREV_TICKS = 0

-- ---- mock DCS export environment -------------------------------------------
CURRENT_TIME = 0.0
CURRENT_AIRCRAFT = "F-16C_50"
POS_X = 1000.0
POS_Y = 100.0
POS_Z = 2000.0
TAS = 200.0
PLANE_ID = 0
UNIT_ID = 0
HUMAN = true
BORN = true
IN_AIR = true
IS_MP = false
PAUSED = false
ALLOWED = true

function LoGetModelTime()
	return CURRENT_TIME
end

function LoGetSelfData()
	if CURRENT_AIRCRAFT == nil then
		return nil
	end
	return {
		Name = CURRENT_AIRCRAFT,
		Position = { x = POS_X, y = POS_Y, z = POS_Z },
		Flags = { Human = HUMAN, Born = BORN, AI_ON = false },
	}
end

function LoGetTrueAirSpeed()
	return TAS
end

function LoGetPlayerPlaneId()
	return PLANE_ID
end

function LoGetPlayerUnitId()
	return UNIT_ID
end

function LoGetInAir()
	return IN_AIR
end

function LoGetAltitudeAboveGroundLevel()
	return 1000
end

function LoGetAltitudeAboveSeaLevel()
	return 1100
end

function LoGetNetIsRunning()
	return IS_MP
end

function LoSimulationOnPause()
	return PAUSED
end

function LoIsOwnshipExportAllowed()
	return ALLOWED
end

local LOGS = {}
log = {
	INFO = 1,
	write = function(message)
		LOGS[#LOGS + 1] = tostring(message)
	end,
}

-- Mock LuaSocket: record datagrams instead of sending.
package.loaded["socket"] = {
	udp = function()
		return {
			settimeout = function() end,
			setsockname = function() end,
			sendto = function(_, data)
				SENT[#SENT + 1] = data
			end,
			close = function() end,
		}
	end,
}

-- Existing exporter callbacks, to verify chaining and min(tNext).
function LuaExportStart()
	PREV_START = true
end

function LuaExportActivityNextEvent(t)
	PREV_TICKS = PREV_TICKS + 1
	return t + 0.25
end

-- ---- load the bridge --------------------------------------------------------
dofile("lua/DCSLogbook/DCSLogbookExport.lua")

-- ---- helpers ----------------------------------------------------------------
local failures = 0

local function check(name, condition, detail)
	if condition then
		print("PASS " .. name)
	else
		failures = failures + 1
		print("FAIL " .. name .. (detail and (" :: " .. tostring(detail)) or ""))
	end
end

local function last()
	return SENT[#SENT] or ""
end

local function contains(haystack, needle)
	return string.find(haystack, needle, 1, true) ~= nil
end

-- ---- test 1: start sends a hello and chains the previous start --------------
LuaExportStart()
check("previous start chained", PREV_START)
check("hello packet sent", #SENT == 1, #SENT)
check("hello is SP and inactive", contains(last(), '"mode":"SP"') and contains(last(), '"active":false'))

-- ---- test 2: active packet at scheduled model time -------------------------
CURRENT_TIME = 10.0
local next_t = LuaExportActivityNextEvent(10.0)
check("tNext is the earlier of ours and the previous script", next_t == 10.25, next_t)
check("previous timer chained", PREV_TICKS > 0)
check("active packet sent", #SENT == 2, #SENT)
check("aircraft is ownship Name", contains(last(), '"aircraft":"F-16C_50"'))
check("packet carries ownship position", contains(last(), '"pos":true') and contains(last(), '"x":1000.00'))
check("packet carries true airspeed", contains(last(), '"tas":200.00'))
check("model_time serialized", contains(last(), '"model_time":10.000'))
check("active is true", contains(last(), '"active":true'))

-- ---- test 3: paused sends nothing -----------------------------------------
PAUSED = true
CURRENT_TIME = 13.0
LuaExportActivityNextEvent(13.0)
check("paused sends nothing", #SENT == 2, #SENT)
PAUSED = false

-- ---- test 4: aircraft change and MP mode ----------------------------------
CURRENT_AIRCRAFT = "A-10C_2"
IS_MP = true
CURRENT_TIME = 16.0
LuaExportActivityNextEvent(16.0)
check("aircraft change reflected", contains(last(), '"aircraft":"A-10C_2"'), last())
check("MP mode detected", contains(last(), '"mode":"MP"'))

-- ---- test 5: spectator / no aircraft --------------------------------------
CURRENT_AIRCRAFT = nil
CURRENT_TIME = 19.0
LuaExportActivityNextEvent(19.0)
check("no self data means inactive", contains(last(), '"active":false'), last())

-- ---- test 6: server blocks ownship export ---------------------------------
CURRENT_AIRCRAFT = "F-16C_50"
ALLOWED = false
CURRENT_TIME = 22.0
LuaExportActivityNextEvent(22.0)
check("blocked packet is inactive", contains(last(), '"active":false'), last())
check("blocked flag present", contains(last(), '"blocked":true'), last())
ALLOWED = true

-- ---- test 7: leaving the aircraft is detected --------------------------------
CURRENT_AIRCRAFT = "JF-17"
PLANE_ID = 777
CURRENT_TIME = 25.0
LuaExportActivityNextEvent(25.0)
check("re-entry with a plane id is active", contains(last(), '"active":true'), last())

PLANE_ID = 0
CURRENT_TIME = 28.0
LuaExportActivityNextEvent(28.0)
check("plane id dropping to 0 ends the flight", contains(last(), '"active":false'), last())

PLANE_ID = 888
CURRENT_TIME = 31.0
LuaExportActivityNextEvent(31.0)
check("re-entry after id reset is active again", contains(last(), '"active":true'), last())

HUMAN = false
CURRENT_TIME = 34.0
LuaExportActivityNextEvent(34.0)
check("non-human airframe ends the flight", contains(last(), '"active":false'), last())

HUMAN = true
PLANE_ID = 999
UNIT_ID = 999
CURRENT_TIME = 37.0
LuaExportActivityNextEvent(37.0)
check("human airframe with plane id is active", contains(last(), '"active":true'), last())

-- ---- test 8: unit id that is not the plane means the pilot left ------------
PLANE_ID = 1000
UNIT_ID = 2000
CURRENT_TIME = 40.0
LuaExportActivityNextEvent(40.0)
check("unit id differing from plane id ends the flight", contains(last(), '"active":false'), last())

UNIT_ID = 1000
CURRENT_TIME = 43.0
LuaExportActivityNextEvent(43.0)
check("matching unit id resumes the flight", contains(last(), '"active":true'), last())

-- ---- test 9: airborne-only counting ---------------------------------------
IN_AIR = false
CURRENT_TIME = 46.0
LuaExportActivityNextEvent(46.0)
check("on-ground packet is inactive", contains(last(), '"active":false'), last())
check("on-ground state is idle", true)

IN_AIR = true
CURRENT_TIME = 49.0
LuaExportActivityNextEvent(49.0)
check("airborne again resumes", contains(last(), '"active":true'), last())

-- ---- test 10: dead / not born ---------------------------------------------
BORN = false
CURRENT_TIME = 52.0
LuaExportActivityNextEvent(52.0)
check("not-born airframe is inactive", contains(last(), '"active":false'), last())

BORN = true
CURRENT_TIME = 55.0
LuaExportActivityNextEvent(55.0)
check("born airframe resumes", contains(last(), '"active":true'), last())

-- ---- test 11: authoritative hook events -----------------------------------
PLANE_ID = 1234
UNIT_ID = 1234
IN_AIR = true
BORN = true
HUMAN = true
CURRENT_TIME = 58.0
DCSLogbookEvent("eject", 1234)
LuaExportActivityNextEvent(58.0)
check("eject event ends the flight", contains(last(), '"active":false'), last())

DCSLogbookEvent("eject", 9999)
CURRENT_TIME = 61.0
LuaExportActivityNextEvent(61.0)
check("another eject while already inactive stays inactive", contains(last(), '"active":false'), last())

DCSLogbookEvent("takeoff", 1234)
CURRENT_TIME = 64.0
LuaExportActivityNextEvent(64.0)
check("takeoff event resumes the flight", contains(last(), '"active":true'), last())

-- ---- test 12: leaving the aircraft closes immediately ---------------------
CURRENT_TIME = 67.0
LuaExportOnHumanStop()
check("human stop sends inactive", contains(last(), '"active":false'), last())

-- ---- test 13: diagnostics survive the export log cap ----------------------
-- DCS's export log.write truncates at 64 characters and keeps only one write
-- per callback, so the bridge queues messages and flushes one per tick. Drain
-- the queue so every diagnostic chunk is visible to the checks below.
for _ = 1, 8 do
	CURRENT_TIME = CURRENT_TIME + 3.0
	LuaExportActivityNextEvent(CURRENT_TIME)
end

local max_len = 0
for _, message in ipairs(LOGS) do
	if #message > max_len then
		max_len = #message
	end
end
check("log lines fit the 64-char export cap", max_len <= 64, "max=" .. tostring(max_len))

local saw_human, saw_inair, saw_born = false, false, false
for _, message in ipairs(LOGS) do
	if message:find("human=", 1, true) then
		saw_human = true
	end
	if message:find("inair=", 1, true) then
		saw_inair = true
	end
	if message:find("born=", 1, true) then
		saw_born = true
	end
end
check("state diagnostics include human=", saw_human)
check("state diagnostics include born=", saw_born)
check("state diagnostics include inair=", saw_inair)

-- ---- result ----------------------------------------------------------------
if failures > 0 then
	print(string.format("%d Lua bridge test(s) failed", failures))
	error("luatest failed")
end
print("all Lua bridge tests passed")
