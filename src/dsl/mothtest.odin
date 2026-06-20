package dsl

import "core:testing"
import "core:fmt"

print_f64_array :: proc(name: string, values: []f64) {
	fmt.printf("%s: [", name)
	for value, i in values {
		if i > 0 do fmt.print(", ")
		fmt.printf("%.5f", value)
	}
	fmt.println("]")
}

@(test)
test1 :: proc(t: ^testing.T) {
	code, err := parse_mothball("sj.w sa.wa(11)")
	defer destroy_moth_code(&code)

	if err != "" {
		fmt.printf("Parse error: %s\n", err)
		testing.expect(t, false)
		return
	}

	state := init_moth_execution_state()
    state.speed = 1
	defer destroy_moth_execution_state(&state)

	moth_to_model(&state, code[:])
	if !state.ok {
		fmt.printf("Model error: %s\n", state.err)
		testing.expect(t, false)
		return
	}

	fmt.println("n: ", state.n)
	print_f64_array("drag_x", state.drag_x[:])
	print_f64_array("drag_z", state.drag_z[:])
	print_f64_array("accel", state.accel[:])
	print_f64_array("angle_offset", state.angle_offset[:])

	testing.expect_value(t, state.n, len(state.accel))
}


