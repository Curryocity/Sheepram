package optimizer

import "core:math"
import "core:math/rand"

Discrete_Model :: struct {
	// Part II optimization
	n: int,
	init_v: f64,
	has_init_theta: bool,
	init_theta: f64, // radians
	init_drag: f64,
	angle_offset: [dynamic]f64, // radians; theta = facing + angle_offset
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

destroy_discrete_cand_arr :: proc(cands: ^[dynamic]Discrete_Cand) {
	for i in 0..<len(cands^) do destroy_discrete_cand(&cands^[i])
	delete(cands^)
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

MAX_ROUND_CANDIDATES :: 32
MAX_2_OPT_ATTEMPTS :: 4096
WORSE_ACCEPT_THRESHOLD :: 256
MAX_DROP :: ACCEPT_TOL
MAX_DOWN_HILLS :: 128

One_Opt_Cand :: struct {
	tick: int,
	delta: int,
	grade: Grade,
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

local_search :: proc(
	model: ^Discrete_Model,
	p: ^Problem,
	exact_p: ^Raw_Problem,
	sol: ^Solution,
	search_mode: Local_Search_Mode,
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

	work := Workspace {
		sin_cache = make([dynamic]f64, model.n),
		cos_cache = make([dynamic]f64, model.n),
	}
	defer delete(work.sin_cache)
	defer delete(work.cos_cache)

	exact_work := make_exact_workspace(model.n)
	defer destroy_exact_workspace(&exact_work)

	rng_state: rand.Xoshiro256_Random_State
	rng := rand.xoshiro256_random_generator(&rng_state)

	// 2. Grade the current "solution"

	grade: Grade
	exact_grade: Grade

	// initial prep

	update_discrete_trig_cache(&work, trial, model.angle_offset[:])
	grading(&grade, model, p, trial, &work)

	current := Discrete_Cand {
		state = clone_discrete_state(trial),
		grade = grade,
	}
	defer destroy_discrete_cand(&current)

	if mode == .Repair && grade.feasible {
		exact_grading(&exact_grade, model, exact_p, trial, &exact_work)

		if exact_grade.feasible {
			current.grade = exact_grade
			mode = .Polish
		}
	}

	best := clone_discrete_cand(current)
	defer destroy_discrete_cand(&best)
	has_best := mode == .Polish

	// 3. Greedy full 1-opt ±1 rounds
	//
	// For each round, grade every single-index ±1 neighbor.
	//
	// Case A: Repair mode + no fast-feasible candidates
	// -> Accept the best repair-grade candidate:
	//    violation_sqr, then objective.
	//
	// Case B: Repair mode + fast-feasible candidates exist
	// -> Exact-check fast-feasible candidates from best to worst.
	// -> Once exact-feasible, store current, switch to Polish,
	//    and continue next round.
	// -> If none exact-feasible, accept the best repair-grade candidate.
	//
	// Case C: Polish mode
	// -> Exact-check fast-feasible objective-improving candidates
	//    from best to worst.
	// -> Accept only exact-feasible objective improvement.
	//
	// End condition:
	// -> No accepted 1-opt move this round, go to 2-opt phase.

	cands := make([dynamic]One_Opt_Cand, 0, MAX_ROUND_CANDIDATES)
	defer delete(cands)

	local_current := clone_discrete_cand(current)
	defer destroy_discrete_cand(&local_current)

	for {
		local_improved := false
		resize(&cands, 0)
		copy_discrete_cand(&local_current, current)

		copy_discrete_state(&trial, current.state)
		prev_t := 0
		prev_delta := 0


		for t in 0..<ilen {

			for sign in 0..=1 {
				delta := sign == 0 ? 1 : -1

				// backtrack and apply
				trial.indices[prev_t] = offset_index(trial.indices[prev_t], -prev_delta)
				trial.indices[t] = offset_index(trial.indices[t], delta)

				update_discrete_trig_cache(&work, trial, model.angle_offset[:])
				grading(&grade, model, p, trial, &work)

				if improveQ(&grade, &local_current.grade, mode) {
					copy_discrete_state(&local_current.state, trial)
					local_current.grade = grade
					local_improved = true
				}

				if good_candQ(&grade, &current.grade, mode, search_mode) {
					insert_one_opt_cand(&cands, One_Opt_Cand {
						tick  = t,
						delta = delta,
						grade = grade,
					}, mode)
				}

				prev_t = t
				prev_delta = delta
			}
		}

		accept := false

		if len(cands) > 0 {
			// Case B/C:
			// exact-check top-K fast-feasible candidates from best to worst

			copy_discrete_state(&trial, current.state)
			prev_t = 0
			prev_delta = 0

			for c in cands {
				trial.indices[prev_t] = offset_index(trial.indices[prev_t], -prev_delta)
				trial.indices[c.tick] = offset_index(trial.indices[c.tick], c.delta)

				prev_t = c.tick
				prev_delta = c.delta

				exact_grading(&exact_grade, model, exact_p, trial, &exact_work)

				if !exact_grade.feasible {
					continue
				}

				if mode == .Polish && !improveQ(&exact_grade, &current.grade, mode) {
					continue
				}

				accept = true
				copy_discrete_state(&current.state, trial)
				current.grade = exact_grade
				mode = .Polish
				break
			}
		}
		
		if !accept && mode == .Repair && local_improved {
			// Case A: it is also a fallback of case B
			copy_discrete_cand(&current, local_current)
			accept = true
		}

		if !accept do break
	}

	// 4. Greedy randomized 2-opt
	//
	// Regular mode shuffles tick-pair ranks and tries each pair at most once.
	// Cooking mode samples random pairs with replacement and allows bounded
	// worse exact moves after the initial attempt window.
	// Try signed versions of:
	//     (1,1), (1,2), (1,3), (2,1), (3,1)
	//
	// Repair mode:
	// -> Prefer exact-feasible candidate if found.
	// -> Otherwise accept best violation-reducing pair move.
	//
	// Polish mode:
	// -> Exact-check candidates that are fast-feasible and
	//    objective-improving.
	// -> Accept only exact-feasible objective improvement.
	//
	// End condition:
	// -> No improvement after the pair budget is exhausted.

	TWO_OPT_DELTAS := [?][2]int {
		{ 1,  1}, { 1, -1}, {-1,  1}, {-1, -1},
		{ 1,  2}, { 1, -2}, {-1,  2}, {-1, -2},
		{ 1,  3}, { 1, -3}, {-1,  3}, {-1, -3},
		{ 2,  1}, { 2, -1}, {-2,  1}, {-2, -1},
		{ 3,  1}, { 3, -1}, {-3,  1}, {-3, -1},
	}

	if ilen < 2 do return clone_discrete_state(best.state)

	if mode == .Polish && (!has_best || improveQ(&current.grade, &best.grade, .Polish)) {
		copy_discrete_cand(&best, current)
		has_best = true
	}

	pair_count := ilen*(ilen-1)/2
	pairs := create_pair_orders(pair_count)
	defer delete(pairs)
	down_hills := 0

	for {
		accept := false
		attempts := 0
		max_attempts := pair_count

		if search_mode == .Cooking {
			max_attempts = MAX_2_OPT_ATTEMPTS
		} else {
			for i := len(pairs)-1; i > 0; i -= 1 {
				j := rand.int_max(i+1, rng)
				tmp := pairs[i]
				pairs[i] = pairs[j]
				pairs[j] = tmp
			}
		}

		for attempts < max_attempts {
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
			copy_discrete_cand(&local_current, current)

			for delta in TWO_OPT_DELTAS {
				copy_discrete_state(&trial, current.state)
				trial.indices[t0] = offset_index(trial.indices[t0], delta[0])
				trial.indices[t1] = offset_index(trial.indices[t1], delta[1])

				update_discrete_trig_cache(&work, trial, model.angle_offset[:])
				grading(&grade, model, p, trial, &work)

				if mode == .Repair && improveQ(&grade, &local_current.grade, mode) {
					copy_discrete_state(&local_current.state, trial)
					local_current.grade = grade
					local_pair_improved = true
				}

				if good_candQ(&grade, &current.grade, mode, search_mode) {
					exact_grading(&exact_grade, model, exact_p, trial, &exact_work)

					if !exact_grade.feasible do continue

					exact_improved := improveQ(&exact_grade, &current.grade, mode)
					accept_worse := false
					if !exact_improved {
						if search_mode != .Cooking do continue
						if mode != .Polish do continue
						if attempts < WORSE_ACCEPT_THRESHOLD do continue
						if down_hills >= MAX_DOWN_HILLS do continue
						if exact_grade.objective >= current.grade.objective + MAX_DROP do continue
						accept_worse = true
					}

					copy_discrete_state(&current.state, trial)
					current.grade = exact_grade
					mode = .Polish
					accept = true

					if exact_improved {
						if !has_best || improveQ(&current.grade, &best.grade, .Polish) {
							copy_discrete_cand(&best, current)
							has_best = true
						}
					}

					if accept_worse {
						down_hills += 1
					}

					break
				}
			}

			if !accept && mode == .Repair && local_pair_improved {
				copy_discrete_cand(&current, local_current)
				accept = true
			}

			if accept do break
		}

		if !accept do break
	}

	if mode == .Polish && (!has_best || improveQ(&current.grade, &best.grade, .Polish)) {
		copy_discrete_cand(&best, current)
		has_best = true
	} else if !has_best && improveQ(&current.grade, &best.grade, .Repair) {
		copy_discrete_cand(&best, current)
	}

	return clone_discrete_state(best.state)
}

grading :: proc(out: ^Grade, model: ^Discrete_Model, p: ^Problem, state: Discrete_State, work: ^Workspace) {
	out.objective = eval_discrete_expr(p.objective, state, model.angle_offset[:], work)
	out.violation_sqr = 0
	out.feasible = true

	for con, i in p.ineq_cons {
		value := eval_discrete_expr(con, state, model.angle_offset[:], work)

		violation := max(0, value)
		out.violation_sqr += violation*violation
		if violation > ACCEPT_TOL do out.feasible = false
	}

	for con, i in p.eq_cons {
		value := eval_discrete_expr(con, state, model.angle_offset[:], work)

		violation := math.abs(value)
		out.violation_sqr += violation*violation
		if violation > ACCEPT_TOL do out.feasible = false
	}
}

good_candQ :: proc(
	grade: ^Grade,
	champ: ^Grade,
	mode: Discrete_Mode,
	search_mode: Local_Search_Mode,
) -> bool {
	if grade.violation_sqr > ACCEPT_TOL*ACCEPT_TOL do return false

	switch mode {
	case .Repair:
		return true

	case .Polish:
		if search_mode == .Cooking {
			return grade.objective < champ.objective + max(ACCEPT_TOL, MAX_DROP)
		}
		return grade.objective < champ.objective + ACCEPT_TOL
	}

	return false
}

// Sorted from best to worst
insert_one_opt_cand :: proc(cands: ^[dynamic]One_Opt_Cand, cand: One_Opt_Cand, mode: Discrete_Mode) -> bool {
	
	candidate := cand
	pos := len(cands^)
	for i in 0..<len(cands^) {
		if improveQ(&candidate.grade, &cands^[i].grade, mode) {
			pos = i
			break
		}
	}

	// Overcrowd and is not top-K
	if pos == len(cands^) && len(cands^) >= MAX_ROUND_CANDIDATES {
		return false
	}

	if len(cands^) < MAX_ROUND_CANDIDATES {
		append(cands, One_Opt_Cand{})
	}

	for i := len(cands^)-1; i > pos; i -= 1 {
		cands^[i] = cands^[i-1]
	}

	cands^[pos] = candidate
	return true
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
