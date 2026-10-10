package app_test

import app "../../src/app"

import "core:math"
import "core:strings"
import "core:testing"

@(test)
range_initialization_works_across_continuous_and_discrete_solvers :: proc(t: ^testing.T) {
	scripts := [?]string {
		"initAirRange(0.1, 0.3) [wa.wa wa.wd] wa",
		"slip(0.8) initGndRange(0.1, 0.3) [sj.wa sa.wd(2)] w",
		"initAirRange(0, 0) [wa.wa wa.wd] wa",
		"initGndRange(0.2, 0.2) [w.wa w.wd] w",
	}
	bounds := [?][2]f64{{0.1, 0.3}, {0.1, 0.3}, {0, 0}, {0.2, 0.2}}
	optimizers := [?]app.Continuous_Optimizer{.BFGS, .Spine, .Pancake}
	for script, i in scripts {
		for optimizer in optimizers {
			for discrete in 0..<2 {
				for multistart in 0..<2 {
					material := app.Optimizer_Material {
						continuous_optimizer = optimizer,
						pancake_recovery = .BFGS,
						obj_type = .Custom,
						obj_script = "Z[n]+0.3*X[n]",
						maximize = true,
						seed = 30,
						multistart_on = multistart == 1,
						seed_samples = 8,
						discrete_search = discrete == 1,
						movement_script = script,
						x_origin_script = "Vx[0]",
						z_origin_script = "Vz[0]",
					}
					result := app.optimize(&material)
					testing.expect_value(t, result.error, "")
					testing.expect(t, result.solution != nil)
					if result.solution != nil {
						s := result.solution
						testing.expect_value(t, len(s.thetas), len(s.xs))
						testing.expect_value(t, len(s.thetas), len(s.zs))
						testing.expect_value(t, len(s.xs), 5 if i == 1 else 4)
						testing.expect_value(t, s.thetas[1], s.thetas[2])
						vx, vz := s.xs[1]-s.xs[0], s.zs[1]-s.zs[0]
						speed := math.sqrt(vx*vx+vz*vz)
						testing.expect(t, speed >= bounds[i][0]-1e-12 && speed <= bounds[i][1]+1e-12)
						expected_facing := math.atan2(vx, vz) if speed != 0 else 0
						facing := s.thetas[0]*math.PI/180 if discrete == 1 else s.thetas[0]
						testing.expect(t, math.abs(facing-expected_facing) < 1e-12)
						testing.expect(t, math.abs(result.x_origin-vx) < 1e-12)
						testing.expect(t, math.abs(result.z_origin-vz) < 1e-12)
						testing.expect(t, app.solution_is_finite(s))
					}
					if i == 0 && discrete == 1 {
						material.discrete_search = false
						continuous := app.optimize(&material)
						testing.expect_value(t, continuous.error, "")
						if continuous.solution != nil && result.solution != nil {
							testing.expect(t, math.abs(result.solution.xs[1]-continuous.solution.xs[1]) < 1e-14)
							testing.expect(t, math.abs(result.solution.zs[1]-continuous.solution.zs[1]) < 1e-14)
						}
						app.destroy_optimizer_result(&continuous)
					}
					app.destroy_optimizer_result(&result)
				}
			}
		}
	}
}

@(test)
range_initialization_rejects_initial_facing_in_app_expressions :: proc(t: ^testing.T) {
	for location in 0..<3 {
		material := app.Optimizer_Material {
			movement_script = "initAirRange(0.1, 0.3) wa(3)",
			obj_type = .Z,
			x_origin_script = "0",
			z_origin_script = "0",
		}
		if location == 0 do material.cons_script = "F[0] = 0"
		if location == 1 do material.x_origin_script = "T[0]"
		if location == 2 {
			material.obj_type = .Custom
			material.obj_script = "F[0]"
		}
		result := app.optimize(&material)
		testing.expect(t, strings.contains(result.error, "cannot be used with initial velocity ranges"))
		app.destroy_optimizer_result(&result)
	}
}

@(test)
range_initialization_supports_constraints_cooking_and_tightening :: proc(t: ^testing.T) {
	optimizers := [?]app.Continuous_Optimizer{.BFGS, .Spine, .Pancake}
	for optimizer in optimizers {
		for mode in 0..<3 {
			material := app.Optimizer_Material {
				continuous_optimizer = optimizer,
				obj_type = .Z,
				maximize = true,
				seed = 30,
				discrete_search = true,
				cook = mode == 1,
				chefs = 2,
				movement_script = "initAirRange(0.1, 0.3) [wa.wa wa.wd] [wa.wd wa.wa] wa",
				cons_script = "Vx[0] = 0.12\nF[2]-F[1] = 0",
				x_origin_script = "0",
				z_origin_script = "0",
			}
			if mode == 2 do material.cons_script = "X[n] > 0.02\nX[n] < 0.020000001"
			result := app.optimize(&material)
			testing.expect_value(t, result.error, "")
			testing.expect(t, result.solution != nil)
			if result.solution != nil {
				testing.expect_value(t, result.solution.thetas[1], result.solution.thetas[2])
				if mode != 2 do testing.expect(t, math.abs(result.solution.xs[1]-0.12) < 1e-5)
				if mode == 1 do testing.expect_value(t, result.chefs_completed, 2)
				if mode == 2 do testing.expect(t, result.tightening_retries > 0)
			}
			app.destroy_optimizer_result(&result)
		}
	}
}

@(test)
fixed_initialization_still_preserves_explicit_angle_in_discrete_search :: proc(t: ^testing.T) {
	material := app.Optimizer_Material {
		movement_script = "initAir(0.2, 30) [wa.wa wa.wd] wa",
		obj_type = .Z,
		discrete_search = true,
		x_origin_script = "0",
		z_origin_script = "0",
	}
	result := app.optimize(&material)
	defer app.destroy_optimizer_result(&result)
	testing.expect_value(t, result.error, "")
	testing.expect(t, result.solution != nil)
	if result.solution != nil {
		testing.expect(t, math.abs(result.solution.thetas[0]-30) < 1e-12)
		theta := f64(30)*math.PI/180
		testing.expect(t, math.abs(result.solution.xs[1]-0.2*math.sin(theta)) < 1e-12)
		testing.expect(t, math.abs(result.solution.zs[1]-0.2*math.cos(theta)) < 1e-12)
	}
}
