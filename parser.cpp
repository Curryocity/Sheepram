#include "parser.hpp"
#include "optimizer.hpp"

#include <cmath>
#include <stdexcept>
#include <cstddef>
#include <optional>
#include <cctype>
#include <string>

using Expr = optimizer::CompiledExpr;

struct Parser::Lexer{
    Lexer(const std::string& s) : input(s){}

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

    private:

    std::string input;
    size_t pos = 0;
    std::optional<Token> nextCache;

    void skipSpace(){
        while (pos < input.size() && std::isspace(static_cast<unsigned char>(input[pos]))) 
            pos ++;
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

std::vector<Parser::Constraint> Parser::parseMultiline(const std::string& input){
    std::vector<Constraint> constraints;

    size_t start = 0;

    while (start < input.size()) {

        // Find end of line
        size_t end = input.find('\n', start);
        if (end == std::string::npos)
            end = input.size();

        std::string line = input.substr(start, end - start);

        // Strip comment
        size_t commentPos = line.find("//");
        if (commentPos != std::string::npos)
            line = line.substr(0, commentPos);

        // Trim whitespace
        auto trim = [](std::string& s) {
            size_t l = 0;
            while (l < s.size() && std::isspace((unsigned char)s[l])) l++;

            size_t r = s.size();
            while (r > l && std::isspace((unsigned char)s[r - 1])) r--;

            s = s.substr(l, r - l);
        };

        trim(line);

        if (!line.empty()) {
            constraints.push_back(parse(line));
        }

        start = end + 1;
    }

    return constraints;
}

void Parser::buildVarMap(const std::vector<std::string>& names, const std::vector<std::string>& values){
    varMap.clear();
    int m = names.size();
    for(int i = 0; i < m; i++){
        const std::string& value = values[i];
        const std::string& name = names[i];
        if (name.empty())
            continue;
        if(value.empty()) 
            throw std::runtime_error{names[i] + " has no definition"};

        Lexer lex(value);
        Expr e = parseExpr(lex, 0);
        if (lex.peek().type != TokenType::End)
            throw std::runtime_error{"Invalid expression in definition of " + name};
        if(!e.isConstant()) throw std::runtime_error{"Unable to reduce '" + name + "' to a constant."};

        double v = e.constant;
        this -> varMap[name] = v;
    }
}

Expr Parser::resolveIndexed(char c, int index){
    switch(c){
        case 'X':
            return model.X[index];
        case 'Z':
            return model.Z[index];
        case 'F':
            Expr e(model.n);
            e.thetaCoeff[index] = 1;
            return e;  
    }
    throw std::runtime_error{"Bug: This shouldn't happen cuz I checked the identifier name already."};
}

Parser::Constraint Parser::parse(const std::string& s){
    Lexer lex(s);
    Expr lhs = parseExpr(lex, 0);

    Token cmpTok = lex.next();
    if(cmpTok.type != TokenType::Cmp)
        throw std::runtime_error(
            "Expected comparison operator, got '" + cmpTok.text + "'"
        );

    Constraint::Cmp cmp = convertCmp(cmpTok);

    Expr rhs = parseExpr(lex, 0);

    if (lex.peek().type != TokenType::End)
        throw std::runtime_error("Unexpected trailing tokens");

    Token minusTok{TokenType::Operator, "-"};

    Expr stdForm;
    Constraint::Cmp stdType;

    switch (cmp) {
        case Constraint::Less:
            // lhs < rhs  ->  lhs - rhs <= 0
            stdForm = combineExpr(lhs, rhs, minusTok);
            stdType = Constraint::Less;
            break;

        case Constraint::Greater:
            // lhs > rhs  -> rhs - lhs <= 0
            stdForm = combineExpr(rhs, lhs, minusTok);
            stdType = Constraint::Less;
            break;

        case Constraint::Equal:
            // lhs = rhs -> lhs - rhs == 0
            stdForm = combineExpr(lhs, rhs, minusTok);
            stdType = Constraint::Equal;
            break;
    }

    return Constraint{stdForm, stdType};
}

Parser::Constraint::Cmp Parser::convertCmp(const Token& cmpTok){
    if(cmpTok.text.size() != 1) throw std::runtime_error("Unknown Cmp Token: " + cmpTok.text);
    switch (cmpTok.text[0]) {
        case '<':
            return Constraint::Less;
        case '=':
            return Constraint::Equal;
        case '>':
            return Constraint::Greater;
        default:
            throw std::runtime_error("Unknown Cmp Token: " + cmpTok.text);
    }
}

// Pratt Parser IS THE BEST
Expr Parser::parseExpr(Lexer& lex, int minBP){
    Expr lhs;

    Token prefix = lex.next();
    switch (prefix.type) {

        case TokenType::Number:
            lhs = parseNumber(prefix);
            break;

        case TokenType::Identifier:
            lhs = parseIdentifier(lex, prefix);
            break;

        case TokenType::Operator:
            if (prefix.text == "-") {
                const int prefixBP = 30;
                Expr rhs = parseExpr(lex, prefixBP);
                lhs = scaleExpr(rhs, -1);
                break;
            }
            throw std::runtime_error("Invalid prefix operator");

        case TokenType::LParen:
            lhs = parseExpr(lex, 0);
            if (lex.next().type != TokenType::RParen)
                throw std::runtime_error("Missing ')'");
            break;

        default:
            throw std::runtime_error("Invalid prefix token: " + prefix.text);
    }


    while(true){
        Token op = lex.peek();
        if(op.type != TokenType::Operator)
            break;

        BP baseBP = getBP(op);

        if(baseBP.left < minBP) break;
        lex.next(); // Consume operator

        Expr rhs = parseExpr(lex, baseBP.right);

        lhs = combineExpr(lhs, rhs, op);
    }

    return lhs;
}

Expr Parser::parseNumber(const Token& tok){
    Expr e(model.n);
    e.constant = std::stod(tok.text);
    return e;
}

Expr Parser::parseIdentifier(Lexer& lex, const Token& tok){
    if(tok.text == "X" || tok.text == "Z" || tok.text == "F"){
        
        if(lex.next().type != TokenType::LBracket)
            throw std::runtime_error("Expected '[' after " + tok.text);

        Expr index = parseExpr(lex, 0);

        if(lex.next().type != TokenType::RBracket)
            throw std::runtime_error("Missing ']'");

        if(!index.isConstant())
            throw std::runtime_error("Index must be constant");

        int idx = (int) std::round(index.constant);

        if (idx < 0 || idx >= model.n)
            throw std::runtime_error("Index out of range");

        return resolveIndexed(tok.text[0], idx);
    }else{ // Variables
        if (varMap.contains(tok.text)) {
            double v = varMap.at(tok.text);
            Expr e(model.n);
            e.constant = v;
            return e;
        }else{
            throw std::runtime_error{"Identifier " + tok.text + " is undefined."};
        }
    }
}

Expr Parser::combineExpr(const Expr& lhs, const Expr& rhs, const Token& op) {
    const std::string& s = op.text;

    auto add = [&](double signRhs) {
        Expr out = lhs;
        out.constant += signRhs * rhs.constant;
        for (size_t i = 0; i < out.thetaCoeff.size(); ++i) {
            out.thetaCoeff[i] += signRhs * rhs.thetaCoeff[i];
            out.sinCoeff[i]   += signRhs * rhs.sinCoeff[i];
            out.cosCoeff[i]   += signRhs * rhs.cosCoeff[i];
        }
        static constexpr double EPS = 1e-12;
        for (size_t i = 0; i < out.thetaCoeff.size(); ++i) {
            if (std::abs(out.thetaCoeff[i]) < EPS) out.thetaCoeff[i] = 0.0;
            if (std::abs(out.sinCoeff[i])   < EPS) out.sinCoeff[i]   = 0.0;
            if (std::abs(out.cosCoeff[i])   < EPS) out.cosCoeff[i]   = 0.0;
        }
        if (std::abs(out.constant) < EPS) out.constant = 0.0;
        return out;
    };

    if (s == "+") return add(+1.0);
    if (s == "-") return add(-1.0);

    if (s == "*") {
        const bool lc = lhs.isConstant();
        const bool rc = rhs.isConstant();

        if (lc && rc) {
            Expr out(model.n);
            out.constant = lhs.constant * rhs.constant;
            return out;
        }
        if (lc) return scaleExpr(rhs, lhs.constant);
        if (rc) return scaleExpr(lhs, rhs.constant);

        throw std::runtime_error("Nonlinear multiplication is not allowed");
    }

    if (s == "/") {
        const bool rc = rhs.isConstant();
        if (!rc) throw std::runtime_error("Division by non-constant is not allowed");
        if (rhs.constant == 0.0) throw std::runtime_error("Division by zero");
        return scaleExpr(lhs, 1.0 / rhs.constant);
    }

    throw std::runtime_error("Unknown operator: " + op.text);
}

Expr Parser::scaleExpr(const Expr& e, double s) {
    Expr out = e;
    out.constant *= s;
    for (size_t i = 0; i < out.thetaCoeff.size(); ++i) {
        out.thetaCoeff[i] *= s;
        out.sinCoeff[i]   *= s;
        out.cosCoeff[i]   *= s;
    }
    return out;
}


Parser::BP Parser::getBP(const Token& op){
    if(op.text == "+" || op.text == "-")
        return {10, 11};

    if(op.text == "*" || op.text == "/")
        return {20, 21};

    throw std::runtime_error("Unknown operator");
}

