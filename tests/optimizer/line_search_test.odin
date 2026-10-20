package optimizer_test

import "core:testing"
import opt "../../src/optimizer"

@(test)
exhausted_line_search_does_not_return_an_unverified_step :: proc(t: ^testing.T) {
	problem := opt.Problem{n = 1, objective = opt.make_compiled_expr(1)}
	defer opt.destroy_problem(&problem)
	problem.objective.sin_coeff[0] = -1
	work := opt.make_workspace(1)
	defer opt.destroy_workspace(&work)
	thetas := [1]f64{0}
	step := [1]f64{1e300}
	gradient, trial: [1]f64
	value := opt.compute_aug_l(gradient[:], thetas[:], &problem, nil, nil, 1, &work)
	derivative := gradient[0]*step[0]
	alpha := opt.line_search(thetas[:], &problem, nil, nil, 1, step[:], value, derivative, &work, gradient[:], trial[:])
	testing.expect_value(t, alpha, 0)
	testing.expect_value(t, thetas[0], 0)
}
