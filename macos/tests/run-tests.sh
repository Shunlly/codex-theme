#!/bin/bash

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
NODE="${NODE:-/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node}"
[ -x "$NODE" ] || { printf 'Codex bundled Node.js was not found: %s\n' "$NODE" >&2; exit 1; }

while IFS= read -r file; do /bin/bash -n "$file"; done < <(
  /usr/bin/find "$ROOT" -type f \( -name '*.sh' -o -name '*.command' \) \
    ! -path '*/release/*' -print
)
while IFS= read -r file; do "$NODE" --check "$file" >/dev/null; done < <(
  /usr/bin/find "$ROOT/scripts" "$ROOT/assets" "$ROOT/presets" -type f \( -name '*.mjs' -o -name '*.js' \) -print
)

if /usr/bin/grep -R -n -E 'dream-skin-skin|DREAM_SKIN_SKIN|1\.0\.0-rc2' \
  "$ROOT/scripts" "$ROOT/assets" >/dev/null; then
  printf 'Legacy release-candidate identifiers remain in runtime files.\n' >&2
  exit 1
fi
if /usr/bin/grep -R -n -E '(writeFile|rename|copyFile|rm).*app\.asar' "$ROOT/scripts" >/dev/null; then
  printf 'A runtime script appears to mutate app.asar.\n' >&2
  exit 1
fi
if /usr/bin/grep -R -n --include='*.sh' -E '/usr/bin/python3|(^|[[:space:]])eval([[:space:]]|$)' \
  "$ROOT/scripts" "$ROOT/menubar" >/dev/null; then
  printf 'Runtime shell (scripts + menu bar) must parse JSON with bundled Node.js or plain shell, without python3 or eval.\n' >&2
  exit 1
fi
if /usr/bin/grep -R -n --include='*.sh' -E '/usr/bin/osascript[[:space:]]+-e[[:space:]]+"' \
  "$ROOT/scripts" "$ROOT/menubar" >/dev/null; then
  printf 'Dynamic AppleScript must be passed through argv, not interpolated into osascript -e.\n' >&2
  exit 1
fi
if ! /usr/bin/grep -F -q 'sfimage=paintpalette.fill' \
  "$ROOT/menubar/codex_dream_skin.10s.sh"; then
  printf 'SwiftBar menu title must retain the Dream Skin palette icon.\n' >&2
  exit 1
fi
if ! /usr/bin/grep -F -q 'flag: "wx"' "$ROOT/scripts/write-theme.mjs"; then
  printf 'Theme writes must create randomized temporary files exclusively.\n' >&2
  exit 1
fi

"$NODE" "$ROOT/scripts/injector.mjs" --check-payload >/dev/null
"$NODE" "$ROOT/tests/image-metadata.test.mjs"
"$NODE" "$ROOT/tests/injector-bootstrap.test.mjs"
"$NODE" "$ROOT/tests/renderer-inject.test.mjs"
"$NODE" "$ROOT/tests/theme-stage.test.mjs"
"$NODE" "$ROOT/tests/theme-config.test.mjs"
NODE="$NODE" "$ROOT/tests/studio-adapter.test.sh"

/usr/bin/swift build --package-path "$ROOT/studio" --product dream-skin-config-restore >/dev/null
NATIVE_CONFIG_RESTORE="$(/usr/bin/swift build --package-path "$ROOT/studio" --show-bin-path)/dream-skin-config-restore"
[ -x "$NATIVE_CONFIG_RESTORE" ] || {
  printf 'Native config restore helper was not built: %s\n' "$NATIVE_CONFIG_RESTORE" >&2
  exit 1
}

# Every bundled preset must be a valid, injectable theme pack with a preset-* id.
for preset in "$ROOT"/presets/preset-*/; do
  [ -d "$preset" ] || continue
  PRESET_CHECK="$("$NODE" "$ROOT/scripts/injector.mjs" --check-payload --theme-dir "$preset")"
  "$NODE" -e '
    const v = JSON.parse(process.argv[1]);
    if (!v.pass || !String(v.themeId).startsWith("preset-") || v.imageBytes < 1) process.exit(1);
  ' "$PRESET_CHECK"
done

TMP="$(/usr/bin/mktemp -d /tmp/codex-dream-skin-tests.XXXXXX)"
TEST_INJECTOR_JOB_LABEL="com.openai.codex-dream-skin-studio.tests.$$"
DUMMY_PID=""
STATUS_PID=""
WATCH_PID=""
cleanup_tests() {
  if [ -n "$DUMMY_PID" ]; then
    /bin/kill -TERM "$DUMMY_PID" 2>/dev/null || true
    wait "$DUMMY_PID" 2>/dev/null || true
  fi
  if [ -n "$STATUS_PID" ]; then
    /bin/kill -TERM "$STATUS_PID" 2>/dev/null || true
    wait "$STATUS_PID" 2>/dev/null || true
  fi
  if [ -n "$WATCH_PID" ]; then
    /bin/kill -TERM "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
  fi
  /bin/rm -rf "$TMP"
}
trap cleanup_tests EXIT

# The runtime is user-scoped: sudo must fail before creating install or state files.
ROOT_GUARD_HOME="$TMP/root-guard-home"
for guarded_script in install-dream-skin-macos.sh apply-from-menubar-macos.sh; do
  ROOT_GUARD_ERROR="$TMP/$guarded_script.error"
  if /usr/bin/env HOME="$ROOT_GUARD_HOME" SUDO_USER=fixture \
    "$ROOT/scripts/$guarded_script" >/dev/null 2>"$ROOT_GUARD_ERROR"; then
    printf '%s unexpectedly accepted sudo.\n' "$guarded_script" >&2
    exit 1
  fi
  /usr/bin/grep -F -q 'Do not run with sudo' "$ROOT_GUARD_ERROR"
done
[ ! -e "$ROOT_GUARD_HOME" ] || {
  printf 'A sudo invocation created user-scoped files before it was rejected.\n' >&2
  exit 1
}

# Standalone archives flatten macos/ to their root. Prompt guides and NOTICE
# must describe that layout and must not claim that Windows assets are bundled.
STANDALONE_ROOT="$TMP/standalone-root"
STANDALONE_DOCS="$TMP/standalone-source-docs"
/bin/mkdir -p "$STANDALONE_ROOT" \
  "$STANDALONE_DOCS/images/gallery" "$STANDALONE_DOCS/images/presets"
/usr/bin/printf '%s\n' \
  'macos/presets/preset-romantic-rose/ macos/assets/portal-hero.png macos/NOTICE.md windows/assets/theme.json' \
  > "$STANDALONE_DOCS/reference-background-prompt-guide.md"
/bin/cp "$STANDALONE_DOCS/reference-background-prompt-guide.md" \
  "$STANDALONE_DOCS/reference-background-prompt-guide.en.md"
/bin/cp "$STANDALONE_DOCS/reference-background-prompt-guide.md" \
  "$STANDALONE_DOCS/background-generation-prompts.md"
: > "$STANDALONE_DOCS/images/gallery/skin-01.jpg"
: > "$STANDALONE_DOCS/images/presets/romantic-rose-source.png"
: > "$STANDALONE_DOCS/images/hero-banner-red-white.png"
/usr/bin/printf '%s\n' \
  '- `presets/preset-romantic-rose/background.jpg`' \
  '- `../windows/assets/dream-reference.jpg`' \
  '- `../docs/images/presets/romantic-rose-source.png`' \
  "They are included at the maintainer's direction as a local theme preset, source archive, and real runtime previews." \
  > "$STANDALONE_ROOT/NOTICE.md"
"$ROOT/scripts/prepare-standalone-docs.sh" "$STANDALONE_ROOT" "$STANDALONE_DOCS"
/usr/bin/grep -F -q 'presets/preset-romantic-rose/' \
  "$STANDALONE_ROOT/docs/reference-background-prompt-guide.md"
/usr/bin/grep -F -q 'assets/portal-hero.png' \
  "$STANDALONE_ROOT/docs/reference-background-prompt-guide.md"
/usr/bin/grep -F -q 'https://github.com/Fei-Away/Codex-Dream-Skin/blob/main/windows/assets/theme.json' \
  "$STANDALONE_ROOT/docs/reference-background-prompt-guide.md"
[ -f "$STANDALONE_ROOT/docs/images/hero-banner-red-white.png" ]
/usr/bin/grep -F -q '`docs/images/presets/romantic-rose-source.png`' \
  "$STANDALONE_ROOT/NOTICE.md"
/usr/bin/grep -F -q 'not included in this macOS archive' \
  "$STANDALONE_ROOT/NOTICE.md"

# A standalone studio can build another archive from its already-rewritten
# docs. Source discovery must stay inside that studio and URL rewriting must
# be idempotent.
STANDALONE_SOURCE="$TMP/standalone-source"
STANDALONE_REPACK="$TMP/standalone-repack"
/bin/mkdir -p "$STANDALONE_SOURCE/scripts" "$STANDALONE_REPACK"
/bin/cp "$ROOT/scripts/prepare-standalone-docs.sh" "$STANDALONE_SOURCE/scripts/"
/bin/cp -R "$STANDALONE_ROOT/docs" "$STANDALONE_SOURCE/docs"
/bin/cp "$STANDALONE_ROOT/NOTICE.md" "$STANDALONE_REPACK/NOTICE.md"
"$STANDALONE_SOURCE/scripts/prepare-standalone-docs.sh" "$STANDALONE_REPACK"
REPACK_GUIDE="$STANDALONE_REPACK/docs/reference-background-prompt-guide.md"
/usr/bin/grep -F -q \
  'https://github.com/Fei-Away/Codex-Dream-Skin/blob/main/windows/assets/theme.json' \
  "$REPACK_GUIDE"
if /usr/bin/grep -E -q 'tree/main/windows/assets|blob/main/https://' "$REPACK_GUIDE"; then
  printf 'Standalone prompt URL rewriting is not idempotent.\n' >&2
  exit 1
