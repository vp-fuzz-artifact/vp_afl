#!/usr/bin/env bash

# Get directory of script itself
SOURCE="${BASH_SOURCE[0]}"
# resolve $SOURCE until the file is no longer a symlink
while [ -h "$SOURCE" ]; do
    DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
    SOURCE="$(readlink "$SOURCE")"
    # if $SOURCE was a relative symlink, we need to resolve it relative to the
    # path where the symlink file was located
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
ROOT_DIR="$( cd -P "$DIR/.." >/dev/null 2>&1 && pwd )"

make -C "$ROOT_DIR" submodules # to initialize the repo's four submodules (afl, vcml, avp64 and vp-testing-interface)

# (Optional) Install CRIU if not already installed:
if ! command -v criu &> /dev/null; then
    git clone --depth 1 --branch v4.2 https://github.com/checkpoint-restore/criu /tmp/criu
    make -C /tmp/criu -j"$(nproc)" criu lib # we are only interested in criu and libcriu
    make -C /tmp/criu PREFIX=/usr/local install-criu install-lib
    ldconfig # adds the installation path to LD_LIBRARY_PATH
    rm -rf /tmp/criu
fi

# Clone the dependencies, this is a replacement for CMake's own auto-fetch
git clone --depth 1 --recursive --branch avp64 https://github.com/nbosb/ocx-qemu-arm "$ROOT_DIR"/ocx-qemu-arm
git clone --depth 1 --recursive --branch v2026.02.10 https://github.com/machineware-gmbh/mwr "$ROOT_DIR"/mwr
git clone --depth 1 https://github.com/machineware-gmbh/systemc "$ROOT_DIR"/systemc

export OCX_QEMU_ARM_HOME="$ROOT_DIR"/ocx-qemu-arm
export MWR_HOME="$ROOT_DIR"/mwr
export SYSTEMC_HOME="$ROOT_DIR"/systemc

make -C "$ROOT_DIR" all