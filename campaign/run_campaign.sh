#!/usr/bin/env bash
# Campaign driver.  WORKERS containers run in parallel; each worker takes the
# next unclaimed run from schedule.tsv, so the counterbalanced order is kept.
#
#   ./run_campaign.sh --dry-run        print schedule + the podman command
#   ./run_campaign.sh --smoke          3 min per run, checks every cell works
#   sudo -E ./run_campaign.sh          the campaign (mode 1 needs root)
#   sudo -E ./run_campaign.sh --workers 8
#   ./run_campaign.sh --smoke --only-cell zephyr:crypto
# Interrupted? run it again: finished runs are skipped.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/campaign.conf"

DRY=0; SMOKE=0; ONLY_MODE=""; ONLY_CELL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY=1 ;;
    --smoke)     SMOKE=1 ;;
    --workers)   WORKERS="$2"; shift ;;
    --rounds)    ROUNDS="$2"; shift ;;
    --only-mode) ONLY_MODE="$2"; shift ;;
    --only-cell) ONLY_CELL="$2"; shift ;;
    --results)   RESULTS_ROOT="$2"; shift ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac; shift
done

if [[ $SMOKE -eq 1 ]]; then
  # just long enough to reach the first executions; Linux boots far slower
  ROUNDS=1; MAX_SECONDS=180; MAX_SECONDS_Linux=900
  NOFIND_baremetal=60; NOFIND_zephyr=60; NOFIND_Linux=300
  CAMP="$RESULTS_ROOT/smoke_$(date +%Y%m%d_%H%M%S)"
else
  CAMP="$RESULTS_ROOT/campaign"
fi

for c in "${CELLS[@]}"; do
  d="$BENCH_ROOT/${c%%:*}/${c##*:}"
  [[ -d "$d" ]] || { echo "BENCH_ROOT looks wrong: $d does not exist"; exit 1; }
  compgen -G "$d/*.cfg" >/dev/null || { echo "no .cfg in $d"; exit 1; }
done
SCHED="$CAMP/schedule.tsv"; CLAIMS="$CAMP/.claims"; CKPT="$CAMP/checkpoints"
mkdir -p "$CAMP" "$CLAIMS" "$CKPT"

podman image exists "$IMAGE_NAME" || { echo "image $IMAGE_NAME missing"; exit 1; }

if [[ ! -s "$SCHED" ]]; then
  args=(); for c in "${CELLS[@]}"; do args+=(--cell "$c"); done
  for m in "${MODES[@]}"; do args+=(--mode "$m"); done
  args+=(--afl-seed-base "$AFL_SEED_BASE"
         --afl-seed-per-round "$AFL_SEED_PER_ROUND")
  python3 "$HERE/gen_schedule.py" --rounds "$ROUNDS" --seed "$ORDER_SEED" "${args[@]}" > "$SCHED" \
    || { echo "schedule generation failed"; exit 1; }
  echo "schedule: $SCHED"
fi

{ echo "date=$(date -Is)"; echo "host=$(hostname)"; echo "uid=$EUID"
  echo "vp_afl=$(git -C "$VP_AFL_ROOT" rev-parse --short HEAD 2>/dev/null)"
  echo "image=$(podman image inspect -f '{{.Id}}' "$IMAGE_NAME" | cut -c1-12)"
  echo "workers=$WORKERS"; echo "max_seconds=$MAX_SECONDS"
  echo "afl_seed_base=$AFL_SEED_BASE per_round=$AFL_SEED_PER_ROUND"
  echo "nofind=bm:$NOFIND_baremetal zephyr:$NOFIND_zephyr linux:$NOFIND_Linux"
} > "$CAMP/campaign_info.txt"

