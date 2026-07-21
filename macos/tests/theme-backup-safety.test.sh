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

ARCHIVE_STAGED="$TMP/theme-backup.stage.json"
ARCHIVE_DESTINATION="$TMP/theme-backup.restored.json"
/bin/cp "$BACKUP_TARGET" "$ARCHIVE_STAGED"
ARCHIVE_IDENTITY="$(/usr/bin/stat -f '%d:%i' "$ARCHIVE_STAGED")"
"$NODE" "$ROOT/scripts/theme-config.mjs" archive \
  "$ARCHIVE_STAGED" "$ARCHIVE_DESTINATION" "$ARCHIVE_IDENTITY"
[ ! -e "$ARCHIVE_STAGED" ] && [ ! -L "$ARCHIVE_STAGED" ]
/usr/bin/cmp -s "$BACKUP_TARGET" "$ARCHIVE_DESTINATION"

/bin/cp "$BACKUP_TARGET" "$ARCHIVE_STAGED"
/usr/bin/printf '%s\n' 'replacement staged bytes' > "$ARCHIVE_STAGED.replacement"
ARCHIVE_IDENTITY="$(/usr/bin/stat -f '%d:%i' "$ARCHIVE_STAGED")"
if "$NODE" --input-type=module - \
  "$ROOT/scripts/theme-config.mjs" "$ARCHIVE_STAGED" \
  "$ARCHIVE_DESTINATION.cleanup-race" "$ARCHIVE_IDENTITY" <<'NODE_TEST' >/dev/null 2>&1
import fs from "node:fs/promises";
import { pathToFileURL } from "node:url";
const [modulePath, staged, destination, expectedIdentity] = process.argv.slice(2);
const { archiveBackup } = await import(pathToFileURL(modulePath));
await archiveBackup(staged, destination, expectedIdentity, undefined, async () => {
  await fs.rename(staged, `${staged}.displaced`);
  await fs.copyFile(`${staged}.replacement`, staged);
});
NODE_TEST
then
  printf 'Node archive accepted a staged replacement at the quarantine boundary.\n' >&2
  exit 1
fi
/usr/bin/cmp -s "$BACKUP_TARGET" "$ARCHIVE_STAGED.displaced"
/usr/bin/cmp -s "$ARCHIVE_STAGED.replacement" "$ARCHIVE_STAGED"
/usr/bin/cmp -s "$BACKUP_TARGET" "$ARCHIVE_DESTINATION.cleanup-race"

/bin/cp "$BACKUP_TARGET" "$ARCHIVE_STAGED"
ARCHIVE_IDENTITY="$(/usr/bin/stat -f '%d:%i' "$ARCHIVE_STAGED")"
/bin/mv "$ARCHIVE_STAGED" "$ARCHIVE_STAGED.displaced"
/bin/cp "$BACKUP_TARGET" "$ARCHIVE_STAGED"
if "$NODE" "$ROOT/scripts/theme-config.mjs" archive \
  "$ARCHIVE_STAGED" "$ARCHIVE_DESTINATION.replaced" "$ARCHIVE_IDENTITY" >/dev/null 2>&1; then
  printf 'Node archive accepted a replacement staged pathname.\n' >&2
  exit 1
fi
[ ! -e "$ARCHIVE_DESTINATION.replaced" ]
/usr/bin/cmp -s "$ARCHIVE_STAGED.displaced" "$ARCHIVE_DESTINATION"

/bin/rm -f "$ARCHIVE_DESTINATION"
/bin/mkdir "$ARCHIVE_DESTINATION"
/bin/rm -f "$ARCHIVE_STAGED"
/bin/cp "$BACKUP_TARGET" "$ARCHIVE_STAGED"
ARCHIVE_IDENTITY="$(/usr/bin/stat -f '%d:%i' "$ARCHIVE_STAGED")"
if "$NODE" "$ROOT/scripts/theme-config.mjs" archive \
  "$ARCHIVE_STAGED" "$ARCHIVE_DESTINATION" "$ARCHIVE_IDENTITY" >/dev/null 2>&1; then
  printf 'Node archive moved a staged backup into a destination directory.\n' >&2
  exit 1
fi
/usr/bin/cmp -s "$ARCHIVE_STAGED" "$BACKUP_TARGET"
[ -d "$ARCHIVE_DESTINATION" ]
[ -z "$(/usr/bin/find "$ARCHIVE_DESTINATION" -mindepth 1 -maxdepth 1 -print -quit)" ]

