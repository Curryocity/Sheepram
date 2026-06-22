package dsl

import "core:fmt"
import "core:math"
import "core:strings"
import opt "../optimizer"

Model_State :: struct {
	speed: u8,
	slow: u8,
	slip: f64,
	ix_next: bool,
	iz_next: bool,

	ok: bool,
	err: string,

	has_init_v: bool,
	init_v: f64,
	init_airborne: bool,
	init_slip: f64,

	n: int,
	drag_x: [dynamic]f64,
	drag_z: [dynamic]f64,
	accel:  [dynamic]f64,
	angle_offset: [dynamic]f64,
	variables: map[string]f64,
}


destroy_moth_execution_state :: proc(state: ^Model_State) {
	delete(state.err)
	delete(state.drag_x)
	delete(state.drag_z)
	delete(state.accel)
	delete(state.angle_offset)
	for name in state.variables do delete(name)
	delete(state.variables)
	state^ = {}
}

add_moth_variables :: proc(
	state: ^Model_State,
	names, values: []string,
) -> string {
	if len(names) != len(values) {
		return strings.clone("Variable name/value size mismatch")
	}

	model := opt.Model{n = 1}
	parser := init_parser(&model)
	defer destroy(&parser)
	if err := add_variables(&parser, names, values); err != "" do return err

	if state.variables == nil do state.variables = make(map[string]f64)
	for raw_name in names {
		name := trim(raw_name)
		if name == "" do continue
		value, found := parser.var_map[name]
		if !found do continue
		if old_name, exists := map_key(state.variables, name); exists {
			state.variables[old_name] = value
		} else {
			state.variables[strings.clone(name)] = value
		}
	}
	return ""
}

set_model_error :: proc(state: ^Model_State, message: string) {
	if !state.ok do return
	state.ok = false
	state.err = strings.clone(message)
}

moth_to_model :: proc(state: ^Model_State, code: []Arg) {
	state.slip = 0.6
	state.ok = true
	state.n = 1
    append(&state.drag_x, 0)
    append(&state.drag_z, 0)
    append(&state.accel, 0)
    append(&state.angle_offset, 0)

	exe_code(state, code)

	if !state.has_init_v {
		set_model_error(state, "Error: initial velocity missing")
		return
	}

	state.accel[0] = state.init_v
	if state.init_airborne {
		state.drag_x[0] = 0.91
		state.drag_z[0] = 0.91
	} else {
		state.drag_x[0] = state.init_slip * 0.91
		state.drag_z[0] = state.init_slip * 0.91
	}

	// The optimizer stores the terminal position after the final movement tick.
	// Its drag/accel/offset values are unused, but the arrays share model.n.
	append(&state.drag_x, 0)
	append(&state.drag_z, 0)
	append(&state.accel, 0)
	append(&state.angle_offset, 0)
}

exe_code :: proc(state: ^Model_State, code: []Arg) {
	if !state.ok do return

	for ins in code {
		#partial switch ins.type {
		case .MoveCall:
			mf := ins.mvfunc
			duration := mf.t
			if mf.t_variable != "" {
				duration_value, found := state.variables[mf.t_variable]
				duration_rounded := math.round(duration_value)
				if !found ||
				   duration_value != duration_rounded ||
				   duration_rounded <= 0 {
					set_model_error(
						state,
						fmt.tprintf(
							"Error: duration in %s(...) must be a defined positive whole-number global variable",
							mf.name,
						),
					)
					return
				}
				duration = int(duration_rounded)
			}

			drag := f64(0.91)
			base_accel: f64

			if mf.airborne {
				base_accel = 0.02
			} else {
				drag *= state.slip
				base_accel = 0.1
				base_accel *= 0.16277136 / (drag * drag * drag)

				if state.speed > 0 do base_accel *= 1+0.2*f64(state.speed)
				if state.slow > 0 do base_accel *= 1-0.15*f64(state.slow)
				if base_accel < 0 do base_accel = 0
			}

			

			if mf.sprint do base_accel *= 1.3


			mul := f64(0.98)

			if mf.sneak do mul *= 0.3
			if mf.stop do mul = 0

			forward := f64(mf.w) * mul
			strafe := f64(mf.a) * mul

			dist2 := forward*forward+strafe*strafe
			if dist2 > 1 {
				forward /= math.sqrt(dist2)
				strafe /= math.sqrt(dist2)
			}

			forward *= base_accel
			strafe *= base_accel

			if mf.sprint && mf.jump do forward += 0.2

			final_accel := math.sqrt(forward*forward+strafe*strafe)
			angle_offset := math.atan2(-strafe, forward)*180/math.PI

			for i in 0..<duration {
				if i == 0 && state.ix_next {
					append(&state.drag_x, 0)
					state.ix_next = false
				} else {
					append(&state.drag_x, drag)
				}

				if i == 0 && state.iz_next {
					append(&state.drag_z, 0)
					state.iz_next = false
				} else {
					append(&state.drag_z, drag)
				}

				append(&state.accel, final_accel)
				append(&state.angle_offset, angle_offset)
			}

			state.n += duration

		case .Call:
			exe_model_cmd(state, ins.expr)
			if !state.ok do return
		case:
			set_model_error(state, "Error: expected a command or movement")
			return
		}
	}
}

