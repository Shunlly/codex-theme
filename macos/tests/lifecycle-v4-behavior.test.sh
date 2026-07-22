#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
NODE="${NODE:-$(command -v node)}"
TMP="$(/usr/bin/mktemp -d /tmp/codex-dream-skin-lifecycle-v4.XXXXXX)"
cleanup() { [ "${KEEP_LIFECYCLE_V4_TMP:-false}" = true ] || /bin/rm -rf "$TMP"; }
trap cleanup EXIT

# The shared launcher helper removes only exact installer-owned regular files.
LAUNCHER_HOME="$TMP/launchers/home"
LAUNCHER_DESKTOP="$LAUNCHER_HOME/Desktop"
/bin/mkdir -p "$LAUNCHER_DESKTOP"
/usr/bin/printf '%s\n' '#!/bin/bash' '# CodexDreamSkinStudio launcher' 'set -e' 'exit 0' \
  > "$LAUNCHER_DESKTOP/Codex Dream Skin.command"
/usr/bin/printf '%s\n' '#!/bin/bash' '# user file' 'set -e' \
  > "$LAUNCHER_DESKTOP/Codex Dream Skin - Customize.command"
/usr/bin/printf 'symlink target\n' > "$TMP/launcher-target"
/bin/ln -s "$TMP/launcher-target" "$LAUNCHER_DESKTOP/Codex Dream Skin - Verify.command"
/usr/bin/env HOME="$LAUNCHER_HOME" NODE="$NODE" /bin/bash -c '
  set -euo pipefail
  . "$1/scripts/common-macos.sh"
  remove_managed_macos_launchers "$2"
  remove_managed_macos_launchers "$2"
' _ "$ROOT" "$LAUNCHER_DESKTOP"
[ ! -e "$LAUNCHER_DESKTOP/Codex Dream Skin.command" ]
[ -f "$LAUNCHER_DESKTOP/Codex Dream Skin - Customize.command" ]
[ -L "$LAUNCHER_DESKTOP/Codex Dream Skin - Verify.command" ]
[ "$(/bin/cat "$TMP/launcher-target")" = 'symlink target' ]
[ ! -e "$LAUNCHER_DESKTOP/Codex Dream Skin - Restore.command" ]

# Ownership remains bound to the inode moved into quarantine. A same-byte
# replacement before that rename must be retained and fail cleanup; a
# same-byte replacement after the rename must survive while only the
# quarantined owned inode is consumed.
LAUNCHER_RACE="$TMP/launcher-race"
LAUNCHER_RACE_COMMON="$LAUNCHER_RACE/common-macos.sh"
LAUNCHER_RACE_MV="$LAUNCHER_RACE/mv"
/bin/mkdir -p "$LAUNCHER_RACE"
/bin/cp "$ROOT/VERSION" "$TMP/VERSION"
/usr/bin/sed "s|/bin/mv|$LAUNCHER_RACE_MV|g" \
  "$ROOT/scripts/common-macos.sh" > "$LAUNCHER_RACE_COMMON"
/usr/bin/sed > "$LAUNCHER_RACE_MV" <<'STUB'
#!/bin/bash
set -euo pipefail
source_path="$1"
destination_path="$2"
case "${LAUNCHER_RACE_MODE:-}:$source_path:$destination_path" in
  before:*Codex\ Dream\ Skin.command:*entry)
    /bin/cp -pP "$source_path" "$source_path.original"
    /bin/rm -f "$source_path"
    /bin/cp -pP "$source_path.original" "$source_path"
    ;;
esac
/bin/mv "$source_path" "$destination_path"
case "${LAUNCHER_RACE_MODE:-}:$source_path:$destination_path" in
  after:*Codex\ Dream\ Skin.command:*entry)
    /bin/cp -pP "$destination_path" "$source_path"
    ;;
esac
STUB
/bin/chmod 755 "$LAUNCHER_RACE_MV"

for race_mode in before after; do
  race_desktop="$LAUNCHER_RACE/$race_mode/Desktop"
  /bin/mkdir -p "$race_desktop"
  race_launcher="$race_desktop/Codex Dream Skin.command"
  /usr/bin/printf '%s\n' '#!/bin/bash' '# CodexDreamSkinStudio launcher' 'set -e' \
    > "$race_launcher"
  race_identity_before="$(/usr/bin/stat -f '%d:%i' "$race_launcher")"
  set +e
  /usr/bin/env HOME="$LAUNCHER_RACE/$race_mode" LAUNCHER_RACE_MODE="$race_mode" \
    /bin/bash -c '
      set -euo pipefail
      . "$1"
      remove_managed_macos_launchers "$2"
    ' _ "$LAUNCHER_RACE_COMMON" "$race_desktop"
  race_exit="$?"
  set -e
  [ -f "$race_launcher" ] && [ ! -L "$race_launcher" ] \
    || { printf 'launcher %s-rename replacement was deleted.\n' "$race_mode" >&2; exit 1; }
  [ "$race_identity_before" != "$(/usr/bin/stat -f '%d:%i' "$race_launcher")" ] \
    || { printf 'launcher %s-rename fixture did not replace the inode.\n' "$race_mode" >&2; exit 1; }
  if [ "$race_mode" = before ]; then
    [ "$race_exit" -ne 0 ] \
      || { printf 'launcher pre-rename replacement did not fail closed.\n' >&2; exit 1; }
  else
    [ "$race_exit" -eq 0 ] \
      || { printf 'launcher post-rename replacement did not preserve owned cleanup.\n' >&2; exit 1; }
  fi
done

# Restore must prove listener absence before it stages a backup or touches a
# recorded watcher whenever the official Codex control identity is unavailable.
RESTORE_FIXTURE="$TMP/restore"
RESTORE_HOME="$RESTORE_FIXTURE/home"
RESTORE_SCRIPTS="$RESTORE_FIXTURE/scripts"
RESTORE_STATE="$RESTORE_HOME/state"
RESTORE_MARKER="$RESTORE_FIXTURE/marker"
/bin/mkdir -p "$RESTORE_SCRIPTS" "$RESTORE_STATE/theme" "$RESTORE_HOME/.codex"
/bin/cp "$ROOT/scripts/restore-dream-skin-macos.sh" "$RESTORE_SCRIPTS/"
/usr/bin/sed \
  -e "s|__HOME__|$RESTORE_HOME|g" \
  -e "s|__SCRIPTS__|$RESTORE_SCRIPTS|g" \
  -e "s|__MARKER__|$RESTORE_MARKER|g" \
  > "$RESTORE_SCRIPTS/common-macos.sh" <<'STUB'
SCRIPT_DIR="__SCRIPTS__"
PROJECT_ROOT="__HOME__/engine"
INSTALL_ROOT="__HOME__/installed"
STATE_ROOT="__HOME__/state"
STATE_PATH="$STATE_ROOT/state.json"
ROLLBACK_STATE_PATH="$STATE_ROOT/rollback.json"
THEME_BACKUP_PATH="$STATE_ROOT/theme-backup.json"
RESTORED_THEME_BACKUP_PATH="$STATE_ROOT/theme-backup.restored.json"
THEME_DIR="$STATE_ROOT/theme"
CONFIG_PATH="__HOME__/.codex/config.toml"
INJECTOR="$SCRIPT_DIR/injector.mjs"
INJECTOR_JOB_LABEL=com.openai.codex-dream-skin-studio.injector
NODE="${NODE:?}"
CODEX_APP_VALIDATED=false
CODEX_APP_CONTROL_VALIDATED=false
NODE_RUNTIME_VALIDATED=false
fail() { printf 'fixture: %s\n' "$*" >&2; exit 1; }
try_discover_codex_app() {
  [ "${FIXTURE_CODEX_AVAILABLE:-false}" = true ] || return 1
  CODEX_BUNDLE=/fixture/Codex.app
  CODEX_EXE=/fixture/Codex
  CODEX_VERSION=fixture
}
try_validate_codex_app_identity() {
  [ "${FIXTURE_CODEX_AVAILABLE:-false}" = true ] || return 1
  [ "${FIXTURE_CODEX_IDENTITY_INVALID:-false}" != true ] || return 1
  CODEX_APP_VALIDATED=true
  CODEX_APP_CONTROL_VALIDATED=true
  CODEX_TEAM_ID=TEAM
}
try_validate_codex_app_control_identity() { try_validate_codex_app_identity; }
try_require_macos_node_runtime() {
  [ "${FIXTURE_CODEX_AVAILABLE:-false}" = true ] || return 1
  NODE_RUNTIME_VALIDATED=true
}
native_restore_helper_identity() { printf 'native-identity\n'; }
require_lifecycle_lock() { :; }
release_lifecycle_lock() { :; }
cleanup_staged_theme_backup() { :; }
live_theme_backup_is_valid() { return 0; }
restored_theme_backup_is_valid() { return 1; }
renderer_rollback_evidence_is_valid() { [ -f "$ROLLBACK_STATE_PATH" ]; }
renderer_rollback_field() {
  case "$1" in
    schemaVersion) printf '%s\n' "${FIXTURE_ROLLBACK_SCHEMA:-2}" ;;
    port) printf '19473\n' ;;
    browserId) printf '%s\n' "${FIXTURE_ROLLBACK_BROWSER_ID:-Browser-A}" ;;
    launcher) printf '%s\n' "${FIXTURE_ROLLBACK_LAUNCHER:-direct}" ;;
    *) printf 'fixture\n' ;;
  esac
}
state_field() {
  case "$1" in
    port) printf '19473\n' ;;
    browserId) printf '%s\n' "${FIXTURE_STATE_BROWSER_ID:-Browser-A}" ;;
  esac
}
browser_id_is_valid() {
  [ -n "$1" ] && [ "${#1}" -le 200 ] || return 1
  case "$1" in *[!A-Za-z0-9._-]*) return 1 ;; esac
}
codex_is_running() { [ "${FIXTURE_CODEX_RUNNING:-false}" = true ]; }
verified_cdp_browser_id() {
  [ "${FIXTURE_CODEX_AVAILABLE:-false}" = true ] || return 1
  [ "${FIXTURE_ENDPOINT_VERIFIED:-true}" = true ] || return 1
  printf '%s\n' "${FIXTURE_ACTIVE_BROWSER_ID:-Browser-A}"
}
saved_managed_listener_is_absent() {
  printf 'listener-gate\n' >> "__MARKER__"
  [ "${FIXTURE_LISTENER_PRESENT:-false}" != true ] \
    && [ "${FIXTURE_LISTENER_UNCERTAIN:-false}" != true ]
}
stop_codex() {
  printf 'stop:%s\n' "$1" >> "__MARKER__"
  [ "${FIXTURE_STOP_TIMEOUT:-false}" != true ]
}
ensure_state_root() { printf 'ensure\n' >> "__MARKER__"; return 1; }
stop_renderer_rollback_watcher() {
  printf 'watcher-stop\n' >> "__MARKER__"
  /usr/bin/printf 'mutated watcher\n' > "$STATE_ROOT/watcher"
}
stop_recorded_injector() { printf 'state-stop\n' >> "__MARKER__"; }
release_codex_launchd_job() { printf 'launchd-release\n' >> "__MARKER__"; }
clear_renderer_rollback_evidence() { /bin/rm -f "$ROLLBACK_STATE_PATH"; }
STUB

reset_restore_fixture() {
  /usr/bin/printf 'config bytes\n' > "$RESTORE_HOME/.codex/config.toml"
  /usr/bin/printf 'state bytes\n' > "$RESTORE_STATE/state.json"
  /usr/bin/printf 'backup bytes\n' > "$RESTORE_STATE/theme-backup.json"
  /usr/bin/printf 'watcher bytes\n' > "$RESTORE_STATE/watcher"
  /bin/rm -f "$RESTORE_STATE/rollback.json"
  : > "$RESTORE_MARKER"
}

