#include "parser.hpp"

#include <cmath>
#include <cstddef>
#include <numbers>
#include <stdexcept>
#include <stdio.h>
#include <algorithm>
#include <string>
#include <vector>
#include <fstream>
#include <filesystem>

#if !defined(GL_SILENCE_DEPRECATION)
#define GL_SILENCE_DEPRECATION
#endif

#if defined(__APPLE__)
#include <OpenGL/gl3.h>
#else
#include <GL/gl.h>
#endif
#include <GLFW/glfw3.h>
#if defined(_WIN32)
#ifndef GLFW_EXPOSE_NATIVE_WIN32
#define GLFW_EXPOSE_NATIVE_WIN32
#endif
#include <GLFW/glfw3native.h>
#endif

#include "imgui.h"
#include "imgui_internal.h"
#include "backends/imgui_impl_glfw.h"
#include "backends/imgui_impl_opengl3.h"
#include "misc/cpp/imgui_stdlib.h"
#include "nfd.h"
#include "optimizer.hpp"
#include <sstream>
#include <iomanip>
#include <cstdlib>

#include "thirdParty/json.hpp"

#if defined(_WIN32)
#include <windows.h>
#elif defined(__APPLE__)
#include <mach-o/dyld.h>
#include <unistd.h>
#else
#include <unistd.h>
#endif

const static char* title = "Wolfram? No. Sheepram.";
using json = nlohmann::json;

struct Environment {

    bool maximize = false;

    enum objectiveType{X = 0, Z = 1, custom = 2};
    objectiveType currObj = X;
    std::string dirX = "0", dirZ = "0";
    std::string objScript = "Optimize along vec(a, b) := a * (X[t1] - X[t0]) + b * (Z[t1] - Z[t0])";

    int n = 12;
    int editN = 12;

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
        std::vector<std::string> angleOffset = {"0"};
        enum offsetType{Facing = 0, Turn = 1};
        int offsetMode = Facing;
        int positionPrecision = 6;
    } post;

    std::optional<optimizer::Solution> lastSol;
    int xIndex, zIndex;
    double xAdd, zAdd;
    std::vector<double> angleOffset;
    std::string lastError;
};

struct TabState {
    int id = 0;
    std::string name = "Untitled";
    std::string nameDraft;
    std::string savedFingerprint;
    std::string savedFileName;
    std::string inlineSaveMessage;
    bool inlineSaveIsError = false;
    Environment env;
    float leftWidth = 0.0f;
    int prevN = -1; // Exist to prevent table resize on every frame.
    int selectedModelTickIndex = -1;
    int selectedGlobalVarIndex = -1;
    ImVec2 modelRegionMin = ImVec2(0.0f, 0.0f);
    ImVec2 modelRegionMax = ImVec2(0.0f, 0.0f);
};

struct AppState {
    enum class Theme {
        Obsidian = 0,
        Curry = 1,
        LuminousAbyss = 2,
        CherryBlossom = 3,
        CrimsonForest = 4
    };
    Theme theme = Theme::Obsidian;
    std::vector<TabState> tabs;
    int activeTab = 0;
    int nextTabId = 1;
    int pendingCloseTabId = -1;
    std::string closePopupError;
};

static void glfw_error_callback(int error, const char* description) {
    fprintf(stderr, "GLFW Error %d: %s\n", error, description);
}

static void applyTheme(AppState::Theme theme);
static ImFont* codeFont = nullptr;
static ImFont* bigCodeFont = nullptr;
static ImFont* uiFont = nullptr;
static constexpr int nMin = 1;
static constexpr int nMax = 256;
static constexpr int maxTabs = 16;
static const char* appDataDirName = "Sheepram";
static std::filesystem::path resourceRootPath = ".";
static std::filesystem::path preferencePath = "preference.json";
static std::filesystem::path tabsDirPath = "presets/saves";
static std::filesystem::path resourcePath(const std::filesystem::path& relPath);
static TabState makeDefaultTab(int tabId);
static void trim(std::string& s);
static void drawClippedSelectionRect(ImDrawList* drawList,
                                     const ImVec2& min,
                                     const ImVec2& max,
                                     ImU32 color) {
    ImGuiWindow* window = ImGui::GetCurrentWindow();
    drawList->PushClipRect(window->ClipRect.Min, window->ClipRect.Max, true);
    drawList->AddRect(min, max, color, 3.0f, 0, 2.0f);
    drawList->PopClipRect();
}

#if defined(_WIN32)
static HICON setNativeWindowIcon(GLFWwindow* window) {
    const std::filesystem::path iconPath = resourcePath("asset/icon/app.ico");
    const std::wstring iconPathWide = iconPath.wstring();
    HICON icon = static_cast<HICON>(LoadImageW(nullptr,
                                               iconPathWide.c_str(),
                                               IMAGE_ICON,
                                               0,
                                               0,
                                               LR_LOADFROMFILE | LR_DEFAULTSIZE));
    if (icon == nullptr) return nullptr;

    const HWND hwnd = glfwGetWin32Window(window);
    SendMessageW(hwnd, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(icon));
    SendMessageW(hwnd, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(icon));
    return icon;
}
#endif

static constexpr int themeCount = 5;
static const char* themeNames[themeCount] = {
    "Obsidian", "Curry", "Luminous Abyss", "Cherry Blossom", "Crimson Forest"
};
static bool nfdReady = false;
static std::string nfdInitError;

static std::filesystem::path executablePath() {
#if defined(_WIN32)
    std::vector<char> buf(MAX_PATH);
    DWORD len = 0;
    while (true) {
        len = GetModuleFileNameA(nullptr, buf.data(), static_cast<DWORD>(buf.size()));
        if (len == 0) return {};
        if (len < buf.size()) return std::filesystem::path(std::string(buf.data(), len));
        buf.resize(buf.size() * 2);
    }
#elif defined(__APPLE__)
    uint32_t size = 0;
    _NSGetExecutablePath(nullptr, &size);
    std::vector<char> buf(size + 1, '\0');
    if (_NSGetExecutablePath(buf.data(), &size) != 0) return {};
    std::error_code ec;
    return std::filesystem::canonical(std::filesystem::path(buf.data()), ec);
#else
    std::vector<char> buf(4096, '\0');
    const ssize_t len = readlink("/proc/self/exe", buf.data(), buf.size() - 1);
    if (len <= 0) return {};
    buf[static_cast<size_t>(len)] = '\0';
    return std::filesystem::path(buf.data());
#endif
}

static bool hasBundledAssets(const std::filesystem::path& root) {
    return std::filesystem::exists(root / "asset/fonts/JetBrainsMono-Regular.ttf") &&
           std::filesystem::exists(root / "asset/fonts/MinecraftRegular.otf");
}

static std::filesystem::path resolveResourceRoot() {
    std::vector<std::filesystem::path> candidates;
    std::error_code ec;
    candidates.push_back(std::filesystem::current_path(ec));

    const std::filesystem::path exePath = executablePath();
    if (!exePath.empty()) {
        const std::filesystem::path exeDir = exePath.parent_path();
        candidates.push_back(exeDir);
        candidates.push_back(exeDir.parent_path());
        candidates.push_back(exeDir.parent_path().parent_path());
        candidates.push_back(exeDir.parent_path() / "Resources");
        candidates.push_back(exeDir.parent_path().parent_path() / "Resources");
    }

    for (const auto& candidate : candidates) {
        if (!candidate.empty() && hasBundledAssets(candidate)) return candidate;
    }
    return std::filesystem::current_path(ec);
}

static std::filesystem::path resolveDataRoot() {
    std::filesystem::path base;
    if (const char* custom = std::getenv("WOLFRAMMCPK_DATA_DIR"); custom && *custom) {
        base = custom;
    } else {
#if defined(_WIN32)
        const char* appData = std::getenv("APPDATA");
        base = (appData && *appData) ? std::filesystem::path(appData) : std::filesystem::current_path();
#elif defined(__APPLE__)
        const char* home = std::getenv("HOME");
        base = (home && *home) ? (std::filesystem::path(home) / "Library/Application Support")
                               : std::filesystem::current_path();
#else
        const char* home = std::getenv("HOME");
        base = (home && *home) ? (std::filesystem::path(home) / ".local/share")
                               : std::filesystem::current_path();
#endif
    }

    std::filesystem::path appRoot = base / appDataDirName;
    std::error_code ec;
    std::filesystem::create_directories(appRoot, ec);
    if (!ec) return appRoot;

    appRoot = std::filesystem::current_path() / appDataDirName;
    ec.clear();
    std::filesystem::create_directories(appRoot, ec);
    return appRoot;
}

static std::filesystem::path resourcePath(const std::filesystem::path& relPath) {
    return resourceRootPath / relPath;
}

