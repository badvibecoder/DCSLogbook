package dcslogbook

import "core:c"
import "core:fmt"
import win "core:sys/windows"

/*
	Thin GDI layer: fonts, colors, text measurement, filled/stroked shapes and a
	double buffer. Everything is plain Win32; no third-party GUI framework.

	All painting happens into an off-screen bitmap and is blitted once, so the
	window never flickers and WM_PAINT cost is bounded.
*/

Rect :: struct {
	x, y, w, h: int,
}

rect :: proc(x, y, w, h: int) -> Rect {
	return Rect{x = x, y = y, w = w, h = h}
}

rect_right :: proc(r: Rect) -> int {return r.x + r.w}
rect_bottom :: proc(r: Rect) -> int {return r.y + r.h}

rect_contains :: proc(r: Rect, px, py: int) -> bool {
	return px >= r.x && px < r.x + r.w && py >= r.y && py < r.y + r.h
}

rect_inset :: proc(r: Rect, dx, dy: int) -> Rect {
	return Rect{x = r.x + dx, y = r.y + dy, w = r.w - dx * 2, h = r.h - dy * 2}
}

// GDI COLORREF is 0x00BBGGRR.
rgb :: proc(r, g, b: u8) -> win.COLORREF {
	return win.COLORREF(u32(r) | (u32(g) << 8) | (u32(b) << 16))
}

blend :: proc(a, b: win.COLORREF, t: f32) -> win.COLORREF {
	ar := u32(a) & 0xff
	ag := (u32(a) >> 8) & 0xff
	ab := (u32(a) >> 16) & 0xff
	br := u32(b) & 0xff
	bg := (u32(b) >> 8) & 0xff
	bb := (u32(b) >> 16) & 0xff
	r := u32(f32(ar) * (1 - t) + f32(br) * t)
	g := u32(f32(ag) * (1 - t) + f32(bg) * t)
	bl := u32(f32(ab) * (1 - t) + f32(bb) * t)
	return win.COLORREF(r | (g << 8) | (bl << 16))
}

Theme :: struct {
	bg:         win.COLORREF,
	panel:      win.COLORREF,
	panel_alt:  win.COLORREF,
	border:     win.COLORREF,
	border_soft: win.COLORREF,
	text:       win.COLORREF,
	dim:        win.COLORREF,
	muted:      win.COLORREF,
	accent:     win.COLORREF,
	green:      win.COLORREF,
	amber:      win.COLORREF,
	red:        win.COLORREF,
	purple:     win.COLORREF,
	cyan:       win.COLORREF,
}

make_theme :: proc() -> Theme {
	return Theme {
		bg          = rgb(12, 16, 22),
		panel       = rgb(21, 26, 34),
		panel_alt   = rgb(27, 33, 42),
		border      = rgb(46, 54, 65),
		border_soft = rgb(33, 40, 50),
		text        = rgb(231, 238, 245),
		dim         = rgb(143, 152, 165),
		muted       = rgb(102, 112, 126),
		accent      = rgb(88, 166, 255),
		green       = rgb(63, 185, 80),
		amber       = rgb(210, 153, 34),
		red         = rgb(248, 81, 73),
		purple      = rgb(188, 140, 255),
		cyan        = rgb(57, 210, 192),
	}
}

Fonts :: struct {
	title:      win.HFONT,
	heading:    win.HFONT,
	body:       win.HFONT,
	body_bold:  win.HFONT,
	small:      win.HFONT,
	label:      win.HFONT,
	big:        win.HFONT,
	mono:       win.HFONT,
	mono_small: win.HFONT,
	valid:      bool,
}

make_font :: proc(px: int, weight: int, face: win.LPCWSTR) -> win.HFONT {
	h := win.CreateFontW(
		-c.int(px),
		0,
		0,
		0,
		c.int(weight),
		0,
		0,
		0,
		win.DEFAULT_CHARSET,
		win.OUT_DEFAULT_PRECIS,
		win.CLIP_DEFAULT_PRECIS,
		win.CLEARTYPE_QUALITY,
		win.DEFAULT_PITCH | win.FF_DONTCARE,
		face,
	)
	return h
}

scaled_px :: proc(n: int, scale: f32) -> int {
	v := int(f32(n) * scale + 0.5)
	if v < 1 {
		return 1
	}
	return v
}

