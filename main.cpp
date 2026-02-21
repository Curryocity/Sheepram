#include "parser.hpp"
#include <cmath>
#include <stdexcept>
#include <stdio.h>
#include <algorithm>
#include <string>
#include <vector>

#define GL_SILENCE_DEPRECATION
#include <OpenGL/gl3.h>
#include <GLFW/glfw3.h>

#include "imgui.h"
#include "backends/imgui_impl_glfw.h"
#include "backends/imgui_impl_opengl3.h"
#include "misc/cpp/imgui_stdlib.h"
#include "optimizer.hpp"
#include <sstream>
#include <iomanip>


const static char* title = "Mom, can we have wolfram at home?";

struct Environment {

    // Default to c4.5 p2p template, the classic
    int themeIndex = 0;
    bool maximize = false;

    enum objectiveType{X = 0, Z = 1, custom = 2};
    objectiveType currObj = X;
    std::string dirX = "0", dirZ = "0";
    std::string objScript = "Optimize along vec(a, b) := a * (X[t1] - X[t0]) + b * (Z[t1] - Z[t0])";

    int n = 12;
    int tempN = 12;   // Editing buffer

    std::string initV = "0.3169516131491288";
    std::vector<std::string> dragX, dragZ, accel;

    int varCapacity = 9;

    std::vector<std::string> globalNames;
    std::vector<std::string> globalValues;

    std::string constraintScript = "// c4.5 p2p\n"
                            "X[m] - X[0] > 7/16\n"
                            "X[m2] - X[0] > 7/16\n"
                            "Z[m2] - Z[m-1] > 1 + 0.6000000238418579\n";

    struct Post {
        std::string xTick = "0"; 
        std::string xAdd = "0"; 
        std::string zTick = "m-1";
        std::string zAdd = "0";
    } post;

    std::optional<optimizer::Solution> lastSol;
    int xIndex, zIndex;
    double xAdd, zAdd;
    std::string lastError;
};


static void glfw_error_callback(int error, const char* description) {
    fprintf(stderr, "GLFW Error %d: %s\n", error, description);
}

static void applyTheme(int themeIndex);
static ImFont* codeFont = nullptr;
static ImFont* uiFont = nullptr;
static constexpr int nMin = 1;
static constexpr int nMax = 256;

static void initFont() {
    ImGuiIO& io = ImGui::GetIO();
    codeFont = io.Fonts->AddFontFromFileTTF("asset/fonts/JetBrainsMono-Regular.ttf", 16.0f);
    uiFont = io.Fonts->AddFontFromFileTTF("asset/fonts/MinecraftRegular.otf", 16.0f);
}

static void initModel(Environment& state){
    state.n = std::clamp(state.n, nMin, nMax);
    // Defaults to delayed WAD

    state.dragX.resize(state.n);
    state.dragZ.resize(state.n);
    state.accel.resize(state.n);

    for (int i = 0; i < state.n; i++){
        if (i < 2){
            state.dragX[i] = "gnd";
            state.dragZ[i] = "gnd";
        }else{
            state.dragX[i] = "air";
            state.dragZ[i] = "air";
        }

        if (i == 0)
            state.accel[i] = "initV";
        else if (i == 1)
            state.accel[i] = "WAD";
        else
            state.accel[i] = "sa45";
    }
}

static void initGlobals(Environment& state){
    // varCapacity defaults to 9
    state.globalNames.resize(state.varCapacity);
    state.globalValues.resize(state.varCapacity);

    int idx = 0;

    state.globalNames[idx] = "gnd";
    state.globalValues[idx] = "0.546";
    idx ++;

    state.globalNames[idx] = "air";
    state.globalValues[idx] = "0.91";
    idx ++;

    state.globalNames[idx] = "s45";
    state.globalValues[idx] = "0.13";
    idx ++;

    state.globalNames[idx] = "sa45";
    state.globalValues[idx] = "0.026";
    idx ++;

    state.globalNames[idx] = "WAD";
    state.globalValues[idx] = "0.3274";
    idx ++;

    state.globalNames[idx] = "WAWD";
    state.globalValues[idx] = "0.3060547988254277";
    idx ++;

    state.globalNames[idx] = "m";
    state.globalValues[idx] = "2";
    idx ++;

    state.globalNames[idx] = "m2";
    state.globalValues[idx] = "8";
    idx ++;

    for (; idx < state.varCapacity; idx++){
        state.globalNames[idx] = "";
        state.globalValues[idx] = "";
    }
}


