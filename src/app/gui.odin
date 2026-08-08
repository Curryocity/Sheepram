package app

import "core:c"
import "core:fmt"
import "core:strings"

import nfd "../nfd"
import im "../../third_party/odin-imgui"

nfd_ready: bool
show_exit_prompt: bool
request_exit: bool
exit_error: [ERROR_CAPACITY]byte

close_tab :: proc(app_state: ^App_State, index: int) {
	if app_state.tab_count <= 1 {
		destroy_tab(app_state.tabs[0])
		app_state.tabs[0] = make_default_tab(app_state.next_tab_id)
		app_state.next_tab_id += 1
		app_state.active_tab = 0
		return
	}
	destroy_tab(app_state.tabs[index])
	for i in index..<app_state.tab_count-1 {
		app_state.tabs[i] = app_state.tabs[i+1]
	}
	app_state.tab_count -= 1
	app_state.tabs[app_state.tab_count] = nil
	app_state.active_tab = clamp(app_state.active_tab, 0, app_state.tab_count-1)
}

find_tab_index :: proc(app_state: ^App_State, id: int) -> int {
	for i in 0..<app_state.tab_count {
		if app_state.tabs[i].id == id do return i
	}
	return -1
}

has_modified_tabs :: proc(app_state: ^App_State) -> bool {
	for i in 0..<app_state.tab_count {
		if is_tab_modified(app_state.tabs[i]) do return true
	}
	return false
}

save_all_tabs :: proc(app_state: ^App_State) -> string {
	for i in 0..<app_state.tab_count {
		tab := app_state.tabs[i]
		if !is_tab_modified(tab) do continue
		if err := save_tab_to_file(tab); err != "" do return err
	}
	return ""
}

draw_close_tab_popup :: proc(app_state: ^App_State) {
	if app_state.pending_close_tab_id < 0 do return
	index := find_tab_index(app_state, app_state.pending_close_tab_id)
	if index < 0 {
		app_state.pending_close_tab_id = -1
		return
	}
	if im.BeginPopupModal("Save Tab Before Closing?", nil, {.AlwaysAutoResize}) {
		tab := app_state.tabs[index]
		im.Text(
			"Save changes to '%s' before closing?",
			cstring(&tab.name[0]),
		)
		error_text := buffer_string(app_state.close_popup_error[:])
		if error_text != "" {
			c_error := strings.clone_to_cstring(error_text)
			im.TextColored({1, 0.4, 0.4, 1}, "%s", c_error)
			delete(c_error)
		}
		im.Spacing()
		if im.Button("Save", {ui_px(110), 0}) {
			save_err := save_tab_to_file(tab)
			if save_err == "" {
				close_tab(app_state, index)
				app_state.pending_close_tab_id = -1
				im.CloseCurrentPopup()
			} else {
				buffer_set(app_state.close_popup_error[:], save_err)
				delete(save_err)
			}
		}
		im.SameLine()
		if im.Button("Don't Save", {ui_px(110), 0}) {
			close_tab(app_state, index)
			app_state.pending_close_tab_id = -1
			im.CloseCurrentPopup()
		}
		im.SameLine()
		if im.Button("Cancel", {ui_px(110), 0}) {
			app_state.pending_close_tab_id = -1
			im.CloseCurrentPopup()
		}
		im.EndPopup()
	}
}

draw_exit_popup :: proc(app_state: ^App_State) {
	if !show_exit_prompt do return
	im.OpenPopup("Save Changes Before Exit?")
	if im.BeginPopupModal("Save Changes Before Exit?", nil, {.AlwaysAutoResize}) {
		im.Text("There are unsaved tabs. Save before exiting?")
		error_text := buffer_string(exit_error[:])
		if error_text != "" {
			c_error := strings.clone_to_cstring(error_text)
			im.TextColored({1, 0.4, 0.4, 1}, "%s", c_error)
			delete(c_error)
		}
		if im.Button("Save All", {ui_px(120), 0}) {
			err := save_all_tabs(app_state)
			if err == "" {
				request_exit = true
				show_exit_prompt = false
				im.CloseCurrentPopup()
			} else {
				buffer_set(exit_error[:], err)
				delete(err)
			}
		}
		im.SameLine()
		if im.Button("Discard All", {ui_px(120), 0}) {
			request_exit = true
			show_exit_prompt = false
			im.CloseCurrentPopup()
		}
		im.SameLine()
		if im.Button("Cancel", {ui_px(120), 0}) {
			show_exit_prompt = false
			buffer_clear(exit_error[:])
			im.CloseCurrentPopup()
		}
		im.EndPopup()
	}
}

