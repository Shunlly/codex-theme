#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(/usr/bin/mktemp -d /tmp/codex-dream-skin-listener.XXXXXX)"
trap '/bin/rm -rf "$TMP"' EXIT
/bin/mkdir -p "$TMP/home"

probe() {
  local records="$1"
  local rejected_pid="${2:-}"
  /usr/bin/env HOME="$TMP/home" LISTENER_FIXTURE="$records" REJECTED_PID="$rejected_pid" \
    /bin/bash -c '
      . "$1/scripts/common-macos.sh"
      listener_records() { printf "%s" "$LISTENER_FIXTURE"; }
      pid_is_codex_descendant() { [ "$1" != "$REJECTED_PID" ]; }
      port_belongs_to_codex 9341
    ' _ "$ROOT"
}

probe $'p101\nf7\nn127.0.0.1:9341\np202\nf8\nn[::1]:9341\n'

for rejected in \
  $'p101\nf7\nn0.0.0.0:9341\n' \
  $'p101\nf7\nn*:9341\n' \
  $'p101\nf7\nn192.168.1.2:9341\n' \
  $'p101\nf7\nn127.0.0.1:9341\np202\nf8\nn0.0.0.0:9341\n' \
  $'p101\nf7\nnlocalhost:9341\n' \
  $'p101\nf7\nn127.0.0.1:93410\n' \
  $'n127.0.0.1:9341\n' \
  $'pnot-a-pid\nf7\nn127.0.0.1:9341\n' \
  $'p101\nf7\n'; do
  if probe "$rejected"; then
    printf 'Accepted unsafe lsof listener records: %q\n' "$rejected" >&2
    exit 1
  fi
done

if probe $'p101\nf7\nn127.0.0.1:9341\np202\nf8\nn[::1]:9341\n' 202; then
  printf 'Accepted a loopback listener whose PID ancestry was not Codex.\n' >&2
  exit 1
fi

/usr/bin/env HOME="$TMP/home" LISTENER_FIXTURE='' /bin/bash -c '
  . "$1/scripts/common-macos.sh"
  listener_records() { printf "%s" "$LISTENER_FIXTURE"; }
  port_is_available 9341
' _ "$ROOT"

if /usr/bin/env HOME="$TMP/home" LISTENER_FIXTURE=$'p101\nf7\nn*:9341\n' /bin/bash -c '
  . "$1/scripts/common-macos.sh"
  listener_records() { printf "%s" "$LISTENER_FIXTURE"; }
  port_is_available 9341
' _ "$ROOT"; then
  printf 'Treated an unsafe listener record as an available port.\n' >&2
  exit 1
fi

printf 'PASS: macOS listener parsing requires numeric loopback addresses and Codex PID ancestry.\n'
