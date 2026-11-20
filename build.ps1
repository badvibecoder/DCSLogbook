# Builds DCS Logbook for 64-bit Windows.
#
#   .\build.ps1                 release GUI binary -> dist\DCSLogbook.exe
#                               (portable: data defaults to dist\DCSLogbookData)
#   .\build.ps1 -Debug          console build with bounds checks -> build\dbg.exe
#   .\build.ps1 -Tools          also build the dev tools (sim/shot/click/closewin/luacheck/luarun)
#                               into build\ (never into dist\)
#
# dist\ is the shippable folder: one exe plus the DCSLogbookData\ folder the app
# creates next to it on first run. build\ holds only the debug binary and the
# dev tools, so a portable logbook never lands inside a build output directory.

param(
    [switch]$Debug,
    [switch]$Tools
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$buildDir = Join-Path $root "build"
$distDir = Join-Path $root "dist"
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
New-Item -ItemType Directory -Force -Path $distDir | Out-Null

$target = "windows_amd64"
$resource = Join-Path $root "assets\dcslogbook.rc"

if ($Debug) {
    $exe = Join-Path $buildDir "dbg.exe"
    Write-Host "odin build (debug console) -> $exe"
    & odin build (Join-Path $root "src") -out:$exe -target:$target -subsystem:console -debug -resource:$resource
}
else {
    $exe = Join-Path $distDir "DCSLogbook.exe"
    Write-Host "odin build (release) -> $exe"
    & odin build (Join-Path $root "src") -out:$exe -target:$target -subsystem:windows -o:speed -resource:$resource
}

if ($LASTEXITCODE -ne 0) {
    throw "odin build failed with exit code $LASTEXITCODE"
}

# Odin emits a compiled .res next to the .rc; the release binary already has the
# resources embedded, so keep the source tree clean.
$resOut = Join-Path $root "assets\dcslogbook.res"
if (Test-Path -LiteralPath $resOut) {
    Remove-Item -LiteralPath $resOut -Force
}

if ($Tools) {
    $toolList = @(
        @{ Name = "sim";      Path = "tools\sim" },
        @{ Name = "shot";     Path = "tools\shot" },
        @{ Name = "click";    Path = "tools\click" },
        @{ Name = "closewin"; Path = "tools\closewin" },
        @{ Name = "luacheck"; Path = "tools\luacheck" },
        @{ Name = "luarun";   Path = "tools\luarun" }
    )
    foreach ($tool in $toolList) {
        $toolOut = Join-Path $buildDir ($tool.Name + ".exe")
        Write-Host "odin build tool -> $toolOut"
        & odin build (Join-Path $root $tool.Path) -out:$toolOut -target:$target -subsystem:console
        if ($LASTEXITCODE -ne 0) {
            throw "odin build $($tool.Name) failed"
        }
    }

    # The Lua dev tools link against Lua 5.1 (the version DCS uses) through
    # Odin's bundled DLL.
    $odinRoot = (& odin root).Trim()
    $luaDll = Join-Path $odinRoot "vendor\lua\5.1\windows\lua5.1.dll"
    if (Test-Path -LiteralPath $luaDll) {
        Copy-Item -LiteralPath $luaDll -Destination $buildDir -Force
        Write-Host "copied lua5.1.dll for luacheck/luarun"
    }
    else {
        Write-Warning "lua5.1.dll not found under $odinRoot; Lua dev tools will not run"
    }
}

Write-Host "Done."
