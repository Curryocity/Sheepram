package app

import "core:fmt"
import "core:strconv"
import "core:strings"

import opt "../optimizer"

Inertia_Assignments :: struct {
	ticks: [2][3][dynamic]int,
}

destroy_inertia_assignments :: proc(assignments: ^Inertia_Assignments) {
	for axis in 0..<2 {
		for mode in 0..<3 do delete(assignments.ticks[axis][mode])
	}
	assignments^ = {}
}

inertia_assignment_contains :: proc(ticks: []int, tick: int) -> bool {
	for assigned_tick in ticks {
		if assigned_tick == tick do return true
	}
	return false
}

inertia_assignment_name :: proc(axis, mode: int) -> string {
	axis_name := "X" if axis == int(Inertia_Axis.X) else "Z"
	mode_names := [?]string{"Hit", "Avoid-", "Avoid+"}
	return fmt.tprintf("%s %s", axis_name, mode_names[mode])
}

parse_inertia_assignments :: proc(texts: ^[2][3]string, n: int) -> (Inertia_Assignments, string) {
	assignments: Inertia_Assignments
	for axis in 0..<2 {
		for mode in 0..<3 {
			text := strings.trim_space(texts[axis][mode])
			if text == "" do continue

			start := 0
			for start <= len(text) {
				end := start
				for end < len(text) && text[end] != ',' do end += 1
				token := strings.trim_space(text[start:end])
				name := inertia_assignment_name(axis, mode)
				if token == "" {
					return assignments, fmt.aprintf("%s contains an empty tick.", name)
				}

				tick, ok := strconv.parse_int(token, 10)
				if !ok {
					return assignments, fmt.aprintf("%s contains invalid tick '%s'.", name, token)
				}
				if tick < 0 || tick >= n {
					return assignments, fmt.aprintf("%s tick %d is outside [0, %d).", name, tick, n)
				}

				for other_mode in 0..<mode {
					if inertia_assignment_contains(assignments.ticks[axis][other_mode][:], tick) {
						other_name := inertia_assignment_name(axis, other_mode)
						return assignments, fmt.aprintf("Tick %d is assigned to both %s and %s.", tick, other_name, name)
					}
				}
				if !inertia_assignment_contains(assignments.ticks[axis][mode][:], tick) {
					append(&assignments.ticks[axis][mode], tick)
				}

				if end == len(text) do break
				start = end+1
			}
		}
	}
	return assignments, ""
}

apply_inertia_hits :: proc(
	assignments: ^Inertia_Assignments,
	drag_x, drag_z: []f64,
	exact_movement: []opt.Exact_Movement,
) -> (initial_drag_x, initial_drag_z: f64) {
	assert(len(drag_x) > 0 && len(drag_z) > 0)
	initial_drag_x = drag_x[0]
	initial_drag_z = drag_z[0]
	for tick in assignments.ticks[int(Inertia_Axis.X)][int(Inertia_Choice.Hit)-1] {
		drag_x[tick] = 0
		if tick == 0 do initial_drag_x = 0
		else if tick-1 < len(exact_movement) do exact_movement[tick-1].drag_x = 0
	}
	for tick in assignments.ticks[int(Inertia_Axis.Z)][int(Inertia_Choice.Hit)-1] {
		drag_z[tick] = 0
		if tick == 0 do initial_drag_z = 0
		else if tick-1 < len(exact_movement) do exact_movement[tick-1].drag_z = 0
	}
	return
}

has_inertia_assignments :: proc(assignments: ^Inertia_Assignments) -> bool {
	for axis in 0..<2 {
		for mode in 0..<3 {
			if len(assignments.ticks[axis][mode]) > 0 do return true
		}
	}
	return false
}

make_inertia_constraint :: proc(n, tick: int, axis: Inertia_Axis, signed_drag, threshold: f64) -> opt.Raw_Expr {
	expr := opt.make_raw_expr(n)
	expr.constant = threshold
	coefficients := expr.x_coeff[:] if axis == .X else expr.z_coeff[:]
	coefficients[tick] = -signed_drag
	coefficients[tick+1] = signed_drag
	return expr
}

add_inertia_constraints :: proc(
	problem: ^opt.Raw_Problem,
	assignments: ^Inertia_Assignments,
	inertia_drag: []f64,
	threshold: f64,
) -> string {
	assert(len(inertia_drag) >= problem.n)
	for axis in 0..<2 {
		for mode in 0..<3 {
			for tick in assignments.ticks[axis][mode] {
				if tick+1 >= problem.n {
					name := inertia_assignment_name(axis, mode)
					return fmt.aprintf("%s tick %d >= n-1.", name, tick)
				}

				drag := inertia_drag[tick]
				choice := Inertia_Choice(mode+1)
				switch choice {
				case .Hit:
					append(&problem.ineq_cons, make_inertia_constraint(problem.n, tick, Inertia_Axis(axis), drag, -threshold))
					append(&problem.ineq_cons, make_inertia_constraint(problem.n, tick, Inertia_Axis(axis), -drag, -threshold))
				case .Avoid_Minus:
					append(&problem.ineq_cons, make_inertia_constraint(problem.n, tick, Inertia_Axis(axis), drag, threshold))
				case .Avoid_Plus:
					append(&problem.ineq_cons, make_inertia_constraint(problem.n, tick, Inertia_Axis(axis), -drag, threshold))
				case .Lazy:
					unreachable()
				}
			}
		}
	}
	return ""
}
