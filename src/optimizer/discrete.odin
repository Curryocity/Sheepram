package optimizer

import "core:math"
import "core:math/rand"

Discrete_Model :: struct {
	// Part II optimization
	n: int,
	init_v: f64,
	init_drag: f64,
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

eval_discrete_expr :: proc(expr: Compiled_Expr, state: Discrete_State, work: ^Workspace) -> f64 {
	n := len(state.indices)+2
	assert(len(expr.theta_coeff) == n)
	assert_no_terminal_angle_dependency(expr)
	assert(len(work.sin_cache) == n)
	assert(len(work.cos_cache) == n)

	value := expr.constant +
	         expr.theta_coeff[0]*state.init_theta +
	         expr.sin_coeff[0]*work.sin_cache[0] +
	         expr.cos_coeff[0]*work.cos_cache[0]
	for index, i in state.indices {
		t := i+1
		value += expr.theta_coeff[t]*index_to_radians(index) +
		         expr.sin_coeff[t]*work.sin_cache[t] +
		         expr.cos_coeff[t]*work.cos_cache[t]
	}
	return value
}

Discrete_Mode :: enum {
	Repair, Polish,
}

MAX_ROUND_CANDIDATES :: 32
MAX_2_OPT_FAILED_ATTEMPTS :: 4096
PROBE_TOL :: CONSTRAINT_TOLERANCE * 4
FAST_OBJECTIVE_ERR :: CONSTRAINT_TOLERANCE

One_Opt_Cand :: struct {
	tick: int,
	delta: int,
	grade: Grade,
}

local_search :: proc(
	model: ^Discrete_Model,
	p: ^Problem,
	exact_p: ^Raw_Problem,
	sol: ^Solution,
) -> Discrete_State {

	ilen := discrete_angle_len(model)

	state := Discrete_State {
		init_theta = sol.thetas[0],
		indices    = make([dynamic]u16, ilen),
	}
	defer destroy_discrete_state(&state)

	// Two modes:
	// Repair: no exact-feasible solution yet.
	// Polish: an exact-feasible solution exists. improve objective only.
	mode := Discrete_Mode.Repair

	// 1. Clamp the solution down to the lattices
	for i in 0..<ilen {
		state.indices[i] = index(f32(sol.thetas[i+1]))
	}

	work := Workspace {
		sin_cache = make([dynamic]f64, model.n),
		cos_cache = make([dynamic]f64, model.n),
	}
	defer delete(work.sin_cache)
	defer delete(work.cos_cache)

	// 2. Grade the current "solution"

	grade: Grade
	exact_grade: Grade

	// initial prep

	update_discrete_trig_cache(&work, state)
	grading(&grade, p, state, &work)

	champ := Discrete_Cand {
		state = clone_discrete_state(state),
		grade = grade,
	}
	defer destroy_discrete_cand(&champ)

	if mode == .Repair && grade.feasible {
		exact_grading(&exact_grade, exact_p, state)

		if exact_grade.feasible {
			champ.grade = exact_grade
			mode = .Polish
		}
	}

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
	// -> Once exact-feasible, store champ, switch to Polish,
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

	local_champ := clone_discrete_cand(champ)
	defer destroy_discrete_cand(&local_champ)


	for {
		local_improved := false
		clear(&cands)
		copy_discrete_cand(&local_champ, champ)

		copy_discrete_state(&state, champ.state)
		prev_t := 0
		prev_delta := 0


		for t in 0..<ilen {

			for sign in 0..=1 {
				delta := sign == 0 ? 1 : -1

				// backtrack and apply
				state.indices[prev_t] = offset_index(state.indices[prev_t], -prev_delta)
				state.indices[t] = offset_index(state.indices[t], delta)

				update_discrete_trig_cache(&work, state)
				grading(&grade, p, state, &work)

				if improveQ(&grade, &local_champ.grade, mode) {
					copy_discrete_state(&local_champ.state, state)
					local_champ.grade = grade
					local_improved = true
				}

				if good_candQ(&grade, &champ.grade, mode) {
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

			copy_discrete_state(&state, champ.state)
			prev_t = 0
			prev_delta = 0

			for c in cands {
				state.indices[prev_t] = offset_index(state.indices[prev_t], -prev_delta)
				state.indices[c.tick] = offset_index(state.indices[c.tick], c.delta)

				prev_t = c.tick
				prev_delta = c.delta

				exact_grading(&exact_grade, exact_p, state)

				if !exact_grade.feasible {
					continue
				}

				if mode == .Polish && !improveQ(&exact_grade, &champ.grade, mode) {
					continue
				}

				accept = true
				copy_discrete_state(&champ.state, state)
				champ.grade = exact_grade
				mode = .Polish
				break
			}
		}
		
		if !accept && mode == .Repair && local_improved {
			// Case A: it is also a fallback of case B
			copy_discrete_cand(&champ, local_champ)
			accept = true
		}

		if !accept do break
	}
	
	rng_state: rand.Xoshiro256_Random_State
	rng := rand.xoshiro256_random_generator(&rng_state)

	// 4. Greedy random 2-opt
	//
	// Randomly pick a pair.
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
	// -> No improvement this round, or max attempts reached.

	TWO_OPT_STEPS := [5][2]int {
		{1, 1},
		{1, 2},
		{1, 3},
		{2, 1},
		{3, 1},
	}

	if ilen >= 2 {
		failed_attempts := 0
		for failed_attempts < MAX_2_OPT_FAILED_ATTEMPTS {
			t0 := rand.int_max(ilen, rng)
			t1 := rand.int_max(ilen-1, rng)
			if t1 >= t0 do t1 += 1

			if t1 < t0 {
				tmp := t0
				t0 = t1
				t1 = tmp
			}

			accept := false
			local_pair_improved := false
			copy_discrete_cand(&local_champ, champ)

			for step in TWO_OPT_STEPS {

				for s0 in 0..=1 {
					for s1 in 0..=1 {
						d0 := step[0]
						d1 := step[1]

						if s0 == 1 do d0 = -d0
						if s1 == 1 do d1 = -d1

						copy_discrete_state(&state, champ.state)
						state.indices[t0] = offset_index(state.indices[t0], d0)
						state.indices[t1] = offset_index(state.indices[t1], d1)

						update_discrete_trig_cache(&work, state)
						grading(&grade, p, state, &work)

						if mode == .Repair && improveQ(&grade, &local_champ.grade, mode) {
							copy_discrete_state(&local_champ.state, state)
							local_champ.grade = grade
							local_pair_improved = true
						}

						if good_candQ(&grade, &champ.grade, mode) {
							exact_grading(&exact_grade, exact_p, state)

							if !exact_grade.feasible do continue
							if mode == .Polish && !improveQ(&exact_grade, &champ.grade, mode) do continue

							copy_discrete_state(&champ.state, state)
							champ.grade = exact_grade
							mode = .Polish
							accept = true
							break
						}
					}
					if accept do break
				}
				if accept do break
			}

			if !accept && mode == .Repair && local_pair_improved {
				copy_discrete_cand(&champ, local_champ)
				accept = true
			}

			if accept {
				failed_attempts = 0
			} else {
				failed_attempts += 1
			}
		}
	}

	return clone_discrete_state(champ.state)
}

grading :: proc(out: ^Grade, p: ^Problem, state: Discrete_State, work: ^Workspace) {
	out.objective = eval_discrete_expr(p.objective, state, work)
	out.violation_sqr = 0
	out.feasible = true

	for con, i in p.ineq_cons {
		value := eval_discrete_expr(con, state, work)

		violation := max(0, value)
		out.violation_sqr += violation*violation
		if violation > CONSTRAINT_TOLERANCE do out.feasible = false
	}

	for con, i in p.eq_cons {
		value := eval_discrete_expr(con, state, work)

		violation := math.abs(value)
		out.violation_sqr += violation*violation
		if violation > CONSTRAINT_TOLERANCE do out.feasible = false
	}
}

good_candQ :: proc(grade: ^Grade, champ: ^Grade, mode: Discrete_Mode) -> bool {
	if grade.violation_sqr > PROBE_TOL*PROBE_TOL do return false

	switch mode {
	case .Repair:
		return true

	case .Polish:
		return grade.objective < champ.objective + FAST_OBJECTIVE_ERR
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
