# DCS Logbook v1.0.0 — Release Notes

Release date: 2026-11-19
Platform: Windows 10/11 x64
License: not yet chosen (decide before publishing if you want others to reuse
the code; the application is distributed as a binary in any case).

## Highlights

First public release. A native, portable DCS World flight log that records
itself while you fly:

- **Automatic flights** — airborne-only time; takeoff starts, landing ends,
  touch-and-go splits.
- **SP / MP / combined hours**, per-aircraft breakdown, segment counts.
- **Real 3D distance in NM** from ownship position, sampled every second —
  loops, turns and climbs count, not just base-to-base distance.
- **Self-installing Lua bridge** — the app writes and updates the DCS bridge
  itself on first launch. No file copying, no config editing.
- **Portable data** — `DCSLogbookData\` next to the executable. Copy the folder,
  move to another PC, keep the logbook.
- **Crash-safe storage** — append-only `flights.jsonl` plus atomic snapshots
  and recovery of an interrupted flight.
- **Click-only UI**, clean native Win32/GDI window, DPI aware.
- **Native app icon** (dark rounded square with yellow "LOG") and Windows
  version metadata (`FileDescription`, `FileVersion 1.0.0.0`) embedded in the
  executable and used for the window/taskbar icon.
- No accounts, no telemetry, no outbound network; loopback UDP only.

## Release artifacts

| File | Size | SHA-256 |
|---|---:|---|
| `DCSLogbook.exe` | 832,512 B | `8AA6E7126FE39583ADEC3A6197FAC24F54B004D0824C195DF702370D7AF85992` |
| `lua/DCSLogbook/DCSLogbookExport.lua` (embedded in the exe) | 17,328 B | `D3818C737E790510C84FB5760C619EE6433391EB9F8A8031F9181DFEE7F9C783` |
| `lua/Hooks/DCSLogbookHook.lua` (embedded in the exe) | 5,159 B | `3F118BC7DEF8CBE925E6D3236EA6EBDDAC66BBA2DD521D96E63FE87B6777F510` |

App and bridge are both **v1.0.0**. The exe embeds the two Lua files above and
installs them automatically; the hashes are listed so an install can be
verified. The exe hash identifies the attached binary — rebuilding from source
produces a byte-different executable (PE build timestamp), so verify the
published artifact rather than a fresh local build.

## Install

1. Put `DCSLogbook.exe` in a writable folder (Documents, Desktop, a games
   folder). Not `Program Files`.
2. Run it. Approve SmartScreen if prompted (**More info → Run anyway**).
3. If DCS is installed, the bridge is installed automatically; otherwise click
   **Install Bridge** once.
4. **Fully restart DCS** (to desktop, then start again).
5. Fly. Data appears in `DCSLogbookData\` next to the exe.

No administrator rights, no tags, no environment variables.

## Upgrade notes

- **From development builds (pre-1.0):** version numbering is reset to 1.0.0.
  On launch, the app detects the older installed bridge and replaces it;
  fully restart DCS afterwards.
- **Data folder:** since the v1.3.0 dev build the logbook is always
  `<exe folder>\DCSLogbookData`. Older development data under
  `%LOCALAPPDATA%\DCSLogbook` or a repo `data\` folder is **not** migrated
  automatically; copy `flights.jsonl` into the new `DCSLogbookData` folder if
  you want to keep it.
- **Existing records** without distance read as `distance_m: 0`; new flights
  accumulate distance normally.

## Verification performed

- Odin `odin check` clean; release built from a clean tree.
- Lua: `luacheck` clean; 37 bridge behaviour checks and 10 hook checks pass.
- Simulation: synthetic 5,000 m position path recorded exactly; TAS fallback
  400 m; a 100 km teleport rejected.
- Real DCS 2.9.31, F-100D, SP and MP:
  - cold and hot start on the ground do not start the timer;
  - airplane takeoff starts the timer, landing stops it, taxi does not count;
  - helicopter hover (1–3 ft) starts, set-down stops;
  - MP mode detection, takeoff and landing work;
  - distance validated in MP: 62 NM recorded on a 40 NM line-of-sight flight
    with many turns; a short flight with loops accumulated the extra path
    correctly.
- UI captured at v1.0.0 for `docs/screenshot.png` (demo data).

## Known issues / limitations

- **Ejection ends at the crash, not at the ejection.** DCS 2.9.31 single-player
  does not expose a usable ejection signal through the export API (the sim keeps
  reporting the pilotless aircraft) and the Hooks `onGameEvent` callback only
  delivers `mission_end`. The flight therefore ends when the aircraft crashes;
  the seconds in between count as time and distance.
- **Time acceleration counts simulated time.** At 8×, one wall minute logs about
  eight flight minutes (distance is unchanged geometry).
- **Multiplayer servers that block ownship export** produce a `blocked` state
  and no logged time for that sortie.
- The executable is **unsigned**; SmartScreen/antivirus may warn.
- A flight is kept only while the app is running; the last packet arrives every
  second while flying.

## Maintainer checklist for publishing

- [ ] Copy this folder (minus `ARCHIVE/`) into the GitHub repository.
- [ ] Confirm `.gitignore` excludes `ARCHIVE/`, `build/`, `dist/`, `data/`,
      `DCSLogbookData/` and test data.
- [ ] Create tag `v1.0.0`.
- [ ] Attach `ARCHIVE\releases\DCSLogbook-v1.0.0-win64.zip` to the GitHub
      release (it contains the exe, README, release notes and screenshots).
      `ARCHIVE\` itself is not committed.
- [ ] Paste these release notes.
- [ ] Choose and add a license, if desired (not included here).
- [ ] Set repository description/topics, e.g. `dcs-world`, `dcs`, `logbook`,
      `flight-hours`, `odin`, `windows`.
- [ ] Link the screenshot in the repository social preview.

## Roadmap

1. **Client/server sync** — move flight data to a server so the logbook persists
   across installations and is available on multiple computers. Per-segment
   `id` and `synced` are already in the data format for this.
2. **Ejection detection** — close the flight at the ejection; the research and
   preserved code are kept in the maintainer archive (not part of the public
   repository).
3. **Optional AGL airborne rule** for modules where `LoGetInAir()` is
   unreliable (parked AGL is non-zero in some modules; needs calibration).
4. **JSON export** back in the UI (backend retained).
