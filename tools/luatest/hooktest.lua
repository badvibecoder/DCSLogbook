-- Dev-only behavioural test for the Hooks event forwarder.
-- Run through tools/luarun with Lua 5.1. No DCS required.

local CAPTURED = nil
local LAST_CODE = nil
local LOGS = {}
local VIA = nil

Sim = {
	setUserCallbacks = function(handler)
		CAPTURED = handler
		VIA = "Sim"
	end,
}

DCS = {
	setUserCallbacks = function(handler)
		CAPTURED = handler
		VIA = "DCS"
	end,
	isMultiplayer = function()
		return true
	end,
}

net = {
	get_my_player_id = function()
		return 7
	end,
	dostring_in = function(environment, code)
		LAST_CODE = code
		return ""
	end,
}

log = {
	INFO = 1,
	write = function(message)
		LOGS[#LOGS + 1] = tostring(message)
	end,
}

dofile("lua/Hooks/DCSLogbookHook.lua")

local failures = 0
local function check(name, condition, detail)
	if condition then
		print("PASS " .. name)
	else
		failures = failures + 1
		print("FAIL " .. name .. (detail and (" :: " .. tostring(detail)) or ""))
	end
end

check("hook registered a callback table", type(CAPTURED) == "table")
check("onGameEvent is present", type(CAPTURED.onGameEvent) == "function")
check("registration used Sim.setUserCallbacks", VIA == "Sim", VIA)
check("hook logged a single registration line", table.concat(LOGS, "\n"):find("cb=Sim", 1, true) ~= nil, table.concat(LOGS, "\n"))

CAPTURED.onGameEvent("eject", 7, 1234)
check(
	"local ejection is forwarded",
	LAST_CODE ~= nil and LAST_CODE:find("DCSLogbookEvent", 1, true) ~= nil and LAST_CODE:find("1234", 1, true) ~= nil,
	LAST_CODE
)

LAST_CODE = nil
CAPTURED.onGameEvent("pilot_death", 7, 1234)
check("pilot death is forwarded", LAST_CODE ~= nil and LAST_CODE:find("pilot_death", 1, true) ~= nil, LAST_CODE)

LAST_CODE = nil
CAPTURED.onGameEvent("eject", 8, 999)
check("another player's ejection is ignored", LAST_CODE == nil, LAST_CODE)

LAST_CODE = nil
CAPTURED.onGameEvent("takeoff", 7, 1234)
check("takeoff is forwarded", LAST_CODE ~= nil and LAST_CODE:find("takeoff", 1, true) ~= nil, LAST_CODE)

LAST_CODE = nil
CAPTURED.onGameEvent("chat_message", 7, 1234)
check("unrelated events are ignored", LAST_CODE == nil, LAST_CODE)

-- Sim absent (older/other builds): fall back to the DCS table.
Sim = nil
VIA = nil
CAPTURED = nil
dofile("lua/Hooks/DCSLogbookHook.lua")
check("falls back to DCS.setUserCallbacks", VIA == "DCS" and type(CAPTURED) == "table", VIA)

if failures > 0 then
	print(string.format("%d hook test(s) failed", failures))
	error("hooktest failed")
end
print("all hook tests passed")
