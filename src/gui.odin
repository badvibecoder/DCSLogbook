package dcslogbook

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:time"
import win "core:sys/windows"

/*
	Native Win32 front end.

	One top-level window, custom drawn with GDI into a double buffer, standard
	blocking GetMessageW loop, and a 250ms WM_TIMER for staleness/autosave. The
	UDP thread only ever posts WM_APP_UPDATE; it never touches GDI.

	Buttons are hit-tested rectangles rather than child BUTTON controls: fewer
	window handles, no font propagation, no z-order flicker.
*/

Button :: enum int {
	Install = 0,
}

Layout :: struct {
	client:        Rect,
	header:        Rect,
	pill:          Rect,
	info:          [5]Rect,
	totals:        [3]Rect,
	table:         Rect,
	recent:        Rect,
	footer:        Rect,
	buttons:       [1]Rect,
	table_rows_y:  int,
	table_row_h:   int,
	table_visible: int,
	recent_rows_y: int,
	recent_row_h:  int,
	recent_visible: int,
}

Ui :: struct {
	theme:               Theme,
	fonts:               Fonts,
	buf:                 Buffer,
	scale:               f32,
	hover:               int,
	pressed:             int,
	scroll_aircraft:     int,
	scroll_recent:       int,
	max_scroll_aircraft: int,
	max_scroll_recent:   int,
	scroll_drag:         bool,
	scroll_drag_dy:      int,
	table_track_hit:     Rect,
	table_thumb_hit:     Rect,
	table_scroll_max:    int,
	table_visible_rows:  int,
	layout:              Layout,
	cursor_arrow:        win.HCURSOR,
	cursor_hand:         win.HCURSOR,
	last_second:         i64,
	view:                View,
}

// ------------------------------------------------------------------- window ---

g_ui_context: runtime.Context

// Numeric icon id from assets/dcslogbook.rc, embedded into the exe at build
// time with -resource. Both the exe icon and the window/taskbar icon use it.
ICON_RESOURCE_ID :: 101


gui_run :: proc(app: ^App) -> int {
	g_ui_context = context
	hinst := win.HINSTANCE(win.GetModuleHandleW(nil))
	app.hinst = hinst

	// Best effort: per-monitor v2 awareness; harmless if an older OS rejects it.
	win.SetProcessDpiAwarenessContext(win.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)

	icon_large := win.LoadImageW(
		hinst,
		cast(win.LPCWSTR) win.MAKEINTRESOURCEW(ICON_RESOURCE_ID),
		win.IMAGE_ICON,
		0,
		0,
		win.LR_DEFAULTCOLOR,
	)
	icon_small := win.LoadImageW(
		hinst,
		cast(win.LPCWSTR) win.MAKEINTRESOURCEW(ICON_RESOURCE_ID),
		win.IMAGE_ICON,
		win.GetSystemMetrics(win.SM_CXSMICON),
		win.GetSystemMetrics(win.SM_CYSMICON),
		win.LR_DEFAULTCOLOR,
	)

	wc := win.WNDCLASSEXW {
		cbSize        = size_of(win.WNDCLASSEXW),
		style         = win.CS_HREDRAW | win.CS_VREDRAW,
		lpfnWndProc   = wnd_proc,
		hInstance     = hinst,
		hIcon         = win.HICON(icon_large),
		hIconSm       = win.HICON(icon_small),
		hCursor       = win.LoadCursorW(nil, cast(win.LPCWSTR) win.MAKEINTRESOURCEW(32512)),
		hbrBackground = nil,
		lpszClassName = win.L("DCSLogbookWindow"),
	}
	if win.RegisterClassExW(&wc) == 0 {
		return 1
	}

	style := win.WS_OVERLAPPEDWINDOW | win.WS_VISIBLE
	frame := win.RECT {
		left   = 0,
		top    = 0,
		right  = 1240,
		bottom = 880,
	}
	win.AdjustWindowRectEx(&frame, style, false, 0)

	hwnd := win.CreateWindowExW(
		0,
		win.L("DCSLogbookWindow"),
		win.L("DCS Logbook"),
		style,
		win.CW_USEDEFAULT,
		win.CW_USEDEFAULT,
		frame.right - frame.left,
		frame.bottom - frame.top,
		nil,
		nil,
		hinst,
		nil,
	)
	if hwnd == nil {
		return 1
	}
	app.hwnd = hwnd

	// Class icons cover new windows; WM_SETICON makes the taskbar/Alt+Tab icon
	// explicit immediately.
	if icon_large != nil {
		win.SendMessageW(hwnd, win.WM_SETICON, win.WPARAM(1), win.LPARAM(uintptr(icon_large)))
	}
	if icon_small != nil {
		win.SendMessageW(hwnd, win.WM_SETICON, win.WPARAM(0), win.LPARAM(uintptr(icon_small)))
	}

	win.ShowWindow(hwnd, win.SW_SHOW)
	win.UpdateWindow(hwnd)

	msg: win.MSG
	for {
		res := win.GetMessageW(&msg, nil, 0, 0)
		if res <= 0 {
			break
		}
		win.TranslateMessage(&msg)
		win.DispatchMessageW(&msg)
	}
	return int(msg.wParam)
}

