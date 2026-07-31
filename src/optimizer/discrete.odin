package optimizer

import "core:math"
import "core:math/rand"
import "core:time"

Discrete_Model :: struct {
	// Part II optimization
	n: int,
	init_v: f64,
	has_init_theta: bool,
	init_theta: f64, // radians
	init_drag: f64,
	angle_offset: [dynamic]f64, // radians, theta = facing + angle_offset
	exact_movement: [dynamic]Exact_Movement,

	vx: [dynamic]Compiled_Expr,
	vz: [dynamic]Compiled_Expr,
	x:  [dynamic]Compiled_Expr,
	z:  [dynamic]Compiled_Expr,
}

Discrete_State :: struct {
	init_theta: f64,
	indices: [dynamic]u16,
}

Grade :: struct {
	objective: f64,
	violation_sqr: f64,
	feasible: bool,
}

Discrete_Cand :: struct {
	state: Discrete_State,
	grade: Grade,
}

clone_discrete_state :: proc(state: Discrete_State) -> Discrete_State {
	out := Discrete_State {
		init_theta = state.init_theta,
		indices    = make([dynamic]u16, len(state.indices)),
	}
	copy(out.indices[:], state.indices[:])
	return out
}

copy_discrete_state :: proc(dst: ^Discrete_State, src: Discrete_State) {
	assert(len(dst.indices) == len(src.indices))
	dst.init_theta = src.init_theta
	copy(dst.indices[:], src.indices[:])
}

destroy_discrete_state :: proc(state: ^Discrete_State) {
	delete(state.indices)
	state^ = {}
}

clone_discrete_cand :: proc(cand: Discrete_Cand) -> Discrete_Cand {
	return Discrete_Cand {
		state = clone_discrete_state(cand.state),
		grade = cand.grade,
	}
}

copy_discrete_cand :: proc(dst: ^Discrete_Cand, src: Discrete_Cand) {
	copy_discrete_state(&dst.state, src.state)
	dst.grade = src.grade
}

destroy_discrete_cand :: proc(cand: ^Discrete_Cand) {
	destroy_discrete_state(&cand.state)
	cand^ = {}
}

destroy_discrete_model :: proc(model: ^Discrete_Model) {
	delete(model.exact_movement)
	delete(model.angle_offset)
	destroy_compiled_expr_array(&model.vx)
	destroy_compiled_expr_array(&model.vz)
	destroy_compiled_expr_array(&model.x)
	destroy_compiled_expr_array(&model.z)
	model^ = {}
}

copy_discrete_exprs :: proc(discrete: ^Discrete_Model, model: ^Model) {
	assert(discrete.n == model.n)
	destroy_compiled_expr_array(&discrete.vx)
	destroy_compiled_expr_array(&discrete.vz)
	destroy_compiled_expr_array(&discrete.x)
	destroy_compiled_expr_array(&discrete.z)
	discrete.vx = clone_compiled_expr_array(model.vx[:])
	discrete.vz = clone_compiled_expr_array(model.vz[:])
	discrete.x  = clone_compiled_expr_array(model.x[:])
	discrete.z  = clone_compiled_expr_array(model.z[:])
}

discrete_angle_len :: proc(model: ^Discrete_Model) -> int {
	if model.n <= 2 do return 0
	return model.n-2
}

assert_discrete_state :: proc(model: ^Discrete_Model, state: Discrete_State) {
	assert(len(state.indices) == discrete_angle_len(model))
}

offset_index :: proc(index: u16, delta: int) -> u16 {
	return u16((int(index)+delta) & SINE_TABLE_MASK)
}

assert_no_terminal_angle_dependency :: proc(expr: Compiled_Expr) {
	assert(len(expr.theta_coeff) == len(expr.sin_coeff))
	assert(len(expr.theta_coeff) == len(expr.cos_coeff))
	if len(expr.theta_coeff) == 0 do return

	last := len(expr.theta_coeff)-1
	assert(math.abs(expr.theta_coeff[last]) <= EPS, "Discrete expression depends on terminal theta")
	assert(math.abs(expr.sin_coeff[last]) <= EPS, "Discrete expression depends on terminal sin(theta)")
	assert(math.abs(expr.cos_coeff[last]) <= EPS, "Discrete expression depends on terminal cos(theta)")
}