fi

# SwiftBar attributes are line-based; unsafe engine paths must never be emitted
# into bash= or param*= fields.
UNSAFE_ENGINE="$TMP/unsafe\"engine"
/bin/mkdir -p "$UNSAFE_ENGINE/scripts"
/usr/bin/printf '#!/bin/bash\ntrue\n' > "$UNSAFE_ENGINE/scripts/start-dream-skin-macos.sh"
/bin/chmod +x "$UNSAFE_ENGINE/scripts/start-dream-skin-macos.sh"
UNSAFE_MENU_OUTPUT="$(
  /usr/bin/env CODEX_DREAM_SKIN_ENGINE="$UNSAFE_ENGINE" \
    "$ROOT/menubar/codex_dream_skin.10s.sh"
)"
/usr/bin/printf '%s\n' "$UNSAFE_MENU_OUTPUT" | /usr/bin/grep -F -q \
  'Engine path contains unsupported SwiftBar characters'
if /usr/bin/printf '%s\n' "$UNSAFE_MENU_OUTPUT" | /usr/bin/grep -F -q 'bash='; then
  printf 'SwiftBar emitted command attributes for an unsafe engine path.\n' >&2
  exit 1
fi

MENU_HOME="$TMP/menu-home"
MENU_IMAGES="$MENU_HOME/Library/Application Support/CodexDreamSkinStudio/images"
/bin/mkdir -p "$MENU_IMAGES"
: > "$MENU_IMAGES/safe-image.png"
: > "$MENU_IMAGES/"$'bad\timage.png'
: > "$MENU_IMAGES/"$'bad\033image.png'
MENU_IMAGE_OUTPUT="$(
  /usr/bin/env HOME="$MENU_HOME" CODEX_DREAM_SKIN_ENGINE="$ROOT" \
    "$ROOT/menubar/codex_dream_skin.10s.sh"
)"
/usr/bin/printf '%s\n' "$MENU_IMAGE_OUTPUT" | /usr/bin/grep -F -q 'safe-image.png'
if /usr/bin/printf '%s\n' "$MENU_IMAGE_OUTPUT" | /usr/bin/grep -F -q 'bad'; then
  printf 'SwiftBar emitted a control-character image filename.\n' >&2
  exit 1
fi

# seed_bundled_presets is idempotent and must never touch user custom-* packs.
/usr/bin/env HOME="$TMP/seed-home" /bin/bash -c '
  . "$1/scripts/common-macos.sh"
  ensure_state_root
  themes="$STATE_ROOT/themes"
  /bin/mkdir -p "$themes/custom-keepme"
  : > "$themes/custom-keepme/theme.json"
  seed_bundled_presets
  seed_bundled_presets
  [ -f "$themes/preset-midnight-aurora/theme.json" ] || exit 1
  [ -f "$themes/preset-midnight-aurora/background.jpg" ] || exit 1
  [ -f "$themes/custom-keepme/theme.json" ] || exit 1
  seeded="$(/usr/bin/find "$themes" -maxdepth 1 -type d -name "preset-*" | /usr/bin/wc -l | /usr/bin/tr -d " ")"
  [ "$seeded" -ge 4 ] || exit 1
' _ "$ROOT"

# Theme switches stage files and publish theme.json last, preserving a complete
# active pack while the watcher is running.
SWITCH_HOME="$TMP/switch-home"
SWITCH_STATE="$SWITCH_HOME/Library/Application Support/CodexDreamSkinStudio"
/bin/mkdir -p "$SWITCH_STATE/themes/preset-switch-fixture" "$SWITCH_STATE/theme"
/bin/cp "$ROOT/assets/portal-hero.png" "$SWITCH_STATE/themes/preset-switch-fixture/background.png"
/usr/bin/printf '%s\n' \
  '{"schemaVersion":1,"id":"preset-switch-fixture","name":"切换测试","image":"background.png"}' \
  > "$SWITCH_STATE/themes/preset-switch-fixture/theme.json"
/usr/bin/printf '%s\n' '{"schemaVersion":1,"id":"old","name":"旧主题","image":"old.png"}' \
  > "$SWITCH_STATE/theme/theme.json"
: > "$SWITCH_STATE/theme/old.png"
if /usr/bin/env HOME="$SWITCH_HOME" NODE="$NODE" \
  "$ROOT/scripts/switch-theme-macos.sh" --id '../escape' --no-apply >/dev/null 2>&1; then
  printf 'switch-theme unexpectedly accepted a path traversal theme id.\n' >&2
  exit 1
fi
/usr/bin/env HOME="$SWITCH_HOME" NODE="$NODE" \
  "$ROOT/scripts/switch-theme-macos.sh" --id preset-switch-fixture --no-apply >/dev/null
/usr/bin/cmp -s "$SWITCH_STATE/theme/background.png" \
  "$SWITCH_STATE/themes/preset-switch-fixture/background.png"
[ ! -e "$SWITCH_STATE/theme/old.png" ]
"$NODE" -e '
  const fs = require("fs");
  const theme = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (theme.id !== "preset-switch-fixture" || theme.name !== "切换测试") process.exit(1);
' "$SWITCH_STATE/theme/theme.json"
[ -z "$(/usr/bin/find "$SWITCH_STATE" -maxdepth 1 -name '.theme-switch.*' -print -quit)" ]

RUNTIME_HOME="$TMP/runtime-home"
RUNTIME_STATE_ROOT="$RUNTIME_HOME/Library/Application Support/CodexDreamSkinStudio"
RUNTIME_STATE="$RUNTIME_STATE_ROOT/state.json"
STATE_EVAL_MARKER="$TMP/state-eval-marker"
# Bundle/exe must exist for restore to trust them (Codex.app→ChatGPT.app rename),
# so build a real bundle whose name still carries spaces/quotes. Shell-injection
# probing moves to the version field, which restore accepts verbatim.
EXPECTED_BUNDLE="$TMP/evil-root/Codex \"Skin\".app"
EXPECTED_EXE="$EXPECTED_BUNDLE/Contents/MacOS/ChatGPT"
EXPECTED_VERSION="1.1.2 \$(touch \"$STATE_EVAL_MARKER\") ; echo pwned"
EXPECTED_TEAM_ID="TEAM'ID"
/bin/mkdir -p "$RUNTIME_STATE_ROOT" "$EXPECTED_BUNDLE/Contents/MacOS"
/usr/bin/printf '#!/bin/bash\ntrue\n' > "$EXPECTED_EXE"
/bin/chmod +x "$EXPECTED_EXE"
"$NODE" -e '
  const fs = require("node:fs");
  const [file, codexBundle, codexExe, codexVersion, codexTeamId] = process.argv.slice(1);
  fs.writeFileSync(file, `${JSON.stringify({ codexBundle, codexExe, codexVersion, codexTeamId })}\n`);
' "$RUNTIME_STATE" "$EXPECTED_BUNDLE" "$EXPECTED_EXE" "$EXPECTED_VERSION" "$EXPECTED_TEAM_ID"
/usr/bin/env -u NODE -u NODE_VERSION HOME="$RUNTIME_HOME" /bin/bash -c '
  . "$1/scripts/common-macos.sh"
  ensure_node_runtime
  [ "$CODEX_BUNDLE" = "$2" ]
  [ "$CODEX_EXE" = "$3" ]
  [ "$CODEX_VERSION" = "$4" ]
  [ "$CODEX_TEAM_ID" = "$5" ]
' _ "$ROOT" "$EXPECTED_BUNDLE" "$EXPECTED_EXE" "$EXPECTED_VERSION" "$EXPECTED_TEAM_ID"
[ ! -e "$STATE_EVAL_MARKER" ] || {
  printf 'Runtime state values were evaluated as shell code.\n' >&2
  exit 1
}

# A reused live PID must never be killed or treated as a successfully stopped
# injector when its command identity does not match the recorded watcher.
STOP_HOME="$TMP/stop-home"
STOP_STATE_ROOT="$STOP_HOME/Library/Application Support/CodexDreamSkinStudio"
/bin/mkdir -p "$STOP_STATE_ROOT"
"$NODE" -e 'process.on("SIGTERM", () => process.exit(0)); setTimeout(() => {}, 30000);' &
DUMMY_PID="$!"
"$NODE" -e '
  const fs = require("node:fs");
  const [file, pid, node, injector] = process.argv.slice(1);
  fs.writeFileSync(file, `${JSON.stringify({
    port: 9341,
    injectorPid: Number(pid),
    injectorStartedAt: "not-the-real-start-time",
    nodePath: node,
    injectorPath: injector,
  })}\n`);
' "$STOP_STATE_ROOT/state.json" "$DUMMY_PID" "$NODE" "$ROOT/scripts/injector.mjs"
/usr/bin/env HOME="$STOP_HOME" NODE="$NODE" /bin/bash -c '
  . "$1/scripts/common-macos.sh"
  INJECTOR_JOB_LABEL="$3"
  if stop_recorded_injector 2>/dev/null; then exit 1; fi
  /bin/kill -0 "$2"
' _ "$ROOT" "$DUMMY_PID" "$TEST_INJECTOR_JOB_LABEL"

# An incomplete live identity (even with a valid PID and port) must also fail
# closed before any signal is sent.
"$NODE" -e '
  const fs = require("node:fs");
  const [file, pid] = process.argv.slice(1);
  fs.writeFileSync(file, `${JSON.stringify({ port: 9341, injectorPid: Number(pid) })}\n`);
' "$STOP_STATE_ROOT/state.json" "$DUMMY_PID"
/usr/bin/env HOME="$STOP_HOME" NODE="$NODE" /bin/bash -c '
  . "$1/scripts/common-macos.sh"
  INJECTOR_JOB_LABEL="$3"
  if stop_recorded_injector 2>/dev/null; then exit 1; fi
  /bin/kill -0 "$2"
' _ "$ROOT" "$DUMMY_PID" "$TEST_INJECTOR_JOB_LABEL"

