package nfd

import "core:c"
import "core:strings"

when ODIN_OS == .Darwin {
	foreign import lib {
		"../../build/nfd_cocoa.o",
		"system:Cocoa.framework",
		"system:UniformTypeIdentifiers.framework",
	}
} else when ODIN_OS == .Linux {
	foreign import lib "../../build/nfd_gtk.o"
} else when ODIN_OS == .Windows {
	foreign import lib {
		"../../build/nfd_win.obj",
		"../../build/app_icon.res",
		"system:ole32.lib",
		"system:uuid.lib",
		"system:comdlg32.lib",
	}
}

Result :: enum c.int {
	Error,
	Okay,
	Cancel,
}

Filter_Item :: struct {
	name: cstring,
	spec: cstring,
}

foreign lib {
	@(link_name="NFD_Init")
	init :: proc() -> Result ---

	@(link_name="NFD_Quit")
	quit :: proc() ---

	@(link_name="NFD_OpenDialogU8")
	open_dialog_u8 :: proc(
		out_path: ^^u8,
		filter_list: ^Filter_Item,
		filter_count: c.uint,
		default_path: cstring,
	) -> Result ---

	@(link_name="NFD_FreePathU8")
	free_path_u8 :: proc(path: ^u8) ---

	@(link_name="NFD_GetError")
	get_error_raw :: proc() -> cstring ---
}

get_error :: proc() -> string {
	raw := get_error_raw()
	if raw == nil do return ""
	return string(raw)
}

open_json :: proc(default_path: string = "") -> (string, Result) {
	path: ^u8
	filter := Filter_Item{name = "JSON", spec = "json"}
	default_c: cstring
	if default_path != "" {
		default_c = strings.clone_to_cstring(default_path)
		defer delete(default_c)
	}
	result := open_dialog_u8(&path, &filter, 1, default_c)
	if result != .Okay do return "", result
	selected := strings.clone(string(cstring(path)))
	free_path_u8(path)
	return selected, result
}
