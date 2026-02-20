#pragma once


#include <string>
#include "optimizer.hpp"

class Parser{

    public:
    struct Constraint{
        enum Cmp {Equal, Less, Greater};
        optimizer::LinearExpr lhs;
        Cmp cmp;
        optimizer::LinearExpr rhs;
    };

    Constraint parse(const std::string& s);

    private:
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

};