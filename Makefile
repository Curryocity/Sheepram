ODIN ?= odin
PYTHON ?= python3
TARGET ?= Sheepram
VERSION ?= dev
UNAME_S := $(shell uname -s)
ODIN_LINK_FLAGS :=

ifeq ($(UNAME_S),Linux)
ODIN_LINK_FLAGS += -extra-linker-flags:"$(shell pkg-config --libs gtk+-3.0)"
endif

.PHONY: all debug release imgui-deps nfd-deps clean \
	package-macos-arm64 package-macos-x86_64 package-linux-x86_64 package-windows-x86_64

all: debug

debug: nfd-deps
	$(ODIN) build src -debug $(ODIN_LINK_FLAGS) -out:build/$(TARGET)

release: nfd-deps
	$(ODIN) build src -o:speed $(ODIN_LINK_FLAGS) -out:build/$(TARGET)

imgui-deps:
	cd third_party/odin-imgui && $(PYTHON) build.py

nfd-deps:
	mkdir -p build
ifeq ($(UNAME_S),Darwin)
	clang -c third_party/nfd/src/nfd_cocoa.m -Ithird_party/nfd/src/include -o build/nfd_cocoa.o
endif
ifeq ($(UNAME_S),Linux)
	c++ -std=c++11 -c third_party/nfd/src/nfd_gtk.cpp -Ithird_party/nfd/src/include $$(pkg-config --cflags gtk+-3.0) -o build/nfd_gtk.o
endif
ifeq ($(OS),Windows_NT)
	c++ -std=c++11 -c third_party/nfd/src/nfd_win.cpp -Ithird_party/nfd/src/include -o build/nfd_win.o
	windres resources/windows/app_icon.rc -O coff -o build/app_icon.o
endif

clean:
	rm -rf build

package-macos-arm64: imgui-deps release
	VERSION=$(VERSION) ./scripts/package.sh macos arm64 build/$(TARGET)

package-macos-x86_64: imgui-deps release
	VERSION=$(VERSION) ./scripts/package.sh macos x86_64 build/$(TARGET)

package-linux-x86_64: imgui-deps release
	VERSION=$(VERSION) ./scripts/package.sh linux x86_64 build/$(TARGET)

package-windows-x86_64: imgui-deps release
	VERSION=$(VERSION) ./scripts/package.sh windows x86_64 build/$(TARGET).exe
