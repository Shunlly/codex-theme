#!/bin/bash

set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
NODE="${NODE:-/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node}"
[ -x "$NODE" ] || { printf 'Codex bundled Node.js was not found: %s\n' "$NODE" >&2; exit 1; }

"$NODE" -e '
  const source = require("node:fs").readFileSync(process.argv[1], "utf8");
  if (!/mdfind '\''kMDItemCFBundleIdentifier == "com\.openai\.codex"'\''/.test(source)) {
    throw new Error("Studio status is missing the official Codex Spotlight fallback.");
  }
' "$SOURCE_ROOT/scripts/status-dream-skin-macos.sh"

TMP="$(/usr/bin/mktemp -d /tmp/codex-dream-skin-studio-adapter.XXXXXX)"
ROOT="$TMP/bundled-engine"
TEST_HOME="$TMP/home"
/bin/mkdir -p "$TEST_HOME" "$ROOT/bin"
/bin/cp -R "$SOURCE_ROOT/scripts" "$ROOT/scripts"
/bin/cp "$SOURCE_ROOT/VERSION" "$ROOT/VERSION"
/usr/bin/swift build --package-path "$SOURCE_ROOT/studio" --product dream-skin-config-restore >/dev/null
BUILT_NATIVE_HELPER="$(/usr/bin/swift build --package-path "$SOURCE_ROOT/studio" --show-bin-path)/dream-skin-config-restore"
/bin/cp "$BUILT_NATIVE_HELPER" "$ROOT/bin/dream-skin-config-restore"
/bin/chmod 755 "$ROOT/bin/dream-skin-config-restore"
RESPONDER_PID=""
LIFECYCLE_OWNER_PID=""
ADAPTER_LOCK_OWNER_PID=""
LOCK_RACE_A_PID=""
LOCK_RACE_B_PID=""
LOCK_GATE_HOLDER_PID=""
RECOVERY_WATCHER_PID=""
FIRST_RUN_CODEX_PID=""
cleanup() {
  [ -z "$RESPONDER_PID" ] || /bin/kill -TERM "$RESPONDER_PID" 2>/dev/null || true
  [ -z "$RESPONDER_PID" ] || wait "$RESPONDER_PID" 2>/dev/null || true
  [ -z "$LIFECYCLE_OWNER_PID" ] || /bin/kill -TERM "$LIFECYCLE_OWNER_PID" 2>/dev/null || true
  [ -z "$LIFECYCLE_OWNER_PID" ] || wait "$LIFECYCLE_OWNER_PID" 2>/dev/null || true
  [ -z "$ADAPTER_LOCK_OWNER_PID" ] || /bin/kill -TERM "$ADAPTER_LOCK_OWNER_PID" 2>/dev/null || true
  [ -z "$ADAPTER_LOCK_OWNER_PID" ] || wait "$ADAPTER_LOCK_OWNER_PID" 2>/dev/null || true
  [ -z "$LOCK_RACE_A_PID" ] || /bin/kill -TERM "$LOCK_RACE_A_PID" 2>/dev/null || true
  [ -z "$LOCK_RACE_A_PID" ] || wait "$LOCK_RACE_A_PID" 2>/dev/null || true
  [ -z "$LOCK_RACE_B_PID" ] || /bin/kill -TERM "$LOCK_RACE_B_PID" 2>/dev/null || true
  [ -z "$LOCK_RACE_B_PID" ] || wait "$LOCK_RACE_B_PID" 2>/dev/null || true
  [ -z "$LOCK_GATE_HOLDER_PID" ] || /bin/kill -TERM "$LOCK_GATE_HOLDER_PID" 2>/dev/null || true
  [ -z "$LOCK_GATE_HOLDER_PID" ] || wait "$LOCK_GATE_HOLDER_PID" 2>/dev/null || true
  [ -z "$RECOVERY_WATCHER_PID" ] || /bin/kill -TERM "$RECOVERY_WATCHER_PID" 2>/dev/null || true
  [ -z "$RECOVERY_WATCHER_PID" ] || wait "$RECOVERY_WATCHER_PID" 2>/dev/null || true
  if [ -n "$FIRST_RUN_CODEX_PID" ]; then
    /bin/kill -TERM "$FIRST_RUN_CODEX_PID" 2>/dev/null || true
    cleanup_deadline=$((SECONDS + 5))
    while /bin/kill -0 "$FIRST_RUN_CODEX_PID" 2>/dev/null \
      && [ "$SECONDS" -lt "$cleanup_deadline" ]; do /bin/sleep 0.02; done
    /bin/kill -KILL "$FIRST_RUN_CODEX_PID" 2>/dev/null || true
    wait "$FIRST_RUN_CODEX_PID" 2>/dev/null || true
  fi
  /bin/rm -rf "$TMP"
}
trap cleanup EXIT

WATCHER_FIXTURE="$TMP/watcher-guard"
WATCHER_HOME="$WATCHER_FIXTURE/home"
WATCHER_MARKER="$WATCHER_FIXTURE/commands"
/bin/mkdir -p "$WATCHER_HOME/Library/Application Support/CodexDreamSkinStudio"
/bin/cp "$SOURCE_ROOT/VERSION" "$TMP/VERSION"
/usr/bin/sed \
  -e "s|/usr/bin/nohup|$WATCHER_FIXTURE/nohup|g" \
  -e "s|/bin/launchctl|$WATCHER_FIXTURE/launchctl|g" \
  -e "s|/bin/kill|$WATCHER_FIXTURE/kill|g" \
  -e "s|/bin/sleep|$WATCHER_FIXTURE/sleep|g" \
  "$SOURCE_ROOT/scripts/common-macos.sh" > "$WATCHER_FIXTURE/common-macos.sh"
/usr/bin/sed "s|__MARKER__|$WATCHER_MARKER|g" > "$WATCHER_FIXTURE/nohup" <<'STUB'
#!/bin/bash
printf 'nohup %s\n' "$*" >> "__MARKER__"
exit 1
STUB
/usr/bin/sed -e "s|__MARKER__|$WATCHER_MARKER|g" \
  -e "s|__SUBMITTED__|$WATCHER_FIXTURE/submitted|g" > "$WATCHER_FIXTURE/launchctl" <<'STUB'
#!/bin/bash
printf 'launchctl %s\n' "$*" >> "__MARKER__"
case "${1:-}" in
  print)
    [ -e "__SUBMITTED__" ] || exit 113
    printf '  pid = 4242\n'
    ;;
  submit) : > "__SUBMITTED__" ;;
  remove) /bin/rm -f "__SUBMITTED__" ;;
esac
STUB
/usr/bin/sed > "$WATCHER_FIXTURE/kill" <<'STUB'
#!/bin/bash
[ "${1:-}" = "-0" ] && [ "${2:-}" = "4242" ]
STUB
/usr/bin/sed > "$WATCHER_FIXTURE/sleep" <<'STUB'
#!/bin/bash
exit 0
STUB
/bin/chmod 755 "$WATCHER_FIXTURE/nohup" "$WATCHER_FIXTURE/launchctl" \
  "$WATCHER_FIXTURE/kill" "$WATCHER_FIXTURE/sleep"

run_watcher_fixture() (
  source "$WATCHER_FIXTURE/common-macos.sh"
  NODE=/usr/bin/false
  process_started_at() { printf 'fixture-start\n'; }
  launched_injector_process_matches() { [ "$1" = "4242" ]; }
  launch_injector_daemon 9341 Browser-A "$STATE_ROOT/.watcher-activation.Ab12Cd"
  printf '%s\n' "$LAUNCHED_INJECTOR_PID"
)

: > "$WATCHER_MARKER"
set +e
HOME="$WATCHER_HOME" DREAM_SKIN_STUDIO_ADAPTER=true \
  run_watcher_fixture > "$WATCHER_FIXTURE/studio.out" 2>/dev/null
WATCHER_EXIT="$?"
set -e
[ "$WATCHER_EXIT" -ne 0 ] || { printf 'Studio watcher failure fell back to launchctl submit.\n' >&2; exit 1; }
/usr/bin/grep -q '^nohup ' "$WATCHER_MARKER"
/usr/bin/grep -q -- '--port 9341 --browser-id Browser-A --theme-dir ' "$WATCHER_MARKER"
/usr/bin/grep -q -- '--activation-gate ' "$WATCHER_MARKER"
! /usr/bin/grep -q '^launchctl submit ' "$WATCHER_MARKER"

: > "$WATCHER_MARKER"
WATCHER_PID="$(HOME="$WATCHER_HOME" run_watcher_fixture)"
[ "$WATCHER_PID" = "4242" ] || { printf 'Legacy watcher fallback did not return its launchctl PID.\n' >&2; exit 1; }
/usr/bin/grep -q '^launchctl submit ' "$WATCHER_MARKER"
/usr/bin/grep -q -- '--port 9341 --browser-id Browser-A --theme-dir ' "$WATCHER_MARKER"
/usr/bin/grep -q -- '--activation-gate ' "$WATCHER_MARKER"

# One per-user lifecycle owner must serialize direct callers, allow only its
# verified descendants to reuse the lock, and project contention read-only.
LOCK_FIXTURE="$TMP/lifecycle-lock"
LOCK_HOME="$LOCK_FIXTURE/home"
LOCK_READY="$LOCK_FIXTURE/ready"
LOCK_RELEASE="$LOCK_FIXTURE/release"
LOCK_CHILD="$LOCK_FIXTURE/child"
LOCK_OWNER_PID_FILE="$LOCK_FIXTURE/owner-pid"
LOCK_OWNER_START_FILE="$LOCK_FIXTURE/owner-start"
LOCK_STATE="$LOCK_HOME/Library/Application Support/CodexDreamSkinStudio"
/bin/mkdir -p "$LOCK_FIXTURE" "$LOCK_HOME/.codex" "$LOCK_STATE"
/usr/bin/printf 'config sentinel\n' > "$LOCK_HOME/.codex/config.toml"
/usr/bin/printf 'state sentinel\n' > "$LOCK_STATE/state.json"
/usr/bin/sed > "$LOCK_FIXTURE/owner.sh" <<'STUB'
#!/bin/bash
set -euo pipefail
. "$1/scripts/common-macos.sh"
require_lifecycle_lock
trap release_lifecycle_lock EXIT
if [ "${7:-}" != "reentered" ]; then
  exec "$0" "$1" "$2" "$3" "$4" "$5" "$6" reentered
fi
[ "$LIFECYCLE_LOCK_OWNED" = "true" ]
[ "$LIFECYCLE_LOCK_BORROWED" = "false" ]
printf '%s\n' "$DREAM_SKIN_LIFECYCLE_LOCK_OWNER_PID" > "$5"
printf '%s\n' "$DREAM_SKIN_LIFECYCLE_LOCK_OWNER_STARTED_AT" > "$6"
/bin/bash -c '
  set -euo pipefail
  . "$1/scripts/common-macos.sh"
  require_lifecycle_lock
  [ "$LIFECYCLE_LOCK_BORROWED" = "true" ]
  : > "$2"
' _ "$1" "$4"
: > "$2"
while [ ! -e "$3" ]; do /bin/sleep 0.02; done
STUB
/bin/chmod 755 "$LOCK_FIXTURE/owner.sh"
/usr/bin/env HOME="$LOCK_HOME" TZ=UTC "$LOCK_FIXTURE/owner.sh" \
  "$ROOT" "$LOCK_READY" "$LOCK_RELEASE" "$LOCK_CHILD" \
  "$LOCK_OWNER_PID_FILE" "$LOCK_OWNER_START_FILE" &
LIFECYCLE_OWNER_PID="$!"
deadline=$((SECONDS + 5))
while [ ! -e "$LOCK_READY" ] && /bin/kill -0 "$LIFECYCLE_OWNER_PID" 2>/dev/null \
  && [ "$SECONDS" -lt "$deadline" ]; do
  /bin/sleep 0.02
done
[ -e "$LOCK_READY" ] && [ -e "$LOCK_CHILD" ] || {
  printf 'Lifecycle owner or verified child did not acquire the shared lock.\n' >&2
  exit 1
}

set +e
/usr/bin/env HOME="$LOCK_HOME" TZ=Asia/Shanghai \
  DREAM_SKIN_LIFECYCLE_LOCK_OWNER_PID="$(/bin/cat "$LOCK_OWNER_PID_FILE")" \
  DREAM_SKIN_LIFECYCLE_LOCK_OWNER_STARTED_AT="$(/bin/cat "$LOCK_OWNER_START_FILE")" \
  /bin/bash -c '
    . "$1/scripts/common-macos.sh"
    acquire_lifecycle_lock
  ' _ "$ROOT"
SPOOF_EXIT="$?"
set -e
[ "$SPOOF_EXIT" -ne 0 ] || { printf 'Unrelated process reused a forged lifecycle handoff.\n' >&2; exit 1; }

LOCK_CONFIG_BEFORE="$(/usr/bin/shasum -a 256 "$LOCK_HOME/.codex/config.toml" "$LOCK_STATE/state.json")"
set +e
LOCK_STATUS_JSON="$(/usr/bin/env HOME="$LOCK_HOME" TZ=Asia/Shanghai \
  "$ROOT/scripts/status-dream-skin-macos.sh" --studio-json --operation apply)"
LOCK_STATUS_EXIT="$?"
set -e
[ "$LOCK_STATUS_EXIT" -eq 1 ] || { printf 'Busy status did not exit 1.\n' >&2; exit 1; }
"$NODE" -e '
  const value = JSON.parse(process.argv[1]);
  if (value.operation !== "apply" || value.ok || value.state?.operation !== "busy") process.exit(1);
  if (value.state.availableActions.length !== 0 || value.error?.code !== "OPERATION_BUSY") process.exit(1);
  if (value.error.recoveryActions.join(",") !== "retry,cancel") process.exit(1);
' "$LOCK_STATUS_JSON"
[ "$LOCK_CONFIG_BEFORE" = "$(/usr/bin/shasum -a 256 "$LOCK_HOME/.codex/config.toml" "$LOCK_STATE/state.json")" ] \
  || { printf 'Busy status changed config or lifecycle state.\n' >&2; exit 1; }

: > "$LOCK_RELEASE"
wait "$LIFECYCLE_OWNER_PID"
LIFECYCLE_OWNER_PID=""
[ ! -e "$LOCK_STATE/lifecycle.lock" ] || { printf 'Lifecycle owner did not release its lock.\n' >&2; exit 1; }

/bin/rm -f "$LOCK_READY" "$LOCK_RELEASE" "$LOCK_CHILD"
/usr/bin/env HOME="$LOCK_HOME" TZ=UTC "$LOCK_FIXTURE/owner.sh" \
  "$ROOT" "$LOCK_READY" "$LOCK_RELEASE" "$LOCK_CHILD" \
  "$LOCK_OWNER_PID_FILE" "$LOCK_OWNER_START_FILE" &
LIFECYCLE_OWNER_PID="$!"
deadline=$((SECONDS + 5))
while [ ! -e "$LOCK_READY" ] && /bin/kill -0 "$LIFECYCLE_OWNER_PID" 2>/dev/null \
  && [ "$SECONDS" -lt "$deadline" ]; do
  /bin/sleep 0.02
done
[ -e "$LOCK_READY" ] || { printf 'Stale-owner fixture did not acquire the lifecycle lock.\n' >&2; exit 1; }
/bin/kill -KILL "$LIFECYCLE_OWNER_PID"
set +e
wait "$LIFECYCLE_OWNER_PID" 2>/dev/null
set -e
LIFECYCLE_OWNER_PID=""
[ -e "$LOCK_STATE/lifecycle.lock" ] || { printf 'Killed owner did not leave a stale lifecycle lock.\n' >&2; exit 1; }
/usr/bin/env HOME="$LOCK_HOME" TZ=Asia/Shanghai /bin/bash -c '
  set -euo pipefail
  . "$1/scripts/common-macos.sh"
  require_lifecycle_lock
  [ "$LIFECYCLE_LOCK_OWNED" = "true" ]
  release_lifecycle_lock
