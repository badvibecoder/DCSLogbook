package dcslogbook

import "core:fmt"
import "core:time"
import win "core:sys/windows"

/*
	Local-time helpers.

	The store keeps human-readable RFC3339 timestamps with a local UTC offset,
	e.g. "2026-11-19T02:04:11-06:00". We deliberately use the Win32 conversion
	(UTC SYSTEMTIME -> tz-specific local SYSTEMTIME) instead of guessing a fixed
	offset, so DST is handled correctly at the moment the stamp is taken.

	Documented assumption: `started_at` / `ended_at` are *local* time with an
	explicit offset, rounded to whole seconds. Any sync service added later should
	prefer the offset-bearing string over re-interpreting it as UTC.
*/

UNIX_EPOCH_AS_FILETIME_SECONDS :: 11_644_473_600
FILETIME_TICKS_PER_SECOND :: 10_000_000

// Returns the tz-specific local breakdown of a Unix timestamp plus the offset in
// minutes east of UTC (e.g. -360 for US Central Standard Time).
local_system_time :: proc(unix_secs: i64) -> (local: win.SYSTEMTIME, offset_min: int, ok: bool) {
	filetime_secs := unix_secs + UNIX_EPOCH_AS_FILETIME_SECONDS
	if filetime_secs < 0 {
		return {}, 0, false
	}
	ticks := u64(filetime_secs) * FILETIME_TICKS_PER_SECOND
	ft := win.FILETIME {
		dwLowDateTime  = u32(ticks & 0xffff_ffff),
		dwHighDateTime = u32(ticks >> 32),
	}
	utc: win.SYSTEMTIME
	if win.FileTimeToSystemTime(&ft, &utc) == win.FALSE {
		return {}, 0, false
	}
	if win.SystemTimeToTzSpecificLocalTime(nil, &utc, &local) == win.FALSE {
		return {}, 0, false
	}

	utc_min := days_from_civil(i64(utc.year), i64(utc.month), i64(utc.day)) * 1440 +
		i64(utc.hour) * 60 + i64(utc.minute)
	local_min := days_from_civil(i64(local.year), i64(local.month), i64(local.day)) * 1440 +
		i64(local.hour) * 60 + i64(local.minute)
	offset_min = int(local_min - utc_min)
	return local, offset_min, true
}

// Civil date -> days since 1970-01-01 (Howard Hinnant's algorithm).
days_from_civil :: proc(y, m, d: i64) -> i64 {
	y2 := y
	if m <= 2 {
		y2 -= 1
	}
	era := y2
	if era < 0 {
		era -= 399
	}
	era /= 400
	yoe := y2 - era * 400
	mp := (m + 9) % 12
	doy := (153 * mp + 2) / 5 + d - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	return era * 146_097 + doe - 719_468
}

// Formats an instant as local RFC3339 with an explicit offset.
// Allocates; call only on segment start/close (a few times per flight).
local_rfc3339 :: proc(t: time.Time) -> string {
	return local_rfc3339_unix(unix_seconds(t))
}

local_rfc3339_unix :: proc(unix_secs: i64) -> string {
	st, offset_min, ok := local_system_time(unix_secs)
	if !ok {
		return fmt.aprintf("%d", unix_secs)
	}
	sign := "+"
	off := offset_min
	if off < 0 {
		sign = "-"
		off = -off
	}
	return fmt.aprintf(
		"%04d-%02d-%02dT%02d:%02d:%02d%s%02d:%02d",
		st.year, st.month, st.day, st.hour, st.minute, st.second,
		sign, off / 60, off % 60,
	)
}

// Current local time as local RFC3339. Allocates.
timestamp_now :: proc() -> string {
	return local_rfc3339(time.now())
}

// Compact local timestamp for filenames: "20261119-020411".
compact_now :: proc() -> string {
	unix := time.time_to_unix(time.now())
	st, _, ok := local_system_time(unix)
	if !ok {
		return fmt.aprintf("%d", unix)
	}
	return fmt.aprintf(
		"%04d%02d%02d-%02d%02d%02d",
		st.year, st.month, st.day, st.hour, st.minute, st.second,
	)
}

// Milliseconds since the process started; cheap monotonic helper for logs.
monotonic_ms :: proc() -> f64 {
	return time.duration_seconds(time.tick_since(BOOT_TICK)) * 1000.0
}

BOOT_TICK: time.Tick = time.tick_now()
