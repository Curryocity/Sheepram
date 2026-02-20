#include "parser.hpp"

#include <stdexcept>
#include <cstddef>
#include <optional>
#include <cctype>

struct Parser::Lexer{
    Lexer(const std::string& s) : input(s){}
    std::string input;
    size_t pos = 0;
    std::optional<Token> nextCache;
    
    Token next(){
        if(!nextCache)
            updateNext();
        Token t = std::move(*nextCache);
        nextCache.reset();
        return t;
    }

    const Token& peek(){
        if(!nextCache)
            updateNext();
        return *nextCache;
    }

    Token updateNext(){
        skipSpace();

        if(pos >= input.size()){
            nextCache = Token{TokenType::End, ""};
            return *nextCache;
        }

        char c = input[pos];

        if (std::isdigit(static_cast<unsigned char>(c))) {
            nextCache = number();
            return *nextCache;
        }else if (std::isalpha(static_cast<unsigned char>(c)) || c == '_') {
            nextCache = identifier();
            return *nextCache;
        }

        TokenType type;
        pos ++;
        switch(c){
            case '+': case '-': case '*': case '/':
                type = TokenType::Operator;
                break;
            case '<': case '=': case '>':
                type = TokenType::Cmp;
                break;
            case '(':
                type = TokenType::LParen;
                break;
            case ')':
                type = TokenType::RParen;
                break;
            case '[':
                type = TokenType::LBracket;
                break;
            case ']':
                type = TokenType::RBracket;
                break;
            default:
                throw std::runtime_error(
                    "Invalid Token '" + std::string(1, c) + "'"
                );
        }

        nextCache = Token{type, std::string(1, c)};
        return *nextCache;
    }

    void skipSpace(){
        while (pos < input.size() && std::isspace(static_cast<unsigned char>(input[pos]))) 
            pos ++;
    }

    Token number() {
        size_t start = pos;

        while (pos < input.size() && std::isdigit(static_cast<unsigned char>(input[pos])))
            pos ++;

        if (pos < input.size() && input[pos] == '.') {
            pos ++;
            while (pos < input.size() && std::isdigit(static_cast<unsigned char>(input[pos])))
                pos ++;
        }

        // Scientic Notation
        if (pos < input.size() && (input[pos] == 'e' || input[pos] == 'E')) {

            size_t expPos = pos;
            pos++;

            if (pos < input.size() && (input[pos] == '+' || input[pos] == '-')) 
                pos ++;

            if (pos >= input.size() || !std::isdigit(static_cast<unsigned char>(input[pos]))) 
                throw std::runtime_error("Invalid scientific notation");

            while (pos < input.size() && std::isdigit(static_cast<unsigned char>(input[pos]))) 
                pos ++;
        }

        return Token{
            TokenType::Number,
            input.substr(start, pos - start)
        };
    }

    Token identifier(){
        size_t start = pos;
        
        while (pos < input.size() && (std::isalnum(static_cast<unsigned char>(input[pos])) || input[pos] == '_')) 
            pos++;

        return Token{
        TokenType::Identifier,
        input.substr(start, pos - start)
        };
    }
    
};

Parser::Constraint Parser::parse(const std::string& s){

}

