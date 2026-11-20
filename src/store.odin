package dcslogbook

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

/*
	Persistence.

	Two files, with distinct jobs:

	  flights.jsonl  Append-only history. One JSON object per completed segment.
	                 Appended on every segment close, flushed immediately. It is
	                 the authoritative log; a torn final line is tolerated on load.

	  flights.json   Materialized snapshot: segments + derived totals, written
	                 atomically (temp file -> FlushFileBuffers -> MoveFileEx with
	                 replace). Serves as a human-readable cache and as a crash
	                 backup if flights.jsonl is lost.

	  active.json    The currently open segment, written every 60s and on demand.
	                 If the app is killed, it is recovered into a segment on the
	                 next start.

	Load order: jsonl first, then snapshot, de-duplicated by segment id. This
	makes the snapshot a genuine backup without double-counting.
*/

SCHEMA_JSON :: 1

join_path :: proc(parts: ..string) -> string {
	joined, err := filepath.join(parts)
	if err != nil {
		return ""
	}
	return joined
}

Snapshot_JSON :: struct {
	schema:       int          `json:"schema"`,
	app:          string       `json:"app"`,
	app_version:  string       `json:"app_version"`,
	generated_at: string       `json:"generated_at"`,
	totals:       Totals_JSON  `json:"totals"`,
	segments:     []Segment    `json:"segments"`,
}

Totals_JSON :: struct {
	sp_seconds:        f64            `json:"sp_seconds"`,
	mp_seconds:        f64            `json:"mp_seconds"`,
	combined_seconds:  f64            `json:"combined_seconds"`,
	sp_distance_m:     f64            `json:"sp_distance_m"`,
	mp_distance_m:     f64            `json:"mp_distance_m"`,
	combined_distance_m: f64          `json:"combined_distance_m"`,
	sp_hours:          f64            `json:"sp_hours"`,
	mp_hours:          f64            `json:"mp_hours"`,
	combined_hours:    f64            `json:"combined_hours"`,
	segment_count:     int            `json:"segment_count"`,
	sp_segment_count:  int            `json:"sp_segment_count"`,
	mp_segment_count:  int            `json:"mp_segment_count"`,
	aircraft_count:    int            `json:"aircraft_count"`,
	per_aircraft:      []Aircraft_Stat `json:"per_aircraft"`,
}

Active_JSON :: struct {
	schema:     int    `json:"schema"`,
	aircraft:   string `json:"aircraft"`,
	mode:       string `json:"mode"`,
	seconds:    f64    `json:"seconds"`,
	distance_m: f64    `json:"distance_m"`,
	started_at: string `json:"started_at"`,
	updated_at: string `json:"updated_at"`,
	model_time: f64    `json:"model_time"`,
}

Store :: struct {
	dir:           string,
	jsonl_path:    string,
	snapshot_path: string,
	active_path:   string,
	export_dir:    string,
	segments:      [dynamic]Segment,
	totals:        Totals,
	jsonl_file:    ^os.File,
	bad_lines:     int,
	dropped:       int,
	last_saved:    string,
	last_error:    string,
	loaded_jsonl:  int,
	loaded_snap:   int,
}

store_init :: proc(dir: string) -> (s: Store, ok: bool) {
	s.dir = dir
	s.jsonl_path = join_path(dir, "flights.jsonl")
	s.snapshot_path = join_path(dir, "flights.json")
	s.active_path = join_path(dir, "active.json")
	s.export_dir = join_path(dir, "exports")
	s.totals.per_aircraft = make(map[string]Aircraft_Stat)

	if err := os.make_directory_all(dir); err != nil {
		s.last_error = fmt.aprintf("cannot create data directory %q: %v", dir, err)
		return s, false
	}

	store_load(&s)
	return s, true
}

// ---------------------------------------------------------------- loading ----

store_load :: proc(s: ^Store) {
	seen := make(map[string]bool)
	defer delete(seen)

	if os.exists(s.jsonl_path) {
		store_load_jsonl(s, &seen)
	}
	if os.exists(s.snapshot_path) {
		store_load_snapshot(s, &seen)
	}
	store_recompute_totals(s)
}

