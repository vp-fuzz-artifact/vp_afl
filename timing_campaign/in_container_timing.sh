#!/bin/bash
# Runs inside the vp-afl-timing container (the DEBUG=1 harness).  It is the
# container-side twin of campaign/in_container_run.sh, but instead of handing
# the target to afl-fuzz it runs the harness' own benchmark loop, which
# timestamps init, each execution and each restart.
#
# env in: TIMING_MODE TIMING_DUMP TIMING_INPUT TIMING_OUT REPEATS
# argv:   <benchmark name>
set -u
BM="$1"; SW="/app/sw"; PROJ="$SW/$BM"
die() { echo "TIMING-FATAL: $*" >&2; exit 97; }

CFG="$(ls "$PROJ"/*.cfg 2>/dev/null | head -1)"; [[ -n "$CFG" ]] || die "no .cfg in $PROJ"
[[ -f "$PROJ/mmio_config.json" ]] || die "no mmio_config.json"

# settings.bash starts the CRIU service with `criu service --address $(pwd)/...`
# but then waits for it at $PRJ_ROOT_DIR/criu_service.socket, so the working
# directory has to be $PRJ_ROOT_DIR or the socket is created somewhere the
# wait loop never looks.  cd before sourcing it.
cd "${PRJ_ROOT_DIR:-/app}" || die "cannot cd to ${PRJ_ROOT_DIR:-/app}"

# These must be set BEFORE settings.bash: it reads them as ${VAR:-default} and
# drives the CRIU socket setup off them.
export TC_CHKPT_MODE="$TIMING_MODE"     # settings.bash honours ${TC_CHKPT_MODE:-0}
export TC_DUMP="$TIMING_DUMP"           # 1 = dump, 0 = restore from images
export CRIU_IMG_DIR="/app/checkpoints"  # per-cell dir, mounted from the host

# shellcheck disable=SC1090
. "$SW/settings.bash" "$BM" || die "settings.bash failed"
[[ "$TC_CHKPT_MODE" == "$TIMING_MODE" ]] || die "mode fell back to $TC_CHKPT_MODE (not root?)"

# These must be set AFTER it: settings.bash assigns TC_LOGGING=0 and
# TC_VP_LOGGING=0 unconditionally (not ${VAR:-0}), so anything exported before
# the source is thrown away -- which silently disables the logging the whole
# measurement is read from.
export TC_LOGGING=1                     # 1 = INFO: the "Elapsed" lines we parse
export TC_LOGGING_PATH="$TIMING_OUT/harness.log"
[[ "$TC_LOGGING" == "1" ]] || die "TC_LOGGING is $TC_LOGGING, no timings would be recorded"

# The VP's own log sits in the simulation hot path, so it is off for a real
# measurement -- but it is the only way to see what the VP is doing inside
# DO_RUN_SHM, so TIMING_VP_LOG=1 turns it on for a diagnostic run.  The path is
# forced into the mounted output dir either way: the settings.bash default
# ($PRJ_ROOT_DIR/logs/vp_out.txt) is a directory that does not exist in the
# image, and the log would be lost with --rm even if it did.
if [[ "${TIMING_VP_LOG:-0}" == "1" ]]; then
  export TC_VP_LOGGING=1
  export TC_VP_LOGGING_PATH="$TIMING_OUT/vp.log"
  echo "vp logging ENABLED -> $TC_VP_LOGGING_PATH (slows the VP; diagnostic only)"
else
  export TC_VP_LOGGING=0
fi

export JSON_CFG_PATH="$PROJ/mmio_config.json"
export PUT_DIR="$SW"

# One fixed input for every run of this cell.  seeds/seed_0 is a symlink in
# some benchmarks, so resolve it the way the fuzzing campaign does.
INPUT="$PROJ/$TIMING_INPUT"
[[ -L "$INPUT" ]] && INPUT="$(readlink -f "$INPUT")"
[[ -f "$INPUT" ]] || die "input not found: $PROJ/$TIMING_INPUT"
echo "input=$INPUT size=$(stat -c%s "$INPUT") sha256=$(sha256sum "$INPUT" | cut -d' ' -f1)"

[[ -x "$TC_PATH" ]] || die "no harness at TC_PATH=$TC_PATH"

# The harness takes the shm ids on the command line (see dbg_init); in the AFL
# path afl-fuzz creates them and sizes them from its own constants.
#
# The coverage segment MUST be at least MAP_SIZE bytes: at the end of every run
# the VP writes its whole basic-block array into it, and a smaller segment
# segfaults the VP just past the end -- so the DO_RUN_SHM response is never
# sent and the harness times out.  harness/scripts/gdb_vp.sh uses 64 KiB, which
# was right when MAP_SIZE_POW2 was 16 and is 32x too small now that it is 21.
# Read the constant out of the headers in the image so this cannot drift again.
AFL_CFG=/app/vp_mode/aflplusplus/include/config.h
VP_HDR=/app/vp_mode/avp64/include/fuzzing/vp_manager.hpp
vp_pow2="$(sed -n 's/^[[:space:]]*constexpr size_t MAP_SIZE_POW2[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p' "$VP_HDR" 2>/dev/null | head -1)"
afl_pow2="$(sed -n 's/^#define MAP_SIZE_POW2[[:space:]]\+\([0-9]\+\).*/\1/p' "$AFL_CFG" 2>/dev/null | head -1)"
[[ -n "$vp_pow2" ]] || die "cannot read MAP_SIZE_POW2 from $VP_HDR"
if [[ "$vp_pow2" != "$afl_pow2" ]]; then
  echo "WARNING: MAP_SIZE_POW2 disagrees: avp64=$vp_pow2 afl=${afl_pow2:-?}"
fi
cov_bytes="${TIMING_COV_BYTES:-$(( 1 << vp_pow2 ))}"
in_bytes="${TIMING_INPUT_BYTES:-1048576}"   # AFL's MAX_FILE
echo "shm sizes: input=$in_bytes cov=$cov_bytes (MAP_SIZE_POW2=$vp_pow2)"

shm_input="$(ipcmk -M "$in_bytes"  | awk '{print $NF}')" || die "ipcmk failed"
shm_cov="$(  ipcmk -M "$cov_bytes" | awk '{print $NF}')" || die "ipcmk failed"
cleanup() { ipcrm -m "$shm_input" 2>/dev/null; ipcrm -m "$shm_cov" 2>/dev/null; }
trap cleanup EXIT
echo "shm_input=$shm_input shm_cov=$shm_cov"

rc=0
for ((i = 1; i <= ${REPEATS:-1}; i++)); do
  echo "=== invocation $i/${REPEATS:-1} $(date -Is)"
  "$TC_PATH" "$CFG" "$INPUT" "$shm_input" "$shm_cov"; rc=$?
  echo "=== invocation $i exit=$rc"
  (( rc != 0 )) && break
done
exit $rc