RETIRE_LIVE="$TMP/theme-backup.live.json"
RETIRE_ARCHIVE="$TMP/theme-backup.retired.json"
/bin/cp "$BACKUP_TARGET" "$RETIRE_LIVE"
/bin/cp "$BACKUP_TARGET" "$RETIRE_ARCHIVE"
RETIRE_IDENTITY="$(/usr/bin/stat -f '%d:%i' "$RETIRE_LIVE")"
"$NODE" "$ROOT/scripts/theme-config.mjs" retire \
  "$RETIRE_LIVE" "$RETIRE_ARCHIVE" "$RETIRE_IDENTITY"
[ ! -e "$RETIRE_LIVE" ] && [ ! -L "$RETIRE_LIVE" ]
/usr/bin/cmp -s "$BACKUP_TARGET" "$RETIRE_ARCHIVE"

/bin/cp "$BACKUP_TARGET" "$RETIRE_LIVE"
/usr/bin/printf '%s\n' 'replacement live bytes' > "$RETIRE_LIVE.replacement"
RETIRE_IDENTITY="$(/usr/bin/stat -f '%d:%i' "$RETIRE_LIVE")"
if "$NODE" --input-type=module - \
  "$ROOT/scripts/theme-config.mjs" "$RETIRE_LIVE" "$RETIRE_ARCHIVE.race" \
  "$RETIRE_IDENTITY" <<'NODE_TEST' >/dev/null 2>&1
import fs from "node:fs/promises";
import { pathToFileURL } from "node:url";
const [modulePath, live, archive, expectedIdentity] = process.argv.slice(2);
const { retireBackup } = await import(pathToFileURL(modulePath));
await fs.copyFile(live, archive);
await retireBackup(live, archive, expectedIdentity, async () => {
  await fs.rename(live, `${live}.displaced`);
  await fs.copyFile(`${live}.replacement`, live);
});
NODE_TEST
then
  printf 'Node retirement accepted a live replacement after final proof.\n' >&2
  exit 1
fi
/usr/bin/cmp -s "$BACKUP_TARGET" "$RETIRE_ARCHIVE.race"
/usr/bin/cmp -s "$BACKUP_TARGET" "$RETIRE_LIVE.displaced"
/usr/bin/cmp -s "$RETIRE_LIVE.replacement" "$RETIRE_LIVE"

/bin/rm -rf "$RETIRE_LIVE" "$RETIRE_LIVE.displaced" "$RETIRE_LIVE".cleanup.* \
  "$RETIRE_ARCHIVE.conflict"
/bin/cp "$BACKUP_TARGET" "$RETIRE_LIVE"
/bin/cp "$BACKUP_TARGET" "$RETIRE_ARCHIVE.conflict"
RETIRE_IDENTITY="$(/usr/bin/stat -f '%d:%i' "$RETIRE_LIVE")"
if "$NODE" --input-type=module - \
  "$ROOT/scripts/theme-config.mjs" "$RETIRE_LIVE" "$RETIRE_ARCHIVE.conflict" \
  "$RETIRE_IDENTITY" <<'NODE_TEST' >/dev/null 2>&1
import fs from "node:fs/promises";
import { pathToFileURL } from "node:url";
const [modulePath, live, archive, expectedIdentity] = process.argv.slice(2);
const { retireBackup } = await import(pathToFileURL(modulePath));
await retireBackup(live, archive, expectedIdentity, undefined, async () => {
  await fs.writeFile(live, "unexpected live bytes\n", { flag: "wx" });
});
NODE_TEST
then
  printf 'Node retirement accepted a no-replace recovery conflict.\n' >&2
  exit 1
fi
[ "$(/bin/cat "$RETIRE_LIVE")" = 'unexpected live bytes' ]
/usr/bin/cmp -s "$BACKUP_TARGET" "$RETIRE_ARCHIVE.conflict"
RETIRE_QUARANTINE="$(/usr/bin/find "$TMP" -path "$RETIRE_LIVE.cleanup.*/staged" -type f -print -quit)"
[ -n "$RETIRE_QUARANTINE" ]
/usr/bin/cmp -s "$BACKUP_TARGET" "$RETIRE_QUARANTINE"

/bin/rm -rf "$RETIRE_LIVE" "$RETIRE_ARCHIVE.bound" "$RETIRE_ARCHIVE.bound.displaced"
/bin/cp "$BACKUP_TARGET" "$RETIRE_LIVE"
/bin/cp "$BACKUP_TARGET" "$RETIRE_ARCHIVE.bound"
RETIRE_IDENTITY="$(/usr/bin/stat -f '%d:%i' "$RETIRE_LIVE")"
if "$NODE" --input-type=module - \
  "$ROOT/scripts/theme-config.mjs" "$RETIRE_LIVE" "$RETIRE_ARCHIVE.bound" \
  "$RETIRE_IDENTITY" <<'NODE_TEST' >/dev/null 2>&1
