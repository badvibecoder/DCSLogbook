package main

/*
	Dev-only screenshot helper (not part of the shipped app).

	Captures a window by exact title into a PNG using PrintWindow. The companion
	app implements WM_PRINTCLIENT, so this works even when the window is behind
	other windows.

	Usage: shot.exe "DCS Logbook" out.png
*/

import "core:c"
import "core:fmt"
import "core:image/png"
import "core:os"
import "core:time"
import win "core:sys/windows"

foreign import user32 "system:User32.lib"

@(default_calling_convention = "system")
foreign user32 {
	PrintWindow :: proc(hwnd: win.HWND, hdc: win.HDC, flags: win.UINT) -> win.BOOL ---
}

PW_RENDERFULLCONTENT :: 0x00000002

main :: proc() {
	if len(os.args) < 3 {
		fmt.println("usage: shot <window-title> <out.png>")
		os.exit(2)
	}
	title := win.utf8_to_wstring_alloc(os.args[1])
	hwnd := win.FindWindowW(nil, title)
	if hwnd == nil {
		fmt.println("shot: window not found:", os.args[1])
		os.exit(1)
	}

	// Bring the window to the front for the duration of the capture. PrintWindow
	// is unreliable for some custom-drawn windows, so capture real screen pixels.
	win.ShowWindow(hwnd, win.SW_RESTORE)
	win.SetWindowPos(hwnd, win.HWND_TOPMOST, 0, 0, 0, 0, win.SWP_NOMOVE | win.SWP_NOSIZE | win.SWP_SHOWWINDOW)
	win.SetForegroundWindow(hwnd)
	time.sleep(400 * time.Millisecond)

	wr: win.RECT
	win.GetWindowRect(hwnd, &wr)
	w := int(wr.right - wr.left)
	h := int(wr.bottom - wr.top)
	if w <= 0 || h <= 0 {
		fmt.println("shot: bad window size")
		os.exit(1)
	}

	screen := win.GetDC(nil)
	defer win.ReleaseDC(nil, screen)
	mem := win.CreateCompatibleDC(screen)
	defer win.DeleteDC(mem)

	bi: win.BITMAPINFO
	bi.bmiHeader.biSize = size_of(win.BITMAPINFOHEADER)
	bi.bmiHeader.biWidth = c.int(w)
	bi.bmiHeader.biHeight = -c.int(h) // top-down
	bi.bmiHeader.biPlanes = 1
	bi.bmiHeader.biBitCount = 32
	bi.bmiHeader.biCompression = win.BI_RGB
	bi.bmiHeader.biSizeImage = u32(w * h * 4)

	bits: rawptr
	bmp := win.CreateDIBSection(mem, &bi, win.DIB_RGB_COLORS, &bits, nil, 0)
	if bmp == nil || bits == nil {
		fmt.println("shot: CreateDIBSection failed")
		os.exit(1)
	}
	defer win.DeleteObject(win.HGDIOBJ(bmp))

	old := win.SelectObject(mem, win.HGDIOBJ(bmp))
	defer win.SelectObject(mem, old)

	win.BitBlt(mem, 0, 0, c.int(w), c.int(h), screen, c.int(wr.left), c.int(wr.top), win.SRCCOPY)
	win.SetWindowPos(hwnd, win.HWND_NOTOPMOST, 0, 0, 0, 0, win.SWP_NOMOVE | win.SWP_NOSIZE)

	pixel_ptr := transmute([^]u8)bits
	pixels := pixel_ptr[:w * h * 4]

	img: png.Image
	img.width = w
	img.height = h
	img.channels = 4
	img.depth = 8
	img.pixels = make([dynamic]u8, 0, w * h * 4)
	defer delete(img.pixels)
	for i := 0; i < w * h * 4; i += 4 {
		b := pixels[i + 0]
		g := pixels[i + 1]
		r := pixels[i + 2]
		append(&img.pixels, r, g, b, 255)
	}

	out: [dynamic]u8
	defer delete(out)
	if err := png.save_to_buffer(&out, &img); err != nil {
		fmt.println("shot: png encode failed:", err)
		os.exit(1)
	}
	if err := os.write_entire_file(os.args[2], out[:]); err != nil {
		fmt.println("shot: write failed:", err)
		os.exit(1)
	}
	fmt.println("shot: wrote", os.args[2], w, "x", h)
}