# Restore a complete (but still intentionally mismatched) record before
# ending the fixture so the dead-PID cleanup path remains testable.
"$NODE" -e '
  const fs = require("node:fs");
  const [file, pid, node, injector] = process.argv.slice(1);
  fs.writeFileSync(file, `${JSON.stringify({
    port: 9341,
    injectorPid: Number(pid),
    injectorStartedAt: "not-the-real-start-time",
    nodePath: node,
    injectorPath: injector,
  })}\n`);
' "$STOP_STATE_ROOT/state.json" "$DUMMY_PID" "$NODE" "$ROOT/scripts/injector.mjs"
/bin/kill -TERM "$DUMMY_PID" 2>/dev/null || true
wait "$DUMMY_PID" 2>/dev/null || true
DUMMY_PID=""

# A genuinely dead recorded PID is safe to discard (and must not block a
# subsequent start/restore operation).
/usr/bin/env HOME="$STOP_HOME" NODE="$NODE" /bin/bash -c '
  . "$1/scripts/common-macos.sh"
  INJECTOR_JOB_LABEL="$2"
  stop_recorded_injector
' _ "$ROOT" "$TEST_INJECTOR_JOB_LABEL"

# SwiftBar status must not call a live, reused PID "active" merely because
# kill -0 succeeds.  A watcher state needs matching command/path/start data.
STATUS_HOME="$TMP/status-home"
STATUS_STATE_ROOT="$STATUS_HOME/Library/Application Support/CodexDreamSkinStudio"
/bin/mkdir -p "$STATUS_STATE_ROOT"
"$NODE" -e 'process.on("SIGTERM", () => process.exit(0)); setTimeout(() => {}, 30000);' &
STATUS_PID="$!"
"$NODE" -e '
  const fs = require("node:fs");
  const [file, pid] = process.argv.slice(1);
  fs.writeFileSync(file, `${JSON.stringify({
    schemaVersion: 4,
    session: "active",
    port: 9341,
    injectorPid: Number(pid),
    injectorStartedAt: "not-the-real-start-time",
    injectorPath: "/tmp/not-the-dream-skin-injector.mjs",
    nodePath: "/tmp/not-the-codex-node",
  })}\n`);
' "$STATUS_STATE_ROOT/state.json" "$STATUS_PID"
STATUS_JSON="$(/usr/bin/env HOME="$STATUS_HOME" "$ROOT/scripts/status-dream-skin-macos.sh" --json)"
"$NODE" -e '
  const value = JSON.parse(process.argv[1]);
  if (value.session !== "stale" || value.injectorAlive !== false) process.exit(1);
' "$STATUS_JSON"
/bin/kill -TERM "$STATUS_PID" 2>/dev/null || true
wait "$STATUS_PID" 2>/dev/null || true
STATUS_PID=""

# A near-prefix port (93410) must not satisfy the saved 9341 identity.  Use a
# real bundled Node process so command/path/start checks pass and only the
# token boundary distinguishes this case.
STATUS_FAKE_INJECTOR="$TMP/status-fake-injector.mjs"
/usr/bin/printf 'setTimeout(() => {}, 30000);\n' > "$STATUS_FAKE_INJECTOR"
"$NODE" "$STATUS_FAKE_INJECTOR" --watch --port 93410 --theme-dir "$TMP" &
STATUS_PID="$!"
/bin/sleep 0.08
STATUS_START="$(/bin/ps -p "$STATUS_PID" -o lstart= 2>/dev/null | /usr/bin/awk '{$1=$1; print}')"
"$NODE" -e '
  const fs = require("node:fs");
  const [file, pid, node, injector, startedAt] = process.argv.slice(1);
  fs.writeFileSync(file, `${JSON.stringify({
    schemaVersion: 4,
    session: "active",
    port: 9341,
    injectorPid: Number(pid),
    injectorStartedAt: startedAt,
    injectorPath: injector,
    nodePath: node,
  })}\n`);
' "$STATUS_STATE_ROOT/state.json" "$STATUS_PID" "$NODE" "$STATUS_FAKE_INJECTOR" "$STATUS_START"
STATUS_JSON="$(/usr/bin/env HOME="$STATUS_HOME" "$ROOT/scripts/status-dream-skin-macos.sh" --json)"
"$NODE" -e '
  const value = JSON.parse(process.argv[1]);
  if (value.session !== "stale" || value.injectorAlive !== false) process.exit(1);
' "$STATUS_JSON"
/bin/kill -TERM "$STATUS_PID" 2>/dev/null || true
wait "$STATUS_PID" 2>/dev/null || true
STATUS_PID=""

# The common stop path must reject a real watcher running on 19341 when the
# saved state claims 1934, even though nodePath/injectorPath/start-time all
# match. This exercises the signal gate directly (status has its own matcher).
"$NODE" "$ROOT/scripts/injector.mjs" --watch --port 19341 --theme-dir "$ROOT/presets/preset-midnight-aurora" \
  >"$TMP/near-prefix-injector.out" 2>&1 &
WATCH_PID="$!"
/bin/sleep 0.2
WATCH_START="$(/bin/ps -p "$WATCH_PID" -o lstart= 2>/dev/null | /usr/bin/awk '{$1=$1; print}')"
[ -n "$WATCH_START" ] || { printf 'Could not record near-prefix watcher start time.\n' >&2; exit 1; }
"$NODE" -e '
  const fs = require("node:fs");
  const [file, pid, node, injector, startedAt] = process.argv.slice(1);
  fs.writeFileSync(file, `${JSON.stringify({
    schemaVersion: 4,
    session: "active",
    port: 1934,
    injectorPid: Number(pid),
    injectorStartedAt: startedAt,
    injectorPath: injector,
    nodePath: node,
  })}\n`);
' "$STOP_STATE_ROOT/state.json" "$WATCH_PID" "$NODE" "$ROOT/scripts/injector.mjs" "$WATCH_START"
if /usr/bin/env HOME="$STOP_HOME" NODE="$NODE" /bin/bash -c '
  . "$1/scripts/common-macos.sh"
  INJECTOR_JOB_LABEL="$2"
  stop_recorded_injector 2>/dev/null
' _ "$ROOT" "$TEST_INJECTOR_JOB_LABEL"; then
  printf 'common stop unexpectedly accepted a near-prefix watcher port.\n' >&2
  exit 1
fi
/bin/kill -0 "$WATCH_PID"
/bin/kill -TERM "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
WATCH_PID=""

# A failed start must prove the recorded watcher stopped before deleting its
# state; this static guard prevents the old launchctl-short-circuit cleanup.
/usr/bin/grep -F -q 'set -Eeuo pipefail' "$ROOT/scripts/start-dream-skin-macos.sh"
/usr/bin/grep -F -q 'if "$NODE" "$INJECTOR" --verify' \
  "$ROOT/scripts/start-dream-skin-macos.sh"
if /usr/bin/grep -F -q 'set +e' "$ROOT/scripts/start-dream-skin-macos.sh"; then
  printf 'start script still disables errexit around expected verify retries.\n' >&2
  exit 1
fi
/usr/bin/grep -F -q 'if ! stop_recorded_injector; then' \
  "$ROOT/scripts/start-dream-skin-macos.sh"
if /usr/bin/grep -F -q 'launchctl remove "$INJECTOR_JOB_LABEL" >/dev/null 2>&1 || /bin/kill -TERM "$INJECTOR_PID"' \
  "$ROOT/scripts/start-dream-skin-macos.sh"; then
  printf 'start script still deletes state without identity-bound injector cleanup.\n' >&2
  exit 1
fi
if /usr/bin/grep -F -q 'index($0, "--port " port)' "$ROOT/scripts/common-macos.sh"; then
  printf 'injector discovery still accepts a near-prefix port.\n' >&2
  exit 1
fi

# Corrupt or structurally incomplete state must be preserved and fail closed;
# otherwise pause/restore could overwrite evidence while a watcher survives.
for state_payload in '{' '{}'; do
  /usr/bin/printf '%s\n' "$state_payload" > "$STOP_STATE_ROOT/state.json"
  /bin/cp "$STOP_STATE_ROOT/state.json" "$STOP_STATE_ROOT/state.original"
  /usr/bin/env HOME="$STOP_HOME" NODE="$NODE" /bin/bash -c '
    . "$1/scripts/common-macos.sh"
    INJECTOR_JOB_LABEL="$2"
    if stop_recorded_injector 2>/dev/null; then exit 1; fi
  ' _ "$ROOT" "$TEST_INJECTOR_JOB_LABEL"
  /usr/bin/cmp -s "$STOP_STATE_ROOT/state.json" "$STOP_STATE_ROOT/state.original"
done

/bin/mkdir -p "$TMP/theme"
/bin/cp "$ROOT/assets/portal-hero.png" "$TMP/theme/background.png"
"$NODE" "$ROOT/scripts/write-theme.mjs" custom --output-dir "$TMP/theme" \
  --image background.png --name '测试主题' --tagline '测试口号' --quote 'TEST' \
  --accent '#11aa55' --secondary '#22bbcc' --highlight '#663399' >/dev/null
PAYLOAD_JSON="$("$NODE" "$ROOT/scripts/injector.mjs" --check-payload --theme-dir "$TMP/theme")"
"$NODE" -e '
  const theme = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  if (theme.appearance !== "auto") process.exit(1);
  if (theme.art?.safeArea !== "auto" || theme.art?.taskMode !== "auto") process.exit(1);
  if (Object.hasOwn(theme.art, "focusX") || Object.hasOwn(theme.art, "focusY")) process.exit(1);
' "$TMP/theme/theme.json"
"$NODE" -e '
  const value = JSON.parse(process.argv[1]);
  if (!value.pass || value.themeName !== "测试主题" || value.imageBytes < 1) process.exit(1);
  if (value.artMetadata?.width !== 2168 || value.artMetadata?.height !== 725) process.exit(1);
  if (!value.artMetadata.wide || value.artMetadata.aspect !== "ultrawide") process.exit(1);
  if (!Number.isFinite(value.timings?.buildMs) || value.timings.buildMs < 0) process.exit(1);