for evidence in ordinary rollback; do
  for listener in live absent; do
    reset_restore_fixture
    [ "$evidence" != rollback ] || /usr/bin/printf 'rollback bytes\n' > "$RESTORE_STATE/rollback.json"
    before="$(/usr/bin/shasum -a 256 "$RESTORE_HOME/.codex/config.toml" \
      "$RESTORE_STATE/state.json" "$RESTORE_STATE/theme-backup.json" "$RESTORE_STATE/watcher")"
    set +e
    /usr/bin/env HOME="$RESTORE_HOME" NODE="$NODE" \
      FIXTURE_LISTENER_PRESENT="$([ "$listener" = live ] && printf true || printf false)" \
      "$RESTORE_SCRIPTS/restore-dream-skin-macos.sh" --restore-base-theme \
      > "$RESTORE_FIXTURE/$evidence-$listener.out" 2> "$RESTORE_FIXTURE/$evidence-$listener.err"
    restore_exit="$?"
    set -e
    [ "$restore_exit" -ne 0 ]
    [ "$before" = "$(/usr/bin/shasum -a 256 "$RESTORE_HOME/.codex/config.toml" \
      "$RESTORE_STATE/state.json" "$RESTORE_STATE/theme-backup.json" "$RESTORE_STATE/watcher")" ]
    /usr/bin/grep -Fx 'listener-gate' "$RESTORE_MARKER" >/dev/null
    if [ "$listener" = live ]; then
      ! /usr/bin/grep -Fx 'ensure' "$RESTORE_MARKER" >/dev/null
    else
      /usr/bin/grep -Fx 'ensure' "$RESTORE_MARKER" >/dev/null
    fi
    ! /usr/bin/grep -Eq 'watcher-stop|state-stop|launchd-release' "$RESTORE_MARKER"
  done
done

reset_restore_fixture
set +e
/usr/bin/env HOME="$RESTORE_HOME" NODE="$NODE" FIXTURE_CODEX_AVAILABLE=true \
  FIXTURE_CODEX_RUNNING=true FIXTURE_ENDPOINT_VERIFIED=false FIXTURE_LISTENER_PRESENT=true \
  DREAM_SKIN_STUDIO_ADAPTER=true \
  "$RESTORE_SCRIPTS/restore-dream-skin-macos.sh" --restore-base-theme \
    --restart-codex --restart-authorized \
    > "$RESTORE_FIXTURE/unverified-running.out" \
    2> "$RESTORE_FIXTURE/unverified-running.err"
restore_exit="$?"
set -e
[ "$restore_exit" -ne 0 ]
[ "$(/bin/cat "$RESTORE_MARKER")" = 'listener-gate' ] \
  || { printf 'unverified running state was closed before listener absence proof.\n' >&2; exit 1; }

# Every saved-state shape closes a validated running Codex and then proves the
# exact saved port absent. A stopped/orphan session and listener enumeration
# uncertainty must prove absence before any mutation.
for evidence in ordinary schema2 schema3 schema4; do
  reset_restore_fixture
  rollback_launcher=direct
  rollback_schema=2
  if [ "$evidence" != ordinary ]; then
    rollback_schema="${evidence#schema}"
    [ "$evidence" != schema4 ] || rollback_launcher=managed-cdp
    /usr/bin/printf 'rollback bytes %s\n' "$evidence" > "$RESTORE_STATE/rollback.json"
  fi
  set +e
  /usr/bin/env HOME="$RESTORE_HOME" NODE="$NODE" FIXTURE_CODEX_AVAILABLE=true \
    FIXTURE_CODEX_RUNNING=true FIXTURE_LISTENER_PRESENT=true \
    FIXTURE_ROLLBACK_SCHEMA="$rollback_schema" FIXTURE_ROLLBACK_LAUNCHER="$rollback_launcher" \
    DREAM_SKIN_STUDIO_ADAPTER=true \
    "$RESTORE_SCRIPTS/restore-dream-skin-macos.sh" --restore-base-theme \
      --restart-codex --restart-authorized \
      > "$RESTORE_FIXTURE/$evidence-post-close.out" \
      2> "$RESTORE_FIXTURE/$evidence-post-close.err"
  restore_exit="$?"
  set -e
  [ "$restore_exit" -ne 0 ]
  [ "$(/bin/cat "$RESTORE_MARKER")" = $'stop:false\nlistener-gate' ] \
    || { /bin/cat "$RESTORE_FIXTURE/$evidence-post-close.err" >&2; printf '%s restore did not prove listener absence after close.\n' "$evidence" >&2; exit 1; }
done

for listener_case in live uncertain; do
  reset_restore_fixture
  listener_present=false
  listener_uncertain=false
  [ "$listener_case" != live ] || listener_present=true
  [ "$listener_case" != uncertain ] || listener_uncertain=true
  set +e
  /usr/bin/env HOME="$RESTORE_HOME" NODE="$NODE" FIXTURE_CODEX_AVAILABLE=true \
    FIXTURE_CODEX_RUNNING=false FIXTURE_LISTENER_PRESENT="$listener_present" \
    FIXTURE_LISTENER_UNCERTAIN="$listener_uncertain" \
    "$RESTORE_SCRIPTS/restore-dream-skin-macos.sh" --restore-base-theme \
      > "$RESTORE_FIXTURE/stopped-$listener_case.out" \
      2> "$RESTORE_FIXTURE/stopped-$listener_case.err"
  restore_exit="$?"
  set -e
  [ "$restore_exit" -ne 0 ]
  [ "$(/bin/cat "$RESTORE_MARKER")" = 'listener-gate' ] \
    || { printf 'stopped %s listener crossed the pre-mutation gate.\n' "$listener_case" >&2; exit 1; }
done

# State and rollback evidence describe one saved endpoint. A concrete mismatch,
# or a pending managed-CDP record whose state Browser ID does not match the live
# endpoint, must fail before listener probing, process closure, or mutation.
for browser_case in concrete-mismatch pending-live-mismatch; do
  reset_restore_fixture
  /usr/bin/printf 'rollback bytes\n' > "$RESTORE_STATE/rollback.json"
  rollback_browser=Browser-B
  rollback_launcher=direct
  active_browser=Browser-B
  if [ "$browser_case" = pending-live-mismatch ]; then
    rollback_browser=managed-cdp-pending
    rollback_launcher=managed-cdp
    active_browser=Browser-B
  fi
  set +e
  /usr/bin/env HOME="$RESTORE_HOME" NODE="$NODE" FIXTURE_CODEX_AVAILABLE=true \
    FIXTURE_CODEX_RUNNING=true FIXTURE_ROLLBACK_SCHEMA=4 \
    FIXTURE_ROLLBACK_LAUNCHER="$rollback_launcher" \
    FIXTURE_ROLLBACK_BROWSER_ID="$rollback_browser" \
    FIXTURE_STATE_BROWSER_ID=Browser-A FIXTURE_ACTIVE_BROWSER_ID="$active_browser" \
    DREAM_SKIN_STUDIO_ADAPTER=true \
    "$RESTORE_SCRIPTS/restore-dream-skin-macos.sh" --restore-base-theme \
      --restart-codex --restart-authorized \
      > "$RESTORE_FIXTURE/$browser_case.out" 2> "$RESTORE_FIXTURE/$browser_case.err"
  browser_exit="$?"
  set -e
  [ "$browser_exit" -ne 0 ]
  [ ! -s "$RESTORE_MARKER" ] \
    || { printf '%s Browser mismatch crossed the pre-close authority gate.\n' "$browser_case" >&2; exit 1; }
done

# A normal-quit timeout happens before rollback watcher or recovery bytes move.
reset_restore_fixture
/usr/bin/printf 'rollback bytes\n' > "$RESTORE_STATE/rollback.json"
timeout_before="$(/usr/bin/shasum -a 256 "$RESTORE_HOME/.codex/config.toml" \
  "$RESTORE_STATE/state.json" "$RESTORE_STATE/theme-backup.json" \
  "$RESTORE_STATE/rollback.json" "$RESTORE_STATE/watcher")"
set +e
/usr/bin/env HOME="$RESTORE_HOME" NODE="$NODE" FIXTURE_CODEX_AVAILABLE=true \
  FIXTURE_CODEX_RUNNING=true FIXTURE_STOP_TIMEOUT=true DREAM_SKIN_STUDIO_ADAPTER=true \
  "$RESTORE_SCRIPTS/restore-dream-skin-macos.sh" --restore-base-theme --restart-codex \
    --restart-authorized > "$RESTORE_FIXTURE/timeout.out" 2> "$RESTORE_FIXTURE/timeout.err"
timeout_exit="$?"
set -e
[ "$timeout_exit" -ne 0 ]
[ "$(/bin/cat "$RESTORE_MARKER")" = 'stop:false' ]
[ "$timeout_before" = "$(/usr/bin/shasum -a 256 "$RESTORE_HOME/.codex/config.toml" \
  "$RESTORE_STATE/state.json" "$RESTORE_STATE/theme-backup.json" \
  "$RESTORE_STATE/rollback.json" "$RESTORE_STATE/watcher")" ]

# Managed-CDP rollback evidence is valid before a Browser ID exists and retains
# the selected non-default port for a later force-authorized Complete Restore.
EVIDENCE_HOME="$TMP/evidence/home"
/bin/mkdir -p "$EVIDENCE_HOME/Library/Application Support/CodexDreamSkinStudio/theme"
/usr/bin/env HOME="$EVIDENCE_HOME" NODE="$NODE" NODE_RUNTIME_VALIDATED=true /bin/bash -c '
  set -euo pipefail
  . "$1/scripts/common-macos.sh"
  NODE="$2"
  write_managed_cdp_recovery_evidence 19473
  renderer_rollback_evidence_is_valid
  [ "$(renderer_rollback_field schemaVersion)" = 4 ]
  [ "$(renderer_rollback_field launcher)" = managed-cdp ]
  [ "$(renderer_rollback_field port)" = 19473 ]
' _ "$ROOT" "$NODE"

# Strict Apply publishes close authority before launch and retains it across
# every early failure. State remains authoritative for a later verify failure.
START_FIXTURE="$TMP/start"
START_HOME="$START_FIXTURE/home"
START_SCRIPTS="$START_FIXTURE/scripts"
START_STATE="$START_HOME/state"
START_MARKER="$START_FIXTURE/marker"
START_LIVE="$START_FIXTURE/codex-live"
/bin/mkdir -p "$START_SCRIPTS" "$START_STATE/theme"
/usr/bin/sed 's|/usr/bin/open|/usr/bin/true|g' "$ROOT/scripts/start-dream-skin-macos.sh" \
  > "$START_SCRIPTS/start-dream-skin-macos.sh"
/usr/bin/sed \
  -e "s|__HOME__|$START_HOME|g" \
  -e "s|__SCRIPTS__|$START_SCRIPTS|g" \
  -e "s|__MARKER__|$START_MARKER|g" \
  -e "s|__LIVE__|$START_LIVE|g" \
  > "$START_SCRIPTS/common-macos.sh" <<'STUB'