@(private = "file")
wnd_proc :: proc "system" (
	hwnd: win.HWND,
	msg: win.UINT,
	wparam: win.WPARAM,
	lparam: win.LPARAM,
) -> win.LRESULT {
	context = g_ui_context
	app := g_app
	if app == nil {
		return win.DefWindowProcW(hwnd, msg, wparam, lparam)
	}

	switch msg {
	case win.WM_CREATE:
		dpi := win.GetDpiForWindow(hwnd)
		if dpi == 0 {
			dpi = 96
		}
		app.hwnd = hwnd
		app.ui.scale = f32(dpi) / 96.0
		app.ui.theme = make_theme()
		app.ui.fonts = create_fonts(app.ui.scale)
		app.ui.hover = -1
		app.ui.pressed = -1
		app.ui.cursor_arrow = win.LoadCursorW(nil, cast(win.LPCWSTR) win.MAKEINTRESOURCEW(32512))
		app.ui.cursor_hand = win.LoadCursorW(nil, cast(win.LPCWSTR) win.MAKEINTRESOURCEW(32649))
		win.SetTimer(hwnd, win.UINT_PTR(1), 250, nil)
		return 0

	case win.WM_TIMER:
		if int(wparam) == 1 {
			changed := app_tick(app)
			second := time.time_to_unix(time.now())
			if second != app.ui.last_second {
				app.ui.last_second = second
				changed = true
			}
			if changed {
				win.InvalidateRect(hwnd, nil, false)
			}
		}
		return 0

	case win.WM_PAINT:
		paint(app, hwnd)
		return 0

	case win.WM_SIZE:
		buffer_release(&app.ui.buf)
		win.InvalidateRect(hwnd, nil, false)
		return 0

	case win.WM_ERASEBKGND:
		return 1

	case win.WM_CLOSE:
		app_save_now(app)
		win.DestroyWindow(hwnd)
		return 0

	case win.WM_DESTROY:
		win.KillTimer(hwnd, win.UINT_PTR(1))
		buffer_release(&app.ui.buf)
		destroy_fonts(&app.ui.fonts)
		win.PostQuitMessage(0)
		return 0

	case win.WM_MOUSEMOVE:
		x, y := mouse_position(lparam)
		if app.ui.scroll_drag {
			track := app.ui.table_track_hit
			thumb_h := app.ui.table_thumb_hit.h
			span := track.h - thumb_h
			if span > 0 {
				pos := y - app.ui.scroll_drag_dy
				if pos < track.y {
					pos = track.y
				}
				if pos > track.y + span {
					pos = track.y + span
				}
				frac := f32(pos - track.y) / f32(span)
				app.ui.scroll_aircraft = int(frac * f32(app.ui.table_scroll_max) + 0.5)
				clamp_scrolls(app)
				win.InvalidateRect(hwnd, nil, false)
			}
			return 0
		}
		hover := hit_button(app, x, y)
		if hover != app.ui.hover {
			app.ui.hover = hover
			win.InvalidateRect(hwnd, nil, false)
		}
		if hover >= 0 {
			win.SetCursor(app.ui.cursor_hand)
		} else {
			win.SetCursor(app.ui.cursor_arrow)
		}
		return 0

	case win.WM_LBUTTONDOWN:
		x, y := mouse_position(lparam)
		if app.ui.table_scroll_max > 0 && rect_contains(app.ui.table_thumb_hit, x, y) {
			app.ui.scroll_drag = true
			app.ui.scroll_drag_dy = y - app.ui.table_thumb_hit.y
			win.SetCapture(hwnd)
			return 0
		}
		if app.ui.table_scroll_max > 0 && rect_contains(app.ui.table_track_hit, x, y) {
			steps := app.ui.table_visible_rows
			if y < app.ui.table_thumb_hit.y {
				app.ui.scroll_aircraft -= steps
			} else {
				app.ui.scroll_aircraft += steps
			}
			clamp_scrolls(app)
			win.InvalidateRect(hwnd, nil, false)
			return 0
		}
		app.ui.pressed = hit_button(app, x, y)
		win.SetCapture(hwnd)
		win.InvalidateRect(hwnd, nil, false)
		return 0

	case win.WM_LBUTTONUP:
		if app.ui.scroll_drag {
			app.ui.scroll_drag = false
			win.ReleaseCapture()
			return 0
		}
		x, y := mouse_position(lparam)
		hit := hit_button(app, x, y)
		pressed := app.ui.pressed
		app.ui.pressed = -1
		win.ReleaseCapture()
		if pressed >= 0 && pressed == hit {
			activate_button(app, pressed)
		}
		win.InvalidateRect(hwnd, nil, false)
		return 0

	case win.WM_MOUSEWHEEL:
		delta := int(i16(u16((u64(wparam) >> 16) & 0xffff)))
		steps := delta / 120
		if steps == 0 && delta != 0 {
			if delta > 0 {
				steps = 1
			} else {
				steps = -1
			}
		}
		pt: win.POINT
		win.GetCursorPos(&pt)
		win.ScreenToClient(hwnd, &pt)
		x := int(pt.x)
		y := int(pt.y)
		if rect_contains(app.ui.layout.table, x, y) {
			app.ui.scroll_aircraft -= steps * 3
			clamp_scrolls(app)
			win.InvalidateRect(hwnd, nil, false)
		} else if rect_contains(app.ui.layout.recent, x, y) {
			app.ui.scroll_recent -= steps * 2
			clamp_scrolls(app)
			win.InvalidateRect(hwnd, nil, false)
		}
		return 0

	case win.WM_KEYDOWN:
		if int(wparam) == win.VK_ESCAPE {
			app.ui.pressed = -1
		}
		return 0

	case win.WM_SETCURSOR:
		if (int(lparam) & 0xffff) == win.HTCLIENT && app.ui.hover >= 0 {
			win.SetCursor(app.ui.cursor_hand)
			return 1
		}

	case win.WM_PRINTCLIENT:
		rect: win.RECT
		win.GetClientRect(hwnd, &rect)
		render_to(app, win.HDC(uintptr(wparam)), int(rect.right - rect.left), int(rect.bottom - rect.top))
		return 0

	case win.WM_DPICHANGED:
		dpi := win.GetDpiForWindow(hwnd)
		if dpi == 0 {
			dpi = 96
		}
		app.ui.scale = f32(dpi) / 96.0
		destroy_fonts(&app.ui.fonts)
		app.ui.fonts = create_fonts(app.ui.scale)
		buffer_release(&app.ui.buf)
		win.InvalidateRect(hwnd, nil, false)
		return 0

	case win.WM_GETMINMAXINFO:
		mmi := cast(^win.MINMAXINFO) uintptr(lparam)
		mmi.ptMinTrackSize = win.POINT {
			x = win.LONG(scaled_px(960, app.ui.scale)),
			y = win.LONG(scaled_px(700, app.ui.scale)),
		}
		return 0
	}

	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}