static void runOptimizer(Environment& state) {
    try {
        // 1. Define the internal n
        int n = state.n + 1;
        optimizer::Model model;
        model.n = n;

        // 2. Initialize parser(varTables, Expr sizes) 
        Parser p(model, state.globalNames, state.globalValues);

        // 3. Evaluate drag/accel scripts to constants
        model.dragX.resize(n);
        model.dragZ.resize(n);
        model.accel.resize(n);

        model.initV = p.parseConstant(state.initV); // accel[0] is not used in the optimizer
        for (int i = 0; i < model.n - 1; i++) {
            model.dragX[i] = p.parseConstant(state.dragX[i]);
            model.dragZ[i] = p.parseConstant(state.dragZ[i]);
        }
        for (int i = 1; i < model.n - 1; i++) { 
            model.accel[i] = p.parseConstant(state.accel[i]);
        }

        // 4. Compile movement formulas
        optimizer::compileModel(model);

        // 5. Parse objective
        optimizer::CompiledExpr objective(model.n);
        if (state.currObj == Environment::X)
            objective = p.parseExpr("X[n]");
        else if (state.currObj == Environment::Z)
            objective = p.parseExpr("Z[n]");
        else if (state.currObj == Environment::custom)
            objective = p.parseExpr(state.objScript);

        // Invert objective when maximizing
        if (state.maximize)
            objective = p.scaleExpr(objective, -1);

        // 6. Parse constraints
        auto constraints = p.parseMultiConstraints(state.constraintScript);

        // 7. Build problem
        auto prob = optimizer::buildProblem(model, objective, constraints);

        // 8. Optimize
        auto sol = optimizer::optimize(model, prob);
        if (state.maximize)
            sol.optimum *= -1; // Invert solution again when maximizing

        // 9. PostProcessor settings
        try{
            state.xIndex = (int) std::round(p.parseConstant(state.post.xTick));
            state.xAdd = p.parseConstant(state.post.xAdd);
            state.zIndex = (int) std::round(p.parseConstant(state.post.zTick));
            state.zAdd = p.parseConstant(state.post.zAdd);

            if(state.xIndex < 0 || state.xIndex >= n || state.zIndex < 0 || state.zIndex >= n)
                throw std::runtime_error{"Out of bound access"};
        }catch(const std::exception& e){
            throw std::runtime_error(
                std::string("Postprocessor:\n") + e.what()
            );
        }

        state.lastError = "";
        state.lastSol = sol;

    }catch (const std::exception& e) {
        state.lastError = std::string("Error:\n") + e.what();
    }

}

static void centerColumnText(const char* text){
    float col_w = ImGui::GetColumnWidth();
    float text_w = ImGui::CalcTextSize(text).x;

    ImGui::SetCursorPosX(ImGui::GetCursorPosX() + (col_w - text_w) * 0.5f);
    ImGui::AlignTextToFramePadding();
    ImGui::Text("%s", text);
}

static void centerColumnInt(int value){
    std::string s = std::to_string(value);
    centerColumnText(s.c_str());
}

static void InputTextAutoWidth(const char* id, std::string& str, float minW = 10.0f){
    float textW = ImGui::CalcTextSize(str.c_str()).x;
    float padding = ImGui::GetStyle().FramePadding.x * 2.0f;
    float width = std::max(minW, textW + padding);

    ImGui::SetNextItemWidth(width);
    ImGui::InputText(id, &str);
}

static void ShowReadOnlyBlock(const char* label, const std::string& text, float height = 70.0f){
    ImGui::TextUnformatted(label);

    ImGui::PushFont(codeFont);

    // InputTextMultiline needs a mutable buffer.
    // Keep a persistent copy so it doesn't reallocate every frame.
    static std::string buf;
    buf = text;

    ImGui::PushID(label);
    ImGui::InputTextMultiline(
        "##readonly",
        &buf,
        ImVec2(-1.0f, height),
        ImGuiInputTextFlags_ReadOnly | ImGuiInputTextFlags_NoUndoRedo
    );
    ImGui::PopID();

    ImGui::PopFont();
}

