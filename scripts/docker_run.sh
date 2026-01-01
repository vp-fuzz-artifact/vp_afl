#!/usr/bin/env bash
CONTAINER_PROGRAM=""
CONTAINER_PROGRAM_FLAGS=""
IMAGE_NAME="vp-afl"

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

if command -v podman &> /dev/null; then
	CONTAINER_PROGRAM="podman"

    # Check if root already sees the image
    if [[ $EUID -eq 0 ]]; then
        TARGET_USER="${SUDO_USER:-$USER}"

        podman image exists "$IMAGE_NAME" || \
            sudo -u "$TARGET_USER" XDG_RUNTIME_DIR=/run/user/$(id -u "$TARGET_USER") podman save "$IMAGE_NAME" | podman load
    else # Under SELinux we basically cant do anything, label=disable allows us basic operations on the mounted dirs (e.g., reading)
        CONTAINER_PROGRAM_FLAGS="--userns keep-id --security-opt label=disable"
    fi
	echo "Using podman"

elif command -v docker &> /dev/null; then
	CONTAINER_PROGRAM="docker"
	CONTAINER_PROGRAM_FLAGS="--user $(id -u):$(id -g)"
	echo "Using docker"
else
	echo "No program to launch containers found. Please install podman or docker."
	exit 1
fi

if [[ $# -lt 1 || ! -d "$1" ]]; then
    echo "Usage: $0 <benchmark dir> [benchmark name] [checkpoint mode] [dump/restore]"
    echo "  e.g. $0 ~/vp_sw_benchmark/cortex-A72/baremetal arch_pro 1 dump"
    exit 1
fi
BENCHMARK_PATH="$1"
BENCHMARK_NAME="${2:-arch_pro}"

TC_CHKPT_MODE="${3:-0}"
TC_DUMP="${4:-"dump"}"

if [[ "$TC_DUMP" == "restore" ]]; then
    TC_DUMP=0
else
    TC_DUMP=1
fi

CRIU_IMG_DIR="$DIR/../checkpoints/$BENCHMARK_NAME"

mkdir -p $CRIU_IMG_DIR
mkdir -p "$DIR/../logs"

if [[ $EUID -eq 0 ]]; then
    CONTAINER_PROGRAM_FLAGS="$CONTAINER_PROGRAM_FLAGS --privileged"
fi

$CONTAINER_PROGRAM run \
    --rm -it \
    $CONTAINER_PROGRAM_FLAGS \
    -e TC_CHKPT_MODE="$TC_CHKPT_MODE" -e TC_DUMP="$TC_DUMP" -e CRIU_IMG_DIR="/app/checkpoints" \
    -e TC_LOGGING -e TC_LOGGING_PATH -e TC_VP_LOGGING -e TC_VP_LOGGING_PATH -e FUZZING_SEED -e TC_TIMEOUT_MS -e FUZZING_TIMEOUT \
    -v "$DIR/../logs":/app/logs \
    -v "$(realpath "$BENCHMARK_PATH")":/app/sw \
    -v "$CRIU_IMG_DIR:/app/checkpoints" \
    -v "$DIR":/app/scripts \
    "$IMAGE_NAME" /app/sw/run_fuzzer.bash "$BENCHMARK_NAME"