' _ "$ROOT"
[ ! -e "$LOCK_STATE/lifecycle.lock" ] || { printf 'Stale lifecycle owner was not recovered.\n' >&2; exit 1; }

LOCK_GATE_READY="$LOCK_FIXTURE/gate-ready"
LOCK_GATE_RELEASE="$LOCK_FIXTURE/gate-release"
/bin/rm -f "$LOCK_READY" "$LOCK_RELEASE" "$LOCK_CHILD" "$LOCK_GATE_READY" "$LOCK_GATE_RELEASE"
/usr/bin/env HOME="$LOCK_HOME" TZ=UTC "$LOCK_FIXTURE/owner.sh" \
  "$ROOT" "$LOCK_READY" "$LOCK_RELEASE" "$LOCK_CHILD" \
  "$LOCK_OWNER_PID_FILE" "$LOCK_OWNER_START_FILE" &
LIFECYCLE_OWNER_PID="$!"
deadline=$((SECONDS + 5))
while [ ! -e "$LOCK_READY" ] && /bin/kill -0 "$LIFECYCLE_OWNER_PID" 2>/dev/null \
  && [ "$SECONDS" -lt "$deadline" ]; do /bin/sleep 0.02; done
[ -e "$LOCK_READY" ] || { printf 'Release-contention owner did not acquire the lifecycle lock.\n' >&2; exit 1; }
/usr/bin/lockf -s -t 0 -k "$LOCK_STATE/lifecycle.lock.gate" /bin/bash -c '
  : > "$1"
  while [ ! -e "$2" ]; do /bin/sleep 0.02; done
' _ "$LOCK_GATE_READY" "$LOCK_GATE_RELEASE" &
LOCK_GATE_HOLDER_PID="$!"
deadline=$((SECONDS + 5))
while [ ! -e "$LOCK_GATE_READY" ] && /bin/kill -0 "$LOCK_GATE_HOLDER_PID" 2>/dev/null \
  && [ "$SECONDS" -lt "$deadline" ]; do /bin/sleep 0.02; done
[ -e "$LOCK_GATE_READY" ] || { printf 'Release-contention fixture did not hold the transition gate.\n' >&2; exit 1; }
: > "$LOCK_RELEASE"
/bin/sleep 0.2
: > "$LOCK_GATE_RELEASE"
wait "$LOCK_GATE_HOLDER_PID"
LOCK_GATE_HOLDER_PID=""
wait "$LIFECYCLE_OWNER_PID"
LIFECYCLE_OWNER_PID=""
[ ! -e "$LOCK_STATE/lifecycle.lock" ] || {
  printf 'Lifecycle release silently skipped owner removal during gate contention.\n' >&2
  exit 1
}

LOCK_RACE="$LOCK_FIXTURE/publication-race"
LOCK_RACE_PAUSED="$LOCK_RACE/a-paused"
LOCK_RACE_CONTINUE="$LOCK_RACE/a-continue"
LOCK_RACE_A_RESULT="$LOCK_RACE/a-result"
LOCK_RACE_B_RESULT="$LOCK_RACE/b-result"
LOCK_RACE_A_FINISH="$LOCK_RACE/a-finish"
LOCK_RACE_B_FINISH="$LOCK_RACE/b-finish"
/bin/mkdir -p "$LOCK_RACE"
/usr/bin/sed > "$LOCK_RACE/owner.sh" <<'STUB'
#!/bin/bash
set -euo pipefail
role="$1"
root="$2"
paused="$3"
continue_path="$4"
result="$5"
finish="$6"
acquired="false"
. "$root/scripts/common-macos.sh"
lifecycle_lock_is_recent() { return 1; }
lifecycle_process_started_at() {
  if [ "$role" = "A" ] && [ ! -e "$paused" ]; then
    : > "$paused"
    while [ ! -e "$continue_path" ]; do /bin/sleep 0.02; done
  fi
  LC_ALL=C TZ=UTC /bin/ps -p "$1" -o lstart= 2>/dev/null | /usr/bin/awk '{$1=$1; print}'
}
trap '[ "$acquired" != "true" ] || release_lifecycle_lock' EXIT
trap 'exit 0' TERM
if acquire_lifecycle_lock; then
  acquired="true"
  printf 'success\n%s\n%s\n' "$LIFECYCLE_LOCK_OWNER_PID" \
    "$LIFECYCLE_LOCK_OWNER_STARTED_AT" > "$result"
else
  printf 'failure\n' > "$result"
fi
while [ ! -e "$finish" ]; do /bin/sleep 0.02; done
STUB
/bin/chmod 755 "$LOCK_RACE/owner.sh"

/usr/bin/env HOME="$LOCK_HOME" "$LOCK_RACE/owner.sh" A "$ROOT" \
  "$LOCK_RACE_PAUSED" "$LOCK_RACE_CONTINUE" "$LOCK_RACE_A_RESULT" \
  "$LOCK_RACE_A_FINISH" &
LOCK_RACE_A_PID="$!"
deadline=$((SECONDS + 5))
while [ ! -e "$LOCK_RACE_PAUSED" ] && /bin/kill -0 "$LOCK_RACE_A_PID" 2>/dev/null \
  && [ "$SECONDS" -lt "$deadline" ]; do /bin/sleep 0.02; done
[ -e "$LOCK_RACE_PAUSED" ] || { printf 'First lock creator did not pause before owner publication.\n' >&2; exit 1; }

/usr/bin/env HOME="$LOCK_HOME" "$LOCK_RACE/owner.sh" B "$ROOT" \
  "$LOCK_RACE_PAUSED" "$LOCK_RACE_CONTINUE" "$LOCK_RACE_B_RESULT" \
  "$LOCK_RACE_B_FINISH" &
LOCK_RACE_B_PID="$!"
deadline=$((SECONDS + 5))
while [ ! -e "$LOCK_RACE_B_RESULT" ] && /bin/kill -0 "$LOCK_RACE_B_PID" 2>/dev/null \
  && [ "$SECONDS" -lt "$deadline" ]; do /bin/sleep 0.02; done
[ -e "$LOCK_RACE_B_RESULT" ] || { printf 'Contending lock creator did not return.\n' >&2; exit 1; }

: > "$LOCK_RACE_CONTINUE"
deadline=$((SECONDS + 5))
while [ ! -e "$LOCK_RACE_A_RESULT" ] && /bin/kill -0 "$LOCK_RACE_A_PID" 2>/dev/null \
  && [ "$SECONDS" -lt "$deadline" ]; do /bin/sleep 0.02; done
[ -e "$LOCK_RACE_A_RESULT" ] || { printf 'Paused lock creator did not return.\n' >&2; exit 1; }
LOCK_RACE_A_STATUS="$(/usr/bin/sed -n '1p' "$LOCK_RACE_A_RESULT")"
LOCK_RACE_B_STATUS="$(/usr/bin/sed -n '1p' "$LOCK_RACE_B_RESULT")"
case "$LOCK_RACE_A_STATUS:$LOCK_RACE_B_STATUS" in
  success:failure) LOCK_RACE_WINNER_RESULT="$LOCK_RACE_A_RESULT" ;;
  failure:success) LOCK_RACE_WINNER_RESULT="$LOCK_RACE_B_RESULT" ;;
  *)
  printf 'Concurrent owner publication did not produce exactly one lock owner.\n' >&2
  exit 1
  ;;
esac
LOCK_RACE_OWNER_PID="$(/usr/bin/sed -n '2p' "$LOCK_RACE_WINNER_RESULT")"
LOCK_RACE_OWNER_START="$(/usr/bin/sed -n '3p' "$LOCK_RACE_WINNER_RESULT")"
/usr/bin/env HOME="$LOCK_HOME" /bin/bash -c '
  set -euo pipefail
  . "$1/scripts/common-macos.sh"
  read_lifecycle_lock_owner
  [ "$LIFECYCLE_RECORDED_OWNER_PID" = "$2" ]
  [ "$LIFECYCLE_RECORDED_OWNER_STARTED_AT" = "$3" ]
  lifecycle_lock_is_busy
' _ "$ROOT" "$LOCK_RACE_OWNER_PID" "$LOCK_RACE_OWNER_START" || {
  printf 'Winning owner was not preserved after concurrent publication.\n' >&2
  exit 1
}
: > "$LOCK_RACE_A_FINISH"
: > "$LOCK_RACE_B_FINISH"
wait "$LOCK_RACE_A_PID"
LOCK_RACE_A_PID=""
wait "$LOCK_RACE_B_PID"
LOCK_RACE_B_PID=""
/usr/bin/env HOME="$LOCK_HOME" /bin/bash -c '
  . "$1/scripts/common-macos.sh"
  ! lifecycle_lock_is_busy
' _ "$ROOT" || { printf 'Publication-race fixture did not release the lifecycle lock.\n' >&2; exit 1; }

ADAPTER_LOCK_FIXTURE="$TMP/adapter-lifecycle-lock"
ADAPTER_LOCK_HOME="$ADAPTER_LOCK_FIXTURE/home"
ADAPTER_LOCK_ROOT="$ADAPTER_LOCK_FIXTURE/engine"
ADAPTER_LOCK_STATE="$ADAPTER_LOCK_HOME/Library/Application Support/CodexDreamSkinStudio"
ADAPTER_LOCK_ENTERED="$ADAPTER_LOCK_FIXTURE/entered"
ADAPTER_LOCK_RELEASE="$ADAPTER_LOCK_FIXTURE/release"
ADAPTER_LOCK_CHILDREN="$ADAPTER_LOCK_FIXTURE/children"
/bin/mkdir -p "$ADAPTER_LOCK_ROOT/bin" "$ADAPTER_LOCK_ROOT/scripts" \
  "$ADAPTER_LOCK_HOME/.codex" "$ADAPTER_LOCK_STATE"
/bin/cp "$ROOT/VERSION" "$ADAPTER_LOCK_ROOT/VERSION"
/bin/cp "$ROOT/bin/dream-skin-config-restore" "$ADAPTER_LOCK_ROOT/bin/"
/bin/cp "$ROOT/scripts/studio-adapter-macos.sh" "$ROOT/scripts/common-macos.sh" \
  "$ADAPTER_LOCK_ROOT/scripts/"
/usr/bin/sed "s|__ENTERED__|$ADAPTER_LOCK_ENTERED|g; s|__RELEASE__|$ADAPTER_LOCK_RELEASE|g; s|__CHILDREN__|$ADAPTER_LOCK_CHILDREN|g" \
  > "$ADAPTER_LOCK_ROOT/scripts/install-dream-skin-macos.sh" <<'STUB'
#!/bin/bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd -P)/common-macos.sh"
require_lifecycle_lock
trap release_lifecycle_lock EXIT
[ "$LIFECYCLE_LOCK_BORROWED" = "true" ] || exit 90
printf 'child\n' >> "__CHILDREN__"
: > "__ENTERED__"
while [ ! -e "__RELEASE__" ]; do /bin/sleep 0.02; done
STUB
/usr/bin/sed > "$ADAPTER_LOCK_ROOT/scripts/status-dream-skin-macos.sh" <<'STUB'
#!/bin/bash
operation=status
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--operation" ]; then operation="$2"; shift 2; else shift; fi
done
. "$(cd "$(dirname "$0")" && pwd -P)/common-macos.sh"
if lifecycle_lock_is_busy; then
  printf '{"schemaVersion":1,"ok":false,"operation":"%s","state":{"install":"not-installed","codex":"not-installed","session":"official","operation":"busy","themeName":null,"requiresRestart":false,"availableActions":[],"verified":null},"error":{"code":"OPERATION_BUSY","message":"Another Studio operation is already running.","recoveryActions":["retry","cancel"]}}\n' "$operation"
  exit 1
fi
printf '{"schemaVersion":1,"ok":true,"operation":"%s","state":{"install":"not-installed","codex":"stopped","session":"official","operation":"idle","themeName":null,"requiresRestart":false,"availableActions":["install"],"verified":null},"error":null}\n' "$operation"
STUB
/bin/chmod 755 "$ADAPTER_LOCK_ROOT/bin/dream-skin-config-restore" \
  "$ADAPTER_LOCK_ROOT/scripts/"*.sh
/usr/bin/printf 'config sentinel\n' > "$ADAPTER_LOCK_HOME/.codex/config.toml"
/usr/bin/printf 'state sentinel\n' > "$ADAPTER_LOCK_STATE/state.json"

/usr/bin/env HOME="$ADAPTER_LOCK_HOME" \
  "$ADAPTER_LOCK_ROOT/scripts/studio-adapter-macos.sh" install \
  > "$ADAPTER_LOCK_FIXTURE/owner.json" 2> "$ADAPTER_LOCK_FIXTURE/owner.stderr" &
ADAPTER_LOCK_OWNER_PID="$!"
deadline=$((SECONDS + 5))
while [ ! -e "$ADAPTER_LOCK_ENTERED" ] && /bin/kill -0 "$ADAPTER_LOCK_OWNER_PID" 2>/dev/null \
  && [ "$SECONDS" -lt "$deadline" ]; do
  /bin/sleep 0.02
done
[ -e "$ADAPTER_LOCK_ENTERED" ] || {
  printf 'Adapter lifecycle child did not enter under the verified ownership handoff.\n' >&2
  exit 1
}

ADAPTER_PROTECTED_BEFORE="$(/usr/bin/shasum -a 256 \
  "$ADAPTER_LOCK_HOME/.codex/config.toml" "$ADAPTER_LOCK_STATE/state.json")"
set +e
/usr/bin/env HOME="$ADAPTER_LOCK_HOME" \
  "$ADAPTER_LOCK_ROOT/scripts/studio-adapter-macos.sh" install \
  > "$ADAPTER_LOCK_FIXTURE/contender.json" 2> "$ADAPTER_LOCK_FIXTURE/contender.stderr"
ADAPTER_CONTENDER_EXIT="$?"
set -e
[ "$ADAPTER_CONTENDER_EXIT" -eq 1 ] || { printf 'Contending adapter did not exit 1.\n' >&2; exit 1; }
"$NODE" -e '
  const lines = require("node:fs").readFileSync(process.argv[1], "utf8").trim().split("\n");
  if (lines.length !== 1) process.exit(1);
  const value = JSON.parse(lines[0]);
  if (value.operation !== "install" || value.ok || value.state.operation !== "busy") process.exit(1);
  if (value.state.availableActions.length !== 0 || value.error?.code !== "OPERATION_BUSY") process.exit(1);
' "$ADAPTER_LOCK_FIXTURE/contender.json"
[ "$ADAPTER_PROTECTED_BEFORE" = "$(/usr/bin/shasum -a 256 \
  "$ADAPTER_LOCK_HOME/.codex/config.toml" "$ADAPTER_LOCK_STATE/state.json")" ] \
  || { printf 'Contending adapter changed config or lifecycle state.\n' >&2; exit 1; }
[ "$(/usr/bin/wc -l < "$ADAPTER_LOCK_CHILDREN" | /usr/bin/tr -d ' ')" = "1" ] \
  || { printf 'Contending adapter invoked a lifecycle child.\n' >&2; exit 1; }

: > "$ADAPTER_LOCK_RELEASE"
wait "$ADAPTER_LOCK_OWNER_PID"
ADAPTER_LOCK_OWNER_PID=""
"$NODE" -e '
  const value = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  if (!value.ok || value.operation !== "install") process.exit(1);
