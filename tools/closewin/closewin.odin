package main

/*
	Dev-only helper: posts WM_CLOSE to a window by title so the companion app's
	clean-exit save path can be tested.

	Usage: closewin.exe "DCS Logbook"
*/

import "core:fmt"
import "core:os"
import "core:time"
import win "core:sys/windows"

main :: proc() {
	if len(os.args) < 2 {
		fmt.println("usage: closewin <window-title>")
		os.exit(2)
	}
	title := win.utf8_to_wstring_alloc(os.args[1])
	hwnd := win.FindWindowW(nil, title)
	if hwnd == nil {
		fmt.println("closewin: window not found")
		os.exit(1)
	}
	win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0)
	fmt.println("closewin: WM_CLOSE posted")
	// Give the app time to flush before the caller inspects files.
	time.sleep(600 * time.Millisecond)
}
