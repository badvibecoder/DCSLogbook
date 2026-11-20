package dcslogbook

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import win "core:sys/windows"

/*
	Application core: owns the store, the tracker, the UDP listener and the
	mutex that serializes all of them. The GUI thread and the UDP thread both go
	through `app.mu`; nothing else touches the store.

	Threading model:
	  UDP thread  -> json decode -> tracker state machine -> append/snapshot
	              -> PostMessage(WM_APP_UPDATE) so the UI can repaint.
	  UI thread   -> WM_TIMER: staleness check, 10s autosave, repaint.
	  UI thread   -> button actions: Save Now / Export JSON (mutex-protected).
*/

WM_APP_UPDATE :: win.WM_APP + 1

Telemetry :: struct {
	sock:       net.UDP_Socket,
	thread:     ^thread.Thread,
	port:       int,
	bind_ok:    bool,
	bind_error: string,
	packets:    u64,
	buf:        []byte,
	recv_error: net.UDP_Recv_Error,
}

App :: struct {
	mu:            sync.Mutex,
	store:         Store,
	tracker:       Tracker,
	tele:          Telemetry,
	log:           Log,
	data_dir:      string,
	port:          int,
	hwnd:          win.HWND,
	hinst:         win.HINSTANCE,
	stop:          bool,
	dirty:         bool,
	last_autosave: time.Tick,
	save_flash:    time.Tick,
	status_buf:    [256]u8,
	status_len:    int,
	status_tick:   time.Tick,
	recovered:     int,
	listener_up:     bool,
	bridge_installed: bool,
	bridge_current:  bool,
	bridge_path:     string,
	ui:              Ui,
}

g_app: ^App

// ------------------------------------------------------------------- startup --

app_init :: proc(app: ^App, data_dir: string, port: int) -> bool {
	app.data_dir = data_dir
	app.port = port
	app.last_autosave = time.tick_now()

	st, ok := store_init(data_dir)
	app.store = st
	if !ok {
		return false
	}
	app.log = log_init(data_dir)

	installed, current, bridge_path := bridge_status()
	app.bridge_installed = installed
	app.bridge_current = current
	app.bridge_path = bridge_path

	log_msg(&app.log, "starting %s v%s (port %d, data %s)", APP_NAME, APP_VERSION, port, data_dir)
	if !installed {
		log_msg(&app.log, "lua bridge: not installed (expected %s)", bridge_path)
	} else if !current {
		log_msg(&app.log, "lua bridge: outdated (expected %s)", bridge_path)
	} else {
		log_msg(&app.log, "lua bridge: v%s current", BRIDGE_VERSION)
	}
	// No click required: when DCS is present and the installed bridge is missing
	// or older than the embedded one, install/update it now. A sandboxed
	// (low-integrity) launch cannot write to Saved Games; that failure is logged
	// and the footer/button stay available as a manual retry.
	if !current && dcs_saved_games_present() {
		result := install_bridge()
		if result.ok {
			app.bridge_installed = true
			app.bridge_current = true
			log_msg(&app.log, "lua bridge: auto-installed v%s", BRIDGE_VERSION)
			status_buf: [160]u8
			app_set_status(
				app,
				fmt.bprintf(status_buf[:], "Lua bridge v%s installed automatically", BRIDGE_VERSION),
				time.tick_now(),
			)
		} else {
			log_msg(&app.log, "lua bridge: auto-install failed: %s", result.message)
		}
	} else if !current {
		log_msg(&app.log, "lua bridge: DCS Saved Games folder not found; auto-install skipped")
	}

	log_msg(
		&app.log,
		"loaded %d segments (%d jsonl, %d snapshot, %d skipped)",
		len(app.store.segments),
		app.store.loaded_jsonl,
		app.store.loaded_snap,
		app.store.bad_lines,
	)

	// Crash recovery: an active.json left behind means the previous run did not
	// exit cleanly. Close it into the history before the listener starts.
	if active, recovered_ok := store_read_active(app.store.active_path); recovered_ok {
		segment := Segment {
			id         = make_id(),
			aircraft   = active.aircraft,
			mode       = active.mode,
			seconds    = active.seconds,
			distance_m = active.distance_m,
			started_at = active.started_at,
			ended_at   = active.updated_at,
			synced     = false,
		}
		if store_add_segment(&app.store, segment) {
			app.recovered = 1
			recovered_buf: [160]u8
			app_set_status(
				app,
				fmt.bprintf(recovered_buf[:], "Recovered an unfinished flight: %.0fs in %s", segment.seconds, segment.aircraft),
				time.tick_now(),
			)
			log_msg(
				&app.log,
				"recovered unfinished segment: %s %s %.1fs",
				segment.aircraft,
				segment.mode,
				segment.seconds,
			)
		}
		store_clear_active(&app.store)
	}

	app.listener_up = telemetry_start(&app.tele, port)
	if !app.listener_up {
		log_msg(&app.log, "UDP listener failed: %s", app.tele.bind_error)
	} else {
		log_msg(&app.log, "UDP listener bound to 127.0.0.1:%d", port)
	}

	return true
}