@(private = "file")
mouse_position :: proc(lparam: win.LPARAM) -> (x, y: int) {
	x = int(i16(u16(u64(lparam) & 0xffff)))
	y = int(i16(u16((u64(lparam) >> 16) & 0xffff)))
	return
}

@(private = "file")
hit_button :: proc(app: ^App, x, y: int) -> int {
	for r, i in app.ui.layout.buttons {
		if rect_contains(r, x, y) {
			return i
		}
	}
	return -1
}

@(private = "file")
clamp_scrolls :: proc(app: ^App) {
	if app.ui.scroll_aircraft < 0 {
		app.ui.scroll_aircraft = 0
	}
	if app.ui.scroll_aircraft > app.ui.max_scroll_aircraft {
		app.ui.scroll_aircraft = app.ui.max_scroll_aircraft
	}
	if app.ui.scroll_recent < 0 {
		app.ui.scroll_recent = 0
	}
	if app.ui.scroll_recent > app.ui.max_scroll_recent {
		app.ui.scroll_recent = app.ui.max_scroll_recent
	}
}

@(private = "file")
activate_button :: proc(app: ^App, index: int) {
	switch Button(index) {
	case .Install:
		app_install_bridge(app)
	}
	win.InvalidateRect(app.hwnd, nil, false)
}

// -------------------------------------------------------------------- layout --

