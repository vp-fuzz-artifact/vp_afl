# make submodules     --> once, after cloning
# make                --> everything
# make harness DEBUG=1
# make avp64          --> after changing the VP

ROOT        := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
VP_DIR      := $(ROOT)/vp_mode
AFL_DIR     := $(VP_DIR)/aflplusplus
VTI_DIR     := $(VP_DIR)/vp-testing-interface
AVP64_DIR   := $(VP_DIR)/avp64
HARNESS_DIR := $(VP_DIR)/harness
VCML_DIR    := $(VP_DIR)/vcml
PATCH_DIR	:= $(VP_DIR)/patches
VCML_PATCH  := $(PATCH_DIR)/vcml-suspender.patch
AFL_PATCH   := $(PATCH_DIR)/aflplusplus.patch

BUILD   := $(ROOT)/build
PREFIX  := $(ROOT)/install
JOBS    ?= $(shell nproc)
DEBUG   ?= 0
BUILD_TYPE ?= Release

MWR_TAG  ?= v2026.02.10
# upstream ocx-qemu-arm master moved to a versioned OCX API (ocx20250721::ocx),
# avp64 still needs the 20201012 API from the avp64 fork
OCX_REPO ?= nbosb/ocx-qemu-arm
OCX_TAG  ?= avp64

CMAKE_COMMON := -DCMAKE_BUILD_TYPE=$(BUILD_TYPE) \
                -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
                -DCMAKE_INSTALL_PREFIX=$(PREFIX) \
                -DCMAKE_PREFIX_PATH=$(PREFIX) \
                -DCMAKE_INSTALL_RPATH='$$ORIGIN/../lib;$$ORIGIN/../lib64' \
                -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON

.PHONY: all submodules afl vp-testing-interface avp64 harness clean vcml-patch afl-patch

all: afl avp64 harness

# Create .vcml-patched in $(VP_DIR), the target depends on $(VCML_PATCH)
# If $(VCML_PATCH) is newer than the target, it applies the patch
# -p1 strips the patch from the dummy directory prefix
# touch creates $(VP_DIR)/.vcml-patched
$(PATCH_DIR)/.vcml-patched: $(VCML_PATCH)
	patch -d $(VCML_DIR) -p1 < $(VCML_PATCH)
	touch $@

# Convenience alias
vcml-patch: $(PATCH_DIR)/.vcml-patched

$(PATCH_DIR)/.afl-patched: $(AFL_PATCH)
	patch -d $(AFL_DIR) -p1 < $(AFL_PATCH)
	touch $@

afl-patch: $(PATCH_DIR)/.afl-patched

submodules:
	git -C $(ROOT) submodule update --init
	git -C $(AVP64_DIR) submodule update --init --recursive
	git -C $(VCML_DIR) submodule update --init --recursive

afl: afl-patch
	$(MAKE) -C $(AFL_DIR) -j$(JOBS) afl-fuzz afl-showmap afl-tmin

vp-testing-interface:
	cmake -S $(VTI_DIR) -B $(BUILD)/vp-testing-interface $(CMAKE_COMMON)
	cmake --build $(BUILD)/vp-testing-interface -j$(JOBS)
	cmake --install $(BUILD)/vp-testing-interface

avp64: vp-testing-interface vcml-patch
	cmake -S $(AVP64_DIR) -B $(BUILD)/avp64 $(CMAKE_COMMON) \
	      -DMWR_TAG=$(MWR_TAG) -DVCML_HOME=$(VCML_DIR) \
	      -DOCX_QEMU_ARM_REPO=$(OCX_REPO) -DOCX_QEMU_ARM_TAG=$(OCX_TAG)
	cmake --build $(BUILD)/avp64 -j$(JOBS)
	cmake --install $(BUILD)/avp64

harness: vp-testing-interface
	cmake -S $(HARNESS_DIR) -B $(BUILD)/harness $(CMAKE_COMMON) \
	      -DCMAKE_CXX_FLAGS=-DDEBUG=$(DEBUG)
	cmake --build $(BUILD)/harness -j$(JOBS)

clean:
	rm -rf $(BUILD) $(PREFIX)
	-$(MAKE) -C $(AFL_DIR) clean
