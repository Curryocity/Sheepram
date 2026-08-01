package app

import "core:c"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:sync"
import "core:time"

import opt "../optimizer"
import im "../../third_party/odin-imgui"

format_duration :: proc(seconds: f64) -> string {
	whole_seconds := int(seconds)
	milliseconds := (seconds-f64(whole_seconds))*1000
	if whole_seconds == 0 {
		return fmt.aprintf("%.3fms", milliseconds)
	}
	return fmt.aprintf("%ds %.3fms", whole_seconds, milliseconds)
}

wrap_degrees_180 :: proc(degrees: f64) -> f64 {
	wrapped := math.mod(degrees+180, 360)
	if wrapped < 0 do wrapped += 360
	return wrapped-180
}

MIN_GRID_PX :: 67.0
MAX_GRID_PX :: 100.0
PLOT_PAD :: f32(30)

XZ_Plot_Layout :: struct {
	min_x, max_x, min_z, max_z: f64,
	range_x, range_z: f64,
	center_x, center_z: f64,
	scale: f64,
	content_width, content_height: f32,
}

compute_xz_plot_layout :: proc(xs, zs: []f64, size: im.Vec2) -> XZ_Plot_Layout {
	layout := XZ_Plot_Layout{scale = MIN_GRID_PX, content_width = 2*PLOT_PAD, content_height = 2*PLOT_PAD}
	if len(xs) == 0 || len(xs) != len(zs) do return layout
	layout.min_x, layout.max_x = xs[0], xs[0]
	layout.min_z, layout.max_z = zs[0], zs[0]
	for i in 1..<len(xs) {
		layout.min_x = min(layout.min_x, xs[i])
		layout.max_x = max(layout.max_x, xs[i])
		layout.min_z = min(layout.min_z, zs[i])
		layout.max_z = max(layout.max_z, zs[i])
	}
	if layout.min_x == layout.max_x {layout.min_x -= 0.5; layout.max_x += 0.5}
	if layout.min_z == layout.max_z {layout.min_z -= 0.5; layout.max_z += 0.5}
	layout.range_x = max(layout.max_x-layout.min_x, 1e-3)
	layout.range_z = max(layout.max_z-layout.min_z, 1e-3)
	layout.center_x = 0.5*(layout.min_x+layout.max_x)
	layout.center_z = 0.5*(layout.min_z+layout.max_z)
	plot_w := max(1, size.x-2*PLOT_PAD)
	plot_h := max(1, size.y-2*PLOT_PAD)
	layout.scale = clamp(min(f64(plot_w)/layout.range_x, f64(plot_h)/layout.range_z), MIN_GRID_PX, MAX_GRID_PX)
	layout.content_width = f32(layout.range_x*layout.scale)+2*PLOT_PAD
	layout.content_height = f32(layout.range_z*layout.scale)+2*PLOT_PAD
	return layout
}