SCRIPT_DIR="__SCRIPTS__"
PROJECT_ROOT="__HOME__/engine"
STATE_ROOT="__HOME__/state"
STATE_PATH="$STATE_ROOT/state.json"
ROLLBACK_STATE_PATH="$STATE_ROOT/rollback.json"
LIFECYCLE_LOCK_PATH="$STATE_ROOT/lifecycle.lock"
THEME_DIR="$STATE_ROOT/theme"
INJECTOR="$SCRIPT_DIR/injector.mjs"
INJECTOR_ERROR_LOG="$STATE_ROOT/injector-error.log"
APP_LOG="$STATE_ROOT/app.log"
APP_ERROR_LOG="$STATE_ROOT/app-error.log"
START_ERROR_LOG="$STATE_ROOT/start-error.log"
CODEX_BUNDLE="__HOME__/Codex.app"
CODEX_EXE="$CODEX_BUNDLE/Contents/MacOS/Codex"
NODE="$SCRIPT_DIR/node-stub"
SKIN_VERSION=1.3.1
fail() { printf 'fixture: %s\n' "$*" >&2; exit 1; }
ensure_state_root() { /bin/mkdir -p "$STATE_ROOT"; }
require_lifecycle_lock() { :; }
release_lifecycle_lock() { :; }
discover_codex_app() { :; }
require_macos_runtime() { :; }
state_field() {
  case "$1" in
    port) printf '19473\n' ;;
    browserId) printf 'Browser-A\n' ;;
  esac
}
browser_id_is_valid() {
  [ -n "$1" ] && [ "${#1}" -le 200 ] || return 1
  case "$1" in *[!A-Za-z0-9._-]*) return 1 ;; esac
}
renderer_rollback_evidence_is_valid() { [ -f "$ROLLBACK_STATE_PATH" ]; }
renderer_rollback_field() {
  case "$1" in
    schemaVersion) printf '4\n' ;;
    launcher) printf 'managed-cdp\n' ;;
    port) /usr/bin/cut -d: -f1 "$ROLLBACK_STATE_PATH" ;;
    browserId) /usr/bin/cut -d: -f2 "$ROLLBACK_STATE_PATH" ;;
  esac
}
write_managed_cdp_recovery_evidence() {
  /usr/bin/printf '%s:%s\n' "$1" "${2:-managed-cdp-pending}" > "$ROLLBACK_STATE_PATH"
}
clear_renderer_rollback_evidence() { /bin/rm -f "$ROLLBACK_STATE_PATH"; }
saved_managed_listener_is_absent() { [ ! -e "__LIVE__" ]; }
codex_is_running() {
  [ "${FIXTURE_EXISTING_CODEX:-false}" = true ] || [ -e "__LIVE__" ]
}
verified_cdp_browser_id() {
  [ -e "__LIVE__" ] || return 1
  [ "${FIXTURE_STAGE:-}" != browser ] || return 1
  printf 'Browser-A\n'
}
select_available_port() { printf '%s\n' "$1"; }
launch_codex_with_cdp() { : > "__LIVE__"; printf 'cdp-launch:%s\n' "$1" >> "__MARKER__"; }
wait_for_cdp() { [ "${FIXTURE_STAGE:-}" != wait ]; }
stop_codex() {
  if [ "${FIXTURE_CLOSE_TIMEOUT:-false}" = true ] && [ "${1:-false}" != true ]; then
    fail "Codex did not close within 15 seconds; explicit restart authorization is required for a forced stop."
  fi
  /bin/rm -f "__LIVE__"
  printf 'codex-stop:%s\n' "${1:-false}" >> "__MARKER__"
}
launch_codex_normally() { printf 'normal-launch\n' >> "__MARKER__"; }
codex_main_pids() { [ -e "__LIVE__" ] && printf '4242\n'; }
start_watcher() {
  [ "${FIXTURE_STAGE:-}" != watcher ] || return 1
  /usr/bin/printf 'state:%s:%s\n' "$1" "$2" > "$STATE_PATH"
  /bin/rm -f "$ROLLBACK_STATE_PATH"
  STARTED_WATCHER_PID=5151
  STARTED_WATCHER_AT=fixture-start
}
stop_recorded_injector() { printf 'watcher-stop\n' >> "__MARKER__"; }
verified_cdp_endpoint() { [ -e "__LIVE__" ]; }
STUB
/usr/bin/sed > "$START_SCRIPTS/node-stub" <<'STUB'
#!/bin/bash
case "$*" in
  *--verify*) exit 41 ;;
  *--remove*) exit 0 ;;
  *) exit 0 ;;
esac
STUB
: > "$START_SCRIPTS/injector.mjs"
/bin/chmod 755 "$START_SCRIPTS/start-dream-skin-macos.sh" "$START_SCRIPTS/node-stub"

reset_start_fixture() {
  /bin/rm -f "$START_STATE/state.json" "$START_STATE/rollback.json" "$START_LIVE" \
    "$START_STATE/start-error.log"
  : > "$START_MARKER"
}

for early_stage in wait browser watcher; do
  reset_start_fixture
  set +e
  /usr/bin/env HOME="$START_HOME" FIXTURE_STAGE="$early_stage" FIXTURE_CLOSE_TIMEOUT=true \
    "$START_SCRIPTS/start-dream-skin-macos.sh" --studio-strict-verify --port 19473 \
    > "$START_FIXTURE/$early_stage.out" 2> "$START_FIXTURE/$early_stage.err"
  start_exit="$?"
  set -e
  [ "$start_exit" -ne 0 ]
  [ -f "$START_STATE/rollback.json" ] && [ ! -e "$START_STATE/state.json" ]
  /usr/bin/grep -F '19473:' "$START_STATE/rollback.json" >/dev/null
  [ -e "$START_LIVE" ]
done

: > "$START_MARKER"
set +e
/usr/bin/env HOME="$START_HOME" FIXTURE_STAGE=wait FIXTURE_CLOSE_TIMEOUT=true \
  "$START_SCRIPTS/start-dream-skin-macos.sh" --studio-strict-verify --port 19473 \
    --force-stop-authorized > "$START_FIXTURE/force.out" 2> "$START_FIXTURE/force.err"
force_exit="$?"
set -e
[ "$force_exit" -ne 0 ]
[ ! -e "$START_STATE/rollback.json" ] && [ ! -e "$START_STATE/state.json" ] && [ ! -e "$START_LIVE" ] \
  || { /bin/cat "$START_FIXTURE/force.err" >&2; /bin/cat "$START_MARKER" >&2; exit 1; }
/usr/bin/grep -Fx 'codex-stop:true' "$START_MARKER" >/dev/null
/usr/bin/grep -Fx 'normal-launch' "$START_MARKER" >/dev/null

# The same evidence is consumable through production status -> adapter ->
# start. Only low-level app/CDP/process functions are stubbed; neither status
# nor the adapter nor the start child is replaced.
ADAPTER_RECOVERY="$TMP/adapter-recovery"
ADAPTER_RECOVERY_HOME="$ADAPTER_RECOVERY/home"
ADAPTER_RECOVERY_BUNDLED="$ADAPTER_RECOVERY_HOME/engine"
ADAPTER_RECOVERY_INSTALLED="$ADAPTER_RECOVERY_HOME/.codex/codex-dream-skin-studio"
ADAPTER_RECOVERY_STATE="$ADAPTER_RECOVERY_HOME/Library/Application Support/CodexDreamSkinStudio"
ADAPTER_RECOVERY_MARKER="$ADAPTER_RECOVERY/marker"
ADAPTER_RECOVERY_LIVE="$ADAPTER_RECOVERY/codex-live"
ADAPTER_RECOVERY_BUNDLE="$ADAPTER_RECOVERY_HOME/Applications/ChatGPT.app"
for engine_root in "$ADAPTER_RECOVERY_BUNDLED" "$ADAPTER_RECOVERY_INSTALLED"; do
  /bin/mkdir -p "$engine_root/bin" "$engine_root/scripts"
  /bin/cp "$ROOT/VERSION" "$engine_root/VERSION"
  /bin/cp /usr/bin/true "$engine_root/bin/dream-skin-config-restore"
  /bin/cp "$ROOT/scripts/studio-adapter-macos.sh" \
    "$ROOT/scripts/status-dream-skin-macos.sh" "$ROOT/scripts/start-dream-skin-macos.sh" \
    "$engine_root/scripts/"
  for script in pause-dream-skin-macos.sh restore-dream-skin-macos.sh verify-dream-skin-macos.sh; do
    /usr/bin/printf '#!/bin/bash\nexit 0\n' > "$engine_root/scripts/$script"
  done
  : > "$engine_root/scripts/injector.mjs"
  : > "$engine_root/scripts/theme-config.mjs"
  /bin/chmod 755 "$engine_root/scripts/"*.sh "$engine_root/bin/dream-skin-config-restore"
done
/bin/mkdir -p "$ADAPTER_RECOVERY_STATE/theme" "$ADAPTER_RECOVERY_HOME/.codex" \
  "$ADAPTER_RECOVERY_BUNDLE/Contents/MacOS"
/usr/bin/printf '[desktop]\n' > "$ADAPTER_RECOVERY_HOME/.codex/config.toml"
/usr/bin/printf 'valid\n' > "$ADAPTER_RECOVERY_STATE/theme-backup.json"
/usr/bin/printf '{"name":"Fixture"}\n' > "$ADAPTER_RECOVERY_STATE/theme/theme.json"
/usr/bin/printf '{"port":19473,"session":"paused","injectorPid":0,"browserId":"Browser-A"}\n' \
  > "$ADAPTER_RECOVERY_STATE/state.json"
: > "$ADAPTER_RECOVERY_BUNDLE/Contents/MacOS/ChatGPT"
/bin/chmod 755 "$ADAPTER_RECOVERY_BUNDLE/Contents/MacOS/ChatGPT"
/usr/bin/plutil -create xml1 "$ADAPTER_RECOVERY_BUNDLE/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string com.openai.codex \
  "$ADAPTER_RECOVERY_BUNDLE/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string ChatGPT \
  "$ADAPTER_RECOVERY_BUNDLE/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string fixture \
  "$ADAPTER_RECOVERY_BUNDLE/Contents/Info.plist"

/usr/bin/sed \
  -e "s|__HOME__|$ADAPTER_RECOVERY_HOME|g" \
  -e "s|__BUNDLED__|$ADAPTER_RECOVERY_BUNDLED|g" \
  -e "s|__INSTALLED__|$ADAPTER_RECOVERY_INSTALLED|g" \
  -e "s|__STATE__|$ADAPTER_RECOVERY_STATE|g" \
  -e "s|__MARKER__|$ADAPTER_RECOVERY_MARKER|g" \
  -e "s|__LIVE__|$ADAPTER_RECOVERY_LIVE|g" \
  > "$ADAPTER_RECOVERY/common-macos.sh" <<'STUB'
