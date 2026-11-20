package dcslogbook

import "core:math"
import "core:time"

/*
	Flight-time state machine.

	Invariants:
	- Only *advancing* model time counts. `dt <= 0` means the sim is paused (or a
	  duplicate/out-of-order packet); nothing is added.
	- A single delta larger than MAX_DT_SECONDS (10s) is rejected. At a 1s packet
	  cadence a normal delta is ~1s, so 10s means a load screen, a hitch, or the
	  "unpause after a long pause" gap. Rejecting keeps a stall from inflating
	  hours, and the stored prev_model_time still advances so the gap is not
	  counted later.
	- A backwards jump larger than DISCONTINUITY_SECONDS (e.g. model time resets
	  to ~0 after a mission reload) closes the current segment and opens a new one
	  for the same aircraft/mode instead of merging two flights.
	- Aircraft or mode changes close the old segment *first*, then start a new
	  one from the current packet. The elapsed delta across the switch is never
	  attributed to the new airframe.
	- Staleness is wall-clock based (the Lua side stops sending while paused), so
	  a 20s silence closes the segment at the last packet's timestamp.
*/

Tracker :: struct {
	cur:               Segment_State,
	has_cur:           bool,
	have_packet:       bool,
	last_packet_tick:  time.Tick,
	last_packet_wall:  time.Time,
	last_model_time:   f64,
	last_dt:           f64,
	state:             Telemetry_State,
	packets_ok:        u64,
	packets_bad:       u64,
	jumps:             u64,
	stale_closes:      u64,
	non_advancing:     u64,
	splits:            u64,
	aircraft_changes:  u64,
	mode_changes:      u64,
	blocked:           bool,
}

Packet_Outcome :: struct {
	closed:     Segment, // valid when did_close
	did_close:  bool,
	did_start:  bool,
	accepted:   bool,
	note:       string, // static diagnostic string, safe to log
}

tracker_handle_packet :: proc(
	t: ^Tracker,
	pkt: Packet,
	now_tick: time.Tick,
	now_wall: time.Time,
) -> Packet_Outcome {
	out: Packet_Outcome

	if !mode_valid(pkt.mode) {
		t.packets_bad += 1
		out.note = "rejected malformed packet"
		return out
	}
	// An inactive packet may legitimately carry no aircraft name: the bridge
	// sends one when it can no longer see the ownship (right after an ejection,
	// LoGetSelfData returns nil). Dropping it would leave the app waiting for
	// the 20 s stale timeout instead of closing at the ejection.
	if pkt.aircraft == "" && pkt.active {
		t.packets_bad += 1
		out.note = "rejected active packet without aircraft"
		return out
	}

	t.have_packet = true
	t.packets_ok += 1
	t.last_packet_tick = now_tick
	t.last_packet_wall = now_wall
	t.last_model_time = pkt.model_time
	t.blocked = pkt.blocked
	out.accepted = true

	// Not flying (spectator, menu, or the Lua side explicitly said inactive):
	// close whatever is open, but do not invent time.
	if !pkt.active {
		if t.has_cur {
			out.closed = tracker_close(t, now_wall)
			out.did_close = true
			out.note = "inactive packet"
		}
		t.state = .Idle
		return out
	}

	if !t.has_cur {
		tracker_start(t, pkt, now_wall)
		out.did_start = true
		t.state = .Active
		return out
	}

	// Aircraft switch: close the old airframe first.
	if t.cur.aircraft != pkt.aircraft {
		out.closed = tracker_close(t, now_wall)
		out.did_close = true
		tracker_start(t, pkt, now_wall)
		out.did_start = true
		t.aircraft_changes += 1
		t.state = .Active
		out.note = "aircraft change"
		return out
	}

	// SP <-> MP switch.
	if t.cur.mode != pkt.mode {
		out.closed = tracker_close(t, now_wall)
		out.did_close = true
		tracker_start(t, pkt, now_wall)
		out.did_start = true
		t.mode_changes += 1
		t.state = .Active
		out.note = "mode change"
		return out
	}

	// Distances come from the bridge's ownship Position. The position delta is
	// ground truth, so it is taken even across a >MAX_DT gap (a paused sim does
	// not move; a load/teleport is rejected by the speed check). It resets with
	// the segment on start/aircraft/mode/discontinuity.
	tracker_take_position(t, pkt)

	dt := pkt.model_time - t.cur.prev_model_time

	// Mission reload / model-time reset: split rather than merge.
	if dt < DISCONTINUITY_SECONDS {
		out.closed = tracker_close(t, now_wall)
		out.did_close = true
		tracker_start(t, pkt, now_wall)
		out.did_start = true
		t.jumps += 1
		t.state = .Active
		out.note = "model time discontinuity"
		return out
	}

	// Non-advancing time: keep prev_model_time unchanged so a small backwards
	// jitter cannot be re-counted as forward time on the next packet.
	if dt <= 0 {
		t.non_advancing += 1
		t.state = .Active
		out.note = "non-advancing sim time ignored"
		return out
	}

	// Rejected jump: still advance prev_model_time, otherwise the same gap would
	// be offered again on the next packet and could pass the cap.
	if dt > MAX_DT_SECONDS {
		t.cur.prev_model_time = pkt.model_time
		t.jumps += 1
		t.state = .Active
		out.note = "delta jump rejected"
		return out
	}

	t.cur.prev_model_time = pkt.model_time
	t.cur.seconds += dt
	// Fallback when a build does not expose Position: integrate true airspeed.
	if !pkt.pos && pkt.tas > 0.0 {
		t.cur.distance_m += pkt.tas * dt
	}
	t.last_dt = dt
	t.state = .Active
	return out
}