expect_moth_args :: proc(
	cmd: ^Command,
	min_count, max_count: int,
	allow_code: bool,
) -> (string, bool) {
	if cmd == nil do return "Error: null command", false

	count := len(cmd.args)
	if count < min_count || count > max_count {
		if min_count == max_count {
			return fmt.tprintf(
				"Error: %s expects %d argument(s), got %d",
				cmd.name,
				min_count,
				count,
			), false
		}
		return fmt.tprintf(
			"Error: %s expects %d to %d arguments, got %d",
			cmd.name,
			min_count,
			max_count,
			count,
		), false
	}

	if !allow_code && len(cmd.code) != 0 {
		return fmt.tprintf("Error: %s does not accept a code block", cmd.name), false
	}
	return "", true
}

eval_moth_constant :: proc(state: ^Model_State, arg: Arg) -> (f64, bool) {
	#partial switch arg.type {
	case .Number:
		return arg.value, true
	case .Variable:
		value, found := state.variables[arg.text]
		return value, found
	case .Call:
		if arg.expr == nil || len(arg.expr.args) != 2 do return 0, false
		lhs, lhs_ok := eval_moth_constant(state, arg.expr.args[0])
		rhs, rhs_ok := eval_moth_constant(state, arg.expr.args[1])
		if !lhs_ok || !rhs_ok do return 0, false
		#partial switch arg.expr.type {
		case .Plus:
			return lhs+rhs, true
		case .Minus:
			return lhs-rhs, true
		case .Mul:
			return lhs*rhs, true
		case .Div:
			if rhs == 0 do return 0, false
			return lhs/rhs, true
		case:
			return 0, false
		}
	case:
		return 0, false
	}
}

eval_moth_number :: proc(
	state: ^Model_State,
	arg: Arg,
	description: string,
) -> (f64, string) {
	value, ok := eval_moth_constant(state, arg)
	if !ok {
		return 0, fmt.tprintf(
			"Error: %s must be a number or defined global-variable expression",
			description,
		)
	}
	if math.is_nan(value) || math.is_inf(value, 0) {
		return 0, fmt.tprintf("Error: %s must be finite", description)
	}
	return value, ""
}

eval_u8 :: proc(state: ^Model_State, arg: Arg, command_name: string) -> (u8, string) {
	value, err := eval_moth_number(
		state,
		arg,
		fmt.tprintf("%s(...) argument", command_name),
	)
	if err != "" do return 0, err

	rounded := math.round(value)
	if value != rounded || rounded < 0 || rounded > 255 {
		return 0, fmt.tprintf(
			"Error: %s(...) argument must be a whole number from 0 to 255",
			command_name,
		)
	}
	return u8(rounded), ""
}

