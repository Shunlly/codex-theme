#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(/usr/bin/mktemp -d /tmp/codex-dream-skin-launcher-entry.XXXXXX)"
trap '/bin/rm -rf "$TMP"' EXIT

make_mv_wrapper() {
  local wrapper="$1"
  /usr/bin/sed > "$wrapper" <<'STUB'
#!/bin/bash
set -euo pipefail
source_path="$1"
destination_path="$2"
case "${LAUNCHER_RACE_MODE:-}:$source_path:$destination_path" in
  before:*Codex\ Dream\ Skin.command:*entry|late:*Codex\ Dream\ Skin.command:*entry)
    /bin/mv "$source_path" "$source_path.owned-original"
    /bin/cp -pP "$source_path.owned-original" "$source_path"
    /usr/bin/stat -f '%d:%i' "$source_path" > "$HOME/replacement.identity"
    ;;
esac
/bin/mv "$source_path" "$destination_path"
case "${LAUNCHER_RACE_MODE:-}:$source_path:$destination_path" in
  after:*Codex\ Dream\ Skin.command:*entry)
    /bin/cp -pP "$destination_path" "$source_path"
    /usr/bin/stat -f '%d:%i' "$source_path" > "$HOME/replacement.identity"
    ;;
esac
STUB
  /bin/chmod 755 "$wrapper"
}

make_ln_wrapper() {
  local wrapper="$1"
  /usr/bin/sed > "$wrapper" <<'STUB'
#!/bin/bash
set -euo pipefail
source_path="$1"
destination_path="$2"
if [ "${LAUNCHER_RACE_MODE:-}" = late ] \
  && [[ "$destination_path" = *"Codex Dream Skin.command" ]]; then
  /usr/bin/printf 'foreign late creator\n' > "$destination_path"
  /usr/bin/stat -f '%d:%i' "$destination_path" > "$HOME/late.identity"
fi
/bin/ln "$source_path" "$destination_path"
STUB
  /bin/chmod 755 "$wrapper"
}

write_common_stub() {
  local target="$1"
  local fixture="$2"
  local wrapper="$3"
  local link_wrapper="$4"
  /usr/bin/sed "s|__FIXTURE__|$fixture|g" > "$target" <<'STUB'
SCRIPT_DIR="__FIXTURE__/scripts"
PROJECT_ROOT="__FIXTURE__"
INSTALL_ROOT="$HOME/.codex/codex-dream-skin-studio"
STATE_ROOT="$HOME/state"
STATE_PATH="$STATE_ROOT/state.json"
ROLLBACK_STATE_PATH="$STATE_ROOT/rollback.json"
THEME_BACKUP_PATH="$STATE_ROOT/theme-backup.json"
RESTORED_THEME_BACKUP_PATH="$STATE_ROOT/theme-backup.restored.json"
THEME_DIR="$STATE_ROOT/theme"
CONFIG_PATH="$HOME/.codex/config.toml"
INJECTOR="$SCRIPT_DIR/injector.mjs"
INJECTOR_JOB_LABEL=fixture.injector
CODEX_APP_VALIDATED=false
CODEX_APP_CONTROL_VALIDATED=false
NODE_RUNTIME_VALIDATED=false
fail() { printf 'fixture: %s\n' "$*" >&2; exit 1; }
try_discover_codex_app() { return 1; }
try_validate_codex_app_identity() { return 1; }
try_validate_codex_app_control_identity() { return 1; }
try_require_macos_node_runtime() { return 1; }
require_lifecycle_lock() { :; }
acquire_lifecycle_lock() { LIFECYCLE_LOCK_BORROWED=true; }
release_lifecycle_lock() { :; }
lifecycle_lock_is_busy() { return 1; }
cleanup_staged_theme_backup() { :; }
ensure_state_root() { /bin/mkdir -p "$STATE_ROOT"; }
live_theme_backup_is_valid() { return 1; }
restored_theme_backup_is_valid() { [ -f "$RESTORED_THEME_BACKUP_PATH" ]; }
release_codex_launchd_job() { :; }
clear_renderer_rollback_evidence() { /bin/rm -f "$ROLLBACK_STATE_PATH"; }
codex_is_running() { return 1; }
STUB
  /usr/bin/sed -n \
    -e '/^managed_macos_launcher_is_owned() {$/,/^}$/p' \
    -e '/^restore_quarantined_macos_launcher() {$/,/^}$/p' \
    -e '/^remove_managed_macos_launchers() {$/,/^}$/p' \
    "$ROOT/scripts/common-macos.sh" \
    | /usr/bin/sed "s|/bin/mv|$wrapper|g; s|/bin/ln|$link_wrapper|g" >> "$target"
}

