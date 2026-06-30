package dsl

import "core:fmt"
import "core:math"
import "core:strings"
import opt "../optimizer"

Parser :: struct {
	model:   ^opt.Model,
	var_map: map[string]f64,
	expr_map: map[string]opt.Compiled_Expr,
}

init_parser :: proc(model: ^opt.Model) -> Parser {
	parser := init_parser_without_n(model)
	parser.var_map[strings.clone("n")] = f64(model.n-1)
	return parser
}

init_parser_without_n :: proc(model: ^opt.Model) -> Parser {
	parser := Parser {
		model   = model,
		var_map = make(map[string]f64),
		expr_map = make(map[string]opt.Compiled_Expr),
	}
	return parser
}

resolve_markers :: proc(parser: ^Parser, markers: []Marker) -> string {
	for marker in markers {
		if marker.tick < 0 || marker.tick >= parser.model.n {
			return fmt.aprintf(
				"Marker '%s' references out-of-range tick %d",
				marker.name,
				marker.tick,
			)
		}
		if (marker.type == .Vx || marker.type == .Vz || marker.type == .T) &&
		   marker.tick >= parser.model.n-1 {
			return fmt.aprintf(
				"Marker '%s' requires a tick before the terminal tick",
				marker.name,
			)
		}
		if _, found := parser.var_map[marker.name]; found {
			return fmt.aprintf(
				"Marker '%s' conflicts with an existing variable",
				marker.name,
			)
		}
		if _, found := parser.expr_map[marker.name]; found {
			return fmt.aprintf("Marker '%s' is already defined", marker.name)
		}

		expr: opt.Compiled_Expr
		switch marker.type {
			case .X:
				expr = opt.clone_compiled_expr(parser.model.x[marker.tick])
			case .Z:
				expr = opt.clone_compiled_expr(parser.model.z[marker.tick])
			case .F:
				expr = opt.make_compiled_expr(parser.model.n)
				expr.theta_coeff[marker.tick] = 180/math.PI
			case .Vx:
				expr = opt.clone_compiled_expr(parser.model.vx[marker.tick])
			case .Vz:
				expr = opt.clone_compiled_expr(parser.model.vz[marker.tick])
			case .T:
				expr = opt.make_compiled_expr(parser.model.n)
				expr.theta_coeff[marker.tick+1] = 180/math.PI
				expr.theta_coeff[marker.tick] = -180/math.PI
		}

		parser.expr_map[strings.clone(marker.name)] = expr
	}
	return ""
}

destroy :: proc(parser: ^Parser) {
	for key in parser.var_map do delete(key)
	delete(parser.var_map)
	for key, expr in parser.expr_map {
		e := expr
		opt.destroy_compiled_expr(&e)
		delete(key)
	}
	delete(parser.expr_map)
	parser^ = {}
}

destroy_constraints :: proc(constraints: ^[dynamic]opt.Constraint) {
	for i in 0..<len(constraints) {
		opt.destroy_compiled_expr(&constraints[i].lhs)
		delete(constraints[i].source)
	}
	delete(constraints^)
	constraints^ = nil
}

trim :: proc(text: string) -> string {
	left := 0
	for left < len(text) && is_space(text[left]) do left += 1
	right := len(text)
	for right > left && is_space(text[right-1]) do right -= 1
	return text[left:right]
}

parser_error :: proc(message: string, lexer: ^Lexer) -> string {
	p := lexer.pos
	if p > 0 do p -= 1
	indicator := strings.repeat(" ", p)
	defer delete(indicator)
	return fmt.aprintf("%s\n\n%s\n%s^", message, lexer.data, indicator)
}

lexer_error :: proc(token: Token, lexer: ^Lexer) -> string {
	return parser_error(token.text, lexer)
}

set_variable :: proc(parser: ^Parser, name: string, value: f64) {
	if name in parser.var_map {
		parser.var_map[name] = value
	} else {
		parser.var_map[strings.clone(name)] = value
	}
}

add_resolved_variables :: proc(parser: ^Parser, variables: map[string]f64) {
	for name, value in variables {
		set_variable(parser, name, value)
	}
}

add_variable :: proc(parser: ^Parser, raw_name, value: string) -> string {
	name := trim(raw_name)
	if len(name) == 0 do return ""
	if !is_alpha(name[0]) && name[0] != '_' {
		return fmt.aprintf("%s is an illegal name", name)
	}
	if name == "n" || name == "X" || name == "Z" ||
	   name == "F" || name == "Vx" || name == "Vz" || name == "T" {
		return fmt.aprintf("%s is a reserved keyword", name)
	}
	if len(value) == 0 do return fmt.aprintf("%s has no definition", name)

	expr, err := parse_expr(parser, value)
	if err != "" do return err
	defer opt.destroy_compiled_expr(&expr)
	if !opt.is_constant(expr) {
		return fmt.aprintf("Unable to reduce '%s' to a constant.", name)
	}
	set_variable(parser, name, expr.constant)
	return ""
}