// --------------------------------------------------------------- UDP thread ---

telemetry_start :: proc(tele: ^Telemetry, port: int) -> bool {
	sock, err := net.make_bound_udp_socket(net.Address(net.IP4_Loopback), port)
	if err != nil {
		tele.bind_error = fmt.aprintf("cannot bind 127.0.0.1:%d: %v", port, err)
		return false
	}
	tele.sock = sock
	tele.port = port
	tele.buf = make([]byte, 4096)
	// A short receive timeout lets the loop observe `app.stop` promptly without
	// busy-spinning. This is the only polling in the program, at 2 Hz.
	net.set_option(sock, .Receive_Timeout, 500 * time.Millisecond)

	tele.thread = thread.create(udp_listener_thread, .Normal, "dcslogbook-udp")
	if tele.thread == nil {
		tele.bind_error = "cannot create UDP listener thread"
		net.close(sock)
		return false
	}
	thread.start(tele.thread)
	tele.bind_ok = true
	return true
}

@(private = "file")
udp_listener_thread :: proc(_: ^thread.Thread) {
	// A thread starter has no ambient context; supply the default one so
	// allocations (JSON decode, timestamps) inside this thread are safe.
	context = runtime.default_context()
	tele := &g_app.tele
	buf := tele.buf
	if len(buf) == 0 {
		return
	}
	for {
		sync.lock(&g_app.mu)
		stopping := g_app.stop
		sync.unlock(&g_app.mu)
		if stopping {
			break
		}

		n, _, err := net.recv_udp(tele.sock, buf[:])
		if err == .Timeout {
			continue
		}
		if err != nil {
			if err == .Interrupted {
				continue
			}
			sync.lock(&g_app.mu)
			g_app.tele.recv_error = err
			g_app.listener_up = false
			sync.unlock(&g_app.mu)
			break
		}
		if n <= 0 {
			continue
		}
		tele.packets += 1
		app_handle_packet(buf[:n])
		if g_app.hwnd != nil {
			win.PostMessageW(g_app.hwnd, WM_APP_UPDATE, 0, 0)
		}
	}
}

// ---------------------------------------------------------------- packet path -

app_handle_packet :: proc(data: []byte) {
	app := g_app

	packet: Packet
	if err := json.unmarshal(data, &packet); err != nil {
		sync.lock(&app.mu)
		app.tracker.packets_bad += 1
		app.dirty = true
		sync.unlock(&app.mu)
		return
	}
	// Foreign UDP traffic on the same port is ignored rather than counted.
	if packet.app != "" && packet.app != "dcslogbook" {
		return
	}

	now_tick := time.tick_now()
	now_wall := time.now()

	sync.lock(&app.mu)
	defer sync.unlock(&app.mu)

	outcome := tracker_handle_packet(&app.tracker, packet, now_tick, now_wall)
	if outcome.did_close {
		if outcome.closed.seconds >= MIN_SEGMENT_SECONDS {
			store_add_segment(&app.store, outcome.closed)
			log_msg(
				&app.log,
				"segment closed (%s): %s %s %.1fs",
				outcome.note,
				outcome.closed.aircraft,
				outcome.closed.mode,
				outcome.closed.seconds,
			)
		} else {
			app.store.dropped += 1
		}
		store_clear_active(&app.store)
	}
	if outcome.did_start && app.tracker.has_cur {
		store_write_active(&app.store, app.tracker.cur)
		app.last_autosave = now_tick
	}
	app.dirty = true
}