inline static void modelTable(Environment& state){
    if (state.n < nMin || state.n > nMax) {
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.95f, 0.35f, 0.35f, 1.0f));
        ImGui::Text("Refused to render the table: n must be in range [%d, %d].", nMin, nMax);
        ImGui::PopStyleColor();
        return;
    }

    static int prevN = state.n;
    if (state.n != prevN) {
        prevN = state.n;

        // Preserve existing entries, fill new ones with defaults
        state.dragX.resize(state.n, "air");
        state.dragZ.resize(state.n, "air");
        state.accel.resize(state.n, "sa45");

        // Re-apply special defaults
        for (int i = 0; i < std::min(2, state.n); ++i) {
            state.dragX[i] = "gnd";
            state.dragZ[i] = "gnd";
        }

        if (state.n > 0)
            state.accel[0] = "initV";

        if (state.n > 1)
            state.accel[1] = "WAD";
    }

    ImGui::BeginChild("model_region", ImVec2(0, 145), false);

    if (ImGui::BeginTable("model_table",
                        state.n + 1,
                        ImGuiTableFlags_Borders |
                        ImGuiTableFlags_RowBg |
                        ImGuiTableFlags_ScrollX |
                        ImGuiTableFlags_ScrollY |
                        ImGuiTableFlags_SizingFixedFit)){

        ImGui::TableSetupScrollFreeze(1, 0);

        const float columnWidth = 65.0f;

        for (int col = 0; col < state.n + 1; col++) {
            ImGui::PushID(col);
            ImGui::TableSetupColumn(nullptr, ImGuiTableColumnFlags_WidthFixed, columnWidth);
            ImGui::PopID();
        }

        ImGui::TableNextRow(ImGuiTableRowFlags_Headers);

        ImGui::TableSetColumnIndex(0);
        centerColumnText("Tick");

        for (int t = 0; t < state.n; t++){
            ImGui::TableSetColumnIndex(t + 1);
            centerColumnInt(t);
        }

        ImGui::TableNextRow();
        ImGui::TableSetColumnIndex(0);
        centerColumnText("DragX");

        for (int t = 0; t < state.n; t++){
            ImGui::TableSetColumnIndex(t + 1);
            ImGui::PushID(t);
            ImGui::SetNextItemWidth(columnWidth);
            ImGui::InputText("##dragX", &state.dragX[t]);
            ImGui::PopID();
        }

        ImGui::TableNextRow();
        ImGui::TableSetColumnIndex(0);
        centerColumnText("DragZ");

        for (int t = 0; t < state.n; t++){
            ImGui::TableSetColumnIndex(t + 1);
            ImGui::PushID(1000 + t);
            ImGui::SetNextItemWidth(columnWidth);
            ImGui::InputText("##dragZ", &state.dragZ[t]);
            ImGui::PopID();
        }

        ImGui::TableNextRow();
        ImGui::TableSetColumnIndex(0);
        centerColumnText("Accel");

        for (int t = 0; t < state.n; t++){
            ImGui::TableSetColumnIndex(t + 1);

            if (t == 0){
                centerColumnText("initV");
            }else{
                ImGui::PushID(2000 + t);
                ImGui::SetNextItemWidth(columnWidth);
                ImGui::InputText("##accel", &state.accel[t]);
                ImGui::PopID();
            }
        }

        ImGui::EndTable();
    }

    ImGui::EndChild();
}