add_variables :: proc(parser: ^Parser, names, values: []string) -> string {
	if len(names) != len(values) {
		return strings.clone("Variable name/value size mismatch")
	}
	for i in 0..<len(names) {
		if err := add_variable(parser, names[i], values[i]); err != "" do return err
	}
	return ""
}

scale_expr :: proc(expr: opt.Compiled_Expr, scalar: f64) -> opt.Compiled_Expr {
	out := opt.clone_compiled_expr(expr)
	out.constant *= scalar
	for i in 0..<len(out.theta_coeff) {
		out.theta_coeff[i] *= scalar
		out.sin_coeff[i]   *= scalar
		out.cos_coeff[i]   *= scalar
	}
	return out
}

combine_expr :: proc(
	parser: ^Parser,
	lhs, rhs: opt.Compiled_Expr,
	operator: Token,
	lexer: ^Lexer,
) -> (opt.Compiled_Expr, string) {
	s := operator.text
	if s == "+" || s == "-" {
		sign_rhs := 1.0 if s == "+" else -1.0
		out := opt.clone_compiled_expr(lhs)
		out.constant += sign_rhs*rhs.constant
		for i in 0..<len(out.theta_coeff) {
			out.theta_coeff[i] += sign_rhs*rhs.theta_coeff[i]
			out.sin_coeff[i]   += sign_rhs*rhs.sin_coeff[i]
			out.cos_coeff[i]   += sign_rhs*rhs.cos_coeff[i]
		}
		for i in 0..<len(out.theta_coeff) {
			if math.abs(out.theta_coeff[i]) < opt.EPS do out.theta_coeff[i] = 0
			if math.abs(out.sin_coeff[i])   < opt.EPS do out.sin_coeff[i] = 0
			if math.abs(out.cos_coeff[i])   < opt.EPS do out.cos_coeff[i] = 0
		}
		if math.abs(out.constant) < opt.EPS do out.constant = 0
		return out, ""
	}

	if s == "*" {
		lhs_constant := opt.is_constant(lhs)
		rhs_constant := opt.is_constant(rhs)
		if lhs_constant && rhs_constant {
			out := opt.make_compiled_expr(parser.model.n)
			out.constant = lhs.constant*rhs.constant
			return out, ""
		}
		if lhs_constant do return scale_expr(rhs, lhs.constant), ""
		if rhs_constant do return scale_expr(lhs, rhs.constant), ""
		return {}, parser_error("Nonlinear multiplication is not allowed", lexer)
	}

	if s == "/" {
		if !opt.is_constant(rhs) {
			return {}, parser_error("Division by non-constant is not allowed", lexer)
		}
		if rhs.constant == 0 {
			return {}, parser_error("Division by zero", lexer)
		}
		return scale_expr(lhs, 1/rhs.constant), ""
	}
	return {}, parser_error(fmt.tprintf("Unknown operator: %s", operator.text), lexer)
}

resolve_indexed :: proc(
	parser: ^Parser,
	name: string,
	index: int,
	lexer: ^Lexer,
) -> (opt.Compiled_Expr, string) {
	bound_error := proc(name: string, requested: int, lexer: ^Lexer) -> string {
		return parser_error(fmt.tprintf("%s[%d] is out of range", name, requested), lexer)
	}
	if name == "X" {
		if index < 0 || index >= len(parser.model.x) do return {}, bound_error(name, index, lexer)
		return opt.clone_compiled_expr(parser.model.x[index]), ""
	}
	if name == "Z" {
		if index < 0 || index >= len(parser.model.z) do return {}, bound_error(name, index, lexer)
		return opt.clone_compiled_expr(parser.model.z[index]), ""
	}
	if name == "Vx" {
		if index < 0 || index >= len(parser.model.x)-1 do return {}, bound_error(name, index, lexer)
		return combine_expr(
			parser,
			parser.model.x[index+1],
			parser.model.x[index],
			Token{type = .Operator, text = "-"},
			lexer,
		)
	}
	if name == "Vz" {
		if index < 0 || index >= len(parser.model.z)-1 do return {}, bound_error(name, index, lexer)
		return combine_expr(
			parser,
			parser.model.z[index+1],
			parser.model.z[index],
			Token{type = .Operator, text = "-"},
			lexer,
		)
	}
	if name == "F" {
		if index < 0 || index >= parser.model.n do return {}, bound_error(name, index, lexer)
		expr := opt.make_compiled_expr(parser.model.n)
		expr.theta_coeff[index] = 180/math.PI
		// so when F[t] = 180 deg, it thinks 180 / PI * theta[t] = 180 -> theta[t] = PI radians
		return expr, ""
	}
	if name == "T" {
		// Turn: T[i] = F[i+1] - F[i]
		if index < 0 || index >= parser.model.n-1 do return {}, bound_error(name, index, lexer)
		expr := opt.make_compiled_expr(parser.model.n)
		expr.theta_coeff[index+1] = 180/math.PI
		expr.theta_coeff[index] = -180/math.PI
		return expr, ""
	}
	return {}, strings.clone("Bug: This shouldn't happen cuz I checked the identifier name already.")
}