create_fonts :: proc(scale: f32) -> Fonts {
	f := Fonts {
		title      = make_font(scaled_px(23, scale), 700, win.L("Segoe UI")),
		heading    = make_font(scaled_px(14, scale), 600, win.L("Segoe UI")),
		body       = make_font(scaled_px(13, scale), 400, win.L("Segoe UI")),
		body_bold  = make_font(scaled_px(13, scale), 600, win.L("Segoe UI")),
		small      = make_font(scaled_px(11, scale), 400, win.L("Segoe UI")),
		label      = make_font(scaled_px(10, scale), 700, win.L("Segoe UI")),
		big        = make_font(scaled_px(31, scale), 700, win.L("Segoe UI")),
		mono       = make_font(scaled_px(13, scale), 400, win.L("Consolas")),
		mono_small = make_font(scaled_px(11, scale), 400, win.L("Consolas")),
		valid      = true,
	}
	return f
}

destroy_fonts :: proc(f: ^Fonts) {
	if !f.valid {
		return
	}
	for h in ([]win.HFONT{f.title, f.heading, f.body, f.body_bold, f.small, f.label, f.big, f.mono, f.mono_small}) {
		if h != nil {
			win.DeleteObject(win.HGDIOBJ(h))
		}
	}
	f^ = {}
}

// ------------------------------------------------------------------- text ----

text_width :: proc(hdc: win.HDC, s: string, font: win.HFONT) -> int {
	if len(s) == 0 {
		return 0
	}
	buf: [2048]u16
	w := win.utf8_to_utf16_buf(buf[:], s)
	if len(w) == 0 {
		return 0
	}
	old := win.SelectObject(hdc, win.HGDIOBJ(font))
	size: win.SIZE
	win.GetTextExtentPoint32W(hdc, win.LPCWSTR(raw_data(w)), c.int(len(w)), &size)
	win.SelectObject(hdc, old)
	return int(size.cx)
}

// Draws text at (x, y) where y is the top of the glyph cell. Returns the
// measured advance width.
draw_text :: proc(hdc: win.HDC, x, y: int, s: string, font: win.HFONT, color: win.COLORREF) -> int {
	if len(s) == 0 {
		return 0
	}
	buf: [2048]u16
	w := win.utf8_to_utf16_buf(buf[:], s)
	if len(w) == 0 {
		return 0
	}
	old := win.SelectObject(hdc, win.HGDIOBJ(font))
	win.SetTextColor(hdc, color)
	win.SetBkMode(hdc, win.BKMODE.TRANSPARENT)
	win.TextOutW(hdc, c.int(x), c.int(y), win.LPCWSTR(raw_data(w)), c.int(len(w)))
	size: win.SIZE
	win.GetTextExtentPoint32W(hdc, win.LPCWSTR(raw_data(w)), c.int(len(w)), &size)
	win.SelectObject(hdc, old)
	return int(size.cx)
}

draw_text_right :: proc(hdc: win.HDC, right, y: int, s: string, font: win.HFONT, color: win.COLORREF) {
	w := text_width(hdc, s, font)
	draw_text(hdc, right - w, y, s, font, color)
}

// Truncates with an ellipsis so text can never bleed into a neighboring column.
// Returns a string over `buf` (valid until the caller's next use).
fit_text :: proc(buf: []u8, hdc: win.HDC, s: string, font: win.HFONT, max_w: int) -> string {
	if max_w <= 0 {
		return ""
	}
	if text_width(hdc, s, font) <= max_w {
		return fmt.bprintf(buf, "%s", s)
	}
	n := len(s)
	for n > 0 {
		// Keep the cut on a UTF-8 boundary.
		for n > 0 && n < len(s) && (s[n] & 0xc0) == 0x80 {
			n -= 1
		}
		candidate := s[:n]
		if text_width(hdc, candidate, font) + text_width(hdc, "...", font) <= max_w {
			return fmt.bprintf(buf, "%s...", candidate)
		}
		n -= 1
	}
	return ""
}

// ------------------------------------------------------------------ shapes ----

fill_rect :: proc(hdc: win.HDC, r: Rect, color: win.COLORREF) {
	if r.w <= 0 || r.h <= 0 {
		return
	}
	rc := win.RECT {
		left   = win.LONG(r.x),
		top    = win.LONG(r.y),
		right  = win.LONG(r.x + r.w),
		bottom = win.LONG(r.y + r.h),
	}
	brush := win.CreateSolidBrush(color)
	win.FillRect(hdc, &rc, brush)
	win.DeleteObject(win.HGDIOBJ(brush))
}