SCRIPT_DIR="__INSTALLED__/scripts"
PROJECT_ROOT="__BUNDLED__"
INSTALL_ROOT="__INSTALLED__"
STATE_ROOT="__STATE__"
STATE_PATH="$STATE_ROOT/state.json"
ROLLBACK_STATE_PATH="$STATE_ROOT/rollback.json"
LIFECYCLE_LOCK_PATH="$STATE_ROOT/lifecycle.lock"
THEME_BACKUP_PATH="$STATE_ROOT/theme-backup.json"
RESTORED_THEME_BACKUP_PATH="$STATE_ROOT/theme-backup.restored.json"
THEME_DIR="$STATE_ROOT/theme"
CONFIG_PATH="__HOME__/.codex/config.toml"
INJECTOR="$SCRIPT_DIR/injector.mjs"
INJECTOR_ERROR_LOG="$STATE_ROOT/injector-error.log"
APP_LOG="$STATE_ROOT/app.log"
APP_ERROR_LOG="$STATE_ROOT/app-error.log"
START_ERROR_LOG="$STATE_ROOT/start-error.log"
NODE="$SCRIPT_DIR/node-stub"
SKIN_VERSION=1.3.1
CODEX_APP_VALIDATED=true
CODEX_APP_CONTROL_VALIDATED=true
NODE_RUNTIME_VALIDATED=true
fail() { printf 'fixture: %s\n' "$*" >&2; exit 1; }
ensure_state_root() { /bin/mkdir -p "$STATE_ROOT"; }
acquire_lifecycle_lock() { return 0; }
require_lifecycle_lock() { return 0; }
release_lifecycle_lock() { return 0; }
lifecycle_lock_is_busy() { return 1; }
try_discover_codex_app() { CODEX_BUNDLE="$CODEX_APP_BUNDLE"; CODEX_EXE="$CODEX_BUNDLE/Contents/MacOS/ChatGPT"; return 0; }
try_validate_codex_app_control_identity() { CODEX_APP_CONTROL_VALIDATED=true; return 0; }
discover_codex_app() { try_discover_codex_app; }
require_macos_runtime() { :; }
theme_backup_is_valid() { [ -f "$1" ] && [ ! -L "$1" ]; }
live_theme_backup_is_valid() { theme_backup_is_valid "$THEME_BACKUP_PATH"; }
restored_theme_backup_is_valid() { theme_backup_is_valid "$RESTORED_THEME_BACKUP_PATH"; }
state_field() {
  case "$1" in
    port) printf '19473\n' ;;
    browserId) printf 'Browser-A\n' ;;
  esac
}
browser_id_is_valid() {
  [ -n "$1" ] && [ "${#1}" -le 200 ] || return 1
  case "$1" in *[!A-Za-z0-9._-]*) return 1 ;; esac
}
renderer_rollback_evidence_is_valid() { [ -f "$ROLLBACK_STATE_PATH" ] && [ ! -L "$ROLLBACK_STATE_PATH" ]; }
renderer_rollback_field() {
  case "$1" in
    schemaVersion) printf '4\n' ;;
    launcher) printf 'managed-cdp\n' ;;
    port) /usr/bin/cut -d: -f1 "$ROLLBACK_STATE_PATH" ;;
    browserId) /usr/bin/cut -d: -f2 "$ROLLBACK_STATE_PATH" ;;
  esac
}
write_managed_cdp_recovery_evidence() { /usr/bin/printf '%s:%s\n' "$1" "${2:-managed-cdp-pending}" > "$ROLLBACK_STATE_PATH"; }
clear_renderer_rollback_evidence() { /bin/rm -f "$ROLLBACK_STATE_PATH"; }
saved_managed_listener_is_absent() { [ ! -e "__LIVE__" ]; }
codex_is_running() { [ -e "__LIVE__" ]; }
verified_cdp_browser_id() { [ -e "__LIVE__" ] || return 1; printf 'Browser-A\n'; }
select_available_port() { printf '%s\n' "$1"; }
launch_codex_with_cdp() { : > "__LIVE__"; printf 'cdp-launch:%s\n' "$1" >> "__MARKER__"; }
wait_for_cdp() { return 1; }
stop_codex() {
  if [ "${FIXTURE_CLOSE_TIMEOUT:-false}" = true ] && [ "${1:-false}" != true ]; then
    fail "Codex did not close within 15 seconds; explicit restart authorization is required for a forced stop."
  fi
  /bin/rm -f "__LIVE__"
  printf 'codex-stop:%s\n' "${1:-false}" >> "__MARKER__"
}
launch_codex_normally() { printf 'normal-launch\n' >> "__MARKER__"; }
codex_main_pids() { [ -e "__LIVE__" ] && printf '4242\n'; }
stop_recorded_injector() { return 0; }
STUB
for engine_root in "$ADAPTER_RECOVERY_BUNDLED" "$ADAPTER_RECOVERY_INSTALLED"; do
  /bin/cp "$ADAPTER_RECOVERY/common-macos.sh" "$engine_root/scripts/common-macos.sh"
  /usr/bin/sed 's|/usr/bin/open|/usr/bin/true|g' "$ROOT/scripts/start-dream-skin-macos.sh" \
    > "$engine_root/scripts/start-dream-skin-macos.sh"
  /usr/bin/printf '#!/bin/bash\nexit 0\n' > "$engine_root/scripts/node-stub"
  /bin/chmod 755 "$engine_root/scripts/start-dream-skin-macos.sh" "$engine_root/scripts/node-stub"
done

set +e
/usr/bin/env HOME="$ADAPTER_RECOVERY_HOME" CODEX_APP_BUNDLE="$ADAPTER_RECOVERY_BUNDLE" \
  FIXTURE_CLOSE_TIMEOUT=true \
  "$ADAPTER_RECOVERY_BUNDLED/scripts/studio-adapter-macos.sh" apply --restart-authorized \
  > "$ADAPTER_RECOVERY/first.json" 2> "$ADAPTER_RECOVERY/first.err"
adapter_first_exit="$?"
set -e
[ "$adapter_first_exit" -eq 1 ]
"$NODE" -e '
  const value = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  if (value.error?.code !== "FORCE_STOP_REQUIRED") process.exit(1);
' "$ADAPTER_RECOVERY/first.json"
[ "$(/bin/cat "$ADAPTER_RECOVERY_STATE/rollback.json")" = '19473:managed-cdp-pending' ]
adapter_recovery_hash="$(/usr/bin/shasum -a 256 "$ADAPTER_RECOVERY_STATE/rollback.json")"
: > "$ADAPTER_RECOVERY_MARKER"
set +e
/usr/bin/env HOME="$ADAPTER_RECOVERY_HOME" CODEX_APP_BUNDLE="$ADAPTER_RECOVERY_BUNDLE" \
  FIXTURE_CLOSE_TIMEOUT=true \
  "$ADAPTER_RECOVERY_BUNDLED/scripts/studio-adapter-macos.sh" apply \
    --restart-authorized --force-authorized \
  > "$ADAPTER_RECOVERY/second.json" 2> "$ADAPTER_RECOVERY/second.err"
adapter_second_exit="$?"
set -e
[ "$adapter_second_exit" -eq 1 ]
[ "$adapter_recovery_hash" != "$(/usr/bin/shasum -a 256 "$ADAPTER_RECOVERY_STATE/rollback.json" 2>/dev/null || true)" ]
[ ! -e "$ADAPTER_RECOVERY_STATE/rollback.json" ]
/usr/bin/grep -Fx 'codex-stop:true' "$ADAPTER_RECOVERY_MARKER" >/dev/null

: > "$START_MARKER"
set +e
/usr/bin/env HOME="$START_HOME" FIXTURE_STAGE=verify FIXTURE_CLOSE_TIMEOUT=true \
  "$START_SCRIPTS/start-dream-skin-macos.sh" --studio-strict-verify --port 19473 \
  > "$START_FIXTURE/verify-timeout.out" 2> "$START_FIXTURE/verify-timeout.err"
verify_timeout_exit="$?"
set -e
[ "$verify_timeout_exit" -ne 0 ]
[ -f "$START_STATE/state.json" ] && [ ! -e "$START_STATE/rollback.json" ] && [ -e "$START_LIVE" ]
/usr/bin/grep -Fx 'watcher-stop' "$START_MARKER" >/dev/null

: > "$START_MARKER"
set +e
/usr/bin/env HOME="$START_HOME" FIXTURE_STAGE=verify FIXTURE_CLOSE_TIMEOUT=true \
  "$START_SCRIPTS/start-dream-skin-macos.sh" --studio-strict-verify --port 19473 \
    --force-stop-authorized > "$START_FIXTURE/verify-force.out" 2> "$START_FIXTURE/verify-force.err"
verify_force_exit="$?"
set -e
[ "$verify_force_exit" -ne 0 ]
[ ! -e "$START_STATE/state.json" ] && [ ! -e "$START_STATE/rollback.json" ] && [ ! -e "$START_LIVE" ]
/usr/bin/grep -Fx 'codex-stop:true' "$START_MARKER" >/dev/null
/usr/bin/grep -Fx 'normal-launch' "$START_MARKER" >/dev/null

# A matching existing CDP keeps its prior state until the replacement watcher
# publishes state. The failed watcher must not erase the non-default port or
# Browser authority.
for prior_session in active paused; do
  reset_start_fixture
  /usr/bin/printf 'prior-state:%s:19473:Browser-A\n' "$prior_session" > "$START_STATE/state.json"
  : > "$START_LIVE"
  prior_state_hash="$(/usr/bin/shasum -a 256 "$START_STATE/state.json")"
  set +e
  /usr/bin/env HOME="$START_HOME" FIXTURE_STAGE=watcher \
    "$START_SCRIPTS/start-dream-skin-macos.sh" --studio-strict-verify --port 19473 \
    > "$START_FIXTURE/hot-watcher-$prior_session.out" \
    2> "$START_FIXTURE/hot-watcher-$prior_session.err"
  hot_watcher_exit="$?"
  set -e
  [ "$hot_watcher_exit" -ne 0 ]
  [ "$prior_state_hash" = "$(/usr/bin/shasum -a 256 "$START_STATE/state.json")" ] \
    || { printf 'hot %s watcher failure discarded prior state authority.\n' "$prior_session" >&2; exit 1; }
  [ -e "$START_LIVE" ]
done

reset_start_fixture
set +e
/usr/bin/env HOME="$START_HOME" FIXTURE_EXISTING_CODEX=true \
  "$START_SCRIPTS/start-dream-skin-macos.sh" --studio-strict-verify --port 19473 \
  > "$START_FIXTURE/cancel.out" 2> "$START_FIXTURE/cancel.err"
cancel_exit="$?"
set -e
[ "$cancel_exit" -ne 0 ]
[ ! -e "$START_STATE/state.json" ] && [ ! -e "$START_STATE/rollback.json" ] \
  && [ ! -e "$START_LIVE" ] && [ ! -s "$START_MARKER" ]

# Exercise the real production preset staging and publication path with real
# receipts, while keeping outer install rollback out of the fixture.
REAL_PRESET_ROOT="$TMP/upgrade-real-presets"
REAL_PRESET_HOME="$REAL_PRESET_ROOT/home"
REAL_PRESET_PROJECT="$REAL_PRESET_ROOT/project"
REAL_PRESET_STATE="$REAL_PRESET_HOME/Library/Application Support/CodexDreamSkinStudio"
REAL_PRESET_SNAPSHOT="$REAL_PRESET_STATE/.upgrade-recovery.fixture"
REAL_PRESET_MARKER="$REAL_PRESET_ROOT/publication.triggered"
/bin/mkdir -p "$REAL_PRESET_PROJECT/scripts" "$REAL_PRESET_PROJECT/presets/preset-new" \
  "$REAL_PRESET_STATE/theme" "$REAL_PRESET_STATE/themes/preset-existing" \
  "$REAL_PRESET_SNAPSHOT/original"
/bin/cp "$ROOT/scripts/common-macos.sh" "$ROOT/scripts/theme-config.mjs" "$REAL_PRESET_PROJECT/scripts/"
/bin/cp "$ROOT/VERSION" "$REAL_PRESET_PROJECT/VERSION"
/usr/bin/printf '{"id":"preset-new","name":"New"}\n' > "$REAL_PRESET_PROJECT/presets/preset-new/theme.json"
/usr/bin/printf '{"name":"active original"}\n' > "$REAL_PRESET_STATE/theme/theme.json"
/usr/bin/printf 'preset original\n' > "$REAL_PRESET_STATE/themes/preset-existing/theme.json"
/bin/cp -pPR "$REAL_PRESET_STATE/themes" "$REAL_PRESET_SNAPSHOT/original/theme-library"
real_root_identity="$(/usr/bin/stat -f '%d:%i' "$REAL_PRESET_SNAPSHOT")"
real_library_identity="$(/usr/bin/stat -f '%d:%i' "$REAL_PRESET_STATE/themes")"
/usr/bin/printf 'present\n%s\nunused\n' "$real_library_identity" \
  > "$REAL_PRESET_SNAPSHOT/original/theme-library.state"
real_receipt="$("$NODE" "$REAL_PRESET_PROJECT/scripts/theme-config.mjs" upgrade-receipt-finalize \
  "$REAL_PRESET_SNAPSHOT" "$real_root_identity" "$REAL_PRESET_SNAPSHOT/original" original \
  theme-library.state "$REAL_PRESET_STATE/themes")"
