package dcslogbook

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import win "core:sys/windows"

USAGE :: `DCS Logbook - native DCS World flight hours companion

Usage:
  DCSLogbook.exe [options]

Options:
  --data-dir=<path>   Explicit data folder (development/testing override).
                      Default: <exe folder>\DCSLogbookData, always next to the
                      executable so the logbook stays portable with the app.
                      If that folder is not writable the app refuses to start
                      and shows the path and the OS error.
  --port=<number>     UDP port to listen on (default 34900).
                      Must match the port in Scripts\DCSLogbook\DCSLogbookExport.lua.
  -h, --help          Show this help.

The app binds 127.0.0.1 only and never opens a network connection outward.
`

main :: proc() {
	requested_dir, port, help, ok := parse_args(os.args)
	if help {
		show_message(USAGE, "DCS Logbook")
		return
	}
	if !ok {
		return
	}

	data_dir, dir_ok, dir_detail, dir_notice := choose_data_dir(requested_dir)
	if !dir_ok {
		show_message(dir_detail, "DCS Logbook - data folder error")
		return
	}

	app := new(App)
	g_app = app

	if _, acquired := single_instance_acquire(data_dir); !acquired {
		show_message(
			"DCS Logbook is already running for this data folder.\n\nOnly one instance can write to a logbook at a time.",
			"DCS Logbook - already running",
		)
		return
	}

	if !app_init(app, data_dir, port) {
		msg := fmt.aprintf(
			"DCS Logbook could not start.\n\nData folder:\n%s\n\n%s",
			data_dir,
			app.store.last_error,
		)
		show_message(msg, "DCS Logbook - startup error")
		return
	}

	if len(dir_notice) > 0 {
		log_msg(&app.log, "%s", dir_notice)
		app_set_status(app, dir_notice, time.tick_now())
	}

	exit_code := gui_run(app)
	app_shutdown(app)
	os.exit(exit_code)
}

parse_args :: proc(args: []string) -> (data_dir: string, port: int, help: bool, ok: bool) {
	port = UDP_PORT_DEFAULT
	ok = true

	i := 1
	for i < len(args) {
		arg := args[i]
		switch {
		case arg == "-h" || arg == "--help":
			help = true

		case strings.has_prefix(arg, "--data-dir="):
			data_dir = arg[len("--data-dir="):]

		case arg == "--data-dir":
			i += 1
			if i < len(args) {
				data_dir = args[i]
			}

		case strings.has_prefix(arg, "--port="):
			value, parsed := strconv.parse_int(arg[len("--port="):])
			if !parsed || value <= 0 || value > 65535 {
				show_message("Invalid --port value. Expected 1..65535.", "DCS Logbook")
				return data_dir, port, false, false
			}
			port = value

		case arg == "--port":
			i += 1
			if i >= len(args) {
				show_message("--port needs a value.", "DCS Logbook")
				return data_dir, port, false, false
			}
			value, parsed := strconv.parse_int(args[i])
			if !parsed || value <= 0 || value > 65535 {
				show_message("Invalid --port value. Expected 1..65535.", "DCS Logbook")
				return data_dir, port, false, false
			}
			port = value
		}
		i += 1
	}

	return
}

show_message :: proc(text, title: string) {
	body := win.utf8_to_wstring_alloc(text)
	caption := win.utf8_to_wstring_alloc(title)
	win.MessageBoxW(nil, body, caption, win.MB_OK | win.MB_ICONERROR)
}
