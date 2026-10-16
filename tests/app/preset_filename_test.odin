package app_test

import "core:os"
import "core:strings"
import "core:testing"
import app "../../src/app"

@(test)
renamed_preset_uses_filename_and_saves_without_touching_original :: proc(t: ^testing.T) {
	root, root_err := os.make_directory_temp("", "sheepram-filename-*", context.allocator)
	testing.expect(t, root_err == nil)
	if root_err != nil do return
	defer delete(root)
	defer os.remove(root)
	previous_root, had_root := os.lookup_env("WOLFRAMMCPK_DATA_DIR", context.allocator)
	defer delete(previous_root)
	defer {
		if had_root do _ = os.set_env("WOLFRAMMCPK_DATA_DIR", previous_root)
		else do _ = os.unset_env("WOLFRAMMCPK_DATA_DIR")
	}
	env_err := os.set_env("WOLFRAMMCPK_DATA_DIR", root)
	testing.expect(t, env_err == nil)
	if env_err != nil do return
	dir, dir_err := app.tabs_directory()
	testing.expect(t, dir_err == nil)
	if dir_err != nil do return
	defer delete(dir)
	presets_dir, _ := os.join_path({root, "presets"}, context.allocator)
	defer delete(presets_dir)
	defer os.remove(presets_dir)
	defer os.remove(dir)
	make_err := os.make_directory_all(dir)
	testing.expect(t, make_err == nil)
	if make_err != nil do return
	original_path, _ := os.join_path({dir, "Original.json"}, context.allocator)
	defer delete(original_path)
	defer os.remove(original_path)
	copy_path, _ := os.join_path({dir, "Copy.v2.json"}, context.allocator)
	defer delete(copy_path)
	defer os.remove(copy_path)
	source := app.make_default_tab(301)
	defer app.destroy_tab(source)
	app.buffer_set(source.name[:], "Original")
	data, json_err := app.build_tab_json(source)
	defer delete(data)
	defer delete(json_err)
	testing.expect_value(t, json_err, "")
	if json_err != "" do return
	testing.expect(t, os.write_entire_file(original_path, data) == nil)
	testing.expect(t, os.write_entire_file(copy_path, data) == nil)
	loaded := app.make_default_tab(302)
	defer app.destroy_tab(loaded)
	load_err := app.load_tab_from_file(loaded, copy_path)
	defer delete(load_err)
	testing.expect_value(t, load_err, "")
	if load_err != "" do return
	testing.expect_value(t, app.buffer_string(loaded.name[:]), "Copy.v2")
	testing.expect_value(t, app.buffer_string(loaded.name_draft[:]), "Copy.v2")
	testing.expect_value(t, app.buffer_string(loaded.saved_file_name[:]), "Copy.v2.json")
	testing.expect(t, !app.is_tab_modified(loaded))
	loaded.env.seed += 1
	testing.expect(t, app.is_tab_modified(loaded))
	save_err := app.save_tab_to_file(loaded)
	defer delete(save_err)
	testing.expect_value(t, save_err, "")
	testing.expect(t, !app.is_tab_modified(loaded))
	copy_data, copy_err := os.read_entire_file(copy_path, context.allocator)
	defer delete(copy_data)
	testing.expect(t, copy_err == nil)
	testing.expect(t, strings.contains(string(copy_data), `"Copy.v2"`))
	app.buffer_set(loaded.name_draft[:], "Original")
	collision_err := app.save_tab_to_file(loaded)
	defer delete(collision_err)
	testing.expect(t, strings.has_prefix(collision_err, "Name already taken:"))
	testing.expect(t, os.is_file(copy_path))
	original_data, read_err := os.read_entire_file(original_path, context.allocator)
	defer delete(original_data)
	testing.expect(t, read_err == nil)
	testing.expect_value(t, string(original_data), string(data))
}