IFS='|' read -r real_group_identity real_receipt_identity real_receipt_digest _ <<< "$real_receipt"
/usr/bin/sed -e '' > "$REAL_PRESET_PROJECT/scripts/publication-race.mjs" <<'STUB'
import fs from "node:fs/promises";
const realMkdir = fs.mkdir;
fs.mkdir = async (target, options) => {
  if (target === process.env.FIXTURE_PUBLISH_TARGET) {
    await realMkdir(target);
    await fs.writeFile(`${target}/foreign`, "foreign theme library\n");
    const stat = await fs.lstat(target, { bigint: true });
    await fs.writeFile(process.env.FIXTURE_PUBLISH_MARKER, `${stat.dev}:${stat.ino}\n`, { flag: "wx" });
  }
  return realMkdir(target, options);
};
STUB
real_active_before="$(/usr/bin/shasum -a 256 "$REAL_PRESET_STATE/theme/theme.json")"
set +e
/usr/bin/env HOME="$REAL_PRESET_HOME" NODE_OPTIONS="--import=$REAL_PRESET_PROJECT/scripts/publication-race.mjs" \
  FIXTURE_PUBLISH_TARGET="$REAL_PRESET_STATE/themes" FIXTURE_PUBLISH_MARKER="$REAL_PRESET_MARKER" \
  REAL_NODE="$NODE" REAL_SNAPSHOT="$REAL_PRESET_SNAPSHOT" REAL_ROOT_ID="$real_root_identity" \
  REAL_GROUP_ID="$real_group_identity" REAL_RECEIPT_ID="$real_receipt_identity" \
  REAL_RECEIPT_DIGEST="$real_receipt_digest" /bin/bash -c '
    set -euo pipefail
    . "$1/scripts/common-macos.sh"
    NODE="$REAL_NODE"
    UPGRADE_SNAPSHOT_ROOT="$REAL_SNAPSHOT"
    UPGRADE_SNAPSHOT_IDENTITY="$REAL_ROOT_ID"
    UPGRADE_ORIGINAL_GROUP_IDENTITY="$REAL_GROUP_ID"
    UPGRADE_ORIGINAL_RECEIPT_IDENTITY="$REAL_RECEIPT_ID"
    UPGRADE_ORIGINAL_RECEIPT_DIGEST="$REAL_RECEIPT_DIGEST"
    upgrade_path_identity() { /usr/bin/stat -f "%d:%i" "$1"; }
    upgrade_path_digest() { COPYFILE_DISABLE=1 /usr/bin/tar -cf - -C "$1" . 2>/dev/null | /usr/bin/shasum -a 256 | /usr/bin/awk "{print \$1}"; }
    record_upgrade_transaction_path() {
      MATCHED_UPGRADE_EXPECTED_GROUP="$("$NODE" "$SCRIPT_DIR/theme-config.mjs" upgrade-receipt-capture \
        "$UPGRADE_SNAPSHOT_ROOT" "$UPGRADE_SNAPSHOT_IDENTITY" "$2" "$1" present "$(upgrade_path_identity "$1")")"
    }
    upgrade_path_matches_any_expected() {
      "$NODE" "$SCRIPT_DIR/theme-config.mjs" upgrade-receipt-verify \
        "$UPGRADE_SNAPSHOT_ROOT" "$UPGRADE_SNAPSHOT_IDENTITY" \
        "$UPGRADE_SNAPSHOT_ROOT/$MATCHED_UPGRADE_EXPECTED_GROUP" auto "$2.state" "$1" identity >/dev/null
    }
    seed_bundled_presets
  ' _ "$REAL_PRESET_PROJECT" > "$REAL_PRESET_ROOT/seed.out" 2> "$REAL_PRESET_ROOT/seed.err"
real_preset_exit="$?"
set -e
[ "$real_preset_exit" -ne 0 ]
[ -f "$REAL_PRESET_MARKER" ] || { /bin/cat "$REAL_PRESET_ROOT/seed.err" >&2; exit 1; }
[ "$real_active_before" = "$(/usr/bin/shasum -a 256 "$REAL_PRESET_STATE/theme/theme.json")" ]
[ "$(/usr/bin/stat -f '%d:%i' "$REAL_PRESET_STATE/themes")" = "$(/bin/cat "$REAL_PRESET_MARKER")" ]
[ "$(/bin/cat "$REAL_PRESET_STATE/themes/foreign")" = 'foreign theme library' ]
[ "$(/bin/cat "$REAL_PRESET_SNAPSHOT/held-theme-library/preset-existing/theme.json")" = 'preset original' ]
real_stage="$(/usr/bin/find "$REAL_PRESET_SNAPSHOT" -maxdepth 1 -name 'staged-theme-library.*' -type d -print -quit)"
[ "$(/bin/cat "$real_stage/preset-new/theme.json")" = '{"id":"preset-new","name":"New"}' ]

# Every failed post-swap initializer restores both the old engine and exact
# config/backup evidence before returning control to Studio.
for fault in seed config payload theme-config previous-commit-swap snapshot-commit-swap \
  after-state-hold predeploy-rsync previous-before-publish engine-state-create \
  engine-state-chmod commit-new-engine-swap rollback-destination-creator \
  cleanup-root-final-swap; do
  if [ -n "${DREAM_SKIN_UPGRADE_FAULT_FILTER:-}" ] \
    && [ "$fault" != "$DREAM_SKIN_UPGRADE_FAULT_FILTER" ]; then
    case "$DREAM_SKIN_UPGRADE_FAULT_FILTER" in
      concurrent-*|same-byte-backup|engine-swap|previous-engine-swap|snapshot-*|state-swap|restored-proof-swap|partial-receipt|active-theme-swap|theme-library-swap|temporary-preexisting)
        [ "$fault" = seed ] || continue
        ;;
      *) continue ;;
    esac
  fi
  UPGRADE_ROOT="$TMP/upgrade-$fault"
  UPGRADE_HOME="$UPGRADE_ROOT/home"
  UPGRADE_BUNDLED="$UPGRADE_ROOT/bundled"
  UPGRADE_INSTALLED="$UPGRADE_HOME/.codex/codex-dream-skin-studio"
  UPGRADE_STATE="$UPGRADE_HOME/Library/Application Support/CodexDreamSkinStudio"
  /bin/mkdir -p "$UPGRADE_BUNDLED/scripts" "$UPGRADE_INSTALLED" \
    "$UPGRADE_STATE/theme" "$UPGRADE_HOME/.codex"
  /bin/cp "$ROOT/scripts/install-dream-skin-macos.sh" "$UPGRADE_BUNDLED/scripts/"
  /bin/cp "$ROOT/VERSION" "$UPGRADE_BUNDLED/VERSION"
  /usr/bin/printf 'old engine %s\n' "$fault" > "$UPGRADE_INSTALLED/old-engine"
  /usr/bin/printf 'config original %s\n' "$fault" > "$UPGRADE_HOME/.codex/config.toml"
  /usr/bin/printf 'backup original %s\n' "$fault" > "$UPGRADE_STATE/theme-backup.json"
  /usr/bin/printf 'restored original %s\n' "$fault" > "$UPGRADE_STATE/theme-backup.restored.json"
  /usr/bin/printf '{"name":"active original %s"}\n' "$fault" > "$UPGRADE_STATE/theme/theme.json"
  /bin/mkdir -p "$UPGRADE_STATE/themes/preset-existing"
  /usr/bin/printf 'preset original %s\n' "$fault" > "$UPGRADE_STATE/themes/preset-existing/theme.json"
  /usr/bin/printf 'state original %s\n' "$fault" > "$UPGRADE_STATE/state.json"
  /usr/bin/sed \
    -e "s|__NODE__|$UPGRADE_BUNDLED/scripts/node-stub|g" \
    > "$UPGRADE_BUNDLED/scripts/common-macos.sh" <<'STUB'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