compute_layout :: proc(w, h: int, scale: f32) -> Layout {
	pad := scaled_px(22, scale)
	gap := scaled_px(14, scale)
	header_h := scaled_px(54, scale)
	info_h := scaled_px(78, scale)
	totals_h := scaled_px(100, scale)
	footer_h := scaled_px(52, scale)
	button_h := scaled_px(34, scale)
	small_gap := scaled_px(12, scale)

	lay: Layout
	lay.client = rect(0, 0, w, h)
	content_x := pad
	content_w := w - pad * 2
	if content_w < 320 {
		content_w = 320
	}

	lay.header = rect(content_x, pad, content_w, header_h)
	pill_w := scaled_px(176, scale)
	pill_h := scaled_px(26, scale)
	lay.pill = rect(
		content_x + content_w - pill_w,
		pad + (header_h - pill_h) / 2,
		pill_w,
		pill_h,
	)

	info_y := pad + header_h + gap
	card_w := (content_w - small_gap * 4) / 5
	if card_w < 120 {
		card_w = 120
	}
	for i in 0 ..< 5 {
		lay.info[i] = rect(content_x + i * (card_w + small_gap), info_y, card_w, info_h)
	}

	totals_y := info_y + info_h + gap
	total_w := (content_w - gap * 2) / 3
	if total_w < 160 {
		total_w = 160
	}
	for i in 0 ..< 3 {
		lay.totals[i] = rect(content_x + i * (total_w + gap), totals_y, total_w, totals_h)
	}

	content_y := totals_y + totals_h + gap
	footer_y := h - pad - footer_h
	content_h := footer_y - gap - content_y
	if content_h < 160 {
		content_h = 160
	}

	table_w := content_w * 63 / 100
	lay.table = rect(content_x, content_y, table_w, content_h)
	lay.recent = rect(content_x + table_w + gap, content_y, content_w - table_w - gap, content_h)
	lay.footer = rect(content_x, footer_y, content_w, footer_h)

	lay.table_row_h = scaled_px(27, scale)
	lay.table_rows_y = content_y + scaled_px(60, scale)
	body_bottom := content_y + content_h - scaled_px(10, scale)
	lay.table_visible = (body_bottom - lay.table_rows_y) / lay.table_row_h
	if lay.table_visible < 1 {
		lay.table_visible = 1
	}

	lay.recent_row_h = scaled_px(46, scale)
	lay.recent_rows_y = content_y + scaled_px(38, scale)
	recent_bottom := content_y + content_h - scaled_px(10, scale)
	lay.recent_visible = (recent_bottom - lay.recent_rows_y) / lay.recent_row_h
	if lay.recent_visible < 1 {
		lay.recent_visible = 1
	}

	install_w := scaled_px(128, scale)
	btn_x := content_x + content_w - install_w
	btn_y := footer_y + (footer_h - button_h) / 2
	lay.buttons[0] = rect(btn_x, btn_y, install_w, button_h)

	return lay
}

// --------------------------------------------------------------------- paint --

@(private = "file")

paint :: proc(app: ^App, hwnd: win.HWND) {
	ps: win.PAINTSTRUCT
	hdc := win.BeginPaint(hwnd, &ps)
	defer win.EndPaint(hwnd, &ps)

	if !app.ui.fonts.valid {
		return
	}

	client: win.RECT
	win.GetClientRect(hwnd, &client)
	w := int(client.right - client.left)
	h := int(client.bottom - client.top)
	if w <= 0 || h <= 0 {
		return
	}
	if !buffer_ensure(&app.ui.buf, hdc, w, h) {
		return
	}

	render_to(app, app.ui.buf.dc, w, h)
	win.BitBlt(hdc, 0, 0, c.int(w), c.int(h), app.ui.buf.dc, 0, 0, win.SRCCOPY)
}

render_to :: proc(app: ^App, dc: win.HDC, w, h: int) {
	build_view(app, &app.ui.view)
	lay := compute_layout(w, h, app.ui.scale)
	app.ui.layout = lay
	draw_all(app, dc, lay, &app.ui.view)
}

@(private = "file")
draw_all :: proc(app: ^App, dc: win.HDC, lay: Layout, v: ^View) {
	th := app.ui.theme

	fill_rect(dc, lay.client, th.bg)

	// Thin accent rule across the very top.
	fill_rect(dc, rect(0, 0, lay.client.w, scaled_px(2, app.ui.scale)), th.accent)

	draw_header(app, dc, lay, v)
	draw_info_cards(app, dc, lay, v)
	draw_totals(app, dc, lay, v)
	draw_table(app, dc, lay, v)
	draw_recent(app, dc, lay, v)
	draw_footer(app, dc, lay, v)
}

@(private = "file")
draw_header :: proc(app: ^App, dc: win.HDC, lay: Layout, v: ^View) {
	th := app.ui.theme
	f := &app.ui.fonts
	s := app.ui.scale

	// Logo mark: a stack of three bars, echoing a logbook.
	mark := rect(lay.header.x, lay.header.y + scaled_px(8, s), scaled_px(26, s), scaled_px(26, s))
	fill_round(dc, mark, scaled_px(7, s), th.accent)
	fill_rect(dc, rect(mark.x + scaled_px(6, s), mark.y + scaled_px(7, s), scaled_px(14, s), scaled_px(2, s)), th.bg)
	fill_rect(dc, rect(mark.x + scaled_px(6, s), mark.y + scaled_px(12, s), scaled_px(14, s), scaled_px(2, s)), th.bg)
	fill_rect(dc, rect(mark.x + scaled_px(6, s), mark.y + scaled_px(17, s), scaled_px(9, s), scaled_px(2, s)), th.bg)

	title_x := mark.x + mark.w + scaled_px(12, s)
	draw_text(dc, title_x, lay.header.y + scaled_px(2, s), "DCS LOGBOOK", f.title, th.text)
	subtitle_buf: [160]u8
	subtitle := fmt.bprintf(subtitle_buf[:], "DCS World flight hours  ·  local UDP telemetry  ·  v%s", APP_VERSION)
	draw_text(
		dc,
		title_x + 1,
		lay.header.y + scaled_px(31, s),
		subtitle,
		f.small,
		th.muted,
	)

	// Status pill.
	color := state_color(th, v.state)
	fill_round(dc, lay.pill, lay.pill.h / 2, blend(color, th.bg, 0.80))
	frame_round(dc, lay.pill, lay.pill.h / 2, blend(color, th.bg, 0.50))
	label := v.state_text
	tw := text_width(dc, label, f.label)
	draw_text(
		dc,
		lay.pill.x + (lay.pill.w - tw) / 2,
		lay.pill.y + (lay.pill.h - scaled_px(10, s)) / 2 - scaled_px(1, s),
		label,
		f.label,
		color,
	)
}

