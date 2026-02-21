#pragma once

#include <vector>

struct optimizer {
    struct CompiledExpr {
        CompiledExpr(){}
        CompiledExpr(int n){
            zero(n);
        }
        double constant = 0.0;
        std::vector<double> thetaCoeff;
        std::vector<double> sinCoeff;
        std::vector<double> cosCoeff;

        void zero(int n){
            constant = 0.0;
            thetaCoeff.assign(n, 0.0);
            sinCoeff.assign(n, 0.0);
            cosCoeff.assign(n, 0.0);
        }

        static constexpr double EPS = 1e-12;

        bool isConstant() const {
            for (size_t i = 0; i < thetaCoeff.size(); ++i) {
                if (std::abs(thetaCoeff[i]) > EPS) return false;
                if (std::abs(sinCoeff[i])   > EPS) return false;
                if (std::abs(cosCoeff[i])   > EPS) return false;
            }
            return true;
        }
    };

    struct Term {
        enum Type { F, X, Z };
        Type type;
        int tick;
        double coeff = 1.0;
    };

    struct LinearExpr {
        std::vector<Term> terms;
        double constant = 0.0;
    };

    struct Constraint {
        enum Cmp { Equal, Less, Greater };
        Cmp type;
        LinearExpr expr;
    };

    struct Model {
        // Require initialization
        int n = 0;
        double initV = 0.0;
        std::vector<double> dragX;
        std::vector<double> dragZ;
        std::vector<double> accel;

        // Compile later
        std::vector<CompiledExpr> Vx;
        std::vector<CompiledExpr> Vz;
        std::vector<CompiledExpr> X;
        std::vector<CompiledExpr> Z;
    };

    struct Problem {
        int n = 0;
        // Assuming minimize, TODO: support maximize
        CompiledExpr objective;
        // Constraints
        std::vector<CompiledExpr> ineqCons;
        std::vector<CompiledExpr> eqCons;
    };

    struct Solution {
        double bestValue = 0.0;
        std::vector<double> thetas;
        std::vector<double> Xs;
        std::vector<double> Zs;
    };

    static void compileModel(Model& model);
    static Problem buildProblem(const Model& model, const LinearExpr& objectiveMinimize, const std::vector<Constraint>& constraints);
    static Solution optimize(const Model& model, const Problem& prob);

private:
    static std::vector<double> global_temp_g;
    static std::vector<double> sin_cache;
    static std::vector<double> cos_cache;

    static void initCompExpr(CompiledExpr& expr, int n);
    static void addScaled(CompiledExpr& out, const CompiledExpr& in, double s);
    static void scale(std::vector<double>& vec, double s);
    static void setScaled(std::vector<double>& out, const std::vector<double>& in, double s);
    static void addScaled(std::vector<double>& out, const std::vector<double>& in, double s);
    static double dot(const std::vector<double>& a, const std::vector<double>& b);
    static void updateTrigCache(const std::vector<double>& thetas);
    static double eval(const CompiledExpr& expr, const std::vector<double>& thetas);
    static void grad(const CompiledExpr& e, const std::vector<double>& thetas, std::vector<double>& g);
    static CompiledExpr compile(const LinearExpr& expr, const Model& model);
    static void BFGS(std::vector<double>& thetas, const Problem& prob, const std::vector<double>& lamb, const std::vector<double>& nu, double pen);
    static double computeAugL(std::vector<double>& gOut, const std::vector<double>& thetas, const Problem& prob, const std::vector<double>& lamb, const std::vector<double>& nu, double pen);
    static double lineSearch(const std::vector<double>& thetas, const Problem& prob, const std::vector<double>& lamb, const std::vector<double>& nu, double pen, const std::vector<double>& step, double val, double deri);
};