import fs from "node:fs/promises";
import { pathToFileURL } from "node:url";
const [modulePath, live, archive, expectedIdentity] = process.argv.slice(2);
const { retireBackup } = await import(pathToFileURL(modulePath));
await retireBackup(live, archive, expectedIdentity, undefined, async () => {
  await fs.rename(archive, `${archive}.displaced`);
  await fs.writeFile(archive, "replacement archive bytes\n");
});
NODE_TEST
then
  printf 'Node retirement consumed live backup after archive replacement.\n' >&2
  exit 1
fi
/usr/bin/cmp -s "$BACKUP_TARGET" "$RETIRE_LIVE"
/usr/bin/cmp -s "$BACKUP_TARGET" "$RETIRE_ARCHIVE.bound.displaced"
[ "$(/bin/cat "$RETIRE_ARCHIVE.bound")" = 'replacement archive bytes' ]

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
ROLLBACK_STATE_PATH="$STATE_ROOT/rollback.json"
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
try_require_macos_node_runtime() { NODE="${DREAM_SKIN_TEST_NODE:-__NODE__}"; NODE_AVAILABLE=true; export NODE; return 0; }
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
clear_renderer_rollback_evidence() { return 0; }
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

# A normal shell Restore must dispatch archive then identity-bound retirement
# before it clears lifecycle state.
/bin/rm -f "$STATE/theme-backup.json" "$STATE/theme-backup.restored.json" "$MARKER"
/bin/cp "$STATE/theme-backup-target.json.original" "$STATE/theme-backup.json"
/bin/cp "$STATE/theme-backup.json" "$STATE/theme-backup.entry.original"
/usr/bin/printf '%s\n' '{"port":9341,"injectorPid":4242}' > "$STATE/state.json"
LOGGING_NODE="$TMP/logging-node"
/usr/bin/sed \
  -e "s|__REAL_NODE__|$NODE|g" \
  -e "s|__MARKER__|$MARKER|g" \
  > "$LOGGING_NODE" <<'NODE_WRAPPER'
#!/bin/bash
set -euo pipefail
printf 'node:%s\n' "${2:-}" >> "__MARKER__"
exec "__REAL_NODE__" "$@"
NODE_WRAPPER
/bin/chmod 755 "$LOGGING_NODE"
/usr/bin/env HOME="$HOME_FIXTURE" DREAM_SKIN_TEST_NODE="$LOGGING_NODE" \
  "$ENGINE/scripts/restore-dream-skin-macos.sh" --restore-base-theme >/dev/null
/usr/bin/cmp -s "$STATE/theme-backup.entry.original" "$STATE/theme-backup.restored.json"
[ ! -e "$STATE/theme-backup.json" ] && [ ! -L "$STATE/theme-backup.json" ]
[ ! -e "$STATE/state.json" ] && [ ! -L "$STATE/state.json" ]
ARCHIVE_LINE="$(/usr/bin/grep -n '^node:archive$' "$MARKER" | /usr/bin/cut -d: -f1)"
RETIRE_LINE="$(/usr/bin/grep -n '^node:retire$' "$MARKER" | /usr/bin/cut -d: -f1)"
[ "$ARCHIVE_LINE" -lt "$RETIRE_LINE" ]

# A replacement after the helper's final live proof must fail before state
# cleanup while preserving the archive, replacement, and quarantine evidence.
/usr/bin/printf '%s\n' '[desktop]' 'appearanceTheme = "dream-skin"' 'keepMe = true' \
  > "$HOME_FIXTURE/.codex/config.toml"
/bin/rm -rf "$STATE/theme-backup.json" "$STATE/theme-backup.restored.json" \
  "$STATE"/theme-backup.json.cleanup.* "$MARKER"
/bin/cp "$STATE/theme-backup-target.json.original" "$STATE/theme-backup.json"
/bin/cp "$STATE/theme-backup.json" "$STATE/theme-backup.entry.original"
/usr/bin/printf '%s\n' '{"port":9341,"injectorPid":4242}' > "$STATE/state.json"
/bin/cp "$STATE/state.json" "$STATE/state.json.original"
"$NODE" -e '
  const fs = require("node:fs");
  const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  value.values.appearanceTheme = `appearanceTheme = "dark"`;
  fs.writeFileSync(process.argv[2], `${JSON.stringify(value)}\n`);