@(private = "file")
draw_info_cards :: proc(app: ^App, dc: win.HDC, lay: Layout, v: ^View) {
	th := app.ui.theme
	f := &app.ui.fonts
	s := app.ui.scale

	labels := [5]string{"LISTENER", "LAST PACKET", "MODE", "AIRCRAFT", "CURRENT FLIGHT"}

	for card, i in lay.info {
		fill_round(dc, card, scaled_px(9, s), th.panel)
		frame_round(dc, card, scaled_px(9, s), th.border_soft)
		draw_text(dc, card.x + scaled_px(14, s), card.y + scaled_px(11, s), labels[i], f.label, th.muted)

		value_x := card.x + scaled_px(14, s)
		value_y := card.y + scaled_px(28, s)
		sub_x := card.x + scaled_px(14, s)
		sub_y := card.y + scaled_px(53, s)
		max_w := card.w - scaled_px(28, s)

		value_buf: [128]u8
		sub_buf: [160]u8

		switch i {
		case 0:
			value := fmt.bprintf(value_buf[:], "127.0.0.1:%d", v.port)
			draw_text(dc, value_x, value_y, fit_text(value_buf[64:], dc, value, f.mono, max_w), f.mono, th.text)
			if v.listener_active {
				draw_text(dc, sub_x, sub_y, "listening", f.small, blend(th.green, th.panel, 0.35))
			} else {
				err_text := v.bind_error
				if len(err_text) == 0 {
					err_text = "listener failed"
				}
				draw_text(dc, sub_x, sub_y, fit_text(sub_buf[:], dc, err_text, f.small, max_w), f.small, th.red)
			}

		case 1:
			if v.have_packet {
				age_buf: [48]u8
				age := fmt.bprintf(age_buf[:], "%s ago", format_age_into(value_buf[:], v.packet_age))
				draw_text(dc, value_x, value_y, age, f.mono, th.text)
				sub := fmt.bprintf(sub_buf[:], "%d packets  ·  %d rejected", v.packets_ok, v.packets_bad)
				draw_text(dc, sub_x, sub_y, fit_text(sub_buf[100:], dc, sub, f.small, max_w), f.small, th.muted)
			} else {
				draw_text(dc, value_x, value_y, "no data", f.mono, th.muted)
				draw_text(dc, sub_x, sub_y, "waiting for the Lua bridge", f.small, th.muted)
			}

		case 2:
			mode_text := v.mode
			if len(mode_text) == 0 {
				mode_text = "—"
			}
			draw_text(dc, value_x, value_y, mode_text, f.heading, th.text)
			sub := "no active flight"
			if v.mode == MODE_SP {
				sub = "single-player"
			} else if v.mode == MODE_MP {
				sub = "multiplayer"
			}
			if v.blocked {
				sub = "server blocks ownship export"
			}
			draw_text(dc, sub_x, sub_y, fit_text(sub_buf[:], dc, sub, f.small, max_w), f.small, th.muted)

		case 3:
			aircraft := v.aircraft
			if len(aircraft) == 0 {
				aircraft = "—"
			}
			draw_text(
				dc,
				value_x,
				value_y,
				fit_text(value_buf[:], dc, aircraft, f.heading, max_w),
				f.heading,
				th.text,
			)
			sub := "no aircraft"
			if v.has_cur {
				sub = "current airframe"
			}
			draw_text(dc, sub_x, sub_y, sub, f.small, th.muted)

		case 4:
			clock := format_clock_into(value_buf[:], v.cur_seconds)
			if !v.has_cur {
				clock = "-"
			}
			draw_text(dc, value_x, value_y, clock, f.mono, th.text)
			sub := "not flying"
			if v.has_cur && len(v.cur_started) >= 16 {
				stamp := format_stamp_short_into(sub_buf[:], v.cur_started)
				sub = fmt.bprintf(sub_buf[64:], "started %s", stamp)
			}
			draw_text(dc, sub_x, sub_y, fit_text(sub_buf[100:], dc, sub, f.small, max_w), f.small, th.muted)
		}
	}
}