static std::vector<std::filesystem::path> bundledPresetDirs() {
    std::vector<std::filesystem::path> candidates;
    std::error_code ec;
    candidates.push_back(resourcePath("presets/saves"));
    candidates.push_back(resourceRootPath.parent_path() / "presets/saves");
    candidates.push_back(std::filesystem::current_path(ec) / "presets/saves");
    return candidates;
}

static void seedBundledPresets() {
    for (const auto& srcDir : bundledPresetDirs()) {
        std::error_code ec;
        if (!std::filesystem::exists(srcDir, ec) || !std::filesystem::is_directory(srcDir, ec))
            continue;

        for (const auto& entry : std::filesystem::directory_iterator(srcDir, ec)) {
            if (ec) break;
            if (!entry.is_regular_file(ec)) continue;
            if (entry.path().extension() != ".json") continue;

            const std::filesystem::path dst = tabsDirPath / entry.path().filename();
            if (std::filesystem::exists(dst, ec)) continue;
            std::filesystem::copy_file(entry.path(), dst, std::filesystem::copy_options::none, ec);
        }
    }
}

static void initPaths() {
    resourceRootPath = resolveResourceRoot();
    const std::filesystem::path dataRoot = resolveDataRoot();
    preferencePath = dataRoot / "preference.json";
    tabsDirPath = dataRoot / "presets/saves";
    std::error_code ec;
    std::filesystem::create_directories(tabsDirPath, ec);
    seedBundledPresets();
}

static int themeToIndex(AppState::Theme theme) {
    return static_cast<int>(theme);
}

static AppState::Theme indexToTheme(int index) {
    const int clamped = std::clamp(index, 0, themeCount - 1);
    return static_cast<AppState::Theme>(clamped);
}

static void initFont() {
    ImGuiIO& io = ImGui::GetIO();
    const std::string codeFontPath = resourcePath("asset/fonts/JetBrainsMono-Regular.ttf").string();
    const std::string uiFontPath = resourcePath("asset/fonts/MinecraftRegular.otf").string();
    codeFont = io.Fonts->AddFontFromFileTTF(codeFontPath.c_str(), 16.0f);
    bigCodeFont = io.Fonts->AddFontFromFileTTF(codeFontPath.c_str(), 22.0f);
    uiFont = io.Fonts->AddFontFromFileTTF(uiFontPath.c_str(), 16.0f);
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


// Forward declarations for utility/serialization helpers (defined near file bottom).
static json buildTabJson(const TabState& tab);
static std::string buildTabFingerprint(const TabState& tab);
static bool isTabModified(const TabState& tab);
static std::string safeFileName(std::string name);
static bool saveTabToFile(TabState& tab, std::string& err);
static bool parseOptionalStringVector(const json& obj, const char* key, std::vector<std::string>& out, std::string& err);
static bool loadTabFromJson(TabState& tab, const json& j, std::string& err);
static bool choosePresetFile(std::string& outPath, std::string& err);
static bool initFileDialog(std::string& err);
static void shutdownFileDialog();
static void savePreferences(const AppState& app);
static void loadPreferences(AppState& app);
static int findTabIndexById(const AppState& app, int id);
static void closeTabById(AppState& app, int tabId, int& activeIndex);
static void setInlineStatus(TabState& tab, const std::string& message, bool isError);
static void loadPresetIntoTab(TabState& tab, const std::string& selectedPath);

struct TopBarResult {
    int closeNowTabId = -1;
    int requestClosePopupTabId = -1;
    int activeIndex = 0;
};
static TopBarResult renderTopBar(AppState& app) {
    TopBarResult result;
    result.activeIndex = app.activeTab;
    const float loadBtnW = 120.0f;

    if (!ImGui::BeginTable("top_bar", 2, ImGuiTableFlags_SizingStretchSame | ImGuiTableFlags_NoBordersInBody))
        return result;

    ImGui::TableSetupColumn("tabs", ImGuiTableColumnFlags_WidthStretch);
    ImGui::TableSetupColumn("load", ImGuiTableColumnFlags_WidthFixed, loadBtnW);
    ImGui::TableNextRow();

    ImGui::TableSetColumnIndex(0);
    if (ImGui::BeginTabBar("optimizer_tabs")) {
        int justCreatedTabIndex = -1;
        const bool canAddTab = app.tabs.size() < maxTabs;
        if (!canAddTab) ImGui::BeginDisabled();
        if (ImGui::TabItemButton("+", ImGuiTabItemFlags_Trailing) && canAddTab) {
            app.tabs.push_back(makeDefaultTab(app.nextTabId++));
            justCreatedTabIndex = static_cast<int>(app.tabs.size()) - 1;
            result.activeIndex = justCreatedTabIndex;
            app.activeTab = justCreatedTabIndex;
        }
        if (!canAddTab) ImGui::EndDisabled();

        const int tabCount = static_cast<int>(app.tabs.size());
        for (int i = 0; i < tabCount; i++) {
            bool open = true;
            ImGuiTabItemFlags tabFlags = 0;
            if (i == justCreatedTabIndex) tabFlags |= ImGuiTabItemFlags_SetSelected;
            const std::string tabLabel = app.tabs[i].name + "###tab_" + std::to_string(app.tabs[i].id);

            if (ImGui::BeginTabItem(tabLabel.c_str(), &open, tabFlags)) {
                result.activeIndex = i;
                ImGui::EndTabItem();
            }

            if (!open) {
                if (isTabModified(app.tabs[i])) {
                    result.requestClosePopupTabId = app.tabs[i].id;
                } else {
                    result.closeNowTabId = app.tabs[i].id;
                }
            }
        }
        ImGui::EndTabBar();
    }

    ImGui::TableSetColumnIndex(1);
    if (ImGui::Button("Load Preset", ImVec2(-1.0f, 0))) {
        std::string selectedPath;
        std::string pickerErr;
        if (choosePresetFile(selectedPath, pickerErr)) {
            if (app.activeTab >= 0 && app.activeTab < static_cast<int>(app.tabs.size()))
                loadPresetIntoTab(app.tabs[app.activeTab], selectedPath);
        } else if (!pickerErr.empty()) {
            if (app.activeTab >= 0 && app.activeTab < static_cast<int>(app.tabs.size()))
                setInlineStatus(app.tabs[app.activeTab], "Load failed: " + pickerErr, true);
        }
    }

    ImGui::EndTable();
    return result;
}

static void handleClosePopup(AppState& app, int& activeIndex) {
    if (ImGui::BeginPopupModal("Save Tab Before Closing?", nullptr, ImGuiWindowFlags_AlwaysAutoResize)) {
        const int pendingIdx = findTabIndexById(app, app.pendingCloseTabId);
        if (pendingIdx < 0) {
            app.pendingCloseTabId = -1;
            app.closePopupError.clear();
            ImGui::CloseCurrentPopup();
            ImGui::EndPopup();
            return;
        }

        const std::string& tabTitle = app.tabs[pendingIdx].name;
        ImGui::Text("Save changes to '%s' before closing?", tabTitle.c_str());
        if (!app.closePopupError.empty())
            ImGui::TextColored(ImVec4(1.0f, 0.45f, 0.45f, 1.0f), "%s", app.closePopupError.c_str());
        ImGui::Spacing();

        if (ImGui::Button("Save", ImVec2(110, 0))) {
            std::string err;
            if (saveTabToFile(app.tabs[pendingIdx], err)) {
                app.tabs[pendingIdx].savedFingerprint = buildTabFingerprint(app.tabs[pendingIdx]);
                closeTabById(app, app.pendingCloseTabId, activeIndex);
                app.pendingCloseTabId = -1;
                app.closePopupError.clear();
                ImGui::CloseCurrentPopup();
            } else {
                app.closePopupError = err;
            }
        }
        ImGui::SameLine();
        if (ImGui::Button("Don't Save", ImVec2(110, 0))) {
            closeTabById(app, app.pendingCloseTabId, activeIndex);
            app.pendingCloseTabId = -1;
            app.closePopupError.clear();
            ImGui::CloseCurrentPopup();
        }
        ImGui::SameLine();
        if (ImGui::Button("Cancel", ImVec2(110, 0))) {
            app.pendingCloseTabId = -1;
            app.closePopupError.clear();
            ImGui::CloseCurrentPopup();
        }
        ImGui::EndPopup();
    }
}

static bool hasModifiedTabs(const AppState& app) {
    for (const TabState& tab : app.tabs) {
        if (isTabModified(tab)) return true;
    }
    return false;
}

static bool saveAllModifiedTabs(AppState& app, std::string& err) {
    for (TabState& tab : app.tabs) {
        if (!isTabModified(tab)) continue;
        std::string saveErr;
        if (!saveTabToFile(tab, saveErr)) {
            err = "Failed to save '" + tab.name + "': " + saveErr;
            return false;
        }
        tab.savedFingerprint = buildTabFingerprint(tab);
    }
    return true;
}

static TabState makeDefaultTab(int tabId) {
    TabState tab;
    tab.id = tabId;
    tab.name = "Untitled " + std::to_string(tabId);
    tab.nameDraft = tab.name;
    initModel(tab.env);
    initGlobals(tab.env);
    tab.env.post.angleOffset.resize(tab.env.n, "0");
    tab.prevN = tab.env.n;
    tab.savedFingerprint = buildTabFingerprint(tab);
    return tab;
}


static void runOptimizer(Environment& state) {
    if (state.n < nMin || state.n > nMax) {
        state.lastSol.reset();
        state.lastError = "Error:\nInvalid n: " + std::to_string(state.n) +
                          " (expected range: " + std::to_string(nMin) + " to " + std::to_string(nMax) + ")";
        return;
    }

    try {
        // 1. Define the internal n
        int n = state.n + 1;
        optimizer::Model model;
        model.n = n;

        // 2. Initialize parser(varTables, Expr sizes) 
        Parser p(model);
        model.initV = p.parseConstant(state.initV); 
        p.defineInitV(model.initV);
        p.addVariables(state.globalNames, state.globalValues);

        // 3. Evaluate drag/accel scripts to constants
        model.dragX.resize(n);
        model.dragZ.resize(n);
        model.accel.resize(n);

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
            state.angleOffset.resize(state.post.angleOffset.size());
            for (int i = 0; i < (int)state.post.angleOffset.size(); i++)
                state.angleOffset[i] = p.parseConstant(state.post.angleOffset[i]);

            if(state.post.offsetMode == Environment::Post::Turn){
                double accumulation = 0;
                for (int i = 0; i < (int)state.post.angleOffset.size(); i++){
                    accumulation += state.angleOffset[i];
                    state.angleOffset[i] = accumulation;
                }
            }

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

static void trim(std::string& s) {
    const size_t start = s.find_first_not_of(" \t\n\r\f\v");
    if (start == std::string::npos) {
        s.clear();
        return;
    }
    const size_t end = s.find_last_not_of(" \t\n\r\f\v");
    s.erase(end + 1);
    s.erase(0, start);
}

static void normalizeTabTitle(TabState& tab) {
    trim(tab.nameDraft);
    if (tab.nameDraft.empty())
        tab.nameDraft = "Untitled " + std::to_string(tab.id);
    tab.name = tab.nameDraft;
}

static void InputTextAutoWidth(const char* id, std::string& str, float minW = 10.0f){
    float textW = ImGui::CalcTextSize(str.c_str()).x;
    float padding = ImGui::GetStyle().FramePadding.x * 2.0f;
    float width = std::max(minW, textW + padding);

    ImGui::SetNextItemWidth(width);
    ImGui::InputText(id, &str);
}

static void readOnlyBlock(const char* label, const std::string& text, float height = 70.0f, bool copyButtonQ = false){
    ImGui::AlignTextToFramePadding();
    ImGui::PushFont(uiFont);
    ImGui::TextUnformatted(label);
    
    if (copyButtonQ){
        ImGui::SameLine();
        if (ImGui::Button((std::string("Copy##") + label).c_str()))
            ImGui::SetClipboardText(text.c_str());
    }
    ImGui::PopFont();

    ImGui::PushFont(codeFont);

    // Persistent storage
    static std::unordered_map<std::string, std::string> buffers;
    std::string& buf = buffers[label];

    if (buf != text)
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

inline static void modelTable(TabState& tab){
    Environment& state = tab.env;
    if (state.n < nMin || state.n > nMax) {
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.95f, 0.35f, 0.35f, 1.0f));
        ImGui::Text("Refused to render the table: n must be in range [%d, %d].", nMin, nMax);
        ImGui::PopStyleColor();
        return;
    }

    if (state.n != tab.prevN) {
        const std::string dragXFill = state.dragX.empty() ? "air" : state.dragX.back();
        const std::string dragZFill = state.dragZ.empty() ? "air" : state.dragZ.back();
        const std::string accelFill = state.accel.empty() ? "sa45" : state.accel.back();
        const std::string angleOffsetFill = state.post.angleOffset.empty() ? "0" : state.post.angleOffset.back();

        // Preserve existing entries, extending new rows with the current last entries.
        state.dragX.resize(state.n, dragXFill);
        state.dragZ.resize(state.n, dragZFill);
        state.accel.resize(state.n, accelFill);
        state.post.angleOffset.resize(state.n, angleOffsetFill);

        state.accel[0] = "initV";

        tab.prevN = state.n;
    }

    ImGui::BeginChild("model_region", ImVec2(0, 145), false);
    tab.modelRegionMin = ImGui::GetWindowPos();
    tab.modelRegionMax = ImVec2(tab.modelRegionMin.x + ImGui::GetWindowSize().x,
                                tab.modelRegionMin.y + ImGui::GetWindowSize().y);
    ImDrawList* drawList = ImGui::GetForegroundDrawList();
    const ImU32 selectedBorderColor = ImGui::GetColorU32(ImVec4(1.0f, 1.0f, 1.0f, 0.4f));

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
            if (ImGui::IsItemActivated() || ImGui::IsItemClicked())
                tab.selectedModelTickIndex = t;
            if (tab.selectedModelTickIndex == t){
                const ImVec2 min = ImGui::GetItemRectMin();
                const ImVec2 max = ImGui::GetItemRectMax();
                drawClippedSelectionRect(drawList,
                                         min,
                                         max,
                                         selectedBorderColor);
            }
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
            if (ImGui::IsItemActivated() || ImGui::IsItemClicked())
                tab.selectedModelTickIndex = t;
            if (tab.selectedModelTickIndex == t){
                const ImVec2 min = ImGui::GetItemRectMin();
                const ImVec2 max = ImGui::GetItemRectMax();
                drawClippedSelectionRect(drawList,
                                         min,
                                         max,
                                         selectedBorderColor);
            }
                
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
                if (ImGui::IsItemActivated() || ImGui::IsItemClicked())
                    tab.selectedModelTickIndex = t;
                if (tab.selectedModelTickIndex == t){
                    const ImVec2 min = ImGui::GetItemRectMin();
                    const ImVec2 max = ImGui::GetItemRectMax();
                    drawClippedSelectionRect(drawList,
                                             min,
                                             max,
                                             selectedBorderColor);
                }
                ImGui::PopID();
            }
        }

        ImGui::EndTable();
    }

    ImGui::EndChild();
}

