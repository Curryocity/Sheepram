#include "parser.hpp"
#include "optimizer.hpp"

#include <cmath>
#include <numbers>
#include <stdexcept>
#include <cstddef>
#include <optional>
#include <cctype>
#include <string>

using Cons = optimizer::Constraint;
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

    size_t getPos() const { return pos; }

    std::string getContent() const { return input;}

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

// Trim whitespace
static void trim(std::string& s){
    size_t l = 0;
    while (l < s.size() && std::isspace((unsigned char)s[l])) l++;

    size_t r = s.size();
    while (r > l && std::isspace((unsigned char)s[r - 1])) r--;

    s = s.substr(l, r - l);
}

std::vector<Cons> Parser::parseMultiConstraints(const std::string& input){
    std::vector<Cons> constraints;

    size_t start = 0;
    int lineCount = 1;

    while (start < input.size()) {

        // Find end of line
        size_t end = input.find('\n', start);
        if (end == std::string::npos)
            end = input.size();

        std::string line = input.substr(start, end - start);
        std::string rawLine = line;

        // Strip comment
        size_t commentPos = line.find("//");
        if (commentPos != std::string::npos)
            line = line.substr(0, commentPos);

        trim(line);

        if (!line.empty()) {
            try {
                constraints.push_back(parseConstraint(line));
            } catch (const std::exception& e) {
                throw std::runtime_error(
                    "At constraint line " + std::to_string(lineCount) + ":\n  " +
                    "Reason: " + std::string(e.what())
                );
            }
        }

        start = end + 1;
        lineCount ++;
    }

    return constraints;
}

void Parser::defineInitV(double initV){
    this -> varMap["initV"] = initV;
};

void Parser::addVariable(std::string& name, const std::string& value){
    trim(name);
    if (name.empty())
        return;
    if(!std::isalpha(name[0]) && name[0] != '_')
            throw std::runtime_error{name + " is an illegal name"};
    if(name == "n" || name == "initV" || name == "X" || name == "Z" || name == "F" || name == "Vx" || name == "Vz" || name == "T")
        throw std::runtime_error{name + " is a reserved keyword"};
    if(value.empty()) 
        throw std::runtime_error{name + " has no definition"};

    Lexer lex(value);
    Expr e = parseExpr(lex, 0);
    if (lex.peek().type != TokenType::End)
        throw error("Invalid expression in definition of " + name, lex);
    if(!e.isConstant()) throw std::runtime_error{"Unable to reduce '" + name + "' to a constant."};

    double v = e.constant;
    this -> varMap[name] = v;
}

void Parser::addVariables(const std::vector<std::string>& names, const std::vector<std::string>& values){

    int m = names.size();
    for(int i = 0; i < m; i++){
        const std::string& value = values[i];
        std::string name = names[i];
        addVariable(name, value);
    }
}

Expr Parser::resolveIndexed(const std::string& s, int index, const Lexer& lex){
    Token minusTok{TokenType::Operator, "-"};
    auto boundCheck = [&](int idx, int size) {
        if (idx < 0 || idx >= size) 
            throw error(s + "[" + std::to_string(index) + "] is out of range", lex);
    };

    if (s == "X") {
        boundCheck(index, model.X.size());
        return model.X.at(index);
    }
    if (s == "Z") {
        boundCheck(index, model.Z.size());
        return model.Z.at(index);
    }
    if (s == "Vx") {
        boundCheck(index, model.X.size() - 1);
        return combineExpr(model.X.at(index + 1), model.X.at(index), minusTok, lex);
    }
    if (s == "Vz") {
        boundCheck(index, model.Z.size() - 1);
        return combineExpr(model.Z.at(index + 1), model.Z.at(index), minusTok, lex);
    }
    if (s == "F") {
        boundCheck(index, model.n);
        Expr e(model.n);
        e.thetaCoeff[index] =  180.0 / std::numbers::pi_v<double>;
        // so when F[t] = 180 deg, it thinks 180 / PI * theta[t] = 180 -> theta[t] = PI radians
        return e;
    }
    if (s == "T") { // Turn: T[i] = F[i+1] - F[i]
        boundCheck(index, model.n - 1);
        Expr e(model.n);
        e.thetaCoeff[index + 1] =  180.0 / std::numbers::pi_v<double>;
        e.thetaCoeff[index] =  - 180.0 / std::numbers::pi_v<double>;
        return e;
    }
    throw std::runtime_error{"Bug: This shouldn't happen cuz I checked the identifier name already."};
}

