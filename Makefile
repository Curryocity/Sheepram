CXX := clang++
TARGET := main

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

OBJ := $(SRC:.cpp=.o)
DEP := $(OBJ:.o=.d)

CPPFLAGS := -Iimgui -Iimgui/backends -I/opt/homebrew/include -DGL_SILENCE_DEPRECATION
CXXFLAGS := -std=c++20 -Wall -Wextra -MMD -MP -ffp-contract=off
LDFLAGS := -L/opt/homebrew/lib \
	-framework OpenGL \
	-framework Cocoa \
	-framework IOKit \
	-framework CoreVideo
LDLIBS := -lglfw

.PHONY: all debug release clean

all: debug

debug: CXXFLAGS += -O1 -g
debug: $(TARGET)

release: CXXFLAGS += -O3
release: $(TARGET)

$(TARGET): $(OBJ)
	$(CXX) $(OBJ) $(LDFLAGS) $(LDLIBS) -o $@

%.o: %.cpp
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -c $< -o $@

clean:
	rm -f $(TARGET) $(OBJ) $(DEP)

-include $(DEP)