draw_split_app :: proc(app_state: ^App_State) {
	viewport := im.GetMainViewport()
	im.SetNextWindowPos(viewport.Pos)
	im.SetNextWindowSize(viewport.Size)
	flags := im.WindowFlags_NoDecoration | im.WindowFlags{.NoMove, .NoResize, .NoCollapse}
	if im.Begin("SheepramRoot", nil, flags) {
		close_index := -1
		just_created := -1
		if im.BeginTable("top_bar", 2, im.TableFlags_SizingStretchSame | im.TableFlags_NoBordersInBody) {
			im.TableSetupColumn("tabs", {.WidthStretch})
			im.TableSetupColumn("load", {.WidthFixed}, ui_px(120))
			im.TableNextRow()
			im.TableSetColumnIndex(0)
			if im.BeginTabBar("optimizer_tabs") {
				can_add := app_state.tab_count < MAX_TABS
				if !can_add do im.BeginDisabled()
				if im.TabItemButton("+", {.Trailing}) && can_add {
					app_state.tabs[app_state.tab_count] = make_default_tab(app_state.next_tab_id)
					app_state.next_tab_id += 1
					just_created = app_state.tab_count
					app_state.active_tab = just_created
					app_state.tab_count += 1
				}
				if !can_add do im.EndDisabled()
				for i in 0..<app_state.tab_count {
					tab := app_state.tabs[i]
					label := fmt.aprintf("%s###tab_%d", buffer_string(tab.name[:]), tab.id)
					c_label := strings.clone_to_cstring(label)
					open := true
					tab_flags: im.TabItemFlags
					if i == just_created do tab_flags += {.SetSelected}
					if im.BeginTabItem(c_label, &open, tab_flags) {
						app_state.active_tab = i
						im.EndTabItem()
					}
					if !open {
						if tab.optimizer_job != nil {
							buffer_set(
								tab.inline_save_message[:],
								"Optimizer is still running; close the tab after it finishes.",
							)
							tab.inline_save_is_error = true
						} else if is_tab_modified(tab) {
							app_state.pending_close_tab_id = tab.id
							buffer_clear(app_state.close_popup_error[:])
						} else {
							close_index = i
						}
					}
					delete(c_label); delete(label)
				}
				im.EndTabBar()
			}
			im.TableSetColumnIndex(1)
			if im.Button("Load Preset", {-1, 0}) {
				tab := app_state.tabs[app_state.active_tab]
				if !nfd_ready {
					buffer_set(tab.inline_save_message[:], fmt.tprintf("Load failed: %s", nfd.get_error()))
					tab.inline_save_is_error = true
				} else {
					default_dir, _ := tabs_directory()
					selected, result := nfd.open_json(default_dir)
					delete(default_dir)
					if result == .Okay {
						load_err := load_tab_from_file(tab, selected)
						if load_err != "" {
							buffer_set(tab.inline_save_message[:], fmt.tprintf("Load failed: %s", load_err))
							tab.inline_save_is_error = true
							delete(load_err)
						} else {
							buffer_set(tab.inline_save_message[:], fmt.tprintf("Loaded: %s", buffer_string(tab.saved_file_name[:])))
							tab.inline_save_is_error = false
						}
						delete(selected)
					} else if result == .Error {
						buffer_set(tab.inline_save_message[:], fmt.tprintf("Load failed: %s", nfd.get_error()))
						tab.inline_save_is_error = true
					}
				}
			}
			im.EndTable()
		}
		if close_index >= 0 do close_tab(app_state, close_index)
		if app_state.pending_close_tab_id >= 0 {
			im.OpenPopup("Save Tab Before Closing?")
		}
		draw_close_tab_popup(app_state)
		draw_exit_popup(app_state)

		tab := app_state.tabs[app_state.active_tab]
		im.PushIDInt(c.int(tab.id))
		available := im.GetContentRegionAvail()
		divider := ui_px(8)
		min_panel_width := ui_px(250)
		if tab.left_width <= 0 do tab.left_width = (available.x-divider)*0.5
		tab.left_width = clamp(tab.left_width, min_panel_width, available.x-min_panel_width-divider)
		right_width := available.x-tab.left_width-divider

		im.BeginChild("LeftRegion", {tab.left_width, available.y})
		draw_input_panel(app_state, tab)
		im.EndChild()
		im.SameLine(0, 0)
		divider_pos := im.GetCursorScreenPos()
		im.InvisibleButton("Divider", {divider, available.y}, {.MouseButtonLeft})
		divider_hovered := im.IsItemHovered()
		divider_active := im.IsItemActive()
		if divider_hovered || divider_active do im.SetMouseCursor(.ResizeEW)
		if im.IsItemActive() {
			tab.left_width += im.GetIO().MouseDelta.x
			tab.left_width = clamp(tab.left_width, min_panel_width, available.x-min_panel_width-divider)
			right_width = available.x-tab.left_width-divider
		}
		divider_color := im.GetColorU32(.Separator)
		if divider_active do divider_color = im.GetColorU32(.SeparatorActive)
		else if divider_hovered do divider_color = im.GetColorU32(.SeparatorHovered)
		im.DrawList_AddRectFilled(
			im.GetWindowDrawList(),
			divider_pos,
			{divider_pos.x+divider, divider_pos.y+available.y},
			divider_color,
		)
		im.SameLine(0, 0)
		im.BeginChild("RightRegion", {right_width, available.y})
		output_margin := ui_pad(10)
		output_size := im.GetContentRegionAvail()
		output_size.x = max(f32(0), output_size.x-2*output_margin)
		output_size.y = max(f32(0), output_size.y-2*output_margin)
		cursor := im.GetCursorPos()
		im.SetCursorPos({cursor.x+output_margin, cursor.y+output_margin})
		draw_output_panel(tab, output_size)
		im.EndChild()
		im.PopID()
	}
	im.End()
}