exe_model_cmd :: proc(state: ^Model_State, cmd: ^Command) {
	if !state.ok do return
	if cmd == nil {
		set_model_error(state, "Error: null command")
		return
	}

	switch cmd.type {
	case .SetInitGroundVel, .SetInitAirVel:
		if state.has_init_v {
			set_model_error(state, "init command can only be called once")
			return
		}

		if message, ok := expect_moth_args(cmd, 1, 1, false); !ok {
			set_model_error(state, message)
			return
		}

		init_v, err := eval_moth_number(state, cmd.args[0], "initGnd/Air(...) argument")
		if err != "" {
			set_model_error(state, err)
			return
		}
		if init_v < 0 {
			set_model_error(state, "Error: init velocity cannot be negative")
			return
		}

		state.init_v = init_v
		state.has_init_v = true
		state.init_slip = state.slip

		if cmd.type == .SetInitAirVel do state.init_airborne = true

		return

	case .SetSlip:
		if message, ok := expect_moth_args(cmd, 1, 1, false); !ok {
			set_model_error(state, message)
			return
		}
		slip, err := eval_moth_number(state, cmd.args[0], "slip(...) argument")
		if err != "" {
			set_model_error(state, err)
			return
		}
		if slip < 0 {
			set_model_error(state, "Error: slip(...) argument cannot be negative")
			return
		}
		state.slip = slip
		return

	case .SetSpeed:
		if message, ok := expect_moth_args(cmd, 1, 1, false); !ok {
			set_model_error(state, message)
			return
		}
		level, err := eval_u8(state, cmd.args[0], "speed")
		if err != "" {
			set_model_error(state, err)
			return
		}
		state.speed = level
		return

	case .SetSlow:
		if message, ok := expect_moth_args(cmd, 1, 1, false); !ok {
			set_model_error(state, message)
			return
		}
		level, err := eval_u8(state, cmd.args[0], "slow")
		if err != "" {
			set_model_error(state, err)
			return
		}
		state.slow = level
		return

	case .ForceInertiaX:
		if message, ok := expect_moth_args(cmd, 0, 0, false); !ok {
			set_model_error(state, message)
			return
		}
		state.ix_next = true
		return

	case .ForceInertiaZ:
		if message, ok := expect_moth_args(cmd, 0, 0, false); !ok {
			set_model_error(state, message)
			return
		}
		state.iz_next = true
		return

	case .Move:
		if message, ok := expect_moth_args(cmd, 2, 3, false); !ok {
			set_model_error(state, message)
			return
		}

		drag, drag_err := eval_moth_number(state, cmd.args[0], "mv(...) drag")
		if drag_err != "" {
			set_model_error(state, drag_err)
			return
		}
		accel, accel_err := eval_moth_number(state, cmd.args[1], "mv(...) acceleration")
		if accel_err != "" {
			set_model_error(state, accel_err)
			return
		}
		duration := 1
		if len(cmd.args) == 3 {
			duration_value, duration_err := eval_moth_number(
				state,
				cmd.args[2],
				"mv(...) duration",
			)
			if duration_err != "" {
				set_model_error(state, duration_err)
				return
			}

			duration_rounded := math.round(duration_value)
			if duration_value != duration_rounded || duration_rounded <= 0 {
				set_model_error(
					state,
					"Error: mv(...) duration must be a positive whole number",
				)
				return
			}
			duration = int(duration_rounded)
		}

		for i in 0..<duration {
			drag_x := drag
			drag_z := drag
			if i == 0 && state.ix_next {
				drag_x = 0
				state.ix_next = false
			}
			if i == 0 && state.iz_next {
				drag_z = 0
				state.iz_next = false
			}

			append(&state.drag_x, drag_x)
			append(&state.drag_z, drag_z)
			append(&state.accel, accel)
			append(&state.angle_offset, 0)
		}
		state.n += duration
		return

	case .Loop:
		if message, ok := expect_moth_args(cmd, 1, 1, true); !ok {
			set_model_error(state, message)
			return
		}
		if len(cmd.code) == 0 {
			set_model_error(state, "Error: loop requires a non-empty code block")
			return
		}

		count_value, err := eval_moth_number(state, cmd.args[0], "loop count")
		if err != "" {
			set_model_error(state, err)
			return
		}
		rounded := math.round(count_value)
		if count_value != rounded || rounded < 0 {
			set_model_error(state, "Error: loop count must be a non-negative whole number")
			return
		}

		for _ in 0..<int(rounded) {
			exe_code(state, cmd.code[:])
			if !state.ok do return
		}
		return

	case .Plus, .Minus, .Mul, .Div:
		set_model_error(state, "Error: arithmetic expression cannot be a top-level command")
		return

	case .Invalid:
		set_model_error(state, "Error: invalid command")
		return
	}
}