' "$ADAPTER_LOCK_FIXTURE/owner.json"
[ ! -e "$ADAPTER_LOCK_STATE/lifecycle.lock" ] || { printf 'Adapter did not release its lifecycle lock.\n' >&2; exit 1; }

ADAPTER_LOCK_FAILURE_HOME="$ADAPTER_LOCK_FIXTURE/failure-home"
ADAPTER_LOCK_FAILURE_STATE="$ADAPTER_LOCK_FAILURE_HOME/Library/Application Support/CodexDreamSkinStudio"
/bin/mkdir -p "$ADAPTER_LOCK_FAILURE_HOME/Library/Application Support"
/usr/bin/printf 'state-root sentinel\n' > "$ADAPTER_LOCK_FAILURE_STATE"
/bin/chmod 600 "$ADAPTER_LOCK_FAILURE_STATE"
ADAPTER_LOCK_FAILURE_BEFORE="$(/usr/bin/shasum -a 256 "$ADAPTER_LOCK_FAILURE_STATE"):$((8#$(/usr/bin/stat -f '%Lp' "$ADAPTER_LOCK_FAILURE_STATE")))"
set +e
/usr/bin/env HOME="$ADAPTER_LOCK_FAILURE_HOME" \
  "$ADAPTER_LOCK_ROOT/scripts/studio-adapter-macos.sh" install \
  > "$ADAPTER_LOCK_FIXTURE/failure.json" 2> "$ADAPTER_LOCK_FIXTURE/failure.stderr"
ADAPTER_LOCK_FAILURE_EXIT="$?"
set -e
[ "$ADAPTER_LOCK_FAILURE_EXIT" -eq 1 ] || {
  printf 'Non-contention lock acquisition failure did not exit 1.\n' >&2
  exit 1
}
"$NODE" -e '
  const lines = require("node:fs").readFileSync(process.argv[1], "utf8").trim().split("\n");
  if (lines.length !== 1) process.exit(1);
  const value = JSON.parse(lines[0]);
  if (value.operation !== "install" || value.ok || value.state.operation !== "idle") process.exit(1);
  if (value.state.availableActions.length !== 0 || value.error?.code !== "INTERNAL_ERROR") process.exit(1);
' "$ADAPTER_LOCK_FIXTURE/failure.json"
[ "$ADAPTER_LOCK_FAILURE_BEFORE" = "$(/usr/bin/shasum -a 256 "$ADAPTER_LOCK_FAILURE_STATE"):$((8#$(/usr/bin/stat -f '%Lp' "$ADAPTER_LOCK_FAILURE_STATE")))" ] \
  || { printf 'Failed lock acquisition changed the state-root sentinel.\n' >&2; exit 1; }

snapshot() {
  /usr/bin/find "$TEST_HOME" -print0 | /usr/bin/sort -z | while IFS= read -r -d '' path; do
    if [ -f "$path" ]; then
      printf 'file %s ' "$path"
      /usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{print $1}'
    elif [ -d "$path" ]; then
      printf 'dir %s\n' "$path"
    else
      printf 'other %s\n' "$path"
    fi
  done
}

run_adapter() {
  local operation="$1"
  shift
  set +e
  ADAPTER_JSON="$(/usr/bin/env HOME="$TEST_HOME" "$ROOT/scripts/studio-adapter-macos.sh" "$operation" "$@")"
  ADAPTER_EXIT="$?"
  set -e
}

assert_json_line() {
  "$NODE" -e '
    const lines = process.argv[1].split("\n").filter(Boolean);
    if (lines.length !== 1) throw new Error(`expected one stdout line, got ${lines.length}`);
    JSON.parse(lines[0]);
  ' "$1"
}

assert_error() {
  local code="$1"
  [ "$ADAPTER_EXIT" -eq "${2:-1}" ] || { printf '%s exited %s.\n' "$code" "$ADAPTER_EXIT" >&2; exit 1; }
  assert_json_line "$ADAPTER_JSON"
  "$NODE" -e 'if (JSON.parse(process.argv[1]).error?.code !== process.argv[2]) process.exit(1)' "$ADAPTER_JSON" "$code"
}

assert_operation() {
  "$NODE" -e 'if (JSON.parse(process.argv[1]).operation !== process.argv[2]) process.exit(1)' \
    "$ADAPTER_JSON" "$1"
}

assert_recovery() {
  "$NODE" -e '
    const actions = JSON.parse(process.argv[1]).error?.recoveryActions || [];
    if (!actions.includes(process.argv[2]) || (process.argv[3] && actions.includes(process.argv[3]))) process.exit(1);
  ' "$ADAPTER_JSON" "$1" "${2:-}"
}

assert_requires_restart() {
  "$NODE" -e '
    const value = JSON.parse(process.argv[1]);
    if (value.state?.requiresRestart !== true) process.exit(1);
  ' "$ADAPTER_JSON"
}

VALID_NATIVE_HELPER="$TMP/valid-dream-skin-config-restore"
/bin/cp "$ROOT/bin/dream-skin-config-restore" "$VALID_NATIVE_HELPER"
for invalid_helper in missing symlink directory; do
  /bin/rm -rf "$ROOT/bin/dream-skin-config-restore"
  case "$invalid_helper" in
    missing) ;;
    symlink) /bin/ln -s "$VALID_NATIVE_HELPER" "$ROOT/bin/dream-skin-config-restore" ;;
    directory) /bin/mkdir "$ROOT/bin/dream-skin-config-restore" ;;
  esac
  for guarded_operation in preflight install; do
    BEFORE="$(snapshot)"
    run_adapter "$guarded_operation"
    assert_error RUNTIME_INVALID
    [ "$BEFORE" = "$(snapshot)" ] || {
      printf '%s with a %s native helper changed HOME.\n' "$guarded_operation" "$invalid_helper" >&2
      exit 1
    }
  done
done
/bin/rm -rf "$ROOT/bin/dream-skin-config-restore"
/bin/cp "$VALID_NATIVE_HELPER" "$ROOT/bin/dream-skin-config-restore"
/bin/chmod 755 "$ROOT/bin/dream-skin-config-restore"

INSTALLED_LAYOUT="$TMP/installed-layout"
/bin/mkdir -p "$INSTALLED_LAYOUT"
/usr/bin/rsync -a "$ROOT/" "$INSTALLED_LAYOUT/"
[ -f "$INSTALLED_LAYOUT/bin/dream-skin-config-restore" ]
[ ! -L "$INSTALLED_LAYOUT/bin/dream-skin-config-restore" ]
[ -x "$INSTALLED_LAYOUT/bin/dream-skin-config-restore" ]
/usr/bin/cmp -s "$ROOT/bin/dream-skin-config-restore" "$INSTALLED_LAYOUT/bin/dream-skin-config-restore"

BEFORE="$(snapshot)"
run_adapter preflight
[ "$ADAPTER_EXIT" -eq 1 ] || {
  printf 'missing-Codex preflight did not exit 1.\n' >&2
  exit 1
}
[ "$BEFORE" = "$(snapshot)" ] || {
  printf 'preflight changed HOME.\n' >&2
  exit 1
}
"$NODE" -e '
  const value = JSON.parse(process.argv[1]);
  if (value.schemaVersion !== 1 || value.operation !== "preflight") process.exit(1);
  if (value.ok || !["CODEX_NOT_INSTALLED", "CODEX_FIRST_RUN_REQUIRED"].includes(value.error?.code)) process.exit(1);
  if (!value.state || !Array.isArray(value.state.availableActions)) process.exit(1);
' "$ADAPTER_JSON"

BEFORE="$(snapshot)"
run_adapter status
[ "$ADAPTER_EXIT" -eq 1 ] || {
  printf 'missing-Codex status did not exit 1.\n' >&2
  exit 1
}
[ "$BEFORE" = "$(snapshot)" ] || {
  printf 'status changed HOME.\n' >&2
  exit 1
}
"$NODE" -e '
  const value = JSON.parse(process.argv[1]);
  if (value.schemaVersion !== 1 || value.operation !== "status") process.exit(1);
  if (value.ok || !["CODEX_NOT_INSTALLED", "CODEX_FIRST_RUN_REQUIRED"].includes(value.error?.code)) process.exit(1);
  if (!value.state || !Array.isArray(value.state.availableActions)) process.exit(1);
  if (/(port|pid|cdp|powershell|\/Users\/)/i.test(JSON.stringify(value))) process.exit(1);
' "$ADAPTER_JSON"

PORT=19431
"$NODE" -e '
  const http = require("node:http");
  http.createServer((_, response) => response.end("{}"))
    .listen(Number(process.argv[1]), "127.0.0.1");
' "$PORT" &
RESPONDER_PID="$!"
/bin/sleep 0.1

LEGACY_HOME="$TMP/legacy-home"
LEGACY_STATE="$LEGACY_HOME/Library/Application Support/CodexDreamSkinStudio"
/bin/mkdir -p "$LEGACY_STATE"
/usr/bin/printf '{"port":%s}\n' "$PORT" > "$LEGACY_STATE/state.json"
LEGACY_JSON="$(/usr/bin/env HOME="$LEGACY_HOME" "$ROOT/scripts/status-dream-skin-macos.sh" --json --deep)"
LEGACY_TEXT="$(/usr/bin/env HOME="$LEGACY_HOME" "$ROOT/scripts/status-dream-skin-macos.sh" --deep)"
"$NODE" -e 'if (JSON.parse(process.argv[1]).cdpOk !== false) process.exit(1)' "$LEGACY_JSON"
printf '%s\n' "$LEGACY_TEXT" | /usr/bin/grep -Fx 'cdp=false' >/dev/null

TEST_HOME="$TMP/success-home"
INSTALL_ROOT="$TEST_HOME/.codex/codex-dream-skin-studio"
STATE_ROOT="$TEST_HOME/Library/Application Support/CodexDreamSkinStudio"
/bin/mkdir -p "$INSTALL_ROOT/bin" "$INSTALL_ROOT/scripts" "$STATE_ROOT/theme"
/bin/cp "$ROOT/VERSION" "$INSTALL_ROOT/VERSION"
/bin/cp "$ROOT/bin/dream-skin-config-restore" "$INSTALL_ROOT/bin/"
for script in studio-adapter-macos.sh start-dream-skin-macos.sh pause-dream-skin-macos.sh \
  restore-dream-skin-macos.sh verify-dream-skin-macos.sh; do
  : > "$INSTALL_ROOT/scripts/$script"
  /bin/chmod 755 "$INSTALL_ROOT/scripts/$script"
done
for script in common-macos.sh injector.mjs theme-config.mjs; do
  : > "$INSTALL_ROOT/scripts/$script"
done
: > "$TEST_HOME/.codex/config.toml"
/usr/bin/printf '%s\n' '{"name":"Fixture"}' > "$STATE_ROOT/theme/theme.json"
/usr/bin/printf '{"port":%s,"session":"paused","injectorPid":0}\n' "$PORT" > "$STATE_ROOT/state.json"
"$NODE" "$ROOT/scripts/theme-config.mjs" install \
  "$TEST_HOME/.codex/config.toml" "$STATE_ROOT/theme-backup.json" >/dev/null
VALID_THEME_BACKUP="$TMP/valid-theme-backup.json"
/bin/cp "$STATE_ROOT/theme-backup.json" "$VALID_THEME_BACKUP"
run_adapter status
[ "$ADAPTER_EXIT" -eq 0 ] || {
  printf 'ready Studio status did not succeed.\n' >&2
  exit 1
}
"$NODE" -e '
  const value = JSON.parse(process.argv[1]);
  if (!value.ok || value.state.install !== "ready" || value.state.verified !== null) process.exit(1);
' "$ADAPTER_JSON"

/usr/bin/printf '{}\n' > "$STATE_ROOT/theme-backup.json"
run_adapter status
"$NODE" -e '
  const value = JSON.parse(process.argv[1]);
  const forbidden = new Set(["apply", "resume", "restore", "uninstall"]);
  if (value.state.install === "ready") process.exit(1);
  if (value.state.availableActions.some((action) => forbidden.has(action))) process.exit(1);
' "$ADAPTER_JSON" || { printf 'malformed live backup enabled lifecycle actions.\n' >&2; exit 1; }
/bin/cp "$VALID_THEME_BACKUP" "$STATE_ROOT/theme-backup.json"

/usr/bin/printf '{"port":%s,"session":"active","injectorPid":0}\n' "$PORT" > "$STATE_ROOT/state.json"
run_adapter status
[ "$ADAPTER_EXIT" -eq 1 ] || { printf 'incomplete active status did not fail safely.\n' >&2; exit 1; }
"$NODE" -e '
  const value = JSON.parse(process.argv[1]);
  if (value.state.session !== "stale" || value.error?.code !== "STATE_UNSAFE") process.exit(1);
  if (value.state.availableActions.join(",") !== "restore,uninstall") process.exit(1);
' "$ADAPTER_JSON"

/usr/bin/printf '{}\n' > "$STATE_ROOT/state.json"
run_adapter status
[ "$ADAPTER_EXIT" -eq 1 ] || { printf 'damaged state did not fail safely.\n' >&2; exit 1; }
"$NODE" -e '
  const value = JSON.parse(process.argv[1]);
  if (value.state.session !== "stale" || value.error?.code !== "STATE_UNSAFE") process.exit(1);
  if (value.state.availableActions.join(",") !== "restore,uninstall") process.exit(1);
' "$ADAPTER_JSON"
/usr/bin/printf '{"port":%s,"session":"paused","injectorPid":0}\n' "$PORT" > "$STATE_ROOT/state.json"

/usr/bin/printf '{malformed\n' > "$STATE_ROOT/rollback.json"
run_adapter status
[ "$ADAPTER_EXIT" -eq 1 ] || { printf 'Malformed rollback evidence did not fail status.\n' >&2; exit 1; }
"$NODE" -e '
  const value = JSON.parse(process.argv[1]);
  if (value.state.availableActions.length !== 0 || value.error?.code !== "STATE_UNSAFE" ||
      value.error.recoveryActions.includes("restore")) process.exit(1);
' "$ADAPTER_JSON" || { printf 'Malformed rollback evidence advertised an unusable lifecycle action.\n' >&2; exit 1; }
/bin/rm -f "$STATE_ROOT/studio-operation.log"
run_adapter restore
[ "$ADAPTER_EXIT" -eq 1 ] || { printf 'Adapter Restore accepted malformed rollback evidence.\n' >&2; exit 1; }
[ ! -e "$STATE_ROOT/studio-operation.log" ] || {
  printf 'Adapter dispatched Restore despite malformed rollback evidence.\n' >&2
  exit 1
}
/bin/rm -f "$STATE_ROOT/rollback.json"

/usr/bin/printf '%s\n' '{"name":"测试主题"}' > "$STATE_ROOT/theme/theme.json"
run_adapter status
"$NODE" -e 'if (JSON.parse(process.argv[1]).state.themeName !== "测试主题") process.exit(1)' "$ADAPTER_JSON"
/usr/bin/printf '%s\n' '{"id":"id-only-theme","image":"theme.jpg"}' > "$STATE_ROOT/theme/theme.json"
run_adapter status
[ "$ADAPTER_EXIT" -eq 0 ] || { printf 'id-only theme status did not return an envelope.\n' >&2; exit 1; }
assert_json_line "$ADAPTER_JSON"
"$NODE" -e 'if (JSON.parse(process.argv[1]).state.themeName !== "id-only-theme") process.exit(1)' "$ADAPTER_JSON"
/usr/bin/printf '{malformed\n' > "$STATE_ROOT/theme/theme.json"
run_adapter status
[ "$ADAPTER_EXIT" -eq 0 ] || { printf 'malformed theme status did not return an envelope.\n' >&2; exit 1; }
assert_json_line "$ADAPTER_JSON"
"$NODE" -e 'if (JSON.parse(process.argv[1]).state.themeName !== null) process.exit(1)' "$ADAPTER_JSON"
for unsafe_theme_name in '/Users/alice/private/theme' 'C:\\Users\\Alice\\private\\theme' 'line\u000asecret'; do
  /usr/bin/printf '{"name":"%s"}\n' "$unsafe_theme_name" > "$STATE_ROOT/theme/theme.json"
  run_adapter status
  assert_json_line "$ADAPTER_JSON"
  "$NODE" -e '
    const value = JSON.parse(process.argv[1]);
    if (value.state.themeName !== null || JSON.stringify(value).includes("alice/private")) process.exit(1);
  ' "$ADAPTER_JSON"
