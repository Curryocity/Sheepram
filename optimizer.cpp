#include <algorithm>
#include <cmath>
#include <limits>
#include "optimizer.hpp"

std::vector<double> optimizer::global_temp_g;
std::vector<double> optimizer::sin_cache;
std::vector<double> optimizer::cos_cache;

struct Matrix {
    explicit Matrix(int n_) : n(n_), data(n_ * n_, 0.0) {}

    double& operator()(int i, int j) { return data[i * n + j]; }
    const double& operator()(int i, int j) const { return data[i * n + j]; }

    void setIdentity() {
        std::fill(data.begin(), data.end(), 0.0);
        for (int i = 0; i < n; i++)  (*this)(i, i) = 1.0;
    }

    std::vector<double> operator*(const std::vector<double>& v) const {
        std::vector<double> product(n, 0.0);
        for (int i = 0; i < n; i++) {
            double sum = 0.0;
            for (int j = 0; j < n; ++j) 
                sum += (*this)(i, j) * v[j];
            product[i] = sum;
        }
        return product;
    }

    void addOuterProduct(const std::vector<double>& a, const std::vector<double>& b, double s) {
        for (int i = 0; i < n; i++) 
            for (int j = 0; j < n; ++j) 
                (*this)(i, j) += s * a[i] * b[j];
    }

    void addSymmetricalOuter(const std::vector<double>& a, const std::vector<double>& b, double s) {
        for (int i = 0; i < n; i++) 
            for (int j = 0; j < n; ++j) 
                (*this)(i, j) += s * (a[i] * b[j] + a[j] * b[i]);
    }

    int n;
    std::vector<double> data;
};


void optimizer::addScaled(CompiledExpr& out, const CompiledExpr& in, double s) {
    // out += s * in
    const int n = static_cast<int>(out.thetaCoeff.size());
    out.constant += s * in.constant;
    for (int i = 0; i < n; i++) {
        out.thetaCoeff[i] += s * in.thetaCoeff[i];
        out.sinCoeff[i] += s * in.sinCoeff[i];
        out.cosCoeff[i] += s * in.cosCoeff[i];
    }
}

void optimizer::scale(std::vector<double>& vec, double s) {
    for (double& x : vec) x *= s;
}

void optimizer::setScaled(std::vector<double>& out, const std::vector<double>& in, double s) {
    const int n = static_cast<int>(out.size());
    for (int i = 0; i < n; i++) out[i] = s * in[i];
}

void optimizer::addScaled(std::vector<double>& out, const std::vector<double>& in, double s) {
    const int n = static_cast<int>(out.size());
    for (int i = 0; i < n; i++) out[i] += s * in[i];
}

double optimizer::dot(const std::vector<double>& a, const std::vector<double>& b) {
    const int n = static_cast<int>(a.size());
    double sum = 0.0;
    for (int i = 0; i < n; i++) sum += a[i] * b[i];
    return sum;
}

void optimizer::updateTrigCache(const std::vector<double>& thetas) {
    const int n = static_cast<int>(thetas.size());
    for (int i = 0; i < n; i++) {
        sin_cache[i] = std::sin(thetas[i]);
        cos_cache[i] = std::cos(thetas[i]);
    }
}

double optimizer::eval(const CompiledExpr& expr, const std::vector<double>& thetas) {
    const int n = static_cast<int>(thetas.size());
    double val = expr.constant;
    for (int i = 0; i < n; i++) {
        val += expr.thetaCoeff[i] * thetas[i] +
               expr.sinCoeff[i] * sin_cache[i] +
               expr.cosCoeff[i] * cos_cache[i];
    }
    return val;
}

void optimizer::grad(const CompiledExpr& e, const std::vector<double>& thetas, std::vector<double>& g) {
    const int n = static_cast<int>(thetas.size());
    g.assign(n, 0.0);
    for (int i = 0; i < n; i++) {
        g[i] =
            e.thetaCoeff[i] +
            e.sinCoeff[i] * cos_cache[i] -
            e.cosCoeff[i] * sin_cache[i];
    }
}

