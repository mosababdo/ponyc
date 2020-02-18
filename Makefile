config ?= release
arch ?= native
tune ?= generic
build_flags ?= -j2
llvm_archs ?= X86
llvm_config ?= Release
llc_arch ?= x86-64

ifndef version
  version := $(shell cat VERSION)
  ifneq ($(wildcard .git),)
    sha := $(shell git rev-parse --short HEAD)
    tag := $(version)-$(sha)
  else
    tag := $(version)
  endif
else
  tag := $(version)
endif

symlink := yes
ifdef DESTDIR
	prefix := $(DESTDIR)
	ponydir := $(prefix)
	symlink := no
else
	prefix ?= /usr/local
	ponydir ?= $(prefix)/lib/pony/$(tag)
endif

# By default, CC is cc and CXX is g++
# So if you use standard alternatives on many Linuxes
# You can get clang and g++ and then bad things will happen
ifneq (,$(shell $(CC) --version 2>&1 | grep clang))
  ifneq (,$(shell $(CXX) --version 2>&1 | grep "Free Software Foundation"))
    CXX = c++
  endif

  ifneq (,$(shell $(CXX) --version 2>&1 | grep "Free Software Foundation"))
    $(error CC is clang but CXX is g++. They must be from matching compilers.)
  endif
else ifneq (,$(shell $(CC) --version 2>&1 | grep "Free Software Foundation"))
  ifneq (,$(shell $(CXX) --version 2>&1 | grep clang))
    CXX = c++
  endif

  ifneq (,$(shell $(CXX) --version 2>&1 | grep clang))
    $(error CC is gcc but CXX is clang++. They must be from matching compilers.)
  endif
endif

srcDir := $(shell dirname '$(subst /Volumes/Macintosh HD/,/,$(realpath $(lastword $(MAKEFILE_LIST))))')
buildDir := $(srcDir)/build/build_$(config)
outDir := $(srcDir)/build/$(config)

libsSrcDir := $(srcDir)/lib
libsBuildDir := $(srcDir)/build/build_libs
libsOutDir := $(srcDir)/build/libs

ifndef verbose
	SILENT = @
	CMAKE_VERBOSE_FLAGS :=
else
	SILENT =
	CMAKE_VERBOSE_FLAGS := -DCMAKE_VERBOSE_MAKEFILE=ON
endif

ifeq ($(lto),yes)
	LTO_CONFIG_FLAGS = -DPONY_USE_LTO=true
else
	LTO_CONFIG_FLAGS =
endif

ifeq ($(runtime-bitcode),yes)
	ifeq (,$(shell $(CC) -v 2>&1 | grep clang))
		$(error Compiling the runtime as a bitcode file requires clang)
	endif
	BITCODE_FLAGS = -DPONY_RUNTIME_BITCODE=true
else
	BITCODE_FLAGS =
endif

.DEFAULT_GOAL := build
.PHONY: all libs cleanlibs configure cross-configure build test test-ci test-check-version test-core test-stdlib-debug test-stdlib-release test-examples test-validate-grammar clean

libs:
	$(SILENT)mkdir -p '$(libsBuildDir)'
	$(SILENT)cd '$(libsBuildDir)' && cmake -B '$(libsBuildDir)' -S '$(libsSrcDir)' -DCMAKE_INSTALL_PREFIX="$(libsOutDir)" -DCMAKE_BUILD_TYPE="$(llvm_config)" -DLLVM_TARGETS_TO_BUILD="$(llvm_archs)" -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_ENABLE_WARNINGS=OFF -DLLVM_ENABLE_TERMINFO=OFF $(CMAKE_VERBOSE_FLAGS)
	$(SILENT)cd '$(libsBuildDir)' && cmake --build '$(libsBuildDir)' --target install --config $(llvm_config) -- $(build_flags)

cleanlibs:
	$(SILENT)rm -rf '$(libsBuildDir)'
	$(SILENT)rm -rf '$(libsOutDir)'

configure:
	$(SILENT)mkdir -p '$(buildDir)'
	$(SILENT)cd '$(buildDir)' && CC="$(CC)" CXX="$(CXX)" cmake -B '$(buildDir)' -S '$(srcDir)' -DCMAKE_BUILD_TYPE=$(config) -DCMAKE_C_FLAGS="-march=$(arch) -mtune=$(tune)" -DCMAKE_CXX_FLAGS="-march=$(arch) -mtune=$(tune)" $(BITCODE_FLAGS) $(LTO_CONFIG_FLAGS) $(CMAKE_VERBOSE_FLAGS)

all: build

build:
	$(SILENT)cd '$(buildDir)' && cmake --build '$(buildDir)' --config $(config) --target all -- $(build_flags)

crossBuildDir := $(srcDir)/build/$(arch)/build_$(config)

cross-libponyrt:
	$(SILENT)mkdir -p $(crossBuildDir)
	$(SILENT)cd '$(crossBuildDir)' && CC=$(CC) CXX=$(CXX) cmake -B '$(crossBuildDir)' -S '$(srcDir)' -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=$(arch) -DCMAKE_C_COMPILER=$(CC) -DCMAKE_CXX_COMPILER=$(CXX) -DPONY_CROSS_LIBPONYRT=true -DCMAKE_BUILD_TYPE=$(config) -DCMAKE_C_FLAGS="-march=$(arch) -mtune=$(tune)" -DCMAKE_CXX_FLAGS="-march=$(arch) -mtune=$(tune)" -DPONYC_VERSION=$(version) -DLL_FLAGS="-O3;-march=$(llc_arch);-mcpu=$(tune)"
	$(SILENT)cd '$(crossBuildDir)' && cmake --build '$(crossBuildDir)' --config $(config) --target libponyrt -- $(build_flags)