draw_xz_plot :: proc(
	xs, zs, facings: []f64,
	vxs, vzs: []string,
	jump_ticks: []bool,
	color_jump_ticks: bool,
	size: im.Vec2,
	position_precision, angle_precision: int,
) {
	if len(xs) == 0 || len(xs) != len(zs) do return
	p0 := im.GetCursorScreenPos()
	p1 := im.Vec2{p0.x+size.x, p0.y+size.y}
	im.InvisibleButton("##xzplot", size)
	draw_list := im.GetWindowDrawList()
	plot_hovered := im.IsItemHovered()
	im.DrawList_AddRectFilled(draw_list, p0, p1, 0xff141414, 6)
	im.DrawList_AddRect(draw_list, p0, p1, 0xff5a5a5a, 6)

	layout := compute_xz_plot_layout(xs, zs, size)
	center := im.Vec2{p0.x+size.x*0.5, p0.y+size.y*0.5}
	to_screen := proc(x, z: f64, center: im.Vec2, layout: XZ_Plot_Layout) -> im.Vec2 {
		return {
			center.x+f32((x-layout.center_x)*layout.scale),
			center.y-f32((z-layout.center_z)*layout.scale),
		}
	}

	im.DrawList_PushClipRect(draw_list, p0, p1, true)
	grid_color: u32 = 0x96969696
	axis_color: u32 = 0xb4c8c8c8
	canvas_min_x := layout.center_x-f64(size.x*0.5)/layout.scale
	canvas_max_x := layout.center_x+f64(size.x*0.5)/layout.scale
	canvas_min_z := layout.center_z-f64(size.y*0.5)/layout.scale
	canvas_max_z := layout.center_z+f64(size.y*0.5)/layout.scale
	mouse := im.GetMousePos()
	hover_radius_sq := f32(64)
	hovered_index := -1
	best_dist_sq := hover_radius_sq
	default_point_color: u32 = 0xfff0f0f0
	jump_point_color := im.GetColorU32ImVec4({0.72, 0.62, 0.95, 1})

	for gx := int(math.ceil(canvas_min_x)); gx <= int(math.floor(canvas_max_x)); gx += 1 {
		x := to_screen(f64(gx), layout.center_z, center, layout).x
		im.DrawList_AddLine(draw_list, {x, p0.y}, {x, p1.y}, axis_color if gx == 0 else grid_color, 1.6 if gx == 0 else 1)
	}
	for gz := int(math.ceil(canvas_min_z)); gz <= int(math.floor(canvas_max_z)); gz += 1 {
		y := to_screen(layout.center_x, f64(gz), center, layout).y
		im.DrawList_AddLine(draw_list, {p0.x, y}, {p1.x, y}, axis_color if gz == 0 else grid_color, 1.6 if gz == 0 else 1)
	}
	for i in 1..<len(xs) {
		im.DrawList_AddLine(
			draw_list,
			to_screen(xs[i-1], zs[i-1], center, layout),
			to_screen(xs[i], zs[i], center, layout),
			0xffc8c0c0,
			2,
		)
	}
	for i in 0..<len(xs) {
		point := to_screen(xs[i], zs[i], center, layout)
		jump_point := color_jump_ticks && i < len(jump_ticks) && jump_ticks[i]
		if plot_hovered {
			dx, dy := point.x-mouse.x, point.y-mouse.y
			dist_sq := dx*dx+dy*dy
			if dist_sq <= best_dist_sq {
				best_dist_sq = dist_sq
				hovered_index = i
			}
		}
		im.DrawList_AddCircleFilled(draw_list, point, 3.5, jump_point_color if jump_point else default_point_color)
	}
	if hovered_index >= 0 {
		point := to_screen(xs[hovered_index], zs[hovered_index], center, layout)
		jump_point := color_jump_ticks && hovered_index < len(jump_ticks) && jump_ticks[hovered_index]
		hover_color := jump_point_color if jump_point else 0xdcffffff
		im.DrawList_AddCircle(draw_list, point, 7, hover_color, 0, 1.8)
	}
	im.DrawList_PopClipRect(draw_list)

	if hovered_index >= 0 &&
	   hovered_index < len(facings) &&
	   hovered_index < len(vxs) &&
	   hovered_index < len(vzs) &&
	   im.BeginTooltip() {
		tick_text := fmt.aprintf("Tick %d", hovered_index)
		defer delete(tick_text)
		tick_c := strings.clone_to_cstring(tick_text)
		defer delete(tick_c)
		im.TextUnformatted(tick_c)
		im.Separator()

		tooltip := strings.builder_make()
		if hovered_index < len(xs)-1 {
			fmt.sbprintf(&tooltip, "Facing: %.*f\n", angle_precision, facings[hovered_index])
		} else {
			strings.write_string(&tooltip, "Facing: -\n")
		}
		fmt.sbprintf(
			&tooltip,
			"Pos: (%.*f, %.*f)",
			position_precision,
			xs[hovered_index],
			position_precision,
			zs[hovered_index],
		)
		if hovered_index < len(xs)-1 {
			fmt.sbprintf(&tooltip, "\nVel: (%s, %s)", vxs[hovered_index], vzs[hovered_index])
			vx := xs[hovered_index+1]-xs[hovered_index]
			vz := zs[hovered_index+1]-zs[hovered_index]
			magnitude := math.sqrt(vx*vx+vz*vz)
			direction := wrap_degrees_180(math.atan2(vx, vz)*180/math.PI)
			fmt.sbprintf(
				&tooltip,
				"\nSpeed: %.*f\nDirection: %.*f deg",
				position_precision,
				magnitude,
				angle_precision,
				direction,
			)
		}
		tooltip_text := strings.to_string(tooltip)
		defer delete(tooltip_text)
		tooltip_c := strings.clone_to_cstring(tooltip_text)
		defer delete(tooltip_c)
		im.TextUnformatted(tooltip_c)
		im.EndTooltip()
	}
}

