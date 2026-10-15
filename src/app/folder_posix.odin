#+build !windows
package app

import "core:fmt"
import "core:os"
import "core:strings"

open_folder :: proc(dir: string) -> string {
	when ODIN_OS == .Darwin || ODIN_OS == .Linux {
		opener := "open" when ODIN_OS == .Darwin else "xdg-open"
		state, stdout, stderr, err := os.process_exec({command = {opener, dir}}, context.allocator)
		defer delete(stdout)
		defer delete(stderr)
		if err != nil do return fmt.aprintf("Failed to open saves folder: %v", err)
		if state.exit_code != 0 do return fmt.aprintf("Failed to open saves folder: %s", strings.trim_space(string(stderr)))
		return ""
	} else {
		return strings.clone("Opening the saves folder is not supported on this platform.")
	}
}
