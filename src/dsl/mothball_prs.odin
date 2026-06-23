package dsl

import "core:fmt"
import "core:math"

ParserState :: struct {
	lex:     Lexer,
	ok:      bool,
	err_msg: string,
}

MoveFunc :: struct {
	name:      string,
	sprint:    bool,
	sneak:     bool,
	jump:      bool,
	airborne:  bool,
	stop:      bool,
	w:         f32,
	a:         f32,
	t:         int,
	t_variable:string,
}

CmdType :: enum {
	Plus, Minus, Mul, Div,

	MarkX, MarkZ, MarkVx, MarkVz, MarkF, MarkTurn,

	SetInitGroundVel, SetInitAirVel,
	ForceInertiaX, ForceInertiaZ,

	SetSlip, SetSpeed, SetSlow,

	Move,

	Loop,

	Invalid,
}

Command :: struct {
	type: CmdType,
	name: string,
	args: [dynamic]Arg,
	code: [dynamic]Arg,
}

ArgType :: enum {
	Number,
	Text,
	Variable,
	Call,
	MoveCall,
}

Arg :: struct {
	type:   ArgType,
	value:  f64,
	text:   string,
	expr:   ^Command,
	mvfunc: MoveFunc,
}

fail_parse :: proc(prs: ^ParserState, message: string) {
	if !prs.ok do return
	prs.ok = false
	prs.err_msg = message
}

token_message :: proc(token: Token) -> string {
	if token.type == .End do return "end of input"
	return token.text
}

destroy_arg :: proc(arg: ^Arg) {
	if arg.type == .Call && arg.expr != nil {
		for &child in arg.expr.args do destroy_arg(&child)
		for &child in arg.expr.code do destroy_arg(&child)
		delete(arg.expr.args)
		delete(arg.expr.code)
		free(arg.expr)
	}
	arg^ = {}
}

destroy_moth_code :: proc(code: ^[dynamic]Arg) {
	for &arg in code do destroy_arg(&arg)
	delete(code^)
	code^ = nil
}

make_call :: proc(cmd_type: CmdType, name: string) -> ^Command {
	cmd := new(Command)
	cmd.type = cmd_type
	cmd.name = name
	return cmd
}

is_call :: proc(arg: ^Arg) -> bool {
	return arg.type == .Call && arg.expr != nil
}

// Parses a Mothball movement script into top-level commands and movements.
// The caller owns code and must eventually call destroy_moth_code.
parse_mothball :: proc(input: string) -> ([dynamic]Arg, string) {
	prs := ParserState {
		lex = Lexer{data = input},
		ok = true,
	}
	code: [dynamic]Arg

	for lexer_peek(&prs.lex).type != .End {
		arg := parse_moth_arg(&prs, 0)
		if !prs.ok {
			destroy_arg(&arg)
			destroy_moth_code(&code)
			return nil, fmt.tprintf("%s\n", prs.err_msg)
		}
		append(&code, arg)
	}

	return code, ""
}

parse_moth_arg :: proc(prs: ^ParserState, min_bp: int) -> Arg {
	if !prs.ok do return {}

	prefix := lexer_next(&prs.lex)
	lhs: Arg

	#partial switch prefix.type {
	case .Number:
		lhs = parse_moth_number(prs, prefix)
	case .Text:
		lhs = Arg{type = .Text, text = prefix.text}
	case .Identifier:
		lhs = parse_moth_identifier(prs, prefix)
	case .Operator:
		if prefix.text != "-" {
			fail_parse(
				prs,
				fmt.tprintf("Error: unexpected operator '%s'", token_message(prefix)),
			)
			return {}
		}
		rhs := parse_moth_arg(prs, 30)
		if !prs.ok do return {}
		lhs = combine(
			prs,
			Arg{type = .Number, value = -1},
			rhs,
			Token{type = .Operator, text = "*"},
		)
	case .L_Paren:
		lhs = parse_moth_arg(prs, 0)
		if !prs.ok do return {}
		close := lexer_next(&prs.lex)
		if close.type != .R_Paren {
			destroy_arg(&lhs)
			fail_parse(prs, "Error: missing ')' to close grouped expression")
			return {}
		}
	case .Invalid:
		fail_parse(prs, fmt.tprintf("Error: %s", prefix.text))
		return {}
	case:
		fail_parse(
			prs,
			fmt.tprintf("Error: unexpected token '%s'", token_message(prefix)),
		)
		return {}
	}
	if !prs.ok do return {}

	if !moth_can_continue_expr(lhs) do return lhs

	for {
		operator := lexer_peek(&prs.lex)
		if operator.type != .Operator do break

		bp, bp_err := get_binding_power(operator)
		if bp_err != "" {
			destroy_arg(&lhs)
			fail_parse(prs, bp_err)
			return {}
		}
		if bp.left < min_bp do break
		lexer_next(&prs.lex)

		rhs := parse_moth_arg(prs, bp.right)
		if !prs.ok {
			destroy_arg(&lhs)
			return {}
		}
		lhs = combine(prs, lhs, rhs, operator)
		if !prs.ok do return {}
	}

	return lhs
}

