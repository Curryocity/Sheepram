package optimizer

Matrix :: struct {
	n:    int,
	data: [dynamic]f64,
}

matrix_make :: proc(n: int) -> Matrix {
	return Matrix{n = n, data = make([dynamic]f64, n*n)}
}

matrix_destroy :: proc(mtx: ^Matrix) {
	delete(mtx.data)
	mtx^ = {}
}

matrix_at :: proc(mtx: ^Matrix, i, j: int) -> ^f64 {
	return &mtx.data[i*mtx.n+j]
}

matrix_set_identity :: proc(mtx: ^Matrix) {
	for &value in mtx.data do value = 0
	for i in 0..<mtx.n {
		matrix_at(mtx, i, i)^ = 1
	}
}

matrix_mul :: proc(mtx: ^Matrix, v: []f64) -> [dynamic]f64 {
	product := make([dynamic]f64, mtx.n)
	for i in 0..<mtx.n {
		sum := 0.0
		for j in 0..<mtx.n {
			sum += matrix_at(mtx, i, j)^*v[j]
		}
		product[i] = sum
	}
	return product
}

matrix_add_outer_product :: proc(mtx: ^Matrix, a, b: []f64, s: f64) {
	for i in 0..<mtx.n {
		for j in 0..<mtx.n {
			matrix_at(mtx, i, j)^ += s*a[i]*b[j]
		}
	}
}

matrix_add_symmetrical_outer :: proc(mtx: ^Matrix, a, b: []f64, s: f64) {
	for i in 0..<mtx.n {
		for j in 0..<mtx.n {
			matrix_at(mtx, i, j)^ += s*(a[i]*b[j]+a[j]*b[i])
		}
	}
}

scale_vector :: proc(vec: []f64, s: f64) {
	for &x in vec do x *= s
}

set_scaled :: proc(out, source: []f64, s: f64) {
	for i in 0..<len(out) do out[i] = s*source[i]
}

add_scaled :: proc(out, source: []f64, s: f64) {
	for i in 0..<len(out) do out[i] += s*source[i]
}

dot :: proc(a, b: []f64) -> f64 {
	sum := 0.0
	for i in 0..<len(a) do sum += a[i]*b[i]
	return sum
}
