ODIN ?= odin
PYTHON ?= python3
TARGET ?= Sheepram
VERSION ?= dev
UNAME_S := $(shell uname -s)
ODIN_LINK_FLAGS :=
EXE_EXT :=

ifeq ($(OS),Windows_NT)
EXE_EXT := .exe
endif

ifeq ($(UNAME_S),Linux)
ODIN_LINK_FLAGS += -extra-linker-flags:"$(shell pkg-config --libs gtk+-3.0)"
endif

.PHONY: all debug release imgui-deps windows-imgui-deps nfd-deps clean \
	package-macos-arm64 package-macos-x86_64 package-linux-x86_64 package-windows-x86_64

all: debug

debug: nfd-deps
	$(ODIN) build src -debug $(ODIN_LINK_FLAGS) -out:build/$(TARGET)$(EXE_EXT)

release: nfd-deps
	$(ODIN) build src -o:speed $(ODIN_LINK_FLAGS) -out:build/$(TARGET)$(EXE_EXT)

imgui-deps:
	cd third_party/odin-imgui && $(PYTHON) build.py

windows-imgui-deps:
	cd third_party/odin-imgui && \
		printf '@echo off\r\n' > vcvarsall.bat && \
		trap 'rm -f vcvarsall.bat' EXIT && \
		$(PYTHON) build.py

nfd-deps:
	mkdir -p build
ifeq ($(UNAME_S),Darwin)
	clang -c third_party/nfd/src/nfd_cocoa.m -Ithird_party/nfd/src/include -o build/nfd_cocoa.o
endif
ifeq ($(UNAME_S),Linux)
	c++ -std=c++11 -c third_party/nfd/src/nfd_gtk.cpp -Ithird_party/nfd/src/include $$(pkg-config --cflags gtk+-3.0) -o build/nfd_gtk.o
endif
ifeq ($(OS),Windows_NT)
	MSYS2_ARG_CONV_EXCL='*' cl /nologo /c /EHsc /Ithird_party/nfd/src/include /Fobuild/nfd_win.obj third_party/nfd/src/nfd_win.cpp
	MSYS2_ARG_CONV_EXCL='*' rc /nologo /fo build/app_icon.res resources/windows/app_icon.rc
endif

clean:
	rm -rf build

package-macos-arm64: imgui-deps release
	VERSION=$(VERSION) ./scripts/package.sh macos arm64 build/$(TARGET)

package-macos-x86_64: imgui-deps release
	VERSION=$(VERSION) ./scripts/package.sh macos x86_64 build/$(TARGET)

package-linux-x86_64: imgui-deps release
	VERSION=$(VERSION) ./scripts/package.sh linux x86_64 build/$(TARGET)

package-windows-x86_64: windows-imgui-deps release
	VERSION=$(VERSION) ./scripts/package.sh windows x86_64 build/$(TARGET)$(EXE_EXT)
