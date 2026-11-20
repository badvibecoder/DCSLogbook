package dcslogbook

import win "core:sys/windows"

/*
	Single-instance guard.

	Two processes appending to the same flights.jsonl would lose or duplicate
	history, so the app takes a named Win32 mutex derived from the data folder.
	The mutex is owned by the process and released by the kernel if it dies, so a
	crash can never leave a stale lock behind.

	Different data folders (--data-dir) intentionally get different mutexes, so
	separate profiles can run side by side.
*/

foreign import kernel32_inst "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32_inst {
	CreateMutexW :: proc(
		lpMutexAttributes: rawptr,
		bInitialOwner: win.BOOL,
		lpName: win.LPCWSTR,
	) -> win.HANDLE ---
}

// Returns (handle, true) when this process may run, (nil, false) when another
// instance already owns the same data folder.
single_instance_acquire :: proc(data_dir: string) -> (handle: win.HANDLE, ok: bool) {
	buf: [320]u8
	prefix := "Local\\DCSLogbook_"
	n := copy(buf[:], prefix)
	for i := 0; i < len(data_dir) && n < len(buf) - 1; i += 1 {
		c := data_dir[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {
			buf[n] = c
		} else {
			buf[n] = '_'
		}
		n += 1
	}

	name := win.utf8_to_wstring_alloc(transmute(string)buf[:n])
	h := CreateMutexW(nil, win.BOOL(true), name)
	err := win.GetLastError()

	if h == nil {
		// Cannot create the mutex (unlikely): do not block startup.
		return nil, true
	}
	if err == win.ERROR_ALREADY_EXISTS {
		win.CloseHandle(h)
		return nil, false
	}
	return h, true
}
