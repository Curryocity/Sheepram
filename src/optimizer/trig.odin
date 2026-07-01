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

index :: proc(rad: f32) -> u16 {
	index := int(rad * INDEX_PER_RAD)
	return u16(index & SINE_TABLE_MASK)
}

new_sin_index :: proc(index: u16) -> f32 {
	step :: 0.005
	center := (f64(index)+0.5) * 360.0 / f64(SINE_TABLE_SIZE)

	deg := math.round(center / step) * step
	return sin(f32(deg))
}

new_cos_index :: proc(index: u16) -> f32 {
	step :: 0.005
	center := (f64(index)+0.5) * 360.0 / f64(SINE_TABLE_SIZE)

	deg := math.round(center / step) * step
	return cos(f32(deg))
}

sin :: proc(deg: f32) -> f32 {
    rad:f32 = deg * f32(math.PI) / f32(180.0)
    return sine_table[int(rad * 10430.378) & 65535]
}

cos :: proc(deg: f32) -> f32 {
    rad:f32 = deg * f32(math.PI) / f32(180.0)
    return sine_table[int(rad * 10430.378 + 16384.0) & 65535]
}


sin_index :: proc(index: u16) -> f32 {
	return sine_table[int(index)]
}

cos_index :: proc(index: u16) -> f32 {
	return sine_table[(int(index)+0x4000)&SINE_TABLE_MASK]
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

index_to_radians :: proc(index: u16) -> f64 {
	return f64(index)*2*math.PI/f64(SINE_TABLE_SIZE)
}

index_to_facing :: proc(idx: u16) -> f64 {
	step :: 0.005
	center := (f64(idx)+0.5) * 360.0 / f64(SINE_TABLE_SIZE)

	base := int(math.round(center / step))

	for offset in -2..=2 {
		k := base + offset

		deg := f64(k) * step

		if same_trig_bucketQ(f32(deg), idx) {
			return deg
		}
	}

	// this does not guaruntee to find a non-half angle
	// todo: fix that

	return center
}


same_trig_bucketQ :: proc(deg: f32, idx: u16) -> bool {
	rad := deg * f32(math.PI) / f32(180.0)
	sin_idx := u16(int(rad * 10430.378) &  0xffff)
	cos_idx := u16(int(rad * 10430.378 + 0x4000) &  0xffff)

	return sin_idx == idx && cos_idx == u16((int(idx) + 0x4000) &  0xffff)
}