void optimizer::compileModel(Model& model) {
    const int n = model.n;
    model.Vx.assign(n, CompiledExpr(n));
    model.Vz.assign(n, CompiledExpr(n));
    model.X.assign(n, CompiledExpr(n));
    model.Z.assign(n, CompiledExpr(n));

    for (int t = 0; t < n; ++t) {
        initCompExpr(model.Vx[t], n);
        initCompExpr(model.Vz[t], n);
        initCompExpr(model.X[t], n);
        initCompExpr(model.Z[t], n);
    }

    // Generate Vx, Vz
    // InitVx = initV * sin(F[0]), initVz = initV * cos(F[0])
    model.Vx[0].sinCoeff[0] = model.initV;
    model.Vz[0].cosCoeff[0] = model.initV;
    for (int t = 1; t < n; ++t) {
        // v[t] = drag[t-1] * v[t-1] + accel[t] * trig(F[t])
        addScaled(model.Vx[t], model.Vx[t - 1], model.dragX[t - 1]);
        addScaled(model.Vz[t], model.Vz[t - 1], model.dragZ[t - 1]);
        model.Vx[t].sinCoeff[t] = model.accel[t];
        model.Vz[t].cosCoeff[t] = model.accel[t];
    }

    // Generate X, Z
    // pos[0] = 0, pos[t] = pos[t-1] + v[t-1]
    for (int t = 1; t < n; ++t) {
        addScaled(model.X[t], model.X[t - 1], 1.0);
        addScaled(model.X[t], model.Vx[t - 1], 1.0);
        addScaled(model.Z[t], model.Z[t - 1], 1.0);
        addScaled(model.Z[t], model.Vz[t - 1], 1.0);
    }
}

optimizer::CompiledExpr optimizer::compile(const LinearExpr& expr, const Model& model) {
    // Compile expression into linear function of F, sin F, cos F
    const int n = model.n;
    CompiledExpr out(n);
    out.constant = expr.constant;

    for (const auto& term : expr.terms) {
        const int t = term.tick;
        const double c = term.coeff;

        if (term.type == Term::F) {
            out.thetaCoeff[t] += c;
        } else if (term.type == Term::X) {
            addScaled(out, model.X[t], c);
        } else if (term.type == Term::Z) {
            addScaled(out, model.Z[t], c);
        }
    }

    return out;
}

optimizer::Problem optimizer::buildProblem(const Model& model, const LinearExpr& objectiveMinimize, const std::vector<Constraint>& constraints) {
    Problem p;
    p.n = model.n;
    p.objective = compile(objectiveMinimize, model);

    for (const auto& c : constraints) {
        CompiledExpr ce = compile(c.expr, model);
        if (c.type == Constraint::Equal) {
            p.eqCons.push_back(ce);
        } else if (c.type == Constraint::Less) {
            p.ineqCons.push_back(ce);
        } else {
            // Convert expr >= 0 to -expr <= 0
            for (double& x : ce.thetaCoeff) x = -x;
            for (double& x : ce.sinCoeff) x = -x;
            for (double& x : ce.cosCoeff) x = -x;
            
            ce.constant = -ce.constant;
            p.ineqCons.push_back(ce);
        }
    }

    return p;
}

