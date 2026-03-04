#pragma once

#include <string>
#include <stdexcept>
#include <unordered_map>
#include "optimizer.hpp"

using Cons = optimizer::Constraint;
using Expr = optimizer::CompiledExpr;

class Parser{

    public:

    Parser(const optimizer::Model& m)  : model(m){
        this -> varMap.clear();
        this -> varMap["n"] = m.n - 1;
    }

    void defineInitV(double initV);
    void addVariable(std::string& name, const std::string& value);
    void addVariables(const std::vector<std::string>& names, const std::vector<std::string>& values);
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

    
    Expr resolveIndexed(const std::string& s, int index, const Lexer& lex);

    Cons parseConstraint(const std::string& s);

    Expr parseExpr(Lexer& lex, int minBP);
    Expr parseNumber(const Token& tok);
    Expr parseIdentifier(Lexer& lex, const Token& tok);

    Expr combineExpr(const Expr& lhs, const Expr& rhs, const Token& op, const Lexer& lex);
    
    BP getBP(const Token& op);

    std::runtime_error error(const std::string& msg, const Lexer& lex);

};
