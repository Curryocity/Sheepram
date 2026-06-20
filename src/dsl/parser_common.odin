package dsl

import "core:fmt"
import "core:strconv"
import "core:strings"

Binding_Power :: struct {
	left:  int,
	right: int,
}

get_token_value :: proc(token: Token) -> (f64, string) {
	value, ok := strconv.parse_f64(token.text)
	if !ok do return 0, fmt.aprintf("Invalid number: %s", token.text)
	return value, ""
}

get_binding_power :: proc(operator: Token) -> (Binding_Power, string) {
	switch operator.text {
	case "+", "-":
		return {10, 11}, ""
	case "*", "/":
		return {20, 21}, ""
	case:
		return {}, strings.clone("Unknown operator")
	}
}
