package app

import "core:fmt"
import win "core:sys/windows"

open_folder :: proc(dir: string) -> string {
	path := win.utf8_to_wstring(dir, context.allocator)
	defer delete(path)
	result := win.ShellExecuteW(nil, win.L("open"), path, nil, nil, win.SW_SHOWNORMAL)
	if uintptr(result) <= 32 do return fmt.aprintf("Failed to open saves folder (error %d)", uintptr(result))
	return ""
}
