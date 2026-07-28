package optimizer

import "core:math"
import "core:testing"

spine_test_close :: proc(actual, expected, tolerance: f64) -> bool {
	return math.abs(actual - expected) <= tolerance
}

@(test)
spine_unconstrained_response_converges :: proc(t: ^testing.T) {
	model := Model {
		n = 1,
		x = make([dynamic]Compiled_Expr, 1),
		z = make([dynamic]Compiled_Expr, 1),
	}
	defer destroy_model(&model)
	model.x[0] = make_compiled_expr(1)
	model.z[0] = make_compiled_expr(1)

	problem := Problem {
		n         = 1,
		objective = make_compiled_expr(1),
	}
	defer destroy_problem(&problem)
	problem.objective.cos_coeff[0] = -1

	solution := spine_optimize(&model, &problem, 1.25)
	defer destroy_solution(&solution)

	testing.expect(t, spine_test_close(solution.thetas[0], 0, ACCEPT_TOL))
	testing.expect(t, spine_test_close(solution.optimum, -1, ACCEPT_TOL))
}

@(test)
spine_hessian_product_matches_gradient_difference :: proc(t: ^testing.T) {
	problem := Problem {
		n         = 2,
		objective = make_compiled_expr(2),
		ineq_cons = make([dynamic]Compiled_Expr, 1),
		eq_cons   = make([dynamic]Compiled_Expr, 1),
	}
	defer destroy_problem(&problem)
	problem.objective.sin_coeff[0] = 0.7
	problem.objective.cos_coeff[1] = -0.4
	problem.ineq_cons[0] = make_compiled_expr(2)
	problem.ineq_cons[0].constant = 0.5
	problem.ineq_cons[0].sin_coeff[0] = 0.3
	problem.ineq_cons[0].cos_coeff[1] = -0.2
	problem.eq_cons[0] = make_compiled_expr(2)
	problem.eq_cons[0].sin_coeff[0] = -0.25
	problem.eq_cons[0].cos_coeff[1] = 0.35

	thetas := [2]f64{0.2, -0.4}
	vector := [2]f64{0.6, -0.8}
	lamb := [1]f64{0.3}
	nu := [1]f64{0.1}
	pen := 2.0
	work := make_workspace(2)
	defer destroy_workspace(&work)

	gradient: [2]f64
	diagonal: [2]f64
	jacobian: [4]f64
	active: [2]bool
	structured_value := spine_evaluate(gradient[:], diagonal[:], jacobian[:], active[:], thetas[:], &problem, lamb[:], nu[:], pen, &work)
	reference_gradient: [2]f64
	reference_value := compute_aug_l(reference_gradient[:], thetas[:], &problem, lamb[:], nu[:], pen, &work)
	testing.expect(t, spine_test_close(structured_value, reference_value, 1e-12))
	for i in 0..<2 {
		testing.expect(t, spine_test_close(gradient[i], reference_gradient[i], 1e-12))
	}
	product: [2]f64
	spine_hessian_product(product[:], vector[:], diagonal[:], jacobian[:], active[:], pen, 0)

	epsilon := 1e-6
	plus := thetas
	minus := thetas
	for i in 0..<2 {
		plus[i] += epsilon * vector[i]
		minus[i] -= epsilon * vector[i]
	}
	gradient_plus: [2]f64
	gradient_minus: [2]f64
	_ = compute_aug_l(gradient_plus[:], plus[:], &problem, lamb[:], nu[:], pen, &work)
	_ = compute_aug_l(gradient_minus[:], minus[:], &problem, lamb[:], nu[:], pen, &work)
	for i in 0..<2 {
		finite_difference :=
			(gradient_plus[i] - gradient_minus[i]) / (2 * epsilon)
		testing.expect(t, spine_test_close(product[i], finite_difference, 1e-7))
	}
}

@(test)
direct_schur_matches_damped_newton_system :: proc(t: ^testing.T) {
	gradient := [3]f64{1.0, -2.0, 0.5}
	diagonal := [3]f64{2.0, 3.0, 4.0}
	jacobian := [6]f64 {
		1.0, 2.0, 0.0,
		-1.0, 0.0, 1.0,
	}
	active := [2]bool{true, true}
	pen := 2.0
	damping := 0.5
	work := make_schur_workspace(3, 2)
	defer destroy_schur_workspace(&work)

	direct_step: [3]f64
	testing.expect(
		t,
		spine_schur(
			direct_step[:],
			gradient[:],
			diagonal[:],
			jacobian[:],
			active[:],
			pen,
			damping,
			&work,
		),
	)
	product: [3]f64
	spine_hessian_product(
		product[:],
		direct_step[:],
		diagonal[:],
		jacobian[:],
		active[:],
		pen,
		damping,
	)
	for tick in 0..<3 {
		testing.expect(
			t,
			spine_test_close(product[tick], -gradient[tick], 1e-10),
		)
	}
}
