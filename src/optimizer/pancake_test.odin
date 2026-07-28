package optimizer

import "core:math"
import "core:testing"

@(test)
pancake_certifies_boundary_solution :: proc(t: ^testing.T) {
	problem := Problem {
		n         = 1,
		objective = make_compiled_expr(1),
	}
	defer destroy_problem(&problem)
	problem.objective.cos_coeff[0] = -1

	result := pancake_solve(&problem)
	defer destroy_pancake_result(&result)

	testing.expect(t, result.converged)
	testing.expect(t, result.certified)
	testing.expect(t, math.abs(result.objective + 1) < 1e-7)
	testing.expect(t, math.abs(result.dual_bound + 1) < 1e-7)
	testing.expect(t, math.abs(result.thetas[0]) < 1e-7)

	model := Model {
		n = 1,
		x = make([dynamic]Compiled_Expr, 1),
		z = make([dynamic]Compiled_Expr, 1),
	}
	defer destroy_model(&model)
	model.x[0] = make_compiled_expr(1)
	model.z[0] = make_compiled_expr(1)
	solution := pancake_optimize(&model, &problem)
	defer destroy_solution(&solution)
	testing.expect(t, solution.continuous_globally_optimal)
	testing.expect(t, solution.pancake_used)
	testing.expect(t, !solution.pancake_used_recovery)
	testing.expect(t, solution.pancake_recovery_reasons == {})
	testing.expect(t, math.abs(solution.pancake_dual_bound + 1) < 1e-7)
}

@(test)
pancake_does_not_certify_interior_solution :: proc(t: ^testing.T) {
	problem := Problem {
		n         = 1,
		objective = make_compiled_expr(1),
		eq_cons   = make([dynamic]Compiled_Expr, 2),
	}
	defer destroy_problem(&problem)
	problem.eq_cons[0] = make_compiled_expr(1)
	problem.eq_cons[0].sin_coeff[0] = 1
	problem.eq_cons[1] = make_compiled_expr(1)
	problem.eq_cons[1].cos_coeff[0] = 1

	result := pancake_solve(&problem)
	defer destroy_pancake_result(&result)

	testing.expect(t, result.converged)
	testing.expect(t, !result.certified)
	testing.expect(t, result.max_radius_deficit > 0.99)
}

@(test)
pancake_reports_gap_and_vector_strength_recovery_reasons :: proc(t: ^testing.T) {
	problem := Problem {
		n         = 1,
		objective = make_compiled_expr(1),
	}
	defer destroy_problem(&problem)
	problem.objective.cos_coeff[0] = -1

	result := Pancake_Result {
		nonreduced        = true,
		objective         = -1,
		dual_bound        = 0,
		gap               = 1,
		max_radius_deficit = 0.5,
		thetas            = make([dynamic]f64, 1),
	}
	defer destroy_pancake_result(&result)

	reasons :=
		pancake_collect_recovery_reasons(&result)
	testing.expect(t, .Large_Dual_Gap in reasons)
	testing.expect(t, .Non_Unit_Vector_Strength in reasons)
	testing.expect(t, !(.Facing_Constraint in reasons))
	testing.expect(t, !(.Infeasible_Solution in reasons))
}

@(test)
pancake_omits_angle_constraints_for_seeding :: proc(t: ^testing.T) {
	problem := Problem {
		n         = 1,
		objective = make_compiled_expr(1),
		ineq_cons = make([dynamic]Compiled_Expr, 1),
	}
	defer destroy_problem(&problem)
	problem.objective.cos_coeff[0] = -1
	problem.ineq_cons[0] = make_compiled_expr(1)
	problem.ineq_cons[0].theta_coeff[0] = 1
	problem.ineq_cons[0].constant = 0.5

	result := pancake_solve(&problem)
	defer destroy_pancake_result(&result)

	testing.expect(t, !result.nonreduced)
	testing.expect(t, !result.certified)
	testing.expect(t, math.abs(result.thetas[0]) < 1e-7)

	model := Model {
		n = 1,
		x = make([dynamic]Compiled_Expr, 1),
		z = make([dynamic]Compiled_Expr, 1),
	}
	defer destroy_model(&model)
	model.x[0] = make_compiled_expr(1)
	model.z[0] = make_compiled_expr(1)
	solution := pancake_optimize(&model, &problem, .BFGS)
	defer destroy_solution(&solution)
	testing.expect(t, solution.pancake_used)
	testing.expect(t, solution.pancake_used_recovery)
	testing.expect(
		t,
		.Facing_Constraint in solution.pancake_recovery_reasons,
	)
	testing.expect(
		t,
		!(.Infeasible_Solution in solution.pancake_recovery_reasons),
	)
	testing.expect(t, math.abs(solution.pancake_dual_bound + 1) < 1e-7)
}

@(test)
pancake_ignores_irrelevant_disk_radius_for_certificate :: proc(t: ^testing.T) {
	problem := Problem {
		n         = 2,
		objective = make_compiled_expr(2),
	}
	defer destroy_problem(&problem)
	problem.objective.cos_coeff[0] = -1

	result := pancake_solve(&problem)
	defer destroy_pancake_result(&result)

	testing.expect(t, result.converged)
	testing.expect(t, result.certified)
	testing.expect(t, result.max_radius_deficit <= PANCAKE_BOUNDARY_TOL)
	testing.expect(t, math.abs(result.objective + 1) <= 1e-7)
}