fill_round :: proc(hdc: win.HDC, r: Rect, radius: int, color: win.COLORREF) {
	if r.w <= 0 || r.h <= 0 {
		return
	}
	brush := win.CreateSolidBrush(color)
	old_brush := win.SelectObject(hdc, win.HGDIOBJ(brush))
	old_pen := win.SelectObject(hdc, win.GetStockObject(win.NULL_PEN))
	win.RoundRect(
		hdc,
		c.int(r.x),
		c.int(r.y),
		c.int(r.x + r.w),
		c.int(r.y + r.h),
		c.int(radius * 2),
		c.int(radius * 2),
	)
	win.SelectObject(hdc, old_pen)
	win.SelectObject(hdc, old_brush)
	win.DeleteObject(win.HGDIOBJ(brush))
}

frame_round :: proc(hdc: win.HDC, r: Rect, radius: int, color: win.COLORREF, width: int = 1) {
	if r.w <= 0 || r.h <= 0 {
		return
	}
	pen := win.CreatePen(win.PS_SOLID, c.int(width), color)
	old_pen := win.SelectObject(hdc, win.HGDIOBJ(pen))
	old_brush := win.SelectObject(hdc, win.GetStockObject(win.NULL_BRUSH))
	win.RoundRect(
		hdc,
		c.int(r.x),
		c.int(r.y),
		c.int(r.x + r.w),
		c.int(r.y + r.h),
		c.int(radius * 2),
		c.int(radius * 2),
	)
	win.SelectObject(hdc, old_brush)
	win.SelectObject(hdc, old_pen)
	win.DeleteObject(win.HGDIOBJ(pen))
}

hline :: proc(hdc: win.HDC, x1, x2, y: int, color: win.COLORREF) {
	if x2 <= x1 {
		return
	}
	pen := win.CreatePen(win.PS_SOLID, 1, color)
	old := win.SelectObject(hdc, win.HGDIOBJ(pen))
	win.MoveToEx(hdc, i32(x1), i32(y), nil)
	win.LineTo(hdc, i32(x2), i32(y))
	win.SelectObject(hdc, old)
	win.DeleteObject(win.HGDIOBJ(pen))
}

vline :: proc(hdc: win.HDC, x, y1, y2: int, color: win.COLORREF) {
	if y2 <= y1 {
		return
	}
	pen := win.CreatePen(win.PS_SOLID, 1, color)
	old := win.SelectObject(hdc, win.HGDIOBJ(pen))
	win.MoveToEx(hdc, i32(x), i32(y1), nil)
	win.LineTo(hdc, i32(x), i32(y2))
	win.SelectObject(hdc, old)
	win.DeleteObject(win.HGDIOBJ(pen))
}

// Small check mark, drawn as two strokes. Used as the autosave confirmation.
draw_check :: proc(hdc: win.HDC, x, y, size: int, color: win.COLORREF, width: int = 2) {
	if size <= 0 {
		return
	}
	pen := win.CreatePen(win.PS_SOLID, c.int(width), color)
	old := win.SelectObject(hdc, win.HGDIOBJ(pen))
	win.MoveToEx(hdc, i32(x), i32(y + size * 55 / 100), nil)
	win.LineTo(hdc, i32(x + size * 38 / 100), i32(y + size * 92 / 100))
	win.LineTo(hdc, i32(x + size), i32(y + size * 8 / 100))
	win.SelectObject(hdc, old)
	win.DeleteObject(win.HGDIOBJ(pen))
}

// ------------------------------------------------------------------ buffer ----

Buffer :: struct {
	dc:      win.HDC,
	bmp:     win.HBITMAP,
	old_bmp: win.HGDIOBJ,
	w:       int,
	h:       int,
}

buffer_ensure :: proc(b: ^Buffer, hdc: win.HDC, w, h: int) -> bool {
	if w <= 0 || h <= 0 {
		return false
	}
	if b.dc == nil {
		b.dc = win.CreateCompatibleDC(hdc)
		if b.dc == nil {
			return false
		}
	}	
	if b.bmp != nil && b.w == w && b.h == h {
		return true
	}
	if b.bmp != nil {
		win.SelectObject(b.dc, b.old_bmp)
		win.DeleteObject(win.HGDIOBJ(b.bmp))
		b.bmp = nil
	}
	bmp := win.CreateCompatibleBitmap(hdc, c.int(w), c.int(h))
	if bmp == nil {
		return false
	}
	b.old_bmp = win.SelectObject(b.dc, win.HGDIOBJ(bmp))
	b.bmp = bmp
	b.w = w
	b.h = h
	return true
}

buffer_release :: proc(b: ^Buffer) {
	if b.bmp != nil {
		win.SelectObject(b.dc, b.old_bmp)
		win.DeleteObject(win.HGDIOBJ(b.bmp))
		b.bmp = nil
	}
	if b.dc != nil {
		win.DeleteDC(b.dc)
		b.dc = nil
	}
	b.w = 0
	b.h = 0
}
