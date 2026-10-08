package app

import "core:math"
import "core:testing"

@(test)
continuous_results_report_shared_facings_by_tick :: proc(t: ^testing.T) {
	optimizers := [?]Continuous_Optimizer{.BFGS, .Spine, .Pancake}
	for optimizer in optimizers {
		material := Optimizer_Material {
			continuous_optimizer = optimizer,
			pancake_recovery = .BFGS,
			obj_type = .Z,
			maximize = true,
			seed = 30,
			movement_script = "initAir(0, 0) [wa.wa wa.wd] w",
			cons_script = "F[2] = 20\nF[2] - F[1] = 0",
			x_origin_script = "F[1]",
			z_origin_script = "F[2]",
		}
		result := optimize(&material)
		testing.expect_value(t, result.error, "")
		if result.solution != nil {
			solution := result.solution
			testing.expect_value(t, len(solution.thetas), len(solution.xs))
			testing.expect_value(t, len(solution.thetas), len(solution.zs))
			testing.expect(t, math.abs(solution.thetas[0]) < 1e-6)
			testing.expect(t, math.abs(solution.thetas[1]*180/math.PI-20) < 1e-5)
			testing.expect_value(t, solution.thetas[1], solution.thetas[2])
			testing.expect(t, math.abs(result.x_origin-20) < 1e-5)
			testing.expect(t, math.abs(result.z_origin-20) < 1e-5)
			testing.expect_value(t, len(solution.constraints), 2)
			for constraint in solution.constraints do testing.expect(t, constraint.margin < 1e-5)
		}
		destroy_optimizer_result(&result)
	}
}
