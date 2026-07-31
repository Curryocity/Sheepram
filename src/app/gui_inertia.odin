package app

import "core:c"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

import opt "../optimizer"
import im "../../third_party/odin-imgui"

Inertia_Hut_Row :: struct {
	velocity: f64,
	in_band: bool,
	near_border: bool,
	suspicious: bool,
	has_velocity: bool,
	nonzero: bool,
}

parse_inertia_tick_list :: proc(buffer: []byte) -> [dynamic]int {
	values: [dynamic]int
	text := buffer_string(buffer)
	start := 0
	for start < len(text) {
		end := start
		for end < len(text) && text[end] != ',' do end += 1
		token := strings.trim_space(text[start:end])
		if token != "" {
			value, ok := strconv.parse_int(token, 10)
			if ok && value >= 0 do append(&values, value)
		}
		start = end+1
	}
	return values
}

normalize_inertia_tick_list :: proc(buffer: []byte) {
	values := parse_inertia_tick_list(buffer)
	defer delete(values)
	for i in 1..<len(values) {
		value := values[i]
		j := i
		for j > 0 && values[j-1] > value {
			values[j] = values[j-1]
			j -= 1
		}
		values[j] = value
	}

	builder := strings.builder_make()
	written := 0
	for value, i in values {
		if i > 0 && value == values[i-1] do continue
		if written > 0 do strings.write_string(&builder, ", ")
		fmt.sbprintf(&builder, "%d", value)
		written += 1
	}
	text := strings.to_string(builder)
	defer delete(text)
	buffer_set(buffer, text)
}

inertia_tick_list_contains :: proc(values: []int, tick: int) -> bool {
	for value in values {
		if value == tick do return true
	}
	return false
}

inertia_choice_for_tick :: proc(lists: ^[2][3][dynamic]int, tick: int, axis: Inertia_Axis) -> Inertia_Choice {
	for list_index in 0..<3 {
		if inertia_tick_list_contains(lists[int(axis)][list_index][:], tick) {
			return Inertia_Choice(list_index+1)
		}
	}
	return .Lazy
}

show_inertia_observer_row :: proc(row: Inertia_Hut_Row, choice: Inertia_Choice, mismatches_only: bool) -> bool {
	visible := choice != .Lazy || row.has_velocity && row.nonzero && (row.in_band || row.near_border || row.suspicious)
	if !visible do return false
	if !mismatches_only do return true
	if !row.has_velocity do return false
	switch choice {
	case .Lazy:
		return row.in_band || row.near_border
	case .Hit:
		return !row.in_band && !row.near_border
	case .Avoid_Minus:
		return row.velocity >= 0 || row.in_band && !row.near_border
	case .Avoid_Plus:
		return row.velocity <= 0 || row.in_band && !row.near_border
	}
	return false
}

get_inertia_hut_row :: proc(
	state: ^Environment,
	tick: int,
	axis: Inertia_Axis,
	threshold, border_tolerance, suspicious_limit: f64,
) -> Inertia_Hut_Row {
	solution := state.last_solution
	if tick < 0 || tick+1 >= len(solution.xs) || tick+1 >= len(solution.zs) ||
	   tick >= len(state.inertia_drag) {
		return {}
	}
	velocity_x := solution.xs[tick+1]-solution.xs[tick]
	velocity_z := solution.zs[tick+1]-solution.zs[tick]
	velocity := velocity_x if axis == .X else velocity_z
	post_drag := velocity*state.inertia_drag[tick]
	magnitude := math.abs(post_drag)
	return {
		velocity = velocity,
		in_band = magnitude < threshold,
		near_border = border_tolerance > 0 && math.abs(magnitude-threshold) <= border_tolerance,
		suspicious = magnitude <= suspicious_limit,
		has_velocity = true,
		nonzero = velocity_x != 0 || velocity_z != 0,
	}
}

draw_inertia_hut_line :: proc(
	tick: int,
	axis: Inertia_Axis,
	row: Inertia_Hut_Row,
	choice: Inertia_Choice,
) {
	color := im.Vec4{0.45, 0.85, 0.55, 1}
	if !row.has_velocity {
		color = {0.7, 0.7, 0.7, 1}
	} else if row.near_border {
		color = {0.35, 0.85, 0.95, 1}
	} else if row.in_band {
		color = {1, 0.75, 0.3, 1}
	}

	component: cstring = "Vx" if axis == .X else "Vz"
	choice_names := [?]cstring{"Lazy", "Hit", "Avoid-", "Avoid+"}
	if row.has_velocity {
		im.TextColored(color, "t=%d  %s=% .6f  %s", tick, component, row.velocity, choice_names[int(choice)])
	} else {
		im.TextColored(color, "t=%d  %s=        -  %s", tick, component, choice_names[int(choice)])
	}
}

