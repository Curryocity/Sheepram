#pragma once

#include <string>
#include <unordered_map>
#include "optimizer.hpp"

using Cons = optimizer::Constraint;
using Expr = optimizer::CompiledExpr;

class Parser{

    public:

    Parser(const optimizer::Model& m, std::vector<std::string> names, std::vector<std::string> values)  : model(m){
        buildVarMap(m.n - 1, m.initV, names, values);
    }

    std::vector<Cons> parseMultiConstraints(const std::string& input);
    Expr parseExpr(const std::string& s);
    double parseConstant(const std::string& s);
    Expr scaleExpr(const Expr& e, double s);

    private:

    const optimizer::Model& model;
    std::unordered_map<std::string,double> varMap;

    enum class TokenType {
        Number,
        Identifier,
        Operator,
        Cmp,
        LParen,
        RParen,
        LBracket,
        RBracket,
        End
    };

    struct Token {
        TokenType type;
        std::string text;  
    };

    struct Lexer;

    struct BP {
        int left;
        int right;
    };

    void buildVarMap(int globalN, double initV, const std::vector<std::string>& names, const std::vector<std::string>& values);
    Expr resolveIndexed(char c, int index);

    Cons parseConstraint(const std::string& s);

    Expr parseExpr(Lexer& lex, int minBP);
    Expr parseNumber(const Token& tok);
    Expr parseIdentifier(Lexer& lex, const Token& tok);

    Expr combineExpr(const Expr& lhs, const Expr& rhs, const Token& op);
    
    BP getBP(const Token& op);

};