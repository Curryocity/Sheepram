#include <cmath>
#include <stdio.h>
#include <algorithm>
#include <iomanip>
#include <sstream>
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

// TODO: Make all input text, and eval() them.
const static char* title = "Mom, can we have wolfram at home?";

struct Environment {

    // Default to c4.5 p2p template, the classic
    int themeIndex = 0;
    bool maximize = false;

    enum objectiveType{X = 0, Z = 1, direction = 2, custom = 3};
    objectiveType currObj = X;
    double dirX = 0, dirZ = 0;
    std::string objectiveScript = "X[n]";

    int n = 12;
    double initV = 0.3169516131491288;
    std::vector<double> dragX, dragZ, accel;

    int varCapacity = 3;

    std::vector<std::string> globalNames;
    std::vector<double> globalValues;

    std::string constraintScript = "// c4.5 p2p\n"
                            "X[m] - X[0] > 7/16\n"
                            "X[m2] - X[0] > 7/16\n"
                            "Z[m2] - Z[m-1] > 1 + 0.6000000238418579\n";


    std::string output = "Press 'Optimize!!'";
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
            state.dragX[i] = 0.546;
            state.dragZ[i] = 0.546;
        }else{
            state.dragX[i] = 0.91;
            state.dragZ[i] = 0.91;
        }

        if (i == 0)
            state.accel[i] = state.initV;
        else if (i == 1)
            state.accel[i] = 0.3274;
        else
            state.accel[i] = 0.026;
    }
}

static void initGlobals(Environment& state){
    // varCapacity defaults to 3
    state.globalNames.resize(state.varCapacity);
    state.globalValues.resize(state.varCapacity);

    int idx = 0;

    state.globalNames[idx] = "m";
    state.globalValues[idx] = 2;
    idx ++;

    state.globalNames[idx] = "m2";
    state.globalValues[idx] = 8;
    idx ++;

    for (; idx < state.varCapacity; idx++){
        state.globalNames[idx] = "";
        state.globalValues[idx] = 0.0;
    }
}