run_one() {   # round platform example mode seed tag worker
  local round="$1" plat="$2" ex="$3" mode="$4" seed="$5" tag="$6" w="$7"
  local rundir="$CAMP/round$(printf '%02d' "$round")/${plat}_${ex}_mode${mode}"
  local nf="NOFIND_${plat}"; local nofind="${!nf}"
  local tt="AFL_T_${plat}";  local afl_t="${!tt}"
  local mx="MAX_SECONDS_${plat}"; local max="${!mx:-$MAX_SECONDS}"
  local cell_ckpt="$CKPT/${plat}_${ex}"
  local cpuset=""; [[ ${#WORKER_CPUSETS[@]} -gt 0 ]] && cpuset="${WORKER_CPUSETS[$w]}"

  if (( $(df -Pm "$CAMP" | awk 'NR==2{print $4}') < MIN_FREE_MB )); then
    echo "ABORT worker $w: free disk < ${MIN_FREE_MB}MB"; return 1
  fi
  if [[ "$mode" == "1" && $EUID -ne 0 ]]; then
    echo "skip $tag: CRIU needs root"; return 0
  fi

  # CRIU rounds of one cell share a single image dir, so they must not run at
  # the same time: take the cell lock, and if another worker holds it, give the
  # run back (return 2) so it is picked up in a later pass.
  mkdir -p "$cell_ckpt"          # mounted into the container for every mode,
                                 # and holds the CRIU lock below
  local lock_fd=; local dump=1
  if [[ "$mode" == "1" ]]; then
    exec {lock_fd}>"$cell_ckpt/.lock"
    if ! flock -n "$lock_fd"; then exec {lock_fd}>&-; return 2; fi
    local stamp; stamp="$(cat "$cell_ckpt/.stamp" 2>/dev/null || true)"
    local want; want="$(sha256sum "$BENCH_ROOT/$plat/$ex"/*.cfg | awk '{print $1}')-$(podman image inspect -f '{{.Id}}' "$IMAGE_NAME")"
    # restore only from an image made from the same .cfg and the same container
    if [[ -f "$cell_ckpt/criu.log" && "$stamp" == "$want" ]]; then dump=0; fi
  fi

  mkdir -p "$rundir/afl"
  local flags=(--rm --name "vpafl_$tag")
  [[ -n "$cpuset" ]] && flags+=(--cpuset-cpus "$cpuset")
  if [[ $EUID -eq 0 ]]; then flags+=(--privileged)
  else flags+=(--security-opt label=disable); fi

  local cmd=(podman run "${flags[@]}"
    -e CAMP_MODE="$mode" -e CAMP_DUMP="$dump" -e CAMP_SEED="$seed"
    -e CAMP_OUT=/app/campaign_out/afl -e CAMP_AFL_T="$afl_t"
    -e CAMP_NOFIND="$nofind" -e CAMP_MAX="$max"
    -v "$BENCH_ROOT/$plat":/app/sw
    -v "$rundir":/app/campaign_out
    -v "$cell_ckpt":/app/checkpoints
    -v "$HERE/in_container_run.sh":/app/in_container_run.sh:ro
    -v "$VP_AFL_ROOT/scripts":/app/scripts
    -w /app/vp_mode/aflplusplus
    "$IMAGE_NAME" /app/in_container_run.sh "$ex")

  if [[ $DRY -eq 1 ]]; then printf '%q ' "${cmd[@]}"; echo; return 0; fi

  local t0 t1 rc
  t0=$(date +%s)
  timeout -k 60 $((max + 1800)) "${cmd[@]}" > "$rundir/afl.log" 2>&1; rc=$?
  t1=$(date +%s)
  podman rm -f "vpafl_$tag" >/dev/null 2>&1

  local status=OK
  (( rc == 124 || rc == 137 )) && status=TIMEOUT_KILLED
  (( rc == 125 ))              && status=PODMAN_FAILED
  (( rc == 97 ))               && status=SETUP_FAILED
  if [[ ! -s "$rundir/afl/default/fuzzer_stats" ]]; then
    [[ "$status" == OK ]] && status=NO_STATS
    echo "  !! $tag: $(tail -1 "$rundir/afl.log")"
  fi
  if [[ "$mode" == "1" && "$dump" == "1" && "$status" == "OK" ]]; then
    if [[ -f "$cell_ckpt/criu.log" ]]; then echo "$want" > "$cell_ckpt/.stamp"
    else status=NO_CHECKPOINT; fi
  fi
  [[ -n "$lock_fd" ]] && exec {lock_fd}>&-

  { echo "tag=$tag"; echo "round=$round"; echo "platform=$plat"; echo "example=$ex"
    echo "mode=$mode"; echo "dumped=$dump"; echo "afl_seed=$seed"
    echo "wall_s=$((t1 - t0))"; echo "exit_code=$rc"; echo "status=$status"
    echo "nofind_s=$nofind"; echo "max_s=$max"; echo "cpuset=$cpuset"
    echo "workers=$WORKERS"; } > "$rundir/meta.txt"
  echo "[$(date +%H:%M:%S)] w$w $tag -> $status ($((t1 - t0))s)"
  sleep "$COOLDOWN"
}

worker() {    # $1 = worker index
  local w="$1" claimed deferred rundir
  while :; do
    claimed=0; deferred=0
    while IFS=$'\t' read -r round idx plat ex mode seed tag; do
      [[ "$round" == \#* || -z "${tag:-}" ]] && continue
      [[ -n "$ONLY_MODE" && "$mode" != "$ONLY_MODE" ]] && continue
      [[ -n "$ONLY_CELL" && "$plat:$ex" != "$ONLY_CELL" ]] && continue
      rundir="$CAMP/round$(printf '%02d' "$round")/${plat}_${ex}_mode${mode}"
      [[ -f "$rundir/meta.txt" ]] && continue                 # already finished
      mkdir "$CLAIMS/$tag" 2>/dev/null || continue             # another worker has it
      run_one "$round" "$plat" "$ex" "$mode" "$seed" "$tag" "$w"
      case $? in
        0) claimed=1 ;;
        2) rmdir "$CLAIMS/$tag"; deferred=1 ;;                 # CRIU cell busy
        *) rmdir "$CLAIMS/$tag"; return 1 ;;                   # abort (disk)
      esac
    done < "$SCHED"
    # nothing left for this worker: stop, unless a deferred run may free up
    (( claimed == 0 && deferred == 0 )) && break
    (( claimed == 0 )) && sleep 60
  done
}

if [[ $DRY -eq 1 || $WORKERS -le 1 ]]; then
  worker 0
else
  for ((w = 0; w < WORKERS; w++)); do worker "$w" & sleep 3; done
  wait
fi
echo "done: $CAMP   -> python3 $HERE/metrics.py $CAMP"