discrete_state_deg :: proc(state: Discrete_State, t: int) -> f64 {
	if t == 0 do return state.init_theta*180/math.PI
	return index_to_facing(state.indices[t-1])
}

eval_discrete_expr :: proc(
	expr: Compiled_Expr,
	state: Discrete_State,
	angle_offset: []f64,
	work: ^Workspace,
) -> f64 {
	n := len(state.indices)+2
	assert(len(expr.theta_coeff) == n)
	assert_no_terminal_angle_dependency(expr)
	assert(len(work.sin_cache) == n)
	assert(len(work.cos_cache) == n)
	assert(len(angle_offset) >= n)

	value := expr.constant +
	         expr.theta_coeff[0]*state.init_theta +
	         expr.sin_coeff[0]*work.sin_cache[0] +
	         expr.cos_coeff[0]*work.cos_cache[0]
	for index, i in state.indices {
		t := i+1
		theta := index_to_radians(index) + angle_offset[t]
		value += expr.theta_coeff[t]*theta +
		         expr.sin_coeff[t]*work.sin_cache[t] +
		         expr.cos_coeff[t]*work.cos_cache[t]
	}
	return value
}

Discrete_Mode :: enum {
	Repair, Polish,
}

Local_Search_Mode :: enum {
	Regular,
	Cooking,
}

Cancel_Check :: proc(data: rawptr) -> bool

LS_Control :: struct {
	cancel_check: Cancel_Check,
	cancel_data: rawptr,
	cancelled: ^bool,
	cancel_last_check: time.Tick,
}

FAST_ERR :: 5e-7
WORSE_ACCEPT_THRESHOLD :: 256
MAX_DROP :: ACCEPT_TOL
MAX_DOWN_HILLS :: 128
CANCEL_CHECK_SEC :: 0.25

TWO_OPT_DELTAS :: [?][2]int {
	{ 1,  1}, { 1, -1}, {-1,  1}, {-1, -1},
	{ 1,  2}, { 1, -2}, {-1,  2}, {-1, -2},
	{ 1,  3}, { 1, -3}, {-1,  3}, {-1, -3},
	{ 2,  1}, { 2, -1}, {-2,  1}, {-2, -1},
	{ 3,  1}, { 3, -1}, {-3,  1}, {-3, -1},
}

get_pair :: proc(rank: int, ilen: int) -> (int, int) {
	assert(rank >= 0 && rank < ilen*(ilen-1)/2)

	remaining := rank
	for t0 in 0..<ilen-1 {
		count := ilen-t0-1
		if remaining < count {
			return t0, t0+1+remaining
		}
		remaining -= count
	}

	return 0, 1
}

create_pair_orders :: proc(pair_count: int) -> [dynamic]int {
	pairs := make([dynamic]int, 0, pair_count)
	for rank in 0..<pair_count {
		append(&pairs, rank)
	}
	return pairs
}

cancel_requested :: proc(control: ^LS_Control) -> bool {
	if control == nil || control.cancel_check == nil do return false
	if time.duration_seconds(time.tick_since(control.cancel_last_check)) < CANCEL_CHECK_SEC {
		return false
	}
	control.cancel_last_check = time.tick_now()
	return control.cancel_check(control.cancel_data)
}