inline static void globalVarTable(Environment& state){
    if (state.varCapacity < 1) state.varCapacity = 1;
    if (static_cast<int>(state.globalNames.size()) < state.varCapacity)
        state.globalNames.resize(state.varCapacity, "");
    if (static_cast<int>(state.globalValues.size()) < state.varCapacity)
        state.globalValues.resize(state.varCapacity, "");

    ImGui::SeparatorText("Global Variables");
    ImGui::BeginChild("var_region", ImVec2(0, 80), false);

    const float buttonWidth = 26.0f;
    const float buttonHeight = ImGui::GetFrameHeight();
    ImGui::BeginGroup();
    if (ImGui::Button("+", ImVec2(buttonWidth, buttonHeight))) {
        ++state.varCapacity;
        state.globalNames.push_back("");
        state.globalValues.push_back("");
    }
    if (ImGui::Button("-", ImVec2(buttonWidth, buttonHeight)) && state.varCapacity > 1) {
        --state.varCapacity;
        state.globalNames.pop_back();
        state.globalValues.pop_back();
    }
    ImGui::EndGroup();

    ImGui::SameLine();

    const float columnWidth = 70.0f;

    if (ImGui::BeginTable("var_table",
                          state.varCapacity + 1,
                          ImGuiTableFlags_Borders |
                          ImGuiTableFlags_RowBg |
                          ImGuiTableFlags_SizingFixedFit |
                          ImGuiTableFlags_ScrollX |
                          ImGuiTableFlags_ScrollY )){
        ImGui::TableSetupScrollFreeze(1, 0);

        ImGui::TableSetupColumn("##label",
                                ImGuiTableColumnFlags_WidthFixed,
                                60.0f);

        for (int i = 0; i < state.varCapacity; i++)
            ImGui::TableSetupColumn(("##col" + std::to_string(i)).c_str(),
                                    ImGuiTableColumnFlags_WidthFixed,
                                    columnWidth);

        ImGui::TableNextRow();
        ImGui::TableSetColumnIndex(0);
        centerColumnText("Name");

        for (int i = 0; i < state.varCapacity; i++){
            ImGui::TableSetColumnIndex(i + 1);
            ImGui::PushID(i);

            ImGui::SetNextItemWidth(columnWidth);
            ImGui::InputText("##name", &state.globalNames[i]);

            ImGui::PopID();
        }

        ImGui::TableNextRow();
        ImGui::TableSetColumnIndex(0);
        centerColumnText("Value");

        for (int i = 0; i < state.varCapacity; i++){
            ImGui::TableSetColumnIndex(i + 1);
            ImGui::PushID(1000 + i);

            ImGui::SetNextItemWidth(columnWidth);
            ImGui::InputText("##value",&state.globalValues[i]);

            ImGui::PopID();
        }

        ImGui::EndTable();
    }

    ImGui::EndChild();
}

static void inputPanel(Environment& state){
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(24.0f, 10.0f));
    ImGui::BeginChild("InputPanel", ImVec2(0, 0), true);
    ImGui::PopStyleVar();

    const char* themes[] = {"Obsidian", "Curry", "Luminous Abyss", "Cherry Blossom"};
    ImGui::Spacing();
    ImGui::AlignTextToFramePadding();
    ImGui::Text("Theme:");
    ImGui::SameLine();
    ImGui::SetNextItemWidth(180.0f);
    if (ImGui::Combo("##theme_bottom", &state.themeIndex, themes, IM_ARRAYSIZE(themes))) {
        applyTheme(state.themeIndex);
    }
    ImGui::Spacing();

    // === Model ===
    ImGui::SeparatorText("Model");

    ImGui::AlignTextToFramePadding();
    ImGui::Text("n =");
    ImGui::SameLine();

    ImGui::SetNextItemWidth(120.0f);

    ImGui::InputInt("##n", &state.tempN);
    bool commit = ImGui::IsItemDeactivatedAfterEdit();  // Commit when lost focus (press enter unfocus)
    if (commit) state.n = state.tempN;

    ImGui::AlignTextToFramePadding();
    ImGui::Text("initV =");
    ImGui::SameLine();
    ImGui::SetNextItemWidth(160);
    ImGui::InputText("##model_initV", &state.initV);

    ImGui::Spacing();
    modelTable(state);
    ImGui::Spacing();

    // === Core ===
    ImGui::SeparatorText("Core");

    ImGui::AlignTextToFramePadding();
    ImGui::Text("Objective Function: ");
    ImGui::SameLine();
    ImGui::SetNextItemWidth(120);

    const char* modes[] = {"X[n]","Z[n]", "Custom"};

    if (ImGui::BeginCombo("##obj", modes[state.currObj])){
        for (int i = 0; i < IM_ARRAYSIZE(modes); i++){
            bool is_selected = (state.currObj == static_cast<Environment::objectiveType>(i));

            if (ImGui::Selectable(modes[i], is_selected))
                state.currObj = static_cast<Environment::objectiveType>(i);

            if (is_selected)
                ImGui::SetItemDefaultFocus();
        }
        ImGui::EndCombo();
    }

    ImGui::SameLine(0.0f, 15.0f);
    if(ImGui::Button(state.maximize ? "Maximize" : "Minimize"))
        state.maximize = !state.maximize;


    if (state.currObj == Environment::custom){
        ImGui::SetNextItemWidth(-1.0f);
        ImGui::PushFont(codeFont);
        ImGui::InputText("##custom_objective_script", &state.objScript);
        ImGui::PopFont();
    }

    globalVarTable(state);

    // === Constraints ===
    ImGui::SeparatorText("Constraints");

    ImGui::PushFont(codeFont);
    ImGui::InputTextMultiline("##constraint_script", &state.constraintScript, ImVec2(-1.0f, 120.0f), ImGuiInputTextFlags_AllowTabInput);
    ImGui::PopFont();


    // === Postprocessing ===
    ImGui::SeparatorText("Postprocessor");

    ImGui::PushFont(codeFont);
    ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(4,2));
    ImGui::PushStyleVar(ImGuiStyleVar_FrameBorderSize, 0.0f);
    ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, 2.0f);

    ImGui::AlignTextToFramePadding();
    ImGui::Text("X Origin: X[");
    ImGui::SameLine(0.0f, 0.0f);

    InputTextAutoWidth("##xTick", state.post.xTick);
    ImGui::SameLine(0.0f, 0.0f);
    ImGui::Text("] + ");
    ImGui::SameLine(0.0f, 0.0f);
    InputTextAutoWidth("##xAdd", state.post.xAdd);


    ImGui::AlignTextToFramePadding();
    ImGui::Text("Z Origin: Z[");
    ImGui::SameLine(0.0f, 0.0f);
    InputTextAutoWidth("##zTick", state.post.zTick);
    ImGui::SameLine(0.0f, 0.0f);
    ImGui::Text("] + ");
    ImGui::SameLine(0.0f, 0.0f);
    InputTextAutoWidth("##zAdd", state.post.zAdd);


    ImGui::PopStyleVar(3);
    ImGui::PopFont();

    if (ImGui::Button("Optimize!!", ImVec2(-1, 35)))
        runOptimizer(state);

    ImGui::EndChild();
}