done
/usr/bin/printf '%s\n' '{"name":"Fixture"}' > "$STATE_ROOT/theme/theme.json"

/bin/rm -f "$STATE_ROOT/state.json" "$STATE_ROOT/theme-backup.json" \
  "$STATE_ROOT/theme-backup.restored.json"
run_adapter status
[ "$ADAPTER_EXIT" -eq 1 ] || { printf 'missing restore proof did not fail closed.\n' >&2; exit 1; }
"$NODE" -e '
  const value = JSON.parse(process.argv[1]);
  if (value.state.session !== "stale" || value.error?.code !== "STATE_UNSAFE") process.exit(1);
  if (value.state.availableActions.includes("uninstall")) process.exit(1);
' "$ADAPTER_JSON"

/usr/bin/printf 'not valid completion proof\n' > "$STATE_ROOT/theme-backup.restored.json"
run_adapter status
[ "$ADAPTER_EXIT" -eq 1 ] || { printf 'invalid restore proof did not fail closed.\n' >&2; exit 1; }

"$NODE" -e '
  const fs = require("node:fs");
  fs.writeFileSync(process.argv[1], `${JSON.stringify({
    schemaVersion: 1,
    platform: "darwin",
    configPath: process.argv[2],
    values: {
      appearanceTheme: "garbage",
      appearanceDarkCodeThemeId: null,
    },
  })}\n`);
' "$STATE_ROOT/theme-backup.restored.json" "$TEST_HOME/.codex/config.toml"
run_adapter status
[ "$ADAPTER_EXIT" -eq 1 ] || { printf 'malformed restore assignment was accepted as completion proof.\n' >&2; exit 1; }
"$NODE" -e '
  const value = JSON.parse(process.argv[1]);
  if (value.state.session !== "stale" || value.error?.code !== "STATE_UNSAFE") process.exit(1);
  if (value.state.availableActions.includes("uninstall")) process.exit(1);
' "$ADAPTER_JSON"

/bin/cp "$VALID_THEME_BACKUP" "$STATE_ROOT/theme-backup.restored.json"
run_adapter status
[ "$ADAPTER_EXIT" -eq 0 ] || { printf 'valid restored installed-engine status failed.\n' >&2; exit 1; }
"$NODE" -e '
  const value = JSON.parse(process.argv[1]);
  if (value.state.install !== "not-installed") process.exit(1);
  if (value.state.availableActions.join(",") !== "install,restore,uninstall") process.exit(1);
' "$ADAPTER_JSON"
/bin/rm -f "$INSTALL_ROOT/scripts/verify-dream-skin-macos.sh"
run_adapter status
[ "$ADAPTER_EXIT" -eq 0 ] || { printf 'restored partial-engine status failed.\n' >&2; exit 1; }
"$NODE" -e '
  const value = JSON.parse(process.argv[1]);
  if (value.state.availableActions.join(",") !== "install,restore,uninstall") process.exit(1);
' "$ADAPTER_JSON"

/bin/rm -f "$STATE_ROOT/theme-backup.restored.json"
/bin/cp "$VALID_THEME_BACKUP" "$STATE_ROOT/theme-backup.json"
/usr/bin/printf '{"port":%s,"session":"paused","injectorPid":0}\n' "$PORT" > "$STATE_ROOT/state.json"
run_adapter status
[ "$ADAPTER_EXIT" -eq 0 ] || { printf 'paused partial-engine status failed.\n' >&2; exit 1; }
"$NODE" -e '
  const value = JSON.parse(process.argv[1]);
  if (value.state.install !== "not-installed" || value.state.session !== "paused") process.exit(1);
  if (value.state.availableActions.join(",") !== "restore,uninstall") process.exit(1);
' "$ADAPTER_JSON" || { printf 'paused partial engine did not expose recovery actions.\n' >&2; exit 1; }

/bin/rm -f "$STATE_ROOT/state.json"
run_adapter status
[ "$ADAPTER_EXIT" -eq 0 ] || { printf 'official partial-engine status failed.\n' >&2; exit 1; }
"$NODE" -e '
  const value = JSON.parse(process.argv[1]);
  if (value.state.install !== "not-installed" || value.state.session !== "official") process.exit(1);
  if (value.state.availableActions.join(",") !== "restore,uninstall") process.exit(1);
' "$ADAPTER_JSON" || { printf 'official partial engine did not expose recovery actions.\n' >&2; exit 1; }
/bin/rm -f "$STATE_ROOT/theme-backup.json"
: > "$INSTALL_ROOT/scripts/verify-dream-skin-macos.sh"
/bin/chmod 755 "$INSTALL_ROOT/scripts/verify-dream-skin-macos.sh"

# A fresh install generation must invalidate an older completed-restore proof
# only after its new live backup has been established successfully.
PROOF_FIXTURE="$TMP/reinstall-proof"
PROOF_HOME="$PROOF_FIXTURE/home"
PROOF_ROOT="$PROOF_FIXTURE/engine"
PROOF_STATE="$PROOF_HOME/Library/Application Support/CodexDreamSkinStudio"
PROOF_CONFIG="$PROOF_HOME/.codex/config.toml"
/bin/mkdir -p "$PROOF_ROOT/scripts" "$PROOF_ROOT/bin" "$PROOF_STATE/theme" "$PROOF_HOME/.codex"
/bin/cp "$ROOT/VERSION" "$PROOF_ROOT/VERSION"
/bin/cp "$ROOT/scripts/install-dream-skin-macos.sh" "$ROOT/scripts/theme-config.mjs" \
  "$PROOF_ROOT/scripts/"
/usr/bin/sed "s|__ROOT__|$PROOF_ROOT|g; s|__HOME__|$PROOF_HOME|g; s|__NODE__|$NODE|g" \
  > "$PROOF_ROOT/scripts/common-macos.sh" <<'STUB'
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="__ROOT__/scripts"
PROJECT_ROOT="__ROOT__"
INSTALL_ROOT="__HOME__/.codex/codex-dream-skin-studio"
STATE_ROOT="__HOME__/Library/Application Support/CodexDreamSkinStudio"
STATE_PATH="$STATE_ROOT/state.json"
THEME_BACKUP_PATH="$STATE_ROOT/theme-backup.json"
RESTORED_THEME_BACKUP_PATH="$STATE_ROOT/theme-backup.restored.json"
THEME_DIR="$STATE_ROOT/theme"
CONFIG_PATH="__HOME__/.codex/config.toml"
INJECTOR="$SCRIPT_DIR/injector.mjs"
NODE="__NODE__"
SKIN_VERSION=1.3.0
CODEX_VERSION=fixture
NODE_VERSION=v24.0.0
fail() { printf 'fixture: %s\n' "$*" >&2; exit 1; }
require_lifecycle_lock() { return 0; }
release_lifecycle_lock() { return 0; }
discover_codex_app() { return 0; }
require_macos_runtime() { return 0; }
codex_is_running() { return 1; }
ensure_state_root() { /bin/mkdir -p "$STATE_ROOT"; }
seed_bundled_presets() { return 0; }
STUB
: > "$PROOF_ROOT/scripts/injector.mjs"
/bin/chmod 755 "$PROOF_ROOT/scripts/install-dream-skin-macos.sh"
/usr/bin/printf '[desktop]\nappearanceTheme = "dark"\n' > "$PROOF_CONFIG"
/usr/bin/printf '{"schemaVersion":1,"image":"theme.jpg"}\n' > "$PROOF_STATE/theme/theme.json"
"$NODE" -e '
  const fs = require("node:fs");
  fs.writeFileSync(process.argv[1], `${JSON.stringify({
    schemaVersion: 1,
    platform: "darwin",
    configPath: process.argv[2],
    values: { appearanceTheme: null, appearanceDarkCodeThemeId: null },
  })}\n`);
' "$PROOF_STATE/theme-backup.restored.json" "$PROOF_CONFIG"
/usr/bin/env HOME="$PROOF_HOME" "$PROOF_ROOT/scripts/install-dream-skin-macos.sh" \
  --in-place --no-launchers --no-launch >/dev/null
[ -f "$PROOF_STATE/theme-backup.json" ] && [ ! -L "$PROOF_STATE/theme-backup.json" ] \
  || { printf 'fresh install did not establish its live recovery backup.\n' >&2; exit 1; }
[ ! -e "$PROOF_STATE/theme-backup.restored.json" ] && [ ! -L "$PROOF_STATE/theme-backup.restored.json" ] \
  || { printf 'fresh install retained an obsolete completed-restore proof.\n' >&2; exit 1; }

/usr/bin/printf 'backup sentinel\n' > "$STATE_ROOT/theme-backup.json"
/usr/bin/printf '{"port":%s,"session":"paused","injectorPid":0}\n' "$PORT" > "$STATE_ROOT/state.json"

invalid_index=0
for invalid_operation in nope 'bad"quote' $'bad\nline' $'bad\xff'; do
  INVALID_JSON="$TMP/invalid-$invalid_index.json"
  set +e
  /usr/bin/env HOME="$TEST_HOME" "$ROOT/scripts/studio-adapter-macos.sh" "$invalid_operation" >"$INVALID_JSON"
  invalid_exit="$?"
  set -e
  [ "$invalid_exit" -eq 2 ] || { printf 'unknown operation did not exit 2.\n' >&2; exit 1; }
  "$NODE" -e '
    const bytes = require("node:fs").readFileSync(process.argv[1]);
    const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    const lines = text.split("\n").filter(Boolean);
    if (lines.length !== 1) process.exit(1);
    const value = JSON.parse(lines[0]);
    if (value.operation !== "status" || value.error?.code !== "INVALID_REQUEST") process.exit(1);
  ' "$INVALID_JSON"
  invalid_index=$((invalid_index + 1))
done

FIXTURE="$TMP/lifecycle"
FIXTURE_HOME="$FIXTURE/home"
BUNDLED="$FIXTURE/bundled"
INSTALLED="$FIXTURE_HOME/.codex/codex-dream-skin-studio"
MARKER="$FIXTURE/marker"
STATUS_FIXTURE="$FIXTURE/status.json"
/bin/mkdir -p "$FIXTURE_HOME" "$BUNDLED/bin" "$BUNDLED/scripts" "$INSTALLED/bin" "$INSTALLED/scripts"
/bin/cp "$ROOT/scripts/studio-adapter-macos.sh" "$BUNDLED/scripts/"
/bin/cp "$ROOT/VERSION" "$BUNDLED/VERSION"
/bin/cp "$ROOT/VERSION" "$INSTALLED/VERSION"
/bin/cp "$ROOT/bin/dream-skin-config-restore" "$BUNDLED/bin/"
/bin/cp "$ROOT/bin/dream-skin-config-restore" "$INSTALLED/bin/"

write_status() {
  /usr/bin/printf '{"schemaVersion":1,"ok":true,"operation":"status","state":{"install":"%s","codex":"%s","session":"%s","operation":"idle","themeName":"Fixture","requiresRestart":%s,"availableActions":["apply","pause","resume","restore","verify","uninstall"],"verified":%s},"error":null}\n' \
    "$1" "$2" "$3" "$4" "$5" > "$STATUS_FIXTURE"
}

make_stub() {
  local path="$1"
  /usr/bin/sed "s|__MARKER__|$MARKER|g; s|__STATUS__|$STATUS_FIXTURE|g" > "$path" <<'STUB'
#!/bin/bash
set -euo pipefail
name="$(/usr/bin/basename "$0")"
if [ "$name" = "status-dream-skin-macos.sh" ]; then
  /bin/cat "__STATUS__"
else
  /usr/bin/printf '%s %s\n' "$name" "$*" >> "__MARKER__"
  if [ "$name" = "start-dream-skin-macos.sh" ]; then
    /usr/bin/sed \
      -e 's/"session":"official"/"session":"active"/' \
      -e 's/"session":"paused"/"session":"active"/' \
      -e 's/"requiresRestart":true/"requiresRestart":false/' \
      -e 's/"verified":null/"verified":true/' \
      -e 's/"verified":false/"verified":true/' \
      "__STATUS__" > "__STATUS__.next"
    /bin/mv "__STATUS__.next" "__STATUS__"
  fi
fi
STUB
  /bin/chmod 755 "$path"
}

make_failure_stub() {
  local path="$1"
  local message="$2"
  /usr/bin/sed "s|__MESSAGE__|$message|g" > "$path" <<'STUB'
#!/bin/bash
printf '%s\n' '__MESSAGE__' >&2
exit 1
STUB
  /bin/chmod 755 "$path"
}

for root in "$BUNDLED" "$INSTALLED"; do
  for script in install-dream-skin-macos.sh start-dream-skin-macos.sh pause-dream-skin-macos.sh restore-dream-skin-macos.sh verify-dream-skin-macos.sh status-dream-skin-macos.sh theme-config.mjs injector.mjs; do
    make_stub "$root/scripts/$script"
  done
  /bin/cp "$ROOT/scripts/common-macos.sh" "$root/scripts/common-macos.sh"
done

run_fixture_adapter() {
  TEST_HOME="$FIXTURE_HOME"
  ADAPTER_STDERR_FILE="$FIXTURE/adapter.stderr"
  set +e
  ADAPTER_JSON="$(/usr/bin/env HOME="$TEST_HOME" "$BUNDLED/scripts/studio-adapter-macos.sh" "$@" 2>"$ADAPTER_STDERR_FILE")"
  ADAPTER_EXIT="$?"
  set -e
}

write_status ready running official true null
: > "$MARKER"
run_fixture_adapter apply
assert_error RESTART_REQUIRED
[ ! -s "$MARKER" ] || { printf 'unauthorized apply invoked a script.\n' >&2; exit 1; }

: > "$MARKER"
run_fixture_adapter apply --restart-authorized
[ "$ADAPTER_EXIT" -eq 0 ] || { printf 'authorized apply failed.\n' >&2; exit 1; }
assert_json_line "$ADAPTER_JSON"
/usr/bin/grep -Fx 'start-dream-skin-macos.sh --studio-strict-verify --restart-existing' "$MARKER" >/dev/null
! /usr/bin/grep -q -- '--force-stop-authorized' "$MARKER"

: > "$MARKER"
write_status ready running official true null
run_fixture_adapter apply --restart-authorized --force-authorized
[ "$ADAPTER_EXIT" -eq 0 ] || { printf 'force-authorized apply failed.\n' >&2; exit 1; }
/usr/bin/grep -Fx 'start-dream-skin-macos.sh --studio-strict-verify --restart-existing --force-stop-authorized' "$MARKER" >/dev/null

: > "$MARKER"
run_fixture_adapter apply --force-authorized
assert_error INVALID_REQUEST 2
assert_operation apply
[ ! -s "$MARKER" ] || { printf 'invalid force authorization invoked a script.\n' >&2; exit 1; }

: > "$MARKER"
run_fixture_adapter pause --delete-user-themes
assert_error INVALID_REQUEST 2
assert_operation pause
[ ! -s "$MARKER" ] || { printf 'invalid theme deletion invoked a script.\n' >&2; exit 1; }