test: all test-core test-stdlib-release test-examples

test-ci: all test-check-version test-core test-stdlib-debug test-stdlib-release test-examples test-validate-grammar

test-cross-ci: cross_args=--triple=$(cross_triple) --cpu=$(cross_cpu) --link-arch=$(cross_arch) --linker='$(cross_linker)'
test-cross-ci: test-stdlib-debug test-stdlib-release

test-check-version: all
	$(SILENT)cd '$(outDir)' && ./ponyc --version

test-core: all
	$(SILENT)cd '$(outDir)' && ./libponyrt.tests --gtest_shuffle
	$(SILENT)cd '$(outDir)' && ./libponyc.tests --gtest_shuffle

test-stdlib-release: all
	$(SILENT)cd '$(outDir)' && PONYPATH=.:$(PONYPATH) ./ponyc -b stdlib-release --pic --checktree --verify $(cross_args) ../../packages/stdlib && echo Built `pwd`/stdlib-release && $(cross_runner) ./stdlib-release --sequential && rm ./stdlib-release

test-stdlib-debug: all
	$(SILENT)cd '$(outDir)' && PONYPATH=.:$(PONYPATH) ./ponyc -d -b stdlib-debug --pic --strip --checktree --verify $(cross_args) ../../packages/stdlib && echo Built `pwd`/stdlib-debug && $(cross_runner) ./stdlib-debug --sequential && rm ./stdlib-debug

test-examples: all
	$(SILENT)cd '$(outDir)' && PONYPATH=.:$(PONYPATH) find ../../examples/*/* -name '*.pony' -print | xargs -n 1 dirname | sort -u | grep -v ffi- | xargs -n 1 -I {} ./ponyc -d -s --checktree -o {} {}

test-validate-grammar: all
	$(SILENT)cd '$(outDir)' && ./ponyc --antlr >> pony.g.new && diff ../../pony.g pony.g.new && rm pony.g.new

clean:
	$(SILENT)([ -d '$(buildDir)' ] && cd '$(buildDir)' && cmake --build '$(buildDir)' --config $(config) --target clean) || true
	$(SILENT)rm -rf '$(crossBuildDir)'
	$(SILENT)rm -rf '$(buildDir)'
	$(SILENT)rm -rf '$(outDir)'

distclean:
	$(SILENT)([ -d build ] && rm -rf build) || true

install: build
	echo $(symlink)
	@mkdir -p $(ponydir)/bin
	@mkdir -p $(ponydir)/lib/$(arch)
	@mkdir -p $(ponydir)/include/pony/detail
	$(SILENT)if [ -f $(outDir)/libponyrt.a ]; then cp $(outDir)/libponyrt.a $(ponydir)/lib/$(arch); fi
	$(SILENT)if [ -f $(ponydir)/lib/$(arch)/libponyrt.a ]; then ln -s -f $(ponydir)/lib/$(arch)/libponyrt.a $(ponydir)/bin/libponyrt.a; fi
	$(SILENT)if [ -f $(outDir)/libponyrt-pic.a ]; then cp $(outDir)/libponyrt-pic.a $(ponydir)/lib/$(arch); fi
	$(SILENT)if [ -f $(ponydir)/lib/$(arch)/libponyrt-pic.a ]; then ln -s -f $(ponydir)/lib/$(arch)/libponyrt-pic.a $(ponydir)/bin/libponyrt-pic.a; fi
	$(SILENT)cp $(outDir)/ponyc $(ponydir)/bin
	$(SILENT)cp src/libponyrt/pony.h $(ponydir)/include
	$(SILENT)cp src/common/pony/detail/atomics.h $(ponydir)/include/pony/detail
	$(SILENT)cp -r packages $(ponydir)/
ifeq ($(symlink),yes)
	@mkdir -p $(prefix)/bin
	@mkdir -p $(prefix)/lib
	@mkdir -p $(prefix)/include/pony/detail
	$(SILENT)ln -s -f $(ponydir)/bin/ponyc $(prefix)/bin/ponyc
	$(SILENT)if [ -f $(ponydir)/lib/$(arch)/libponyrt.a ]; then ln -s -f $(ponydir)/lib/$(arch)/libponyrt.a $(prefix)/bin/libponyrt.a; fi
	$(SILENT)if [ -f $(ponydir)/lib/$(arch)/libponyrt-pic.a ]; then ln -s -f $(ponydir)/lib/$(arch)/libponyrt-pic.a $(prefix)/bin/libponyrt-pic.a; fi
	$(SILENT)ln -s -f $(ponydir)/include/pony.h $(prefix)/include/pony.h
	$(SILENT)ln -s -f $(ponydir)/include/pony/detail/atomics.h $(prefix)/include/pony/detail/atomics.h
endif

uninstall:
	-$(SILENT)rm -rf $(ponydir) ||:
	-$(SILENT)rm -f $(prefix)/bin/ponyc ||:
	-$(SILENT)rm -f $(prefix)/bin/libponyrt*.a ||:
	-$(SILENT)rm -f $(prefix)/include/pony.h ||:
	-$(SILENT)rm -rf $(prefix)/include/pony ||:
