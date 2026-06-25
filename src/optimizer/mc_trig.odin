package optimizer

import "core:math"

SINE_TABLE_SIZE :: 65536
SINE_TABLE_MASK :: 0xffff

INDEX_PER_RAD: f32 = 10430.378
RIGHT_ANGLE: f32 = 16384.0

sine_table: [SINE_TABLE_SIZE]f32

@(init)
init_sine_table :: proc "contextless" () {
	for i in 0..<SINE_TABLE_SIZE {
		sine_table[i] = f32(
			math.sin(f64(i) * math.PI *2.0 /f64(SINE_TABLE_SIZE)),
		)
	}
}

index :: proc(deg: f32) -> u16 {
	rad := deg * f32(math.PI) / f32(180.0)
	index := int(rad * INDEX_PER_RAD)
	return u16(index & SINE_TABLE_MASK)
}

sin_index :: proc(index: u16) -> f32 {
	return sine_table[int(index)]
}

cos_index :: proc(index: u16) -> f32 {
	return sine_table[(int(index)+0x4000)&SINE_TABLE_MASK]
}

update_discrete_trig_cache :: proc(
	work: ^Workspace,
	initial_theta: f64,
	angle_indices: []u16,
) {
	assert(len(work.sin_cache) == len(angle_indices)+1)
	assert(len(work.cos_cache) == len(angle_indices)+1)

	work.sin_cache[0] = math.sin(initial_theta)
	work.cos_cache[0] = math.cos(initial_theta)
	for index, i in angle_indices {
		work.sin_cache[i+1] = f64(sin_index(index))
		work.cos_cache[i+1] = f64(cos_index(index))
	}
}

index_radians :: proc(index: u16) -> f64 {
	return f64(index)*2*math.PI/f64(SINE_TABLE_SIZE)
}

eval_discrete_expr :: proc(
	expr: Compiled_Expr,
	initial_theta: f64,
	angle_indices: []u16,
) -> f64 {
	n := len(angle_indices)+1
	assert(len(expr.theta_coeff) == n)
	work := Workspace {
		sin_cache = make([dynamic]f64, n),
		cos_cache = make([dynamic]f64, n),
	}
	defer delete(work.sin_cache)
	defer delete(work.cos_cache)

	update_discrete_trig_cache(&work, initial_theta, angle_indices)

	value := expr.constant +
	         expr.theta_coeff[0]*initial_theta +
	         expr.sin_coeff[0]*work.sin_cache[0] +
	         expr.cos_coeff[0]*work.cos_cache[0]
	for index, i in angle_indices {
		t := i+1
		value += expr.theta_coeff[t]*index_radians(index) +
		         expr.sin_coeff[t]*work.sin_cache[t] +
		         expr.cos_coeff[t]*work.cos_cache[t]
	}
	return value
}