static void outputPanel(Environment& state){
    ImGui::BeginChild("OutputPanel", ImVec2(0, 0), true);

    ImGui::SeparatorText("Result");

    ImGui::BeginChild("OutputScroll", ImVec2(0, 0), false, ImGuiWindowFlags_HorizontalScrollbar);

    ImGui::PushFont(codeFont);
    
    if (!state.lastError.empty()) {
        ImGui::TextColored(ImVec4(1,0.4f,0.4f,1), "%s", state.lastError.c_str());
        ImGui::PopFont();
        ImGui::EndChild();
        ImGui::EndChild();
        return;
    }

    if (!state.lastSol.has_value()) {
        ImGui::TextDisabled("Press Optimize!!");
        ImGui::PopFont();
        ImGui::EndChild();
        ImGui::EndChild();
        return;
    }

    const auto& sol = *state.lastSol;

    ImGui::Text("=== Optimal Objective ===");
    ImGui::Text("%.16f", sol.optimum);

    ImGui::Spacing();
    ImGui::Text("=== LOG ===");

    int T = (int)sol.Xs.size();

    // ----- Facing -----
    std::vector<double> facings(T, 0.0);
    for (int t = 0; t < (int)sol.thetas.size(); t++) {
        double deg = sol.thetas[t] * 180.0 / M_PI;
        double wrapped = std::fmod(deg + 180.0, 360.0);
        if (wrapped < 0) wrapped += 360.0;
        wrapped -= 180.0;

        // mimic Wolfram rounding
        wrapped = std::round(200.0 * wrapped) * 0.005;

        facings[t] = wrapped;
    }

    // small helper to format doubles (replacement for std::format)
    auto fmt_double = [](double v, int prec) -> std::string {
        std::ostringstream oss;
        oss << std::fixed << std::setprecision(prec) << v;
        return oss.str();
    };

    // ----- Turns -----
    std::vector<std::string> turns(T, "-");
    for (int t = 0; t + 1 < T; t++) {
        double d = facings[t + 1] - facings[t];
        turns[t] = fmt_double(d, 3);
    }

    // ----- Positions -----
    const auto& xvals = sol.Xs;
    const auto& zvals = sol.Zs;

    // ----- Velocities -----
    std::vector<std::string> vxvals(T, "-");
    std::vector<std::string> vzvals(T, "-");

    for (int t = 0; t + 1 < T; t++) {
        double vx = xvals[t + 1] - xvals[t];
        double vz = zvals[t + 1] - zvals[t];

        vxvals[t] = fmt_double(vx, 6);
        vzvals[t] = fmt_double(vz, 6);
    }

    ImGui::PushStyleVar(ImGuiStyleVar_CellPadding, ImVec2(10.0f, 3.0f));
    constexpr float tableContentWidth = 900.0f;
    constexpr float estimateRowHeight = 34.0f;
    constexpr float minRowHeight = 20.0f;
    constexpr int maxVisibleRows = 13;

    const ImVec2 avail = ImGui::GetContentRegionAvail();
    const float tableOuterWidth = std::min(tableContentWidth, avail.x);
    const int visibleRows = std::min(T, maxVisibleRows);
    const float tableContentHeight =  visibleRows * estimateRowHeight + 50.0f;
    const float tableOuterHeight = std::min(tableContentHeight, avail.y);

    if (ImGui::BeginTable("ResultTable", 7,
        ImGuiTableFlags_RowBg |
        ImGuiTableFlags_BordersOuter |
        ImGuiTableFlags_BordersV |
        ImGuiTableFlags_ScrollY |
        ImGuiTableFlags_ScrollX |
        ImGuiTableFlags_SizingFixedFit |
        ImGuiTableFlags_NoHostExtendX,
        ImVec2(tableOuterWidth, tableOuterHeight))) {

        ImGui::TableSetupScrollFreeze(0, 1);
        ImGui::TableSetupColumn("Tick",       ImGuiTableColumnFlags_WidthFixed,  50.0f);
        ImGui::TableSetupColumn("Facing", ImGuiTableColumnFlags_WidthFixed, 100.0f);
        ImGui::TableSetupColumn("Turn", ImGuiTableColumnFlags_WidthFixed, 100.0f);
        ImGui::TableSetupColumn("X",          ImGuiTableColumnFlags_WidthFixed, 120.0f);
        ImGui::TableSetupColumn("Z",          ImGuiTableColumnFlags_WidthFixed, 120.0f);
        ImGui::TableSetupColumn("vx",         ImGuiTableColumnFlags_WidthFixed, 120.0f);
        ImGui::TableSetupColumn("vz",         ImGuiTableColumnFlags_WidthFixed, 120.0f);

        ImGui::TableNextRow(ImGuiTableRowFlags_Headers, minRowHeight);
        static const char* headers[] = {"Tick", "Facing", "Turn", "X", "Z", "Vx", "Vz"};
        for (int c = 0; c < 7; c++) {
            ImGui::TableSetColumnIndex(c);
            centerColumnText(headers[c]);
        }

        for (int t = 0; t < T; t++) {
            ImGui::TableNextRow(0, minRowHeight);

                const std::string tick = std::to_string(t);
                const std::string angle = fmt_double(facings[t], 3);
                const std::string x = fmt_double(xvals[t], 6);
                const std::string z = fmt_double(zvals[t], 6);

            ImGui::TableSetColumnIndex(0);
            centerColumnText(tick.c_str());

            ImGui::TableSetColumnIndex(1);
            centerColumnText(angle.c_str());

            ImGui::TableSetColumnIndex(2);
            centerColumnText(turns[t].c_str());

            ImGui::TableSetColumnIndex(3);
            centerColumnText(x.c_str());

            ImGui::TableSetColumnIndex(4);
            centerColumnText(z.c_str());

            ImGui::TableSetColumnIndex(5);
            centerColumnText(vxvals[t].c_str());

            ImGui::TableSetColumnIndex(6);
            centerColumnText(vzvals[t].c_str());
        }

        ImGui::EndTable();
    }
    ImGui::PopStyleVar();

    ImGui::Spacing();
    ImGui::Text("=== Facing/Turn Copying ===");

    auto formatFacingList = [&](const std::vector<double>& Fs)
    {
        std::string s = "{";
        for (int i = 0; i < state.n; i++) {
            if (i) s += ", ";
            s += fmt_double(Fs[i], 3);
        }
        s += "}";
        return s;
    };

    auto formatTurnList = [&](const std::vector<double>& Fs)
    {
        std::string s = "{";
        for (int i = 0; i + 1 < state.n; i++) {
            if (i) s += ", ";
            s += fmt_double(Fs[i + 1] - Fs[i], 3);
        }
        s += "}";
        return s;
    };

    std::string facingList = formatFacingList(facings);
    std::string turnList = formatTurnList(facings);


    ShowReadOnlyBlock("Facing:", facingList, 30.0f);
    ImGui::Spacing();
    ShowReadOnlyBlock("Turn:", turnList, 30.0f);


    ImGui::PopFont();

    ImGui::EndChild();
    ImGui::EndChild();
}

