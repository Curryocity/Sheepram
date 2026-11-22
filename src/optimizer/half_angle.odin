package optimizer

import "core:math"


Trig :: struct {
    s: int,
    c: int,
}

half_angle_key_bounds :: proc(midpoint: f64) -> (lb_key, ub_key: u32) {
    lb, ub := midpoint-180, midpoint+180
    lb_key, ub_key = f32_key(f32(lb)), f32_key(f32(ub))
    if f64(key_f32(lb_key)) < lb do lb_key += 1
    if f64(key_f32(ub_key)) < ub do ub_key += 1
    return
}

valid_half_angle_range :: proc(midpoint: f64, version: Minecraft_Version) -> bool {
    if !valid_facing_range(midpoint) do return false
    lb_key, ub_key := half_angle_key_bounds(midpoint)
    if lb_key >= ub_key do return false
    // Unmasked indices are monotonic, so the endpoints cover the entire range.
    for key in ([2]u32{lb_key, ub_key-1}) {
        deg := key_f32(key)
        rad := deg*f32(0.017453292) if version == .V1_21_3 else deg*f32(math.PI)/f32(180)
        s, c := f64(rad*INDEX_PER_RAD), f64(rad*INDEX_PER_RAD+RIGHT_ANGLE)
        if s < f64(min(i32)) || s > f64(max(i32)) || c < f64(min(i32)) || c > f64(max(i32)) do return false
    }
    return true
}

half_angle_facing_table :: proc(midpoint: f64, version: Minecraft_Version) -> ^Facing_Table{
    assert(valid_half_angle_range(midpoint, version))
    m := new(Facing_Table)
    m.midpoint = midpoint

    lb_key, ub_key := half_angle_key_bounds(midpoint)

    k := lb_key

    bounds: [dynamic]u32
    defer delete(bounds)

    for {
        trig := getTrig(k, version)

        append(&m.sines, sine_table[trig.s %% SINE_TABLE_SIZE])
        append(&m.cosines, sine_table[trig.c %% SINE_TABLE_SIZE])
        append(&bounds, k) 

        k = next_key(k, ub_key, version)
        if k >= ub_key do break
        
    }

    append(&bounds, ub_key)
    
    // find representitive facing degree

    n := len(m.sines)
    m.angles_count = n

    for i in 0..<n {

        lo_key, hi_key := bounds[i], bounds[i+1]

        lo_deci := (f64(key_f32(lo_key)) + f64(key_f32(lo_key - 1)))/2
        hi_deci := (f64(key_f32(hi_key)) + f64(key_f32(hi_key - 1)))/2

        scale := 1

        repr: f64 = f64(key_f32(lo_key))
        found := false

        assert(lo_deci < hi_deci)
        
        for !found {

            lo := math.ceil(lo_deci*f64(scale))
            hi := math.floor(hi_deci*f64(scale))

            safe_min := f64(min(int))
            safe_max := f64(max(int))
            if lo < safe_min || lo > safe_max ||  hi < safe_min || hi > safe_max do break

            lo_scaled := int(lo)
            hi_scaled := int(hi)

            for j in lo_scaled ..= hi_scaled {
                cand := f64(j) / f64(scale)

                key := f32_key(f32(cand))
                if key < lo_key || key >= hi_key do continue

                if !found || j %% 10 == 5 {
                    repr = cand
                    found = true
                }
            }

            if scale > max(int)/10 do break
            scale *= 10
        }
        
        append(&m.facings, repr)
    }

    return m
}

// Convert f32 to monotonically ordered u32 key
f32_key :: proc(x: f32) -> u32{

    k := transmute(u32)x
    // pos, ie MSB == 0
    if k & 0x80000000 == 0 {
        // make MSB = 1 so key(pos) > key(neg)
        return k | 0x80000000
    }else {
        // make MSB = 0
        // reverse order the neg keys by magnitude
        return ~k
    }

}

// The inverse of the function above
key_f32 :: proc(k: u32) -> f32 {
    // neg
    if k & 0x80000000 == 0 {
        return transmute(f32)(~k)
    }else {
        return transmute(f32)(k ~ 0x80000000)
    }
}


next_key :: proc(cur: u32, ub: u32, version: Minecraft_Version) -> u32{
    lo, hi := cur + 1, ub

    base_trig := getTrig(cur, version)

    for lo < hi {
        mid := lo + (hi-lo)/2
        if equal_trig(base_trig, getTrig(mid, version)) {
            lo = mid + 1
        }else {
            hi = mid
        }
    }

    return lo
}

getTrig :: proc(key: u32, version: Minecraft_Version) -> Trig {
    deg := key_f32(key)
    rad := deg*f32(0.017453292) if version == .V1_21_3 else deg*f32(math.PI)/f32(180)

    return Trig {
        s = int(rad * INDEX_PER_RAD),
        c = int(rad * INDEX_PER_RAD + RIGHT_ANGLE),
    }
}

equal_trig :: proc(a: Trig, b: Trig) -> bool{
    return (a.s == b.s && a.c == b.c)
}