' "$PAYLOAD_JSON"

/bin/mkdir -p "$TMP/explicit-theme"
/bin/cp "$ROOT/assets/portal-hero.png" "$TMP/explicit-theme/background.png"
"$NODE" "$ROOT/scripts/write-theme.mjs" custom --output-dir "$TMP/explicit-theme" \
  --image background.png --name '显式自适应主题' --appearance dark \
  --focus-x 0.12 --focus-y 0.88 --safe-area none --task-mode off >/dev/null
EXPLICIT_PAYLOAD_JSON="$(
  "$NODE" "$ROOT/scripts/injector.mjs" --check-payload --theme-dir "$TMP/explicit-theme"
)"
"$NODE" -e '
  const fs = require("fs");
  const theme = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const payload = JSON.parse(process.argv[2]);
  if (theme.appearance !== "dark") process.exit(1);
  if (theme.art?.focusX !== 0.12 || theme.art?.focusY !== 0.88) process.exit(1);
  if (theme.art?.safeArea !== "none" || theme.art?.taskMode !== "off") process.exit(1);
  if (!payload.pass || payload.themeName !== "显式自适应主题") process.exit(1);
' "$TMP/explicit-theme/theme.json" "$EXPLICIT_PAYLOAD_JSON"

assert_write_theme_rejected() {
  local label="$1"
  shift
  if "$NODE" "$ROOT/scripts/write-theme.mjs" custom --output-dir "$TMP/explicit-theme" \
    --image background.png "$@" >/dev/null 2>&1; then
    printf 'write-theme unexpectedly accepted invalid %s.\n' "$label" >&2
    exit 1
  fi
}
assert_write_theme_rejected appearance --appearance sepia
assert_write_theme_rejected safe-area --safe-area edge
assert_write_theme_rejected task-mode --task-mode fullscreen
assert_write_theme_rejected focus-x --focus-x -0.01
assert_write_theme_rejected focus-y --focus-y 1.01
assert_write_theme_rejected name-control --name $'unsafe\nname'
assert_write_theme_rejected tagline-control --tagline $'unsafe\rtagline'
assert_write_theme_rejected quote-control --quote $'unsafe\033quote'
CONTROL_IMAGE=$'unsafe\nimage.jpg'
/bin/cp "$TMP/explicit-theme/background.png" "$TMP/explicit-theme/$CONTROL_IMAGE"
if "$NODE" "$ROOT/scripts/write-theme.mjs" custom --output-dir "$TMP/explicit-theme" \
  --image "$CONTROL_IMAGE" >/dev/null 2>&1; then
  printf 'write-theme unexpectedly accepted a control-character image filename.\n' >&2
  exit 1
fi
/bin/rm -f "$TMP/explicit-theme/$CONTROL_IMAGE"

"$NODE" -e '
  const fs = require("fs");
  const path = require("path");
  const [source, root] = process.argv.slice(1);
  const cases = {
    appearance: (theme) => { theme.appearance = "sepia"; },
    "safe-area": (theme) => { theme.art.safeArea = "edge"; },
    "task-mode": (theme) => { theme.art.taskMode = "fullscreen"; },
    "focus-x": (theme) => { theme.art.focusX = -0.01; },
    "focus-y": (theme) => { theme.art.focusY = 1.01; },
    "name-control": (theme) => { theme.name = "unsafe\nname"; },
  };
  for (const [name, mutate] of Object.entries(cases)) {
    const target = path.join(root, name);
    fs.cpSync(source, target, { recursive: true });
    const configPath = path.join(target, "theme.json");
    const theme = JSON.parse(fs.readFileSync(configPath, "utf8"));
    mutate(theme);
    fs.writeFileSync(configPath, `${JSON.stringify(theme, null, 2)}\n`);
  }
' "$TMP/explicit-theme" "$TMP/invalid-payloads"
for invalid_case in appearance safe-area task-mode focus-x focus-y name-control; do
  if INVALID_OUTPUT="$(
    "$NODE" "$ROOT/scripts/injector.mjs" --check-payload \
      --theme-dir "$TMP/invalid-payloads/$invalid_case" 2>&1
  )"; then
    printf 'injector unexpectedly accepted invalid %s.\n' "$invalid_case" >&2
    exit 1
  fi
  case "$invalid_case" in
    appearance) EXPECTED_INVALID_FIELD='appearance' ;;
    safe-area) EXPECTED_INVALID_FIELD='art.safeArea' ;;
    task-mode) EXPECTED_INVALID_FIELD='art.taskMode' ;;
    focus-x) EXPECTED_INVALID_FIELD='art.focusX' ;;
    focus-y) EXPECTED_INVALID_FIELD='art.focusY' ;;
    name-control) EXPECTED_INVALID_FIELD='name' ;;
  esac
  /usr/bin/printf '%s\n' "$INVALID_OUTPUT" | /usr/bin/grep -F -q \
    "invalid $EXPECTED_INVALID_FIELD field"
done

/bin/mkdir -p "$TMP/missing-theme"
if MISSING_THEME_OUTPUT="$(
  "$NODE" "$ROOT/scripts/injector.mjs" --check-payload --theme-dir "$TMP/missing-theme" 2>&1
)"; then
  printf 'Explicit theme directory without theme.json unexpectedly passed.\n' >&2
  exit 1
fi
/usr/bin/printf '%s\n' "$MISSING_THEME_OUTPUT" | /usr/bin/grep -F -q \
  "Explicit theme directory is missing theme.json: $TMP/missing-theme/theme.json"

# A theme config or image symlink may resolve only inside its own theme root.
/bin/mkdir -p "$TMP/symlink-outside" "$TMP/symlink-image-theme" "$TMP/symlink-config-theme"
/bin/cp "$ROOT/assets/portal-hero.png" "$TMP/symlink-outside/background.png"
/usr/bin/printf '%s\n' \
  '{"schemaVersion":1,"id":"symlink-image","name":"Symlink image","image":"background.png"}' \
  > "$TMP/symlink-image-theme/theme.json"
/bin/ln -s "$TMP/symlink-outside/background.png" "$TMP/symlink-image-theme/background.png"
if SYMLINK_IMAGE_OUTPUT="$(
  "$NODE" "$ROOT/scripts/injector.mjs" --check-payload --theme-dir "$TMP/symlink-image-theme" 2>&1
)"; then
  printf 'Injector unexpectedly accepted a theme image symlink escaping its theme directory.\n' >&2
  exit 1
fi
/usr/bin/printf '%s\n' "$SYMLINK_IMAGE_OUTPUT" | /usr/bin/grep -F -q \
  'Theme image must stay inside its theme directory'
/usr/bin/printf '%s\n' \
  '{"schemaVersion":1,"id":"symlink-config","name":"Symlink config","image":"background.png"}' \
  > "$TMP/symlink-outside/theme.json"
/bin/ln -s "$TMP/symlink-outside/theme.json" "$TMP/symlink-config-theme/theme.json"
if SYMLINK_CONFIG_OUTPUT="$(
  "$NODE" "$ROOT/scripts/injector.mjs" --check-payload --theme-dir "$TMP/symlink-config-theme" 2>&1
)"; then
  printf 'Injector unexpectedly accepted a theme config symlink escaping its theme directory.\n' >&2
  exit 1
fi
/usr/bin/printf '%s\n' "$SYMLINK_CONFIG_OUTPUT" | /usr/bin/grep -F -q \
  'Theme config must stay inside its theme directory'

# Exercise the dimension limit through the complete payload loader, not only
# through the standalone metadata parser.
OVERSIZED_DIMENSION_THEME="$TMP/oversized-dimension-theme"
/bin/mkdir -p "$OVERSIZED_DIMENSION_THEME"
"$NODE" -e '
  const fs = require("node:fs");
  const file = process.argv[1];
  const value = Buffer.alloc(24);
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(value);
  value.writeUInt32BE(13, 8);
  value.write("IHDR", 12, "ascii");
  value.writeUInt32BE(16385, 16);
  value.writeUInt32BE(1, 20);
  fs.writeFileSync(file, value);
' "$OVERSIZED_DIMENSION_THEME/oversized.png"
/usr/bin/printf '%s\n' \
  '{"schemaVersion":1,"id":"oversized","name":"Oversized","image":"oversized.png"}' \
  > "$OVERSIZED_DIMENSION_THEME/theme.json"
if OVERSIZED_DIMENSION_OUTPUT="$(
  "$NODE" "$ROOT/scripts/injector.mjs" --check-payload \
    --theme-dir "$OVERSIZED_DIMENSION_THEME" 2>&1
)"; then
  printf 'Injector unexpectedly accepted an image over the dimension limit.\n' >&2
  exit 1
fi
/usr/bin/printf '%s\n' "$OVERSIZED_DIMENSION_OUTPUT" | /usr/bin/grep -F -q \
  'invalid or exceeds the 16384px / 50MP safety limit'

# reset-demo must reject realpath aliases back into its own project, including
# case aliases on the default case-insensitive macOS filesystem.
RESET_FIXTURE="$TMP/Reset-Project"
/bin/mkdir -p "$RESET_FIXTURE/scripts"
/bin/cp "$ROOT/scripts/write-theme.mjs" "$RESET_FIXTURE/scripts/write-theme.mjs"
: > "$RESET_FIXTURE/keep-me"
/bin/ln -s "$RESET_FIXTURE" "$TMP/reset-project-link"
if "$NODE" "$RESET_FIXTURE/scripts/write-theme.mjs" reset-demo \
  --output-dir "$TMP/reset-project-link" >/dev/null 2>&1; then
  printf 'reset-demo unexpectedly accepted a realpath alias to its project.\n' >&2
  exit 1