compute_plot_viewport_size :: proc(xs, zs: []f64) -> im.Vec2 {
	min_size :: f32(250)
	max_size :: f32(1000)
	if len(xs) == 0 || len(xs) != len(zs) do return {min_size, min_size}
	height_layout := compute_xz_plot_layout(xs, zs, {min_size, max_size})
	viewport_height := clamp(height_layout.content_height, min_size, max_size)
	width_layout := compute_xz_plot_layout(xs, zs, {0, viewport_height})
	content_width := max(f32(0), width_layout.content_width)
	return {clamp(content_width, min_size, max_size), viewport_height}
}

copy_separator :: proc(separator: Separator_Type) -> string {
	switch separator {
	case .Comma: return ","
	case .Space: return " "
	case .Newline: return "\n"
	}
	return ","
}

format_angle_list :: proc(facings: []f64, turns: bool, separator: string) -> string {
	builder := strings.builder_make()
	count := len(facings)-1
	if turns do count -= 1
	for i in 0..<max(0, count) {
		if i > 0 do strings.write_string(&builder, separator)
		value := facings[i]
		if turns {
			value = wrap_degrees_180(facings[i+1]-value)
		}
		part := fmt.tprintf("%.3f", value)
		strings.write_string(&builder, part)
	}
	return strings.to_string(builder)
}

read_only_block :: proc(label: cstring, text: string, copy_text: string) {
	im.AlignTextToFramePadding()
	pushed_ui := push_font(ui_font)
	im.TextUnformatted(label)
	im.SameLine()
	copy_label := fmt.aprintf("Copy##%s", string(label)); defer delete(copy_label)
	copy_label_c := strings.clone_to_cstring(copy_label); defer delete(copy_label_c)
	if im.Button(copy_label_c) {
		copy_c := strings.clone_to_cstring(copy_text); defer delete(copy_c)
		im.SetClipboardText(copy_c)
	}
	pop_font(pushed_ui)
	pushed_code := push_font(code_font)
	text_c := strings.clone_to_cstring(text); defer delete(text_c)
	padding := im.GetStyle().FramePadding
	im.PushStyleVarImVec2(.FramePadding, {padding.x, padding.y+ui_px(2)})
	im.PushID(label)
	im.InputTextMultiline(
		"##readonly",
		text_c,
		c.size_t(len(text)+1),
		{-1, ui_px(30)},
		{.ReadOnly, .NoUndoRedo},
	)
	im.PopID()
	im.PopStyleVar()
	pop_font(pushed_code)
}