prepare_launchers() {
  local home="$1"
  /bin/mkdir -p "$home/Desktop"
  /usr/bin/printf '%s\n' '#!/bin/bash' '# CodexDreamSkinStudio launcher' 'set -e' \
    > "$home/Desktop/Codex Dream Skin.command"
  /usr/bin/printf '%s\n' '#!/bin/bash' '# user-owned launcher' 'set -e' \
    > "$home/Desktop/Codex Dream Skin - Customize.command"
  /usr/bin/printf 'symlink target\n' > "$home/symlink-target"
  /bin/ln -s "$home/symlink-target" "$home/Desktop/Codex Dream Skin - Verify.command"
}

assert_launcher_race() {
  local home="$1"
  local mode="$2"
  local exit_code="$3"
  local launcher="$home/Desktop/Codex Dream Skin.command"
  [ -f "$launcher" ] && [ ! -L "$launcher" ]
  [ -f "$home/Desktop/Codex Dream Skin - Customize.command" ]
  [ -L "$home/Desktop/Codex Dream Skin - Verify.command" ]
  [ "$(/bin/cat "$home/symlink-target")" = 'symlink target' ]
  if [ "$mode" = late ]; then
    [ "$exit_code" -ne 0 ]
    [ "$(/usr/bin/stat -f '%d:%i' "$launcher")" = "$(/bin/cat "$home/late.identity")" ]
    [ "$(/bin/cat "$launcher")" = 'foreign late creator' ]
    /usr/bin/find "$home/Desktop" -path '*/.codex-dream-skin-launcher.*/entry' -type f \
      -print -quit | /usr/bin/grep -q .
    [ -f "$launcher.owned-original" ]
  elif [ "$mode" = before ]; then
    [ "$(/usr/bin/stat -f '%d:%i' "$launcher")" = "$(/bin/cat "$home/replacement.identity")" ]
    [ "$(/usr/bin/sed -n '1,3p' "$launcher")" = $'#!/bin/bash\n# CodexDreamSkinStudio launcher\nset -e' ]
    [ "$exit_code" -ne 0 ]
    [ -f "$launcher.owned-original" ]
  else
    [ "$(/usr/bin/stat -f '%d:%i' "$launcher")" = "$(/bin/cat "$home/replacement.identity")" ]
    [ "$(/usr/bin/sed -n '1,3p' "$launcher")" = $'#!/bin/bash\n# CodexDreamSkinStudio launcher\nset -e' ]
    [ "$exit_code" -eq 0 ]
    [ ! -e "$launcher.owned-original" ]
  fi
}

for entrypoint in direct studio; do
  for mode in before after late; do
    fixture="$TMP/$entrypoint-$mode"
    home="$fixture/home"
    wrapper="$fixture/mv-race"
    link_wrapper="$fixture/ln-race"
    /bin/mkdir -p "$fixture/scripts" "$fixture/bin" "$home/.codex" "$home/state/theme"
    /bin/cp "$ROOT/VERSION" "$fixture/VERSION"
    make_mv_wrapper "$wrapper"
    make_ln_wrapper "$link_wrapper"
    write_common_stub "$fixture/scripts/common-macos.sh" "$fixture" "$wrapper" "$link_wrapper"
    prepare_launchers "$home"
    /usr/bin/printf 'completion proof\n' > "$home/state/theme-backup.restored.json"
    if [ "$entrypoint" = direct ]; then
      /bin/cp "$ROOT/scripts/restore-dream-skin-macos.sh" "$fixture/scripts/"
      command=("$fixture/scripts/restore-dream-skin-macos.sh" --uninstall)
    else
      /bin/cp "$ROOT/scripts/studio-adapter-macos.sh" "$fixture/scripts/"
      /usr/bin/sed > "$fixture/scripts/restore-dream-skin-macos.sh" <<'STUB'
#!/bin/bash
exit 0
STUB
      /usr/bin/sed > "$fixture/scripts/status-dream-skin-macos.sh" <<'STUB'
#!/bin/bash
printf '{"schemaVersion":1,"ok":false,"operation":"uninstall","state":{"install":"not-installed","codex":"not-installed","session":"official","operation":"idle","themeName":null,"requiresRestart":false,"availableActions":["uninstall"],"verified":null},"error":{"code":"CODEX_NOT_INSTALLED","message":"Codex is not installed.","recoveryActions":["cancel"]}}\n'
exit 1
STUB
      command=("$fixture/scripts/studio-adapter-macos.sh" uninstall)
    fi
    /bin/chmod 755 "$fixture/scripts/"*.sh
    set +e
    /usr/bin/env HOME="$home" LAUNCHER_RACE_MODE="$mode" "${command[@]}" \
      > "$fixture/out" 2> "$fixture/err"
    entry_exit="$?"
    set -e
    assert_launcher_race "$home" "$mode" "$entry_exit"
  done
done

printf 'PASS: launcher ownership races verified through direct and Studio uninstall.\n'