parse_number :: proc(parser: ^Parser, token: Token) -> (opt.Compiled_Expr, string) {
	value, err := get_token_value(token)
	if err != "" do return {}, err
	expr := opt.make_compiled_expr(parser.model.n)
	expr.constant = value
	return expr, ""
}

parse_identifier :: proc(
	parser: ^Parser,
	lexer: ^Lexer,
	token: Token,
) -> (opt.Compiled_Expr, string) {
	name := token.text
	if name == "X" || name == "Z" || name == "F" || name == "Vx" ||
	   name == "Vz" || name == "T" {
		open := lexer_next(lexer)
		if open.type == .Invalid do return {}, lexer_error(open, lexer)
		if open.type != .L_Bracket {
			return {}, parser_error(fmt.tprintf("Expected '[' after %s", name), lexer)
		}

		index_expr, index_err := parse_expr_bp(parser, lexer, 0)
		if index_err != "" do return {}, index_err
		defer opt.destroy_compiled_expr(&index_expr)

		close := lexer_next(lexer)
		if close.type == .Invalid do return {}, lexer_error(close, lexer)
		if close.type != .R_Bracket do return {}, parser_error("Missing ']'", lexer)
		if !opt.is_constant(index_expr) do return {}, parser_error("Index must be constant", lexer)

		index := int(math.round(index_expr.constant))
		if index < 0 {
			return {}, parser_error(fmt.tprintf("%s[%d] is out of range", name, index), lexer)
		}
		return resolve_indexed(parser, name, index, lexer)
	}

	if value, found := parser.var_map[name]; found {
		expr := opt.make_compiled_expr(parser.model.n)
		expr.constant = value
		return expr, ""
	}

	if expr, found := parser.expr_map[name]; found {
		return opt.clone_compiled_expr(expr), ""
	}

	return {}, parser_error(fmt.tprintf("Identifier %s is undefined.", name), lexer)
}

// Pratt Parser IS THE BEST
parse_expr_bp :: proc(
	parser: ^Parser,
	lexer: ^Lexer,
	min_bp: int,
) -> (opt.Compiled_Expr, string) {
	prefix := lexer_next(lexer)
	if prefix.type == .Invalid do return {}, lexer_error(prefix, lexer)
	prefix_err := ""
	lhs: opt.Compiled_Expr

	#partial switch prefix.type {
	case .Number:
		lhs, prefix_err = parse_number(parser, prefix)
	case .Identifier:
		lhs, prefix_err = parse_identifier(parser, lexer, prefix)
	case .Operator:
		if prefix.text != "-" {
			return {}, parser_error(fmt.tprintf("Invalid prefix operator '%s'", prefix.text), lexer)
		}
		rhs, rhs_err := parse_expr_bp(parser, lexer, 30)
		if rhs_err != "" do return {}, rhs_err
		lhs = scale_expr(rhs, -1)
		opt.destroy_compiled_expr(&rhs)
	case .L_Paren:
		lhs, prefix_err = parse_expr_bp(parser, lexer, 0)
		if prefix_err == "" {
			close := lexer_next(lexer)
			if close.type == .Invalid {
				opt.destroy_compiled_expr(&lhs)
				return {}, lexer_error(close, lexer)
			}
			if close.type != .R_Paren {
				opt.destroy_compiled_expr(&lhs)
				return {}, parser_error("Missing ')'", lexer)
			}
		}
	case:
		return {}, parser_error(fmt.tprintf("Invalid prefix token: %s", prefix.text), lexer)
	}
	if prefix_err != "" do return {}, prefix_err

	for {
		operator := lexer_peek(lexer)
		if operator.type == .Invalid {
			opt.destroy_compiled_expr(&lhs)
			return {}, lexer_error(operator, lexer)
		}
		if operator.type != .Operator do break

		bp, bp_err := get_binding_power(operator)
		if bp_err != "" {
			opt.destroy_compiled_expr(&lhs)
			return {}, bp_err
		}
		if bp.left < min_bp do break
		consumed := lexer_next(lexer)
		if consumed.type == .Invalid {
			opt.destroy_compiled_expr(&lhs)
			return {}, lexer_error(consumed, lexer)
		}

		rhs, rhs_err := parse_expr_bp(parser, lexer, bp.right)
		if rhs_err != "" {
			opt.destroy_compiled_expr(&lhs)
			return {}, rhs_err
		}
		combined, combine_err := combine_expr(parser, lhs, rhs, operator, lexer)
		opt.destroy_compiled_expr(&lhs)
		opt.destroy_compiled_expr(&rhs)
		if combine_err != "" do return {}, combine_err
		lhs = combined
	}
	return lhs, ""
}