static float leftWidth = 0.0f;
static void optimizerMenu(Environment& state) {
    // Fullscreen
    ImGuiViewport* viewport = ImGui::GetMainViewport();
    ImGui::SetNextWindowPos(viewport->Pos);
    ImGui::SetNextWindowSize(viewport->Size);

    ImGuiWindowFlags flags =
        ImGuiWindowFlags_NoDecoration |
        ImGuiWindowFlags_NoMove |
        ImGuiWindowFlags_NoResize |
        ImGuiWindowFlags_NoCollapse;

    ImGui::Begin("optimizerMenu", nullptr, flags);

    const float totalWidth = ImGui::GetContentRegionAvail().x;
    const float totalHeight = ImGui::GetContentRegionAvail().y;
    const float dividerWidth = 8.0f;
    const float minPanelWidth = 250.0f;

    if (leftWidth <= 0.0f)
        leftWidth = totalWidth * 0.7f;

    leftWidth = std::clamp(leftWidth, minPanelWidth, totalWidth - minPanelWidth - dividerWidth);
    float rightWidth = totalWidth - leftWidth - dividerWidth;

    ImGui::BeginChild("LeftRegion", ImVec2(leftWidth, totalHeight), false);
    inputPanel(state);
    ImGui::EndChild();

    ImGui::SameLine(0.0f, 0.0f);
    ImVec2 dividerPos = ImGui::GetCursorScreenPos();
    ImGui::InvisibleButton("Divider", ImVec2(dividerWidth, totalHeight), ImGuiButtonFlags_MouseButtonLeft);

    const bool dividerHovered = ImGui::IsItemHovered();
    const bool dividerActive = ImGui::IsItemActive();
    if (dividerHovered || dividerActive)
        ImGui::SetMouseCursor(ImGuiMouseCursor_ResizeEW);
    
    if (dividerActive) {
        leftWidth += ImGui::GetIO().MouseDelta.x;
        leftWidth = std::clamp(leftWidth, minPanelWidth, totalWidth - minPanelWidth - dividerWidth);
        rightWidth = totalWidth - leftWidth - dividerWidth;
    }

    ImDrawList* drawList = ImGui::GetWindowDrawList();
    const ImU32 dividerColor = dividerActive
        ? ImGui::GetColorU32(ImGuiCol_SeparatorActive)
        : (dividerHovered ? ImGui::GetColorU32(ImGuiCol_SeparatorHovered)
                          : ImGui::GetColorU32(ImGuiCol_Separator));
    drawList->AddRectFilled(dividerPos, ImVec2(dividerPos.x + dividerWidth, dividerPos.y + totalHeight), dividerColor);

    ImGui::SameLine(0.0f, 0.0f);

    ImGui::BeginChild("RightRegion", ImVec2(rightWidth, totalHeight), false);
    outputPanel(state);
    ImGui::EndChild();

    ImGui::End();
}