fi
[ -f "$RESET_FIXTURE/keep-me" ]
[ -L "$TMP/reset-project-link" ]
RESET_CASE_ALIAS="$TMP/reset-project"
if [ -f "$RESET_CASE_ALIAS/keep-me" ]; then
  if "$NODE" "$RESET_FIXTURE/scripts/write-theme.mjs" reset-demo \
    --output-dir "$RESET_CASE_ALIAS" >/dev/null 2>&1; then
    printf 'reset-demo unexpectedly accepted a case alias to its project.\n' >&2
    exit 1
  fi
  [ -f "$RESET_FIXTURE/keep-me" ]
fi
"$NODE" "$ROOT/scripts/write-theme.mjs" reset-demo --output-dir "$TMP/theme" >/dev/null
[ ! -e "$TMP/theme" ]

CONFIG="$TMP/config.toml"
BACKUP="$TMP/theme-backup.json"
/usr/bin/printf '%s\n' \
  'model = "gpt-5"' \
  'project = "中文项目"' \
  '' \
  '[desktop]' \
  'appearanceTheme = "system"' \
  'appearanceDarkCodeThemeId = "vscode-dark"' \
  'keepMe = true' > "$CONFIG"
/bin/cp "$CONFIG" "$TMP/original.toml"
"$NODE" "$ROOT/scripts/theme-config.mjs" install "$CONFIG" "$BACKUP" >/dev/null
/usr/bin/cmp -s "$CONFIG" "$TMP/original.toml"
"$NODE" -e '
  const backup = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  if (backup.values.appearanceTheme !== `appearanceTheme = "system"`) process.exit(1);
  if (backup.values.appearanceDarkCodeThemeId !== `appearanceDarkCodeThemeId = "vscode-dark"`) process.exit(1);
' "$BACKUP"
"$NODE" "$ROOT/scripts/theme-config.mjs" restore "$CONFIG" "$BACKUP" >/dev/null
/usr/bin/cmp -s "$CONFIG" "$TMP/original.toml"

assert_theme_config_restore_rejected() {
  local label="$1"
  local config="$2"
  local backup="$3"
  /bin/cp "$config" "$config.original"
  if "$NODE" "$ROOT/scripts/theme-config.mjs" restore "$config" "$backup" >/dev/null 2>&1; then
    printf 'theme-config unexpectedly accepted invalid %s backup.\n' "$label" >&2
    exit 1
  fi
  /usr/bin/cmp -s "$config" "$config.original"
  [ -e "$backup" ]
  [ ! -e "$config.dream-skin.lock" ]
}

MALICIOUS_BACKUP_CONFIG="$TMP/config-malicious-backup.toml"
/usr/bin/printf '%s\n' '[desktop]' 'keepMe = true' > "$MALICIOUS_BACKUP_CONFIG"
for backup_case in newline wrong-key unknown-key; do
  MALICIOUS_BACKUP="$TMP/theme-backup-$backup_case.json"
  "$NODE" -e '
    const fs = require("node:fs");
    const [file, configPath, kind] = process.argv.slice(1);
    const values = { appearanceTheme: null, appearanceDarkCodeThemeId: null };
    if (kind === "newline") values.appearanceTheme = `appearanceTheme = "dark"\nmodel = "unsafe"`;
    if (kind === "wrong-key") values.appearanceTheme = `model = "unsafe"`;
    if (kind === "unknown-key") values.unexpected = `unexpected = true`;
    fs.writeFileSync(file, `${JSON.stringify({
      schemaVersion: 1,
      platform: "darwin",
      configPath,
      values,
    }, null, 2)}\n`);
  ' "$MALICIOUS_BACKUP" "$MALICIOUS_BACKUP_CONFIG" "$backup_case"
  assert_theme_config_restore_rejected "$backup_case" \
    "$MALICIOUS_BACKUP_CONFIG" "$MALICIOUS_BACKUP"
  /bin/rm -f "$MALICIOUS_BACKUP"
done

NO_DESKTOP_CONFIG="$TMP/config-without-desktop.toml"
NO_DESKTOP_BACKUP="$TMP/theme-backup-without-desktop.json"
/usr/bin/printf '%s\n' 'model = "gpt-5"' 'keepMe = true' > "$NO_DESKTOP_CONFIG"
/bin/cp "$NO_DESKTOP_CONFIG" "$TMP/original-without-desktop.toml"
"$NODE" "$ROOT/scripts/theme-config.mjs" install "$NO_DESKTOP_CONFIG" "$NO_DESKTOP_BACKUP" >/dev/null
"$NODE" "$ROOT/scripts/theme-config.mjs" restore "$NO_DESKTOP_CONFIG" "$NO_DESKTOP_BACKUP" >/dev/null
/usr/bin/cmp -s "$NO_DESKTOP_CONFIG" "$TMP/original-without-desktop.toml"

INVALID_UTF_CONFIG="$TMP/config-invalid-utf8.toml"
INVALID_UTF_BACKUP="$TMP/config-invalid-utf8-backup.json"
/usr/bin/printf 'model = "gpt-5"\n# invalid: ' > "$INVALID_UTF_CONFIG"
/usr/bin/printf '\377\n' >> "$INVALID_UTF_CONFIG"
/bin/cp "$INVALID_UTF_CONFIG" "$TMP/original-invalid-utf8.toml"
if "$NODE" "$ROOT/scripts/theme-config.mjs" install \
  "$INVALID_UTF_CONFIG" "$INVALID_UTF_BACKUP" >/dev/null 2>&1; then
  printf 'theme-config unexpectedly accepted invalid UTF-8.\n' >&2
  exit 1
fi
/usr/bin/cmp -s "$INVALID_UTF_CONFIG" "$TMP/original-invalid-utf8.toml"
[ ! -e "$INVALID_UTF_BACKUP" ]
[ ! -e "$INVALID_UTF_CONFIG.dream-skin.lock" ]

assert_theme_config_install_rejected() {
  local label="$1"
  local config="$2"
  local backup="$3"
  /bin/cp "$config" "$config.original"
  if "$NODE" "$ROOT/scripts/theme-config.mjs" install "$config" "$backup" >/dev/null 2>&1; then
    printf 'theme-config unexpectedly accepted invalid %s config.\n' "$label" >&2
    exit 1
  fi
  /usr/bin/cmp -s "$config" "$config.original"
  [ ! -e "$backup" ]
  [ ! -e "$config.dream-skin.lock" ]
}

SYMLINK_CONFIG_TARGET="$TMP/config-symlink-target.toml"
SYMLINK_CONFIG_PATH="$TMP/config-symlink.toml"
/usr/bin/printf '%s\n' '[desktop]' 'appearanceTheme = "system"' > "$SYMLINK_CONFIG_TARGET"
/bin/cp "$SYMLINK_CONFIG_TARGET" "$SYMLINK_CONFIG_TARGET.original"
/bin/ln -s "$SYMLINK_CONFIG_TARGET" "$SYMLINK_CONFIG_PATH"
assert_theme_config_install_rejected config-symlink "$SYMLINK_CONFIG_PATH" \
  "$TMP/config-symlink-backup.json"
[ -L "$SYMLINK_CONFIG_PATH" ]
/usr/bin/cmp -s "$SYMLINK_CONFIG_TARGET" "$SYMLINK_CONFIG_TARGET.original"

NUL_CONFIG="$TMP/config-nul.toml"
/usr/bin/printf 'model = "gpt-5"\n\000' > "$NUL_CONFIG"
assert_theme_config_install_rejected nul "$NUL_CONFIG" "$TMP/config-nul-backup.json"

DUPLICATE_DESKTOP_CONFIG="$TMP/config-duplicate-desktop.toml"
/usr/bin/printf '%s\n' '[desktop]' 'keep = 1' '[desktop]' 'keep = 2' \
  > "$DUPLICATE_DESKTOP_CONFIG"
assert_theme_config_install_rejected duplicate-desktop "$DUPLICATE_DESKTOP_CONFIG" \
  "$TMP/config-duplicate-desktop-backup.json"

MULTILINE_CONFIG="$TMP/config-multiline.toml"
/usr/bin/printf '%s\n' 'note = """value' 'continued"""' '[desktop]' 'keep = true' \
  > "$MULTILINE_CONFIG"
assert_theme_config_install_rejected multiline "$MULTILINE_CONFIG" \
  "$TMP/config-multiline-backup.json"

MULTILINE_ARRAY_CONFIG="$TMP/config-multiline-array.toml"
/usr/bin/printf '%s\n' '[desktop]' 'rows = [' '  ["one", "two"],' ']' \
  'appearanceTheme = "system"' > "$MULTILINE_ARRAY_CONFIG"
assert_theme_config_install_rejected multiline-array "$MULTILINE_ARRAY_CONFIG" \
  "$TMP/config-multiline-array-backup.json"

CRLF_CONFIG="$TMP/config-crlf.toml"
CRLF_BACKUP="$TMP/config-crlf-backup.json"
/usr/bin/printf '\357\273\277model = "gpt-5"\r\nproject = "中文项目"\r\n\r\n[desktop]\r\nappearanceTheme = "system"\r\n' \
  > "$CRLF_CONFIG"
/bin/cp "$CRLF_CONFIG" "$TMP/original-crlf.toml"
"$NODE" "$ROOT/scripts/theme-config.mjs" install "$CRLF_CONFIG" "$CRLF_BACKUP" >/dev/null
"$NODE" "$ROOT/scripts/theme-config.mjs" restore "$CRLF_CONFIG" "$CRLF_BACKUP" >/dev/null
/usr/bin/cmp -s "$CRLF_CONFIG" "$TMP/original-crlf.toml"

