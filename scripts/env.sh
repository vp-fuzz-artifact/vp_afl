# source /path/to/vp_afl/env.sh

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

export PRJ_ROOT_DIR="$( cd -P "$DIR/.." >/dev/null 2>&1 && pwd )"
export CRIU_IMG_DIR="$PRJ_ROOT_DIR/checkpoints"
export SCRIPTS_DIR="$PRJ_ROOT_DIR/scripts"
export TC_PATH="$PRJ_ROOT_DIR/build/harness/harness"
export AFL_PATH="$PRJ_ROOT_DIR/vp_mode/aflplusplus"
export TC_VP_EXECUTABLE="$PRJ_ROOT_DIR/install/bin/avp64-runner"
export LD_LIBRARY_PATH="$PRJ_ROOT_DIR/install/lib:$PRJ_ROOT_DIR/install/lib64:/usr/local/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