draw_constraint_results :: proc(solution: ^opt.Solution, discrete_solution: bool) {
	pushed_ui := push_font(ui_font)
	open := im.CollapsingHeader("Constraint Results", {.DefaultOpen})
	pop_font(pushed_ui)
	if !open do return

	if len(solution.constraints) == 0 {
		im.TextDisabled("No constraints.")
		return
	}

	im.PushStyleVarImVec2(.CellPadding, {ui_px(10), ui_px(3)})
	visible_rows := min(len(solution.constraints), 13)
	table_height := ui_px(f32(visible_rows)*34+50)
	table_flags := im.TableFlags_RowBg | im.TableFlags_BordersOuter |
	               im.TableFlags_BordersV | im.TableFlags_SizingFixedFit |
	               im.TableFlags_NoHostExtendX | im.TableFlags_ScrollY
	if im.BeginTable("ConstraintResults", 3, table_flags, {0, table_height}) {
		im.TableSetupScrollFreeze(0, 1)
		im.TableSetupColumn("Constraint", {.WidthFixed}, ui_px(430))
		im.TableSetupColumn("Margin / Error", {.WidthFixed}, ui_px(130))
		im.TableSetupColumn("Status", {.WidthFixed}, ui_px(100))
		im.TableNextRow({.Headers}, ui_px(20))
		headers := [?]string{"Constraint", "Margin / Error", "Status"}
		for header, i in headers {
			im.TableSetColumnIndex(c.int(i))
			center_text(header)
		}

		for result in solution.constraints {
			metric_text := fmt.aprintf("%+.6g", result.margin)
			status := "Inactive"
			color := im.Vec4{0.45, 0.85, 0.55, 1}

			if result.cmp == .Equal {
				delete(metric_text)
				metric_text = fmt.aprintf("%.6g", result.margin)
				if result.margin > opt.ACCEPT_TOL {
					status = "Violated"
					color = {1, 0.4, 0.4, 1}
				} else {
					status = "Active"
					color = {1, 0.75, 0.3, 1}
				}
			} else {
				violation_limit := -opt.ACCEPT_TOL
				if discrete_solution do violation_limit = 0
				if result.margin < violation_limit {
					status = "Violated"
					color = {1, 0.4, 0.4, 1}
				} else if result.margin <= opt.ACCEPT_TOL {
					status = "Active"
					color = {1, 0.75, 0.3, 1}
				}
			}

			im.TableNextRow({}, ui_px(20))
			im.TableSetColumnIndex(0)
			source_c := strings.clone_to_cstring(result.source)
			im.TextUnformatted(source_c)
			delete(source_c)
			im.TableSetColumnIndex(1)
			center_text(metric_text)
			im.TableSetColumnIndex(2)
			status_c := strings.clone_to_cstring(status)
			im.TextColored(color, "%s", status_c)
			delete(status_c)
			delete(metric_text)
		}
		im.EndTable()
	}
	im.PopStyleVar()
}

draw_optimizer_progress :: proc(tab: ^Tab_State) {
	job := tab.optimizer_job
	if job == nil || job.control == nil {
		im.TextDisabled("Optimizing...")
		return
	}

	progress := &job.control.progress
	has_best: bool
	best_objective: f64
	completed_chefs, total_chefs: int

	sync.atomic_mutex_lock(&progress.mutex)
	has_best = progress.has_best
	best_objective = progress.best_objective
	angles := make([dynamic]f64, len(progress.angles))
	copy(angles[:], progress.angles[:])
	completed_chefs = progress.completed_chefs
	total_chefs = progress.total_chefs
	sync.atomic_mutex_unlock(&progress.mutex)
	defer delete(angles)

	cancel_requested := optimizer_cancel_requested(job.control)
	if cancel_requested {
		im.TextDisabled("Cancelling...")
	} else {
		im.TextDisabled("Optimizing...")
	}
	elapsed_text := format_duration(time.duration_seconds(time.tick_since(job.started_at)))
	defer delete(elapsed_text)
	elapsed_c := strings.clone_to_cstring(elapsed_text)
	defer delete(elapsed_c)
	im.TextDisabled("Elapsed Time: %s", elapsed_c)

	if !has_best {
		im.TextDisabled("Waiting...")
		return
	}

	im.Spacing()
	pushed_big := push_font(big_code_font)
	im.TextColored({0.8, 0.85, 1, 1}, "=> %.12f", best_objective)
	pop_font(pushed_big)

	if total_chefs > 0 {
		im.TextDisabled(
			"Mode: Intense Cooking (Chef(s): %d/%d)",
			completed_chefs,
			total_chefs,
		)
	}

	display_facings := format_angle_list(angles[:], false, ", ")
	defer delete(display_facings)
	copied_facings := format_angle_list(angles[:], false, copy_separator(tab.env.post.copy_separator))
	defer delete(copied_facings)
	read_only_block("Best Facing", display_facings, copied_facings)
}