: > "$MARKER"
run_fixture_adapter verify --unknown-flag
assert_error INVALID_REQUEST 2
assert_operation verify
[ ! -s "$MARKER" ] || { printf 'invalid verify flag invoked a script.\n' >&2; exit 1; }

# Authorization flags are accepted request metadata, but pause and verify
# must never receive force-stop authority they cannot use.
write_status ready running active false true
: > "$MARKER"
run_fixture_adapter pause --restart-authorized --force-authorized
[ "$ADAPTER_EXIT" -eq 0 ] || { printf 'authorized pause failed.\n' >&2; exit 1; }
/usr/bin/grep -Fx 'pause-dream-skin-macos.sh ' "$MARKER" >/dev/null
! /usr/bin/grep -q -- '--force-stop-authorized' "$MARKER"
/usr/bin/grep -Fx 'DREAM_SKIN_PROGRESS=pausing' "$ADAPTER_STDERR_FILE" >/dev/null
! /usr/bin/grep -Fq 'DREAM_SKIN_PROGRESS ' "$ADAPTER_STDERR_FILE"

make_failure_stub "$INSTALLED/scripts/pause-dream-skin-macos.sh" \
  'Could not remove the live skin from Codex; pause state was not written.'
run_fixture_adapter pause
assert_error LIVE_REMOVE_FAILED
assert_recovery restore retry
make_stub "$INSTALLED/scripts/pause-dream-skin-macos.sh"

: > "$MARKER"
run_fixture_adapter verify --restart-authorized --force-authorized
[ "$ADAPTER_EXIT" -eq 0 ] || { printf 'authorized verify failed.\n' >&2; exit 1; }
/usr/bin/grep -Fx 'verify-dream-skin-macos.sh --reload' "$MARKER" >/dev/null
! /usr/bin/grep -q -- '--force-stop-authorized' "$MARKER"

# A process appearing after the read-only status snapshot must map the exact
# lifecycle message to normal authorization before force is ever offered.
write_status ready stopped official false null
make_failure_stub "$BUNDLED/scripts/install-dream-skin-macos.sh" \
  'Close Codex before installation so config.toml cannot be rewritten while the app is saving it.'
run_fixture_adapter install
assert_error CODEX_CLOSE_REQUIRED
assert_recovery authorize-restart authorize-force-stop
assert_requires_restart
make_stub "$BUNDLED/scripts/install-dream-skin-macos.sh"

make_failure_stub "$INSTALLED/scripts/start-dream-skin-macos.sh" \
  'Codex is already running without the verified skin CDP endpoint. Close it first or pass --restart-existing.'
run_fixture_adapter apply
assert_error RESTART_REQUIRED
assert_recovery authorize-restart authorize-force-stop
assert_requires_restart
make_stub "$INSTALLED/scripts/start-dream-skin-macos.sh"

make_failure_stub "$BUNDLED/scripts/restore-dream-skin-macos.sh" \
  'Explicit restart authorization is required before Studio can close Codex.'
run_fixture_adapter restore
assert_error RESTART_REQUIRED
assert_recovery authorize-restart authorize-force-stop
assert_requires_restart

make_failure_stub "$BUNDLED/scripts/restore-dream-skin-macos.sh" \
  'Codex did not close within 15 seconds; explicit restart authorization is required for a forced stop.'
run_fixture_adapter restore --restart-authorized
assert_error FORCE_STOP_REQUIRED
assert_recovery authorize-force-stop
make_stub "$BUNDLED/scripts/restore-dream-skin-macos.sh"

write_status ready running official true null
: > "$MARKER"
run_fixture_adapter install
assert_error CODEX_CLOSE_REQUIRED
[ ! -s "$MARKER" ] || { printf 'unauthorized install invoked a script.\n' >&2; exit 1; }

: > "$MARKER"
run_fixture_adapter install --restart-authorized
[ "$ADAPTER_EXIT" -eq 0 ] || { printf 'authorized install failed.\n' >&2; exit 1; }
/usr/bin/grep -Fx 'install-dream-skin-macos.sh --no-launchers --no-launch --close-running' "$MARKER" >/dev/null

# A stale managed-process identity must fail without replacing the installed engine.
ENGINE_BEFORE="$(/usr/bin/shasum -a 256 "$INSTALLED/VERSION" | /usr/bin/awk '{print $1}')"
/usr/bin/sed "s|__MARKER__|$MARKER|g" > "$BUNDLED/scripts/install-dream-skin-macos.sh" <<'STUB'
#!/bin/bash
/usr/bin/printf 'Recorded injector identity does not match.\n' >&2
exit 1
STUB
/bin/chmod 755 "$BUNDLED/scripts/install-dream-skin-macos.sh"
: > "$MARKER"
run_fixture_adapter install --restart-authorized
assert_error STATE_UNSAFE
[ "$ENGINE_BEFORE" = "$(/usr/bin/shasum -a 256 "$INSTALLED/VERSION" | /usr/bin/awk '{print $1}')" ] \
  || { printf 'unsafe install changed the installed engine.\n' >&2; exit 1; }
make_stub "$BUNDLED/scripts/install-dream-skin-macos.sh"

# Normal-quit timeout must surface force authorization before protected state changes.
/bin/mkdir -p "$FIXTURE_HOME/.codex" "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio"
/usr/bin/printf 'config sentinel\n' > "$FIXTURE_HOME/.codex/config.toml"
/usr/bin/printf 'state sentinel\n' > "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/state.json"
/usr/bin/printf 'backup sentinel\n' > "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/theme-backup.json"
PROTECTED_BEFORE="$(/usr/bin/shasum -a 256 \
  "$FIXTURE_HOME/.codex/config.toml" \
  "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/state.json" \
  "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/theme-backup.json")"
/usr/bin/sed > "$BUNDLED/scripts/restore-dream-skin-macos.sh" <<'STUB'
#!/bin/bash
printf 'Codex did not close within 15 seconds; explicit restart authorization is required for a forced stop.\n' >&2
exit 1
STUB
/bin/chmod 755 "$BUNDLED/scripts/restore-dream-skin-macos.sh"
: > "$MARKER"
run_fixture_adapter restore --restart-authorized
assert_error FORCE_STOP_REQUIRED
[ "$PROTECTED_BEFORE" = "$(/usr/bin/shasum -a 256 \
  "$FIXTURE_HOME/.codex/config.toml" \
  "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/state.json" \
  "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/theme-backup.json")" ] \
  || { printf 'normal-quit timeout changed protected state.\n' >&2; exit 1; }
make_stub "$BUNDLED/scripts/restore-dream-skin-macos.sh"

: > "$MARKER"
run_fixture_adapter restore --restart-authorized
[ "$ADAPTER_EXIT" -eq 0 ] || { printf 'authorized restore failed.\n' >&2; exit 1; }
/usr/bin/grep -Fx 'restore-dream-skin-macos.sh --restore-base-theme --restart-codex --restart-authorized' "$MARKER" >/dev/null
! /usr/bin/grep -q -- '--force-stop-authorized' "$MARKER"

: > "$MARKER"
run_fixture_adapter restore --restart-authorized --force-authorized
[ "$ADAPTER_EXIT" -eq 0 ] || { printf 'force-authorized restore failed.\n' >&2; exit 1; }
/usr/bin/grep -Fx 'restore-dream-skin-macos.sh --restore-base-theme --restart-codex --restart-authorized --force-stop-authorized' "$MARKER" >/dev/null

# Restore rechecks authorization after the adapter status snapshot. A Codex
# process appearing after that snapshot must not be stopped or permit mutation.
RESTORE_REAL="$TMP/restore-real"
RESTORE_REAL_HOME="$RESTORE_REAL/home"
RESTORE_REAL_MARKER="$RESTORE_REAL/marker"
/bin/mkdir -p "$RESTORE_REAL/scripts" "$RESTORE_REAL_HOME/.codex" "$RESTORE_REAL_HOME/state/theme"
/bin/cp "$ROOT/scripts/restore-dream-skin-macos.sh" "$RESTORE_REAL/scripts/"
/usr/bin/printf 'config sentinel\n' > "$RESTORE_REAL_HOME/.codex/config.toml"
/usr/bin/printf 'state sentinel\n' > "$RESTORE_REAL_HOME/state/state.json"
/usr/bin/printf 'backup sentinel\n' > "$RESTORE_REAL_HOME/state/theme-backup.json"
/usr/bin/sed "s|__HOME__|$RESTORE_REAL_HOME|g; s|__SCRIPTS__|$RESTORE_REAL/scripts|g; s|__MARKER__|$RESTORE_REAL_MARKER|g" > "$RESTORE_REAL/scripts/common-macos.sh" <<'STUB'
SCRIPT_DIR="__SCRIPTS__"
STATE_ROOT="__HOME__/state"
STATE_PATH="$STATE_ROOT/state.json"
ROLLBACK_STATE_PATH="$STATE_ROOT/rollback.json"
INSTALL_ROOT="__HOME__/installed"
THEME_BACKUP_PATH="$STATE_ROOT/theme-backup.json"
RESTORED_THEME_BACKUP_PATH="$STATE_ROOT/theme-backup.restored.json"
THEME_DIR="$STATE_ROOT/theme"
CONFIG_PATH="__HOME__/.codex/config.toml"
INJECTOR="__HOME__/injector.mjs"
NODE="__SCRIPTS__/node-stub"
fail() { printf 'fixture: %s\n' "$*" >&2; exit 1; }
discover_codex_app() { :; }
require_macos_runtime() { :; }
try_discover_codex_app() { :; }
try_require_macos_runtime() { :; }
try_validate_codex_app_identity() { CODEX_APP_VALIDATED=true; }
try_require_macos_node_runtime() { NODE="$SCRIPT_DIR/node-stub"; NODE_RUNTIME_VALIDATED=true; }
ensure_state_root() { printf 'ensure\n' >> "__MARKER__"; }
state_field() { printf '9341\n'; }
codex_is_running() { return 0; }
verified_cdp_endpoint() { return 1; }
verified_cdp_browser_id() { return 1; }
stop_codex() { printf 'stop:%s\n' "$1" >> "__MARKER__"; }
stop_recorded_injector() { printf 'injector\n' >> "__MARKER__"; }
release_codex_launchd_job() { printf 'release\n' >> "__MARKER__"; }
launch_codex_normally() {
  printf 'launch\n' >> "__MARKER__"
  [ "${DREAM_SKIN_TEST_LAUNCH_FAIL:-false}" != "true" ]
}
acquire_lifecycle_lock() { LIFECYCLE_LOCK_BORROWED="true"; return 0; }
require_lifecycle_lock() { acquire_lifecycle_lock; }
release_lifecycle_lock() { return 0; }
live_theme_backup_is_valid() { [ -f "$THEME_BACKUP_PATH" ] && [ ! -L "$THEME_BACKUP_PATH" ]; }
restored_theme_backup_is_valid() { [ -f "$RESTORED_THEME_BACKUP_PATH" ]; }
clear_renderer_rollback_evidence() { /bin/rm -f "$ROLLBACK_STATE_PATH"; }
STUB
/usr/bin/sed > "$RESTORE_REAL/scripts/node-stub" <<'STUB'
#!/bin/bash
set -euo pipefail
case "${2:-}" in
  restore)
    [ -f "${4:-}" ] || { printf 'No selective pre-install theme backup is available.\n' >&2; exit 1; }
    ;;
  archive)
    [ -f "${3:-}" ] || exit 1
    [ ! -e "${4:-}" ] || [ -f "$4" ] || exit 1
    /bin/cp "$3" "$4.tmp"
    /bin/mv "$4.tmp" "$4"
    /bin/rm -f "$3"
    ;;
  retire)
    [ -f "${3:-}" ] && [ -f "${4:-}" ] || exit 1
    /usr/bin/cmp -s "$3" "$4" || exit 1
    /bin/rm -f "$3"
    ;;
esac
STUB
/bin/chmod 755 "$RESTORE_REAL/scripts/node-stub"
: > "$RESTORE_REAL_MARKER"
set +e
/usr/bin/env HOME="$RESTORE_REAL_HOME" DREAM_SKIN_STUDIO_ADAPTER=true \
  "$RESTORE_REAL/scripts/restore-dream-skin-macos.sh" --restore-base-theme --restart-codex >/dev/null 2>&1
RESTORE_REAL_EXIT="$?"
set -e
[ "$RESTORE_REAL_EXIT" -ne 0 ] || { printf 'Studio restore crossed the restart-authorization race.\n' >&2; exit 1; }
[ ! -s "$RESTORE_REAL_MARKER" ] || { printf 'unauthorized raced restore stopped or mutated state.\n' >&2; exit 1; }
[ "$(/bin/cat "$RESTORE_REAL_HOME/.codex/config.toml")" = 'config sentinel' ]
[ "$(/bin/cat "$RESTORE_REAL_HOME/state/state.json")" = 'state sentinel' ]

: > "$RESTORE_REAL_MARKER"
/usr/bin/env HOME="$RESTORE_REAL_HOME" DREAM_SKIN_STUDIO_ADAPTER=true \
  "$RESTORE_REAL/scripts/restore-dream-skin-macos.sh" --restore-base-theme --restart-codex --restart-authorized >/dev/null
/usr/bin/grep -Fx 'stop:false' "$RESTORE_REAL_MARKER" >/dev/null
[ ! -e "$RESTORE_REAL_HOME/state/state.json" ]
[ ! -e "$RESTORE_REAL_HOME/state/theme-backup.json" ]
[ "$(/bin/cat "$RESTORE_REAL_HOME/state/theme-backup.restored.json")" = 'backup sentinel' ]

# State cleanup failure must retain the live recovery backup and be retryable.
/usr/bin/printf 'state sentinel\n' > "$RESTORE_REAL_HOME/state/state.json"
/usr/bin/printf 'state-fault backup\n' > "$RESTORE_REAL_HOME/state/theme-backup.json"
/bin/chmod 500 "$RESTORE_REAL_HOME/state"
set +e
/usr/bin/env HOME="$RESTORE_REAL_HOME" DREAM_SKIN_STUDIO_ADAPTER=true \
  "$RESTORE_REAL/scripts/restore-dream-skin-macos.sh" --restore-base-theme --restart-codex --restart-authorized \
  >/dev/null 2>&1
RESTORE_STATE_FAULT_EXIT="$?"
set -e
/bin/chmod 700 "$RESTORE_REAL_HOME/state"
[ "$RESTORE_STATE_FAULT_EXIT" -ne 0 ] || { printf 'state unlink fault unexpectedly committed restore.\n' >&2; exit 1; }
[ "$(/bin/cat "$RESTORE_REAL_HOME/state/state.json")" = 'state sentinel' ]
[ "$(/bin/cat "$RESTORE_REAL_HOME/state/theme-backup.json")" = 'state-fault backup' ]
/usr/bin/env HOME="$RESTORE_REAL_HOME" DREAM_SKIN_STUDIO_ADAPTER=true \
  "$RESTORE_REAL/scripts/restore-dream-skin-macos.sh" --restore-base-theme --restart-codex --restart-authorized \
  >/dev/null
[ ! -e "$RESTORE_REAL_HOME/state/state.json" ]
[ ! -e "$RESTORE_REAL_HOME/state/theme-backup.json" ]
[ "$(/bin/cat "$RESTORE_REAL_HOME/state/theme-backup.restored.json")" = 'state-fault backup' ]

