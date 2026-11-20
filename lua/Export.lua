--[[
	DCS Logbook - Saved Games\DCS\Scripts\Export.lua loader.

	If you do NOT already have an Export.lua, use this file as-is.
	If you DO have one (Tacview, SRS, DCS-BIOS, Helios, VAICOM...), do not
	replace it. Add this single line at the end instead:

		pcall(function() local l = require("lfs"); dofile(l.writedir() .. "Scripts/DCSLogbook/DCSLogbookExport.lua") end)

	The bridge chains onto any callbacks already defined, so both tools keep
	working. install.ps1 performs this edit for you and keeps a backup.
--]]

local ok, lfs_lib = pcall(require, "lfs")
if not ok or not lfs_lib or not lfs_lib.writedir then
	return
end

pcall(dofile, lfs_lib.writedir() .. "Scripts/DCSLogbook/DCSLogbookExport.lua")
