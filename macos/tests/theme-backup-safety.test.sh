#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
NODE="${NODE:-$(command -v node)}"
TMP="$(/usr/bin/mktemp -d /tmp/codex-dream-skin-backup-safety.XXXXXX)"
trap '/bin/rm -rf "$TMP"' EXIT

CONFIG="$TMP/config.toml"
BACKUP_TARGET="$TMP/theme-backup-target.json"
BACKUP_LINK="$TMP/theme-backup.json"
/usr/bin/printf '%s\n' '[desktop]' 'appearanceTheme = "dream-skin"' 'keepMe = true' > "$CONFIG"
/bin/cp "$CONFIG" "$CONFIG.original"
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
' "$BACKUP_TARGET" "$CONFIG"
/bin/cp "$BACKUP_TARGET" "$BACKUP_TARGET.original"
/bin/ln -s "$BACKUP_TARGET" "$BACKUP_LINK"
if "$NODE" "$ROOT/scripts/theme-config.mjs" restore "$CONFIG" "$BACKUP_LINK" >/dev/null 2>&1; then
  printf 'Node restore accepted a symlinked theme backup.\n' >&2
  exit 1
fi
/usr/bin/cmp -s "$CONFIG" "$CONFIG.original"
/usr/bin/cmp -s "$BACKUP_TARGET" "$BACKUP_TARGET.original"
[ -L "$BACKUP_LINK" ]

HOME_FIXTURE="$TMP/home"
ENGINE="$TMP/engine"
STATE="$HOME_FIXTURE/state"
MARKER="$TMP/restore.marker"
/bin/mkdir -p "$ENGINE/scripts" "$STATE" "$HOME_FIXTURE/.codex"
/bin/cp "$ROOT/scripts/restore-dream-skin-macos.sh" "$ROOT/scripts/theme-config.mjs" "$ENGINE/scripts/"
/usr/bin/printf '%s\n' '[desktop]' 'appearanceTheme = "dream-skin"' 'keepMe = true' \
  > "$HOME_FIXTURE/.codex/config.toml"
/bin/cp "$HOME_FIXTURE/.codex/config.toml" "$HOME_FIXTURE/.codex/config.toml.original"
/usr/bin/printf '%s\n' '{"port":9341,"injectorPid":4242}' > "$STATE/state.json"
/bin/cp "$STATE/state.json" "$STATE/state.json.original"
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
' "$STATE/theme-backup-target.json" "$HOME_FIXTURE/.codex/config.toml"
/bin/cp "$STATE/theme-backup-target.json" "$STATE/theme-backup-target.json.original"
/bin/ln -s "$STATE/theme-backup-target.json" "$STATE/theme-backup.json"
/usr/bin/sed \
  -e "s|__ENGINE__|$ENGINE|g" \
  -e "s|__STATE__|$STATE|g" \
  -e "s|__CONFIG__|$HOME_FIXTURE/.codex/config.toml|g" \
  -e "s|__NODE__|$NODE|g" \
  -e "s|__MARKER__|$MARKER|g" \
  > "$ENGINE/scripts/common-macos.sh" <<'STUB'
PROJECT_ROOT="__ENGINE__"
SCRIPT_DIR="$PROJECT_ROOT/scripts"
STATE_ROOT="__STATE__"
STATE_PATH="$STATE_ROOT/state.json"
THEME_BACKUP_PATH="$STATE_ROOT/theme-backup.json"
RESTORED_THEME_BACKUP_PATH="$STATE_ROOT/theme-backup.restored.json"
THEME_DIR="$STATE_ROOT/theme"
INSTALL_ROOT="$PROJECT_ROOT"
CONFIG_PATH="__CONFIG__"
NODE="__NODE__"
INJECTOR="$SCRIPT_DIR/injector.mjs"
fail() { printf '%s\n' "$*" >&2; exit 1; }
try_discover_codex_app() { return 0; }
try_validate_codex_app_identity() { CODEX_APP_VALIDATED=true; return 0; }
try_require_macos_node_runtime() { NODE_AVAILABLE=true; return 0; }
require_lifecycle_lock() { :; }
release_lifecycle_lock() { :; }
ensure_state_root() { :; }
state_field() { printf '9341\n'; }
codex_is_running() { return 1; }
verified_cdp_browser_id() { printf 'endpoint-probe\n' >> "__MARKER__"; return 1; }
stop_recorded_injector() { printf 'stop-injector\n' >> "__MARKER__"; return 0; }
recover_damaged_injector_state_without_live_candidate() { return 1; }
release_codex_launchd_job() { printf 'release-job\n' >> "__MARKER__"; }
browser_id_is_valid() { return 0; }
live_theme_backup_is_valid() { [ -f "$THEME_BACKUP_PATH" ] && [ ! -L "$THEME_BACKUP_PATH" ]; }
restored_theme_backup_is_valid() { return 1; }
STUB

if /usr/bin/env HOME="$HOME_FIXTURE" "$ENGINE/scripts/restore-dream-skin-macos.sh" \
  --restore-base-theme >/dev/null 2>&1; then
  printf 'Direct restore accepted a symlinked theme backup.\n' >&2
  exit 1
fi
/usr/bin/cmp -s "$HOME_FIXTURE/.codex/config.toml" "$HOME_FIXTURE/.codex/config.toml.original"
/usr/bin/cmp -s "$STATE/state.json" "$STATE/state.json.original"
/usr/bin/cmp -s "$STATE/theme-backup-target.json" "$STATE/theme-backup-target.json.original"
[ -L "$STATE/theme-backup.json" ]
[ ! -e "$MARKER" ] || {
  printf 'Direct restore touched watcher or CDP hooks before rejecting a symlinked backup.\n' >&2
  exit 1
}

printf 'PASS: macOS restore rejects unsafe theme backups before mutation.\n'