' "$STATE/theme-backup.json" "$STATE/theme-backup.replacement.json"
RETIRE_RACE_NODE="$TMP/retire-race-node"
/usr/bin/sed \
  -e "s|__REAL_NODE__|$NODE|g" \
  -e "s|__REPLACEMENT__|$STATE/theme-backup.replacement.json|g" \
  > "$RETIRE_RACE_NODE" <<'NODE_WRAPPER'
#!/bin/bash
set -euo pipefail
if [ "${2:-}" = "retire" ]; then
  exec "__REAL_NODE__" --input-type=module - "$1" "$3" "$4" "$5" <<'NODE_TEST'
import fs from "node:fs/promises";
import { pathToFileURL } from "node:url";
const [modulePath, live, archive, expectedIdentity] = process.argv.slice(2);
const { retireBackup } = await import(pathToFileURL(modulePath));
await retireBackup(live, archive, expectedIdentity, async () => {
  await fs.rename(live, `${live}.displaced-after-proof`);
  await fs.copyFile("__REPLACEMENT__", live);
});
NODE_TEST
fi
exec "__REAL_NODE__" "$@"
NODE_WRAPPER
/bin/chmod 755 "$RETIRE_RACE_NODE"
set +e
/usr/bin/env HOME="$HOME_FIXTURE" DREAM_SKIN_TEST_NODE="$RETIRE_RACE_NODE" \
  "$ENGINE/scripts/restore-dream-skin-macos.sh" \
  --restore-base-theme >"$TMP/retire-race.out" 2>"$TMP/retire-race.err"
RETIRE_RACE_EXIT="$?"
set -e
if [ "$RETIRE_RACE_EXIT" -eq 0 ]; then
  /bin/cat "$TMP/retire-race.out" "$TMP/retire-race.err" >&2
  printf 'Direct restore accepted a live replacement after final retirement proof.\n' >&2
  exit 1
fi
/usr/bin/grep -F 'Could not retire the live theme backup safely' "$TMP/retire-race.err" >/dev/null
/usr/bin/cmp -s "$STATE/theme-backup.entry.original" "$STATE/theme-backup.restored.json"
/usr/bin/cmp -s "$STATE/theme-backup.entry.original" \
  "$STATE/theme-backup.json.displaced-after-proof"
/usr/bin/cmp -s "$STATE/theme-backup.replacement.json" "$STATE/theme-backup.json"
/usr/bin/cmp -s "$STATE/state.json.original" "$STATE/state.json"
if /usr/bin/find "$STATE" -maxdepth 1 -name '.theme-backup.stage.*' -print -quit \
  | /usr/bin/grep -q .; then
  printf 'Failed live retirement retained an already-archived private stage.\n' >&2
  exit 1
fi
RETIRE_RACE_QUARANTINE="$(/usr/bin/find "$STATE" \
  -path "$STATE/theme-backup.json.cleanup.*/staged" -type f -print -quit)"
[ -n "$RETIRE_RACE_QUARANTINE" ]
/usr/bin/cmp -s "$STATE/theme-backup.replacement.json" "$RETIRE_RACE_QUARANTINE"

# Replace the live backup after config restore. A committed archive must consume
# its exact private stage without deleting the replacement live backup.
/bin/rm -f "$STATE/theme-backup.json" "$STATE/theme-backup.restored.json" "$MARKER"
/bin/cp "$STATE/theme-backup-target.json.original" "$STATE/theme-backup.json"
/bin/cp "$STATE/theme-backup.json" "$STATE/theme-backup.entry.original"
/usr/bin/printf '%s\n' '{"port":9341,"injectorPid":4242}' > "$STATE/state.json"
"$NODE" -e '
  const fs = require("node:fs");
  const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  value.values.appearanceTheme = `appearanceTheme = "dark"`;
  fs.writeFileSync(process.argv[2], `${JSON.stringify(value)}\n`);
' "$STATE/theme-backup.json" "$STATE/theme-backup.replacement.json"
LIVE_RACE_NODE="$TMP/live-race-node"
/usr/bin/sed \
  -e "s|__REAL_NODE__|$NODE|g" \
  -e "s|__STATE__|$STATE|g" \
  -e "s|__REPLACEMENT__|$STATE/theme-backup.replacement.json|g" \
  > "$LIVE_RACE_NODE" <<'NODE_WRAPPER'
#!/bin/bash
set -euo pipefail
"__REAL_NODE__" "$@"
if [ "${2:-}" = "restore" ]; then
  /bin/mv "__STATE__/theme-backup.json" "__STATE__/theme-backup.original-live.json"
  /bin/cp "__REPLACEMENT__" "__STATE__/theme-backup.json"