INSTALL_ROOT="$HOME/.codex/codex-dream-skin-studio"
STATE_ROOT="$HOME/Library/Application Support/CodexDreamSkinStudio"
STATE_PATH="$STATE_ROOT/state.json"
THEME_BACKUP_PATH="$STATE_ROOT/theme-backup.json"
RESTORED_THEME_BACKUP_PATH="$STATE_ROOT/theme-backup.restored.json"
THEME_DIR="$STATE_ROOT/theme"
CONFIG_PATH="$HOME/.codex/config.toml"
INJECTOR="$SCRIPT_DIR/injector.mjs"
NODE="__NODE__"
SKIN_VERSION=1.3.1
CODEX_VERSION=fixture
NODE_VERSION=v22.0.0
fail() { printf 'fixture: %s\n' "$*" >&2; exit 1; }
require_lifecycle_lock() { :; }
release_lifecycle_lock() { :; }
discover_codex_app() { :; }
require_macos_runtime() { :; }
codex_is_running() { return 1; }
stop_recorded_injector() {
  if [ "${DREAM_SKIN_UPGRADE_FAULT:-}" = state-swap ]; then
    /usr/bin/printf 'state-swap\n' > "$HOME/../fault.triggered"
    old_identity="$(/usr/bin/stat -f '%d:%i' "$STATE_PATH")"
    /bin/cp -pP "$STATE_PATH" "$STATE_PATH.concurrent"
    new_identity="$(/usr/bin/stat -f '%d:%i' "$STATE_PATH.concurrent")"
    [ "$old_identity" != "$new_identity" ] || return 1
    /bin/mv "$STATE_PATH.concurrent" "$STATE_PATH"
    /usr/bin/printf '%s\n' "$new_identity" > "$HOME/../foreign.identity"
  fi
}
ensure_state_root() { /bin/mkdir -p "$STATE_ROOT"; [ -d "$STATE_ROOT" ] && [ ! -L "$STATE_ROOT" ]; }
seed_bundled_presets() {
  case "${DREAM_SKIN_UPGRADE_FAULT:-}" in
    previous-commit-swap|snapshot-commit-swap|cleanup-root-final-swap) return 0 ;;
    commit-new-engine-swap)
      /bin/mv "$INSTALL_ROOT" "$INSTALL_ROOT.transaction-owned"
      /bin/cp -pPR "$INSTALL_ROOT.transaction-owned" "$INSTALL_ROOT"
      /usr/bin/stat -f '%d:%i' "$INSTALL_ROOT" > "$HOME/../foreign.identity"
      /usr/bin/printf '%s\n' "$INSTALL_ROOT" > "$HOME/../foreign.path"
      /usr/bin/printf 'commit-new-engine-swap\n' > "$HOME/../fault.triggered"
      return 0
      ;;
  esac
  /usr/bin/printf 'config mutated\n' > "$CONFIG_PATH"
  /usr/bin/printf 'backup mutated\n' > "$THEME_BACKUP_PATH"
  /usr/bin/printf 'restored mutated\n' > "$RESTORED_THEME_BACKUP_PATH"
  /usr/bin/printf 'state mutated\n' > "$STATE_PATH"
  /usr/bin/printf '{"name":"active mutated"}\n' > "$THEME_DIR/theme.json"
  /bin/rm -rf "$STATE_ROOT/themes/preset-existing"
  /bin/mkdir -p "$STATE_ROOT/themes/preset-new"
  /usr/bin/printf 'preset new\n' > "$STATE_ROOT/themes/preset-new/theme.json"
  record_upgrade_transaction_path "$CONFIG_PATH" config
  record_upgrade_transaction_path "$THEME_BACKUP_PATH" live-backup
  record_upgrade_transaction_path "$RESTORED_THEME_BACKUP_PATH" restored-backup
  record_upgrade_transaction_path "$STATE_PATH" lifecycle-state
  record_upgrade_transaction_path "$THEME_DIR" active-theme
  record_upgrade_transaction_path "$STATE_ROOT/themes" theme-library
  /usr/bin/printf '%s\n' "${DREAM_SKIN_UPGRADE_FAULT:-none}" > "$HOME/../fault.triggered"
  case "${DREAM_SKIN_UPGRADE_FAULT:-}" in
    seed) return 1 ;;
    config) /bin/rm -f "$CONFIG_PATH"; record_upgrade_transaction_path "$CONFIG_PATH" config ;;
    concurrent-config)
      /usr/bin/printf 'concurrent config writer\n' > "$CONFIG_PATH.concurrent"
      /bin/mv "$CONFIG_PATH.concurrent" "$CONFIG_PATH"
      return 1
      ;;
    concurrent-backup)
      /usr/bin/printf 'concurrent backup writer\n' > "$THEME_BACKUP_PATH.concurrent"
      /bin/mv "$THEME_BACKUP_PATH.concurrent" "$THEME_BACKUP_PATH"
      return 1
      ;;
    same-byte-backup)
      old_identity="$(/usr/bin/stat -f '%d:%i' "$THEME_BACKUP_PATH")"
      /bin/cp -pP "$THEME_BACKUP_PATH" "$THEME_BACKUP_PATH.concurrent"
      new_identity="$(/usr/bin/stat -f '%d:%i' "$THEME_BACKUP_PATH.concurrent")"
      [ "$old_identity" != "$new_identity" ] || return 1
      /bin/mv "$THEME_BACKUP_PATH.concurrent" "$THEME_BACKUP_PATH"
      /usr/bin/printf '%s\n' "$new_identity" > "$HOME/../foreign.identity"
      return 1
      ;;
    engine-swap)
      /bin/mv "$INSTALL_ROOT" "$INSTALL_ROOT.foreign-owned"
      /bin/cp -pPR "$INSTALL_ROOT.foreign-owned" "$INSTALL_ROOT"
      /usr/bin/stat -f '%d:%i' "$INSTALL_ROOT" > "$HOME/../foreign.identity"
      return 1
      ;;
    previous-engine-swap)
      previous="$UPGRADE_SNAPSHOT_ROOT/previous-engine"
      [ -d "$previous" ] || return 1
      /bin/mv "$previous" "$previous.foreign-owned"
      /bin/cp -pPR "$previous.foreign-owned" "$previous"
      /usr/bin/stat -f '%d:%i' "$previous" > "$HOME/../foreign.identity"
      return 1
      ;;
    snapshot-swap)
      /bin/mv "$UPGRADE_SNAPSHOT_ROOT" "$UPGRADE_SNAPSHOT_ROOT.foreign-owned"
      /bin/cp -pPR "$UPGRADE_SNAPSHOT_ROOT.foreign-owned" "$UPGRADE_SNAPSHOT_ROOT"
      /usr/bin/stat -f '%d:%i' "$UPGRADE_SNAPSHOT_ROOT" > "$HOME/../foreign.identity"
      return 1
      ;;
    snapshot-entry-swap)
      entry="$UPGRADE_SNAPSHOT_ROOT/original/config"
      /bin/mv "$entry" "$entry.foreign-owned"
      /bin/cp -pP "$entry.foreign-owned" "$entry"
      /usr/bin/stat -f '%d:%i' "$entry" > "$HOME/../foreign.identity"
      return 1
      ;;
    snapshot-group-swap)
      /bin/mv "$UPGRADE_SNAPSHOT_ROOT/original" "$UPGRADE_SNAPSHOT_ROOT/original.foreign-owned"
      /bin/cp -pPR "$UPGRADE_SNAPSHOT_ROOT/original.foreign-owned" "$UPGRADE_SNAPSHOT_ROOT/original"
      /usr/bin/stat -f '%d:%i' "$UPGRADE_SNAPSHOT_ROOT/original" > "$HOME/../foreign.identity"
      return 1
      ;;
    snapshot-complete-swap)
      expected="$(/usr/bin/find "$UPGRADE_SNAPSHOT_ROOT" -maxdepth 1 -name '.expected.*' -type d -print -quit)"
      [ -n "$expected" ] || return 1
      /bin/mv "$expected/COMPLETE.json" "$expected/COMPLETE.json.foreign-owned"
      /bin/cp -pP "$expected/COMPLETE.json.foreign-owned" "$expected/COMPLETE.json"
      /usr/bin/stat -f '%d:%i' "$expected/COMPLETE.json" > "$HOME/../foreign.identity"
      return 1
      ;;
    restored-proof-swap)
      old_identity="$(/usr/bin/stat -f '%d:%i' "$RESTORED_THEME_BACKUP_PATH")"
      /bin/cp -pP "$RESTORED_THEME_BACKUP_PATH" "$RESTORED_THEME_BACKUP_PATH.concurrent"
      new_identity="$(/usr/bin/stat -f '%d:%i' "$RESTORED_THEME_BACKUP_PATH.concurrent")"
      [ "$old_identity" != "$new_identity" ] || return 1
      /bin/mv "$RESTORED_THEME_BACKUP_PATH.concurrent" "$RESTORED_THEME_BACKUP_PATH"
      /usr/bin/printf '%s\n' "$new_identity" > "$HOME/../foreign.identity"
      ;;
    partial-receipt)
      partial="$UPGRADE_SNAPSHOT_ROOT/.expected.partial"
      /bin/mkdir "$partial"
      /usr/bin/printf 'present\n%s\nunused\n' \
        "$(/usr/bin/stat -f '%d:%i' "$CONFIG_PATH")" > "$partial/config.state"
      /bin/cp -pP "$CONFIG_PATH" "$partial/config"
      /usr/bin/printf 'partial receipt foreign\n' > "$CONFIG_PATH.concurrent"
      /bin/mv "$CONFIG_PATH.concurrent" "$CONFIG_PATH"
      /usr/bin/stat -f '%d:%i' "$CONFIG_PATH" > "$HOME/../foreign.identity"
      return 1
      ;;
    active-theme-swap)
      /bin/mv "$THEME_DIR" "$THEME_DIR.foreign-owned"
      /bin/cp -pPR "$THEME_DIR.foreign-owned" "$THEME_DIR"
      /usr/bin/stat -f '%d:%i' "$THEME_DIR" > "$HOME/../foreign.identity"
      return 1
      ;;
    theme-library-swap)
      /bin/mv "$STATE_ROOT/themes" "$STATE_ROOT/themes.foreign-owned"
      /bin/cp -pPR "$STATE_ROOT/themes.foreign-owned" "$STATE_ROOT/themes"
      /usr/bin/stat -f '%d:%i' "$STATE_ROOT/themes" > "$HOME/../foreign.identity"
      return 1
      ;;
    rollback-destination-creator) return 1 ;;
  esac
}
STUB
  /usr/bin/sed "s|__REAL_NODE__|$NODE|g" > "$UPGRADE_BUNDLED/scripts/node-stub" <<'STUB'
#!/bin/bash
if [ "${DREAM_SKIN_UPGRADE_FAULT:-}" = cleanup-root-final-swap ] \
  && [ "${2:-}" = upgrade-consume-tree ]; then
  exec "__REAL_NODE__" "$(dirname "$0")/upgrade-consume-race.mjs" "$@"
fi
case "${2:-}" in upgrade-*) exec "__REAL_NODE__" "$@" ;; esac
case "${DREAM_SKIN_UPGRADE_FAULT:-}:$*" in
  payload:*--check-payload*) exit 31 ;;
  theme-config:*theme-config.mjs*) exit 32 ;;
esac
exit 0
STUB
  if [ "$fault" = cleanup-root-final-swap ]; then
    /usr/bin/sed > "$UPGRADE_BUNDLED/scripts/upgrade-consume-race.mjs" <<'RACE'
import fs from "node:fs/promises";
import path from "node:path";

const [, , themeConfig, mode, tree, identity] = process.argv;
if (mode !== "upgrade-consume-tree") throw new Error("Unexpected cleanup race mode.");
const { consumeUpgradeTree } = await import(themeConfig);
await consumeUpgradeTree(tree, identity, async (quarantine) => {
  const displaced = `${quarantine}.transaction-owned`;
  await fs.rename(quarantine, displaced);
  await fs.cp(displaced, quarantine, { recursive: true, preserveTimestamps: true });
  const foreign = await fs.lstat(quarantine, { bigint: true });
  const fixtureRoot = path.resolve(process.env.HOME, "..");
  await fs.writeFile(path.join(fixtureRoot, "foreign.identity"), `${foreign.dev}:${foreign.ino}\n`);
  await fs.writeFile(path.join(fixtureRoot, "foreign.path"), `${quarantine}\n`);
  await fs.writeFile(path.join(fixtureRoot, "cleanup.triggered"), "cleanup-root-final-swap\n");
});
RACE
  fi
  : > "$UPGRADE_BUNDLED/scripts/injector.mjs"
  /bin/cp "$ROOT/scripts/theme-config.mjs" "$UPGRADE_BUNDLED/scripts/theme-config.mjs"
  "$NODE" - "$UPGRADE_BUNDLED/scripts/install-dream-skin-macos.sh" <<'NODE_TEST'
const fs = require("node:fs");
const file = process.argv[2];
let source = fs.readFileSync(file, "utf8");
function replaceOnce(needle, replacement) {
  if (!source.includes(needle)) throw new Error(`fixture transform anchor missing: ${needle}`);
  source = source.replace(needle, replacement);
}
replaceOnce("  deploy_project\n", `  if [ "\${DREAM_SKIN_UPGRADE_FAULT:-}" = after-state-hold ]; then
    /usr/bin/printf 'after-state-hold\\n' > "$HOME/../fault.triggered"
    exit 61
  fi
  deploy_project
`);
replaceOnce("  /usr/bin/rsync -a \\\n", `  if [ "\${DREAM_SKIN_UPGRADE_FAULT:-}" = predeploy-rsync ]; then
    /usr/bin/printf 'predeploy-rsync\\n' > "$HOME/../fault.triggered"
    exit 62
  fi
  /usr/bin/rsync -a \\\n`);
replaceOnce(`  if ! /bin/mv "$temporary" "$INSTALL_ROOT"; then\n`, `  if [ "\${DREAM_SKIN_UPGRADE_FAULT:-}" = previous-before-publish ]; then
    /usr/bin/printf 'previous-before-publish\\n' > "$HOME/../fault.triggered"
    exit 63
  fi
  if ! /bin/mv "$temporary" "$INSTALL_ROOT"; then
`);
replaceOnce("  /usr/bin/printf '%s\\n%s\\n%s\\n%s\\n' \\\n", `  if [ "\${DREAM_SKIN_UPGRADE_FAULT:-}" = engine-state-create ]; then
    /bin/mkdir "$UPGRADE_SNAPSHOT_ROOT/engine.state"
    /usr/bin/printf 'engine-state-create\\n' > "$HOME/../fault.triggered"
  fi
  /usr/bin/printf '%s\\n%s\\n%s\\n%s\\n' \\\n`);
replaceOnce(`  /bin/chmod 600 "$UPGRADE_SNAPSHOT_ROOT/engine.state"\n`, `  if [ "\${DREAM_SKIN_UPGRADE_FAULT:-}" = engine-state-chmod ]; then
    /usr/bin/printf 'engine-state-chmod\\n' > "$HOME/../fault.triggered"
    false
  else
    /bin/chmod 600 "$UPGRADE_SNAPSHOT_ROOT/engine.state"
  fi
`);
fs.writeFileSync(file, source);
NODE_TEST
  if [ "$fault" = previous-commit-swap ] || [ "$fault" = snapshot-commit-swap ]; then
    /usr/bin/sed "s|__MODE__|$fault|g" > "$UPGRADE_BUNDLED/scripts/rm-race" <<'STUB'
#!/bin/bash
set -euo pipefail
target="${!#}"
case "__MODE__:$target" in
  previous-commit-swap:*.previous.*|snapshot-commit-swap:*/.upgrade-recovery.*)
    if [ ! -e "$HOME/../cleanup.triggered" ]; then
      /bin/mv "$target" "$target.transaction-owned"
      /bin/cp -pPR "$target.transaction-owned" "$target"
      /usr/bin/stat -f '%d:%i' "$target" > "$HOME/../foreign.identity"
      /usr/bin/printf '%s\n' "$target" > "$HOME/../foreign.path"
      /usr/bin/printf '__MODE__\n' > "$HOME/../cleanup.triggered"
    fi
    ;;