inline static void globalVarTable(TabState& tab){
    Environment& state = tab.env;
    if (state.varCapacity < 1) state.varCapacity = 1;
    if (static_cast<int>(state.globalNames.size()) < state.varCapacity)
        state.globalNames.resize(state.varCapacity, "");
    if (static_cast<int>(state.globalValues.size()) < state.varCapacity)
        state.globalValues.resize(state.varCapacity, "");

    ImGui::SeparatorText("Global Variables");
    ImGui::BeginChild("var_region", ImVec2(0, 80), false);
    const ImVec2 varRegionMin = ImGui::GetWindowPos();
    const ImVec2 varRegionMax(varRegionMin.x + ImGui::GetWindowSize().x,
                              varRegionMin.y + ImGui::GetWindowSize().y);

    const float buttonWidth = 26.0f;
    const float buttonHeight = ImGui::GetFrameHeight();
    ImDrawList* drawList = ImGui::GetForegroundDrawList();
    const ImU32 selectedBorderColor = ImGui::GetColorU32(ImVec4(1.0f, 1.0f, 1.0f, 0.4f));

    const int activeIndex = state.varCapacity > 0
    ? ((tab.selectedGlobalVarIndex >= 0 && tab.selectedGlobalVarIndex < state.varCapacity)
        ? tab.selectedGlobalVarIndex
        : state.varCapacity - 1)
    : -1;

    ImGui::BeginGroup();
    if (ImGui::Button("+", ImVec2(buttonWidth, buttonHeight))) {
        const int insertIndex = activeIndex + 1;
        state.globalNames.insert(state.globalNames.begin() + insertIndex, "");
        state.globalValues.insert(state.globalValues.begin() + insertIndex, "");
        ++state.varCapacity;
        tab.selectedGlobalVarIndex = insertIndex;
    }
    if (ImGui::Button("-", ImVec2(buttonWidth, buttonHeight)) && state.varCapacity > 1) {
        state.globalNames.erase(state.globalNames.begin() + activeIndex);
        state.globalValues.erase(state.globalValues.begin() + activeIndex);
        --state.varCapacity;
        tab.selectedGlobalVarIndex = std::max(0, activeIndex - 1);
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
            if (ImGui::IsItemActivated() || ImGui::IsItemClicked())
                tab.selectedGlobalVarIndex = i;
            if (tab.selectedGlobalVarIndex == i) {
                const ImVec2 min = ImGui::GetItemRectMin();
                const ImVec2 max = ImGui::GetItemRectMax();
                drawClippedSelectionRect(drawList,
                                         min,
                                         max,
                                         selectedBorderColor);
            }
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
            if (ImGui::IsItemActivated() || ImGui::IsItemClicked())
                tab.selectedGlobalVarIndex = i;
            if (tab.selectedGlobalVarIndex == i) {
                const ImVec2 min = ImGui::GetItemRectMin();
                const ImVec2 max = ImGui::GetItemRectMax();
                drawClippedSelectionRect(drawList,
                                         min,
                                         max,
                                         selectedBorderColor);
            }
            ImGui::PopID();
        }

        ImGui::EndTable();
    }

    const ImVec2 mousePos = ImGui::GetIO().MousePos;
    const bool insideVarRegion =
        mousePos.x >= varRegionMin.x && mousePos.x <= varRegionMax.x &&
        mousePos.y >= varRegionMin.y && mousePos.y <= varRegionMax.y;
    if (ImGui::IsMouseClicked(ImGuiMouseButton_Left) && !insideVarRegion)
        tab.selectedGlobalVarIndex = -1;

    ImGui::EndChild();
}

