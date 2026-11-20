package dcslogbook

import "core:fmt"
import "core:os"
import "core:sync"

/*
	Minimal append-only diagnostic log. Kept separate from the flight data so a
	crash can never corrupt the history, and so users have something to send when
	reporting "no telemetry" problems.
*/

Log :: struct {
	path: string,
}

log_init :: proc(dir: string) -> Log {
	l := Log {
		path = join_path(dir, "app.log"),
	}
	return l
}

g_log_mutex: sync.Mutex

log_msg :: proc(l: ^Log, format: string, args: ..any) {
	if len(l.path) == 0 {
		return
	}
	buf: [2048]u8
	stamp := fmt.bprintf(buf[:], "%s  ", timestamp_now())
	line := fmt.bprintf(buf[len(stamp):], format, ..args)
	n := len(stamp) + len(line)

	sync.lock(&g_log_mutex)
	defer sync.unlock(&g_log_mutex)
	f, err := os.open(l.path, {.Write, .Append, .Create})
	if err != nil {
		return
	}
	defer os.close(f)
	os.write(f, buf[:n])
	os.write(f, []byte{'\n'})
}
