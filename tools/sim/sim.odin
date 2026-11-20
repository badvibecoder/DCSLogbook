package main

/*
	Dev-only telemetry simulator (not shipped with the app).

	Pushes the same compact JSON packets the DCS Lua bridge sends, so the Odin
	side can be exercised without launching DCS.

	Usage:
	  sim.exe [port]          scripted edge-case sequence (default 34900)
	  sim.exe [port] demo     ~2.8 hours of demo history across 5 aircraft

	The default scenario covers: normal deltas, a 6s gap (accepted), an aircraft
	change, an SP->MP change, a zero delta (paused), a 23s jump (rejected), an
	inactive packet, and a stale close after the script stops sending.
*/

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

Step :: struct {
	mode:       string,
	aircraft:   string,
	model_time: f64,
	active:     bool,
	pause_ms:   int,
}

SCENARIO := []Step{
	{"SP", "F-16C_50", 10.0, true, 150},
	{"SP", "F-16C_50", 13.0, true, 150},
	{"SP", "F-16C_50", 16.0, true, 150},
	{"SP", "F-16C_50", 19.0, true, 150},
	{"SP", "F-16C_50", 25.0, true, 150}, // dt = 6s, accepted
	{"SP", "A-10C_2", 28.0, true, 150},  // aircraft change -> closes F-16
	{"SP", "A-10C_2", 31.0, true, 150},  // dt = 3s
	{"MP", "A-10C_2", 34.0, true, 150},  // mode change -> closes SP A-10
	{"MP", "A-10C_2", 37.0, true, 150},  // dt = 3s
	{"MP", "A-10C_2", 37.0, true, 150},  // dt = 0 -> ignored
	{"MP", "A-10C_2", 60.0, true, 150},  // dt = 23s -> rejected
	{"MP", "A-10C_2", 63.0, true, 150},  // dt = 3s
	{"MP", "A-10C_2", 66.0, false, 150}, // inactive -> closes MP segment
	{"SP", "F-15C", 100.0, true, 150},   // stale test: segment opens...
	{"SP", "F-15C", 103.0, true, 150},   // ...accrues 3s, then goes silent
}

Demo_Batch :: struct {
	mode:     string,
	aircraft: string,
	steps:    int,
}

DEMO_BATCHES := []Demo_Batch{
	{"SP", "F-16C_50", 420},
	{"MP", "FA-18C_hornet", 260},
	{"SP", "A-10C_2", 180},
	{"MP", "A-10C_2", 120},
	{"SP", "F-15C", 90},
	{"SP", "Ka-50", 60},
}

main :: proc() {
	port := 34900
	mode := ""
	if len(os.args) > 1 {
		if v, ok := strconv.parse_int(os.args[1]); ok && v > 0 && v < 65536 {
			port = v
		} else {
			mode = os.args[1]
		}
	}
	if len(os.args) > 2 {
		mode = os.args[2]
	}

	sock, err := net.make_unbound_udp_socket(.IP4)
	if err != nil {
		fmt.println("sim: socket failed:", err)
		os.exit(1)
	}
	defer net.close(sock)
	target := net.Endpoint {
		address = net.Address(net.IP4_Loopback),
		port    = port,
	}

	if mode == "demo" {
		run_demo(sock, target)
		return
	}

	for step in SCENARIO {
		send_packet(sock, target, step.mode, step.aircraft, step.model_time, step.active)
		time.sleep(time.Duration(step.pause_ms) * time.Millisecond)
	}
	fmt.println("sim: done. Leave the app running ~22s to observe the stale close.")
}

send_packet :: proc(
	sock: net.UDP_Socket,
	target: net.Endpoint,
	mode: string,
	aircraft: string,
	model_time: f64,
	active: bool,
) {
	model := fmt.aprintf("%.3f", model_time)
	defer delete(model)
	active_text := "false"
	if active {
		active_text = "true"
	}
	payload := strings.concatenate(
		{
			`{"app":"dcslogbook","v":1,"mode":"`,
			mode,
			`","aircraft":"`,
			aircraft,
			`","model_time":`,
			model,
			`,"active":`,
			active_text,
			`}`,
		},
		context.allocator,
	)
	defer delete(payload)
	if _, err := net.send_udp(sock, transmute([]byte)payload, target); err != nil {
		fmt.println("sim: send failed:", err)
	}
}

// Fast burst using 9s deltas (under the 10s rejection threshold). One inactive
// packet closes each aircraft's segment cleanly.
run_demo :: proc(sock: net.UDP_Socket, target: net.Endpoint) {
	model_time := 0.0
	total := 0
	for batch in DEMO_BATCHES {
		for _ in 0 ..< batch.steps {
			model_time += 9.0
			send_packet(sock, target, batch.mode, batch.aircraft, model_time, true)
			total += 1
			time.sleep(time.Millisecond)
		}
		send_packet(sock, target, batch.mode, batch.aircraft, model_time, false)
		fmt.printf("sim: %-6s %-14s %6.2f h\n", batch.mode, batch.aircraft, f64(batch.steps) * 9.0 / 3600.0)
		time.sleep(10 * time.Millisecond)
	}
	// Leave one live flight open so the UI shows an active session.
	for _ in 0 ..< 4 {
		model_time += 9.0
		send_packet(sock, target, "SP", "F-16C_50", model_time, true)
		total += 1
		time.sleep(time.Millisecond)
	}
	fmt.printf("sim: demo done, %d packets (F-16C_50 left active)\n", total)
}
