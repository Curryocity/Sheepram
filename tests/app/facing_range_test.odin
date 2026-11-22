package app_test

import "core:math"
import "core:strings"
import "core:testing"
import app "../../src/app"
import opt "../../src/optimizer"

@(test)
output_preserves_solved_facings_and_raw_turns :: proc(t: ^testing.T) {
	degrees := [?]f64{181.003, 359, 1, 1}
	for discrete in ([2]bool{false, true}) {
		solution := opt.Solution{thetas = make([dynamic]f64, len(degrees))}
		for angle, i in degrees do solution.thetas[i] = angle if discrete else angle*math.PI/180
		facings := app.solution_facings_degrees(&solution, discrete)
		for angle, i in degrees do testing.expect(t, math.abs(facings[i]-angle) < 1e-10)
		facing_list := app.format_angle_list(facings[:], false, ", ")
		turn_list := app.format_angle_list(facings[:], true, ", ")
		testing.expect_value(t, facing_list, "181.003, 359.000, 1.000")
		testing.expect_value(t, turn_list, "177.997, -358.000")
		delete(facing_list)
		delete(turn_list)
		delete(facings)
		opt.destroy_solution(&solution)
	}
}

@(test)
facing_midpoint_round_trips_and_old_saves_default_to_zero :: proc(t: ^testing.T) {
	tab := app.make_default_tab(601)
	defer app.destroy_tab(tab)
	before := app.build_tab_fingerprint(tab)
	defer delete(before)
	tab.env.facing_range_midpoint = 180
	after := app.build_tab_fingerprint(tab)
	defer delete(after)
	testing.expect(t, before != after)
	data, err := app.build_tab_json(tab)
	defer delete(data)
	defer delete(err)
	testing.expect_value(t, err, "")
	loaded := app.make_default_tab(602)
	defer app.destroy_tab(loaded)
	load_err := app.load_tab_from_json(loaded, data)
	defer delete(load_err)
	testing.expect_value(t, load_err, "")
	testing.expect_value(t, loaded.env.facing_range_midpoint, 180)
	material := app.make_optimizer_material(&loaded.env)
	defer app.destroy_optimizer_material(&material)
	testing.expect_value(t, material.facing_range_midpoint, 180)
	legacy, allocated := strings.replace_all(string(data), `"facingRangeMidpoint":180.0000000000000000,`, "")
	testing.expect(t, allocated)
	if !allocated do return
	defer delete(legacy)
	legacy_err := app.load_tab_from_json(loaded, transmute([]byte)legacy)
	defer delete(legacy_err)
	testing.expect_value(t, legacy_err, "")
	testing.expect_value(t, loaded.env.facing_range_midpoint, 0)
	invalid, _ := strings.replace_all(string(data), `"facingRangeMidpoint":180.0000000000000000`, `"facingRangeMidpoint":1e100`)
	defer delete(invalid)
	invalid_err := app.load_tab_from_json(loaded, transmute([]byte)invalid)
	defer delete(invalid_err)
	testing.expect(t, strings.contains(invalid_err, "Invalid field: facingRangeMidpoint"))
	testing.expect_value(t, loaded.env.facing_range_midpoint, 0)
}

@(test)
facing_and_turn_constraints_use_the_selected_range_across_solvers :: proc(t: ^testing.T) {
	midpoints := [3]f64{0, 180, 37.12345}
	for optimizer in ([3]app.Continuous_Optimizer{.BFGS, .Spine, .Pancake}) {
		for case_id in 0..<6 {
			midpoint := midpoints[case_id%3]
			for mode in 0..<3 {
				material := app.Optimizer_Material {
					minecraft_version = .V1_8_9 if case_id < 3 else .V1_21_3,
					facing_range_midpoint = midpoint,
					continuous_optimizer = optimizer,
					obj_type = .Z,
					maximize = true,
					seed = 179.995,
					discrete_search = mode != 0,
					cook = mode == 2,
					chefs = 2,
					movement_script = "initAirRange(0.1, 0.3) [wa wa] wa wa",
					cons_script = "F[1] = 179.995\nF[3] = 180.005\nT[2] = 0.01",
					x_origin_script = "T[2]",
					z_origin_script = "Vz[0]",
				}
				if midpoint == 0 do material.cons_script = "F[1] = 179.995\nF[3] = -180\nT[2] = -359.995"
				result := app.optimize(&material)
				testing.expect_value(t, result.error, "")
				testing.expect(t, result.solution != nil)
				if result.solution != nil {
					s := result.solution
					testing.expect(t, app.solution_is_finite(s))
					for angle in s.thetas {
						facing := angle if result.discrete else angle*180/math.PI
						tolerance := 0 if result.discrete else opt.CONTINUOUS_TOL
						testing.expect(t, facing >= midpoint-180-tolerance && facing < midpoint+180+tolerance)
					}
					for constraint in s.constraints do testing.expect(t, constraint.margin < 1e-5)
					testing.expect_value(t, s.thetas[1], s.thetas[2])
					expected_turn := -359.995 if midpoint == 0 else 0.01
					testing.expect(t, math.abs(result.x_origin-expected_turn) < 1e-5)
					vx, vz := s.xs[1]-s.xs[0], s.zs[1]-s.zs[0]
					speed := math.sqrt(vx*vx+vz*vz)
					testing.expect(t, speed >= 0.1-1e-12 && speed <= 0.3+1e-12)
				}
				app.destroy_optimizer_result(&result)
			}
		}
	}
}

