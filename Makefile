CXX ?= c++
TARGET := main
BUILD_DIR := build
UNAME_S := $(shell uname -s)
PKG_CONFIG ?= pkg-config

SRC := \
	main.cpp \
	optimizer.cpp \
	parser.cpp \
	imgui/imgui.cpp \
	imgui/imgui_draw.cpp \
	imgui/imgui_widgets.cpp \
	imgui/imgui_tables.cpp \
	imgui/backends/imgui_impl_glfw.cpp \
	imgui/backends/imgui_impl_opengl3.cpp \
	imgui/misc/cpp/imgui_stdlib.cpp

# Platform-specific NFD backend
ifeq ($(UNAME_S),Darwin)
SRC += thirdParty/nfd/src/nfd_cocoa.m
endif
ifeq ($(UNAME_S),Linux)
SRC += thirdParty/nfd/src/nfd_gtk.cpp
endif
ifneq (,$(findstring MINGW,$(UNAME_S)))
SRC += thirdParty/nfd/src/nfd_win.cpp
endif
ifneq (,$(findstring MSYS,$(UNAME_S)))
SRC += thirdParty/nfd/src/nfd_win.cpp
endif
ifeq ($(OS),Windows_NT)
SRC += thirdParty/nfd/src/nfd_win.cpp
endif

OBJ := $(addprefix $(BUILD_DIR)/,$(patsubst %.cpp,%.o,$(patsubst %.m,%.o,$(SRC))))
DEP := $(OBJ:.o=.d)

CPPFLAGS := -Iimgui -Iimgui/backends -IthirdParty/nfd/src/include
CXXFLAGS := -std=c++20 -Wall -Wextra -MMD -MP -ffp-contract=off
OBJCFLAGS := -Wall -Wextra -MMD -MP
LDLIBS := -lglfw

ifeq ($(UNAME_S),Darwin)
CXX := clang++
CPPFLAGS += -I/opt/homebrew/include -DGL_SILENCE_DEPRECATION
LDFLAGS += -L/opt/homebrew/lib \
	-framework OpenGL \
	-framework Cocoa \
	-framework IOKit \
	-framework CoreVideo \
	-framework UniformTypeIdentifiers
endif

ifeq ($(UNAME_S),Linux)
GTK_CFLAGS := $(shell $(PKG_CONFIG) --cflags gtk+-3.0 2>/dev/null)
GTK_LIBS := $(shell $(PKG_CONFIG) --libs gtk+-3.0 2>/dev/null)
CPPFLAGS += $(GTK_CFLAGS)
LDLIBS += $(GTK_LIBS) -lGL -ldl -lpthread
endif

ifneq (,$(findstring MINGW,$(UNAME_S)))
LDLIBS += -lopengl32 -lgdi32 -lshell32 -lcomdlg32 -lole32 -luuid
endif
ifneq (,$(findstring MSYS,$(UNAME_S)))
LDLIBS += -lopengl32 -lgdi32 -lshell32 -lcomdlg32 -lole32 -luuid
endif
ifeq ($(OS),Windows_NT)
LDLIBS += -lopengl32 -lgdi32 -lshell32 -lcomdlg32 -lole32 -luuid
endif

.PHONY: all debug release clean

all: debug

debug: CXXFLAGS += -O1 -g
debug: $(BUILD_DIR)/$(TARGET)

release: CXXFLAGS += -O3
release: $(BUILD_DIR)/$(TARGET)

$(BUILD_DIR)/$(TARGET): $(OBJ)
	$(CXX) $(OBJ) $(LDFLAGS) $(LDLIBS) -o $@

$(BUILD_DIR)/%.o: %.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -c $< -o $@

$(BUILD_DIR)/%.o: %.m
	@mkdir -p $(dir $@)
	clang $(CPPFLAGS) $(OBJCFLAGS) -c $< -o $@

clean:
	rm -f $(BUILD_DIR)/$(TARGET) $(OBJ) $(DEP)

-include $(DEP)