optimizer::Solution optimizer::optimize(const Model& model, const Problem& prob) {
    const int n = model.n;
    global_temp_g.assign(n, 0.0);
    sin_cache.assign(n, 0.0);
    cos_cache.assign(n, 0.0);

    std::vector<double> thetas(n, 0.0);
    std::vector<double> lamb(prob.ineqCons.size(), 0.0); // "lambda" in inequality
    std::vector<double> nu(prob.eqCons.size(), 0.0);     // "nu" in equality
    double pen = 1.0;  // Penalty for "A" in "ALM"

    const double tarVio = 1e-7; // Constraint violation threshold; below? -> Leave Outer Loop
    double maxVio = std::numeric_limits<double>::infinity();
    double prevMaxVio = maxVio;

    const int maxOuter = 25;
    for (int outer = 0; outer < maxOuter; ++outer) {
        // [Outer Loop]: Augmented Lagrangian Method
        BFGS(thetas, prob, lamb, nu, pen);

        // Update multipliers
        double max_gi = 0.0;
        double max_hj = 0.0;
        updateTrigCache(thetas);

        for (int i = 0; i < static_cast<int>(prob.ineqCons.size()); i++) {
            const double gi = eval(prob.ineqCons[i], thetas);
            lamb[i] = std::max(0.0, lamb[i] + pen * gi);
            max_gi = std::max(max_gi, std::max(0.0, gi));
        }
        for (int j = 0; j < static_cast<int>(prob.eqCons.size()); ++j) {
            const double hj = eval(prob.eqCons[j], thetas);
            nu[j] += pen * hj;
            max_hj = std::max(max_hj, std::abs(hj));
        }
        maxVio = std::max(max_gi, max_hj);

        // Check Feasibility
        if (maxVio < tarVio) break;
        
        // Increase penalty if violation didn't decrease enough
        // The exact parameters here are questionable but works fine at the moment
        if (maxVio > 0.5 * prevMaxVio) 
            pen *= 2.0;
        
        prevMaxVio = maxVio;
    }

    // Write solution
    Solution sol;
    sol.thetas = thetas;
    updateTrigCache(thetas);
    sol.bestValue = eval(prob.objective, thetas);
    sol.Xs.assign(n, 0.0);
    sol.Zs.assign(n, 0.0);
    for (int i = 0; i < n; i++) {
        sol.Xs[i] = eval(model.X[i], thetas);
        sol.Zs[i] = eval(model.Z[i], thetas);
    }

    return sol;
}

void optimizer::BFGS(std::vector<double>& thetas, const Problem& prob, const std::vector<double>& lamb, const std::vector<double>& nu, double pen) {
    const int n = prob.n;
    Matrix H(n);
    H.setIdentity();

    std::vector<double> grad_vec(n, 0.0);
    std::vector<double> grad_new(n, 0.0);

    double val = computeAugL(grad_vec, thetas, prob, lamb, nu, pen);

    const double tarGrad = 1e-9; // Gradient norm threshold; below? -> Leave Inner Loop
    const int maxInner = 100;
    for (int inner = 0; inner < maxInner; ++inner) {
        // [Inner Loop]: Optimize Augmented Lagrangian via BFGS
        if (dot(grad_vec, grad_vec) < tarGrad * tarGrad) break;
        
        std::vector<double> step = H * grad_vec;
        scale(step, -1.0);

        double deri = dot(grad_vec, step);
        if (deri >= 0.0) {
            // Fallback to gradient descent
            setScaled(step, grad_vec, -1.0);
            deri = dot(grad_vec, step);
        }

        const double alpha = lineSearch(thetas, prob, lamb, nu, pen, step, val, deri);
        scale(step, alpha);
        // Modify/update thetas by step
        addScaled(thetas, step, 1.0);

        const double val_new = computeAugL(grad_new, thetas, prob, lamb, nu, pen);
        std::vector<double> curv(n, 0.0);
        for (int i = 0; i < n; i++) {
            curv[i] = grad_new[i] - grad_vec[i];
        }

        double a = dot(step, curv);
        const double ss = dot(step, step);
        const double cc = dot(curv, curv);
        // a < 0 -> violate positive definiteness
        // cos(angle between step and curv) <= 1e-12 -> curvature information is unreliable
        const double eps = 1e-12;
        if (a * a <= (eps * eps) * ss * cc) {
            grad_vec = grad_new;
            val = val_new;
            continue;
        }

        a = 1.0 / a;
        std::vector<double> step_approx = H * curv;
        H.addSymmetricalOuter(step, step_approx, -a);
        const double b = a * (1.0 + a * dot(step_approx, curv));
        H.addOuterProduct(step, step, b);

        grad_vec = grad_new;
        val = val_new;
    }
}