@(private = "file")
draw_totals :: proc(app: ^App, dc: win.HDC, lay: Layout, v: ^View) {
	th := app.ui.theme
	f := &app.ui.fonts
	s := app.ui.scale

	labels := [3]string{"SP HOURS", "MP HOURS", "COMBINED HOURS"}
	values := [3]f64{v.sp_seconds, v.mp_seconds, v.sp_seconds + v.mp_seconds}
	dist_values := [3]f64{v.sp_distance_m, v.mp_distance_m, v.sp_distance_m + v.mp_distance_m}
	colors := [3]win.COLORREF{th.accent, th.purple, th.green}

	for card, i in lay.totals {
		fill_round(dc, card, scaled_px(9, s), th.panel)
		frame_round(dc, card, scaled_px(9, s), th.border_soft)
		draw_text(dc, card.x + scaled_px(16, s), card.y + scaled_px(12, s), labels[i], f.label, th.muted)

		buf: [48]u8
		num := format_hours_into(buf[:], values[i])
		draw_text(dc, card.x + scaled_px(16, s), card.y + scaled_px(30, s), num, f.big, th.text)
		// Accent underline proportional to this bucket's share of total time.
		total := values[0] + values[1]
		bar_w := card.w - scaled_px(32, s)
		fill_rect(
			dc,
			rect(card.x + scaled_px(16, s), card.y + card.h - scaled_px(14, s), bar_w, scaled_px(3, s)),
			th.border_soft,
		)
		if total > 0 && values[i] > 0 {
			filled := int(f32(bar_w) * f32(values[i] / total))
			fill_rect(
				dc,
				rect(card.x + scaled_px(16, s), card.y + card.h - scaled_px(14, s), filled, scaled_px(3, s)),
				colors[i],
			)
		}

		sub_buf: [160]u8
		nm_buf: [24]u8
		nm := format_nm_into(nm_buf[:], dist_values[i])
		sub := ""
		switch i {
		case 0:
			sub = fmt.bprintf(sub_buf[:], "%d segments · %s NM", v.sp_segment_count, nm)
		case 1:
			sub = fmt.bprintf(sub_buf[:], "%d segments · %s NM", v.mp_segment_count, nm)
		case 2:
			sub = fmt.bprintf(
				sub_buf[:],
				"%d segments · %s NM · %d types",
				v.segment_count,
				nm,
				v.total_aircraft,
			)
		}
		draw_text(dc, card.x + scaled_px(16, s), card.y + card.h - scaled_px(34, s), fit_text(sub_buf[96:], dc, sub, f.small, card.w - scaled_px(32, s)), f.small, th.muted)
	}
}

@(private = "file")
draw_table :: proc(app: ^App, dc: win.HDC, lay: Layout, v: ^View) {
	th := app.ui.theme
	f := &app.ui.fonts
	s := app.ui.scale
	r := lay.table

	fill_round(dc, r, scaled_px(9, s), th.panel)
	frame_round(dc, r, scaled_px(9, s), th.border_soft)

	pad := scaled_px(16, s)
	draw_text(dc, r.x + pad, r.y + scaled_px(13, s), "AIRCRAFT BREAKDOWN", f.label, th.muted)
	count_buf: [64]u8
	count := fmt.bprintf(count_buf[:], "%d types", v.total_aircraft)
	draw_text_right(dc, r.x + r.w - pad, r.y + scaled_px(13, s), count, f.small, th.muted)

	combined_right := r.x + r.w - pad - scaled_px(86, s)
	mp_right := combined_right - scaled_px(102, s)
	sp_right := mp_right - scaled_px(94, s)
	dist_right := r.x + r.w - pad
	name_x := r.x + pad
	name_max := sp_right - scaled_px(96, s) - name_x

	header_y := r.y + scaled_px(38, s)
	draw_text(dc, name_x, header_y, "AIRCRAFT", f.label, th.muted)
	draw_text_right(dc, sp_right, header_y, "SP HOURS", f.label, th.muted)
	draw_text_right(dc, mp_right, header_y, "MP HOURS", f.label, th.muted)
	draw_text_right(dc, combined_right, header_y, "COMBINED", f.label, th.muted)
	draw_text_right(dc, dist_right, header_y, "DIST NM", f.label, th.muted)
	hline(dc, r.x + pad, r.x + r.w - pad, header_y + scaled_px(20, s), th.border_soft)

	rows_y := lay.table_rows_y
	visible := lay.table_visible
	row_h := lay.table_row_h

	max_scroll := v.row_count - visible
	if max_scroll < 0 {
		max_scroll = 0
	}
	app.ui.max_scroll_aircraft = max_scroll
	if app.ui.scroll_aircraft > max_scroll {
		app.ui.scroll_aircraft = max_scroll
	}
	scroll := app.ui.scroll_aircraft

	if v.row_count == 0 {
		msg_y := r.y + (r.h - scaled_px(52, s)) / 2
		draw_text(dc, r.x + pad, msg_y, "No flights logged yet.", f.heading, th.dim)
		draw_text(
			dc,
			r.x + pad,
			msg_y + scaled_px(22, s),
			"Install the Lua bridge, then fly any aircraft in DCS.",
			f.small,
			th.muted,
		)
		return
	}

	buf: [96]u8
	row_y := rows_y
	for row_index in 0 ..< visible {
		index := scroll + row_index
		if index >= v.row_count {
			break
		}
		row := v.rows[index]
		if row_index % 2 == 1 {
			fill_rect(dc, rect(r.x + 1, row_y, r.w - 2, row_h), blend(th.panel, th.panel_alt, 0.55))
		}
		text_y := row_y + (row_h - scaled_px(13, s)) / 2 - scaled_px(1, s)
		draw_text(
			dc,
			name_x,
			text_y,
			fit_text(buf[32:], dc, row.aircraft, f.body, name_max),
			f.body,
			th.text,
		)

		sp := format_hours_cell_into(buf[:16], row.sp_seconds)
		sp_color := th.muted
		if row.sp_seconds > 0 {
			sp_color = th.dim
		}
		draw_text_right(dc, sp_right, text_y, sp, f.mono, sp_color)
		mp := format_hours_cell_into(buf[16:32], row.mp_seconds)
		mp_color := th.muted
		if row.mp_seconds > 0 {
			mp_color = th.dim
		}
		draw_text_right(dc, mp_right, text_y, mp, f.mono, mp_color)
		comb := format_hours_cell_into(buf[32:48], row.sp_seconds + row.mp_seconds)
		draw_text_right(dc, combined_right, text_y, comb, f.body_bold, th.text)
		dist := format_nm_into(buf[48:80], row.distance_m)
		draw_text_right(dc, dist_right, text_y, dist, f.mono, th.dim)

		if row_index < visible - 1 && index < v.row_count - 1 {
			hline(dc, r.x + pad, r.x + r.w - pad, row_y + row_h, blend(th.panel, th.border_soft, 0.55))
		}
		row_y += row_h
	}

	// Slim scroll indicator.
	app.ui.table_scroll_max = max_scroll
	app.ui.table_visible_rows = visible
	if max_scroll > 0 {
		track := rect(r.x + r.w - scaled_px(6, s), rows_y, scaled_px(3, s), visible * row_h)
		fill_rect(dc, track, th.border_soft)
		thumb_h := int(f32(track.h) * f32(visible) / f32(v.row_count))
		if thumb_h < scaled_px(18, s) {
			thumb_h = scaled_px(18, s)
		}
		thumb_y := track.y + int(f32(track.h - thumb_h) * f32(scroll) / f32(max_scroll))
		fill_round(dc, rect(track.x, thumb_y, track.w, thumb_h), 2, th.muted)
		// Wider invisible hit areas make the 3px bar usable without drawing a
		// chunky scrollbar.
		app.ui.table_track_hit = rect(track.x - scaled_px(5, s), track.y, scaled_px(12, s), track.h)
		app.ui.table_thumb_hit = rect(track.x - scaled_px(5, s), thumb_y, scaled_px(12, s), thumb_h)
	} else {
		app.ui.table_track_hit = {}
		app.ui.table_thumb_hit = {}
	}
}