int main() {
    glfwSetErrorCallback(glfw_error_callback);
    if (!glfwInit()) return 1;

    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 3);
    glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);
    glfwWindowHint(GLFW_OPENGL_FORWARD_COMPAT, GL_TRUE);

    GLFWwindow* window = glfwCreateWindow(1100, 720, title, nullptr, nullptr);
    if (!window) return 1;

    glfwMakeContextCurrent(window);
    glfwSwapInterval(1);

    IMGUI_CHECKVERSION();
    Environment state;
    ImGui::CreateContext();
    applyTheme(state.themeIndex);
    initFont();

    initModel(state);
    initGlobals(state);

    ImGui_ImplGlfw_InitForOpenGL(window, true);
    ImGui_ImplOpenGL3_Init("#version 330 core");

    while (!glfwWindowShouldClose(window)) {
        glfwPollEvents();

        ImGui_ImplOpenGL3_NewFrame();
        ImGui_ImplGlfw_NewFrame();
        ImGui::NewFrame();

        bool pushed_font = false;
        if (uiFont != nullptr) {
            ImGui::PushFont(uiFont);
            pushed_font = true;
        }

        optimizerMenu(state);

        if (pushed_font) ImGui::PopFont();

        ImGui::Render();
        int display_w, display_h;
        glfwGetFramebufferSize(window, &display_w, &display_h);
        glViewport(0, 0, display_w, display_h);
        glClearColor(0.05f, 0.05f, 0.05f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());

        glfwSwapBuffers(window);
    }

    ImGui_ImplOpenGL3_Shutdown();
    ImGui_ImplGlfw_Shutdown();
    ImGui::DestroyContext();
    glfwDestroyWindow(window);
    glfwTerminate();
    return 0;
}


struct RGB {
    float r, g, b;
};

static ImVec4 rgba(const RGB& c, float a = 1.0f){
    return ImVec4(c.r, c.g, c.b, a);
}

