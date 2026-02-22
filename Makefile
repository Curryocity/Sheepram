CXX ?= c++
TARGET := main
APP_NAME ?= Sheepram
VERSION ?= dev
UNAME_S := $(shell uname -s)
ARCH ?= $(shell uname -m)
BUILD_DIR := build/$(UNAME_S)-$(ARCH)
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
ifeq (,$(findstring MINGW,$(UNAME_S)))
ifeq (,$(findstring MSYS,$(UNAME_S)))
SRC += thirdParty/nfd/src/nfd_win.cpp
endif
endif
endif

OBJ := $(addprefix $(BUILD_DIR)/,$(patsubst %.cpp,%.o,$(patsubst %.m,%.o,$(SRC))))
DEP := $(OBJ:.o=.d)

CPPFLAGS := -Iimgui -Iimgui/backends -IthirdParty/nfd/src/include
CXXFLAGS := -std=c++20 -Wall -Wextra -MMD -MP -ffp-contract=off
OBJCFLAGS := -Wall -Wextra -MMD -MP
LDLIBS := -lglfw
RELEASE_LDFLAGS :=
STRIP_CMD :=

ifeq ($(UNAME_S),Darwin)
CXX := clang++
ifeq ($(ARCH),x86_64)
BREW_PREFIX ?= /usr/local
else
BREW_PREFIX ?= /opt/homebrew
endif
CPPFLAGS += -I$(BREW_PREFIX)/include -DGL_SILENCE_DEPRECATION
CXXFLAGS += -arch $(ARCH)
OBJCFLAGS += -arch $(ARCH)
LDFLAGS += -L$(BREW_PREFIX)/lib \
	-arch $(ARCH) \
	-framework OpenGL \
	-framework Cocoa \
	-framework IOKit \
	-framework CoreVideo \
	-framework UniformTypeIdentifiers
RELEASE_LDFLAGS += -Wl,-dead_strip
STRIP_CMD = strip -x $(BUILD_DIR)/$(TARGET)
endif

ifeq ($(UNAME_S),Linux)
GTK_CFLAGS := $(shell $(PKG_CONFIG) --cflags gtk+-3.0 2>/dev/null)
GTK_LIBS := $(shell $(PKG_CONFIG) --libs gtk+-3.0 2>/dev/null)
CPPFLAGS += $(GTK_CFLAGS)
LDLIBS += $(GTK_LIBS) -lGL -ldl -lpthread
RELEASE_LDFLAGS += -Wl,--gc-sections
STRIP_CMD = strip --strip-unneeded $(BUILD_DIR)/$(TARGET)
endif

ifneq (,$(findstring MINGW,$(UNAME_S)))
LDLIBS := $(filter-out -lglfw,$(LDLIBS))
LDLIBS += -lglfw3 -lopengl32 -lgdi32 -lshell32 -lcomdlg32 -lole32 -luuid
endif
ifneq (,$(findstring MSYS,$(UNAME_S)))
LDLIBS := $(filter-out -lglfw,$(LDLIBS))
LDLIBS += -lglfw3 -lopengl32 -lgdi32 -lshell32 -lcomdlg32 -lole32 -luuid
endif
ifeq ($(OS),Windows_NT)
LDLIBS := $(filter-out -lglfw,$(LDLIBS))
LDLIBS += -lglfw3 -lopengl32 -lgdi32 -lshell32 -lcomdlg32 -lole32 -luuid
endif

.PHONY: all debug release clean clean-artifacts \
	package-macos-arm64 package-macos-x86_64 package-linux-x86_64 package-windows-x86_64

all: debug

debug: CXXFLAGS += -O1 -g
debug: $(BUILD_DIR)/$(TARGET)

release: CXXFLAGS += -O3 -DNDEBUG -fdata-sections -ffunction-sections
release: OBJCFLAGS += -O3 -DNDEBUG -fdata-sections -ffunction-sections
release: LDFLAGS += $(RELEASE_LDFLAGS)
release: $(BUILD_DIR)/$(TARGET)
ifneq ($(STRIP_CMD),)
	$(STRIP_CMD)
endif

$(BUILD_DIR)/$(TARGET): $(OBJ)
	$(CXX) $(OBJ) $(LDFLAGS) $(LDLIBS) -o $@
ifneq ($(BUILD_DIR),build)
	@mkdir -p build
	cp -f $@ build/$(TARGET)
endif

$(BUILD_DIR)/%.o: %.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -c $< -o $@

$(BUILD_DIR)/%.o: %.m
	@mkdir -p $(dir $@)
	clang $(CPPFLAGS) $(OBJCFLAGS) -c $< -o $@

clean:
	rm -f $(BUILD_DIR)/$(TARGET) $(OBJ) $(DEP)

clean-artifacts:
	rm -rf $(BUILD_DIR)/*.dSYM *.dSYM

package-macos-arm64:
	@host="$$(uname -s)"; \
	if [ "$$host" != "Darwin" ]; then \
		echo "package-macos-arm64 must be run on macOS (or CI macOS runner)."; \
		exit 2; \
	fi
	$(MAKE) clean release UNAME_S=Darwin ARCH=arm64 TARGET=$(APP_NAME)
	VERSION=$(VERSION) ./scripts/package.sh macos arm64 build/Darwin-arm64/$(APP_NAME)

package-macos-x86_64:
	@host="$$(uname -s)"; \
	if [ "$$host" != "Darwin" ]; then \
		echo "package-macos-x86_64 must be run on macOS (or CI macOS runner)."; \
		exit 2; \
	fi
	$(MAKE) clean release UNAME_S=Darwin ARCH=x86_64 TARGET=$(APP_NAME)
	VERSION=$(VERSION) ./scripts/package.sh macos x86_64 build/Darwin-x86_64/$(APP_NAME)

package-linux-x86_64:
	@host="$$(uname -s)"; \
	if [ "$$host" != "Linux" ]; then \
		echo "package-linux-x86_64 must be run on Linux (or CI Linux runner)."; \
		exit 2; \
	fi
	$(MAKE) clean release UNAME_S=Linux ARCH=x86_64 TARGET=$(APP_NAME)
	VERSION=$(VERSION) ./scripts/package.sh linux x86_64 build/Linux-x86_64/$(APP_NAME)

package-windows-x86_64:
	@host="$$(uname -s)"; \
	case "$$host" in MINGW*|MSYS*|CYGWIN*) ;; \
	*) echo "package-windows-x86_64 must be run in MinGW/MSYS/Cygwin (or CI Windows runner)."; exit 2;; \
	esac
	$(MAKE) clean release UNAME_S=MINGW64_NT ARCH=x86_64 TARGET=$(APP_NAME).exe
	VERSION=$(VERSION) ./scripts/package.sh windows x86_64 build/MINGW64_NT-x86_64/$(APP_NAME).exe

-include $(DEP)