static void inputPanel(AppState& app, TabState& tab){
    Environment& state = tab.env;
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(24.0f, 10.0f));
    ImGui::BeginChild("InputPanel", ImVec2(0, 0), true);
    ImGui::PopStyleVar();

    ImGui::Spacing();
    ImGui::AlignTextToFramePadding();
    ImGui::Text("Theme:");
    ImGui::SameLine();
    ImGui::SetNextItemWidth(180.0f);
    int themeIndex = themeToIndex(app.theme);
    if (ImGui::Combo("##theme_bottom", &themeIndex, themeNames, themeCount)) {
        app.theme = indexToTheme(themeIndex);
        applyTheme(app.theme);
        savePreferences(app);
    }

    ImGui::AlignTextToFramePadding();
    ImGui::Text("Title:");
    ImGui::SameLine();
    ImGui::SetNextItemWidth(220.0f);
    const bool pressedEnter = ImGui::InputText("##tab_name",&tab.nameDraft,ImGuiInputTextFlags_EnterReturnsTrue);
    const bool commitName = pressedEnter || ImGui::IsItemDeactivatedAfterEdit();
    if (commitName) normalizeTabTitle(tab);
    ImGui::SameLine();
    if (ImGui::Button("Save")) {
        normalizeTabTitle(tab);
        std::string err;
        if (saveTabToFile(tab, err)) {
            tab.savedFingerprint = buildTabFingerprint(tab);
            tab.inlineSaveMessage = "Saved as '" + tab.savedFileName + "'";
            tab.inlineSaveIsError = false;
        } else {
            tab.inlineSaveMessage = err;
            tab.inlineSaveIsError = true;
        }
    }
    if (!tab.inlineSaveMessage.empty()) {
        const ImVec4 color = tab.inlineSaveIsError
            ? ImVec4(1.0f, 0.45f, 0.45f, 1.0f)
            : ImVec4(0.45f, 1.0f, 0.55f, 1.0f);
        ImGui::TextColored(color, "%s", tab.inlineSaveMessage.c_str());
    }
    ImGui::Spacing();

    // === Model ===
    ImGui::SeparatorText("Model");

    ImGui::AlignTextToFramePadding();
    ImGui::Text("n =");
    ImGui::SameLine();

    ImGui::SetNextItemWidth(60.0f);

    ImGui::InputInt("##n", &state.editN, 0, 0);
    ImVec2 modelControlsMin = ImGui::GetItemRectMin();
    ImVec2 modelControlsMax = ImGui::GetItemRectMax();
    bool commit = ImGui::IsItemDeactivatedAfterEdit();  // Commit when lost focus (press enter unfocus)
    if (commit) state.n = state.editN;

    const int activeModelTick = state.n > 0
        ? ((tab.selectedModelTickIndex >= 0 && tab.selectedModelTickIndex < state.n)
            ? tab.selectedModelTickIndex
            : state.n - 1)
        : -1;
    const float slotButtonWidth = 30.0f;
    const float slotButtonHeight = ImGui::GetFrameHeight();

    ImGui::SameLine();
    if (ImGui::Button("-", ImVec2(slotButtonWidth, slotButtonHeight)) && state.n > 1 && activeModelTick > 0) {
        modelControlsMin.x = std::min(modelControlsMin.x, ImGui::GetItemRectMin().x);
        modelControlsMin.y = std::min(modelControlsMin.y, ImGui::GetItemRectMin().y);
        modelControlsMax.x = std::max(modelControlsMax.x, ImGui::GetItemRectMax().x);
        modelControlsMax.y = std::max(modelControlsMax.y, ImGui::GetItemRectMax().y);
        state.dragX.erase(state.dragX.begin() + activeModelTick);
        state.dragZ.erase(state.dragZ.begin() + activeModelTick);
        state.accel.erase(state.accel.begin() + activeModelTick);
        --state.n;
        state.editN = state.n;
        state.accel[0] = "initV";
        tab.prevN = state.n;
        tab.selectedModelTickIndex = std::max(0, activeModelTick - 1);
    }
    modelControlsMin.x = std::min(modelControlsMin.x, ImGui::GetItemRectMin().x);
    modelControlsMin.y = std::min(modelControlsMin.y, ImGui::GetItemRectMin().y);
    modelControlsMax.x = std::max(modelControlsMax.x, ImGui::GetItemRectMax().x);
    modelControlsMax.y = std::max(modelControlsMax.y, ImGui::GetItemRectMax().y);

    ImGui::SameLine();
    if (ImGui::Button("+", ImVec2(slotButtonWidth, slotButtonHeight))) {
        modelControlsMin.x = std::min(modelControlsMin.x, ImGui::GetItemRectMin().x);
        modelControlsMin.y = std::min(modelControlsMin.y, ImGui::GetItemRectMin().y);
        modelControlsMax.x = std::max(modelControlsMax.x, ImGui::GetItemRectMax().x);
        modelControlsMax.y = std::max(modelControlsMax.y, ImGui::GetItemRectMax().y);
        const int insertIndex = activeModelTick + 1;
        const std::string dragXValue = state.dragX[activeModelTick];
        const std::string dragZValue = state.dragZ[activeModelTick];
        const std::string accelValue = state.accel[activeModelTick];
        state.dragX.insert(state.dragX.begin() + insertIndex, dragXValue);
        state.dragZ.insert(state.dragZ.begin() + insertIndex, dragZValue);
        state.accel.insert(state.accel.begin() + insertIndex, accelValue);
        ++state.n;
        state.editN = state.n;
        state.accel[0] = "initV";
        tab.prevN = state.n;
        tab.selectedModelTickIndex = insertIndex;
    }
    modelControlsMin.x = std::min(modelControlsMin.x, ImGui::GetItemRectMin().x);
    modelControlsMin.y = std::min(modelControlsMin.y, ImGui::GetItemRectMin().y);
    modelControlsMax.x = std::max(modelControlsMax.x, ImGui::GetItemRectMax().x);
    modelControlsMax.y = std::max(modelControlsMax.y, ImGui::GetItemRectMax().y);

    ImGui::AlignTextToFramePadding();
    ImGui::Text("initV =");
    ImGui::SameLine();
    ImGui::SetNextItemWidth(160);
    ImGui::InputText("##model_initV", &state.initV);

    ImGui::Spacing();
    modelTable(tab);
    const ImVec2 mousePos = ImGui::GetIO().MousePos;
    const bool insideModelControls =
        mousePos.x >= modelControlsMin.x && mousePos.x <= modelControlsMax.x &&
        mousePos.y >= modelControlsMin.y && mousePos.y <= modelControlsMax.y;
    const bool insideModelRegion =
        mousePos.x >= tab.modelRegionMin.x && mousePos.x <= tab.modelRegionMax.x &&
        mousePos.y >= tab.modelRegionMin.y && mousePos.y <= tab.modelRegionMax.y;
    if (ImGui::IsMouseClicked(ImGuiMouseButton_Left) && !insideModelControls && !insideModelRegion)
        tab.selectedModelTickIndex = -1;
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

    globalVarTable(tab);

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

    ImGui::AlignTextToFramePadding();
    ImGui::Text("Angle Offset (Manual copying section):");
    ImGui::SameLine(0.0f, 8.0f);
    const char* offsetModes[] = {"Facing", "Turn"};
    ImGui::SetNextItemWidth(90.0f);
    ImGui::Combo("##offsetMode", &state.post.offsetMode, offsetModes, IM_ARRAYSIZE(offsetModes));
    ImGui::SameLine(0.0f, 8.0f);
    if (ImGui::Button("Reset")) {
        std::fill(state.post.angleOffset.begin(), state.post.angleOffset.end(), "0");
    }

    ImGui::BeginChild("angle_offset_region", ImVec2(0, 63.0f), false);
    if (ImGui::BeginTable("angle_offset_table",
                          state.n + 1,
                          ImGuiTableFlags_Borders |
                          ImGuiTableFlags_RowBg |
                          ImGuiTableFlags_ScrollX |
                          ImGuiTableFlags_SizingFixedFit)) {
        ImGui::TableSetupScrollFreeze(1, 0);
        const float columnWidth = 50.0f;

        ImGui::TableNextRow();
        ImGui::TableSetColumnIndex(0);
        centerColumnText("Tick");
        for (int col = 0; col < state.n; col++) {
            ImGui::TableSetColumnIndex(col + 1);
            centerColumnInt(col);
        }

        ImGui::TableNextRow();
        ImGui::TableSetColumnIndex(0);
        centerColumnText("Offset");
        for (int col = 0; col < state.n; col++) {
            ImGui::TableSetColumnIndex(col + 1);
            ImGui::PushID(4000 + col);
            ImGui::SetNextItemWidth(columnWidth);
            ImGui::InputText("##angle_offset", &state.post.angleOffset[col]);
            ImGui::PopID();
        }

        ImGui::EndTable();
    }
    ImGui::EndChild();

    ImGui::AlignTextToFramePadding();
    ImGui::Text("X/Z precision:");
    ImGui::SameLine(0.0f, 8.0f);
    ImGui::SetNextItemWidth(80.0f);
    ImGui::InputInt("##positionPrecision", &state.post.positionPrecision);
    state.post.positionPrecision = std::clamp(state.post.positionPrecision, 3, 10);


    ImGui::PopStyleVar(3);
    ImGui::PopFont();

    if (ImGui::Button("Optimize!!", ImVec2(-1, 35)))
        runOptimizer(state);

    ImGui::EndChild();
}