store_load_jsonl :: proc(s: ^Store, seen: ^map[string]bool) {
	data, err := os.read_entire_file(s.jsonl_path, context.allocator)
	if err != nil {
		s.last_error = fmt.aprintf("cannot read %s: %v", s.jsonl_path, err)
		return
	}
	defer delete(data)

	start := 0
	for i in 0 ..< len(data) {
		if data[i] != '\n' {
			continue
		}
		store_parse_segment_line(s, data[start:i], seen)
		start = i + 1
	}
	if start < len(data) {
		// Tolerate a torn trailing line (power loss mid-append).
		store_parse_segment_line(s, data[start:], seen)
	}
}

store_parse_segment_line :: proc(s: ^Store, raw: []byte, seen: ^map[string]bool) {
	line := strings.trim_space(string(raw))
	if len(line) == 0 {
		return
	}
	segment: Segment
	if err := json.unmarshal(transmute([]byte)line, &segment); err != nil {
		s.bad_lines += 1
		return
	}
	store_accept_segment(s, segment, seen)
	s.loaded_jsonl += 1
}

store_load_snapshot :: proc(s: ^Store, seen: ^map[string]bool) {
	data, err := os.read_entire_file(s.snapshot_path, context.allocator)
	if err != nil {
		s.last_error = fmt.aprintf("cannot read %s: %v", s.snapshot_path, err)
		return
	}
	defer delete(data)

	snap: Snapshot_JSON
	if err := json.unmarshal(data, &snap); err != nil {
		s.bad_lines += 1
		return
	}
	for segment in snap.segments {
		store_accept_segment(s, segment, seen)
		s.loaded_snap += 1
	}
}

store_accept_segment :: proc(s: ^Store, raw: Segment, seen: ^map[string]bool) {
	segment := raw
	segment.aircraft = strings.trim_space(segment.aircraft)
	if segment.aircraft == "" {
		segment.aircraft = "Unknown"
	}
	if !mode_valid(segment.mode) {
		s.bad_lines += 1
		return
	}
	if !(segment.seconds > 0) || segment.seconds != segment.seconds {
		s.bad_lines += 1
		return
	}
	if segment.id == "" {
		segment.id = make_id()
	}
	if segment.id in seen^ {
		return
	}
	seen^[segment.id] = true
	if len(s.segments) >= MAX_LOAD_SEGMENTS {
		s.bad_lines += 1
		return
	}
	append(&s.segments, segment)
}

store_recompute_totals :: proc(s: ^Store) {
	clear(&s.totals.per_aircraft)
	s.totals.sp_seconds = 0
	s.totals.mp_seconds = 0
	s.totals.sp_distance_m = 0
	s.totals.mp_distance_m = 0
	s.totals.segment_count = 0
	s.totals.sp_segment_count = 0
	s.totals.mp_segment_count = 0
	for segment in s.segments {
		totals_add(&s.totals, segment)
	}
}

// ---------------------------------------------------------------- mutation ---

store_add_segment :: proc(s: ^Store, segment: Segment) -> bool {
	if segment.seconds < MIN_SEGMENT_SECONDS {
		s.dropped += 1
		return false
	}
	append(&s.segments, segment)
	totals_add(&s.totals, segment)

	appended := store_append_jsonl(s, segment)
	// Always materialize the snapshot too: it is the backup path if the
	// append-only log is damaged or deleted by the user.
	store_write_snapshot(s)
	return appended
}

totals_add :: proc(t: ^Totals, segment: Segment) {
	switch segment.mode {
	case MODE_SP:
		t.sp_seconds += segment.seconds
		t.sp_distance_m += segment.distance_m
		t.sp_segment_count += 1
	case MODE_MP:
		t.mp_seconds += segment.seconds
		t.mp_distance_m += segment.distance_m
		t.mp_segment_count += 1
	case:
		return
	}
	t.segment_count += 1

	stat := t.per_aircraft[segment.aircraft]
	stat.aircraft = segment.aircraft
	stat.segments += 1
	switch segment.mode {
	case MODE_SP:
		stat.sp_seconds += segment.seconds
		stat.sp_distance_m += segment.distance_m
	case MODE_MP:
		stat.mp_seconds += segment.seconds
		stat.mp_distance_m += segment.distance_m
	}
	if segment.ended_at != "" {
		stat.last_flown = segment.ended_at
	}
	t.per_aircraft[segment.aircraft] = stat
}