# Complete config restore must use the installed native helper when full app
# validation fails but the signed main executable remains safe to control.
NATIVE_HOME="$TMP/native-restore-home"
NATIVE_ENGINE="$NATIVE_HOME/.codex/codex-dream-skin-studio"
NATIVE_STATE="$NATIVE_HOME/Library/Application Support/CodexDreamSkinStudio"
NATIVE_MARKER="$TMP/native-restore-marker"
/bin/mkdir -p "$NATIVE_ENGINE/bin" "$NATIVE_ENGINE/scripts" "$NATIVE_STATE" "$NATIVE_HOME/.codex"
/bin/cp "$NATIVE_CONFIG_RESTORE" "$NATIVE_ENGINE/bin/dream-skin-config-restore"
/bin/cp "$ROOT/scripts/restore-dream-skin-macos.sh" "$NATIVE_ENGINE/scripts/"
/bin/cp "$ROOT/scripts/common-macos.sh" "$NATIVE_ENGINE/scripts/"
/usr/bin/printf '%s\n' \
  'model = "gpt-5"' \
  '' \
  '[desktop]' \
  'appearanceTheme = "dream-skin"' \
  'keepMe = "中文保留"' > "$NATIVE_HOME/.codex/config.toml"
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
' "$NATIVE_STATE/theme-backup.json" "$NATIVE_HOME/.codex/config.toml"
/usr/bin/printf '%s\n' '{"port":9341}' > "$NATIVE_STATE/state.json"
/usr/bin/sed "s|__MARKER__|$NATIVE_MARKER|g" \
  >> "$NATIVE_ENGINE/scripts/common-macos.sh" <<'STUB'
try_discover_codex_app() { printf 'discover\n' >> "__MARKER__"; return 0; }
try_validate_codex_app_identity() {
  CODEX_APP_VALIDATED=false
  printf 'deep-app-invalid\n' >> "__MARKER__"
  return 1
}
try_validate_codex_app_control_identity() {
  CODEX_APP_VALIDATED=false
  CODEX_APP_CONTROL_VALIDATED=true
  printf 'control-app-valid\n' >> "__MARKER__"
  return 0
}
try_require_macos_node_runtime() { printf 'node-validation\n' >> "__MARKER__"; return 1; }
try_require_macos_runtime() { printf 'legacy-runtime\n' >> "__MARKER__"; return 1; }
ensure_state_root() { :; }
state_field() { printf '9341\n'; }
codex_is_running() { return 0; }
verified_cdp_endpoint() { return 1; }
stop_codex() { printf 'stop:%s\n' "$1" >> "__MARKER__"; }
stop_recorded_injector() { printf 'stop-injector\n' >> "__MARKER__"; return 0; }
release_codex_launchd_job() { printf 'release-job\n' >> "__MARKER__"; return 0; }
launch_codex_normally() { printf 'launch\n' >> "__MARKER__"; }
STUB
: > "$NATIVE_MARKER"
NATIVE_OUTPUT="$(/usr/bin/env -u NODE HOME="$NATIVE_HOME" DREAM_SKIN_STUDIO_ADAPTER=true \
  "$NATIVE_ENGINE/scripts/restore-dream-skin-macos.sh" \
  --restore-base-theme --restart-codex --restart-authorized)"
/usr/bin/grep -F -q 'appearanceTheme = "system"' "$NATIVE_HOME/.codex/config.toml"
/usr/bin/grep -F -q 'keepMe = "中文保留"' "$NATIVE_HOME/.codex/config.toml"
[ ! -e "$NATIVE_STATE/theme-backup.json" ]
[ ! -e "$NATIVE_STATE/state.json" ]
/usr/bin/grep -Fx -q 'deep-app-invalid' "$NATIVE_MARKER"
/usr/bin/grep -Fx -q 'control-app-valid' "$NATIVE_MARKER"
/usr/bin/grep -Fx -q 'stop:false' "$NATIVE_MARKER"
/usr/bin/grep -Fx -q 'stop-injector' "$NATIVE_MARKER"
/usr/bin/grep -Fx -q 'release-job' "$NATIVE_MARKER"
/usr/bin/printf '%s\n' "$NATIVE_OUTPUT" | /usr/bin/grep -F -q \
  'Codex was not restarted because full app signature validation failed. Repair or reinstall the official Codex app, then open it again.'
if /usr/bin/grep -Eq '^(node-validation|legacy-runtime|launch)$' "$NATIVE_MARKER"; then
  printf 'Control-only restore validated Node, used legacy runtime validation, or relaunched Codex.\n' >&2
  exit 1
fi

assert_unsafe_native_restore_helper_rejected() {
  local kind="$1"
  local fixture_home="$TMP/native-helper-$kind-home"
  local fixture_engine="$fixture_home/.codex/codex-dream-skin-studio"
  local fixture_state="$fixture_home/Library/Application Support/CodexDreamSkinStudio"
  local fixture_helper="$fixture_engine/bin/dream-skin-config-restore"
  local fixture_marker="$TMP/native-helper-$kind-marker"
  local malicious_helper="$TMP/native-helper-$kind-malicious"
  local malicious_marker="$TMP/native-helper-$kind-malicious-marker"
  local error_path="$TMP/native-helper-$kind.error"
  local restore_exit

  /bin/mkdir -p "$fixture_engine/bin" "$fixture_engine/scripts" "$fixture_state" \
    "$fixture_home/.codex"
  /bin/cp "$ROOT/scripts/restore-dream-skin-macos.sh" "$fixture_engine/scripts/"
  /bin/cp "$ROOT/scripts/common-macos.sh" "$fixture_engine/scripts/"
  /usr/bin/printf 'config sentinel\n' > "$fixture_home/.codex/config.toml"
  /usr/bin/printf 'backup sentinel\n' > "$fixture_state/theme-backup.json"
  /bin/cp "$fixture_home/.codex/config.toml" "$fixture_home/.codex/config.toml.original"
  /bin/cp "$fixture_state/theme-backup.json" "$fixture_state/theme-backup.json.original"
  /usr/bin/sed "s|__MARKER__|$malicious_marker|g" > "$malicious_helper" <<'STUB'
#!/bin/bash
: > "__MARKER__"
exit 0
STUB
  /bin/chmod 755 "$malicious_helper"
  case "$kind" in
    missing) : ;;
    symlink) /bin/ln -s "$malicious_helper" "$fixture_helper" ;;
    directory) /bin/mkdir "$fixture_helper" ;;
    *) printf 'Unknown native helper fixture: %s\n' "$kind" >&2; exit 1 ;;
  esac
  /usr/bin/sed "s|__MARKER__|$fixture_marker|g" \
    >> "$fixture_engine/scripts/common-macos.sh" <<'STUB'
try_discover_codex_app() { printf 'discover\n' >> "__MARKER__"; return 0; }
try_validate_codex_app_identity() { printf 'trusted-app\n' >> "__MARKER__"; return 0; }
try_require_macos_node_runtime() { printf 'missing-node\n' >> "__MARKER__"; return 1; }
state_field() { printf 'state-field\n' >> "__MARKER__"; return 1; }
codex_is_running() { printf 'process-probe\n' >> "__MARKER__"; return 1; }
ensure_state_root() { printf 'ensure-state\n' >> "__MARKER__"; }
verified_cdp_endpoint() { printf 'endpoint-probe\n' >> "__MARKER__"; return 1; }
stop_codex() { printf 'stop\n' >> "__MARKER__"; }
stop_recorded_injector() { printf 'stop-injector\n' >> "__MARKER__"; return 0; }
release_codex_launchd_job() { printf 'release-job\n' >> "__MARKER__"; return 0; }
launch_codex_normally() { printf 'launch\n' >> "__MARKER__"; }
STUB
  : > "$fixture_marker"

  set +e
  /usr/bin/env -u NODE HOME="$fixture_home" DREAM_SKIN_STUDIO_ADAPTER=true \
    "$fixture_engine/scripts/restore-dream-skin-macos.sh" \
    --restore-base-theme --restart-codex --restart-authorized \
    >/dev/null 2>"$error_path"
  restore_exit="$?"
  set -e

  [ "$restore_exit" -ne 0 ] || {
    printf 'Restore unexpectedly accepted a %s native helper.\n' "$kind" >&2
    exit 1
  }
  if /usr/bin/grep -Eq \
    '^(state-field|process-probe|ensure-state|endpoint-probe|stop|stop-injector|release-job|launch)$' \
    "$fixture_marker"; then
    printf 'Restore touched process or state hooks before rejecting a %s native helper.\n' "$kind" >&2
    exit 1
  fi
  /usr/bin/grep -F -q 'Native config restore helper is unsafe or missing' "$error_path" || {
    printf 'Restore did not report an unsafe or missing %s native helper.\n' "$kind" >&2
    exit 1
  }
  /usr/bin/cmp -s "$fixture_home/.codex/config.toml" \
    "$fixture_home/.codex/config.toml.original"
  /usr/bin/cmp -s "$fixture_state/theme-backup.json" \
    "$fixture_state/theme-backup.json.original"
  [ ! -e "$malicious_marker" ] || {
    printf 'Restore executed a rejected %s native helper.\n' "$kind" >&2
    exit 1
  }
}

for unsafe_native_helper_kind in missing symlink directory; do
  assert_unsafe_native_restore_helper_rejected "$unsafe_native_helper_kind"
done

