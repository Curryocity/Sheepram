package parser

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import opt "../optimizer"

Parser :: struct {
	model:   ^opt.Model,
	var_map: map[string]f64,
}

Token_Type :: enum {
	Number,
	Identifier,
	Operator,
	Cmp,
	L_Paren,
	R_Paren,
	L_Bracket,
	R_Bracket,
	End,
}

Token :: struct {
	type: Token_Type,
	text: string,
}

Lexer :: struct {
	input:       string,
	pos:         int,
	next_cache:  Token,
	cache_valid: bool,
}

Binding_Power :: struct {
	left:  int,
	right: int,
}

init_parser :: proc(model: ^opt.Model) -> Parser {
	parser := Parser {
		model   = model,
		var_map = make(map[string]f64),
	}
	parser.var_map[strings.clone("n")] = f64(model.n-1)
	return parser
}

destroy :: proc(parser: ^Parser) {
	for key in parser.var_map do delete(key)
	delete(parser.var_map)
	parser^ = {}
}

destroy_constraints :: proc(constraints: ^[dynamic]opt.Constraint) {
	for i in 0..<len(constraints) {
		opt.destroy_compiled_expr(&constraints[i].lhs)
	}
	delete(constraints^)
	constraints^ = nil
}

is_space :: proc(ch: u8) -> bool {
	return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' ||
	       ch == '\f' || ch == '\v'
}

is_digit :: proc(ch: u8) -> bool {
	return ch >= '0' && ch <= '9'
}

is_alpha :: proc(ch: u8) -> bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
}

is_alnum :: proc(ch: u8) -> bool {
	return is_alpha(ch) || is_digit(ch)
}

trim :: proc(text: string) -> string {
	left := 0
	for left < len(text) && is_space(text[left]) do left += 1
	right := len(text)
	for right > left && is_space(text[right-1]) do right -= 1
	return text[left:right]
}

lexer_skip_space :: proc(lexer: ^Lexer) {
	for lexer.pos < len(lexer.input) && is_space(lexer.input[lexer.pos]) {
		lexer.pos += 1
	}
}

lexer_number :: proc(lexer: ^Lexer) -> (Token, string) {
	start := lexer.pos
	for lexer.pos < len(lexer.input) && is_digit(lexer.input[lexer.pos]) {
		lexer.pos += 1
	}

	if lexer.pos < len(lexer.input) && lexer.input[lexer.pos] == '.' {
		lexer.pos += 1
		for lexer.pos < len(lexer.input) && is_digit(lexer.input[lexer.pos]) {
			lexer.pos += 1
		}
	}

	// Scientic Notation
	if lexer.pos < len(lexer.input) &&
	   (lexer.input[lexer.pos] == 'e' || lexer.input[lexer.pos] == 'E') {
		lexer.pos += 1
		if lexer.pos < len(lexer.input) &&
		   (lexer.input[lexer.pos] == '+' || lexer.input[lexer.pos] == '-') {
			lexer.pos += 1
		}
		if lexer.pos >= len(lexer.input) || !is_digit(lexer.input[lexer.pos]) {
			return {}, strings.clone("Invalid scientific notation")
		}
		for lexer.pos < len(lexer.input) && is_digit(lexer.input[lexer.pos]) {
			lexer.pos += 1
		}
	}
	return Token{type = .Number, text = lexer.input[start:lexer.pos]}, ""
}

lexer_identifier :: proc(lexer: ^Lexer) -> Token {
	start := lexer.pos
	for lexer.pos < len(lexer.input) &&
	    (is_alnum(lexer.input[lexer.pos]) || lexer.input[lexer.pos] == '_') {
		lexer.pos += 1
	}
	return Token{type = .Identifier, text = lexer.input[start:lexer.pos]}
}

lexer_update_next :: proc(lexer: ^Lexer) -> string {
	lexer_skip_space(lexer)
	if lexer.pos >= len(lexer.input) {
		lexer.next_cache = Token{type = .End}
		lexer.cache_valid = true
		return ""
	}

	ch := lexer.input[lexer.pos]
	if is_digit(ch) {
		token, err := lexer_number(lexer)
		if err != "" do return err
		lexer.next_cache = token
		lexer.cache_valid = true
		return ""
	}
	if is_alpha(ch) || ch == '_' {
		lexer.next_cache = lexer_identifier(lexer)
		lexer.cache_valid = true
		return ""
	}

	lexer.pos += 1
	token_type: Token_Type
	switch ch {
	case '+', '-', '*', '/':
		token_type = .Operator
	case '<', '=', '>':
		token_type = .Cmp
	case '(':
		token_type = .L_Paren
	case ')':
		token_type = .R_Paren
	case '[':
		token_type = .L_Bracket
	case ']':
		token_type = .R_Bracket
	case:
		return fmt.aprintf("Invalid Token '%c'", ch)
	}
	lexer.next_cache = Token {
		type = token_type,
		text = lexer.input[lexer.pos-1:lexer.pos],
	}
	lexer.cache_valid = true
	return ""
}

lexer_next :: proc(lexer: ^Lexer) -> (Token, string) {
	if !lexer.cache_valid {
		if err := lexer_update_next(lexer); err != "" do return {}, err
	}
	token := lexer.next_cache
	lexer.cache_valid = false
	return token, ""
}