store_append_jsonl :: proc(s: ^Store, segment: Segment) -> bool {
	if s.jsonl_file == nil {
		f, err := os.open(s.jsonl_path, {.Write, .Append, .Create})
		if err != nil {
			s.last_error = fmt.aprintf("cannot open %s: %v", s.jsonl_path, err)
			return false
		}
		s.jsonl_file = f
	}
	data, err := json.marshal(segment)
	if err != nil {
		s.last_error = fmt.aprintf("cannot encode segment: %v", err)
		return false
	}
	defer delete(data)

	if _, werr := os.write(s.jsonl_file, data); werr != nil {
		s.last_error = fmt.aprintf("cannot append to %s: %v", s.jsonl_path, werr)
		return false
	}
	if _, werr := os.write(s.jsonl_file, []byte{'\n'}); werr != nil {
		s.last_error = fmt.aprintf("cannot append newline: %v", werr)
		return false
	}
	// FlushFileBuffers: the line is durable before we report success.
	if ferr := os.flush(s.jsonl_file); ferr != nil {
		s.last_error = fmt.aprintf("cannot flush %s: %v", s.jsonl_path, ferr)
		return false
	}
	return true
}

// ----------------------------------------------------------------- snapshots -

store_write_snapshot :: proc(s: ^Store) -> bool {
	data, ok := store_marshal_snapshot(s)
	if !ok {
		return false
	}
	defer delete(data)
	if !atomic_write(s.snapshot_path, data) {
		s.last_error = fmt.aprintf("cannot write snapshot %s", s.snapshot_path)
		return false
	}
	s.last_saved = timestamp_now()
	return true
}

store_marshal_snapshot :: proc(s: ^Store) -> (data: []byte, ok: bool) {
	aircraft := store_sorted_aircraft(s)
	defer delete(aircraft)

	totals := Totals_JSON {
		sp_seconds       = s.totals.sp_seconds,
		mp_seconds       = s.totals.mp_seconds,
		combined_seconds = s.totals.sp_seconds + s.totals.mp_seconds,
		sp_distance_m    = s.totals.sp_distance_m,
		mp_distance_m    = s.totals.mp_distance_m,
		combined_distance_m = s.totals.sp_distance_m + s.totals.mp_distance_m,
		sp_hours         = s.totals.sp_seconds / 3600.0,
		mp_hours         = s.totals.mp_seconds / 3600.0,
		combined_hours   = (s.totals.sp_seconds + s.totals.mp_seconds) / 3600.0,
		segment_count    = s.totals.segment_count,
		sp_segment_count = s.totals.sp_segment_count,
		mp_segment_count = s.totals.mp_segment_count,
		aircraft_count   = len(aircraft),
		per_aircraft     = aircraft[:],
	}

	snap := Snapshot_JSON {
		schema       = SCHEMA_JSON,
		app          = "dcslogbook",
		app_version  = APP_VERSION,
		generated_at = timestamp_now(),
		totals       = totals,
		segments     = s.segments[:],
	}

	encoded, err := json.marshal(snap, {pretty = true, use_spaces = true, spaces = 2})
	if err != nil {
		s.last_error = fmt.aprintf("cannot encode snapshot: %v", err)
		return nil, false
	}
	return encoded, true
}

store_sorted_aircraft :: proc(s: ^Store) -> [dynamic]Aircraft_Stat {
	names: [dynamic]string
	defer delete(names)
	for name in s.totals.per_aircraft {
		append(&names, name)
	}
	slice.sort(names[:])

	out: [dynamic]Aircraft_Stat
	for name in names {
		append(&out, s.totals.per_aircraft[name])
	}
	return out
}