static ImVec4 scale(const RGB& c, float f, float a = 1.0f){
    return ImVec4(c.r * f, c.g * f, c.b * f, a);
}

static RGB mix(const RGB& a, const RGB& b, float t){
    return {
        a.r * (1.0f - t) + b.r * t,
        a.g * (1.0f - t) + b.g * t,
        a.b * (1.0f - t) + b.b * t
    };
}

static void applyAccent(const RGB& accent){
    auto& c = ImGui::GetStyle().Colors;

    RGB dark = {0.10f, 0.10f, 0.10f};
    RGB mid  = mix(dark, accent, 0.35f);
    RGB soft = mix(dark, accent, 0.20f);

    c[ImGuiCol_Button]        = scale(accent, 0.85f, 0.85f);
    c[ImGuiCol_ButtonHovered] = scale(accent, 1.00f, 0.95f);
    c[ImGuiCol_ButtonActive]  = scale(accent, 1.15f, 1.00f);

    c[ImGuiCol_Header]        = scale(accent, 0.70f, 0.85f);
    c[ImGuiCol_HeaderHovered] = scale(accent, 0.85f, 0.90f);
    c[ImGuiCol_HeaderActive]  = scale(accent, 1.00f, 0.95f);

    c[ImGuiCol_SliderGrab]        = scale(accent, 1.10f);
    c[ImGuiCol_SliderGrabActive]  = scale(accent, 1.25f);

    c[ImGuiCol_CheckMark]    = scale(accent, 1.30f);
    c[ImGuiCol_NavHighlight] = scale(accent, 1.30f);

    c[ImGuiCol_Border] = scale(accent, 0.75f, 0.80f);
    c[ImGuiCol_Separator] = scale(accent, 0.75f, 0.90f);

    c[ImGuiCol_TableBorderLight]  = rgba(soft, 0.65f);
    c[ImGuiCol_TableBorderStrong] = rgba(mid,  0.85f);
    c[ImGuiCol_TableRowBg]    = rgba(soft, 0.60f);
    c[ImGuiCol_TableRowBgAlt] = rgba(mid,  0.60f);
}

static void applyTheme(int themeIndex) {
    ImGuiStyle& style = ImGui::GetStyle();
    
    style.WindowRounding = 7.0f;
    style.ChildRounding = 6.0f;
    style.FrameRounding = 5.0f;
    style.GrabRounding = 4.0f;
    style.ScrollbarRounding = 6.0f;
    style.WindowBorderSize = 1.0f;
    style.FrameBorderSize = 0.0f;
    style.WindowPadding = ImVec2(12.0f, 10.0f);
    style.FramePadding = ImVec2(9.0f, 6.0f);
    style.ItemSpacing = ImVec2(9.0f, 8.0f);

    auto& c = style.Colors;

    c[ImGuiCol_Text]         = {0.95f, 0.95f, 0.95f, 1.0f};
    c[ImGuiCol_TextDisabled] = {0.6f,  0.6f,  0.6f,  1.0f};
    c[ImGuiCol_TextSelectedBg] = {0.8f, 0.8f, 0.8f, 0.30f};

    c[ImGuiCol_WindowBg] = {0.04f, 0.04f, 0.04f, 1.0f};
    c[ImGuiCol_ChildBg]  = {0.06f, 0.06f, 0.06f, 1.0f};
    c[ImGuiCol_PopupBg]  = {0.1f, 0.1f, 0.1f, 1.0f};

    c[ImGuiCol_FrameBg]        = {0.25f, 0.25f, 0.25f, 1.0f};
    c[ImGuiCol_FrameBgHovered] = {0.25f, 0.25f, 0.25f, 1.0f};
    c[ImGuiCol_FrameBgActive]  = {0.3f, 0.3f, 0.3f, 1.0f};

    c[ImGuiCol_TitleBg]       = {0.1f, 0.1f, 0.1f, 1.0f};
    c[ImGuiCol_TitleBgActive] = {0.15f, 0.15f, 0.15f, 1.0f};

    // Should I make a enum?
    switch (themeIndex){
        case 0: applyAccent({0.45f, 0.39f, 0.60f}); break; // Obsidian
        case 1: applyAccent({0.92f, 0.69f, 0.22f}); break; // Curry (Literally honey)
        case 2: applyAccent({0.38f, 0.74f, 0.80f}); break; // Luminous Abyss
        case 3: applyAccent({0.86f, 0.57f, 0.75f}); break; // Cherry Blossom
    }
}