// -------------------------------------------------------------- UI-thread ops -

// Returns true when the UI should repaint.
app_tick :: proc(app: ^App) -> bool {
	now_tick := time.tick_now()
	changed := false

	sync.lock(&app.mu)
	closed, did_close := tracker_tick(&app.tracker)
	if did_close {
		if closed.seconds >= MIN_SEGMENT_SECONDS {
			store_add_segment(&app.store, closed)
			status_buf: [160]u8
			app_set_status(
				app,
				fmt.bprintf(status_buf[:], "Telemetry stale - logged %.1fs in %s", closed.seconds, closed.aircraft),
				now_tick,
			)
			log_msg(&app.log, "segment closed (stale): %s %s %.1fs", closed.aircraft, closed.mode, closed.seconds)
		} else {
			app.store.dropped += 1
		}
		store_clear_active(&app.store)
		changed = true
	}

	// Periodic durable snapshot of the open segment + totals. Never per packet.
	if app.tracker.has_cur && time.tick_since(app.last_autosave) >= AUTOSAVE_INTERVAL {
		store_write_snapshot(&app.store)
		store_write_active(&app.store, app.tracker.cur)
		app.last_autosave = now_tick
		app.save_flash = now_tick
		changed = true
	}
	if app.dirty {
		changed = true
		app.dirty = false
	}
	sync.unlock(&app.mu)

	return changed
}

app_save_now :: proc(app: ^App) -> bool {
	now_tick := time.tick_now()
	sync.lock(&app.mu)
	defer sync.unlock(&app.mu)

	ok := store_write_snapshot(&app.store)
	if app.tracker.has_cur {
		store_write_active(&app.store, app.tracker.cur)
	}
	store_flush(&app.store)
	app.save_flash = now_tick
	status_buf: [200]u8
	if ok {
		app_set_status(app, fmt.bprintf(status_buf[:], "Saved to disk at %s", app.store.last_saved), now_tick)
	} else {
		app_set_status(app, fmt.bprintf(status_buf[:], "Save failed: %s", app.store.last_error), now_tick)
	}
	return ok
}

app_install_bridge :: proc(app: ^App) {
	now_tick := time.tick_now()
	result := install_bridge()
	app_set_status(app, result.message, now_tick)
	if result.ok {
		app.bridge_installed = true
		app.bridge_current = true
		log_msg(&app.log, "%s", result.message)
	} else {
		log_msg(&app.log, "bridge install failed: %s", result.message)
		show_message(result.message, "DCS Logbook - bridge install failed")
	}
	app.dirty = true
}

app_shutdown :: proc(app: ^App) {
	sync.lock(&app.mu)
	app.stop = true
	sync.unlock(&app.mu)

	if app.tele.thread != nil {
		if app.tele.bind_ok {
			// Wake a blocking recv; the loop also checks `stop` between reads.
			net.close(app.tele.sock)
			app.tele.bind_ok = false
		}
		thread.join(app.tele.thread)
		thread.destroy(app.tele.thread)
		app.tele.thread = nil
	} else if app.tele.bind_ok {
		net.close(app.tele.sock)
		app.tele.bind_ok = false
	}

	sync.lock(&app.mu)
	// Clean exit: the open segment becomes a normal historical segment.
	if app.tracker.has_cur {
		closed := tracker_close(&app.tracker, time.now())
		if closed.seconds >= MIN_SEGMENT_SECONDS {
			store_add_segment(&app.store, closed)
			log_msg(&app.log, "segment closed (exit): %s %s %.1fs", closed.aircraft, closed.mode, closed.seconds)
		}
	}
	store_write_snapshot(&app.store)
	store_clear_active(&app.store)
	store_shutdown(&app.store)
	log_msg(&app.log, "clean exit; saved at %s", app.store.last_saved)
	sync.unlock(&app.mu)
}

// ------------------------------------------------------------------ status ----