esac
exec /bin/rm "$@"
STUB
    /usr/bin/sed "s|/bin/rm|$UPGRADE_BUNDLED/scripts/rm-race|g" \
      "$UPGRADE_BUNDLED/scripts/install-dream-skin-macos.sh" \
      > "$UPGRADE_BUNDLED/scripts/install-dream-skin-macos.sh.next"
    /bin/mv "$UPGRADE_BUNDLED/scripts/install-dream-skin-macos.sh.next" \
      "$UPGRADE_BUNDLED/scripts/install-dream-skin-macos.sh"
    /usr/bin/sed "s|__MODE__|$fault|g" > "$UPGRADE_BUNDLED/scripts/mv-race" <<'STUB'
#!/bin/bash
set -euo pipefail
source="$1"
[ "$source" != -n ] || source="$2"
case "__MODE__:$source" in
  previous-commit-swap:*/.upgrade-recovery.*)
    candidate="$source/previous-engine"
    /bin/mv "$candidate" "$candidate.transaction-owned"
    /bin/cp -pPR "$candidate.transaction-owned" "$candidate"
    /usr/bin/stat -f '%d:%i' "$candidate" > "$HOME/../foreign.identity"
    /usr/bin/printf '%s\n' "$candidate" > "$HOME/../foreign.path"
    /usr/bin/printf '__MODE__\n' > "$HOME/../cleanup.triggered"
    ;;
  snapshot-commit-swap:*/.upgrade-recovery.*)
    /bin/mv "$source" "$source.transaction-owned"
    /bin/cp -pPR "$source.transaction-owned" "$source"
    /usr/bin/stat -f '%d:%i' "$source" > "$HOME/../foreign.identity"
    /usr/bin/printf '%s\n' "$source" > "$HOME/../foreign.path"
    /usr/bin/printf '__MODE__\n' > "$HOME/../cleanup.triggered"
    ;;
esac
exec /bin/mv "$@"
STUB
    /usr/bin/sed "s|/bin/mv|$UPGRADE_BUNDLED/scripts/mv-race|g" \
      "$UPGRADE_BUNDLED/scripts/install-dream-skin-macos.sh" \
      > "$UPGRADE_BUNDLED/scripts/install-dream-skin-macos.sh.next"
    /bin/mv "$UPGRADE_BUNDLED/scripts/install-dream-skin-macos.sh.next" \
      "$UPGRADE_BUNDLED/scripts/install-dream-skin-macos.sh"
    /bin/chmod 755 "$UPGRADE_BUNDLED/scripts/rm-race" "$UPGRADE_BUNDLED/scripts/mv-race"
  fi
  if [ "$fault" = rollback-destination-creator ]; then
    /usr/bin/sed > "$UPGRADE_BUNDLED/scripts/mv-race" <<'STUB'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = -n ] && [[ "${2:-}" == */.upgrade-recovery.*/previous-engine ]] \
  && [[ "${3:-}" == */codex-dream-skin-studio ]]; then
  /bin/mkdir "$3"
  /usr/bin/printf 'foreign rollback destination\n' > "$3/foreign"
  /usr/bin/stat -f '%d:%i' "$3" > "$HOME/../foreign.identity"
  /usr/bin/printf '%s\n' "$3" > "$HOME/../foreign.path"
  /usr/bin/printf 'rollback-destination-creator\n' > "$HOME/../cleanup.triggered"