// ------------------------------------------------------------------- active --

store_write_active :: proc(s: ^Store, cur: Segment_State) -> bool {
	active := Active_JSON {
		schema     = SCHEMA_JSON,
		aircraft   = cur.aircraft,
		mode       = cur.mode,
		seconds    = cur.seconds,
		distance_m = cur.distance_m,
		started_at = cur.started_at,
		updated_at = timestamp_now(),
		model_time = cur.prev_model_time,
	}
	data, err := json.marshal(active, {pretty = true, use_spaces = true, spaces = 2})
	if err != nil {
		s.last_error = fmt.aprintf("cannot encode active segment: %v", err)
		return false
	}
	defer delete(data)
	if !atomic_write(s.active_path, data) {
		s.last_error = fmt.aprintf("cannot write %s", s.active_path)
		return false
	}
	return true
}

store_clear_active :: proc(s: ^Store) {
	if os.exists(s.active_path) {
		if err := os.remove(s.active_path); err != nil {
			s.last_error = fmt.aprintf("cannot remove %s: %v", s.active_path, err)
		}
	}
}

store_read_active :: proc(path: string) -> (active: Active_JSON, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return {}, false
	}
	defer delete(data)
	if err := json.unmarshal(data, &active); err != nil {
		return {}, false
	}
	if !mode_valid(active.mode) || active.aircraft == "" || active.seconds <= 0 {
		return {}, false
	}
	return active, true
}

// ------------------------------------------------------------------- export --

store_export :: proc(s: ^Store) -> (path: string, ok: bool) {
	if err := os.make_directory_all(s.export_dir); err != nil {
		s.last_error = fmt.aprintf("cannot create export directory: %v", err)
		return "", false
	}
	name := fmt.aprintf("dcslogbook-export-%s.json", compact_now())
	defer delete(name)
	path = join_path(s.export_dir, name)

	data, marshaled := store_marshal_snapshot(s)
	if !marshaled {
		return path, false
	}
	defer delete(data)
	if !atomic_write(path, data) {
		s.last_error = fmt.aprintf("cannot write export %s", path)
		return path, false
	}
	return path, true
}

// ------------------------------------------------------------------ shutdown -

store_flush :: proc(s: ^Store) {
	if s.jsonl_file != nil {
		os.flush(s.jsonl_file)
	}
}

store_shutdown :: proc(s: ^Store) {
	if s.jsonl_file != nil {
		os.flush(s.jsonl_file)
		os.close(s.jsonl_file)
		s.jsonl_file = nil
	}
}

// ------------------------------------------------------------------ helpers --

// Atomic replace: write a sibling temp file, fsync it, close it, then move it
// over the destination with MoveFileEx(MOVEFILE_REPLACE_EXISTING).
atomic_write :: proc(path: string, data: []byte) -> bool {
	tmp := fmt.aprintf("%s.tmp", path)
	defer delete(tmp)

	f, err := os.open(tmp, {.Write, .Create, .Trunc})
	if err != nil {
		return false
	}
	if _, werr := os.write(f, data); werr != nil {
		os.close(f)
		os.remove(tmp)
		return false
	}
	if ferr := os.flush(f); ferr != nil {
		os.close(f)
		os.remove(tmp)
		return false
	}
	if cerr := os.close(f); cerr != nil {
		os.remove(tmp)
		return false
	}
	if rerr := os.rename(tmp, path); rerr != nil {
		os.remove(tmp)
		return false
	}
	return true
}

@(private = "file")
id_sequence: u64

// Unique enough for a local append-only log: seconds + boot-relative
// milliseconds + a process-local counter.
make_id :: proc() -> string {
	id_sequence += 1
	elapsed_ms := int(time.duration_seconds(time.tick_since(BOOT_TICK)) * 1000.0)
	return fmt.aprintf(
		"%d-%03d-%04d",
		time.time_to_unix(time.now()),
		elapsed_ms % 1000,
		int(id_sequence % 10000),
	)
}