# A valid helper can be replaced after preflight. The restore path must bind
# execution to the original device/inode and reject the swapped path.
RACE_HOME="$TMP/native-helper-race-home"
RACE_ENGINE="$RACE_HOME/.codex/codex-dream-skin-studio"
RACE_STATE="$RACE_HOME/Library/Application Support/CodexDreamSkinStudio"
RACE_HELPER="$RACE_ENGINE/bin/dream-skin-config-restore"
RACE_MARKER="$TMP/native-helper-race-marker"
RACE_MALICIOUS="$TMP/native-helper-race-malicious"
RACE_MALICIOUS_MARKER="$TMP/native-helper-race-malicious-marker"
RACE_ERROR="$TMP/native-helper-race.error"
/bin/mkdir -p "$RACE_ENGINE/bin" "$RACE_ENGINE/scripts" "$RACE_STATE" "$RACE_HOME/.codex"
/bin/cp "$NATIVE_CONFIG_RESTORE" "$RACE_HELPER"
/bin/cp "$ROOT/scripts/restore-dream-skin-macos.sh" "$RACE_ENGINE/scripts/"
/bin/cp "$ROOT/scripts/common-macos.sh" "$RACE_ENGINE/scripts/"
/usr/bin/printf 'config sentinel\n' > "$RACE_HOME/.codex/config.toml"
/usr/bin/printf 'backup sentinel\n' > "$RACE_STATE/theme-backup.json"
/bin/cp "$RACE_HOME/.codex/config.toml" "$RACE_HOME/.codex/config.toml.original"
/bin/cp "$RACE_STATE/theme-backup.json" "$RACE_STATE/theme-backup.json.original"
/usr/bin/sed "s|__MARKER__|$RACE_MALICIOUS_MARKER|g" > "$RACE_MALICIOUS" <<'STUB'
#!/bin/bash
: > "__MARKER__"
exit 0
STUB
/bin/chmod 755 "$RACE_MALICIOUS"
/usr/bin/sed \
  "s|__MARKER__|$RACE_MARKER|g; s|__MALICIOUS__|$RACE_MALICIOUS|g" \
  >> "$RACE_ENGINE/scripts/common-macos.sh" <<'STUB'
try_discover_codex_app() { return 0; }
try_validate_codex_app_identity() { return 0; }
try_require_macos_node_runtime() { return 1; }
codex_is_running() {
  /bin/mv "$INSTALL_ROOT/bin/dream-skin-config-restore" \
    "$INSTALL_ROOT/bin/dream-skin-config-restore.preflight"
  /bin/ln -s "__MALICIOUS__" "$INSTALL_ROOT/bin/dream-skin-config-restore"
  printf 'process-probe\n' >> "__MARKER__"
  return 1
}
ensure_state_root() { :; }
verified_cdp_endpoint() { return 1; }
release_codex_launchd_job() { return 0; }
launch_codex_normally() { printf 'launch\n' >> "__MARKER__"; }
STUB
: > "$RACE_MARKER"
set +e
/usr/bin/env -u NODE HOME="$RACE_HOME" DREAM_SKIN_STUDIO_ADAPTER=true \
  "$RACE_ENGINE/scripts/restore-dream-skin-macos.sh" \
  --restore-base-theme --restart-codex --restart-authorized \
  >/dev/null 2>"$RACE_ERROR"
RACE_EXIT="$?"
set -e
[ "$RACE_EXIT" -ne 0 ] || {
  printf 'Restore accepted a native helper swapped after preflight.\n' >&2
  exit 1
}
/usr/bin/grep -F -q 'Native config restore helper changed before execution' "$RACE_ERROR" || {
  printf 'Restore did not report a native helper changed after preflight.\n' >&2
  exit 1
}
/usr/bin/grep -Fx -q 'process-probe' "$RACE_MARKER"
if /usr/bin/grep -Fx -q 'launch' "$RACE_MARKER"; then
  printf 'Restore relaunched Codex after the native helper identity changed.\n' >&2
  exit 1
fi
[ ! -e "$RACE_MALICIOUS_MARKER" ] || {
  printf 'Restore executed a native helper swapped after preflight.\n' >&2
  exit 1
}
/usr/bin/cmp -s "$RACE_HOME/.codex/config.toml" "$RACE_HOME/.codex/config.toml.original"
/usr/bin/cmp -s "$RACE_STATE/theme-backup.json" "$RACE_STATE/theme-backup.json.original"

UNTRUSTED_HOME="$TMP/untrusted-app-home"
UNTRUSTED_ENGINE="$UNTRUSTED_HOME/.codex/codex-dream-skin-studio"
UNTRUSTED_STATE="$UNTRUSTED_HOME/Library/Application Support/CodexDreamSkinStudio"
UNTRUSTED_MARKER="$TMP/untrusted-app-marker"
/bin/mkdir -p "$UNTRUSTED_ENGINE/bin" "$UNTRUSTED_ENGINE/scripts" "$UNTRUSTED_STATE" "$UNTRUSTED_HOME/.codex"
/bin/cp "$NATIVE_CONFIG_RESTORE" "$UNTRUSTED_ENGINE/bin/dream-skin-config-restore"
/bin/cp "$ROOT/scripts/restore-dream-skin-macos.sh" "$UNTRUSTED_ENGINE/scripts/"
/usr/bin/printf 'config sentinel\n' > "$UNTRUSTED_HOME/.codex/config.toml"
/usr/bin/printf 'backup sentinel\n' > "$UNTRUSTED_STATE/theme-backup.json"
/usr/bin/sed "s|__HOME__|$UNTRUSTED_HOME|g; s|__ENGINE__|$UNTRUSTED_ENGINE|g; s|__MARKER__|$UNTRUSTED_MARKER|g" \
  > "$UNTRUSTED_ENGINE/scripts/common-macos.sh" <<'STUB'
INSTALL_ROOT="__ENGINE__"
STATE_ROOT="__HOME__/Library/Application Support/CodexDreamSkinStudio"
STATE_PATH="$STATE_ROOT/state.json"
THEME_BACKUP_PATH="$STATE_ROOT/theme-backup.json"
THEME_DIR="$STATE_ROOT/theme"
CONFIG_PATH="__HOME__/.codex/config.toml"
fail() { printf 'fixture: %s\n' "$*" >&2; exit 1; }
try_discover_codex_app() { return 0; }
try_validate_codex_app_identity() { printf 'untrusted-app\n' >> "__MARKER__"; return 1; }
try_validate_codex_app_control_identity() { printf 'untrusted-control\n' >> "__MARKER__"; return 1; }
try_require_macos_node_runtime() { printf 'node-validation\n' >> "__MARKER__"; return 0; }
try_require_macos_runtime() { return 0; }
codex_is_running() { printf 'process-probe\n' >> "__MARKER__"; return 0; }
stop_codex() { printf 'stop\n' >> "__MARKER__"; }
launch_codex_normally() { printf 'launch\n' >> "__MARKER__"; }
STUB
: > "$UNTRUSTED_MARKER"
set +e
/usr/bin/env -u NODE HOME="$UNTRUSTED_HOME" DREAM_SKIN_STUDIO_ADAPTER=true \
  "$UNTRUSTED_ENGINE/scripts/restore-dream-skin-macos.sh" \
  --restore-base-theme --restart-codex --restart-authorized >/dev/null 2>&1
UNTRUSTED_EXIT="$?"
set -e
[ "$UNTRUSTED_EXIT" -ne 0 ] || { printf 'Untrusted Codex app restore unexpectedly succeeded.\n' >&2; exit 1; }
/usr/bin/grep -Fx -q 'untrusted-app' "$UNTRUSTED_MARKER"
/usr/bin/grep -Fx -q 'untrusted-control' "$UNTRUSTED_MARKER"
if /usr/bin/grep -Eq '^(node-validation|process-probe|stop|launch)$' "$UNTRUSTED_MARKER"; then
  printf 'Untrusted Codex app was probed, stopped, or relaunched.\n' >&2
  exit 1
fi
[ "$(/bin/cat "$UNTRUSTED_HOME/.codex/config.toml")" = 'config sentinel' ]
[ "$(/bin/cat "$UNTRUSTED_STATE/theme-backup.json")" = 'backup sentinel' ]

# Full app identity must retain deep validation. A separate control-only layer
# may trust the signed main executable after nested resource validation fails.
# Replace only codesign so the real validators exercise exact command args.
APP_IDENTITY_HOME="$TMP/app-identity-home"
APP_IDENTITY_BUNDLE="$TMP/app-identity.app"
APP_IDENTITY_EXE="$APP_IDENTITY_BUNDLE/Contents/MacOS/Codex"
APP_IDENTITY_COMMON="$TMP/app-identity-common.sh"
APP_IDENTITY_CODESIGN="$TMP/app-identity-codesign"
APP_IDENTITY_LOG="$TMP/app-identity-codesign.log"
APP_IDENTITY_ERROR="$TMP/app-identity.error"
/bin/mkdir -p "$APP_IDENTITY_HOME" "$APP_IDENTITY_BUNDLE/Contents/MacOS"
/usr/bin/plutil -create xml1 "$APP_IDENTITY_BUNDLE/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string com.openai.codex \
  "$APP_IDENTITY_BUNDLE/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string Codex \
  "$APP_IDENTITY_BUNDLE/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string 1.0 \
  "$APP_IDENTITY_BUNDLE/Contents/Info.plist"
/usr/bin/printf '#!/bin/bash\nexit 0\n' > "$APP_IDENTITY_EXE"
/bin/chmod 755 "$APP_IDENTITY_EXE"
/usr/bin/sed \
  "s|__BUNDLE__|$APP_IDENTITY_BUNDLE|g; s|__EXE__|$APP_IDENTITY_EXE|g" \
  > "$APP_IDENTITY_CODESIGN" <<'STUB'
#!/bin/bash
mode="${CODESIGN_MODE:-valid}"
if [ "$#" -eq 4 ] && [ "$1" = "--verify" ] && [ "$2" = "--deep" ] \
  && [ "$3" = "--strict" ] && [ "$4" = "__BUNDLE__" ]; then
  printf 'verify-bundle-deep\n' >> "$CODESIGN_LOG"
  [ "$mode" != "bundle-signature" ] && [ "$mode" != "resource-tamper" ]
  exit
fi
if [ "$#" -eq 3 ] && [ "$1" = "--verify" ] && [ "$2" = "--strict" ] \
  && [ "$3" = "__EXE__" ]; then
  printf 'verify-executable\n' >> "$CODESIGN_LOG"
  [ "$mode" != "executable-signature" ]
  exit
