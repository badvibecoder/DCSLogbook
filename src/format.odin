package dcslogbook

import "core:fmt"
import "core:time"

// Presentation helpers. Every proc that formats into a caller buffer avoids
// allocation so the paint loop stays allocation-free.

// Seconds -> decimal hours, e.g. 45296 -> "12.58".
format_hours_into :: proc(buf: []u8, seconds: f64) -> string {
	h := seconds / 3600.0
	if h < 0 {
		h = 0
	}
	return fmt.bprintf(buf, "%.2f", h)
}

// Seconds -> hours for dense table cells. Anything non-zero but under 18
// seconds would round to 0.00, so show "<0.01" instead of pretending it is zero.
format_hours_cell_into :: proc(buf: []u8, seconds: f64) -> string {
	h := seconds / 3600.0
	if seconds > 0 && h < 0.005 {
		return fmt.bprintf(buf, "<0.01")
	}
	return fmt.bprintf(buf, "%.2f", h)
}

// Seconds -> clock string: "1:23:45" or "23:45".
format_clock_into :: proc(buf: []u8, seconds: f64) -> string {
	total := int(seconds + 0.5)
	if total < 0 {
		total = 0
	}
	h := total / 3600
	m := (total % 3600) / 60
	s := total % 60
	if h > 0 {
		return fmt.bprintf(buf, "%d:%02d:%02d", h, m, s)
	}
	return fmt.bprintf(buf, "%02d:%02d", m, s)
}

// Seconds -> compact elapsed age: "0.6s", "14s", "2m 05s", "1h 03m".
format_age_into :: proc(buf: []u8, seconds: f64) -> string {
	secs := seconds
	if secs < 0 {
		secs = 0
	}
	if secs < 10 {
		return fmt.bprintf(buf, "%.1fs", secs)
	}
	if secs < 60 {
		return fmt.bprintf(buf, "%ds", int(secs))
	}
	if secs < 3600 {
		s := int(secs)
		return fmt.bprintf(buf, "%dm %02ds", s / 60, s % 60)
	}
	s := int(secs)
	return fmt.bprintf(buf, "%dh %02dm", s / 3600, (s % 3600) / 60)
}

// Metres -> nautical miles for display. Below 10 NM one decimal ("0.4"),
// otherwise whole NM with thousands separators ("1,234"). Returns a string
// over the caller's buffer.
format_nm_into :: proc(buf: []u8, meters: f64) -> string {
	nm := meters / 1852.0
	if nm < 0 {
		nm = 0
	}
	if nm < 10.0 {
		return fmt.bprintf(buf, "%.1f", nm)
	}
	whole := int(nm + 0.5)
	digits_buf: [24]u8
	digits := fmt.bprintf(digits_buf[:], "%d", whole)
	n := 0
	for i in 0 ..< len(digits) {
		if i > 0 && (len(digits) - i) % 3 == 0 {
			if n < len(buf) {
				buf[n] = ','
				n += 1
			}
		}
		if n < len(buf) {
			buf[n] = digits[i]
			n += 1
		}
	}
	return string(buf[:n])
}

// "2026-11-19T02:04:11-06:00" -> "11-19 02:04" (no allocation, returns a copied
// value into `buf`).
format_stamp_short_into :: proc(buf: []u8, rfc3339: string) -> string {
	if len(rfc3339) < 16 {
		return fmt.bprintf(buf, "%s", rfc3339)
	}
	return fmt.bprintf(buf, "%s %s", rfc3339[5:10], rfc3339[11:16])
}

// "2026-11-19T02:04:11-06:00" -> "2026-11-19 02:04:11".
format_stamp_long_into :: proc(buf: []u8, rfc3339: string) -> string {
	if len(rfc3339) < 19 {
		return fmt.bprintf(buf, "%s", rfc3339)
	}
	return fmt.bprintf(buf, "%s %s", rfc3339[0:10], rfc3339[11:19])
}

// Long-lived strings for UI status messages.
format_hours :: proc(seconds: f64) -> string {
	buf: [32]u8
	return fmt.aprintf("%s", format_hours_into(buf[:], seconds))
}

format_clock :: proc(seconds: f64) -> string {
	buf: [32]u8
	return fmt.aprintf("%s", format_clock_into(buf[:], seconds))
}

format_age :: proc(seconds: f64) -> string {
	buf: [32]u8
	return fmt.aprintf("%s", format_age_into(buf[:], seconds))
}

format_stamp_long :: proc(rfc3339: string) -> string {
	buf: [64]u8
	return fmt.aprintf("%s", format_stamp_long_into(buf[:], rfc3339))
}

// Unix seconds for time.Time without going through wall-clock formatting.
unix_seconds :: proc(t: time.Time) -> i64 {
	return time.time_to_unix(t)
}