# Archive publication failure happens after state commit but keeps the live
# backup usable; retry then atomically replaces the fixed completion archive.
/usr/bin/printf 'state sentinel\n' > "$RESTORE_REAL_HOME/state/state.json"
/usr/bin/printf 'archive-fault backup\n' > "$RESTORE_REAL_HOME/state/theme-backup.json"
/bin/rm -f "$RESTORE_REAL_HOME/state/theme-backup.restored.json"
/bin/mkdir "$RESTORE_REAL_HOME/state/theme-backup.restored.json"
set +e
/usr/bin/env HOME="$RESTORE_REAL_HOME" DREAM_SKIN_STUDIO_ADAPTER=true \
  "$RESTORE_REAL/scripts/restore-dream-skin-macos.sh" --restore-base-theme --restart-codex --restart-authorized \
  >/dev/null 2>&1
RESTORE_ARCHIVE_FAULT_EXIT="$?"
set -e
[ "$RESTORE_ARCHIVE_FAULT_EXIT" -ne 0 ] || { printf 'backup archive fault unexpectedly committed restore.\n' >&2; exit 1; }
[ "$(/bin/cat "$RESTORE_REAL_HOME/state/state.json")" = 'state sentinel' ]
[ "$(/bin/cat "$RESTORE_REAL_HOME/state/theme-backup.json")" = 'archive-fault backup' ]
/bin/rmdir "$RESTORE_REAL_HOME/state/theme-backup.restored.json"
/usr/bin/env HOME="$RESTORE_REAL_HOME" DREAM_SKIN_STUDIO_ADAPTER=true \
  "$RESTORE_REAL/scripts/restore-dream-skin-macos.sh" --restore-base-theme --restart-codex --restart-authorized \
  >/dev/null
[ "$(/bin/cat "$RESTORE_REAL_HOME/state/theme-backup.restored.json")" = 'archive-fault backup' ]
if /usr/bin/find "$RESTORE_REAL_HOME/state" -maxdepth 1 -name '.theme-backup.stage.*' -print -quit \
  | /usr/bin/grep -q .; then
  printf 'successful archive retry retained a staged theme backup.\n' >&2
  exit 1
fi
RESTORED_ARCHIVE_HASH="$(/usr/bin/shasum -a 256 "$RESTORE_REAL_HOME/state/theme-backup.restored.json")"
/usr/bin/env HOME="$RESTORE_REAL_HOME" DREAM_SKIN_STUDIO_ADAPTER=true \
  "$RESTORE_REAL/scripts/restore-dream-skin-macos.sh" --restore-base-theme --restart-codex --restart-authorized \
  >/dev/null
[ "$RESTORED_ARCHIVE_HASH" = "$(/usr/bin/shasum -a 256 "$RESTORE_REAL_HOME/state/theme-backup.restored.json")" ]

/usr/bin/printf 'state sentinel\n' > "$RESTORE_REAL_HOME/state/state.json"
/usr/bin/printf 'backup sentinel\n' > "$RESTORE_REAL_HOME/state/theme-backup.json"
: > "$RESTORE_REAL_MARKER"
set +e
/usr/bin/env HOME="$RESTORE_REAL_HOME" DREAM_SKIN_STUDIO_ADAPTER=true DREAM_SKIN_TEST_LAUNCH_FAIL=true \
  "$RESTORE_REAL/scripts/restore-dream-skin-macos.sh" --restore-base-theme --restart-codex --restart-authorized \
  >"$RESTORE_REAL/launch-failure.out" 2>"$RESTORE_REAL/launch-failure.err"
RESTORE_LAUNCH_EXIT="$?"
set -e
[ "$RESTORE_LAUNCH_EXIT" -eq 0 ] || { printf 'completed restore treated relaunch failure as transactional.\n' >&2; exit 1; }
[ ! -e "$RESTORE_REAL_HOME/state/state.json" ] || { printf 'completed restore retained stale state after relaunch failure.\n' >&2; exit 1; }
[ ! -e "$RESTORE_REAL_HOME/state/theme-backup.json" ] || { printf 'completed restore retained its live backup after relaunch failure.\n' >&2; exit 1; }
[ "$(/bin/cat "$RESTORE_REAL_HOME/state/theme-backup.restored.json")" = 'backup sentinel' ]

/usr/bin/env HOME="$RESTORE_REAL_HOME" DREAM_SKIN_STUDIO_ADAPTER=true \
  "$RESTORE_REAL/scripts/restore-dream-skin-macos.sh" --restore-base-theme --restart-codex --uninstall --restart-authorized \
  >/dev/null

# Restore and uninstall must stay adapter-to-native-helper complete when the
# installed engine is partial and every Node candidate is unavailable or unsafe.
RECOVERY_FIXTURE="$TMP/native-adapter-recovery"
RECOVERY_HOME="$RECOVERY_FIXTURE/home"
RECOVERY_BUNDLED="$RECOVERY_FIXTURE/bundled"
RECOVERY_INSTALLED="$RECOVERY_HOME/.codex/codex-dream-skin-studio"
RECOVERY_STATE="$RECOVERY_HOME/Library/Application Support/CodexDreamSkinStudio"
RECOVERY_CONFIG="$RECOVERY_HOME/.codex/config.toml"
RECOVERY_BACKUP="$RECOVERY_STATE/theme-backup.json"
RECOVERY_NODE_MARKER="$RECOVERY_FIXTURE/node-executed"
/bin/mkdir -p "$RECOVERY_BUNDLED/bin" "$RECOVERY_BUNDLED/scripts" "$RECOVERY_HOME/.codex" "$RECOVERY_STATE"
/bin/cp "$ROOT/VERSION" "$RECOVERY_BUNDLED/VERSION"
/bin/cp "$ROOT/bin/dream-skin-config-restore" "$RECOVERY_BUNDLED/bin/"
/bin/cp "$ROOT/scripts/restore-dream-skin-macos.sh" "$RECOVERY_BUNDLED/scripts/"
NO_NODE_CANDIDATE="$RECOVERY_FIXTURE/no-candidate"
/usr/bin/sed \
  -e "s|/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node|$NO_NODE_CANDIDATE|g" \
  -e "s|/Applications/Codex.app/Contents/Resources/cua_node/bin/node|$NO_NODE_CANDIDATE|g" \
  "$ROOT/scripts/studio-adapter-macos.sh" > "$RECOVERY_BUNDLED/scripts/studio-adapter-macos.sh"
/bin/cp "$ROOT/scripts/common-macos.sh" "$RECOVERY_BUNDLED/scripts/common-production-macos.sh"
/usr/bin/sed "s|__ROOT__|$RECOVERY_BUNDLED|g; s|__HOME__|$RECOVERY_HOME|g" \
  > "$RECOVERY_BUNDLED/scripts/common-macos.sh" <<'STUB'
#!/bin/bash
set -euo pipefail
. "__ROOT__/scripts/common-production-macos.sh"
try_discover_codex_app() {
  unset CODEX_BUNDLE CODEX_EXE CODEX_VERSION CODEX_TEAM_ID NODE RUNTIME_NODE NODE_VERSION NODE_TEAM_ID
  CODEX_APP_VALIDATED="false"
  CODEX_APP_CONTROL_VALIDATED="false"
  NODE_RUNTIME_VALIDATED="false"
  return 1
}
try_validate_codex_app_identity() { return 1; }
try_validate_codex_app_control_identity() { return 1; }
try_require_macos_node_runtime() { return 1; }
STUB
/usr/bin/sed > "$RECOVERY_BUNDLED/scripts/status-dream-skin-macos.sh" <<'STUB'
#!/bin/bash
operation=status
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--operation" ]; then operation="$2"; shift 2; else shift; fi
done
state="$HOME/Library/Application Support/CodexDreamSkinStudio/state.json"
archive="$HOME/Library/Application Support/CodexDreamSkinStudio/theme-backup.restored.json"
backup="$HOME/Library/Application Support/CodexDreamSkinStudio/theme-backup.json"
installed="$HOME/.codex/codex-dream-skin-studio"
if [ -e "$state" ]; then
  printf '{"schemaVersion":1,"ok":false,"operation":"%s","state":{"install":"not-installed","codex":"not-installed","session":"stale","operation":"idle","themeName":null,"requiresRestart":false,"availableActions":["restore","uninstall"],"verified":null},"error":{"code":"STATE_UNSAFE","message":"Theme state needs recovery before it can be used.","recoveryActions":["restore","diagnostics","cancel"]}}\n' "$operation"
  exit 1
fi
if [ -d "$installed" ] && [ ! -L "$installed" ] && [ ! -f "$archive" ] && [ ! -f "$backup" ]; then
  printf '{"schemaVersion":1,"ok":false,"operation":"%s","state":{"install":"not-installed","codex":"not-installed","session":"stale","operation":"idle","themeName":null,"requiresRestart":false,"availableActions":[],"verified":null},"error":{"code":"STATE_UNSAFE","message":"Theme state needs recovery before it can be used.","recoveryActions":["diagnostics","cancel"]}}\n' "$operation"
  exit 1
fi
actions='["install"]'
[ ! -d "$installed" ] || actions='["install","uninstall"]'
[ ! -f "$backup" ] || actions='["restore","uninstall"]'
[ ! -f "$archive" ] || actions='["install","restore","uninstall"]'
codex="${RECOVERY_CODEX_STATE:-not-installed}"
code=CODEX_NOT_INSTALLED
message='Codex is not installed.'
if [ "$codex" = "needs-first-run" ]; then
  code=CODEX_FIRST_RUN_REQUIRED
  message='Open Codex and complete first-run setup.'
fi
printf '{"schemaVersion":1,"ok":false,"operation":"%s","state":{"install":"not-installed","codex":"%s","session":"official","operation":"idle","themeName":null,"requiresRestart":false,"availableActions":%s,"verified":null},"error":{"code":"%s","message":"%s","recoveryActions":["cancel"]}}\n' \
  "$operation" "$codex" "$actions" "$code" "$message"
exit 1
STUB
: > "$RECOVERY_BUNDLED/scripts/theme-config.mjs"
/usr/bin/sed > "$RECOVERY_BUNDLED/scripts/injector.mjs" <<'STUB'
setInterval(() => {}, 30000);
STUB
/bin/chmod 755 "$RECOVERY_BUNDLED/scripts/"*.sh "$RECOVERY_BUNDLED/bin/dream-skin-config-restore"

NONEXEC_NODE="$RECOVERY_FIXTURE/non-executable-node"
TAMPERED_NODE="$RECOVERY_FIXTURE/tampered-node"
: > "$NONEXEC_NODE"
/usr/bin/sed "s|__MARKER__|$RECOVERY_NODE_MARKER|g" > "$TAMPERED_NODE" <<'STUB'
#!/bin/bash
/usr/bin/touch "__MARKER__"
exit 99
STUB
/bin/chmod 600 "$NONEXEC_NODE"
/bin/chmod 700 "$TAMPERED_NODE"

recreate_native_recovery() {
  /bin/mkdir -p "$RECOVERY_INSTALLED" "$RECOVERY_STATE"
  /usr/bin/printf 'partial engine\n' > "$RECOVERY_INSTALLED/partial"
  /usr/bin/printf '[desktop]\nappearanceTheme = "dark"\n' > "$RECOVERY_CONFIG"
  /usr/bin/printf '{damaged state\n' > "$RECOVERY_STATE/state.json"
  "$NODE" -e '
    const fs = require("node:fs");
    fs.writeFileSync(process.argv[1], `${JSON.stringify({
      schemaVersion: 1,
      platform: "darwin",
      configPath: process.argv[2],
      values: {
        appearanceTheme: `appearanceTheme = "system"`,
        appearanceDarkCodeThemeId: null,
      },
    })}\n`);
  ' "$RECOVERY_BACKUP" "$RECOVERY_CONFIG"
}

for watcher_protocol in 2 3; do
  recreate_native_recovery
  RECOVERY_STATE_BEFORE="$(/usr/bin/shasum -a 256 "$RECOVERY_STATE/state.json" "$RECOVERY_BACKUP")"
  watcher_args=(--watch --port 9341)
  [ "$watcher_protocol" != "3" ] || watcher_args+=(--browser-id Browser-A)
  watcher_args+=(--theme-dir "$RECOVERY_STATE/theme")
  "$NODE" "$RECOVERY_BUNDLED/scripts/injector.mjs" "${watcher_args[@]}" &
  RECOVERY_WATCHER_PID="$!"
  /bin/sleep 0.1
  set +e
  /usr/bin/env HOME="$RECOVERY_HOME" \
    "$RECOVERY_BUNDLED/scripts/studio-adapter-macos.sh" restore \
    > "$RECOVERY_FIXTURE/unsafe-identity-$watcher_protocol.json" \
    2> "$RECOVERY_FIXTURE/unsafe-identity-$watcher_protocol.stderr"
  RECOVERY_UNSAFE_EXIT="$?"
  set -e
  [ "$RECOVERY_UNSAFE_EXIT" -eq 1 ] \
    || { printf 'protocol-%s live identity did not fail closed.\n' "$watcher_protocol" >&2; exit 1; }
  "$NODE" -e '
    const text = require("node:fs").readFileSync(process.argv[1], "utf8").trim();
    const lines = text.split("\n");
    if (lines.length !== 1 || JSON.parse(lines[0]).error?.code !== "STATE_UNSAFE") {
      throw new Error(`unsafe recovery returned an unexpected envelope: ${text}`);
    }
  ' "$RECOVERY_FIXTURE/unsafe-identity-$watcher_protocol.json"
  [ "$RECOVERY_STATE_BEFORE" = "$(/usr/bin/shasum -a 256 "$RECOVERY_STATE/state.json" "$RECOVERY_BACKUP")" ] \
    || { printf 'protocol-%s live identity changed recovery artifacts.\n' "$watcher_protocol" >&2; exit 1; }
  /bin/kill -0 "$RECOVERY_WATCHER_PID" 2>/dev/null \
    || { printf 'unsafe recovery signalled protocol-%s watcher candidate.\n' "$watcher_protocol" >&2; exit 1; }
  /usr/bin/grep -F 'live injector candidate' "$RECOVERY_STATE/studio-operation.log" >/dev/null \
    || { printf 'protocol-%s recovery skipped watcher classification.\n' "$watcher_protocol" >&2; exit 1; }
  /bin/kill -TERM "$RECOVERY_WATCHER_PID" 2>/dev/null || true
  wait "$RECOVERY_WATCHER_PID" 2>/dev/null || true
  RECOVERY_WATCHER_PID=""
done

for recovery_operation in restore uninstall; do
  for node_case in missing non-executable tampered; do
    recreate_native_recovery
    /bin/rm -f "$RECOVERY_NODE_MARKER"
    case "$node_case" in
      missing) RECOVERY_NODE="$RECOVERY_FIXTURE/missing-node" ;;
      non-executable) RECOVERY_NODE="$NONEXEC_NODE" ;;
      tampered) RECOVERY_NODE="$TAMPERED_NODE" ;;
    esac
    set +e
    /usr/bin/env HOME="$RECOVERY_HOME" NODE="$RECOVERY_NODE" \
      "$RECOVERY_BUNDLED/scripts/studio-adapter-macos.sh" "$recovery_operation" \
      > "$RECOVERY_FIXTURE/$recovery_operation-$node_case.json" \
      2> "$RECOVERY_FIXTURE/$recovery_operation-$node_case.stderr"
    RECOVERY_EXIT="$?"
    set -e
    [ "$RECOVERY_EXIT" -eq 0 ] || {
      printf '%s with %s Node did not complete native recovery.\n' "$recovery_operation" "$node_case" >&2
      /bin/cat "$RECOVERY_FIXTURE/$recovery_operation-$node_case.json" >&2 || true
      /bin/cat "$RECOVERY_FIXTURE/$recovery_operation-$node_case.stderr" >&2 || true
      exit 1
    }
    "$NODE" -e '
      const value = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
      if (!value.ok || value.operation !== process.argv[2]) process.exit(1);
    ' "$RECOVERY_FIXTURE/$recovery_operation-$node_case.json" "$recovery_operation"
    /usr/bin/grep -Fx 'appearanceTheme = "system"' "$RECOVERY_CONFIG" >/dev/null
    [ ! -e "$RECOVERY_BACKUP" ]
    [ -f "$RECOVERY_STATE/theme-backup.restored.json" ]
    [ ! -e "$RECOVERY_NODE_MARKER" ] || { printf 'unsafe Node was executed during native recovery.\n' >&2; exit 1; }
  done