moth_can_continue_expr :: proc(arg: Arg) -> bool {
	#partial switch arg.type {
	case .Number, .Variable:
		return true
	case .Call:
		if arg.expr == nil do return false
		#partial switch arg.expr.type {
		case .Plus, .Minus, .Mul, .Div:
			return true
		case:
			return false
		}
	case:
		return false
	}
}

parse_moth_number :: proc(prs: ^ParserState, token: Token) -> Arg {
	if !prs.ok do return {}
	value, err := get_token_value(token)
	if err != "" {
		fail_parse(prs, err)
		return {}
	}
	return Arg{type = .Number, value = value}
}

parse_moth_identifier :: proc(prs: ^ParserState, token: Token) -> Arg {
	if !prs.ok do return {}

	mf, is_mf := check_move_func(token.text)
	if is_mf do return parse_move_func(prs, &mf, token)

	cmd_type := get_command_type(token.text)
	if cmd_type == .Invalid {
		next_type := lexer_peek(&prs.lex).type
		if next_type == .L_Paren || next_type == .L_Brace {
			fail_parse(prs, fmt.tprintf("Error: unknown command '%s'", token.text))
			return {}
		}
		return Arg{type = .Variable, text = token.text}
	}

	cmd := make_call(cmd_type, token.text)

	paren: if lexer_peek(&prs.lex).type == .L_Paren {
		lexer_next(&prs.lex)
		if lexer_peek(&prs.lex).type == .R_Paren {
			lexer_next(&prs.lex)
			break paren
		}

		for {
			arg := parse_moth_arg(prs, 0)
			if !prs.ok {
				destroy_arg(&arg)
				call := Arg{type = .Call, expr = cmd}
				destroy_arg(&call)
				return {}
			}
			append(&cmd.args, arg)

			next := lexer_peek(&prs.lex)
			if next.type == .Comma {
				lexer_next(&prs.lex)
			} else if next.type == .R_Paren {
				lexer_next(&prs.lex)
				break
			} else {
				call := Arg{type = .Call, expr = cmd}
				destroy_arg(&call)
				fail_parse(
					prs,
					fmt.tprintf(
						"Error: expected ',' or ')' in %s(...), got '%s'",
						token.text,
						token_message(next),
					),
				)
				return {}
			}
		}
	}

	if lexer_peek(&prs.lex).type == .L_Brace {
		lexer_next(&prs.lex)
		if lexer_peek(&prs.lex).type == .R_Brace {
			call := Arg{type = .Call, expr = cmd}
			destroy_arg(&call)
			fail_parse(prs, "Error: {...} cannot be empty")
			return {}
		}

		for {
			inner := parse_moth_arg(prs, 0)
			if !prs.ok {
				destroy_arg(&inner)
				call := Arg{type = .Call, expr = cmd}
				destroy_arg(&call)
				return {}
			}
			if inner.type != .Call && inner.type != .MoveCall {
				destroy_arg(&inner)
				call := Arg{type = .Call, expr = cmd}
				destroy_arg(&call)
				fail_parse(prs, "Error: code block can only contain commands or movements")
				return {}
			}
			append(&cmd.code, inner)

			next := lexer_peek(&prs.lex)
			if next.type == .R_Brace {
				lexer_next(&prs.lex)
				break
			}
			if next.type == .End {
				call := Arg{type = .Call, expr = cmd}
				destroy_arg(&call)
				fail_parse(prs, "Error: missing '}' to close code block")
				return {}
			}
		}
	}

	return Arg{type = .Call, expr = cmd}
}

get_command_type :: proc(name: string) -> CmdType {
	switch name {
	case "slip":
		return .SetSlip
	case "speed":
		return .SetSpeed
	case "slow", "slowness":
		return .SetSlow
	case "ix":
		return .ForceInertiaX
	case "iz":
		return .ForceInertiaZ
	case "mv":
		return .Move
	case "r", "loop", "repeat":
		return .Loop
	case "initGnd":
		return .SetInitGroundVel
	case "initAir":
		return .SetInitAirVel
	case "X":
		return .MarkX
	case "Z":
		return .MarkZ
	case "Vx":
		return .MarkVx
	case "Vz":
		return .MarkVz
	case "F":
		return .MarkF
	case "T":
		return .MarkTurn
	case:
		return .Invalid
	}
}

check_move_func :: proc(name: string) -> (MoveFunc, bool) {
	mf := MoveFunc{name = name}
	base := name

	if len(base) > 0 && base[len(base)-1] == 'a' {
		mf.airborne = true
		base = base[:len(base)-1]
	} else if len(base) > 0 && base[len(base)-1] == 'j' {
		mf.jump = true
		base = base[:len(base)-1]
	}

	switch base {
	case "w":
	case "s":
		mf.sprint = true
	case "sn":
		mf.sneak = true
	case "sns":
		mf.sneak = true
		mf.sprint = true
	case "st":
		mf.stop = true
	case:
		return mf, false
	}

	return mf, true
}

