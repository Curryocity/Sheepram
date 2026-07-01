package optimizer

import "core:math"

SINE_TABLE_SIZE :: 65536
SINE_TABLE_MASK :: 0xffff

INDEX_PER_RAD: f32 = 10430.378
RIGHT_ANGLE: f32 = 16384.0

sine_table: [SINE_TABLE_SIZE]f32
facing_table: [SINE_TABLE_SIZE]f64
sin_value_table: [SINE_TABLE_SIZE]f32
cos_value_table: [SINE_TABLE_SIZE]f32

@(init)
init_sine_table :: proc "contextless" () {
	for i in 0..<SINE_TABLE_SIZE {
		sine_table[i] = f32(
			math.sin(f64(i) * math.PI *2.0 /f64(SINE_TABLE_SIZE)),
		)
	}
	for i in 0..<SINE_TABLE_SIZE {
		facing := compute_index_facing(u16(i))
		facing_table[i] = facing
		sin_value_table[i] = sin(f32(facing))
		cos_value_table[i] = cos(f32(facing))
	}
}

index :: proc "contextless" (rad: f32) -> u16 {
	index := int(rad * INDEX_PER_RAD)
	return u16(index & SINE_TABLE_MASK)
}

sin :: proc "contextless" (deg: f32) -> f32 {
	rad := deg * f32(math.PI) / f32(180.0)
	return sine_table[int(rad * INDEX_PER_RAD) & SINE_TABLE_MASK]
}

cos :: proc "contextless" (deg: f32) -> f32 {
	rad := deg * f32(math.PI) / f32(180.0)
	return sine_table[int(rad * INDEX_PER_RAD + RIGHT_ANGLE) & SINE_TABLE_MASK]
}

facing_sin_index :: proc "contextless" (deg: f32) -> u16 {
	rad := deg * f32(math.PI) / f32(180.0)
	return u16(int(rad * INDEX_PER_RAD) & SINE_TABLE_MASK)
}

facing_cos_index :: proc "contextless" (deg: f32) -> u16 {
	rad := deg * f32(math.PI) / f32(180.0)
	return u16(int(rad * INDEX_PER_RAD + RIGHT_ANGLE) & SINE_TABLE_MASK)
}

sin_index :: proc "contextless" (index: u16) -> f32 {
	return sin_value_table[int(index)]
}

cos_index :: proc "contextless" (index: u16) -> f32 {
	return cos_value_table[int(index)]
}

update_discrete_trig_cache :: proc(
	work: ^Workspace,
	state: Discrete_State,
	angle_offset: []f64,
) {
	assert(len(work.sin_cache) == len(state.indices)+2)
	assert(len(work.cos_cache) == len(state.indices)+2)
	assert(len(angle_offset) >= len(state.indices)+2)

	work.sin_cache[0] = math.sin(state.init_theta)
	work.cos_cache[0] = math.cos(state.init_theta)
	for index, i in state.indices {
		t := i+1
		facing_sin := f64(sin_index(index))
		facing_cos := f64(cos_index(index))
		offset_sin := math.sin(angle_offset[t])
		offset_cos := math.cos(angle_offset[t])

		work.sin_cache[t] = facing_sin*offset_cos + facing_cos*offset_sin
		work.cos_cache[t] = facing_cos*offset_cos - facing_sin*offset_sin
	}
}

index_to_radians :: proc "contextless" (index: u16) -> f64 {
	return index_to_facing(index)*math.PI/180.0
}

index_to_facing :: proc "contextless" (idx: u16) -> f64 {
	return facing_table[int(idx)]
}

compute_index_facing :: proc "contextless" (idx: u16) -> f64 {
	step :: 0.005
	center := (f64(idx)+0.5) * 360.0 / f64(SINE_TABLE_SIZE)
	if center > 180 do center -= 360

	base := int(math.round(center / step))
	for radius in 0..=2 {
		for sign in 0..=1 {
			if radius == 0 && sign == 1 do continue
			offset := radius if sign == 0 else -radius
			deg := f64(base+offset) * step
			if deg < -180 || deg > 180 do continue
			if facing_sin_index(f32(deg)) == idx do return deg
		}
	}

	return f64(base) * step
}


same_trig_bucketQ :: proc "contextless" (deg: f32, idx: u16) -> bool {
	return facing_sin_index(deg) == idx
}