double optimizer::computeAugL(std::vector<double>& gOut, const std::vector<double>& thetas, const Problem& prob, const std::vector<double>& lamb, const std::vector<double>& nu, double pen) {
    // Evaluates Augmented Lagrangian's value & gradient
    updateTrigCache(thetas);

    double value = eval(prob.objective, thetas);
    grad(prob.objective, thetas, gOut);

    for (int i = 0; i < static_cast<int>(prob.ineqCons.size()); i++) {
        const CompiledExpr& ineq = prob.ineqCons[i];
        const double v_ineq = eval(ineq, thetas);
        grad(ineq, thetas, global_temp_g);

        const double t = std::max(0.0, lamb[i] + v_ineq * pen);
        value += 0.5 / pen * (t * t - lamb[i] * lamb[i]);
        addScaled(gOut, global_temp_g, t);
    }

    for (int j = 0; j < static_cast<int>(prob.eqCons.size()); ++j) {
        const CompiledExpr& eq = prob.eqCons[j];
        const double v_eq = eval(eq, thetas);
        grad(eq, thetas, global_temp_g);

        value += nu[j] * v_eq;
        value += 0.5 * pen * v_eq * v_eq;
        addScaled(gOut, global_temp_g, nu[j] + pen * v_eq);
    }

    return value;
}

// Strong Wolfe, weaker version of scipy/optimize/_line_search: "scalar_search_wolfe2()"
double optimizer::lineSearch(const std::vector<double>& thetas, const Problem& prob, const std::vector<double>& lamb, const std::vector<double>& nu, double pen, const std::vector<double>& step, double val, double deri) {
    
    const int n = prob.n;

    double base = 0.0;
    double alpha = 1.0;
    const double c1 = 1e-4;
    const double c2 = 0.9;

    double val_prev = val;
    std::vector<double> temp_grad(n, 0.0);
    std::vector<double> trial(n, 0.0);

    const auto phi = [&](double alpha_in, std::vector<double>& gradOut) {
        for (int i = 0; i < n; i++) {
            trial[i] = thetas[i] + alpha_in * step[i];
        }
        return computeAugL(gradOut, trial, prob, lamb, nu, pen);
    };

    const auto zoom = [&](double lo, double hi) {
        double val_lo = phi(lo, temp_grad);
        const int maxZoomIter = 20;
        for (int iter = 0; iter < maxZoomIter; ++iter) {
            const double mid = 0.5 * (lo + hi);
            const double val_mid = phi(mid, temp_grad);

            // Armijo fail or Value increase -> Step too large -> zoom(lo, mid)
            if (val_mid > val + c1 * mid * deri || val_mid >= val_lo) {
                hi = mid;
            } else {
                // Curvature satisfied -> accept mid
                const double deri_mid = dot(temp_grad, step);
                if (std::abs(deri_mid) <= -c2 * deri) {
                    return mid;
                }
                // zoom(mid, hi)
                lo = mid;
                val_lo = val_mid;
            }
        }
        return 0.5 * (lo + hi);
    };

    const int maxBracketIter = 20;
    for (int iter = 0; iter < maxBracketIter; ++iter) {
        // Armijo fail -> zoom
        const double val_alpha = phi(alpha, temp_grad);
        if (val_alpha > val + c1 * alpha * deri) 
            return zoom(base, alpha);
        
        // Value increase -> zoom
        if (base > 0.0 && val_alpha >= val_prev) 
            return zoom(base, alpha);
        
        // Curvature satisfied -> accept alpha
        const double deri_alpha = dot(temp_grad, step);
        if (std::abs(deri_alpha) <= -c2 * deri) 
            return alpha;
        
        // Derivative became positive -> zoom
        if (deri_alpha >= 0.0) 
            return zoom(base, alpha);
        
        val_prev = val_alpha;
        base = alpha;
        alpha *= 2.0;
    }

    return alpha;
}