one_opt_descent :: proc(
	model: ^Discrete_Model,
	exact_p: ^Raw_Problem,
	current: ^Discrete_Cand,
	mode: ^Discrete_Mode,
	trial: ^Discrete_State,
	exact_work: ^Exact_Workspace,
	control: ^LS_Control,
	max_delta: int = 1,
) -> (improved, cancelled: bool) {
	ilen := discrete_angle_len(model)
	exact_grade: Grade
	exact_grading(&exact_grade, model, exact_p, current.state, exact_work)
	current.grade = exact_grade
	mode^ = .Polish if exact_grade.feasible else .Repair

	for {
		if cancel_requested(control) {
			return improved, true
		}

		best_found := false
		best_tick := 0
		best_delta := 0
		best_grade := current.grade

		copy_discrete_state(trial, current.state)

		for t in 0..<ilen {
			old_index := trial.indices[t]
			for magnitude in 1..=max_delta {
				for sign in 0..=1 {
					delta := sign == 0 ? magnitude : -magnitude
					trial.indices[t] = offset_index(old_index, delta)

					exact_grading(&exact_grade, model, exact_p, trial^, exact_work)
					if improveQ(&exact_grade, &best_grade, mode^) {
						best_found = true
						best_tick = t
						best_delta = delta
						best_grade = exact_grade
					}
				}
			}
			trial.indices[t] = old_index
		}

		if !best_found do return improved, false

		current.state.indices[best_tick] = offset_index(current.state.indices[best_tick], best_delta)
		current.grade = best_grade
		mode^ = .Polish if best_grade.feasible else .Repair
		improved = true
	}
}

exact_grade_two_opt :: #force_inline proc(
	out: ^Grade,
	model: ^Discrete_Model,
	p: ^Raw_Problem,
	state: ^Discrete_State,
	t0, t1: int,
	delta: [2]int,
	work: ^Exact_Workspace,
) {
	old0 := state.indices[t0]
	old1 := state.indices[t1]
	state.indices[t0] = offset_index(old0, delta[0])
	state.indices[t1] = offset_index(old1, delta[1])

	exact_grading(out, model, p, state^, work)

	state.indices[t0] = old0
	state.indices[t1] = old1
}

two_opt_descent :: #force_inline proc(
	model: ^Discrete_Model,
	p: ^Problem,
	exact_p: ^Raw_Problem,
	current: ^Discrete_Cand,
	best: ^Discrete_Cand,
	mode: ^Discrete_Mode,
	exact_work: ^Exact_Workspace,
	search_mode: Local_Search_Mode,
	control: ^LS_Control,
) -> (cancelled: bool) {
	ilen := discrete_angle_len(model)

	work := make_workspace(model.n)
	defer destroy_workspace(&work)

	baseline := make_discrete_baseline(model, p)
	defer destroy_discrete_baseline(&baseline)
	rebuild_discrete_baseline(&baseline, model, p, current.state, &work, mode^)

	rng_state: rand.Xoshiro256_Random_State
	rng := rand.xoshiro256_random_generator(&rng_state)

	exact_grade: Grade
	pair_count := ilen*(ilen-1)/2
	pairs := create_pair_orders(pair_count)
	defer delete(pairs)
	down_hills := 0

	for {
		if cancel_requested(control) do return true

		accept := false
		attempts := 0
		max_attempts := pair_count

		if search_mode == .Cooking {
			max_attempts = 512 * model.n
		} else {
			for i := len(pairs)-1; i > 0; i -= 1 {
				j := rand.int_max(i+1, rng)
				tmp := pairs[i]
				pairs[i] = pairs[j]
				pairs[j] = tmp
			}
		}

		for attempts < max_attempts {
			if cancel_requested(control) do return true
			attempts += 1

			t0, t1: int
			if search_mode == .Cooking {
				t0 = rand.int_max(ilen, rng)
				t1 = rand.int_max(ilen-1, rng)
				if t1 >= t0 do t1 += 1
				if t1 < t0 {
					tmp := t0
					t0 = t1
					t1 = tmp
				}
			} else {
				t0, t1 = get_pair(pairs[attempts-1], ilen)
			}

			local_pair_improved := false
			local_pair_best := Two_Opt_Grade {
				violation_sqr = baseline.violation_sqr,
				feasible = baseline.feasible,
			}
			local_pair_delta := [2]int{}

			for delta in TWO_OPT_DELTAS {
				move := Two_Opt_Move {
					deltas = delta,
					ticks = {t0, t1},
				}
				two_opt_grade: Two_Opt_Grade
				grade_two_opt(&two_opt_grade, &baseline, model, p, &move, mode^)

				if mode^ == .Repair &&
				   improve_two_opt_repairQ(&two_opt_grade, &local_pair_best) {
					local_pair_best = two_opt_grade
					local_pair_delta = delta
					local_pair_improved = true
				}

				if good_two_opt_candQ(&two_opt_grade, &baseline, &current.grade, p, mode^, search_mode) {
					exact_grade_two_opt(&exact_grade, model, exact_p, &current.state, t0, t1, delta, exact_work)

					if !exact_grade.feasible do continue

					exact_improved := improveQ(&exact_grade, &current.grade, mode^)
					accept_worse := false
					if !exact_improved {
						if search_mode != .Cooking do continue
						if mode^ != .Polish do continue
						if attempts < WORSE_ACCEPT_THRESHOLD do continue
						if down_hills >= MAX_DOWN_HILLS do continue
						if exact_grade.objective >= current.grade.objective + MAX_DROP do continue
						accept_worse = true
					}

					current.state.indices[t0] = offset_index(current.state.indices[t0], delta[0])
					current.state.indices[t1] = offset_index(current.state.indices[t1], delta[1])
					current.grade = exact_grade
					mode^ = .Polish
					rebuild_discrete_baseline(&baseline, model, p, current.state, &work, mode^)
					accept = true

					if exact_improved &&
					   (!best.grade.feasible || improveQ(&current.grade, &best.grade, .Polish)) {
						copy_discrete_cand(best, current^)
					}

					if accept_worse do down_hills += 1
					break
				}
			}

			if !accept && mode^ == .Repair && local_pair_improved {
				current.state.indices[t0] = offset_index(current.state.indices[t0], local_pair_delta[0])
				current.state.indices[t1] = offset_index(current.state.indices[t1], local_pair_delta[1])
				rebuild_discrete_baseline(&baseline, model, p, current.state, &work, mode^)
				current.grade = baseline_grade(&baseline)
				accept = true
			}

			if accept do break
		}

		if !accept do return false
	}
}