@(test)
shifted_ranges_preserve_continuous_initial_velocity :: proc(t: ^testing.T) {
	for midpoint in ([3]f64{-360, 1800, -1800}) {
		for mode in 0..<3 {
			for version in ([2]app.Minecraft_Version{.V1_8_9, .V1_21_3}) {
				material := app.Optimizer_Material {
					minecraft_version = version,
					facing_range_midpoint = midpoint,
					continuous_optimizer = .Pancake,
					obj_type = .Z,
					maximize = true,
					discrete_search = mode != 0,
					cook = mode == 2,
					chefs = 2,
					movement_script = "initAirRange(0.1, 0.3) [wa wa.wd] wa",
					x_origin_script = "Vx[0]",
					z_origin_script = "Vz[0]",
				}
				result := app.optimize(&material)
				testing.expect_value(t, result.error, "")
				testing.expect(t, result.solution != nil)
				if result.solution != nil {
					s := result.solution
					for angle in s.thetas {
						facing := angle if result.discrete else angle*180/math.PI
						testing.expect(t, facing >= midpoint-180 && facing < midpoint+180)
					}
					speed := math.sqrt(s.xs[1]*s.xs[1]+s.zs[1]*s.zs[1])
					testing.expect(t, speed >= 0.1-1e-12 && speed <= 0.3+1e-12)
					testing.expect(t, math.abs(result.x_origin-s.xs[1]) < 1e-12)
					testing.expect(t, math.abs(result.z_origin-s.zs[1]) < 1e-12)
				}
				app.destroy_optimizer_result(&result)
			}
		}
	}
}

@(test)
regular_search_rejects_midpoints_outside_the_limit_before_solving :: proc(t: ^testing.T) {
	limit := opt.REGULAR_FACING_MIDPOINT_LIMIT
	for midpoint in ([2]f64{math.nextafter(-limit, -1e300), math.nextafter(limit, 1e300)}) {
		for discrete in ([2]bool{false, true}) {
			material := app.Optimizer_Material{facing_range_midpoint = midpoint, discrete_search = discrete, movement_script = "wa"}
			result := app.optimize(&material)
			testing.expect(t, result.solution == nil)
			testing.expect(t, strings.contains(result.error, "Regular angle search requires a yaw range midpoint between -1800 and 1800."))
			app.destroy_optimizer_result(&result)
		}
	}
}

@(test)
initial_guess_must_be_inside_the_selected_yaw_range_when_used :: proc(t: ^testing.T) {
	for optimizer in ([2]app.Continuous_Optimizer{.BFGS, .Spine}) {
		for midpoint in ([3]f64{0, 180, 1800}) {
			lower, upper := midpoint-180, midpoint+180
			for guess, i in ([6]f64{lower, upper-0.001, math.nextafter(lower, -1e300), upper, math.INF_F64, math.QNAN_F64}) {
				material := app.Optimizer_Material {
					continuous_optimizer = optimizer,
					facing_range_midpoint = midpoint,
					seed = guess,
					movement_script = "wa(2)",
					x_origin_script = "0",
					z_origin_script = "0",
				}
				result := app.optimize(&material)
				if i < 2 {
					testing.expect_value(t, result.error, "")
					testing.expect(t, result.solution != nil)
				} else {
					testing.expect(t, result.solution == nil)
					testing.expect(t, strings.contains(result.error, "Initial guess must be a finite yaw in ["))
				}
				app.destroy_optimizer_result(&result)
			}
		}
	}
	for optimizer in ([3]app.Continuous_Optimizer{.BFGS, .Spine, .Pancake}) {
		material := app.Optimizer_Material {
			continuous_optimizer = optimizer,
			facing_range_midpoint = 360,
			seed = -1,
			multistart_on = optimizer != .Pancake,
			seed_samples = 8,
			movement_script = "wa(2)",
			x_origin_script = "0",
			z_origin_script = "0",
		}
		result := app.optimize(&material)
		testing.expect_value(t, result.error, "")
		testing.expect(t, result.solution != nil)
		if material.multistart_on do testing.expect(t, result.winner_seed >= 180 && result.winner_seed < 540)
		app.destroy_optimizer_result(&result)
	}
}

@(test)
classic_stalled_boundary_guesses_do_not_produce_exploding_yaws :: proc(t: ^testing.T) {
	for seed in ([3]f64{-180, -179, 179.999}) {
		material := app.Optimizer_Material {
			continuous_optimizer = .BFGS,
			obj_type = .Custom,
			obj_script = "Z[n] - Z[m2]",
			seed = seed,
			movement_script = "initGnd(0.2819852266386473, 163.11353750482684) sj.w sa.wa(11) set(m, 2) set(m2, 8)",
			cons_script = "Z[m] - Z[0] < -7/16\nZ[m2] - Z[m] > -1 + bx\nX[m2+1] - X[m] > 1 + bx\nX[m] - X[0] < 8/16 - 0.0465540099908084\nT[1] < 9",
			x_origin_script = "X[0]",
			z_origin_script = "Z[0]",
		}
		result := app.optimize(&material)
		testing.expect_value(t, result.error, "")
		testing.expect(t, result.solution != nil)
		if result.solution != nil {
			testing.expect(t, app.solution_is_finite(result.solution))
			for angle in result.solution.thetas do testing.expect(t, math.abs(angle*180/math.PI) < 1000)
		}
		app.destroy_optimizer_result(&result)
	}
}
