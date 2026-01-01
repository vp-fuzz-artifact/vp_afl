#!/bin/bash

CURRENT_FILE=$(realpath "$0")
SCRIPT_DIR=$(dirname "$CURRENT_FILE")

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <sw benchmark>"
  echo "Available benchmarks:"

  for dir in "$SCRIPT_DIR"/*/; do
    echo "${dir%/}"
  done

  exit 1
fi

PROJECT_NAME="$SCRIPT_DIR/$1"
JSON_CFG="$PROJECT_NAME/mmio_config.json"
SEEDS_DIR="$PROJECT_NAME/seeds"
cfg_file=$(basename "$PROJECT_NAME"/*.cfg)
CFG_FILE="$PROJECT_NAME/$cfg_file"
FUZZING_SEED="${FUZZING_SEED:-42}"
FUZZING_TIMEOUT="${FUZZING_TIMEOUT:-20000}"

# Source settings.bash if it exists
if [[ -f "$SCRIPT_DIR/settings.bash" ]]; then
    echo "Using settings.bash from: $SCRIPT_DIR"
    . "$SCRIPT_DIR/settings.bash" "$1"
else
    echo "Error: settings.bash not found in $SCRIPT_DIR"
    exit 1
fi

if [[ ! -f "$JSON_CFG" ]]; then
    echo "Error: mmio_config.json not found in $SCRIPT_DIR"
    exit 1
fi

export JSON_CFG_PATH="$JSON_CFG"
export PUT_DIR="$SCRIPT_DIR"


if [[ -L "$SEEDS_DIR/seed_0" ]]; then
    echo "seed_0 is a symbolic link"

    REAL_SEED=$(readlink -f "$SEEDS_DIR/seed_0")

    if [[ -z "$REAL_SEED" ]]; then
        echo "Failed to resolve seed symlink"
        exit 1
    fi

    SEEDS_DIR=$(dirname "$REAL_SEED")
fi

echo "Using seeds directory: $SEEDS_DIR"

# ---------------------------
# Create Shared Memory Segments 
# (1 KB for test cases and 64KB for coverage)
# ---------------------------
shm_input_output=$(ipcmk -M 1024)
shm_cov_output=$(ipcmk -M 65536)

# Extract the shared memory IDs from the command output.
shm_input=$(echo "$shm_input_output" | awk '{print $NF}')
shm_cov=$(echo "$shm_cov_output" | awk '{print $NF}')

echo "Created shared memory segment for test cases with id: $shm_input"
echo "Created shared memory segment for code coverage with id: $shm_cov"

# ---------------------------
# Define Cleanup Function
# Set to be automatically called when the script ends
# ---------------------------
cleanup() {
  echo "Cleaning up shared memory segments..."
  ipcrm -m "$shm_input"
  ipcrm -m "$shm_cov"
}
trap cleanup EXIT

# -x : execute the commands in gdb_script.gdb
# dirname "$0" : directory path of the script (.)
# harness : file to debug, it takes as inputs the settings.bash and shared memories
# gdb -x "$(dirname "$0")"/gdb_script.gdb --args "$(dirname "$0")"/../build/harness "$CFG_FILE" "$SEEDS_DIR" "$shm_input" "$shm_cov"
gdb --args "$(dirname "$0")"/../build/harness "$CFG_FILE" "$SEEDS_DIR" "$shm_input" "$shm_cov"

#"$(dirname "$0")"/../build/harness "$CFG_FILE" "$SEEDS_DIR" "$shm_input" "$shm_cov"
