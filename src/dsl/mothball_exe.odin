package dsl

import "core:fmt"
import "core:math"
import "core:strings"

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
	n: int,
	drag_x: [dynamic]f64,
	drag_z: [dynamic]f64,
	accel:  [dynamic]f64,
	angle_offset: [dynamic]f64,
}

init_moth_execution_state :: proc() -> Model_State {
	return Model_State {
		slip = 0.6,
		ok = true,
	}
}

destroy_moth_execution_state :: proc(state: ^Model_State) {
	delete(state.err)
	delete(state.drag_x)
	delete(state.drag_z)
	delete(state.accel)
	delete(state.angle_offset)
	state^ = {}
}

set_model_error :: proc(state: ^Model_State, message: string) {
	if !state.ok do return
	state.ok = false
	state.err = strings.clone(message)
}

moth_to_model :: proc(state: ^Model_State, code: []Arg) {
	if !state.ok do return

	for ins in code {
		#partial switch ins.type {
		case .MoveCall:
			mf := ins.mvfunc

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

			for i in 0..<mf.t {
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

			state.n += mf.t

		case .Call:
			exe_model_cmd(state, ins.expr)
			if !state.ok do return
		case:
			set_model_error(state, "Error: expected a command or movement")
			return
		}
	}

	if !state.has_init_v {
		set_model_error(state, "Error: init(...) is required")
		return
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

eval_moth_number :: proc(arg: Arg, description: string) -> (f64, string) {
	value, ok := eval_constant(arg)
	if !ok {
		return 0, fmt.tprintf("Error: %s must be a constant number", description)
	}
	if math.is_nan(value) || math.is_inf(value, 0) {
		return 0, fmt.tprintf("Error: %s must be finite", description)
	}
	return value, ""
}

eval_u8 :: proc(arg: Arg, command_name: string) -> (u8, string) {
	value, err := eval_moth_number(arg, fmt.tprintf("%s(...) argument", command_name))
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
	case .SetInitVel:
		if state.has_init_v {
			set_model_error(state, "init(...) can only be called once")
			return
		}

		if message, ok := expect_moth_args(cmd, 1, 1, false); !ok {
			set_model_error(state, message)
			return
		}

		init_v, err := eval_moth_number(cmd.args[0], "init(...) argument")
		if err != "" {
			set_model_error(state, err)
			return
		}
		if init_v < 0 {
			set_model_error(state, "Error: init(...) argument cannot be negative")
			return
		}
		state.init_v = init_v
		state.has_init_v = true

		return

	case .SetSlip:
		if message, ok := expect_moth_args(cmd, 1, 1, false); !ok {
			set_model_error(state, message)
			return
		}
		slip, err := eval_moth_number(cmd.args[0], "slip(...) argument")
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
		level, err := eval_u8(cmd.args[0], "speed")
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
		level, err := eval_u8(cmd.args[0], "slow")
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

	case .Loop:
		if message, ok := expect_moth_args(cmd, 1, 1, true); !ok {
			set_model_error(state, message)
			return
		}
		if len(cmd.code) == 0 {
			set_model_error(state, "Error: loop requires a non-empty code block")
			return
		}

		count_value, err := eval_moth_number(cmd.args[0], "loop count")
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
			moth_to_model(state, cmd.code[:])
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