static constexpr double minGridPx = 67.0;
static constexpr double maxGridPx = 100.0;
static constexpr float plotPad = 30.0f;

struct XZPlotLayout {
    double minX = 0.0;
    double maxX = 0.0;
    double minZ = 0.0;
    double maxZ = 0.0;
    double rangeX = 1.0;
    double rangeZ = 1.0;
    double centerX = 0.0;
    double centerZ = 0.0;
    double scale = minGridPx;
    float contentWidth = 2.0f * plotPad;
    float contentHeight = 2.0f * plotPad;
};

static XZPlotLayout computeXZPlotLayout(const std::vector<double>& xs, const std::vector<double>& zs, ImVec2 size) {
    XZPlotLayout layout;
    if (xs.empty() || xs.size() != zs.size()) return layout;

    layout.minX = *std::min_element(xs.begin(), xs.end());
    layout.maxX = *std::max_element(xs.begin(), xs.end());
    layout.minZ = *std::min_element(zs.begin(), zs.end());
    layout.maxZ = *std::max_element(zs.begin(), zs.end());

    if (layout.minX == layout.maxX) { layout.minX -= 0.5; layout.maxX += 0.5; }
    if (layout.minZ == layout.maxZ) { layout.minZ -= 0.5; layout.maxZ += 0.5; }

    layout.rangeX = std::max(layout.maxX - layout.minX, 1e-3);
    layout.rangeZ = std::max(layout.maxZ - layout.minZ, 1e-3);
    layout.centerX = 0.5 * (layout.minX + layout.maxX);
    layout.centerZ = 0.5 * (layout.minZ + layout.maxZ);

    const float plotW = std::max(1.0f, size.x - 2.0f * plotPad);
    const float plotH = std::max(1.0f, size.y - 2.0f * plotPad);
    layout.scale = std::clamp(std::min(plotW / layout.rangeX, plotH / layout.rangeZ), minGridPx, maxGridPx);
    layout.contentWidth = static_cast<float>(layout.rangeX * layout.scale + 2.0f * plotPad);
    layout.contentHeight = static_cast<float>(layout.rangeZ * layout.scale + 2.0f * plotPad);
    return layout;
}

static void drawXZPlot(const std::vector<double>& Xs, const std::vector<double>& Zs, const std::vector<double>& facings, const std::vector<std::string>& VXs, const std::vector<std::string>& VZs,
                       ImVec2 size, int positionPrecision, int anglePrecision) {
    if (Xs.empty() || Xs.size() != Zs.size()) return;

    ImVec2 p0 = ImGui::GetCursorScreenPos();
    ImVec2 p1(p0.x + size.x, p0.y + size.y);

    ImGui::InvisibleButton("##xzplot", size);
    ImDrawList* dl = ImGui::GetWindowDrawList();
    const bool plotHovered = ImGui::IsItemHovered();

    dl->AddRectFilled(p0, p1, IM_COL32(20, 20, 20, 255), 6.0f);
    dl->AddRect(p0, p1, IM_COL32(90, 90, 90, 255), 6.0f);

    const XZPlotLayout layout = computeXZPlotLayout(Xs, Zs, size);
    const ImVec2 center(p0.x + size.x * 0.5f, p0.y + size.y * 0.5f);

    auto toScreen = [&](double x, double z) -> ImVec2 {
        return ImVec2(
            center.x + float((x - layout.centerX) * layout.scale),
            center.y - float((z - layout.centerZ) * layout.scale)
        );
    };

    dl->PushClipRect(p0, p1, true);

    const ImU32 gridColor = IM_COL32(150, 150, 150, 150);
    const ImU32 axisColor = IM_COL32(200, 200, 200, 180);

    const double canvasMinX = layout.centerX - (size.x * 0.5f) / layout.scale;
    const double canvasMaxX = layout.centerX + (size.x * 0.5f) / layout.scale;
    const double canvasMinZ = layout.centerZ - (size.y * 0.5f) / layout.scale;
    const double canvasMaxZ = layout.centerZ + (size.y * 0.5f) / layout.scale;
    const ImVec2 mousePos = ImGui::GetIO().MousePos;
    constexpr float hoverRadius = 8.0f;
    const float hoverRadiusSq = hoverRadius * hoverRadius;
    int hoveredIndex = -1;
    float bestDistSq = hoverRadiusSq;

    for (int gx = static_cast<int>(std::ceil(canvasMinX)); gx <= static_cast<int>(std::floor(canvasMaxX)); gx++) {
        const float x = toScreen(static_cast<double>(gx), layout.centerZ).x;
        dl->AddLine(ImVec2(x, p0.y), ImVec2(x, p1.y),
                    gx == 0 ? axisColor : gridColor,
                    gx == 0 ? 1.6f : 1.0f);
    }

    for (int gz = static_cast<int>(std::ceil(canvasMinZ)); gz <= static_cast<int>(std::floor(canvasMaxZ)); gz++) {
        const float y = toScreen(layout.centerX, static_cast<double>(gz)).y;
        dl->AddLine(ImVec2(p0.x, y), ImVec2(p1.x, y),
                    gz == 0 ? axisColor : gridColor,
                    gz == 0 ? 1.6f : 1.0f);
    }

    for (int i = 1; i < (int)Xs.size(); i++) {
        dl->AddLine(
            toScreen(Xs[i - 1], Zs[i - 1]),
            toScreen(Xs[i], Zs[i]),
            IM_COL32(192, 192, 200, 255),
            2.0f
        );
    }

    for (int i = 0; i < (int)Xs.size(); i++) {
        const ImVec2 point = toScreen(Xs[i], Zs[i]);
        if (plotHovered) {
            const float dx = point.x - mousePos.x;
            const float dy = point.y - mousePos.y;
            const float distSq = dx * dx + dy * dy;
            if (distSq <= bestDistSq) {
                bestDistSq = distSq;
                hoveredIndex = i;
            }
        }
        dl->AddCircleFilled(point, 3.5f, IM_COL32(240, 240, 240, 255));
    }

    if (hoveredIndex >= 0) {
        const ImVec2 point = toScreen(Xs[hoveredIndex], Zs[hoveredIndex]);
        dl->AddCircle(point, 7.0f, IM_COL32(255, 255, 255, 220), 0, 1.8f);
    }

    dl->PopClipRect();

    if (hoveredIndex >= 0) {
        auto fmt_double = [](double v, int prec) -> std::string {
            std::ostringstream oss;
            oss << std::fixed << std::setprecision(prec) << v;
            return oss.str();
        };

        ImGui::BeginTooltip();
        ImGui::Text("Tick %d", hoveredIndex);
        ImGui::Separator();
        ImGui::Text("Facing:  %s", fmt_double(facings[hoveredIndex], anglePrecision).c_str());
        ImGui::Text("Pos:  (%s, %s)", fmt_double(Xs[hoveredIndex], positionPrecision).c_str(), fmt_double(Zs[hoveredIndex], positionPrecision).c_str());
        ImGui::Text("Vel: (%s, %s)", VXs[hoveredIndex].c_str(), VZs[hoveredIndex].c_str());
        if((size_t) hoveredIndex < Xs.size() - 1){
            double vx = Xs[hoveredIndex + 1] - Xs[hoveredIndex];
            double vz = Zs[hoveredIndex + 1] - Zs[hoveredIndex];
            double magnitude = std::sqrt(vx * vx + vz * vz);
            double direction = std::atan2(vx, vz) * 180.0 / std::numbers::pi_v<double>;
            ImGui::Text("SpeedVec: (%s, %s°)", fmt_double(magnitude, positionPrecision).c_str(), fmt_double(direction, positionPrecision).c_str());
        }
        ImGui::EndTooltip();
    }
}

