#!/bin/bash
# Runs inside the vp-afl container, same working dir as docker_run.sh uses.
# It sources your settings.bash and only overrides what the campaign varies.
# env in: CAMP_MODE CAMP_DUMP CAMP_SEED CAMP_OUT CAMP_AFL_T CAMP_NOFIND CAMP_MAX
# argv:   <benchmark name>
set -u
BM="$1"; SW="/app/sw"; PROJ="$SW/$BM"
die() { echo "CAMPAIGN-FATAL: $*" >&2; exit 97; }

CFG="$(ls "$PROJ"/*.cfg 2>/dev/null | head -1)"; [[ -n "$CFG" ]] || die "no .cfg in $PROJ"
[[ -f "$PROJ/mmio_config.json" ]] || die "no mmio_config.json"

export TC_CHKPT_MODE="$CAMP_MODE"       # settings.bash honours ${TC_CHKPT_MODE:-0}
export TC_DUMP="$CAMP_DUMP"             # 1 = dump, 0 = restore from images
export CRIU_IMG_DIR="/app/checkpoints"  # per-cell dir, mounted from the host
export TC_LOGGING=2                     # errors only: catches the mode fallback
export TC_LOGGING_PATH="/app/campaign_out/harness.log"
export TC_VP_LOGGING=0

# shellcheck disable=SC1090
. "$SW/settings.bash" "$BM" || die "settings.bash failed"
[[ "$TC_CHKPT_MODE" == "$CAMP_MODE" ]] || die "mode fell back to $TC_CHKPT_MODE (not root?)"

export JSON_CFG_PATH="$PROJ/mmio_config.json"
export PUT_DIR="$SW"
SEEDS="$PROJ/seeds"
[[ -L "$SEEDS/seed_0" ]] && SEEDS="$(dirname "$(readlink -f "$SEEDS/seed_0")")"

export AFL_SKIP_CPUFREQ=1 AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1
export AFL_NO_AFFINITY=1                # pinning is done by podman --cpuset-cpus
export AFL_NO_UI=1                      # plain log instead of the TUI
export AFL_EXIT_ON_TIME="$CAMP_NOFIND"  # stop when no new coverage for N seconds

# -v is VP mode, -V the hard cap, -s the RNG seed of this round
exec ./afl-fuzz -s "$CAMP_SEED" -i "$SEEDS" -o "$CAMP_OUT" \
     -t "$CAMP_AFL_T" -m none -V "$CAMP_MAX" -v -- "$CFG"