// TODO: Switch this
static std::string runOptimizer() {
    const int n = 12;
    const int m = 2;
    const int m2 = 8;

    optimizer::Model model;
    model.n = n + 1;
    model.initV = 0.31695;

    model.dragX = {0.546, 0.546, 0.91, 0.91, 0.91, 0.91,0.91, 0.91, 0.91, 0.91, 0.91};
    model.dragZ = model.dragX;

    model.accel = {0.31695, 0.3274, 0.026, 0.026, 0.026, 0.026, 0.026, 0.026, 0.026, 0.026,0.026, 0.026};

    optimizer::compileModel(model);

    optimizer::LinearExpr objective;
    objective.terms.push_back({optimizer::Term::X, n, 1.0});

    optimizer::Constraint h1;
    h1.type = optimizer::Constraint::Less;
    h1.expr.constant = 7.0 / 16.0;
    h1.expr.terms.push_back({optimizer::Term::X, m, -1.0});
    h1.expr.terms.push_back({optimizer::Term::X, 0, 1.0});

    optimizer::Constraint h2;
    h2.type = optimizer::Constraint::Less;
    h2.expr.constant = 7.0 / 16.0;
    h2.expr.terms.push_back({optimizer::Term::X, m2, -1.0});
    h2.expr.terms.push_back({optimizer::Term::X, 0, 1.0});

    optimizer::Constraint h3;
    h3.type = optimizer::Constraint::Less;
    h3.expr.constant = 1.6;
    h3.expr.terms.push_back({optimizer::Term::Z, m2, -1.0});
    h3.expr.terms.push_back({optimizer::Term::Z, m - 1, 1.0});

    const std::vector<optimizer::Constraint> constraints = {h1, h2, h3};
    const optimizer::Problem prob = optimizer::buildProblem(model, objective, constraints);
    const optimizer::Solution sol = optimizer::optimize(model, prob);

    std::ostringstream out;
    out << std::setprecision(10);

    out << "\n=== Best Objective ===\n";
    out << sol.bestValue << "\n";

    out << "\n=== Angles (deg) ===\n";
    for (int i = 0; i < static_cast<int>(sol.thetas.size()) - 1; i++) {
        float deg = static_cast<float>(sol.thetas[i] * 180.0 / 3.14159265358979323846);
        float wrapped = std::fmod(deg + 180.0f, 360.0f);
        if (wrapped < 0) wrapped += 360.0f;
        wrapped -= 180.0f;
        out << "F[" << i << "] = " << wrapped << "\n";
    }

    out << "\n=== Trajectory (t, X[t], Z[t]) ===\n";
    for (int t = 0; t < static_cast<int>(sol.Xs.size()); t++) {
        out << t << "  "
            << sol.Xs[t] << "  "
            << sol.Zs[t] - sol.Zs[1] << "\n";
    }

    return out.str();
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

inline static void modelTable(Environment& state){
    if (state.n < nMin || state.n > nMax) {
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.95f, 0.35f, 0.35f, 1.0f));
        ImGui::Text("Refused to render the table: n must be in range [%d, %d].", nMin, nMax);
        ImGui::PopStyleColor();
        return;
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

        for (int col = 0; col < state.n + 1; col++) {
            ImGui::PushID(col);
            ImGui::TableSetupColumn(nullptr, ImGuiTableColumnFlags_WidthFixed, 70.0f);
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
            ImGui::SetNextItemWidth(70);
            ImGui::InputDouble("##dragX", &state.dragX[t], 0.0, 0.0, "%.4f");
            ImGui::PopID();
        }

        ImGui::TableNextRow();
        ImGui::TableSetColumnIndex(0);
        centerColumnText("DragZ");

        for (int t = 0; t < state.n; t++){
            ImGui::TableSetColumnIndex(t + 1);
            ImGui::PushID(1000 + t);
            ImGui::SetNextItemWidth(70);
            ImGui::InputDouble("##dragZ", &state.dragZ[t], 0.0, 0.0, "%.4f");
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
                ImGui::SetNextItemWidth(70);
                ImGui::InputDouble("##accel", &state.accel[t], 0.0, 0.0, "%.4f");
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
        state.globalValues.resize(state.varCapacity, 0.0);

    ImGui::SeparatorText("Global Variables");
    ImGui::BeginChild("var_region", ImVec2(0, 80), false);

    const float buttonWidth = 26.0f;
    const float buttonHeight = ImGui::GetFrameHeight();
    ImGui::BeginGroup();
    if (ImGui::Button("+", ImVec2(buttonWidth, buttonHeight))) {
        ++state.varCapacity;
        state.globalNames.push_back("");
        state.globalValues.push_back(0.0);
    }
    if (ImGui::Button("-", ImVec2(buttonWidth, buttonHeight)) && state.varCapacity > 1) {
        --state.varCapacity;
        state.globalNames.pop_back();
        state.globalValues.pop_back();
    }
    ImGui::EndGroup();

    ImGui::SameLine();

    const float columnWidth = 90.0f;

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
                                70.0f);

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
            ImGui::InputDouble("##value",&state.globalValues[i], 0.0, 0.0, "%.6f");

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

    const char* themes[] = {"Obsidian", "Gilded Blackstone", "Glow Squid", "Cherry Blossom"};
    ImGui::Spacing();
    ImGui::AlignTextToFramePadding();
    ImGui::Text("Theme:");
    ImGui::SameLine();
    ImGui::SetNextItemWidth(180.0f);
    if (ImGui::Combo("##theme_bottom", &state.themeIndex, themes, IM_ARRAYSIZE(themes))) {
        applyTheme(state.themeIndex);
    }
    ImGui::Spacing();

    ImGui::SeparatorText("Model");

    ImGui::AlignTextToFramePadding();
    ImGui::Text("n =");
    ImGui::SameLine();
    ImGui::SetNextItemWidth(40);
    ImGui::InputInt("##model_n", &state.n, 0, 0);

    ImGui::AlignTextToFramePadding();
    ImGui::Text("initV =");
    ImGui::SameLine();
    ImGui::SetNextItemWidth(160);
    ImGui::InputDouble("##model_initV", &state.initV, 0.0, 0.0, "%.16f");

    ImGui::Spacing();
    modelTable(state);

    ImGui::Spacing();
    ImGui::SeparatorText("Core");

    ImGui::AlignTextToFramePadding();
    ImGui::Text("Objective Function: ");
    ImGui::SameLine();
    ImGui::SetNextItemWidth(120);

    const char* modes[] = {"X[n]","Z[n]","Direction[n]", "Custom"};

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

    if (state.currObj == Environment::direction){
        ImGui::AlignTextToFramePadding();
        ImGui::Text("   > Set Direction Vector >");
        ImGui::SameLine();
        ImGui::PushItemWidth(120);

        ImGui::AlignTextToFramePadding();
        ImGui::Text("X:");
        ImGui::SameLine();
        ImGui::InputDouble("##dirx", &state.dirX);

        
        ImGui::SameLine();
        ImGui::AlignTextToFramePadding();
        ImGui::Text("Z:");
        ImGui::SameLine();
        ImGui::InputDouble("##dirz", &state.dirZ);

        ImGui::PopItemWidth();
    } else if (state.currObj == Environment::custom){
        ImGui::SetNextItemWidth(-1.0f);
        ImGui::InputText("##custom_objective_script", &state.objectiveScript);
    }

    globalVarTable(state);

    ImGui::SeparatorText("Constraints");

    ImGui::PushFont(codeFont);
    ImGui::InputTextMultiline("##constraint_script", &state.constraintScript, ImVec2(-1.0f, 120.0f), ImGuiInputTextFlags_AllowTabInput);
    ImGui::PopFont();


    if (ImGui::Button("Optimize!!", ImVec2(-1, 35))) {
        state.output = runOptimizer();
    }

    ImGui::EndChild();
}