parse_expr :: proc(parser: ^Parser, text: string) -> (opt.Compiled_Expr, string) {
	lexer := Lexer{data = text}
	expr, err := parse_expr_bp(parser, &lexer, 0)
	if err != "" do return {}, err
	next := lexer_peek(&lexer)
	if next.type == .Invalid {
		opt.destroy_compiled_expr(&expr)
		return {}, lexer_error(next, &lexer)
	}
	if next.type != .End {
		opt.destroy_compiled_expr(&expr)
		return {}, parser_error("Unexpected trailing tokens", &lexer)
	}
	return expr, ""
}

parse_constant :: proc(parser: ^Parser, text: string) -> (f64, string) {
	expr, err := parse_expr(parser, text)
	if err != "" do return 0, err
	defer opt.destroy_compiled_expr(&expr)
	if !opt.is_constant(expr) {
		return 0, fmt.aprintf("Cannot reduce expression to constant: %s", text)
	}
	return expr.constant, ""
}

parse_constraint :: proc(parser: ^Parser, text: string) -> (opt.Constraint, string) {
	lexer := Lexer{data = text}
	lhs, lhs_err := parse_expr_bp(parser, &lexer, 0)
	if lhs_err != "" do return {}, lhs_err
	defer opt.destroy_compiled_expr(&lhs)

	cmp_token := lexer_next(&lexer)
	if cmp_token.type == .Invalid do return {}, lexer_error(cmp_token, &lexer)
	if cmp_token.type != .Cmp {
		return {}, parser_error(
			fmt.tprintf("Expected comparison operator, got '%s'", cmp_token.text),
			&lexer,
		)
	}
	if len(cmp_token.text) != 1 ||
	   (cmp_token.text != "<" && cmp_token.text != "=" && cmp_token.text != ">") {
		return {}, parser_error(fmt.tprintf("Unknown Cmp Token: %s", cmp_token.text), &lexer)
	}

	rhs, rhs_err := parse_expr_bp(parser, &lexer, 0)
	if rhs_err != "" do return {}, rhs_err
	defer opt.destroy_compiled_expr(&rhs)
	trailing := lexer_peek(&lexer)
	if trailing.type == .Invalid do return {}, lexer_error(trailing, &lexer)
	if trailing.type != .End do return {}, parser_error("Unexpected trailing tokens", &lexer)

	operator := Token{type = .Operator, text = "-"}
	standard: opt.Compiled_Expr
	cmp: opt.Cmp
	combine_err: string
	switch cmp_token.text {
	case "<":
		standard, combine_err = combine_expr(parser, lhs, rhs, operator, &lexer)
		cmp = .Less
	case ">":
		standard, combine_err = combine_expr(parser, rhs, lhs, operator, &lexer)
		cmp = .Less
	case "=":
		standard, combine_err = combine_expr(parser, lhs, rhs, operator, &lexer)
		cmp = .Equal
	}
	if combine_err != "" do return {}, combine_err
	return opt.Constraint {
		lhs    = standard,
		cmp    = cmp,
		source = strings.clone(text),
	}, ""
}

index_byte :: proc(text, needle: string) -> int {
	if len(needle) == 0 do return 0
	if len(needle) > len(text) do return -1
	for i in 0..=len(text)-len(needle) {
		if text[i:i+len(needle)] == needle do return i
	}
	return -1
}

parse_multi_constraints :: proc(
	parser: ^Parser,
	input: string,
) -> ([dynamic]opt.Constraint, string) {
	constraints: [dynamic]opt.Constraint
	start := 0
	line_count := 1
	for start < len(input) {
		relative_end := index_byte(input[start:], "\n")
		end := len(input) if relative_end < 0 else start+relative_end
		line := input[start:end]
		if comment_pos := index_byte(line, "//"); comment_pos >= 0 {
			line = line[:comment_pos]
		}
		line = trim(line)
		if len(line) > 0 {
			constraint, err := parse_constraint(parser, line)
			if err != "" {
				destroy_constraints(&constraints)
				wrapped := fmt.aprintf(
					"At constraint line %d:\n  Reason: %s",
					line_count,
					err,
				)
				delete(err)
				return nil, wrapped
			}
			append(&constraints, constraint)
		}
		start = end+1
		line_count += 1
	}
	return constraints, ""
}
