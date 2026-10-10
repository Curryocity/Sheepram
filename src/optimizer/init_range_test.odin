package optimizer

import "core:math"
import "core:testing"

@(test)
compiled_initial_range_combines_two_rotators :: proc(t: ^testing.T) {
	ranges := [?][2]f64{{0.1, 0.3}, {0, 0}, {0.2, 0.2}, {0, 0.3}}
	for bounds in ranges {
		model := Model {
			n = 3,
			n_unique = 3,
			init_v_range = true,
			init_v_extra = (bounds[1]-bounds[0])/2,
			drag_x = make([dynamic]f64, 3),
			drag_z = make([dynamic]f64, 3),
			accel = make([dynamic]f64, 3),
			facing_map = make([dynamic]int, 3),
			angle_offset = make([dynamic]f64, 3),
		}
		copy(model.drag_x[:], []f64{0.5, 0.5, 0})
		copy(model.drag_z[:], []f64{0.5, 0.5, 0})
		copy(model.accel[:], []f64{bounds[0]/2+bounds[1]/2, 0.04, 0})
		copy(model.facing_map[:], []int{0, 2, 2})
		copy(model.angle_offset[:], []f64{0, 45, 0})
		compile_model(&model)
		work := make_workspace(model.n_unique)
		thetas := [?]f64{0, 0, 0.3}
		for a in 0..<16 {
			for b in 0..<16 {
				thetas[0] = f64(a)*math.PI/8
				thetas[1] = f64(b)*math.PI/8
				update_trig_cache(&work, thetas[:])
				vx := eval(model.vx[0], thetas[:], &work)
				vz := eval(model.vz[0], thetas[:], &work)
				speed := math.sqrt(vx*vx+vz*vz)
				testing.expect(t, speed >= bounds[0]-1e-12 && speed <= bounds[1]+1e-12)
				testing.expect(t, math.abs(eval(model.x[1], thetas[:], &work)-vx) < 1e-12)
				testing.expect(t, math.abs(eval(model.z[1], thetas[:], &work)-vz) < 1e-12)
				direction := thetas[2]+math.PI/4
				testing.expect(t, math.abs(eval(model.x[2], thetas[:], &work)-(1.5*vx+0.04*math.sin(direction))) < 1e-12)
				testing.expect(t, math.abs(eval(model.z[2], thetas[:], &work)-(1.5*vz+0.04*math.cos(direction))) < 1e-12)
			}
		}
		raw := make_raw_expr(model.n)
		raw.z_coeff[2] = -1
		problem := Problem{n = model.n_unique, objective = reduce_expr(raw, &model)}
		for solver in 0..<3 {
			solution: Solution
			switch solver {
			case 0: solution = optimize_1seed(&model, &problem, 0.3)
			case 1: solution = spine_optimize_1seed(&model, &problem, 0.3)
			case 2: solution = pancake_optimize(&model, &problem)
			}
			testing.expect(t, math.abs(solution.optimum+(1.5*bounds[1]+0.04)) < 1e-6)
			destroy_solution(&solution)
		}
		destroy_problem(&problem)
		destroy_raw_expr(&raw)
		destroy_workspace(&work)
		destroy_model(&model)
	}
}