static float computeXZPlotCanvasWidth(const std::vector<double>& xs, const std::vector<double>& zs, float viewportWidth, float plotHeight) {
    if (xs.empty() || xs.size() != zs.size()) return viewportWidth;
    const XZPlotLayout layout = computeXZPlotLayout(xs, zs, ImVec2(viewportWidth, plotHeight));
    return std::max(viewportWidth, layout.contentWidth);
}

static ImVec2 computeXZPlotViewportSize(const std::vector<double>& xs, const std::vector<double>& zs) {
    constexpr float minPlotSize = 250.0f;
    constexpr float maxPlotSize = 1000.0f;
    if (xs.empty() || xs.size() != zs.size()) return ImVec2(minPlotSize, minPlotSize);
    const XZPlotLayout heightLayout = computeXZPlotLayout(xs, zs, ImVec2(minPlotSize, maxPlotSize));
    const float viewportHeight = std::clamp(heightLayout.contentHeight, minPlotSize, maxPlotSize);
    const float contentWidth = computeXZPlotCanvasWidth(xs, zs, 0.0f, viewportHeight);
    return ImVec2(
        std::clamp(contentWidth, minPlotSize, maxPlotSize),
        viewportHeight
    );
} 


static void outputPanel(TabState& tab){
    Environment& state = tab.env;
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
    constexpr int anglePrecision = 3;
    const int positionPrecision = std::clamp(state.post.positionPrecision, 3, 10);

    ImGui::Spacing();
    ImGui::PushFont(bigCodeFont);
    ImGui::TextColored(ImVec4(0.8f,0.85f,1.0f,1.0f), "=> %.12f", sol.optimum);
    ImGui::PopFont();

    ImGui::Spacing();
    ImGui::Spacing();

    int T = (int)sol.Xs.size();

    std::vector<double> facings(T, 0.0);
    for (int t = 0; t < (int)sol.thetas.size(); t++) {
        double deg = sol.thetas[t] * 180.0 / std::numbers::pi_v<double>;
        double wrapped = std::fmod(deg + 180.0, 360.0);
        if (wrapped < 0) wrapped += 360.0;
        wrapped -= 180.0;

        wrapped = std::round(200.0 * wrapped) * 0.005;

        facings[t] = wrapped;
    }

    auto fmt_double = [](double v, int prec) -> std::string {
        std::ostringstream oss;
        oss << std::fixed << std::setprecision(prec) << v;
        return oss.str();
    };

    std::vector<std::string> turns(T, "-");
    for (int t = 0; t < T - 2; t++) {
        double d = facings[t + 1] - facings[t];
        turns[t] = fmt_double(d, anglePrecision);
    }

    std::vector<double> xvals(T);
    std::vector<double> zvals(T);
    for (int t = 0; t < T; t++) {
        xvals[t] = sol.Xs[t] - sol.Xs[state.xIndex] - state.xAdd;
        zvals[t] = sol.Zs[t] - sol.Zs[state.zIndex] - state.zAdd;
    }

    std::vector<std::string> vxvals(T, "-");
    std::vector<std::string> vzvals(T, "-");

    for (int t = 0; t + 1 < T; t++) {
        double vx = xvals[t + 1] - xvals[t];
        double vz = zvals[t + 1] - zvals[t];

        vxvals[t] = fmt_double(vx, positionPrecision);
        vzvals[t] = fmt_double(vz, positionPrecision);
    }

    ImGui::PushStyleVar(ImGuiStyleVar_CellPadding, ImVec2(10.0f, 3.0f));
    constexpr float tableContentWidth = 877.0f;
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
            const std::string angle = (t < T-1)? fmt_double(facings[t], anglePrecision) : "-";
            const std::string x = fmt_double(xvals[t], positionPrecision);
            const std::string z = fmt_double(zvals[t], positionPrecision);

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
    ImGui::Spacing();

    auto formatFacingList = [&](const std::vector<double>& Fs){
        std::string s = "{";
        for (int i = 0; i < (int)Fs.size() - 1; i++) {
            if (i) s += ", ";
            double f = Fs[i] + state.angleOffset[i];
            s += fmt_double(f, anglePrecision);
        }
        s += "}";
        return s;
    };

    auto formatTurnList = [&](const std::vector<double>& Fs){
        std::string s = "{";
        for (int i = 0; i + 1 < (int)Fs.size() - 1; i++) {
            if (i) s += ", ";
            double f0 = Fs[i] + state.angleOffset[i];
            double f1 = Fs[i + 1] + state.angleOffset[i + 1];
            s += fmt_double(f1 - f0, anglePrecision);
        }
        s += "}";
        return s;
    };

    std::string facingList = formatFacingList(facings);
    std::string turnList = formatTurnList(facings);
    ImVec2 plotViewportSize = computeXZPlotViewportSize(xvals, zvals);
    const float plotCanvasWidth = computeXZPlotCanvasWidth(xvals, zvals, plotViewportSize.x, plotViewportSize.y);
    plotViewportSize.x += 25.0f;
    plotViewportSize.y += 50.0f;

    readOnlyBlock("Facing", facingList, 30.0f, true);
    ImGui::Spacing();
    readOnlyBlock("Turn", turnList, 30.0f, true);

    ImGui::Spacing();
    ImGui::Spacing();
    ImGui::PushFont(uiFont);
    ImGui::Text("Visualization");
    ImGui::PopFont();
    ImGui::BeginChild("PlotScroll", ImVec2(plotViewportSize.x, plotViewportSize.y + 20.0f), true, ImGuiWindowFlags_HorizontalScrollbar);
    if (ImGui::IsWindowAppearing()) {
        ImGui::SetScrollX(std::max(0.0f, 0.5f * (plotCanvasWidth - plotViewportSize.x)));
    }
    drawXZPlot(xvals, zvals, facings, vxvals, vzvals,
               ImVec2(plotCanvasWidth, plotViewportSize.y), positionPrecision, anglePrecision);
    ImGui::EndChild();
    ImGui::Spacing();


    ImGui::PopFont();

    ImGui::EndChild();
    ImGui::EndChild();
}

static void optimizerMenu(AppState& app) {
    app.activeTab = std::clamp(app.activeTab, 0, static_cast<int>(app.tabs.size()) - 1);

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

    TopBarResult top = renderTopBar(app);
    if (top.requestClosePopupTabId >= 0) {
        app.pendingCloseTabId = top.requestClosePopupTabId;
        app.closePopupError.clear();
        ImGui::OpenPopup("Save Tab Before Closing?");
    }
    if (top.closeNowTabId >= 0)
        closeTabById(app, top.closeNowTabId, top.activeIndex);
    handleClosePopup(app, top.activeIndex);
    app.activeTab = std::clamp(top.activeIndex, 0, static_cast<int>(app.tabs.size()) - 1);

    TabState& tab = app.tabs[app.activeTab];

    const float totalWidth = ImGui::GetContentRegionAvail().x;
    const float totalHeight = ImGui::GetContentRegionAvail().y;
    const float dividerWidth = 8.0f;
    const float minPanelWidth = 250.0f;

    if (tab.leftWidth <= 0.0f)
        tab.leftWidth = totalWidth * 0.7f;

    tab.leftWidth = std::clamp(tab.leftWidth, minPanelWidth, totalWidth - minPanelWidth - dividerWidth);
    float rightWidth = totalWidth - tab.leftWidth - dividerWidth;

    ImGui::BeginChild("LeftRegion", ImVec2(tab.leftWidth, totalHeight), false);
    inputPanel(app, tab);
    ImGui::EndChild();

    ImGui::SameLine(0.0f, 0.0f);
    ImVec2 dividerPos = ImGui::GetCursorScreenPos();
    ImGui::InvisibleButton("Divider", ImVec2(dividerWidth, totalHeight), ImGuiButtonFlags_MouseButtonLeft);

    const bool dividerHovered = ImGui::IsItemHovered();
    const bool dividerActive = ImGui::IsItemActive();
    if (dividerHovered || dividerActive)
        ImGui::SetMouseCursor(ImGuiMouseCursor_ResizeEW);
    
    if (dividerActive) {
        tab.leftWidth += ImGui::GetIO().MouseDelta.x;
        tab.leftWidth = std::clamp(tab.leftWidth, minPanelWidth, totalWidth - minPanelWidth - dividerWidth);
        rightWidth = totalWidth - tab.leftWidth - dividerWidth;
    }

    ImDrawList* drawList = ImGui::GetWindowDrawList();
    const ImU32 dividerColor = dividerActive
        ? ImGui::GetColorU32(ImGuiCol_SeparatorActive)
        : (dividerHovered ? ImGui::GetColorU32(ImGuiCol_SeparatorHovered)
                          : ImGui::GetColorU32(ImGuiCol_Separator));
    drawList->AddRectFilled(dividerPos, ImVec2(dividerPos.x + dividerWidth, dividerPos.y + totalHeight), dividerColor);

    ImGui::SameLine(0.0f, 0.0f);

    ImGui::BeginChild("RightRegion", ImVec2(rightWidth, totalHeight), false);
    outputPanel(tab);
    ImGui::EndChild();

    ImGui::End();
}

