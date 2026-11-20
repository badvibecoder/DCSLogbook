package dcslogbook

import "core:time"

/*
	DCS Logbook - shared types.

	Design notes:
	- `mode` is stored as a string ("SP" / "MP") in JSON so the on-disk format stays
	  readable and forward compatible with a future sync service.
	- All durations are stored in seconds (f64) and formatted only at the UI edge.
	- `synced` is reserved for the future account/sync phase; it is always written
	  as false today and preserved when read.
*/

APP_NAME :: "DCS Logbook"
APP_VERSION :: "1.0.0"
SCHEMA_VERSION :: 1

// UDP port the DCS Lua bridge pushes packets to (127.0.0.1 only).
UDP_PORT_DEFAULT :: 34900

// Edge-case guards (see tracker.odin).
PACKET_STALE_SECONDS :: 20.0 // no active packet for this long -> close segment
MAX_DT_SECONDS :: 10.0       // reject abnormal model-time jumps
DISCONTINUITY_SECONDS :: -1.0 // backwards jump larger than this -> split segment
MIN_SEGMENT_SECONDS :: 1.0   // do not persist accidental sub-second blips
MAX_SPEED_MPS :: 1200.0      // reject position deltas implying faster than this (teleport/load)
AUTOSAVE_SECONDS :: 10.0     // periodic atomic snapshot while a segment is open
AUTOSAVE_INTERVAL :: 10 * time.Second
SAVE_FLASH_DURATION :: 1500 * time.Millisecond // "saved" check visible after a save
STATUS_TTL :: 8 * time.Second  // action messages fade back to live state

MAX_AIRCRAFT_ROWS :: 512
MAX_RECENT_ROWS :: 14
MAX_LOAD_SEGMENTS :: 200_000

MODE_SP :: "SP"
MODE_MP :: "MP"

mode_valid :: proc(mode: string) -> bool {
	return mode == MODE_SP || mode == MODE_MP
}

// One completed, indivisible flight segment. This is the append-only unit of history.
Segment :: struct {
	id:         string `json:"id"`,
	aircraft:   string `json:"aircraft"`,
	mode:       string `json:"mode"`,
	seconds:    f64    `json:"seconds"`,
	distance_m: f64    `json:"distance_m"`, // 3D path length in metres (0 for old records)
	started_at: string `json:"started_at"`,
	ended_at:   string `json:"ended_at"`,
	synced:     bool   `json:"synced"`,
}

// Per-aircraft derived totals (cached in memory, recomputed from segments on load).
Aircraft_Stat :: struct {
	aircraft:      string `json:"aircraft"`,
	sp_seconds:    f64    `json:"sp_seconds"`,
	mp_seconds:    f64    `json:"mp_seconds"`,
	sp_distance_m: f64    `json:"sp_distance_m"`,
	mp_distance_m: f64    `json:"mp_distance_m"`,
	segments:      int    `json:"segments"`,
	last_flown:    string `json:"last_flown"`,
}

// Aggregate totals. `per_aircraft` is keyed by aircraft type name.
Totals :: struct {
	sp_seconds:       f64,
	mp_seconds:       f64,
	sp_distance_m:    f64,
	mp_distance_m:    f64,
	segment_count:    int,
	sp_segment_count: int,
	mp_segment_count: int,
	per_aircraft:     map[string]Aircraft_Stat,
}

// A single UDP telemetry packet produced by the DCS Lua bridge.
Packet :: struct {
	app:        string `json:"app"`, // "dcslogbook" (optional, used to filter foreign packets)
	v:          int    `json:"v"`,   // payload version, currently 1
	mode:       string `json:"mode"`,
	aircraft:   string `json:"aircraft"`,
	model_time: f64    `json:"model_time"`,
	active:     bool   `json:"active"`,
	blocked:    bool   `json:"blocked"`, // MP server disallows ownship export
	pos:        bool   `json:"pos"`,     // x/y/z below are valid
	x:          f64    `json:"x"`,
	y:          f64    `json:"y"`,
	z:          f64    `json:"z"`,
	tas:        f64    `json:"tas"`, // true airspeed m/s, fallback when position is absent
}

// The open (not yet closed) segment tracked in memory.
Segment_State :: struct {
	aircraft:        string,
	mode:            string,
	seconds:         f64,
	distance_m:      f64,
	prev_x:          f64,
	prev_y:          f64,
	prev_z:          f64,
	prev_pos_time:   f64,
	have_prev_pos:   bool,
	started_at:      string,
	started_unix:    i64,
	prev_model_time: f64,
}

Telemetry_State :: enum {
	Waiting, // no packet ever received
	Active,  // a segment is open
	Idle,    // recent packet, but not flying (spectator / menu)
	Stale,   // had telemetry, but nothing recent
}

// Flattened view of the store/tracker for the GUI. Built under the app mutex.
Aircraft_Row :: struct {
	aircraft:   string,
	sp_seconds: f64,
	mp_seconds: f64,
	distance_m: f64,
	segments:   int,
	last_flown: string,
}

View :: struct {
	state:           Telemetry_State,
	state_text:      string,
	have_packet:     bool,
	packet_age:      f64,
	last_packet_wall: time.Time,
	mode:            string,
	aircraft:        string,
	has_cur:         bool,
	cur_seconds:     f64,
	cur_started:     string,
	sp_seconds:      f64,
	mp_seconds:      f64,
	sp_distance_m:   f64,
	mp_distance_m:   f64,
	segment_count:   int,
	sp_segment_count: int,
	mp_segment_count: int,
	packets_ok:      u64,
	packets_bad:     u64,
	jumps:           u64,
	stale_closes:    u64,
	rows:            [MAX_AIRCRAFT_ROWS]Aircraft_Row,
	row_count:       int,
	total_aircraft:  int,
	recent:          [MAX_RECENT_ROWS]Segment,
	recent_count:    int,
	last_saved:      string,
	save_flash:      bool,
	status_msg:      string,
	data_dir:        string,
	jsonl_path:      string,
	bind_error:      string,
	bridge_warning:  string,
	port:            int,
	scroll:          int,
	listener_active: bool,
	blocked:         bool,
}