local_search :: proc(
	model: ^Discrete_Model,
	p: ^Problem,
	exact_p: ^Raw_Problem,
	sol: ^Solution,
	search_mode: Local_Search_Mode,
	control: ^LS_Control = nil,
) -> Discrete_State {

	ilen := discrete_angle_len(model)

	init_theta := sol.thetas[0]
	if model.has_init_theta do init_theta = model.init_theta

	trial := Discrete_State {
		init_theta = init_theta,
		indices    = make([dynamic]u16, ilen),
	}
	defer destroy_discrete_state(&trial)

	// Two modes:
	// Repair: no exact-feasible solution yet.
	// Polish: an exact-feasible solution exists. improve objective only.
	mode := Discrete_Mode.Repair

	// 1. Clamp the solution down to the lattices
	for i in 0..<ilen {
		t := i+1
		facing := sol.thetas[t] - model.angle_offset[t]
		trial.indices[i] = index(f32(facing))
	}

	exact_work := make_exact_workspace(model.n)
	defer destroy_exact_workspace(&exact_work)

	current := Discrete_Cand {
		state = clone_discrete_state(trial),
	}
	defer destroy_discrete_cand(&current)

	if control != nil do control.cancel_last_check = time.tick_now()
	search_cancelled := false

	// 2. Exact steepest 1-opt ±1 rounds
	//
	// Exact-grade every single-index neighbor and accept the best move.
	// Repair minimizes exact violation. Polish minimizes exact objective.

	_, search_cancelled = one_opt_descent(model, exact_p, &current, &mode, &trial, &exact_work, control)

	best := clone_discrete_cand(current)
	defer destroy_discrete_cand(&best)

	if ilen < 2 {
		if control != nil && control.cancelled != nil do control.cancelled^ = search_cancelled
		return clone_discrete_state(best.state)
	}

	// 3. Greedy randomized 2-opt
	if !search_cancelled {
		search_cancelled = two_opt_descent(model, p, exact_p, &current, &best, &mode, &exact_work, search_mode, control)
	}

	// 4. Exact steepest 1-opt cleanup with ±1, ±2, and ±3 moves
	if !search_cancelled {
		_, search_cancelled = one_opt_descent(model, exact_p, &current, &mode, &trial, &exact_work, control, 3)
	}

	if mode == .Polish &&
	   (!best.grade.feasible || improveQ(&current.grade, &best.grade, .Polish)) {
		copy_discrete_cand(&best, current)
	} else if !best.grade.feasible &&
	          improveQ(&current.grade, &best.grade, .Repair) {
		copy_discrete_cand(&best, current)
	}

	if control != nil && control.cancelled != nil do control.cancelled^ = search_cancelled
	return clone_discrete_state(best.state)
}

