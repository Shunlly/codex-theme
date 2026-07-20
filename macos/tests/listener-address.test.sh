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

CURRENT_UID="$(/usr/bin/id -u)"
FOREIGN_UID="$((CURRENT_UID + 1))"
/bin/mkdir -p "$TMP/engine/scripts"
/bin/cp "$ROOT/VERSION" "$TMP/engine/VERSION"
/usr/bin/sed "s|/bin/ps|$TMP/ps|g" "$ROOT/scripts/common-macos.sh" > "$TMP/engine/scripts/common-macos.sh"
/usr/bin/sed \
  -e "s|__CURRENT_UID__|$CURRENT_UID|g" \
  -e "s|__FOREIGN_UID__|$FOREIGN_UID|g" \
  > "$TMP/ps" <<'STUB'
#!/bin/bash
case "$*" in
  '-axo uid=,pid=,command=')
    printf '%s\n' \
      '__CURRENT_UID__ 101 /fixture/renderer' \
      '__FOREIGN_UID__ 202 /fixture/renderer' \
      '__FOREIGN_UID__ 303 /fixture/Codex --remote-debugging-port=9341' \
      '__CURRENT_UID__ 404 /fixture/Codex --remote-debugging-port=9341'
    ;;
  '-axo pid=,command=')
    printf '%s\n' \
      '202 /fixture/renderer' \
      '303 /fixture/Codex --remote-debugging-port=9341' \
      '404 /fixture/Codex --remote-debugging-port=9341'
    ;;
  '-p 101 -o uid=') printf '%s\n' '__CURRENT_UID__' ;;
  '-p 202 -o uid='|'-p 303 -o uid=') printf '%s\n' '__FOREIGN_UID__' ;;
  '-p 404 -o uid=') printf '%s\n' '__CURRENT_UID__' ;;
  '-p 101 -o command=') printf '%s\n' '/fixture/renderer' ;;
  '-p 202 -o command=') printf '%s\n' '/fixture/renderer' ;;
  '-p 303 -o command='|'-p 404 -o command=') printf '%s\n' '/fixture/Codex --remote-debugging-port=9341' ;;
  '-p 101 -o ppid=') printf '%s\n' '404' ;;
  '-p 202 -o ppid=') printf '%s\n' '303' ;;
  *) exit 1 ;;
esac
STUB
/bin/chmod 755 "$TMP/ps"

/usr/bin/env HOME="$TMP/home" LISTENER_MARKER="$TMP/foreign-listener-http" /bin/bash -c '
  set -euo pipefail
  . "$1"
  CODEX_EXE=/fixture/Codex
  listener_records() { printf "p202\nf7\nn127.0.0.1:9341\n"; }
  cdp_browser_id() { : > "$LISTENER_MARKER"; printf "Browser-A\n"; }
  [ "$(codex_main_pids)" = 404 ] || {
    printf "Foreign Codex main PID was classified as local.\n" >&2
    exit 1
  }
  ! pid_is_codex_descendant 202 || {
    printf "Foreign listener ancestry was classified as local Codex.\n" >&2
    exit 1
  }
  pid_is_codex_descendant 101
  ! verified_cdp_browser_id 9341 || {
    printf "Foreign listener was accepted as the verified CDP endpoint.\n" >&2
    exit 1
  }
  [ ! -e "$LISTENER_MARKER" ] || {
    printf "Foreign listener was queried over CDP.\n" >&2
    exit 1
  }
' _ "$TMP/engine/scripts/common-macos.sh"

printf 'PASS: macOS listener parsing requires numeric loopback addresses and Codex PID ancestry.\n'