Cons Parser::parseConstraint(const std::string& s){
    Lexer lex(s);
    Expr lhs = parseExpr(lex, 0);

    Token cmpTok = lex.next();
    if(cmpTok.type != TokenType::Cmp)
        throw error("Expected comparison operator, got '" + cmpTok.text + "'", lex);

    char cmpChar = cmpTok.text[0];

    if(cmpTok.text.size() != 1 || (cmpChar != '<' && cmpChar != '=' && cmpChar != '>')) 
        throw error("Unknown Cmp Token: " + cmpTok.text, lex);

    Expr rhs = parseExpr(lex, 0);

    if (lex.peek().type != TokenType::End)
        throw error("Unexpected trailing tokens", lex);

    Token minusTok{TokenType::Operator, "-"};

    Expr stdForm;
    Cons::Cmp cmpType;

    switch (cmpChar) {
        case '<':
            stdForm = combineExpr(lhs, rhs, minusTok, lex);
            cmpType = Cons::Less;
            break;

        case '>':
            stdForm = combineExpr(rhs, lhs, minusTok, lex);
            cmpType = Cons::Less;
            break;

        case '=':
            stdForm = combineExpr(lhs, rhs, minusTok, lex);
            cmpType = Cons::Equal;
            break;
    }

    return Cons{stdForm, cmpType};
}

Expr Parser::parseExpr(const std::string& s){
    Lexer lex(s);
    Expr expr = parseExpr(lex, 0);
    if (lex.peek().type != TokenType::End)
        throw error("Unexpected trailing tokens", lex);
    return expr;
}

double Parser::parseConstant(const std::string& s){
    Expr e = parseExpr(s);
    if(!e.isConstant())
        throw std::runtime_error("Cannot reduce expression to constant: " + s);
    return e.constant;
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
            throw error("Invalid prefix operator '" + prefix.text + "'", lex);

        case TokenType::LParen:
            lhs = parseExpr(lex, 0);
            if (lex.next().type != TokenType::RParen)
                throw error("Missing ')'", lex);
            break;

        default:
            throw error("Invalid prefix token: " + prefix.text, lex);
    }


    while(true){
        Token op = lex.peek();
        if(op.type != TokenType::Operator)
            break;

        BP baseBP = getBP(op);

        if(baseBP.left < minBP) break;
        lex.next(); // Consume operator

        Expr rhs = parseExpr(lex, baseBP.right);

        lhs = combineExpr(lhs, rhs, op, lex);
    }

    return lhs;
}

Expr Parser::parseNumber(const Token& tok){
    Expr e(model.n);
    e.constant = std::stod(tok.text);
    return e;
}

Expr Parser::parseIdentifier(Lexer& lex, const Token& tok){
    if(tok.text == "X" || tok.text == "Z" || tok.text == "F" || tok.text == "Vx" || tok.text == "Vz" || tok.text == "T"){
        
        if(lex.next().type != TokenType::LBracket)
            throw error("Expected '[' after " + tok.text, lex);

        Expr index = parseExpr(lex, 0);

        if(lex.next().type != TokenType::RBracket)
            throw error("Missing ']'", lex);

        if(!index.isConstant())
            throw error("Index must be constant", lex);

        int idx = (int) std::round(index.constant);

        if (idx < 0)
            throw error(tok.text + "[" + std::to_string(idx) + "] is out of range", lex);

        return resolveIndexed(tok.text, idx, lex);
    }else{ // Variables
        if (varMap.contains(tok.text)) {
            double v = varMap.at(tok.text);
            Expr e(model.n);
            e.constant = v;
            return e;
        }else{
            throw error("Identifier " + tok.text + " is undefined.", lex);
        }
    }
}

Expr Parser::combineExpr(const Expr& lhs, const Expr& rhs, const Token& op, const Lexer& lex) {
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

        throw error("Nonlinear multiplication is not allowed", lex);
    }

    if (s == "/") {
        const bool rc = rhs.isConstant();
        if (!rc) throw error("Division by non-constant is not allowed", lex);
        if (rhs.constant == 0.0) throw error("Division by zero", lex);
        return scaleExpr(lhs, 1.0 / rhs.constant);
    }

    throw error("Unknown operator: " + op.text, lex);
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

std::runtime_error Parser::error(const std::string& msg, const Lexer& lex) {
    size_t p = lex.getPos();
    if (p > 0) --p;
    const std::string& src = lex.getContent();

    std::string indicator(p, ' ');
    indicator += '^';

    return std::runtime_error(
        msg +
        "\n\n" + src +
        "\n" + indicator
    );
}