static void outputPanel(Environment& state){
    ImGui::BeginChild("OutputPanel", ImVec2(0, 0), true);

    ImGui::SeparatorText("Result");

    ImGui::BeginChild("OutputScroll", ImVec2(0, 0), false, ImGuiWindowFlags_HorizontalScrollbar);

    ImGui::TextUnformatted(state.output.c_str());

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

    c[ImGuiCol_TextSelectedBg] = scale(accent, 0.85f, 0.30f);
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

    c[ImGuiCol_WindowBg] = {0.04f, 0.04f, 0.04f, 1.0f};
    c[ImGuiCol_ChildBg]  = {0.06f, 0.06f, 0.06f, 1.0f};
    c[ImGuiCol_PopupBg]  = {0.1f, 0.1f, 0.1f, 1.0f};

    c[ImGuiCol_FrameBg]        = {0.25f, 0.25f, 0.25f, 1.0f};
    c[ImGuiCol_FrameBgHovered] = {0.25f, 0.25f, 0.25f, 1.0f};
    c[ImGuiCol_FrameBgActive]  = {0.3f, 0.3f, 0.3f, 1.0f};

    c[ImGuiCol_TitleBg]       = {0.1f, 0.1f, 0.1f, 1.0f};
    c[ImGuiCol_TitleBgActive] = {0.15f, 0.15f, 0.15f, 1.0f};

    // Should make a enum?
    switch (themeIndex){
        case 0: applyAccent({0.45f, 0.39f, 0.60f}); break; // Obsidian
        case 1: applyAccent({0.92f, 0.69f, 0.22f}); break; // Gilded Blackstone
        case 2: applyAccent({0.38f, 0.74f, 0.80f}); break; // Glow Squid
        case 3: applyAccent({0.86f, 0.57f, 0.75f}); break; // Cherry Blossom
    }
}