Two_Opt_Move :: struct {
	deltas: [2]int,
	ticks: [2]int, // Indices into Discrete_State.indices.

	dsin: [2]f64,
	dcos: [2]f64,
	dtheta: [2]f64,
}

Two_Opt_Grade :: struct {
	objective_delta: f64,
	violation_sqr: f64,
	feasible: bool,
}

Discrete_Baseline :: struct {
	state: Discrete_State,
	objective: f64,
	inequality_values: [dynamic]f64,
	equality_values: [dynamic]f64,
	violation_sqr: f64,
	feasible: bool,
}

make_discrete_baseline :: proc(
	model: ^Discrete_Model,
	p: ^Problem,
) -> Discrete_Baseline {
	return {
		state = {
			indices = make([dynamic]u16, discrete_angle_len(model)),
		},
		inequality_values = make([dynamic]f64, len(p.ineq_cons)),
		equality_values = make([dynamic]f64, len(p.eq_cons)),
	}
}

destroy_discrete_baseline :: proc(base: ^Discrete_Baseline) {
	destroy_discrete_state(&base.state)
	delete(base.inequality_values)
	delete(base.equality_values)
	base^ = {}
}

rebuild_discrete_baseline :: proc(
	base: ^Discrete_Baseline,
	model: ^Discrete_Model,
	p: ^Problem,
	state: Discrete_State,
	work: ^Workspace,
	mode: Discrete_Mode,
) {
	assert(len(base.state.indices) == len(state.indices))
	assert(len(base.inequality_values) == len(p.ineq_cons))
	assert(len(base.equality_values) == len(p.eq_cons))

	copy_discrete_state(&base.state, state)
	update_discrete_trig_cache(work, state, model.angle_offset[:])

	base.objective = eval_discrete_expr(p.objective, state, model.angle_offset[:], work)
	base.violation_sqr = 0
	base.feasible = true

	for constraint, i in p.ineq_cons {
		value := eval_discrete_expr(constraint, state, model.angle_offset[:], work)
		base.inequality_values[i] = value
		violation := max(0.0, value)
		base.violation_sqr += violation*violation
		if violation > FAST_ERR do base.feasible = false
	}

	for constraint, i in p.eq_cons {
		value := eval_discrete_expr(constraint, state, model.angle_offset[:], work)
		base.equality_values[i] = value
		violation := math.abs(value)
		base.violation_sqr += violation*violation
		if violation > ACCEPT_TOL do base.feasible = false
	}

	if mode == .Repair && base.violation_sqr > 0 {
		base.feasible = false
	}
}

baseline_grade :: proc(base: ^Discrete_Baseline) -> Grade {
	return {
		objective = base.objective,
		violation_sqr = base.violation_sqr,
		feasible = base.feasible,
	}
}