fi
exec /bin/mv "$@"
STUB
    /usr/bin/sed "s|/bin/mv|$UPGRADE_BUNDLED/scripts/mv-race|g" \
      "$UPGRADE_BUNDLED/scripts/install-dream-skin-macos.sh" \
      > "$UPGRADE_BUNDLED/scripts/install-dream-skin-macos.sh.next"
    /bin/mv "$UPGRADE_BUNDLED/scripts/install-dream-skin-macos.sh.next" \
      "$UPGRADE_BUNDLED/scripts/install-dream-skin-macos.sh"
    /bin/chmod 755 "$UPGRADE_BUNDLED/scripts/mv-race"
  fi
  /bin/chmod 755 "$UPGRADE_BUNDLED/scripts/install-dream-skin-macos.sh" \
    "$UPGRADE_BUNDLED/scripts/node-stub"
  upgrade_before="$(/usr/bin/shasum -a 256 "$UPGRADE_INSTALLED/old-engine" \
    "$UPGRADE_HOME/.codex/config.toml" "$UPGRADE_STATE/theme-backup.json" \
    "$UPGRADE_STATE/theme-backup.restored.json" "$UPGRADE_STATE/state.json" \
    "$UPGRADE_STATE/theme/theme.json" "$UPGRADE_STATE/themes/preset-existing/theme.json")"
  set +e
  /usr/bin/env HOME="$UPGRADE_HOME" DREAM_SKIN_UPGRADE_FAULT="$fault" \
    "$UPGRADE_BUNDLED/scripts/install-dream-skin-macos.sh" --no-launchers --no-launch \
    > "$UPGRADE_ROOT/install.out" 2> "$UPGRADE_ROOT/install.err"
  upgrade_exit="$?"
  set -e
  case "$fault" in
    after-state-hold|predeploy-rsync|previous-before-publish|engine-state-create|engine-state-chmod)
      [ "$upgrade_exit" -ne 0 ] || { printf 'upgrade preservation fault %s unexpectedly succeeded.\n' "$fault" >&2; exit 1; }
      [ "$(/bin/cat "$UPGRADE_ROOT/fault.triggered")" = "$fault" ] \
        || { printf 'upgrade preservation fault %s did not reach its branch.\n' "$fault" >&2; exit 1; }
      snapshot="$(/usr/bin/find "$UPGRADE_STATE" -maxdepth 1 -name '.upgrade-recovery.*' -type d -print -quit)"
      state_copy="$(/usr/bin/find "$UPGRADE_HOME" -type f \
        \( -path '*/state.json' -o -name 'held-lifecycle-state' -o -name 'lifecycle-state' \) \
        -exec /usr/bin/grep -lFx "state original $fault" {} + | /usr/bin/head -n 1)"
      old_engine="$(/usr/bin/find "$UPGRADE_HOME" -type f -name old-engine \
        -exec /usr/bin/grep -lFx "old engine $fault" {} + | /usr/bin/head -n 1)"
      [ -n "$state_copy" ] && [ -n "$old_engine" ] || {
        printf 'upgrade preservation fault %s discarded lifecycle state or prior engine.\n' "$fault" >&2
        exit 1
      }
      if [ -z "$snapshot" ]; then
        [ "$state_copy" = "$UPGRADE_STATE/state.json" ] \
          && [ "$old_engine" = "$UPGRADE_INSTALLED/old-engine" ] || {
          printf 'upgrade preservation fault %s consumed its snapshot without exact public rollback.\n' "$fault" >&2
          exit 1
        }
      fi
      continue
      ;;
    commit-new-engine-swap)
      [ -f "$UPGRADE_ROOT/foreign.identity" ] || {
        /bin/cat "$UPGRADE_ROOT/install.err" >&2 || true
        printf 'commit-new-engine-swap fixture did not reach its race branch.\n' >&2
        exit 1
      }
      [ "$upgrade_exit" -ne 0 ] \
        || { printf 'upgrade terminal race commit-new-engine-swap committed a replaced new engine.\n' >&2; exit 1; }
      foreign_identity="$(/bin/cat "$UPGRADE_ROOT/foreign.identity")"
      foreign_path="$(/bin/cat "$UPGRADE_ROOT/foreign.path")"
      [ "$(/usr/bin/stat -f '%d:%i' "$foreign_path" 2>/dev/null || true)" = "$foreign_identity" ] \
        || { printf 'commit-new-engine-swap deleted its foreign replacement.\n' >&2; exit 1; }
      /usr/bin/find "$UPGRADE_STATE" -maxdepth 1 -name '.upgrade-recovery.*' -type d -print -quit \
        | /usr/bin/grep -q . || { printf 'commit-new-engine-swap discarded recovery snapshot.\n' >&2; exit 1; }
      /usr/bin/find "$UPGRADE_HOME" -type f -name old-engine \
        -exec /usr/bin/grep -lFx 'old engine commit-new-engine-swap' {} + | /usr/bin/grep -q . \
        || { printf 'commit-new-engine-swap discarded the prior engine.\n' >&2; exit 1; }
      continue
      ;;
    rollback-destination-creator)
      [ "$upgrade_exit" -ne 0 ]
      [ "$(/bin/cat "$UPGRADE_ROOT/cleanup.triggered")" = rollback-destination-creator ]
      foreign_path="$(/bin/cat "$UPGRADE_ROOT/foreign.path")"
      foreign_identity="$(/bin/cat "$UPGRADE_ROOT/foreign.identity")"
      [ "$(/usr/bin/stat -f '%d:%i' "$foreign_path" 2>/dev/null || true)" = "$foreign_identity" ] \
        && [ "$(/bin/cat "$foreign_path/foreign")" = 'foreign rollback destination' ] \
        || { printf 'rollback destination race changed its foreign creator.\n' >&2; exit 1; }
      /usr/bin/find "$UPGRADE_HOME" -type f -name old-engine -print -quit | /usr/bin/grep -q . \
        && /usr/bin/find "$UPGRADE_STATE" -maxdepth 1 -name '.upgrade-recovery.*' -type d -print -quit \
          | /usr/bin/grep -q . \
        || { printf 'rollback destination race consumed prior engine or recovery snapshot.\n' >&2; exit 1; }
      continue
      ;;
    cleanup-root-final-swap)
      [ "$upgrade_exit" -ne 0 ] \
        || { printf 'cleanup-root-final-swap deleted a post-proof foreign cleanup root.\n' >&2; exit 1; }
      [ "$(/bin/cat "$UPGRADE_ROOT/cleanup.triggered")" = cleanup-root-final-swap ]
      foreign_identity="$(/bin/cat "$UPGRADE_ROOT/foreign.identity")"
      foreign_path="$(/bin/cat "$UPGRADE_ROOT/foreign.path")"
      [ "$(/usr/bin/stat -f '%d:%i' "$foreign_path" 2>/dev/null || true)" = "$foreign_identity" ] \
        || { printf 'cleanup-root-final-swap deleted its foreign replacement.\n' >&2; exit 1; }
      /usr/bin/find "$UPGRADE_HOME" -path '*.transaction-owned/snapshot' -type d -print -quit \
        | /usr/bin/grep -q . || { printf 'cleanup-root-final-swap discarded its exact recovery snapshot.\n' >&2; exit 1; }
      continue
      ;;
  esac
  if [ "$fault" = previous-commit-swap ] || [ "$fault" = snapshot-commit-swap ]; then
    [ "$upgrade_exit" -ne 0 ] || { printf 'upgrade cleanup race %s did not fail closed.\n' "$fault" >&2; exit 1; }
    [ "$(/bin/cat "$UPGRADE_ROOT/cleanup.triggered")" = "$fault" ] \
      || { printf 'upgrade cleanup race %s did not reach its branch.\n' "$fault" >&2; exit 1; }
    foreign_identity="$(/bin/cat "$UPGRADE_ROOT/foreign.identity")"
    foreign_path="$(/usr/bin/find "$UPGRADE_HOME" -inum "${foreign_identity#*:}" -print -quit)"
    if [ -z "$foreign_path" ] \
      || [ "$(/usr/bin/stat -f '%d:%i' "$foreign_path" 2>/dev/null || true)" != "$foreign_identity" ]; then
      printf 'upgrade cleanup race %s deleted its foreign replacement.\n' "$fault" >&2
      exit 1
    fi
    continue
  fi
  [ "$upgrade_exit" -ne 0 ]
  [ -f "$UPGRADE_INSTALLED/old-engine" ] \
    || { /bin/cat "$UPGRADE_ROOT/install.err" >&2; exit 1; }
  [ "$upgrade_before" = "$(/usr/bin/shasum -a 256 "$UPGRADE_INSTALLED/old-engine" \
    "$UPGRADE_HOME/.codex/config.toml" "$UPGRADE_STATE/theme-backup.json" \
    "$UPGRADE_STATE/theme-backup.restored.json" "$UPGRADE_STATE/state.json" \
    "$UPGRADE_STATE/theme/theme.json" "$UPGRADE_STATE/themes/preset-existing/theme.json")" ]
  [ ! -e "$UPGRADE_STATE/themes/preset-new" ]
  if /usr/bin/find "$UPGRADE_HOME" \( -name '.upgrade-recovery.*' \
      -o -name 'codex-dream-skin-studio.previous.*' \
      -o -name 'codex-dream-skin-studio.failed.*' \) -print | /usr/bin/grep -q .; then
    printf 'Upgrade %s left transaction output behind.\n' "$fault" >&2
    exit 1
  fi
done

for fault in concurrent-config concurrent-backup same-byte-backup engine-swap previous-engine-swap \
  snapshot-swap snapshot-entry-swap snapshot-group-swap snapshot-complete-swap \
  state-swap restored-proof-swap partial-receipt active-theme-swap theme-library-swap \
  temporary-preexisting; do
  [ -z "${DREAM_SKIN_UPGRADE_FAULT_FILTER:-}" ] \
    || [ "$fault" = "$DREAM_SKIN_UPGRADE_FAULT_FILTER" ] || continue
  UPGRADE_ROOT="$TMP/upgrade-race-$fault"
  UPGRADE_HOME="$UPGRADE_ROOT/home"
  UPGRADE_BUNDLED="$UPGRADE_ROOT/bundled"
  UPGRADE_INSTALLED="$UPGRADE_HOME/.codex/codex-dream-skin-studio"
  UPGRADE_STATE="$UPGRADE_HOME/Library/Application Support/CodexDreamSkinStudio"
  /bin/mkdir -p "$UPGRADE_BUNDLED/scripts" "$UPGRADE_INSTALLED" \
    "$UPGRADE_STATE/theme" "$UPGRADE_STATE/themes/preset-existing" "$UPGRADE_HOME/.codex"
  /bin/cp "$ROOT/scripts/install-dream-skin-macos.sh" "$ROOT/scripts/theme-config.mjs" \
    "$UPGRADE_BUNDLED/scripts/"
  /bin/cp "$ROOT/VERSION" "$UPGRADE_BUNDLED/VERSION"
  /usr/bin/printf 'old engine race %s\n' "$fault" > "$UPGRADE_INSTALLED/old-engine"
  /usr/bin/printf 'config original race %s\n' "$fault" > "$UPGRADE_HOME/.codex/config.toml"
  /usr/bin/printf 'backup original race %s\n' "$fault" > "$UPGRADE_STATE/theme-backup.json"
  /usr/bin/printf 'restored original race %s\n' "$fault" > "$UPGRADE_STATE/theme-backup.restored.json"
  /usr/bin/printf 'state original race %s\n' "$fault" > "$UPGRADE_STATE/state.json"
  /usr/bin/printf '{"name":"active race"}\n' > "$UPGRADE_STATE/theme/theme.json"
  /usr/bin/printf 'preset race\n' > "$UPGRADE_STATE/themes/preset-existing/theme.json"
  /usr/bin/sed -e "s|__NODE__|$UPGRADE_BUNDLED/scripts/node-stub|g" \
    -e "/^seed_bundled_presets()/,/^}/!d" \
    "$TMP/upgrade-seed/bundled/scripts/common-macos.sh" >/dev/null 2>&1 || true
  /bin/cp "$TMP/upgrade-seed/bundled/scripts/common-macos.sh" "$UPGRADE_BUNDLED/scripts/common-macos.sh"
  /usr/bin/sed "s|$TMP/upgrade-seed|$UPGRADE_ROOT|g; s|DREAM_SKIN_UPGRADE_FAULT:-seed|DREAM_SKIN_UPGRADE_FAULT:-$fault|g" \
    "$UPGRADE_BUNDLED/scripts/common-macos.sh" > "$UPGRADE_BUNDLED/scripts/common-macos.sh.next"
  /bin/mv "$UPGRADE_BUNDLED/scripts/common-macos.sh.next" "$UPGRADE_BUNDLED/scripts/common-macos.sh"
  /bin/cp "$TMP/upgrade-seed/bundled/scripts/node-stub" "$UPGRADE_BUNDLED/scripts/node-stub"
  : > "$UPGRADE_BUNDLED/scripts/injector.mjs"
  if [ "$fault" = temporary-preexisting ]; then
    /usr/bin/sed 's|local temporary="$INSTALL_ROOT.installing.$$"|local temporary="$INSTALL_ROOT.installing.fixture"|' \
      "$UPGRADE_BUNDLED/scripts/install-dream-skin-macos.sh" \
      > "$UPGRADE_BUNDLED/scripts/install-dream-skin-macos.sh.next"
    /bin/mv "$UPGRADE_BUNDLED/scripts/install-dream-skin-macos.sh.next" \
      "$UPGRADE_BUNDLED/scripts/install-dream-skin-macos.sh"
    /bin/mkdir "$UPGRADE_INSTALLED.installing.fixture"
    /usr/bin/printf 'foreign temporary engine\n' \
      > "$UPGRADE_INSTALLED.installing.fixture/foreign"
    /usr/bin/stat -f '%d:%i' "$UPGRADE_INSTALLED.installing.fixture" \
      > "$UPGRADE_ROOT/foreign.identity"
    /usr/bin/printf 'temporary-preexisting\n' > "$UPGRADE_ROOT/fault.triggered"
  fi
  /bin/chmod 755 "$UPGRADE_BUNDLED/scripts/install-dream-skin-macos.sh" \
    "$UPGRADE_BUNDLED/scripts/node-stub"
  set +e
  /usr/bin/env HOME="$UPGRADE_HOME" DREAM_SKIN_UPGRADE_FAULT="$fault" \
    "$UPGRADE_BUNDLED/scripts/install-dream-skin-macos.sh" --no-launchers --no-launch \
    > "$UPGRADE_ROOT/install.out" 2> "$UPGRADE_ROOT/install.err"
  race_exit="$?"
  set -e
  [ "$race_exit" -ne 0 ]
  [ "$(/bin/cat "$UPGRADE_ROOT/fault.triggered")" = "$fault" ] \
    || { printf 'upgrade race %s did not reach its fault branch.\n' "$fault" >&2; exit 1; }
  case "$fault" in
    concurrent-config) [ "$(/bin/cat "$UPGRADE_HOME/.codex/config.toml")" = 'concurrent config writer' ] ;;
    concurrent-backup) [ "$(/bin/cat "$UPGRADE_STATE/theme-backup.json")" = 'concurrent backup writer' ] ;;
    same-byte-backup)
      [ "$(/usr/bin/stat -f '%d:%i' "$UPGRADE_STATE/theme-backup.json")" = "$(/bin/cat "$UPGRADE_ROOT/foreign.identity")" ]
      [ "$(/bin/cat "$UPGRADE_STATE/theme-backup.json")" = 'backup mutated' ]
      ;;
    engine-swap)
      [ -d "$UPGRADE_INSTALLED" ] && [ -d "$UPGRADE_INSTALLED.foreign-owned" ]
      [ "$(/usr/bin/stat -f '%d:%i' "$UPGRADE_INSTALLED")" = "$(/bin/cat "$UPGRADE_ROOT/foreign.identity")" ]
      ;;
    previous-engine-swap)
      snapshot="$(/usr/bin/find "$UPGRADE_STATE" -maxdepth 1 -name '.upgrade-recovery.*' -type d -print -quit)"
      previous="$snapshot/previous-engine"
      [ -d "$previous" ]
      [ "$(/usr/bin/stat -f '%d:%i' "$previous")" = "$(/bin/cat "$UPGRADE_ROOT/foreign.identity")" ]
      [ -d "$previous.foreign-owned" ]
      ;;
    snapshot-swap)
      [ "$(/usr/bin/stat -f '%d:%i' "$(/usr/bin/find "$UPGRADE_STATE" -maxdepth 1 \
        -name '.upgrade-recovery.*' ! -name '*.foreign-owned' -type d -print -quit)")" = "$(/bin/cat "$UPGRADE_ROOT/foreign.identity")" ]
      /usr/bin/find "$UPGRADE_STATE" -maxdepth 1 -name '.upgrade-recovery.*.foreign-owned' -print -quit \
        | /usr/bin/grep -q .
      ;;
    snapshot-entry-swap|snapshot-group-swap|snapshot-complete-swap)
      snapshot="$(/usr/bin/find "$UPGRADE_STATE" -maxdepth 1 -name '.upgrade-recovery.*' -type d -print -quit)"
      [ -n "$snapshot" ]
      /usr/bin/find "$snapshot" -name '*.foreign-owned' -print -quit | /usr/bin/grep -q .
      ;;
    state-swap)
      [ "$(/usr/bin/stat -f '%d:%i' "$UPGRADE_STATE/state.json")" = "$(/bin/cat "$UPGRADE_ROOT/foreign.identity")" ]
      [ "$(/bin/cat "$UPGRADE_STATE/state.json")" = "state original race $fault" ]
      ;;
    restored-proof-swap)
      [ "$(/usr/bin/stat -f '%d:%i' "$UPGRADE_STATE/theme-backup.restored.json")" = "$(/bin/cat "$UPGRADE_ROOT/foreign.identity")" ]
      [ "$(/bin/cat "$UPGRADE_STATE/theme-backup.restored.json")" = 'restored mutated' ]
      ;;
    partial-receipt)
      [ "$(/usr/bin/stat -f '%d:%i' "$UPGRADE_HOME/.codex/config.toml")" = "$(/bin/cat "$UPGRADE_ROOT/foreign.identity")" ]
      [ "$(/bin/cat "$UPGRADE_HOME/.codex/config.toml")" = 'partial receipt foreign' ]
      ;;
    active-theme-swap)
      [ "$(/usr/bin/stat -f '%d:%i' "$UPGRADE_STATE/theme")" = "$(/bin/cat "$UPGRADE_ROOT/foreign.identity")" ]
      [ -d "$UPGRADE_STATE/theme.foreign-owned" ]
      ;;
    theme-library-swap)
      [ "$(/usr/bin/stat -f '%d:%i' "$UPGRADE_STATE/themes")" = "$(/bin/cat "$UPGRADE_ROOT/foreign.identity")" ]
      [ -d "$UPGRADE_STATE/themes.foreign-owned" ]
      ;;
    temporary-preexisting)
      [ "$(/usr/bin/stat -f '%d:%i' "$UPGRADE_INSTALLED.installing.fixture")" = "$(/bin/cat "$UPGRADE_ROOT/foreign.identity")" ]
      [ "$(/bin/cat "$UPGRADE_INSTALLED.installing.fixture/foreign")" = 'foreign temporary engine' ]
      ;;
  esac
  snapshot="$(/usr/bin/find "$UPGRADE_STATE" -maxdepth 1 -name '.upgrade-recovery.*' -type d -print -quit)"
  [ -n "$snapshot" ] \
    || { printf 'upgrade race %s discarded its recovery snapshot.\n' "$fault" >&2; exit 1; }
  /usr/bin/find "$snapshot" -type f \
    \( -name lifecycle-state -o -name held-lifecycle-state \) \
    -exec /usr/bin/grep -lFx "state original race $fault" {} + | /usr/bin/grep -q . \
    || { printf 'upgrade race %s discarded original lifecycle state.\n' "$fault" >&2; exit 1; }
  /usr/bin/find "$UPGRADE_HOME" -type f -name old-engine \
    -exec /usr/bin/grep -lFx "old engine race $fault" {} + | /usr/bin/grep -q . \
    || { printf 'upgrade race %s discarded the prior engine.\n' "$fault" >&2; exit 1; }
done

printf 'PASS: macOS V4 lifecycle behavior verified.\n'
