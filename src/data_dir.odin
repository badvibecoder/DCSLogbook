package dcslogbook

import "core:fmt"
import "core:os"
import "core:strings"

/*
	Data folder selection.

	Data lives next to the executable, always:

	  <folder of DCSLogbook.exe>\DCSLogbookData

	That keeps the app portable: copy the release folder and the logbook travels
	with it, with no per-user setup and no dependence on %LOCALAPPDATA% or %TEMP%.
	`--data-dir=<path>` is an explicit development/testing override.

	Writability is checked by creating and deleting a probe file, not just by
	looking at attributes, so network shares and virtualized folders behave
	correctly. If the exe folder cannot be written (e.g. Program Files), startup
	fails with the path and the OS error instead of silently putting the logbook
	somewhere the user would not find it.
*/

choose_data_dir :: proc(
	cli_dir: string,
) -> (path: string, ok: bool, detail: string, notice: string) {
	candidates: [dynamic]string
	defer delete(candidates)
	errors: [dynamic]string
	defer delete(errors)

	add_candidate :: proc(candidates: ^[dynamic]string, candidate: string) {
		if len(candidate) == 0 {
			return
		}
		for existing in candidates^ {
			if existing == candidate {
				return
			}
		}
		append(candidates, candidate)
	}

	if len(cli_dir) > 0 {
		add_candidate(&candidates, cli_dir)
	}

	exe_dir, exe_err := os.get_executable_directory(context.allocator)
	if exe_err != nil || len(exe_dir) == 0 {
		return "", false, "DCS Logbook could not determine the folder the executable is in.", ""
	}
	add_candidate(&candidates, join_path(exe_dir, "DCSLogbookData"))

	for candidate, i in candidates {
		if writable, err := dir_writable(candidate); writable {
			if i > 0 && len(errors) > 0 {
				notice = fmt.aprintf(
					"Data folder %s is not writable (%s); using %s",
					candidates[0],
					errors[0],
					candidate,
				)
			}
			return candidate, true, "", notice
		} else {
			append(&errors, err)
		}
	}

	builder, build_err := strings.builder_make()
	if build_err != nil {
		return "", false, "DCS Logbook could not create its data folder.", ""
	}
	fmt.sbprintf(&builder, "DCS Logbook could not create its data folder.\n")
	for candidate, i in candidates {
		fmt.sbprintf(&builder, "\n  %s\n      %s", candidate, errors[i])
	}
	if len(cli_dir) > 0 {
		fmt.sbprintf(&builder, "\n\nThe --data-dir value was tried first and failed.")
	}
	fmt.sbprintf(&builder, "\n\nRun DCSLogbook.exe from a writable folder (for example your Documents or Desktop).")
	return "", false, strings.to_string(builder), ""
}

dir_writable :: proc(path: string) -> (ok: bool, err: string) {
	if make_err := os.make_directory_all(path); make_err != nil {
		return false, fmt.aprintf("%v", make_err)
	}
	probe := join_path(path, ".dcslogbook-write-probe")
	f, open_err := os.open(probe, {.Write, .Create, .Trunc})
	if open_err != nil {
		return false, fmt.aprintf("%v", open_err)
	}
	_, write_err := os.write(f, []byte{'x'})
	close_err := os.close(f)
	os.remove(probe)
	if write_err != nil {
		return false, fmt.aprintf("%v", write_err)
	}
	if close_err != nil {
		return false, fmt.aprintf("%v", close_err)
	}
	return true, ""
}