fi
NODE_WRAPPER
/bin/chmod 755 "$LIVE_RACE_NODE"
/usr/bin/env HOME="$HOME_FIXTURE" DREAM_SKIN_TEST_NODE="$LIVE_RACE_NODE" \
  "$ENGINE/scripts/restore-dream-skin-macos.sh" --restore-base-theme >/dev/null
/usr/bin/cmp -s "$STATE/theme-backup.replacement.json" "$STATE/theme-backup.json"
/usr/bin/cmp -s "$STATE/theme-backup.entry.original" "$STATE/theme-backup.restored.json"
[ ! -e "$STATE/state.json" ] && [ ! -L "$STATE/state.json" ]
if /usr/bin/find "$STATE" -maxdepth 1 -name '.theme-backup.stage.*' -print -quit | /usr/bin/grep -q .; then
  printf 'Successful Restore orphaned a private staged theme backup.\n' >&2
  exit 1
fi

# Replace the staged pathname and turn the archive destination into a directory
# after config restore returns, at the archive boundary.
/usr/bin/printf '%s\n' '[desktop]' 'appearanceTheme = "dream-skin"' 'keepMe = true' \
  > "$HOME_FIXTURE/.codex/config.toml"
/bin/rm -f "$STATE/theme-backup.json" "$STATE/theme-backup.restored.json" "$MARKER"
/bin/cp "$STATE/theme-backup-target.json.original" "$STATE/theme-backup.json"
/bin/cp "$STATE/theme-backup.json" "$STATE/theme-backup.entry.original"
/usr/bin/printf '%s\n' '{"port":9341,"injectorPid":4242}' > "$STATE/state.json"
RACE_NODE="$TMP/race-node"
/usr/bin/sed \
  -e "s|__REAL_NODE__|$NODE|g" \
  -e "s|__STATE__|$STATE|g" \
  -e "s|__REPLACEMENT__|$STATE/theme-backup.replacement.json|g" \
  -e "s|__MARKER__|$MARKER|g" \
  > "$RACE_NODE" <<'NODE_WRAPPER'
#!/bin/bash
set -euo pipefail
"__REAL_NODE__" "$@"
if [ "${2:-}" = "restore" ]; then
  STAGED="$(/usr/bin/find "__STATE__" -maxdepth 1 -type f -name '.theme-backup.stage.*' -print -quit)"
  [ -n "$STAGED" ]
  /bin/mv "$STAGED" "__STATE__/.theme-backup.stage.held"
  /bin/cp "__REPLACEMENT__" "$STAGED"
  /bin/mkdir "__STATE__/theme-backup.restored.json"
  printf 'archive-race\n' >> "__MARKER__"
fi
NODE_WRAPPER
/bin/chmod 755 "$RACE_NODE"
set +e
/usr/bin/env HOME="$HOME_FIXTURE" DREAM_SKIN_TEST_NODE="$RACE_NODE" \
  "$ENGINE/scripts/restore-dream-skin-macos.sh" \
  --restore-base-theme >"$TMP/race.out" 2>"$TMP/race.err"
RACE_EXIT="$?"
set -e
if [ "$RACE_EXIT" -eq 0 ]; then
  /bin/cat "$TMP/race.out" "$TMP/race.err" >&2
  printf 'Direct restore accepted an unsafe archive-boundary replacement.\n' >&2
  exit 1
fi
/usr/bin/grep -F 'staged theme backup identity changed' "$TMP/race.err" >/dev/null
/usr/bin/printf '%s\n' '[desktop]' 'appearanceTheme = "system"' 'keepMe = true' \
  > "$TMP/config.expected"
/usr/bin/cmp -s "$HOME_FIXTURE/.codex/config.toml" "$TMP/config.expected"
/usr/bin/cmp -s "$STATE/state.json" "$STATE/state.json.original"
/usr/bin/printf '%s\n' endpoint-probe stop-injector release-job archive-race > "$TMP/marker.expected"
/usr/bin/cmp -s "$MARKER" "$TMP/marker.expected"
/usr/bin/cmp -s "$STATE/.theme-backup.stage.held" "$STATE/theme-backup.entry.original"
/usr/bin/cmp -s "$STATE/theme-backup.replacement.json" \
  "$(/usr/bin/find "$STATE" -maxdepth 1 -type f -name '.theme-backup.stage.*' ! -name '*.held' -print -quit)"
[ -d "$STATE/theme-backup.restored.json" ]
[ -z "$(/usr/bin/find "$STATE/theme-backup.restored.json" -mindepth 1 -maxdepth 1 -print -quit)" ]

printf 'PASS: macOS restore rejects unsafe theme backups before mutation.\n'