done

# A valid live backup remains completion proof when config.toml disappeared.
# Restore is retryable, Uninstall continues, and default recovery preserves themes.
for recovery_codex in not-installed needs-first-run; do
  recreate_native_recovery
  /bin/rm -f "$RECOVERY_CONFIG" "$RECOVERY_STATE/state.json" \
    "$RECOVERY_STATE/theme-backup.restored.json"
  /bin/mkdir -p "$RECOVERY_STATE/themes/user-theme" "$RECOVERY_STATE/theme"
  /usr/bin/printf 'user theme sentinel\n' > "$RECOVERY_STATE/themes/user-theme/theme.json"
  /usr/bin/printf 'active theme sentinel\n' > "$RECOVERY_STATE/theme/theme.json"
  RECOVERY_THEME_BEFORE="$(/usr/bin/shasum -a 256 \
    "$RECOVERY_STATE/themes/user-theme/theme.json" "$RECOVERY_STATE/theme/theme.json")"

  for recovery_attempt in first retry; do
    set +e
    /usr/bin/env HOME="$RECOVERY_HOME" RECOVERY_CODEX_STATE="$recovery_codex" \
      "$RECOVERY_BUNDLED/scripts/studio-adapter-macos.sh" restore \
      > "$RECOVERY_FIXTURE/missing-config-$recovery_codex-$recovery_attempt.json" \
      2> "$RECOVERY_FIXTURE/missing-config-$recovery_codex-$recovery_attempt.stderr"
    RECOVERY_EXIT="$?"
    set -e
    [ "$RECOVERY_EXIT" -eq 0 ] || {
      printf 'Missing-config %s restore %s failed.\n' "$recovery_codex" "$recovery_attempt" >&2
      /bin/cat "$RECOVERY_FIXTURE/missing-config-$recovery_codex-$recovery_attempt.json" >&2 || true
      exit 1
    }
    [ ! -e "$RECOVERY_CONFIG" ] && [ ! -L "$RECOVERY_CONFIG" ]
    [ ! -e "$RECOVERY_BACKUP" ] && [ -f "$RECOVERY_STATE/theme-backup.restored.json" ]
    [ ! -e "$RECOVERY_STATE/state.json" ] && [ ! -L "$RECOVERY_STATE/state.json" ]
  done

  set +e
  /usr/bin/env HOME="$RECOVERY_HOME" RECOVERY_CODEX_STATE="$recovery_codex" \
    "$RECOVERY_BUNDLED/scripts/studio-adapter-macos.sh" uninstall \
    > "$RECOVERY_FIXTURE/missing-config-$recovery_codex-uninstall.json" \
    2> "$RECOVERY_FIXTURE/missing-config-$recovery_codex-uninstall.stderr"
  RECOVERY_EXIT="$?"
  set -e
  [ "$RECOVERY_EXIT" -eq 0 ] || {
    printf 'Missing-config %s uninstall failed.\n' "$recovery_codex" >&2
    /bin/cat "$RECOVERY_FIXTURE/missing-config-$recovery_codex-uninstall.json" >&2 || true
    exit 1
  }
  [ ! -e "$RECOVERY_CONFIG" ] && [ ! -L "$RECOVERY_CONFIG" ]
  [ ! -e "$RECOVERY_INSTALLED" ] && [ ! -L "$RECOVERY_INSTALLED" ]
  [ "$RECOVERY_THEME_BEFORE" = "$(/usr/bin/shasum -a 256 \
    "$RECOVERY_STATE/themes/user-theme/theme.json" "$RECOVERY_STATE/theme/theme.json")" ]
done

# A bundle-present first-run Codex can still be running even though config.toml
# is absent. Preserve that fact through status and authorization, close only
# the exact validated process, and never relaunch into first-run setup.
FIRST_RUN_FIXTURE="$TMP/running-first-run"
FIRST_RUN_HOME="$FIRST_RUN_FIXTURE/home"
FIRST_RUN_BUNDLED="$FIRST_RUN_FIXTURE/bundled"
FIRST_RUN_STATE="$FIRST_RUN_HOME/Library/Application Support/CodexDreamSkinStudio"
FIRST_RUN_CONFIG="$FIRST_RUN_HOME/.codex/config.toml"
FIRST_RUN_BACKUP="$FIRST_RUN_STATE/theme-backup.json"
FIRST_RUN_ARCHIVE="$FIRST_RUN_STATE/theme-backup.restored.json"
FIRST_RUN_MARKER="$FIRST_RUN_FIXTURE/lifecycle.log"
FIRST_RUN_BUNDLE="$FIRST_RUN_HOME/Applications/ChatGPT.app"
FIRST_RUN_CODEX_EXE="$FIRST_RUN_BUNDLE/Contents/MacOS/ChatGPT"
FIRST_RUN_CODEX_SOURCE="$FIRST_RUN_FIXTURE/ChatGPT.c"
/bin/mkdir -p "$FIRST_RUN_BUNDLED/bin" "$FIRST_RUN_BUNDLED/scripts" \
  "$FIRST_RUN_HOME/.codex" "$FIRST_RUN_STATE/themes/user-theme" "$FIRST_RUN_STATE/theme" \
  "$FIRST_RUN_BUNDLE/Contents/MacOS"
/bin/cp "$ROOT/VERSION" "$FIRST_RUN_BUNDLED/VERSION"
/bin/cp "$ROOT/bin/dream-skin-config-restore" "$FIRST_RUN_BUNDLED/bin/"
/bin/cp "$ROOT/scripts/studio-adapter-macos.sh" "$ROOT/scripts/status-dream-skin-macos.sh" \
  "$ROOT/scripts/restore-dream-skin-macos.sh" "$FIRST_RUN_BUNDLED/scripts/"
/bin/cp "$ROOT/scripts/common-macos.sh" "$FIRST_RUN_BUNDLED/scripts/common-production-macos.sh"
: > "$FIRST_RUN_BUNDLED/scripts/theme-config.mjs"
: > "$FIRST_RUN_BUNDLED/scripts/injector.mjs"
/usr/bin/sed > "$FIRST_RUN_CODEX_SOURCE" <<'STUB'
#include <signal.h>
#include <unistd.h>

static volatile sig_atomic_t running = 1;

static void stop_process(int signal_number) {
  (void)signal_number;
  running = 0;
}

int main(void) {
  signal(SIGTERM, stop_process);
  signal(SIGINT, stop_process);
  while (running) pause();
  return 0;
}
STUB
/usr/bin/clang -Os "$FIRST_RUN_CODEX_SOURCE" -o "$FIRST_RUN_CODEX_EXE"
/usr/bin/sed > "$FIRST_RUN_BUNDLE/Contents/Info.plist" <<'STUB'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.openai.codex</string>
  <key>CFBundleExecutable</key>
  <string>ChatGPT</string>
  <key>CFBundleShortVersionString</key>
  <string>fixture</string>
</dict>
</plist>
STUB
/usr/bin/sed \
  -e "s|__MARKER__|$FIRST_RUN_MARKER|g" \
  > "$FIRST_RUN_BUNDLED/scripts/common-macos.sh" <<'STUB'
#!/bin/bash
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/common-production-macos.sh"
try_validate_codex_app_identity() {
  [ "$CODEX_BUNDLE" = "$CODEX_APP_BUNDLE" ] \
    && [ "$CODEX_EXE" = "$CODEX_APP_BUNDLE/Contents/MacOS/ChatGPT" ] || return 1
  CODEX_APP_VALIDATED="true"
  CODEX_APP_CONTROL_VALIDATED="true"
  CODEX_TEAM_ID="$EXPECTED_CODEX_TEAM_ID"
  export CODEX_APP_VALIDATED CODEX_APP_CONTROL_VALIDATED CODEX_TEAM_ID
}
try_validate_codex_app_control_identity() { try_validate_codex_app_identity; }
try_require_macos_node_runtime() {
  NODE_RUNTIME_VALIDATED="false"
  unset NODE RUNTIME_NODE NODE_VERSION NODE_TEAM_ID
  return 1
}
release_codex_launchd_job() { :; }
verified_cdp_browser_id() { return 1; }
stop_codex() {
  [ "${CODEX_APP_VALIDATED:-false}" = "true" ] \
    && [ "${CODEX_APP_CONTROL_VALIDATED:-false}" = "true" ] \
    || fail "Fixture Codex control identity was not validated."
  [ "$(codex_main_pids)" = "$DREAM_SKIN_TEST_CODEX_PID" ] \
    || fail "Fixture Codex PID did not match the validated executable."
  printf 'verified-stop:%s\n' "$DREAM_SKIN_TEST_CODEX_PID" >> "__MARKER__"
  /bin/kill -TERM "$DREAM_SKIN_TEST_CODEX_PID"
  local deadline=$((SECONDS + 5))
  while codex_is_running && [ "$SECONDS" -lt "$deadline" ]; do /bin/sleep 0.02; done
  codex_is_running && fail "Fixture Codex did not stop."
  return 0
}
launch_codex_normally() { printf 'relaunch\n' >> "__MARKER__"; }
STUB
/bin/chmod 755 "$FIRST_RUN_BUNDLED/bin/dream-skin-config-restore" \
  "$FIRST_RUN_BUNDLED/scripts/"*.sh "$FIRST_RUN_CODEX_EXE"
/usr/bin/printf 'user theme sentinel\n' > "$FIRST_RUN_STATE/themes/user-theme/theme.json"
/usr/bin/printf 'active theme sentinel\n' > "$FIRST_RUN_STATE/theme/theme.json"
"$NODE" -e '
  const fs = require("node:fs");
  fs.writeFileSync(process.argv[1], `${JSON.stringify({
    schemaVersion: 1,
    platform: "darwin",
    configPath: process.argv[2],
    values: {
      appearanceTheme: `appearanceTheme = "system"`,
      appearanceDarkCodeThemeId: null,
    },
  })}\n`);
' "$FIRST_RUN_BACKUP" "$FIRST_RUN_CONFIG"
FIRST_RUN_THEME_BEFORE="$(/usr/bin/shasum -a 256 \
  "$FIRST_RUN_STATE/themes/user-theme/theme.json" "$FIRST_RUN_STATE/theme/theme.json")"
"$FIRST_RUN_CODEX_EXE" &
FIRST_RUN_CODEX_PID="$!"
/bin/sleep 0.1
/usr/bin/pgrep -x ChatGPT | /usr/bin/grep -Fx "$FIRST_RUN_CODEX_PID" >/dev/null

set +e
/usr/bin/env HOME="$FIRST_RUN_HOME" CODEX_APP_BUNDLE="$FIRST_RUN_BUNDLE" \
  "$FIRST_RUN_BUNDLED/scripts/status-dream-skin-macos.sh" --studio-json --deep --operation restore \
  > "$FIRST_RUN_FIXTURE/status.json"
FIRST_RUN_STATUS_EXIT="$?"
set -e
[ "$FIRST_RUN_STATUS_EXIT" -eq 1 ]
"$NODE" -e '
  const value = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  if (value.state?.codex !== "needs-first-run" || value.state?.requiresRestart !== true) {
    throw new Error(`running first-run status lost the live Codex fact: ${JSON.stringify(value)}`);
  }
' "$FIRST_RUN_FIXTURE/status.json"

set +e
/usr/bin/env HOME="$FIRST_RUN_HOME" CODEX_APP_BUNDLE="$FIRST_RUN_BUNDLE" \
  DREAM_SKIN_TEST_CODEX_PID="$FIRST_RUN_CODEX_PID" \
  "$FIRST_RUN_BUNDLED/scripts/studio-adapter-macos.sh" restore \
  > "$FIRST_RUN_FIXTURE/unauthorized.json" 2> "$FIRST_RUN_FIXTURE/unauthorized.stderr"
FIRST_RUN_RESTORE_EXIT="$?"
set -e
[ "$FIRST_RUN_RESTORE_EXIT" -eq 1 ]
"$NODE" -e '
  const value = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  if (value.error?.code !== "RESTART_REQUIRED") throw new Error(`unexpected first-run authorization result: ${JSON.stringify(value)}`);
' "$FIRST_RUN_FIXTURE/unauthorized.json"
/bin/kill -0 "$FIRST_RUN_CODEX_PID"
[ -f "$FIRST_RUN_BACKUP" ] && [ ! -e "$FIRST_RUN_ARCHIVE" ] && [ ! -e "$FIRST_RUN_MARKER" ]

set +e
/usr/bin/env HOME="$FIRST_RUN_HOME" CODEX_APP_BUNDLE="$FIRST_RUN_BUNDLE" \
  DREAM_SKIN_TEST_CODEX_PID="$FIRST_RUN_CODEX_PID" \
  "$FIRST_RUN_BUNDLED/scripts/studio-adapter-macos.sh" restore --restart-authorized \
  > "$FIRST_RUN_FIXTURE/authorized.json" 2> "$FIRST_RUN_FIXTURE/authorized.stderr"
FIRST_RUN_RESTORE_EXIT="$?"
set -e
[ "$FIRST_RUN_RESTORE_EXIT" -eq 0 ] || {
  /bin/cat "$FIRST_RUN_FIXTURE/authorized.json" >&2 || true
  /bin/cat "$FIRST_RUN_FIXTURE/authorized.stderr" >&2 || true
  /bin/cat "$FIRST_RUN_STATE/studio-operation.log" >&2 || true
  exit 1
}
"$NODE" -e '
  const value = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  if (!value.ok || value.operation !== "restore") throw new Error(`authorized first-run restore failed: ${JSON.stringify(value)}`);
' "$FIRST_RUN_FIXTURE/authorized.json"
[ ! -e "$FIRST_RUN_CONFIG" ] && [ ! -L "$FIRST_RUN_CONFIG" ]
[ ! -e "$FIRST_RUN_BACKUP" ] && [ -f "$FIRST_RUN_ARCHIVE" ]
[ "$(/bin/cat "$FIRST_RUN_MARKER")" = "verified-stop:$FIRST_RUN_CODEX_PID" ]
[ "$FIRST_RUN_THEME_BEFORE" = "$(/usr/bin/shasum -a 256 \
  "$FIRST_RUN_STATE/themes/user-theme/theme.json" "$FIRST_RUN_STATE/theme/theme.json")" ]
wait "$FIRST_RUN_CODEX_PID" 2>/dev/null || true
FIRST_RUN_CODEX_PID=""

# A restored partial engine stays removable through the fixed completion proof;
# losing that proof must fail closed without deleting the engine.
/bin/mkdir -p "$RECOVERY_INSTALLED"
/usr/bin/printf 'partial engine\n' > "$RECOVERY_INSTALLED/partial"
[ -f "$RECOVERY_STATE/theme-backup.restored.json" ]
set +e
/usr/bin/env HOME="$RECOVERY_HOME" "$RECOVERY_BUNDLED/scripts/studio-adapter-macos.sh" uninstall \
  > "$RECOVERY_FIXTURE/completed-uninstall.json" 2> "$RECOVERY_FIXTURE/completed-uninstall.stderr"
COMPLETED_UNINSTALL_EXIT="$?"
set -e
[ "$COMPLETED_UNINSTALL_EXIT" -eq 0 ] || {
  printf 'completion-proof uninstall failed.\n' >&2
  /bin/cat "$RECOVERY_FIXTURE/completed-uninstall.json" >&2 || true
  /bin/cat "$RECOVERY_FIXTURE/completed-uninstall.stderr" >&2 || true
  exit 1
}
[ ! -e "$RECOVERY_INSTALLED" ] || { printf 'completion-proof uninstall retained the partial engine.\n' >&2; exit 1; }