Initialize_GUI :: proc(theme: Theme, ui_size_level: int, native_file_dialog_ready: bool) {
	load_fonts()
	base_style = im.GetStyle()^
	base_style_ready = true
	apply_ui_size(ui_size_level, theme)
	nfd_ready = native_file_dialog_ready
	show_exit_prompt = false
	request_exit = false
	buffer_clear(exit_error[:])
}

GUI_Prepare_Frame :: proc(app_state: ^App_State) {
	// Switch the preloaded font set and global style before ImGui::NewFrame().
	if app_state.ui_size_level != applied_ui_size_level {
		apply_ui_size(app_state.ui_size_level, app_state.theme)
	}
}

Draw_GUI :: proc(app_state: ^App_State) {
	poll_optimizer_jobs(app_state)
	pushed := push_font(ui_font)
	draw_split_app(app_state)
	pop_font(pushed)
}

GUI_Handle_Window_Close :: proc(app_state: ^App_State) {
	if has_running_optimizer_jobs(app_state) {
		tab := app_state.tabs[app_state.active_tab]
		buffer_set(
			tab.inline_save_message[:],
			"Optimizer is still running; exit after it finishes.",
		)
		tab.inline_save_is_error = true
		return
	}
	if has_modified_tabs(app_state) {
		show_exit_prompt = true
		buffer_clear(exit_error[:])
	} else {
		request_exit = true
	}
}

GUI_Should_Exit :: proc() -> bool {
	return request_exit
}
