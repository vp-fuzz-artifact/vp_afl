#!/usr/bin/env bash
# Build the timing image, base image included.
#
#   ./container_build.sh              build the base image if it is missing, then
#                                  the timing image, then verify it
#   ./container_build.sh --skip-base  fail instead of building the base
#   ./container_build.sh --rebuild    rebuild the timing image even if it exists
#
# The timing image only replaces the harness with its DEBUG=1 build, so it
# derives from the fuzzing image rather than repeating its ~30 min of VP, AFL
# and CRIU builds.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
. "$HERE/podman_store.sh"

SKIP_BASE=0; REBUILD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-base) SKIP_BASE=1 ;;
    --rebuild)   REBUILD=1 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac; shift
done

if command -v podman >/dev/null 2>&1; then CP=podman
elif command -v docker >/dev/null 2>&1; then CP=docker
else echo "no podman or docker found"; exit 1; fi
echo "Using $CP"

BASE_IMAGE="${BASE_IMAGE:-localhost/vp-afl:latest}"
TIMING_IMAGE="${IMAGE_NAME:-vp-afl-timing}"
# docker has no "localhost/" prefix for local images
[[ "$CP" == "docker" ]] && BASE_IMAGE="${BASE_IMAGE#localhost/}"

# ensure_image also imports the image from the invoking user's rootless store
# when we run as root, so `sudo ./container_build.sh` after a rootless build
# copies the images over instead of rebuilding them.  The inspect is the docker
# fallback: one daemon, one store, and no `image exists` subcommand.
have() { ensure_image "$1" "$CP" && return 0; $CP image inspect "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------------ base
if have "$BASE_IMAGE"; then
  echo "base image $BASE_IMAGE: present"
else
  echo "base image $BASE_IMAGE: MISSING"
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    echo "  note: running as root, and it is not in ${SUDO_USER}'s rootless"
    echo "  store either, so there was nothing to copy over."
  fi
  if [[ $SKIP_BASE -eq 1 ]]; then
    echo "  --skip-base given; build it first with:"
    echo "    $ROOT/scripts/docker_build.sh"
    exit 1
  fi
  echo "  building it with scripts/docker_build.sh"
  "$ROOT/scripts/docker_build.sh" || { echo "base image build failed"; exit 1; }
  have "$BASE_IMAGE" || { echo "base image still missing after the build"; exit 1; }
fi

# ------------------------------------------------------------------ timing
if have "$TIMING_IMAGE" && [[ $REBUILD -eq 0 ]]; then
  echo "timing image $TIMING_IMAGE: present (--rebuild to redo it)"
else
  echo "building $TIMING_IMAGE from $BASE_IMAGE"
  $CP build -t "$TIMING_IMAGE" --build-arg BASE_IMAGE="$BASE_IMAGE" \
      -f "$HERE/Dockerfile.timing" "$ROOT" \
    || { echo "timing image build failed"; exit 1; }
fi

# ------------------------------------------------------------------ verify
# A non-DEBUG harness takes the AFL path and would silently record no
# intervals at all, so prove the DEBUG path is the one compiled in: only it
# logs "Run manual." (main.cpp).  Run it with no target, which fails straight
# after that line, and look for it in the log.
echo -n "verifying the DEBUG build ... "
if $CP run --rm -e TC_LOGGING=1 -e TC_LOGGING_PATH=/tmp/probe.log \
      "$TIMING_IMAGE" \
      bash -c '"$TC_PATH" >/dev/null 2>&1; grep -q "Run manual" /tmp/probe.log' \
      >/dev/null 2>&1; then
  echo "ok (DEBUG harness at \$TC_PATH)"
else
  echo "FAILED"
  echo "  $TIMING_IMAGE does not contain a DEBUG=1 harness; run_timing.sh would"
  echo "  mark every run NOT_DEBUG_BUILD.  Try: $0 --rebuild"
  exit 1
fi
echo "done: $TIMING_IMAGE ready -> cd $HERE && ./run_timing.sh --dry-run"
