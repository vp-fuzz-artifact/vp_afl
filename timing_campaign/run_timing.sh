#!/usr/bin/env bash
# Timing campaign driver.  Same shape as campaign/run_campaign.sh: WORKERS
# containers run in parallel, each takes the next unclaimed run from
# schedule.tsv, finished runs are skipped so an interrupted campaign resumes.
#
#   ./run_timing.sh --dry-run                     print schedule + one command
#   ./run_timing.sh --only-cell baremetal:zlib_baremetal --rounds 1
#   sudo -E ./run_timing.sh                       the campaign (mode 1 needs root)
#   sudo -E ./run_timing.sh --workers 4
#
# This measures latency, not throughput: anything else running on the machine
# inflates every interval.  Do not overlap it with the fuzzing campaign, and
# pin the workers (WORKER_CPUSETS) if WORKERS > 1.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/timing.conf"
# shellcheck disable=SC1091
. "$HERE/podman_store.sh"

DRY=0; ONLY_MODE=""; ONLY_CELL=""; TIMING_VP_LOG=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY=1 ;;
    --workers)   WORKERS="$2"; shift ;;
    --rounds)    ROUNDS="$2"; shift ;;
    --repeats)   REPEATS_PER_RUN="$2"; shift ;;
    --only-mode) ONLY_MODE="$2"; shift ;;
    --only-cell) ONLY_CELL="$2"; shift ;;
    --input)     TIMING_INPUT="$2"; shift ;;
    --vp-log)    TIMING_VP_LOG=1 ;;
    --results)   RESULTS_ROOT="$2"; shift ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac; shift
done

for c in "${CELLS[@]}"; do
  [[ -n "$ONLY_CELL" && "$c" != "$ONLY_CELL" ]] && continue
  d="$BENCH_ROOT/${c%%:*}/${c##*:}"
  [[ -d "$d" ]] || { echo "BENCH_ROOT looks wrong: $d does not exist"; exit 1; }
  compgen -G "$d/*.cfg" >/dev/null || { echo "no .cfg in $d"; exit 1; }
  [[ -e "$d/$TIMING_INPUT" ]] || { echo "no input $d/$TIMING_INPUT"; exit 1; }
done

CAMP="$RESULTS_ROOT/timing"
SCHED="$CAMP/schedule.tsv"; CLAIMS="$CAMP/.claims"; CKPT="$CAMP/checkpoints"
mkdir -p "$CAMP"
# A dry run must leave no trace beyond the schedule: no claims (they would make
# every run unclaimable for the real campaign), no empty round dirs.
[[ $DRY -eq 0 ]] && mkdir -p "$CLAIMS" "$CKPT"

# The DEBUG=1 harness image.  Under sudo this also imports it from the
# invoking user's rootless store, since podman keeps one store per user and
# mode 1 forces us to run as root (see podman_store.sh).  container_build.sh
# builds the base image (localhost/vp-afl) too on a fresh checkout.
if [[ $DRY -eq 1 ]]; then
  # a dry run launches nothing, so do not drag a multi-GB image between stores
  podman image exists "$IMAGE_NAME" 2>/dev/null || \
    echo "note: $IMAGE_NAME is not in this store; the real run would import or build it"
else
  ensure_image "$IMAGE_NAME" || {
    echo "image $IMAGE_NAME missing. Build it with:"
    echo "  $HERE/container_build.sh"
    [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]] && \
      echo "  (it is in neither root's nor ${SUDO_USER}'s store, so there was nothing to copy)"
    exit 1; }
fi

if [[ ! -s "$SCHED" ]]; then
  args=(); for c in "${CELLS[@]}"; do args+=(--cell "$c"); done
  for m in "${MODES[@]}"; do args+=(--mode "$m"); done
  python3 "$HERE/gen_timing_schedule.py" --rounds "$ROUNDS" --seed "$ORDER_SEED" \
    "${args[@]}" > "$SCHED" || { echo "schedule generation failed"; exit 1; }
  echo "schedule: $SCHED"
fi

if [[ $DRY -eq 0 ]]; then
{ echo "date=$(date -Is)"; echo "host=$(hostname)"; echo "uid=$EUID"
  echo "vp_afl=$(git -C "$VP_AFL_ROOT" rev-parse --short HEAD 2>/dev/null)"
  echo "image=$(podman image inspect -f '{{.Id}}' "$IMAGE_NAME" | cut -c1-12)"
  echo "workers=$WORKERS"; echo "cpusets=${WORKER_CPUSETS[*]:-none}"
  echo "rounds=$ROUNDS"; echo "repeats_per_run=$REPEATS_PER_RUN"
  echo "harness_iters=$HARNESS_ITERS"; echo "input=$TIMING_INPUT"
  echo "workdir=$CONTAINER_WORKDIR"
  echo "nproc=$(nproc)"; echo "loadavg=$(cut -d' ' -f1-3 /proc/loadavg)"
} > "$CAMP/timing_info.txt"
fi