grade_two_opt :: proc(
	out: ^Two_Opt_Grade,
	base: ^Discrete_Baseline,
	model: ^Discrete_Model,
	p: ^Problem,
	move: ^Two_Opt_Move,
	mode: Discrete_Mode,
) {
	assert(len(base.inequality_values) == len(p.ineq_cons))
	assert(len(base.equality_values) == len(p.eq_cons))
	assert(move.ticks[0] != move.ticks[1])

	out^ = {
		feasible = true,
	}

	for i in 0..<2 {
		state_index := move.ticks[i]
		assert(state_index >= 0 && state_index < len(base.state.indices))

		old_idx := base.state.indices[state_index]
		new_idx := offset_index(old_idx, move.deltas[i])
		actual_t := state_index + 1

		old_s, old_c := trig_index_offset(old_idx, model.angle_offset[actual_t])
		new_s, new_c := trig_index_offset(new_idx, model.angle_offset[actual_t])

		move.dsin[i] = new_s - old_s
		move.dcos[i] = new_c - old_c
		move.dtheta[i] = index_to_radians(new_idx) - index_to_radians(old_idx)
	}

	out.objective_delta = two_opt_expr_delta(p.objective, move)

	for constraint, i in p.ineq_cons {
		old_val := base.inequality_values[i]
		new_val := old_val + two_opt_expr_delta(constraint, move)
		new_vio := max(0.0, new_val)

		out.violation_sqr += new_vio*new_vio
		if new_vio > FAST_ERR do out.feasible = false
	}

	for constraint, i in p.eq_cons {
		old_value := base.equality_values[i]
		new_value := old_value + two_opt_expr_delta(constraint, move)
		new_vio := math.abs(new_value)

		out.violation_sqr += new_vio*new_vio
		if new_vio > ACCEPT_TOL do out.feasible = false
	}

	if mode == .Repair && out.violation_sqr > 0 {
		out.feasible = false
	}
}

two_opt_expr_delta :: proc(expr: Compiled_Expr, move: ^Two_Opt_Move) -> f64 {
	delta := f64(0)

	for i in 0..<2 {
		t := move.ticks[i] + 1
		delta += expr.sin_coeff[t] * move.dsin[i]
		delta += expr.cos_coeff[t] * move.dcos[i]
		delta += expr.theta_coeff[t] * move.dtheta[i]
	}

	return delta
}

viosqr_tol :: proc(p: ^Problem) -> f64 {
	constraint_count := len(p.ineq_cons) + len(p.eq_cons)
	return f64(max(1, constraint_count)) * FAST_ERR * FAST_ERR
}

good_two_opt_candQ :: proc(
	grade: ^Two_Opt_Grade,
	base: ^Discrete_Baseline,
	champ: ^Grade,
	p: ^Problem,
	mode: Discrete_Mode,
	search_mode: Local_Search_Mode,
) -> bool {
	if grade.violation_sqr > viosqr_tol(p) do return false

	switch mode {
	case .Repair:
		return true

	case .Polish:
		trial_objective := base.objective + grade.objective_delta
		if search_mode == .Cooking {
			return trial_objective < champ.objective + MAX_DROP
		}
		return trial_objective < champ.objective + FAST_ERR
	}

	return false
}

improveQ :: proc(new: ^Grade, src: ^Grade, mode: Discrete_Mode) -> bool {
	switch mode {
	case .Repair:
		if new.feasible != src.feasible {
			return new.feasible
		}
		if !new.feasible {
			return new.violation_sqr < src.violation_sqr
		}

	case .Polish:
		if !new.feasible do return false
		if !src.feasible do return true
	}

	return new.objective < src.objective
}

improve_two_opt_repairQ :: proc(new: ^Two_Opt_Grade, src: ^Two_Opt_Grade) -> bool {
	if new.feasible != src.feasible {
		return new.feasible
	}
	if !new.feasible {
		return new.violation_sqr < src.violation_sqr
	}

	return new.objective_delta < src.objective_delta
}

create_exact_solution :: proc(discrete: ^Discrete_Model, state: Discrete_State) -> Solution {
	assert_discrete_state(discrete, state)

	solution := Solution {
		thetas = make([dynamic]f64, discrete.n),
		xs     = make([dynamic]f64, discrete.n),
		zs     = make([dynamic]f64, discrete.n),
	}

	if discrete.n > 0 {
		solution.thetas[0] = state.init_theta*180/math.PI
	}
	for index, i in state.indices {
		solution.thetas[i+1] = index_to_facing(index)
	}

	if discrete.n > 1 {
		// Last facing has no effect on recorded positions
		solution.thetas[discrete.n-1] = solution.thetas[discrete.n-2]
	}

	exact_simulation(discrete, state, solution.xs[:], solution.zs[:])
	return solution
}