fi
if [ "$#" -eq 3 ] && [ "$1" = "-dv" ] && [ "$2" = "--verbose=4" ]; then
  case "$3" in
    "__BUNDLE__")
      printf 'describe-bundle\n' >> "$CODESIGN_LOG"
      [ "$mode" = "bundle-identifier" ] \
        && printf 'Identifier=com.example.forged\n' >&2 \
        || printf 'Identifier=com.openai.codex\n' >&2
      printf 'TeamIdentifier=2DC432GLL2\n' >&2
      exit 0
      ;;
    "__EXE__")
      printf 'describe-executable\n' >> "$CODESIGN_LOG"
      [ "$mode" = "executable-identifier" ] \
        && printf 'Identifier=com.example.forged\n' >&2 \
        || printf 'Identifier=com.openai.codex\n' >&2
      [ "$mode" = "executable-team" ] \
        && printf 'TeamIdentifier=FORGEDTEAM\n' >&2 \
        || printf 'TeamIdentifier=2DC432GLL2\n' >&2
      exit 0
      ;;
  esac
fi
printf 'unexpected:' >> "$CODESIGN_LOG"
printf ' %s' "$@" >> "$CODESIGN_LOG"
printf '\n' >> "$CODESIGN_LOG"
exit 91
STUB
/bin/chmod 755 "$APP_IDENTITY_CODESIGN"
/usr/bin/sed "s|/usr/bin/codesign|$APP_IDENTITY_CODESIGN|g" \
  "$ROOT/scripts/common-macos.sh" > "$APP_IDENTITY_COMMON"
: > "$APP_IDENTITY_LOG"
if ! /usr/bin/env HOME="$APP_IDENTITY_HOME" CODEX_APP_BUNDLE="$APP_IDENTITY_BUNDLE" \
  CODESIGN_LOG="$APP_IDENTITY_LOG" CODESIGN_MODE=valid /bin/bash -c '
    . "$1"
    try_discover_codex_app
    try_validate_codex_app_identity
    [ "$CODEX_APP_VALIDATED" = "true" ]
    [ "${CODEX_APP_CONTROL_VALIDATED:-false}" = "false" ]
    [ ! -e "$CODEX_BUNDLE/Contents/Resources/cua_node/bin/node" ]
    if try_require_macos_node_runtime 2>"$2"; then exit 1; fi
    [ "$CODEX_APP_VALIDATED" = "true" ]
    [ "$NODE_RUNTIME_VALIDATED" = "false" ]
    /usr/bin/grep -F -q "signed Node.js runtime bundled with Codex was not found" "$2"
  ' _ "$APP_IDENTITY_COMMON" "$APP_IDENTITY_ERROR"; then
  printf 'Missing nested Node invalidated the trusted main Codex app identity.\n' >&2
  exit 1
fi
/usr/bin/printf '%s\n' \
  verify-bundle-deep describe-bundle describe-bundle \
  verify-executable describe-executable describe-executable \
  > "$TMP/app-identity-codesign.expected"
/usr/bin/cmp -s "$APP_IDENTITY_LOG" "$TMP/app-identity-codesign.expected" || {
  printf 'Main Codex app identity validation used unexpected codesign branches.\n' >&2
  exit 1
}

: > "$APP_IDENTITY_LOG"
/usr/bin/env HOME="$APP_IDENTITY_HOME" CODEX_APP_BUNDLE="$APP_IDENTITY_BUNDLE" \
  CODESIGN_LOG="$APP_IDENTITY_LOG" CODESIGN_MODE=resource-tamper /bin/bash -c '
    . "$1"
    try_discover_codex_app
    if try_validate_codex_app_identity >/dev/null 2>&1; then exit 1; fi
    [ "$CODEX_APP_VALIDATED" = "false" ]
    try_validate_codex_app_control_identity
    [ "$CODEX_APP_VALIDATED" = "false" ]
    [ "$CODEX_APP_CONTROL_VALIDATED" = "true" ]
    if try_require_macos_node_runtime >/dev/null 2>&1; then exit 1; fi
    [ "$NODE_RUNTIME_VALIDATED" = "false" ]
  ' _ "$APP_IDENTITY_COMMON" || {
    printf 'Control-only identity did not safely survive nested resource failure.\n' >&2
    exit 1
  }
/usr/bin/printf '%s\n' \
  verify-bundle-deep verify-executable describe-executable describe-executable \
  > "$TMP/app-control-codesign.expected"
/usr/bin/cmp -s "$APP_IDENTITY_LOG" "$TMP/app-control-codesign.expected" || {
  printf 'Control-only identity used full-app or unexpected codesign branches.\n' >&2
  exit 1
}

for app_identity_failure in resource-tamper bundle-signature bundle-identifier \
  executable-signature executable-identifier executable-team; do
  : > "$APP_IDENTITY_LOG"
  /usr/bin/env HOME="$APP_IDENTITY_HOME" CODEX_APP_BUNDLE="$APP_IDENTITY_BUNDLE" \
    CODESIGN_LOG="$APP_IDENTITY_LOG" CODESIGN_MODE="$app_identity_failure" /bin/bash -c '
      . "$1"
      try_discover_codex_app
      if try_validate_codex_app_identity >/dev/null 2>&1; then exit 1; fi
      [ "$CODEX_APP_VALIDATED" = "false" ]
    ' _ "$APP_IDENTITY_COMMON" || {
      printf 'App identity validation accepted %s.\n' "$app_identity_failure" >&2
      exit 1
    }
done

for control_identity_failure in executable-signature executable-identifier executable-team; do
  : > "$APP_IDENTITY_LOG"
  /usr/bin/env HOME="$APP_IDENTITY_HOME" CODEX_APP_BUNDLE="$APP_IDENTITY_BUNDLE" \
    CODESIGN_LOG="$APP_IDENTITY_LOG" CODESIGN_MODE="$control_identity_failure" /bin/bash -c '
      . "$1"
      try_discover_codex_app
      if try_validate_codex_app_control_identity >/dev/null 2>&1; then exit 1; fi
      [ "$CODEX_APP_VALIDATED" = "false" ]
      [ "$CODEX_APP_CONTROL_VALIDATED" = "false" ]
    ' _ "$APP_IDENTITY_COMMON" || {
      printf 'Control-only identity accepted %s.\n' "$control_identity_failure" >&2
      exit 1
    }
done

/usr/bin/plutil -replace CFBundleIdentifier -string com.example.forged \
  "$APP_IDENTITY_BUNDLE/Contents/Info.plist"
: > "$APP_IDENTITY_LOG"
/usr/bin/env HOME="$APP_IDENTITY_HOME" CODESIGN_LOG="$APP_IDENTITY_LOG" \
  CODESIGN_MODE=valid /bin/bash -c '
    . "$1"
    CODEX_BUNDLE="$2"
    CODEX_EXE="$3"
    if try_validate_codex_app_identity 2>"$4"; then exit 1; fi
    if try_validate_codex_app_control_identity 2>>"$4"; then exit 1; fi
    [ "$CODEX_APP_VALIDATED" = "false" ]
    [ "$CODEX_APP_CONTROL_VALIDATED" = "false" ]
    /usr/bin/grep -F -q "bundle identifier" "$4"
  ' _ "$APP_IDENTITY_COMMON" "$APP_IDENTITY_BUNDLE" "$APP_IDENTITY_EXE" \
  "$APP_IDENTITY_ERROR" || {
    printf 'App identity validation accepted a forged bundle identifier.\n' >&2
    exit 1
  }
[ ! -s "$APP_IDENTITY_LOG" ] || {
  printf 'Forged bundle identifier reached codesign validation.\n' >&2
  exit 1
}

STATE_FALLBACK_HOME="$TMP/state-fallback-home"
STATE_FALLBACK_ROOT="$STATE_FALLBACK_HOME/Library/Application Support/CodexDreamSkinStudio"
/bin/mkdir -p "$STATE_FALLBACK_ROOT"
/usr/bin/printf '%s\n' '{"port":9341,"injectorPid":0}' > "$STATE_FALLBACK_ROOT/state.json"
MALICIOUS_NODE="$TMP/inherited-node"
MALICIOUS_NODE_MARKER="$TMP/inherited-node-marker"
/usr/bin/sed "s|__MARKER__|$MALICIOUS_NODE_MARKER|g" > "$MALICIOUS_NODE" <<'STUB'
#!/bin/bash
: > "__MARKER__"
exit 91
STUB
/bin/chmod 755 "$MALICIOUS_NODE"
/usr/bin/env HOME="$STATE_FALLBACK_HOME" NODE="$MALICIOUS_NODE" \
  NODE_RUNTIME_VALIDATED=true /bin/bash -c '
    . "$1/scripts/common-macos.sh"
    [ "$(state_field port)" = "9341" ]
  ' _ "$ROOT"
[ ! -e "$MALICIOUS_NODE_MARKER" ] || {
  printf 'state_field executed an inherited unvalidated Node.\n' >&2
  exit 1
}
/usr/bin/env -u NODE HOME="$STATE_FALLBACK_HOME" /bin/bash -c '
  . "$1/scripts/common-macos.sh"
  CODEX_BUNDLE="$2"
  CODEX_APP_VALIDATED=true
  CODEX_TEAM_ID="$EXPECTED_CODEX_TEAM_ID"
  if try_require_macos_node_runtime 2>"$3"; then exit 1; fi
  /usr/bin/grep -F -q "signed Node.js runtime bundled with Codex was not found" "$3"
' _ "$ROOT" "$TMP/missing-codex.app" "$TMP/try-runtime.error"
/usr/bin/env -u NODE HOME="$STATE_FALLBACK_HOME" /bin/bash -c '
  . "$1/scripts/common-macos.sh"
  type try_discover_codex_app >/dev/null
  type try_require_macos_runtime >/dev/null
  [ "$(state_field port)" = "9341" ]
' _ "$ROOT"

/usr/bin/env -u HOME /bin/bash -c '. "$1/scripts/common-macos.sh"; [ -n "$HOME" ] && [ "$SKIN_VERSION" = "1.2.0" ]' _ "$ROOT"
"$ROOT/scripts/doctor-macos.sh" >/dev/null

printf 'PASS: syntax, payload, bundled presets, preset seeding, runtime-state safety, custom-theme, config round-trips, HOME recovery, signature, and doctor checks.\n'