lexer_peek :: proc(lexer: ^Lexer) -> (Token, string) {
	if !lexer.cache_valid {
		if err := lexer_update_next(lexer); err != "" do return {}, err
	}
	return lexer.next_cache, ""
}

parser_error :: proc(message: string, lexer: ^Lexer) -> string {
	p := lexer.pos
	if p > 0 do p -= 1
	indicator := strings.repeat(" ", p)
	defer delete(indicator)
	return fmt.aprintf("%s\n\n%s\n%s^", message, lexer.input, indicator)
}

define_init_v :: proc(parser: ^Parser, init_v: f64) {
	if old_key, found := map_key(parser.var_map, "initV"); found {
		parser.var_map[old_key] = init_v
	} else {
		parser.var_map[strings.clone("initV")] = init_v
	}
}

set_variable :: proc(parser: ^Parser, name: string, value: f64) {
	if old_key, found := map_key(parser.var_map, name); found {
		parser.var_map[old_key] = value
	} else {
		parser.var_map[strings.clone(name)] = value
	}
}

map_key :: proc(values: map[string]f64, wanted: string) -> (string, bool) {
	for key in values {
		if key == wanted do return key, true
	}
	return "", false
}

add_variable :: proc(parser: ^Parser, raw_name, value: string) -> string {
	name := trim(raw_name)
	if len(name) == 0 do return ""
	if !is_alpha(name[0]) && name[0] != '_' {
		return fmt.aprintf("%s is an illegal name", name)
	}
	if name == "n" || name == "initV" || name == "X" || name == "Z" ||
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

get_binding_power :: proc(operator: Token) -> (Binding_Power, string) {
	if operator.text == "+" || operator.text == "-" do return {10, 11}, ""
	if operator.text == "*" || operator.text == "/" do return {20, 21}, ""
	return {}, strings.clone("Unknown operator")
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
	value, ok := strconv.parse_f64(token.text)
	if !ok do return {}, fmt.aprintf("Invalid number: %s", token.text)
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
		open, err := lexer_next(lexer)
		if err != "" do return {}, err
		if open.type != .L_Bracket {
			return {}, parser_error(fmt.tprintf("Expected '[' after %s", name), lexer)
		}

		index_expr, index_err := parse_expr_bp(parser, lexer, 0)
		if index_err != "" do return {}, index_err
		defer opt.destroy_compiled_expr(&index_expr)

		close, close_err := lexer_next(lexer)
		if close_err != "" do return {}, close_err
		if close.type != .R_Bracket do return {}, parser_error("Missing ']'", lexer)
		if !opt.is_constant(index_expr) do return {}, parser_error("Index must be constant", lexer)

		index := int(math.round(index_expr.constant))
		if index < 0 {
			return {}, parser_error(fmt.tprintf("%s[%d] is out of range", name, index), lexer)
		}
		return resolve_indexed(parser, name, index, lexer)
	}

	if key, found := map_key(parser.var_map, name); found {
		expr := opt.make_compiled_expr(parser.model.n)
		expr.constant = parser.var_map[key]
		return expr, ""
	}
	return {}, parser_error(fmt.tprintf("Identifier %s is undefined.", name), lexer)
}

// Pratt Parser IS THE BEST
parse_expr_bp :: proc(
	parser: ^Parser,
	lexer: ^Lexer,
	min_bp: int,
) -> (opt.Compiled_Expr, string) {
	prefix, prefix_err := lexer_next(lexer)
	if prefix_err != "" do return {}, prefix_err
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
			close, close_err := lexer_next(lexer)
			if close_err != "" {
				opt.destroy_compiled_expr(&lhs)
				return {}, close_err
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
		operator, peek_err := lexer_peek(lexer)
		if peek_err != "" {
			opt.destroy_compiled_expr(&lhs)
			return {}, peek_err
		}
		if operator.type != .Operator do break

		bp, bp_err := get_binding_power(operator)
		if bp_err != "" {
			opt.destroy_compiled_expr(&lhs)
			return {}, bp_err
		}
		if bp.left < min_bp do break
		_, consume_err := lexer_next(lexer)
		if consume_err != "" {
			opt.destroy_compiled_expr(&lhs)
			return {}, consume_err
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
	lexer := Lexer{input = text}
	expr, err := parse_expr_bp(parser, &lexer, 0)
	if err != "" do return {}, err
	next, next_err := lexer_peek(&lexer)
	if next_err != "" {
		opt.destroy_compiled_expr(&expr)
		return {}, next_err
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
	lexer := Lexer{input = text}
	lhs, lhs_err := parse_expr_bp(parser, &lexer, 0)
	if lhs_err != "" do return {}, lhs_err
	defer opt.destroy_compiled_expr(&lhs)

	cmp_token, cmp_err := lexer_next(&lexer)
	if cmp_err != "" do return {}, cmp_err
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
	trailing, trailing_err := lexer_peek(&lexer)
	if trailing_err != "" do return {}, trailing_err
	if trailing.type != .End do return {}, parser_error("Unexpected trailing tokens", &lexer)

	operator := Token{type = .Operator, text = "-"}
	standard: opt.Compiled_Expr
	cmp: opt.Constraint_Comparison
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
	return opt.Constraint{lhs = standard, cmp = cmp}, ""
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