// Adds the 3D distance between this packet's ownship position and the previous
// one. Uses the position timestamps for the speed check so intermittent
// Position payloads still integrate correctly.
tracker_take_position :: proc(t: ^Tracker, pkt: Packet) {
	if !pkt.pos {
		return
	}
	if t.cur.have_prev_pos {
		ddt := pkt.model_time - t.cur.prev_pos_time
		if ddt > 0.0 {
			dx := pkt.x - t.cur.prev_x
			dy := pkt.y - t.cur.prev_y
			dz := pkt.z - t.cur.prev_z
			dd := math.sqrt(dx * dx + dy * dy + dz * dz)
			if dd / ddt <= MAX_SPEED_MPS {
				t.cur.distance_m += dd
			}
		}
	}
	t.cur.prev_x = pkt.x
	t.cur.prev_y = pkt.y
	t.cur.prev_z = pkt.z
	t.cur.prev_pos_time = pkt.model_time
	t.cur.have_prev_pos = true
}

tracker_start :: proc(t: ^Tracker, pkt: Packet, now_wall: time.Time) {
	t.cur = Segment_State {
		aircraft        = pkt.aircraft,
		mode            = pkt.mode,
		seconds         = 0,
		distance_m      = 0,
		started_at      = local_rfc3339(now_wall),
		started_unix    = unix_seconds(now_wall),
		prev_model_time = pkt.model_time,
	}
	if pkt.pos {
		t.cur.prev_x = pkt.x
		t.cur.prev_y = pkt.y
		t.cur.prev_z = pkt.z
		t.cur.prev_pos_time = pkt.model_time
		t.cur.have_prev_pos = true
	}
	t.has_cur = true
}

// Finalize the open segment. `end_wall` is the moment the segment stopped
// advancing: the packet arrival time for a change, or the last packet's arrival
// time for a stale close.
tracker_close :: proc(t: ^Tracker, end_wall: time.Time) -> Segment {
	segment := Segment {
		id         = make_id(),
		aircraft   = t.cur.aircraft,
		mode       = t.cur.mode,
		seconds    = t.cur.seconds,
		distance_m = t.cur.distance_m,
		started_at = t.cur.started_at,
		ended_at   = local_rfc3339(end_wall),
		synced     = false,
	}
	t.cur = {}
	t.has_cur = false
	return segment
}

// Called from the UI timer. Detects silence (paused game, mission end, DCS
// closed) and closes the open segment at the last packet's timestamp.
tracker_tick :: proc(t: ^Tracker) -> (closed: Segment, did_close: bool) {
	age := time.duration_seconds(time.tick_since(t.last_packet_tick))

	if t.has_cur && age > PACKET_STALE_SECONDS {
		closed = tracker_close(t, t.last_packet_wall)
		did_close = true
		t.stale_closes += 1
		t.state = .Stale
		return
	}
	if !t.has_cur {
		if !t.have_packet {
			t.state = .Waiting
		} else if age > PACKET_STALE_SECONDS {
			t.state = .Stale
		} else {
			t.state = .Idle
		}
	}
	return
}

tracker_packet_age :: proc(t: ^Tracker) -> f64 {
	if !t.have_packet {
		return 0
	}
	age := time.duration_seconds(time.tick_since(t.last_packet_tick))
	if age < 0 {
		return 0
	}
	return age
}
