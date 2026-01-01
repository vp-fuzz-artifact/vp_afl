# Sourced helper: make an image available in the podman store we are using.
#
# podman keeps a separate image store per user, so an image built rootless
# (~/.local/share/containers) is invisible to root (/var/lib/containers) and
# the other way round.  The timing campaign is built rootless but has to run
# under sudo for CRIU (mode 1), which is exactly the case where the image
# "disappears".  scripts/docker_run.sh solves this by streaming the image from
# the invoking user's store into root's; same thing here.
#
# docker needs none of this: one daemon, one store.

# ensure_image <image> [container_program]
#   0 = the image is now usable, 1 = it is not and could not be imported
ensure_image() {
  local img="$1" cp="${2:-podman}"
  $cp image exists "$img" 2>/dev/null && return 0

  # only podman has per-user stores, and only root can read another user's
  [[ "$cp" == "podman" && $EUID -eq 0 ]] || return 1
  local u="${SUDO_USER:-}"
  [[ -n "$u" && "$u" != "root" ]] || return 1
  local uid
  uid="$(id -u "$u" 2>/dev/null)" || return 1

  # -H so podman finds the user's graphroot under their HOME
  local as_user=(sudo -u "$u" -H env "XDG_RUNTIME_DIR=/run/user/$uid")
  "${as_user[@]}" podman image exists "$img" 2>/dev/null || return 1

  echo "image $img is in ${u}'s rootless store but not root's; copying it over"
  "${as_user[@]}" podman save "$img" | podman load || {
    echo "  copy failed"; return 1; }
  # save/load preserves the image Id, so a CRIU stamp taken under one store
  # still matches under the other
  $cp image exists "$img" 2>/dev/null
}