wasd_to_vec :: proc(input: string) -> (w, a: f32, ok: bool) {
	if len(input) == 0 do return 0, 0, false

	for ch in input {
		switch ch {
		case 'w':
			w += 1
		case 's':
			w -= 1
		case 'a':
			a += 1
		case 'd':
			a -= 1
		case:
			return 0, 0, false
		}
	}

	if math.abs(w) > 1 || math.abs(a) > 1 do return 0, 0, false
	return w, a, w != 0 || a != 0
}

eval_constant :: proc(arg: Arg) -> (f64, bool) {
	#partial switch arg.type {
	case .Number:
		return arg.value, true
	case .Call:
		if arg.expr == nil || len(arg.expr.args) != 2 do return 0, false
		lhs, lhs_ok := eval_constant(arg.expr.args[0])
		rhs, rhs_ok := eval_constant(arg.expr.args[1])
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

parse_move_func :: proc(prs: ^ParserState, mf: ^MoveFunc, token: Token) -> Arg {
	if lexer_peek(&prs.lex).type == .Dot {
		if mf.stop {
			fail_parse(prs, "Error: stop movement functions cannot have appended inputs")
			return {}
		}
		lexer_next(&prs.lex)

		input_token := lexer_next(&prs.lex)
		if input_token.type != .Identifier {
			fail_parse(
				prs,
				fmt.tprintf(
					"Error: expected a movement input after '.', got '%s'",
					token_message(input_token),
				),
			)
			return {}
		}

		w, a, ok := wasd_to_vec(input_token.text)
		if !ok {
			fail_parse(prs, fmt.tprintf("Error: invalid movement input '%s'", input_token.text))
			return {}
		}
		mf.w, mf.a = w, a
	} else if !mf.stop {
		mf.w = 1
	}

	paren: if lexer_peek(&prs.lex).type == .L_Paren {
		lexer_next(&prs.lex)
		duration_arg := parse_moth_arg(prs, 0)
		if !prs.ok do return {}
		duration, duration_ok := eval_constant(duration_arg)
		if !duration_ok {
			if duration_arg.type != .Variable {
				destroy_arg(&duration_arg)
				fail_parse(
					prs,
					fmt.tprintf(
						"Error: duration in %s(...) must be a number or global variable",
						token.text,
					),
				)
				return {}
			}
			mf.t_variable = duration_arg.text
		} else {
			rounded := math.round(duration)
			if math.abs(duration-rounded) >= 1e-15 || rounded <= 0 {
				destroy_arg(&duration_arg)
				fail_parse(
					prs,
					fmt.tprintf(
						"Error: duration in %s(...) must be a positive whole number",
						token.text,
					),
				)
				return {}
			}
			mf.t = int(rounded)
		}
		destroy_arg(&duration_arg)

		close := lexer_next(&prs.lex)
		if close.type != .R_Paren {
			fail_parse(
				prs,
				fmt.tprintf(
					"Error: %s(...) accepts only a duration; expected ')', got '%s'",
					token.text,
					token_message(close),
				),
			)
			return {}
		}
	} else {
		mf.t = 1
	}

	return Arg{type = .MoveCall, mvfunc = mf^}
}

combine :: proc(prs: ^ParserState, lhs, rhs: Arg, operator: Token) -> Arg {
	if !prs.ok {
		lhs_owned := lhs
		rhs_owned := rhs
		destroy_arg(&lhs_owned)
		destroy_arg(&rhs_owned)
		return {}
	}

	if lhs.type == .Number && rhs.type == .Number {
		switch operator.text {
		case "+":
			return Arg{type = .Number, value = lhs.value+rhs.value}
		case "-":
			return Arg{type = .Number, value = lhs.value-rhs.value}
		case "*":
			return Arg{type = .Number, value = lhs.value*rhs.value}
		case "/":
			if rhs.value == 0 {
				fail_parse(prs, "Error: division by zero")
				return {}
			}
			return Arg{type = .Number, value = lhs.value/rhs.value}
		}
	}

	cmd_type: CmdType
	switch operator.text {
	case "+":
		cmd_type = .Plus
	case "-":
		cmd_type = .Minus
	case "*":
		cmd_type = .Mul
	case "/":
		cmd_type = .Div
	case:
		lhs_owned := lhs
		rhs_owned := rhs
		destroy_arg(&lhs_owned)
		destroy_arg(&rhs_owned)
		fail_parse(prs, fmt.tprintf("Error: unsupported operator '%s'", operator.text))
		return {}
	}

	cmd := make_call(cmd_type, operator.text)
	append(&cmd.args, lhs, rhs)
	return Arg{type = .Call, expr = cmd}
}
