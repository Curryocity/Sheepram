package dsl

import "core:strings"
import "core:testing"
import opt "../optimizer"

@(test)
range_initialization_rejects_initial_facing_and_turn :: proc(t: ^testing.T) {
	model := opt.Model{n = 4, init_v_range = true}
	parser := init_parser(&model)
	defer destroy(&parser)
	set_variable(&parser, "zero", 0)
	texts := [?]string{"F[0]", "T[0]", "F[n-n]", "T[zero]", "F[1]+F[0]", "0*F[0]"}
	for text in texts {
		expr, err := parse_expr(&parser, text)
		testing.expect(t, strings.contains(err, "cannot be used with initial velocity ranges"))
		opt.destroy_raw_expr(&expr)
		delete(err)
	}
	constraints, err := parse_multi_constraints(&parser, "F[0] = 30")
	testing.expect(t, strings.contains(err, "F[0] cannot be used with initial velocity ranges"))
	destroy_constraints(&constraints)
	delete(err)
}

@(test)
range_initialization_keeps_velocity_and_movement_expressions :: proc(t: ^testing.T) {
	model := opt.Model {
		n = 4,
		init_v_range = true,
		x = make([dynamic]opt.Compiled_Expr, 4),
		z = make([dynamic]opt.Compiled_Expr, 4),
	}
	defer opt.destroy_model(&model)
	parser := init_parser(&model)
	defer destroy(&parser)
	texts := [?]string{"Vx[0]", "Vz[0]", "F[1]", "T[1]", "X[0]", "Z[n]"}
	for text in texts {
		expr, err := parse_expr(&parser, text)
		testing.expect_value(t, err, "")
		opt.destroy_raw_expr(&expr)
		delete(err)
	}
}

@(test)
fixed_initialization_keeps_initial_facing_and_turn :: proc(t: ^testing.T) {
	model := opt.Model{n = 4}
	parser := init_parser(&model)
	defer destroy(&parser)
	facing, facing_err := parse_expr(&parser, "F[0]")
	defer opt.destroy_raw_expr(&facing)
	defer delete(facing_err)
	testing.expect_value(t, facing_err, "")
	if facing_err == "" do testing.expect_value(t, facing.f_coeff[0], 1.0)
	turn, turn_err := parse_expr(&parser, "T[0]")
	defer opt.destroy_raw_expr(&turn)
	defer delete(turn_err)
	testing.expect_value(t, turn_err, "")
	if turn_err == "" {
		testing.expect_value(t, turn.f_coeff[0], -1.0)
		testing.expect_value(t, turn.f_coeff[1], 1.0)
	}
}
