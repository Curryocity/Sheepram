package optimizer

import "core:math"
import "core:testing"

@(test)
continuous_optimizers_support_shared_facings :: proc(t: ^testing.T) {
	model := Model {
		n = 5,
		n_unique = 3,
		drag_x = make([dynamic]f64, 5),
		drag_z = make([dynamic]f64, 5),
		accel = make([dynamic]f64, 5),
		facing_map = make([dynamic]int, 5),
		angle_offset = make([dynamic]f64, 5),
	}
	defer destroy_model(&model)
	copy(model.drag_x[:], []f64{1, 1, 1, 1, 0})
	copy(model.drag_z[:], []f64{1, 1, 1, 1, 0})
	copy(model.accel[:], []f64{0, 1, 1, 1, 0})
	copy(model.facing_map[:], []int{0, 1, 1, 2, 2})
	copy(model.angle_offset[:], []f64{0, 0, 90, -45, 0})
	compile_model(&model)

	raw := make_raw_expr(model.n)
	defer destroy_raw_expr(&raw)
	raw.z_coeff[4] = -1
	problem := Problem{n = model.n_unique, objective = reduce_expr(raw, &model)}
	defer destroy_problem(&problem)
	work := make_workspace(problem.n)
	defer destroy_workspace(&work)
	seeds := []f64{0.3, 1.2}
	initial := []f64{0.3, 0.3, 0.3}

	for constrained in 0..<2 {
		expected := -(math.sqrt(f64(13))+1)
		if constrained == 1 {
			constraint := make_raw_expr(model.n)
			constraint.f_coeff[2] = 1
			constraint.constant = -0.4*180/math.PI
			append(&problem.eq_cons, reduce_expr(constraint, &model))
			destroy_raw_expr(&constraint)
			expected = -(3*math.cos(f64(0.4))-2*math.sin(f64(0.4))+1)
		}
		for solver in 0..<8 {
			solution: Solution
			switch solver {
			case 0: solution = optimize_1seed(&model, &problem, 0.3)
			case 1: solution = optimize_thetas_slice(&model, &problem, initial, &work)
			case 2: solution, _ = optimize_multistart(&model, &problem, seeds)
			case 3: solution = spine_optimize_1seed(&model, &problem, 0.3)
			case 4: solution = spine_optimize_thetas_slice(&model, &problem, initial, &work)
			case 5: solution, _ = spine_optimize_multistart(&model, &problem, seeds)
			case 6: solution = pancake_optimize(&model, &problem, .Spine, &work)
			case 7: solution = pancake_optimize(&model, &problem, .BFGS)
			}
			testing.expect_value(t, len(solution.thetas), model.n_unique)
			testing.expect_value(t, len(solution.xs), model.n)
			testing.expect_value(t, len(solution.zs), model.n)
			testing.expect(t, math.abs(solution.optimum-expected) < 1e-5)
			testing.expect(t, constraint_violation(&problem, solution.thetas[:], &work) < CONTINUOUS_TOL)
			if constrained == 1 && solver >= 6 do testing.expect(t, solution.pancake_used_recovery)
			vx, vz, x, z: f64
			for tick in 0..<model.n {
				testing.expect(t, math.abs(solution.xs[tick]-x) < 1e-10)
				testing.expect(t, math.abs(solution.zs[tick]-z) < 1e-10)
				theta := solution.thetas[model.facing_map[tick]] + model.angle_offset[tick]*math.PI/180
				if tick > 0 {
					vx *= model.drag_x[tick-1]
					vz *= model.drag_z[tick-1]
				}
				vx += model.accel[tick]*math.sin(theta)
				vz += model.accel[tick]*math.cos(theta)
				x += vx
				z += vz
			}
			destroy_solution(&solution)
		}
	}
}
