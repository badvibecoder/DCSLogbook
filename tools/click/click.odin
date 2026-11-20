package main

/*
	Dev-only helper: posts a left click to a window's client coordinates, so the
	app's hit-testing and button actions can be tested without a real mouse.

	Usage: click.exe "DCS Logbook" <x> <y>
*/

import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"
import win "core:sys/windows"

main :: proc() {
	if len(os.args) < 4 {
		fmt.println("usage: click <window-title> <x> <y>")
		os.exit(2)
	}
	x, ok_x := strconv.parse_int(os.args[2])
	y, ok_y := strconv.parse_int(os.args[3])
	if !ok_x || !ok_y {
		fmt.println("click: invalid coordinates")
		os.exit(2)
	}

	title := win.utf8_to_wstring_alloc(os.args[1])
	hwnd := win.FindWindowW(nil, title)
	if hwnd == nil {
		fmt.println("click: window not found")
		os.exit(1)
	}

	lparam := win.LPARAM((u64(u16(y)) << 16) | u64(u16(x)))

	win.PostMessageW(hwnd, win.WM_MOUSEMOVE, 0, lparam)
	time.sleep(30 * time.Millisecond)
	win.PostMessageW(hwnd, win.WM_LBUTTONDOWN, win.WPARAM(win.MK_LBUTTON), lparam)
	time.sleep(30 * time.Millisecond)
	win.PostMessageW(hwnd, win.WM_LBUTTONUP, 0, lparam)
	time.sleep(150 * time.Millisecond)
	fmt.printf("click: posted at %d,%d\n", x, y)
}