# Always prints exactly one integer: grep -c prints a count even when it finds
# nothing (and exits 1), and a missing file prints nothing at all.
count_matches() {   # pattern file
  local n
  n="$(grep -cE "$1" "$2" 2>/dev/null | head -1)"
  printf '%s' "${n:-0}"
}

run_one() {   # round platform example mode tag worker
  local round="$1" plat="$2" ex="$3" mode="$4" tag="$5" w="$6"
  local rundir="$CAMP/round$(printf '%02d' "$round")/${plat}_${ex}_mode${mode}"
  local mx="MAX_SECONDS_${plat}"; local max="${!mx:-$MAX_SECONDS}"
  local cell_ckpt="$CKPT/${plat}_${ex}"
  local cpuset=""; [[ ${#WORKER_CPUSETS[@]} -gt 0 ]] && cpuset="${WORKER_CPUSETS[$w]}"

  local lock_fd=; local dump=1
  if [[ $DRY -eq 0 ]]; then
  if (( $(df -Pm "$CAMP" | awk 'NR==2{print $4}') < MIN_FREE_MB )); then
    echo "ABORT worker $w: free disk < ${MIN_FREE_MB}MB"; return 1
  fi
  if [[ "$mode" == "1" && $EUID -ne 0 ]]; then
    echo "skip $tag: CRIU needs root"; return 0
  fi

  mkdir -p "$cell_ckpt"
  if [[ "$mode" == "1" ]]; then
    # One image dir per cell: mode-1 runs of a cell must not overlap.  A worker
    # that finds the lock taken gives the run back (return 2) for a later pass.
    exec {lock_fd}>"$cell_ckpt/.lock"
    if ! flock -n "$lock_fd"; then exec {lock_fd}>&-; return 2; fi

    local stamp want
    stamp="$(cat "$cell_ckpt/.stamp" 2>/dev/null || true)"
    want="$(sha256sum "$BENCH_ROOT/$plat/$ex"/*.cfg | awk '{print $1}')-$(podman image inspect -f '{{.Id}}' "$IMAGE_NAME")"
    # restore only from an image made from the same .cfg and the same container
    if [[ -f "$cell_ckpt/criu.log" && "$stamp" == "$want" ]]; then dump=0; fi

    # CRIU dumps first and restores afterwards: the dump belongs to round 1, so
    # a later round waits for it rather than dumping on its own.  If round 1 has
    # already finished without leaving a usable image, stop waiting (otherwise
    # every later round would defer forever) and dump here instead.
    if [[ $dump -eq 1 && "$round" != "1" ]]; then
      if [[ ! -f "$CAMP/round01/${plat}_${ex}_mode1/meta.txt" ]]; then
        exec {lock_fd}>&-; return 2
      fi
      echo "  !! $tag: round 1 left no image, dumping in round $round"
    fi
  fi
  mkdir -p "$rundir"
  fi   # DRY == 0

  local flags=(--rm --name "vptim_$tag")
  [[ -n "$cpuset" ]] && flags+=(--cpuset-cpus "$cpuset")
  if [[ $EUID -eq 0 ]]; then flags+=(--privileged)
  else flags+=(--security-opt label=disable); fi

  local cmd=(podman run "${flags[@]}"
    -e TIMING_MODE="$mode" -e TIMING_DUMP="$dump"
    -e TIMING_INPUT="$TIMING_INPUT" -e TIMING_OUT=/app/timing_out
    -e REPEATS="$REPEATS_PER_RUN" -e TIMING_VP_LOG="$TIMING_VP_LOG"
    -v "$BENCH_ROOT/$plat":/app/sw
    -v "$rundir":/app/timing_out
    -v "$cell_ckpt":/app/checkpoints
    -v "$HERE/in_container_timing.sh":/app/in_container_timing.sh:ro
    -v "$VP_AFL_ROOT/scripts":/app/scripts
    -w "$CONTAINER_WORKDIR"
    "$IMAGE_NAME" /app/in_container_timing.sh "$ex")

  if [[ $DRY -eq 1 ]]; then printf '%q ' "${cmd[@]}"; echo; return 0; fi

  local t0 t1 rc
  t0=$(date +%s)
  timeout -k 60 $((max + 300)) "${cmd[@]}" > "$rundir/run.log" 2>&1; rc=$?
  t1=$(date +%s)
  podman rm -f "vptim_$tag" >/dev/null 2>&1

  local status=OK
  (( rc == 124 || rc == 137 )) && status=TIMEOUT_KILLED
  (( rc == 125 ))              && status=PODMAN_FAILED
  (( rc == 97 ))               && status=SETUP_FAILED
  # count only the four real intervals; "Tot Execution and Restart" is their sum
  # grep -c already prints 0 when nothing matches, it just exits 1 as well, so
  # swallow the status instead of echoing a second 0 into the variable
  local n_int=0 n_to=0
  if [[ -f "$rundir/harness.log" ]]; then
    n_int=$(count_matches 'INFO: (launch_vp|run_init|Execution|Restart): Elapsed' \
              "$rundir/harness.log")
    # An execution that times out does not measure Tbody, it measures
    # TC_TIMEOUT_MS.  Such a run must never reach the medians.
    n_to=$(count_matches 'a timeout occurred' "$rundir/harness.log")
  fi
  if (( n_int == 0 )); then
    [[ "$status" == OK ]] && status=NO_TIMINGS
    echo "  !! $tag: $(tail -1 "$rundir/run.log" 2>/dev/null)"
  elif (( n_to > 0 )); then
    [[ "$status" == OK ]] && status=EXEC_TIMEOUTS
    echo "  !! $tag: $n_to execution(s) timed out (TC_TIMEOUT_MS), not a Tbody measurement"
  fi
  # A DEBUG=0 image runs the AFL path instead of the benchmark loop and would
  # silently produce no intervals at all; say so plainly.
  if [[ -f "$rundir/harness.log" ]] && ! grep -q 'Run manual' "$rundir/harness.log"; then
    status=NOT_DEBUG_BUILD
  fi
  if [[ "$mode" == "1" && "$dump" == "1" && "$status" == "OK" ]]; then
    if [[ -f "$cell_ckpt/criu.log" ]]; then echo "$want" > "$cell_ckpt/.stamp"
    else status=NO_CHECKPOINT; fi
  fi
  [[ -n "$lock_fd" ]] && exec {lock_fd}>&-

  { echo "tag=$tag"; echo "round=$round"; echo "platform=$plat"; echo "example=$ex"
    echo "mode=$mode"; echo "dumped=$dump"; echo "wall_s=$((t1 - t0))"
    echo "exit_code=$rc"; echo "status=$status"; echo "intervals=$n_int"
    echo "exec_timeouts=$n_to"
    echo "repeats=$REPEATS_PER_RUN"; echo "harness_iters=$HARNESS_ITERS"
    echo "input=$TIMING_INPUT"; echo "cpuset=$cpuset"; echo "workers=$WORKERS"
    echo "max_s=$max"; } > "$rundir/meta.txt"
  echo "[$(date +%H:%M:%S)] w$w $tag -> $status (dump=$dump, ${n_int} intervals, $((t1 - t0))s)"
  sleep "$COOLDOWN"
}

worker() {    # $1 = worker index
  local w="$1" claimed deferred rundir
  while :; do
    claimed=0; deferred=0
    while IFS=$'\t' read -r round idx plat ex mode tag; do
      [[ "$round" == \#* || -z "${tag:-}" ]] && continue
      [[ -n "$ONLY_MODE" && "$mode" != "$ONLY_MODE" ]] && continue
      [[ -n "$ONLY_CELL" && "$plat:$ex" != "$ONLY_CELL" ]] && continue
      # mode 1 needs root: leave the row unclaimed so a later sudo -E run can
      # still pick it up (a claim would make it unreachable forever)
      [[ $DRY -eq 0 && "$mode" == "1" && $EUID -ne 0 ]] && continue
      rundir="$CAMP/round$(printf '%02d' "$round")/${plat}_${ex}_mode${mode}"
      [[ -f "$rundir/meta.txt" ]] && continue                 # already finished
      if [[ $DRY -eq 1 ]]; then
        run_one "$round" "$plat" "$ex" "$mode" "$tag" "$w"; claimed=1; continue
      fi
      mkdir "$CLAIMS/$tag" 2>/dev/null || continue             # another worker has it
      run_one "$round" "$plat" "$ex" "$mode" "$tag" "$w"
      case $? in
        0) claimed=1 ;;
        2) rmdir "$CLAIMS/$tag"; deferred=1 ;;                 # CRIU cell busy / waiting for the dump
        *) rmdir "$CLAIMS/$tag"; return 1 ;;                   # abort (disk)
      esac
    done < "$SCHED"
    (( DRY == 1 )) && break        # one pass is all a dry run needs
    (( claimed == 0 && deferred == 0 )) && break
    (( claimed == 0 )) && sleep 30
  done
}

if [[ $DRY -eq 1 || $WORKERS -le 1 ]]; then
  worker 0
else
  for ((w = 0; w < WORKERS; w++)); do worker "$w" & sleep 2; done
  wait
fi
echo "done: $CAMP   -> python3 $HERE/timing_metrics.py $CAMP"
