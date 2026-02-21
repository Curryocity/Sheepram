#pragma once

#include <string>
#include <unordered_map>
#include "optimizer.hpp"

using Expr = optimizer::CompiledExpr;

class Parser{

    public:

    Parser(const optimizer::Model& m, std::vector<std::string> names, std::vector<std::string> values)  : model(m){
        buildVarMap(names, values);
    }

    struct Constraint{
        // rhs is 0 in standard form
        // Always covert Greater to Less, Greater is an intermediate state used in parsing
        enum Cmp {Equal, Less, Greater};
        Expr lhs; 
        Cmp cmp;
    };

    std::vector<Parser::Constraint> parseMultiline(const std::string& input);

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

    void buildVarMap(const std::vector<std::string>& names, const std::vector<std::string>& values);
    Expr resolveIndexed(char c, int index);

    Constraint::Cmp convertCmp(const Token& cmpTok);
    Constraint parse(const std::string& s);
    Expr parseExpr(Lexer& lex, int minBP);
    Expr parseNumber(const Token& tok);
    Expr parseIdentifier(Lexer& lex, const Token& tok);

    Expr combineExpr(const Expr& lhs, const Expr& rhs, const Token& op);
    Expr scaleExpr(const Expr& e, double s);

    BP getBP(const Token& op);

};