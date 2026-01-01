#!/bin/bash

# Execute this file from the aflplusplus directory with: 
# <path to bash script>/run_fuzzer.bash <name of the baremetal app>
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

OUT_DIR=${OUT_DIR:-"$PROJECT_NAME/out/$TC_CHKPT_MODE"}
mkdir -p "$OUT_DIR"

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

"$AFL_PATH/afl-fuzz" -s $FUZZING_SEED -i "$SEEDS_DIR" -o $OUT_DIR -t $FUZZING_TIMEOUT -m none -v -- "$CFG_FILE"
#increased timeout time to 5 seconds to let criu dump
