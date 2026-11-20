# DCS Logbook script installer.
# Copies the Lua bridge into Saved Games\DCS\Scripts and wires it into Export.lua
# without clobbering other exporters (Tacview, SRS, DCS-BIOS, ...).
#
# Usage:
#   .\install.ps1
#   .\install.ps1 -DcsDir "C:\Users\me\Saved Games\DCS.openbeta"
#
# If Windows blocks local scripts, run it with a per-process policy instead of
# elevating:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
# No administrator rights are needed: DCS reads the Saved Games folder of the
# user that runs DCS.

param(
    [string]$DcsDir = ""
)

$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if ($isAdmin) {
    Write-Warning "Running elevated. DCS loads Scripts from the Saved Games folder of the user that runs DCS."
    Write-Warning "If that is not this administrator account, install without elevation (see the comment at the top of this file)."
}

if ([string]::IsNullOrWhiteSpace($DcsDir)) {
    $candidates = @(
        (Join-Path $env:USERPROFILE "Saved Games\DCS"),
        (Join-Path $env:USERPROFILE "Saved Games\DCS.openbeta")
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            $DcsDir = $candidate
            break
        }
    }
}

if ([string]::IsNullOrWhiteSpace($DcsDir) -or -not (Test-Path -LiteralPath $DcsDir)) {
    Write-Error "DCS Saved Games folder not found. Pass -DcsDir 'C:\Users\<you>\Saved Games\DCS'."
    exit 1
}

$root = $PSScriptRoot
$scripts = Join-Path $DcsDir "Scripts"
$bridgeDir = Join-Path $scripts "DCSLogbook"
$hooksDir = Join-Path $scripts "Hooks"

Write-Host "DCS Logbook installer"
Write-Host "  target: $DcsDir"

New-Item -ItemType Directory -Force -Path $bridgeDir | Out-Null
New-Item -ItemType Directory -Force -Path $hooksDir | Out-Null

Copy-Item -LiteralPath (Join-Path $root "lua\DCSLogbook\DCSLogbookExport.lua") -Destination $bridgeDir -Force
Copy-Item -LiteralPath (Join-Path $root "lua\Hooks\DCSLogbookHook.lua") -Destination $hooksDir -Force
Write-Host "  installed bridge + hook"

$loaderLine = 'pcall(function() local l = require("lfs"); dofile(l.writedir() .. "Scripts/DCSLogbook/DCSLogbookExport.lua") end)'
$exportPath = Join-Path $scripts "Export.lua"

if (-not (Test-Path -LiteralPath $exportPath)) {
    Copy-Item -LiteralPath (Join-Path $root "lua\Export.lua") -Destination $exportPath -Force
    Write-Host "  created Scripts\Export.lua"
}
else {
    $contents = Get-Content -LiteralPath $exportPath -Raw
    if ($contents -like "*DCSLogbookExport*") {
        Write-Host "  Scripts\Export.lua already loads the bridge"
    }
    else {
        $backup = "$exportPath.dcslogbook-backup"
        if (-not (Test-Path -LiteralPath $backup)) {
            Copy-Item -LiteralPath $exportPath -Destination $backup
            Write-Host "  backed up existing Export.lua -> $backup"
        }
        $addition = "`r`n-- DCS Logbook telemetry bridge (appended by install.ps1)`r`n$loaderLine`r`n"
        # Append as UTF-8 without a BOM: a BOM mid-file would confuse Lua.
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($exportPath, $addition, $utf8NoBom)
        Write-Host "  appended loader to existing Scripts\Export.lua"
    }
}

Write-Host ""
Write-Host "Done. Start DCSLogbook.exe, then fly."
Write-Host "Data lives in DCSLogbookData\ next to DCSLogbook.exe, always (portable)."
Write-Host "The UDP port is 34900; change it in DCSLogbookExport.lua and pass --port to the app."
Write-Host "Check Saved Games\DCS\Logs\dcs.log for 'DCSLogbook:' lines."