draw_inertia_tick_lists :: proc(state: ^Environment) {
	im.SeparatorText("Inertia Tick Lists")
	table_flags := im.TableFlags_SizingStretchSame | im.TableFlags_NoBordersInBody
	labels := [?]cstring{"Hit", "Avoid-", "Avoid+"}
	axes := [?]Inertia_Axis{.X, .Z}
	table_ids := [?]cstring{"InertiaXTickLists", "InertiaZTickLists"}
	toggle_labels := [2][3]cstring {
		{"X=", "X-", "X+"},
		{"Z=", "Z-", "Z+"},
	}
	first_toggle := true
	for axis in axes {
		for list_index in 0..<3 {
			if !first_toggle do im.SameLine(0, ui_px(8))
			im.Checkbox(toggle_labels[int(axis)][list_index], &state.inertia_tick_list_visible[int(axis)][list_index])
			first_toggle = false
		}
	}

	for axis in axes {
		axis_visible := false
		for list_index in 0..<3 {
			if state.inertia_tick_list_visible[int(axis)][list_index] {
				axis_visible = true
				break
			}
		}
		if !axis_visible do continue

		axis_name: cstring = "X" if axis == .X else "Z"
		if im.BeginTable(table_ids[int(axis)], 2, table_flags) {
			im.TableSetupColumn("Status", {.WidthFixed}, ui_px(90))
			im.TableSetupColumn("Ticks", {.WidthStretch})
			for list_index in 0..<3 {
				if !state.inertia_tick_list_visible[int(axis)][list_index] do continue
				im.TableNextRow()
				im.TableSetColumnIndex(0)
				im.AlignTextToFramePadding()
				im.Text("%s %s:", axis_name, labels[list_index])
				im.TableSetColumnIndex(1)
				im.SetNextItemWidth(-1)
				im.PushIDInt(c.int(int(axis)*3+list_index))
				_ = input_text("##ticks", state.inertia_tick_lists[int(axis)][list_index][:])
				im.PopID()
			}
			im.EndTable()
		}
	}
	if im.Button("Sort") {
		for axis in 0..<2 {
			for list_index in 0..<3 do normalize_inertia_tick_list(state.inertia_tick_lists[axis][list_index][:])
		}
	}
	if im.IsItemHovered() do im.SetTooltip("Sort valid ticks, remove duplicates, and normalize spacing.")
}

draw_inertia_observer :: proc(state: ^Environment) {
	if !im.CollapsingHeader("Observer", {.DefaultOpen}) do return
	im.AlignTextToFramePadding()
	im.Text("Suspicious Factor:")
	im.SameLine(0, ui_px(8))
	im.SetNextItemWidth(ui_px(90))
	factor := state.inertia_suspicious_factor
	if im.InputDouble("##inertia_suspicious_factor", &factor, 0, 0, "%.3g") {
		if math.is_nan(factor) || math.is_inf(factor, 0) do factor = 2
		state.inertia_suspicious_factor = max(1.0, factor)
	}
	im.Checkbox("Mismatches only", &state.inertia_mismatches_only)

	solution := state.last_solution
	if solution == nil || len(state.inertia_drag) == 0 {
		im.TextDisabled("Optimize once to inspect inertia.")
		return
	}

	movement_count := min(len(solution.xs)-1, len(solution.zs)-1)
	movement_count = min(movement_count, len(state.inertia_drag))
	threshold := state.inertia_threshold
	border_tolerance := 0.0
	if !state.last_solution_discrete do border_tolerance = opt.ACCEPT_TOL
	suspicious_limit := state.inertia_suspicious_factor*threshold

	lists: [2][3][dynamic]int
	defer {
		for axis in 0..<2 {
			for list_index in 0..<3 do delete(lists[axis][list_index])
		}
	}
	observer_ticks: [dynamic]int
	defer delete(observer_ticks)
	for tick in 0..<movement_count do append(&observer_ticks, tick)
	for axis in 0..<2 {
		for list_index in 0..<3 {
			lists[axis][list_index] = parse_inertia_tick_list(state.inertia_tick_lists[axis][list_index][:])
			for tick in lists[axis][list_index] {
				if tick >= movement_count do append(&observer_ticks, tick)
			}
		}
	}
	for i in movement_count+1..<len(observer_ticks) {
		tick := observer_ticks[i]
		j := i
		for j > movement_count && observer_ticks[j-1] > tick {
			observer_ticks[j] = observer_ticks[j-1]
			j -= 1
		}
		observer_ticks[j] = tick
	}
	write := movement_count
	for read in movement_count..<len(observer_ticks) {
		if write > movement_count && observer_ticks[read] == observer_ticks[write-1] do continue
		observer_ticks[write] = observer_ticks[read]
		write += 1
	}
	resize(&observer_ticks, write)

	axes := [?]Inertia_Axis{.X, .Z}
	row_count := 0
	for tick in observer_ticks {
		for axis in axes {
			row := get_inertia_hut_row(state, tick, axis, threshold, border_tolerance, suspicious_limit)
			choice := inertia_choice_for_tick(&lists, tick, axis)
			if show_inertia_observer_row(row, choice, state.inertia_mismatches_only) {
				row_count += 1
			}
		}
	}

	if row_count == 0 {
		im.TextDisabled("No assigned or suspicious ticks.")
		return
	}

	console_height := f32(row_count)*im.GetTextLineHeightWithSpacing()+ui_px(12)
	im.PushStyleColorImVec4(.ChildBg, {0, 0, 0, 1})
	im.PushStyleVarImVec2(.WindowPadding, {ui_px(8), ui_px(6)})
	console_visible := im.BeginChild("InertiaObserverConsole", {0, console_height}, {.Borders})
	if console_visible {
		pushed_code := push_font(code_font)
		for tick in observer_ticks {
			for axis in axes {
				row := get_inertia_hut_row(state, tick, axis, threshold, border_tolerance, suspicious_limit)
				choice := inertia_choice_for_tick(&lists, tick, axis)
				if show_inertia_observer_row(row, choice, state.inertia_mismatches_only) {
					draw_inertia_hut_line(tick, axis, row, choice)
				}
			}
		}
		pop_font(pushed_code)
	}
	im.EndChild()
	im.PopStyleVar()
	im.PopStyleColor()
}

draw_inertia_hut :: proc(state: ^Environment) {
	if !im.CollapsingHeader("Inertia Hut", {.DefaultOpen}) do return

	draw_inertia_tick_lists(state)
	draw_inertia_observer(state)
}