@(private = "file")
draw_recent :: proc(app: ^App, dc: win.HDC, lay: Layout, v: ^View) {
	th := app.ui.theme
	f := &app.ui.fonts
	s := app.ui.scale
	r := lay.recent

	fill_round(dc, r, scaled_px(9, s), th.panel)
	frame_round(dc, r, scaled_px(9, s), th.border_soft)

	pad := scaled_px(16, s)
	draw_text(dc, r.x + pad, r.y + scaled_px(13, s), "RECENT FLIGHTS", f.label, th.muted)
	count_buf: [64]u8
	count := fmt.bprintf(count_buf[:], "%d total", v.segment_count)
	draw_text_right(dc, r.x + r.w - pad, r.y + scaled_px(13, s), count, f.small, th.muted)
	hline(dc, r.x + pad, r.x + r.w - pad, r.y + scaled_px(32, s), th.border_soft)

	max_scroll := v.recent_count - lay.recent_visible
	if max_scroll < 0 {
		max_scroll = 0
	}
	app.ui.max_scroll_recent = max_scroll
	if app.ui.scroll_recent > max_scroll {
		app.ui.scroll_recent = max_scroll
	}
	scroll := app.ui.scroll_recent

	if v.recent_count == 0 {
		draw_text(dc, r.x + pad, r.y + scaled_px(54, s), "No segments yet.", f.body, th.dim)
		draw_text(
			dc,
			r.x + pad,
			r.y + scaled_px(76, s),
			"Each flight is logged when telemetry stops.",
			f.small,
			th.muted,
		)
		return
	}

	row_h := lay.recent_row_h
	row_y := lay.recent_rows_y
	for row_index in 0 ..< lay.recent_visible {
		index := scroll + row_index
		if index >= v.recent_count {
			break
		}
		segment := v.recent[index]
		badge_w := scaled_px(32, s)
		badge_h := scaled_px(16, s)
		badge := rect(r.x + r.w - pad - badge_w, row_y + scaled_px(5, s), badge_w, badge_h)
		badge_color := th.accent
		if segment.mode == MODE_MP {
			badge_color = th.purple
		}
		fill_round(dc, badge, scaled_px(4, s), blend(badge_color, th.panel, 0.80))
		mode_w := text_width(dc, segment.mode, f.label)
		draw_text(
			dc,
			badge.x + (badge.w - mode_w) / 2,
			badge.y + scaled_px(2, s),
			segment.mode,
			f.label,
			badge_color,
		)

		name_buf: [96]u8
		name_max := r.w - pad * 2 - badge_w - scaled_px(12, s)
		draw_text(
			dc,
			r.x + pad,
			row_y + scaled_px(3, s),
			fit_text(name_buf[:], dc, segment.aircraft, f.body_bold, name_max),
			f.body_bold,
			th.text,
		)

		line_buf: [128]u8
		stamp_buf: [24]u8
		clock_buf: [24]u8
		nm_buf: [24]u8
		stamp := format_stamp_short_into(stamp_buf[:], segment.started_at)
		clock := format_clock_into(clock_buf[:], segment.seconds)
		line := fmt.bprintf(line_buf[:], "%s  ·  %s", stamp, clock)
		if segment.distance_m > 0 {
			nm := format_nm_into(nm_buf[:], segment.distance_m)
			line = fmt.bprintf(line_buf[:], "%s  ·  %s  ·  %s NM", stamp, clock, nm)
		}
		draw_text(
			dc,
			r.x + pad,
			row_y + scaled_px(22, s),
			fit_text(line_buf[64:], dc, line, f.mono_small, r.w - pad * 2),
			f.mono_small,
			th.muted,
		)

		if row_index < lay.recent_visible - 1 && index < v.recent_count - 1 {
			hline(dc, r.x + pad, r.x + r.w - pad, row_y + row_h, blend(th.panel, th.border_soft, 0.55))
		}
		row_y += row_h
	}
}