// Copies into a fixed buffer: callers may pass literals or stack-formatted
// strings without any ownership or lifetime concerns.
app_set_status :: proc(app: ^App, msg: string, now_tick: time.Tick) {
	n := copy(app.status_buf[:], msg)
	app.status_len = n
	app.status_tick = now_tick
}

// -------------------------------------------------------------------- view ----

build_view :: proc(app: ^App, view: ^View) {
	sync.lock(&app.mu)
	defer sync.unlock(&app.mu)

	view.state = app.tracker.state
	view.state_text = state_label(app.tracker.state)
	view.have_packet = app.tracker.have_packet
	view.packet_age = tracker_packet_age(&app.tracker)
	view.last_packet_wall = app.tracker.last_packet_wall
	view.mode = ""
	view.aircraft = ""
	view.has_cur = app.tracker.has_cur
	view.cur_seconds = 0
	view.cur_started = ""
	if app.tracker.has_cur {
		view.mode = app.tracker.cur.mode
		view.aircraft = app.tracker.cur.aircraft
		view.cur_seconds = app.tracker.cur.seconds
		view.cur_started = app.tracker.cur.started_at
	}

	view.sp_seconds = app.store.totals.sp_seconds
	view.mp_seconds = app.store.totals.mp_seconds
	view.sp_distance_m = app.store.totals.sp_distance_m
	view.mp_distance_m = app.store.totals.mp_distance_m
	view.segment_count = app.store.totals.segment_count
	view.sp_segment_count = app.store.totals.sp_segment_count
	view.mp_segment_count = app.store.totals.mp_segment_count
	view.packets_ok = app.tracker.packets_ok
	view.packets_bad = app.tracker.packets_bad + u64(app.store.bad_lines)
	view.jumps = app.tracker.jumps
	view.stale_closes = app.tracker.stale_closes
	view.last_saved = app.store.last_saved
	view.save_flash = time.tick_since(app.save_flash) < SAVE_FLASH_DURATION
	if app.status_len > 0 && time.tick_since(app.status_tick) < STATUS_TTL {
		view.status_msg = transmute(string)app.status_buf[:app.status_len]
	} else {
		view.status_msg = ""
	}
	view.data_dir = app.data_dir
	view.jsonl_path = app.store.jsonl_path
	view.bind_error = app.tele.bind_error
	if !app.listener_up && len(view.bind_error) == 0 {
		view.bind_error = "telemetry receiver stopped"
	}
	view.port = app.port
	view.listener_active = app.listener_up
	view.blocked = app.tracker.blocked
	view.bridge_warning = ""
	if !app.bridge_installed {
		view.bridge_warning = "Lua bridge not installed - click Install Bridge."
	} else if !app.bridge_current {
		view.bridge_warning = "Lua bridge outdated - click Install Bridge."
	}

	view.row_count = 0
	view.total_aircraft = len(app.store.totals.per_aircraft)
	for aircraft, stat in app.store.totals.per_aircraft {
		if view.row_count >= MAX_AIRCRAFT_ROWS {
			break
		}
		view.rows[view.row_count] = Aircraft_Row {
			aircraft   = aircraft,
			sp_seconds = stat.sp_seconds,
			mp_seconds = stat.mp_seconds,
			distance_m = stat.sp_distance_m + stat.mp_distance_m,
			segments   = stat.segments,
			last_flown = stat.last_flown,
		}
		view.row_count += 1
	}
	slice.sort_by(
		view.rows[:view.row_count],
		proc(a, b: Aircraft_Row) -> bool {
			ac := a.sp_seconds + a.mp_seconds
			bc := b.sp_seconds + b.mp_seconds
			if ac != bc {
				return ac > bc
			}
			return strings.compare(a.aircraft, b.aircraft) < 0
		},
	)

	view.recent_count = 0
	for i := len(app.store.segments) - 1; i >= 0 && view.recent_count < MAX_RECENT_ROWS; i -= 1 {
		view.recent[view.recent_count] = app.store.segments[i]
		view.recent_count += 1
	}
}

state_label :: proc(state: Telemetry_State) -> string {
	switch state {
	case .Waiting:
		return "WAITING FOR DCS"
	case .Active:
		return "FLYING"
	case .Idle:
		return "IDLE"
	case .Stale:
		return "STALE"
	}
	return "UNKNOWN"
}