int main() {
    glfwSetErrorCallback(glfw_error_callback);
    if (!glfwInit()) return 1;
    initPaths();

    GLFWwindow* window = nullptr;
    const char* glslVersion = "#version 330 core";

    auto tryCreateWindow = [&](int major, int minor, bool requestProfile) -> bool {
        glfwDefaultWindowHints();
        if (major > 0 && minor > 0) {
            glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, major);
            glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, minor);
        }
#if defined(__APPLE__)
        (void)requestProfile;
        glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);
        glfwWindowHint(GLFW_OPENGL_FORWARD_COMPAT, GL_TRUE);
#else
        if (requestProfile) {
            glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);
        }
#endif
        window = glfwCreateWindow(1100, 720, title, nullptr, nullptr);
        if (!window) return false;
        glfwMakeContextCurrent(window);
        if (glfwGetCurrentContext() != window) {
            glfwDestroyWindow(window);
            window = nullptr;
            return false;
        }
        return true;
    };

#if defined(__APPLE__)
    if (!tryCreateWindow(3, 3, true)) return 1;
    glslVersion = "#version 330 core";
#else
    // Windows/Linux fallback chain for driver compatibility.
    if (tryCreateWindow(3, 3, false)) {
        glslVersion = "#version 130";
    } else if (tryCreateWindow(3, 0, false)) {
        glslVersion = "#version 130";
    } else if (tryCreateWindow(0, 0, false)) {
        glslVersion = "#version 130";
    } else {
        return 1;
    }
#endif

    glfwSwapInterval(1);
#if defined(_WIN32)
    HICON nativeWindowIcon = setNativeWindowIcon(window);
#endif

    IMGUI_CHECKVERSION();
    AppState app;
    loadPreferences(app);
    ImGui::CreateContext();
    applyTheme(app.theme);
    initFont();

    app.tabs.push_back(makeDefaultTab(app.nextTabId++));
    nfdReady = initFileDialog(nfdInitError);
    if (!nfdReady) {
        setInlineStatus(app.tabs[0], "Load failed: " + nfdInitError, true);
    }

    ImGui_ImplGlfw_InitForOpenGL(window, true);
    ImGui_ImplOpenGL3_Init(glslVersion);

    bool running = true;
    bool showExitSavePrompt = false;
    bool openExitSavePopupNextFrame = false;
    std::string exitSaveError;

    while (running) {
        glfwPollEvents();
        if (glfwWindowShouldClose(window)) {
            glfwSetWindowShouldClose(window, GLFW_FALSE);
            if (hasModifiedTabs(app)) {
                showExitSavePrompt = true;
                openExitSavePopupNextFrame = true;
                exitSaveError.clear();
            } else {
                running = false;
                continue;
            }
        }

        ImGui_ImplOpenGL3_NewFrame();
        ImGui_ImplGlfw_NewFrame();
        ImGui::NewFrame();

        bool pushed_font = false;
        if (uiFont != nullptr) {
            ImGui::PushFont(uiFont);
            pushed_font = true;
        }

        optimizerMenu(app);

        if (openExitSavePopupNextFrame) {
            ImGui::OpenPopup("Save Changes Before Exit?");
            openExitSavePopupNextFrame = false;
        }

        if (showExitSavePrompt && ImGui::BeginPopupModal("Save Changes Before Exit?", nullptr, ImGuiWindowFlags_AlwaysAutoResize)) {
            ImGui::Text("There are unsaved tabs. Save before exiting?");
            if (!exitSaveError.empty())
                ImGui::TextColored(ImVec4(1.0f, 0.45f, 0.45f, 1.0f), "%s", exitSaveError.c_str());
            ImGui::Spacing();

            if (ImGui::Button("Save All", ImVec2(120, 0))) {
                std::string err;
                if (saveAllModifiedTabs(app, err)) {
                    running = false;
                    showExitSavePrompt = false;
                    openExitSavePopupNextFrame = false;
                    ImGui::CloseCurrentPopup();
                } else {
                    exitSaveError = err;
                }
            }
            ImGui::SameLine();
            if (ImGui::Button("Discard All", ImVec2(120, 0))) {
                running = false;
                showExitSavePrompt = false;
                openExitSavePopupNextFrame = false;
                ImGui::CloseCurrentPopup();
            }
            ImGui::SameLine();
            if (ImGui::Button("Cancel", ImVec2(120, 0))) {
                showExitSavePrompt = false;
                openExitSavePopupNextFrame = false;
                exitSaveError.clear();
                ImGui::CloseCurrentPopup();
            }
            ImGui::EndPopup();
        }

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
    if (nfdReady) shutdownFileDialog();
    savePreferences(app);
#if defined(_WIN32)
    if (nativeWindowIcon != nullptr) DestroyIcon(nativeWindowIcon);
#endif
    glfwDestroyWindow(window);
    glfwTerminate();
    return 0;
}

// ---- Serialization / Deserialization, complete coded by AI -------
static json buildTabJson(const TabState& tab) {
    const Environment& e = tab.env;
    return json{
        {"title", tab.name},
        {"maximize", e.maximize},
        {"currObj", static_cast<int>(e.currObj)},
        {"n", e.n},
        {"initV", e.initV},
        {"dragX", e.dragX},
        {"dragZ", e.dragZ},
        {"accel", e.accel},
        {"globalNames", e.globalNames},
        {"globalValues", e.globalValues},
        {"objScript", e.objScript},
        {"constraintScript", e.constraintScript},
        {"post", {
            {"xTick", e.post.xTick},
            {"xAdd", e.post.xAdd},
            {"zTick", e.post.zTick},
            {"zAdd", e.post.zAdd},
            {"angleOffset", e.post.angleOffset},
            {"offsetMode", e.post.offsetMode},
            {"positionPrecision", e.post.positionPrecision},
        }}
    };
}

static std::string buildTabFingerprint(const TabState& tab) {
    return buildTabJson(tab).dump();
}

static bool isTabModified(const TabState& tab) {
    return buildTabFingerprint(tab) != tab.savedFingerprint;
}

static std::string safeFileName(std::string name) {
    for (char& ch : name) {
        const bool forbidden =
            ch == '/' || ch == '\\' || ch == ':' || ch == '*' || ch == '?' ||
            ch == '"' || ch == '<' || ch == '>' || ch == '|';
        if (forbidden || static_cast<unsigned char>(ch) < 32) ch = '_';
    }
    const size_t start = name.find_first_not_of(" \t\n\r\f\v");
    if (start == std::string::npos) {
        name.clear();
    } else {
        const size_t end = name.find_last_not_of(" \t\n\r\f\v");
        name.erase(end + 1);
        name.erase(0, start);
    }
    while (!name.empty() && (name.back() == '.' || name.back() == ' ')) name.pop_back();
    if (name.empty()) name = "Untitled";
    return name;
}

static bool saveTabToFile(TabState& tab, std::string& err) {
    try {
        std::filesystem::create_directories(tabsDirPath);
        const std::string baseName = safeFileName(tab.name);
        const std::string fileName = baseName + ".json";
        const std::filesystem::path path = tabsDirPath / fileName;
        const bool isRenameTarget = tab.savedFileName != fileName;
        const bool hasOldFile = !tab.savedFileName.empty();
        const std::filesystem::path oldPath = tabsDirPath / tab.savedFileName;
        if (isRenameTarget && std::filesystem::exists(path)) {
            err = "Name already taken: " + fileName + ". Choose another title.";
            return false;
        }

        std::ofstream out(path, std::ios::trunc);
        if (!out) {
            err = "Failed to open " + path.string();
            return false;
        }
        out << buildTabJson(tab).dump(2) << "\n";
        if (!out.good()) {
            err = "Failed to write " + path.string();
            return false;
        }

        if (isRenameTarget && hasOldFile && std::filesystem::exists(oldPath)) {
            std::error_code removeErr;
            std::filesystem::remove(oldPath, removeErr);
            if (removeErr) {
                err = "Saved to " + fileName + ", but failed to remove old file: " + tab.savedFileName;
                return false;
            }
        }

        tab.savedFileName = fileName;
        return true;
    } catch (const std::exception& e) {
        err = e.what();
        return false;
    }
}