@(private = "file")
draw_footer :: proc(app: ^App, dc: win.HDC, lay: Layout, v: ^View) {
	th := app.ui.theme
	f := &app.ui.fonts
	s := app.ui.scale
	r := lay.footer

	status_w := lay.buttons[0].x - r.x - scaled_px(24, s)
	if status_w < 120 {
		status_w = 120
	}

	status := v.status_msg
	if len(status) == 0 {
		if len(v.bridge_warning) > 0 {
			status = v.bridge_warning
		} else {
			switch v.state {
			case .Waiting:
				status = "Waiting for DCS telemetry. Start DCS and fly."
			case .Active:
				status = "Receiving telemetry from DCS."
			case .Idle:
				status = "Connected. No active flight."
			case .Stale:
				status = "Telemetry stale. Waiting for the next mission."
			}
		}
	}
	status_color := th.dim
	if len(v.bind_error) > 0 {
		status_color = th.red
	} else if len(v.bridge_warning) > 0 && len(v.status_msg) == 0 {
		status_color = th.amber
	}
	buf: [256]u8
	draw_text(
		dc,
		r.x,
		r.y + scaled_px(3, s),
		fit_text(buf[:], dc, status, f.small, status_w),
		f.small,
		status_color,
	)

	path_buf: [512]u8
	saved_buf: [32]u8
	saved := v.last_saved
	if len(saved) == 0 {
		saved = "never"
	} else {
		saved = format_stamp_short_into(saved_buf[:], saved)
	}
	line_x := r.x
	line_w := status_w
	if v.save_flash {
		draw_check(dc, line_x, r.y + scaled_px(26, s), scaled_px(10, s), th.green)
		line_x += scaled_px(16, s)
		line_w -= scaled_px(16, s)
	}
	path_line := fmt.bprintf(path_buf[:], "Last save %s   ·   %s", saved, v.data_dir)
	draw_text(
		dc,
		line_x,
		r.y + scaled_px(24, s),
		fit_text(path_buf[300:], dc, path_line, f.mono_small, line_w),
		f.mono_small,
		th.muted,
	)

	labels := [1]string{"Install Bridge"}
	for btn, i in lay.buttons {
		draw_button(app, dc, btn, labels[i], i)
	}
}

@(private = "file")
draw_button :: proc(app: ^App, dc: win.HDC, r: Rect, label: string, index: int) {
	th := app.ui.theme
	f := &app.ui.fonts
	s := app.ui.scale

	hovered := app.ui.hover == index

	switch index {
	case 0:
		fill := th.panel_alt
		if hovered {
			fill = blend(th.panel_alt, th.accent, 0.14)
		}
		fill_round(dc, r, scaled_px(6, s), fill)
		frame_round(dc, r, scaled_px(6, s), blend(th.accent, th.panel, 0.55))
		tw := text_width(dc, label, f.body_bold)
		draw_text(dc, r.x + (r.w - tw) / 2, r.y + (r.h - scaled_px(13, s)) / 2, label, f.body_bold, th.accent)
	}
}

@(private = "file")
state_color :: proc(th: Theme, state: Telemetry_State) -> win.COLORREF {
	switch state {
	case .Active:
		return th.green
	case .Idle:
		return th.accent
	case .Stale:
		return th.red
	case .Waiting:
		return th.amber
	}
	return th.muted
}