draw_output_panel :: proc(tab: ^Tab_State, size: im.Vec2 = {0, 0}) {
	state := &tab.env
	im.PushStyleVarImVec2(.WindowPadding, {ui_pad(24), ui_pad(10)})
	im.BeginChild("OutputPanel", size, {.Borders})
	im.PopStyleVar()
	im.SeparatorText("Result")
	im.BeginChild("OutputScroll", {0, 0}, {}, {.HorizontalScrollbar})
	pushed_code := push_font(code_font)

	error_text := buffer_string(state.last_error[:])
	if error_text != "" {
		c_error := strings.clone_to_cstring(error_text); defer delete(c_error)
		im.TextColored({1, 0.4, 0.4, 1}, "%s", c_error)
		pop_font(pushed_code)
		im.EndChild(); im.EndChild()
		return
	}
	if state.last_solution == nil {
		if tab.optimizer_job != nil {
			draw_optimizer_progress(tab)
		} else {
			im.TextDisabled("Press Optimize!!")
		}
		pop_font(pushed_code)
		im.EndChild(); im.EndChild()
		return
	}

	solution := state.last_solution
	angle_precision :: 3
	position_precision := clamp(state.post.position_precision, 3, 10)
	im.Spacing()
	pushed_big := push_font(big_code_font)
	im.TextColored({0.8, 0.85, 1, 1}, "=> %.12f", solution.optimum)
	pop_font(pushed_big)
	compile_time := format_duration(state.compile_time_seconds)
	defer delete(compile_time)
	optimize_time := format_duration(state.continuous_time_seconds)
	defer delete(optimize_time)
	if state.last_solution_discrete {
		local_search_time := format_duration(state.discrete_time_seconds)
		defer delete(local_search_time)
		compile_c := strings.clone_to_cstring(compile_time)
		defer delete(compile_c)
		optimize_c := strings.clone_to_cstring(optimize_time)
		defer delete(optimize_c)
		local_search_c := strings.clone_to_cstring(local_search_time)
		defer delete(local_search_c)
		im.TextDisabled(
			"Compile: %s | Optimize: %s | Local Search: %s",
			compile_c,
			optimize_c,
			local_search_c,
		)
	} else {
		compile_c := strings.clone_to_cstring(compile_time)
		defer delete(compile_c)
		optimize_c := strings.clone_to_cstring(optimize_time)
		defer delete(optimize_c)
		im.TextDisabled(
			"Compile: %s | Optimize: %s",
			compile_c,
			optimize_c,
		)
	}
	if state.last_solution_cooking {
		im.TextDisabled(
			"Mode: Intense Cooking (Chef(s): %d/%d)",
			state.last_solution_chefs_completed,
			state.last_solution_chefs_total,
		)
	} else {
		im.TextDisabled(
			"Mode: %s",
			"Discrete" if state.last_solution_discrete else "Continuous",
		)
	}
	if solution.pancake_used {
		im.Spacing()
		pushed_ui := push_font(ui_font)
		im.Text("Pancake Log")
		pop_font(pushed_ui)
		recovery_text: cstring =
			"true" if solution.pancake_used_recovery else "false"
		im.TextDisabled(
			"Used Recovery Engine: %s",
			recovery_text,
		)
		if solution.pancake_used_recovery {
			reasons := solution.pancake_recovery_reasons
			reason_codes := strings.builder_make()
			defer strings.builder_destroy(&reason_codes)
			first := true
			if .Facing_Constraint in reasons {
				strings.write_string(&reason_codes, "1")
				first = false
			}
			if .Non_Unit_Vector_Strength in reasons {
				if !first do strings.write_string(&reason_codes, ", ")
				strings.write_string(&reason_codes, "2")
				first = false
			}
			if .Large_Dual_Gap in reasons {
				if !first do strings.write_string(&reason_codes, ", ")
				strings.write_string(&reason_codes, "3")
				first = false
			}
			if .Infeasible_Solution in reasons {
				if !first do strings.write_string(&reason_codes, ", ")
				strings.write_string(&reason_codes, "4")
			}
			reason_codes_text := strings.to_string(reason_codes)
			reason_codes_c := strings.clone_to_cstring(reason_codes_text)
			defer delete(reason_codes_c)
			im.TextDisabled("Reason: %s", reason_codes_c)
			im.TextDisabled("1. Facing constraint exists")
			im.TextDisabled("2. Non-unit vector strength")
			im.TextDisabled("3. Large dual gap")
			im.TextDisabled("4. Infeasible solution")
		}
		im.TextDisabled("Dual Bound: %.12f", solution.pancake_dual_bound)
	}
	im.Spacing(); im.Spacing()

	count := len(solution.xs)
	facings := make([dynamic]f64, count); defer delete(facings)
	for i in 0..<len(solution.thetas) {
		if state.last_solution_discrete {
			facings[i] = solution.thetas[i]
		} else {
			wrapped := wrap_degrees_180(solution.thetas[i]*180/math.PI)
			facings[i] = math.round(200*wrapped)*0.005
		}
	}
	turns := make([dynamic]string, count); defer delete(turns)
	xvals := make([dynamic]f64, count); defer delete(xvals)
	zvals := make([dynamic]f64, count); defer delete(zvals)
	vxvals := make([dynamic]string, count); defer delete(vxvals)
	vzvals := make([dynamic]string, count); defer delete(vzvals)
	speedvals := make([dynamic]string, count); defer delete(speedvals)
	directionvals := make([dynamic]string, count); defer delete(directionvals)
	for i in 0..<count {
		turns[i] = "-"
		vxvals[i] = "-"
		vzvals[i] = "-"
		speedvals[i] = "-"
		directionvals[i] = "-"
		xvals[i] = solution.xs[i]-state.x_origin
		zvals[i] = solution.zs[i]-state.z_origin
	}
	for i in 0..<count-2 {
		turns[i] = fmt.aprintf("%.3f", wrap_degrees_180(facings[i+1]-facings[i]))
	}
	defer for i in 0..<count-2 do delete(turns[i])
	for i in 0..<count-1 {
		vx := xvals[i+1]-xvals[i]
		vz := zvals[i+1]-zvals[i]
		vxvals[i] = fmt.aprintf("%.*f", position_precision, vx)
		vzvals[i] = fmt.aprintf("%.*f", position_precision, vz)
		speedvals[i] = fmt.aprintf("%.*f", position_precision, math.sqrt(vx*vx+vz*vz))
		directionvals[i] = fmt.aprintf(
			"%.3f",
			wrap_degrees_180(math.atan2(vx, vz)*180/math.PI),
		)
	}
	defer for i in 0..<count-1 {
		delete(vxvals[i])
		delete(vzvals[i])
		delete(speedvals[i])
		delete(directionvals[i])
	}

	pushed_ui := push_font(ui_font)
	im.Text("Visualization")
	pop_font(pushed_ui)
	viewport_size := compute_plot_viewport_size(xvals[:], zvals[:])
	layout := compute_xz_plot_layout(xvals[:], zvals[:], viewport_size)
	canvas_width := max(viewport_size.x, layout.content_width)
	viewport_size.x += ui_px(25)
	viewport_size.y += ui_px(50)
	im.BeginChild("PlotScroll", {viewport_size.x, viewport_size.y+ui_px(20)}, {.Borders}, {.HorizontalScrollbar})
	if im.IsWindowAppearing() do im.SetScrollX(max(0, 0.5*(canvas_width-viewport_size.x)))
	draw_xz_plot(xvals[:], zvals[:], facings[:], vxvals[:], vzvals[:], state.last_jump_ticks[:], state.color_jump_ticks, {canvas_width, viewport_size.y}, position_precision, angle_precision)
	im.EndChild()
	im.Spacing()
	_ = im.Checkbox(" Color jump ticks", &state.color_jump_ticks)
	im.Spacing(); im.Spacing()

	draw_constraint_results(solution, state.last_solution_discrete)
	im.Spacing(); im.Spacing()

	pushed_ui = push_font(ui_font)
	movement_log_open := im.CollapsingHeader("Movement Log", {.DefaultOpen})
	pop_font(pushed_ui)

	if movement_log_open {
		im.PushStyleVarImVec2(.CellPadding, {ui_px(10), ui_px(3)})
		available := im.GetContentRegionAvail()
		table_width := min(ui_px(877), available.x)
		visible_rows := min(count, 13)
		table_height := ui_px(f32(visible_rows)*34+50)
		table_flags := im.TableFlags_RowBg | im.TableFlags_BordersOuter | im.TableFlags_BordersV |
		               im.TableFlags_ScrollY | im.TableFlags_ScrollX | im.TableFlags_SizingFixedFit |
		               im.TableFlags_NoHostExtendX
		if im.BeginTable("ResultTable", 9, table_flags, {table_width, table_height}) {
			im.TableSetupScrollFreeze(1, 1)
			headers := [?]cstring{
				"Tick",
				"Facing",
				"Turn",
				"X",
				"Z",
				"Vx",
				"Vz",
				"Speed",
				"Direction",
			}
			widths := [?]f32{50, 100, 100, 120, 120, 120, 120, 120, 100}
			for i in 0..<9 do im.TableSetupColumn(headers[i], {.WidthFixed}, ui_px(widths[i]))
			im.TableNextRow({.Headers}, ui_px(20))
			for i in 0..<9 {
				im.TableSetColumnIndex(c.int(i))
				center_text(string(headers[i]))
			}
			jump_text_color := im.Vec4{0.72, 0.62, 0.95, 1}
			for tick in 0..<count {
				im.TableNextRow({}, ui_px(20))
				jump_row := state.color_jump_ticks && tick < len(state.last_jump_ticks) && state.last_jump_ticks[tick]
				angle := "-" if tick >= count-1 else fmt.tprintf("%.3f", facings[tick])
				values := [?]string{
					fmt.tprintf("%d", tick),
					angle,
					turns[tick],
					fmt.tprintf("%.*f", position_precision, xvals[tick]),
					fmt.tprintf("%.*f", position_precision, zvals[tick]),
					vxvals[tick],
					vzvals[tick],
					speedvals[tick],
					directionvals[tick],
				}
				for column in 0..<9 {
					im.TableSetColumnIndex(c.int(column))
					if jump_row {
						center_text_colored(values[column], jump_text_color)
					} else {
						center_text(values[column])
					}
				}
			}
			im.EndTable()
		}
		im.PopStyleVar()
	}
	im.Spacing(); im.Spacing()

	copy_angles := facings[:]
	if !state.post.include_initial_angle && len(copy_angles) > 0 {
		copy_angles = copy_angles[1:]
	}
	display_facings := format_angle_list(copy_angles, false, ", ")
	defer delete(display_facings)
	display_turns := format_angle_list(copy_angles, true, ", ")
	defer delete(display_turns)
	copied_facings := format_angle_list(copy_angles, false, copy_separator(state.post.copy_separator))
	defer delete(copied_facings)
	copied_turns := format_angle_list(copy_angles, true, copy_separator(state.post.copy_separator))
	defer delete(copied_turns)

	initial_angle := solution.thetas[0]
	if !state.last_solution_discrete {
		initial_angle = wrap_degrees_180(initial_angle*180/math.PI)
	}
	pushed_ui = push_font(ui_font)
	_ = im.Checkbox(" Include Initial Angle", &state.post.include_initial_angle)
	im.SameLine(0, 10)
	im.TextDisabled("(Value: %.9f)", initial_angle)
	pop_font(pushed_ui)
	im.Spacing()

	read_only_block("Facing", display_facings, copied_facings)
	im.Spacing()
	read_only_block("Turn", display_turns, copied_turns)

	im.AlignTextToFramePadding()
	pushed_ui = push_font(ui_font)
	im.Text("Separator for copied angles:")
	im.SameLine(0, ui_px(8))
	separator := c.int(state.post.copy_separator)
	im.SetNextItemWidth(ui_px(90))
	items := [?]cstring{"comma", "space", "\\n"}
	if combo_select("##copySeparator", &separator, items[:]) do state.post.copy_separator = Separator_Type(separator)
	pop_font(pushed_ui)
	im.Spacing()

	pop_font(pushed_code)
	im.EndChild()
	im.EndChild()
}