/bin/mkdir -p "$RECOVERY_INSTALLED"
/usr/bin/printf 'partial engine\n' > "$RECOVERY_INSTALLED/partial"
/bin/rm -f "$RECOVERY_STATE/theme-backup.restored.json"
set +e
/usr/bin/env HOME="$RECOVERY_HOME" "$RECOVERY_BUNDLED/scripts/studio-adapter-macos.sh" uninstall \
  > "$RECOVERY_FIXTURE/missing-proof-uninstall.json" 2> "$RECOVERY_FIXTURE/missing-proof-uninstall.stderr"
MISSING_PROOF_UNINSTALL_EXIT="$?"
set -e
[ "$MISSING_PROOF_UNINSTALL_EXIT" -eq 1 ] || { printf 'missing-proof uninstall did not fail closed.\n' >&2; exit 1; }
[ -d "$RECOVERY_INSTALLED" ] || { printf 'missing-proof uninstall deleted the partial engine.\n' >&2; exit 1; }
"$NODE" -e '
  const value = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  if (value.error?.code !== "STATE_UNSAFE") process.exit(1);
' "$RECOVERY_FIXTURE/missing-proof-uninstall.json"

"$NODE" -e '
  const fs = require("node:fs");
  fs.writeFileSync(process.argv[1], `${JSON.stringify({
    schemaVersion: 1,
    platform: "darwin",
    configPath: process.argv[2],
    values: {
      appearanceTheme: "garbage",
      appearanceDarkCodeThemeId: null,
    },
  })}\n`);
' "$RECOVERY_STATE/theme-backup.restored.json" "$RECOVERY_CONFIG"
set +e
/usr/bin/env HOME="$RECOVERY_HOME" "$RECOVERY_BUNDLED/scripts/studio-adapter-macos.sh" uninstall \
  > "$RECOVERY_FIXTURE/invalid-proof-uninstall.json" 2> "$RECOVERY_FIXTURE/invalid-proof-uninstall.stderr"
INVALID_PROOF_UNINSTALL_EXIT="$?"
set -e
[ "$INVALID_PROOF_UNINSTALL_EXIT" -eq 1 ] || { printf 'invalid-proof uninstall did not fail closed.\n' >&2; exit 1; }
[ -d "$RECOVERY_INSTALLED" ] || { printf 'invalid-proof uninstall deleted the partial engine.\n' >&2; exit 1; }

# The production deploy-and-exec upgrade path must transition verified-stopped
# watcher state before the new engine is installed.
UPGRADE_FIXTURE="$TMP/production-upgrade"
UPGRADE_HOME="$UPGRADE_FIXTURE/home"
UPGRADE_BUNDLED="$UPGRADE_FIXTURE/bundled"
UPGRADE_INSTALLED="$UPGRADE_HOME/.codex/codex-dream-skin-studio"
UPGRADE_STATE="$UPGRADE_HOME/Library/Application Support/CodexDreamSkinStudio"
UPGRADE_MARKER="$UPGRADE_FIXTURE/stops"
/bin/mkdir -p "$UPGRADE_BUNDLED/bin" "$UPGRADE_BUNDLED/scripts" "$UPGRADE_INSTALLED" \
  "$UPGRADE_STATE/theme" "$UPGRADE_HOME/.codex"
/bin/cp "$ROOT/VERSION" "$UPGRADE_BUNDLED/VERSION"
/bin/cp "$ROOT/bin/dream-skin-config-restore" "$UPGRADE_BUNDLED/bin/"
/bin/cp "$ROOT/scripts/studio-adapter-macos.sh" "$ROOT/scripts/install-dream-skin-macos.sh" \
  "$UPGRADE_BUNDLED/scripts/"
/usr/bin/sed "s|__MARKER__|$UPGRADE_MARKER|g" > "$UPGRADE_BUNDLED/scripts/common-macos.sh" <<'STUB'
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
INSTALL_ROOT="$HOME/.codex/codex-dream-skin-studio"
STATE_ROOT="$HOME/Library/Application Support/CodexDreamSkinStudio"
STATE_PATH="$STATE_ROOT/state.json"
THEME_BACKUP_PATH="$STATE_ROOT/theme-backup.json"
THEME_DIR="$STATE_ROOT/theme"
CONFIG_PATH="$HOME/.codex/config.toml"
INJECTOR="$SCRIPT_DIR/injector.mjs"
NODE=/usr/bin/true
SKIN_VERSION=1.3.0
CODEX_VERSION=fixture
NODE_VERSION=v20.0.0
fail() { printf 'fixture: %s\n' "$*" >&2; exit 1; }
discover_codex_app() { return 0; }
require_macos_runtime() { return 0; }
codex_is_running() { return 1; }
stop_recorded_injector() { printf 'verified-stop\n' >> "__MARKER__"; return 0; }
ensure_state_root() { /bin/mkdir -p "$STATE_ROOT"; }
seed_bundled_presets() { /bin/mkdir -p "$THEME_DIR"; [ -f "$THEME_DIR/theme.json" ] || printf '{"name":"Fixture"}\n' > "$THEME_DIR/theme.json"; }
acquire_lifecycle_lock() { LIFECYCLE_LOCK_BORROWED="true"; return 0; }
require_lifecycle_lock() { acquire_lifecycle_lock; }
release_lifecycle_lock() { return 0; }
STUB
/usr/bin/sed > "$UPGRADE_BUNDLED/scripts/status-dream-skin-macos.sh" <<'STUB'
#!/bin/bash
operation=status
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--operation" ]; then operation="$2"; shift 2; else shift; fi
done
state="$HOME/Library/Application Support/CodexDreamSkinStudio/state.json"
if [ -e "$state" ]; then
  printf '{"schemaVersion":1,"ok":false,"operation":"%s","state":{"install":"not-installed","codex":"stopped","session":"stale","operation":"idle","themeName":"Fixture","requiresRestart":false,"availableActions":["install"],"verified":null},"error":{"code":"STATE_UNSAFE","message":"Theme state needs recovery before it can be used.","recoveryActions":["restore","diagnostics","cancel"]}}\n' "$operation"
  exit 1
fi
printf '{"schemaVersion":1,"ok":true,"operation":"%s","state":{"install":"ready","codex":"stopped","session":"official","operation":"idle","themeName":"Fixture","requiresRestart":false,"availableActions":["apply","restore","uninstall"],"verified":null},"error":null}\n' "$operation"
STUB
for script in start-dream-skin-macos.sh pause-dream-skin-macos.sh restore-dream-skin-macos.sh verify-dream-skin-macos.sh; do
  /usr/bin/sed > "$UPGRADE_BUNDLED/scripts/$script" <<'STUB'
#!/bin/bash
exit 0
STUB
done
for script in theme-config.mjs injector.mjs; do : > "$UPGRADE_BUNDLED/scripts/$script"; done
/bin/chmod 755 "$UPGRADE_BUNDLED/scripts/"*.sh "$UPGRADE_BUNDLED/bin/dream-skin-config-restore"
/usr/bin/printf '[desktop]\n' > "$UPGRADE_HOME/.codex/config.toml"
/usr/bin/printf '{}\n' > "$UPGRADE_STATE/theme-backup.json"
/usr/bin/printf '{"name":"Fixture"}\n' > "$UPGRADE_STATE/theme/theme.json"
/usr/bin/printf '{"port":9341,"session":"active","injectorPid":4242}\n' > "$UPGRADE_STATE/state.json"
set +e
/usr/bin/env HOME="$UPGRADE_HOME" "$UPGRADE_BUNDLED/scripts/studio-adapter-macos.sh" install \
  > "$UPGRADE_FIXTURE/install.json" 2> "$UPGRADE_FIXTURE/install.stderr"
UPGRADE_EXIT="$?"
set -e
[ "$UPGRADE_EXIT" -eq 0 ] || { printf 'production upgrade fixture failed.\n' >&2; exit 1; }
/usr/bin/grep -Fx 'verified-stop' "$UPGRADE_MARKER" >/dev/null
[ ! -e "$UPGRADE_STATE/state.json" ] || { printf 'successful production upgrade retained old watcher state.\n' >&2; exit 1; }

write_status ready stopped paused false false
: > "$MARKER"
run_fixture_adapter resume
[ "$ADAPTER_EXIT" -eq 0 ] || { printf 'resume failed.\n' >&2; exit 1; }
/usr/bin/grep -Fx 'start-dream-skin-macos.sh --studio-strict-verify' "$MARKER" >/dev/null
[ "$(/usr/bin/head -n 1 "$MARKER")" = 'start-dream-skin-macos.sh --studio-strict-verify' ] \
  || { printf 'resume did not use the installed engine.\n' >&2; exit 1; }

/bin/mkdir -p "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/themes" \
  "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/images" \
  "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/theme"
: > "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/themes/saved"
: > "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/images/saved"
: > "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/theme/active"
write_status ready stopped official false false
: > "$MARKER"
run_fixture_adapter uninstall --restart-authorized
[ "$ADAPTER_EXIT" -eq 0 ] || { printf 'default uninstall failed.\n' >&2; exit 1; }
[ -e "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/themes/saved" ]
[ -e "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/images/saved" ]
[ -e "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/theme/active" ]
[ "$(/usr/bin/head -n 1 "$MARKER")" = 'restore-dream-skin-macos.sh --restore-base-theme --restart-codex --uninstall --restart-authorized' ]

# Recreate the installed fixture after uninstall, then prove explicit theme deletion is last.
/bin/mkdir -p "$INSTALLED/bin" "$INSTALLED/scripts"
/bin/cp "$ROOT/VERSION" "$INSTALLED/VERSION"
/bin/cp "$ROOT/bin/dream-skin-config-restore" "$INSTALLED/bin/"
for script in start-dream-skin-macos.sh pause-dream-skin-macos.sh restore-dream-skin-macos.sh verify-dream-skin-macos.sh status-dream-skin-macos.sh common-macos.sh theme-config.mjs injector.mjs; do
  make_stub "$INSTALLED/scripts/$script"
done
: > "$MARKER"
run_fixture_adapter uninstall --restart-authorized --delete-user-themes
[ "$ADAPTER_EXIT" -eq 0 ] || { printf 'theme-deleting uninstall failed.\n' >&2; exit 1; }
[ ! -e "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/themes" ]
[ ! -e "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/images" ]
[ ! -e "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/theme" ]

# A failed restore must leave both the installed engine and saved themes untouched.
/bin/mkdir -p "$INSTALLED/bin" "$INSTALLED/scripts" "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/themes"
/bin/cp "$ROOT/VERSION" "$INSTALLED/VERSION"
/bin/cp "$ROOT/bin/dream-skin-config-restore" "$INSTALLED/bin/"
for script in start-dream-skin-macos.sh pause-dream-skin-macos.sh verify-dream-skin-macos.sh status-dream-skin-macos.sh common-macos.sh theme-config.mjs injector.mjs; do
  make_stub "$INSTALLED/scripts/$script"
done
/usr/bin/sed "s|__MARKER__|$MARKER|g" > "$BUNDLED/scripts/restore-dream-skin-macos.sh" <<'STUB'
#!/bin/bash
/usr/bin/printf 'restore-dream-skin-macos.sh %s\n' "$*" >> "__MARKER__"
exit 1
STUB
/bin/chmod 755 "$BUNDLED/scripts/restore-dream-skin-macos.sh"
: > "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/themes/saved"
: > "$MARKER"
run_fixture_adapter uninstall --restart-authorized --delete-user-themes
assert_error OPERATION_FAILED
[ -d "$INSTALLED" ] || { printf 'failed restore deleted the engine.\n' >&2; exit 1; }
[ -e "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/themes/saved" ] \
  || { printf 'failed restore deleted saved themes.\n' >&2; exit 1; }

# Cleanup failures stay in the operation log and return one stable JSON line.
/bin/mkdir -p "$INSTALLED/bin" "$INSTALLED/scripts"
/bin/cp "$ROOT/VERSION" "$INSTALLED/VERSION"
/bin/cp "$ROOT/bin/dream-skin-config-restore" "$INSTALLED/bin/"
for script in start-dream-skin-macos.sh pause-dream-skin-macos.sh restore-dream-skin-macos.sh verify-dream-skin-macos.sh status-dream-skin-macos.sh common-macos.sh theme-config.mjs injector.mjs; do
  make_stub "$INSTALLED/scripts/$script"
done
write_status ready stopped official false false
/bin/chmod 500 "$FIXTURE_HOME/.codex"
CLEANUP_JSON="$TMP/cleanup-failure.json"
CLEANUP_STDERR="$TMP/cleanup-failure.stderr"
set +e
/usr/bin/env HOME="$FIXTURE_HOME" "$BUNDLED/scripts/studio-adapter-macos.sh" uninstall --restart-authorized \
  >"$CLEANUP_JSON" 2>"$CLEANUP_STDERR"
CLEANUP_EXIT="$?"
set -e
/bin/chmod 700 "$FIXTURE_HOME/.codex"
[ "$CLEANUP_EXIT" -eq 1 ] || { printf 'cleanup failure did not return a domain error.\n' >&2; exit 1; }
CLEANUP_VALUE="$(/bin/cat "$CLEANUP_JSON")"
assert_json_line "$CLEANUP_VALUE"
"$NODE" -e 'if (JSON.parse(process.argv[1]).error?.code !== "OPERATION_FAILED") process.exit(1)' "$CLEANUP_VALUE"
! /usr/bin/grep -Eqi 'permission denied|operation not permitted|rm:' "$CLEANUP_STDERR"

# Lifecycle scripts must expose the explicit flags and keep mutations behind safe stops.
"$NODE" -e '
  const fs = require("node:fs");
  const install = fs.readFileSync(process.argv[1], "utf8");
  const start = fs.readFileSync(process.argv[2], "utf8");
  const pause = fs.readFileSync(process.argv[3], "utf8");
  const restore = fs.readFileSync(process.argv[4], "utf8");
  for (const required of ["--close-running", "--force-stop-authorized"]) {
    if (!install.includes(required)) throw new Error(`install missing ${required}`);
  }
  const deployCall = install.indexOf("\n  deploy_project\n");
  const stopCodex = install.indexOf("stop_codex");
  const stopInjector = install.indexOf("stop_recorded_injector");
  if (deployCall === -1 || stopCodex === -1 || stopCodex > deployCall) throw new Error("install deploys before stopping Codex");
  if (stopInjector === -1 || stopInjector > deployCall) throw new Error("install deploys before validating the injector");
  for (const required of ["--force-stop-authorized", "--studio-strict-verify"]) {
    if (!start.includes(required)) throw new Error(`start missing ${required}`);
  }
  if (!/STUDIO_STRICT_VERIFY[\s\S]*installed.*true/.test(start)) throw new Error("strict verify does not guard soft success");
  if (!pause.includes("verified_cdp_browser_id") || !pause.includes("--browser-id") ||
      !/fail .*live skin/.test(pause)) throw new Error("pause removal is not Browser-ID verified");
  if (!restore.includes("--restart-authorized")) throw new Error("restore missing restart authorization");
  if (!restore.includes("--force-stop-authorized")) throw new Error("restore missing force authorization");
' "$ROOT/scripts/install-dream-skin-macos.sh" "$ROOT/scripts/start-dream-skin-macos.sh" \
  "$ROOT/scripts/pause-dream-skin-macos.sh" "$ROOT/scripts/restore-dream-skin-macos.sh"

printf 'PASS: macOS Studio adapter lifecycle is authorized, ordered, and protocol-safe.\n'