static bool parseOptionalStringVector(const json& obj, const char* key, std::vector<std::string>& out, std::string& err) {
    if (!obj.contains(key)) return true;
    try {
        out = obj.at(key).get<std::vector<std::string>>();
        return true;
    } catch (...) {
        err = std::string("Invalid field: ") + key;
        return false;
    }
}

static bool loadTabFromJson(TabState& tab, const json& j, std::string& err) {
    try {
        Environment loaded;
        loaded.maximize = j.value("maximize", loaded.maximize);

        const int objIndex = j.value("currObj", static_cast<int>(loaded.currObj));
        if (objIndex < 0 || objIndex > 2) {
            err = "Invalid field: currObj";
            return false;
        }
        loaded.currObj = static_cast<Environment::objectiveType>(objIndex);

        loaded.n = j.value("n", loaded.n);
        loaded.n = std::clamp(loaded.n, nMin, nMax);
        loaded.editN = loaded.n;
        loaded.initV = j.value("initV", loaded.initV);
        loaded.objScript = j.value("objScript", loaded.objScript);
        loaded.constraintScript = j.value("constraintScript", loaded.constraintScript);

        if (!parseOptionalStringVector(j, "dragX", loaded.dragX, err)) return false;
        if (!parseOptionalStringVector(j, "dragZ", loaded.dragZ, err)) return false;
        if (!parseOptionalStringVector(j, "accel", loaded.accel, err)) return false;
        if (!parseOptionalStringVector(j, "globalNames", loaded.globalNames, err)) return false;
        if (!parseOptionalStringVector(j, "globalValues", loaded.globalValues, err)) return false;

        if (static_cast<int>(loaded.dragX.size()) != loaded.n ||
            static_cast<int>(loaded.dragZ.size()) != loaded.n ||
            static_cast<int>(loaded.accel.size()) != loaded.n) {
            err = "dragX/dragZ/accel sizes must match n";
            return false;
        }

        if (loaded.globalNames.size() != loaded.globalValues.size()) {
            err = "globalNames/globalValues size mismatch";
            return false;
        }
        loaded.varCapacity = static_cast<int>(loaded.globalNames.size());
        if (loaded.varCapacity < 1) {
            loaded.varCapacity = 1;
            loaded.globalNames = {""};
            loaded.globalValues = {""};
        }

        if (j.contains("post")) {
            const json& post = j.at("post");
            loaded.post.xTick = post.value("xTick", loaded.post.xTick);
            loaded.post.xAdd = post.value("xAdd", loaded.post.xAdd);
            loaded.post.zTick = post.value("zTick", loaded.post.zTick);
            loaded.post.zAdd = post.value("zAdd", loaded.post.zAdd);
            if (post.contains("angleOffset")) {
                const json& angleOffset = post.at("angleOffset");
                if (angleOffset.is_array()) {
                    loaded.post.angleOffset = angleOffset.get<std::vector<std::string>>();
                } else if (angleOffset.is_string()) {
                    loaded.post.angleOffset = {angleOffset.get<std::string>()};
                } else {
                    err = "Invalid field: post.angleOffset";
                    return false;
                }
            }
            loaded.post.offsetMode = post.value("offsetMode", loaded.post.offsetMode);
            if (loaded.post.offsetMode < Environment::Post::Facing ||
                loaded.post.offsetMode > Environment::Post::Turn) {
                err = "Invalid field: post.offsetMode";
                return false;
            }
            loaded.post.positionPrecision = post.value("positionPrecision", loaded.post.positionPrecision);
        }
        loaded.post.angleOffset.resize(loaded.n, loaded.post.angleOffset.empty() ? "0" : loaded.post.angleOffset.back());

        tab.name = j.value("title", tab.name);
        trim(tab.name);
        if (tab.name.empty()) tab.name = "Untitled " + std::to_string(tab.id);
        tab.nameDraft = tab.name;
        tab.env = loaded;
        tab.prevN = loaded.n;
        tab.env.lastSol.reset();
        tab.env.lastError.clear();
        tab.inlineSaveMessage.clear();
        tab.inlineSaveIsError = false;
        return true;
    } catch (const std::exception& e) {
        err = e.what();
        return false;
    }
}

static bool choosePresetFile(std::string& outPath, std::string& err) {
    if (!nfdReady) {
        err = nfdInitError.empty() ? "File dialog is unavailable." : nfdInitError;
        return false;
    }

    const std::string defaultDir = std::filesystem::absolute(tabsDirPath).string();
    nfdu8char_t* pickedPath = nullptr;
    nfdu8filteritem_t filterItem[1] = {{"JSON", "json"}};
    const nfdresult_t res = NFD_OpenDialogU8(&pickedPath, filterItem, 1, defaultDir.c_str());

    if (res == NFD_OKAY) {
        outPath = pickedPath;
        NFD_FreePathU8(pickedPath);
        return true;
    }
    if (res == NFD_CANCEL) {
        err.clear();
        return false;
    }
    const char* nfdErr = NFD_GetError();
    if (nfdErr && *nfdErr)
        err = nfdErr;
    else
        err = "File picker failed.";
    return false;
}

static bool initFileDialog(std::string& err) {
    const nfdresult_t res = NFD_Init();
    if (res == NFD_OKAY) return true;
    const char* nfdErr = NFD_GetError();
    if (nfdErr && *nfdErr)
        err = nfdErr;
    else
        err = "NFD_Init failed.";
    return false;
}

static void shutdownFileDialog() {
    NFD_Quit();
}

static void savePreferences(const AppState& app) {
    std::ofstream out(preferencePath, std::ios::trunc);
    if (!out) return;
    const json pref = {
        {"themeIndex", themeToIndex(app.theme)}
    };
    out << pref.dump(2) << "\n";
}

static void loadPreferences(AppState& app) {
    std::ifstream in(preferencePath);
    if (!in) return;
    try {
        json pref;
        in >> pref;
        const int parsed = pref.value("themeIndex", themeToIndex(app.theme));
        app.theme = indexToTheme(parsed);
    } catch (...) {
        // Ignore invalid preference file
    }
}

static int findTabIndexById(const AppState& app, int id) {
    for (int i = 0; i < static_cast<int>(app.tabs.size()); i++) {
        if (app.tabs[i].id == id) return i;
    }
    return -1;
}

static void closeTabById(AppState& app, int tabId, int& activeIndex) {
    const int idx = findTabIndexById(app, tabId);
    if (idx < 0) return;
    if (static_cast<int>(app.tabs.size()) <= 1) {
        app.tabs[0] = makeDefaultTab(app.nextTabId++);
        activeIndex = 0;
        return;
    }

    app.tabs.erase(app.tabs.begin() + idx);
    if (activeIndex > idx) activeIndex--;
    if (activeIndex >= static_cast<int>(app.tabs.size()))
        activeIndex = static_cast<int>(app.tabs.size()) - 1;
}

static void setInlineStatus(TabState& tab, const std::string& message, bool isError) {
    tab.inlineSaveMessage = message;
    tab.inlineSaveIsError = isError;
}

static void loadPresetIntoTab(TabState& tab, const std::string& selectedPath) {
    std::ifstream in(selectedPath);
    if (!in) {
        setInlineStatus(tab, "Load failed: unable to open file.", true);
        return;
    }

    try {
        json j;
        in >> j;
        std::string loadErr;
        if (!loadTabFromJson(tab, j, loadErr)) {
            setInlineStatus(tab, "Load failed: " + loadErr, true);
            return;
        }
        tab.savedFileName = std::filesystem::path(selectedPath).filename().string();
        tab.savedFingerprint = buildTabFingerprint(tab);
        setInlineStatus(tab, "Loaded: " + tab.savedFileName, false);
    } catch (...) {
        setInlineStatus(tab, "Load failed: invalid JSON file.", true);
    }
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
    RGB tabBg = mix(dark, accent, 0.28f);
    RGB tabActive = mix(dark, accent, 0.52f);

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

    c[ImGuiCol_Tab]               = rgba(tabBg, 0.90f);
    c[ImGuiCol_TabHovered]        = rgba(tabActive, 0.95f);
    c[ImGuiCol_TabActive]         = rgba(tabActive, 1.00f);
    c[ImGuiCol_TabUnfocused]      = rgba(tabBg, 0.70f);
    c[ImGuiCol_TabUnfocusedActive]= rgba(tabActive, 0.80f);
}

static void applyTheme(AppState::Theme theme) {
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

    switch (theme){
        case AppState::Theme::Obsidian:      applyAccent({0.45f, 0.39f, 0.60f}); break;
        case AppState::Theme::Curry:         applyAccent({0.92f, 0.69f, 0.22f}); break;
        case AppState::Theme::LuminousAbyss: applyAccent({0.38f, 0.74f, 0.80f}); break;
        case AppState::Theme::CherryBlossom: applyAccent({0.86f, 0.57f, 0.75f}); break;
        case AppState::Theme::CrimsonForest: applyAccent({0.85f, 0.32f, 0.36f}); break;
    }
}
