#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BUILD="$ROOT/macos/scripts/build-studio-release.sh"
SCANNER="$ROOT/studio/release/check-contents.mjs"
RELEASE_VERSION="$(/usr/bin/tr -d '[:space:]' < "$ROOT/macos/VERSION")"
RELEASE_DIR="$ROOT/macos/release/adhoc"
BASE_NAME="CodexDreamSkinStudio-$RELEASE_VERSION-macos-universal-ADHOC"
APP_NAME="$BASE_NAME.app"
DMG_NAME="$BASE_NAME.dmg"
APP="$RELEASE_DIR/$APP_NAME"
DMG="$RELEASE_DIR/$DMG_NAME"
MANIFEST="$RELEASE_DIR/release-manifest.json"
ALLOWLIST="$ROOT/studio/release/allowlist-macos.json"
WINDOWS_ALLOWLIST="$ROOT/studio/release/allowlist-windows.json"
ICON_SOURCE="$ROOT/studio/assets/app-icon-source.png"
NODE="${NODE:-$(command -v node || true)}"

[ -x "$BUILD" ] || {
  printf 'Studio release builder is missing: %s\n' "$BUILD" >&2
  exit 1
}
[ -x "$NODE" ] || { printf 'Node.js is required for the release test.\n' >&2; exit 1; }
[ "$(/usr/bin/sips -g format "$ICON_SOURCE" | /usr/bin/awk '/format:/ { print $2 }')" = 'png' ]
[ "$(/usr/bin/sips -g pixelWidth "$ICON_SOURCE" | /usr/bin/awk '/pixelWidth:/ { print $2 }')" = '1024' ]
[ "$(/usr/bin/sips -g pixelHeight "$ICON_SOURCE" | /usr/bin/awk '/pixelHeight:/ { print $2 }')" = '1024' ]
"$NODE" -e '
  const source = require("node:fs").readFileSync(process.argv[1], "utf8");
  const helper = source.match(/copy_snapshot_file\(\) \{[\s\S]*?\n\}/)?.[0] || "";
  const steps = [
    "[ -f \"$source_path\" ] && [ ! -L \"$source_path\" ]",
    "/bin/cp -P",
    "[ -f \"$destination\" ] && [ ! -L \"$destination\" ]",
    "| /usr/bin/cmp -s - \"$destination\"",
    "/bin/chmod 644 \"$destination\"",
  ];
  let offset = -1;
  for (const step of steps) {
    const next = helper.indexOf(step, offset + 1);
    if (next < 0) throw new Error(`copy_snapshot_file is missing ordered safety step: ${step}`);
    offset = next;
  }
' "$BUILD"
"$NODE" -e '
  const source = require("node:fs").readFileSync(process.argv[1], "utf8");
  const versionRead = `VERSION="$(/usr/bin/tr -d ${String.fromCharCode(39)}[:space:]${String.fromCharCode(39)} < "$SNAPSHOT_ROOT/macos/VERSION")"`;
  const versionIndex = source.indexOf(versionRead);
  const snapshotIndex = source.indexOf(`SNAPSHOT_ROOT="$TMP/index"`);
  const buildIndex = source.indexOf("build_thin CodexDreamSkinStudio");
  if (snapshotIndex < 0 || versionIndex <= snapshotIndex || buildIndex <= versionIndex) {
    throw new Error("macOS VERSION is not validated from the immutable snapshot before Swift build");
  }
  if (source.includes(`< "$MACOS_ROOT/VERSION"`)) {
    throw new Error("macOS release metadata still reads live VERSION");
  }
' "$BUILD"
"$NODE" -e '
  const source = require("node:fs").readFileSync(process.argv[1], "utf8");
  for (const required of [
    `RELEASE_CHANNEL="adhoc"`,
    `RELEASE_CHANNEL="notarized"`,
    `CodexDreamSkinStudio-$VERSION-macos-universal-ADHOC.app`,
    `CodexDreamSkinStudio-$VERSION-macos-universal-ADHOC.dmg`,
    `RELEASE_DIR="$RELEASE_ROOT/$RELEASE_CHANNEL"`,
    `OLD_RELEASE="$MACOS_ROOT/.release-old.$RELEASE_CHANNEL.$$"`,
    "release-manifest.json",
    "notarized",
    "stapled",
  ]) {
    if (!source.includes(required)) throw new Error(`release truth contract is missing: ${required}`);
  }
  const namingStart = source.indexOf(`if [ "$MODE" = "adhoc" ]; then`);
  const namingEnd = source.indexOf("\nfi", namingStart);
  const naming = source.slice(namingStart, namingEnd);
  const canonical = naming.indexOf(`APP_NAME="CodexDreamSkinStudio.app"`);
  const adhoc = naming.indexOf(`APP_NAME="CodexDreamSkinStudio-$VERSION-macos-universal-ADHOC.app"`);
  if (namingStart < 0 || adhoc < 0 || canonical <= adhoc ||
      !naming.slice(0, canonical).includes("else")) {
    throw new Error("canonical app name is not reserved for notarized output");
  }
  const manifest = source.lastIndexOf("release-manifest.json");
  for (const gate of [
    `notarytool submit "$PUBLISH/$DMG_NAME"`,
    `stapler validate "$APP"`,
    `stapler validate "$PUBLISH/$DMG_NAME"`,
    `spctl --assess --type execute "$APP"`,
  ]) {
    const index = source.indexOf(gate);
    if (index < 0 || index > manifest) throw new Error(`manifest precedes production trust gate: ${gate}`);
  }
' "$BUILD"
"$NODE" -e '
  const source = require("node:fs").readFileSync(process.argv[1], "utf8");
  for (const required of [
    "SNAPSHOT_SOURCE_ROOT=",
    "copy_snapshot_file()",
    `while IFS= read -r -d ${String.fromCharCode(39, 39)} source`,
    "ls-tree -r -z --name-only",
    "\"$INDEX_TREE\" -- macos/assets macos/presets",
    "\"$SNAPSHOT_ROOT/studio/release/check-contents.mjs\"",
    "\"$SNAPSHOT_ROOT/studio/release/allowlist-macos.json\"",
  ]) {
    if (!source.includes(required)) throw new Error(`builder is missing snapshot release input: ${required}`);
  }
  const afterSnapshot = source.slice(source.indexOf("SNAPSHOT_SOURCE_ROOT="));
  if (/\bgit\b[^\n]*\bls-files\b/.test(afterSnapshot)) {
    throw new Error("post-snapshot release enumeration still reads the live index");
  }
  if (afterSnapshot.includes("copy_tracked_file")) {
    throw new Error("post-snapshot release copy still reads the live worktree");
  }
' "$BUILD"
"$NODE" -e '
  const source = require("node:fs").readFileSync(process.argv[1], "utf8");
  for (const required of [
    "O_NOFOLLOW",
    "fs.open(filePath, FILE_OPEN_FLAGS)",
    "handle.readFile()",
    "sameStableStat",
    "fs.opendir(directory)",
    "directoryHandle.read()",
    "finally",
    "handle.close()",
    "directoryHandle.close()",
  ]) {
    if (!source.includes(required)) throw new Error(`scanner is missing stable-handle step: ${required}`);
  }
' "$SCANNER"
"$NODE" -e '
  const source = require("node:fs").readFileSync(process.argv[1], "utf8");
  const guard = source.match(/verify_tracked_regular_file\(\) \{[\s\S]*?\n\}/)?.[0] || "";
  if (!/case "\$index_mode" in 100644\|100755\) ;; \*\) release_input_error ;; esac/.test(guard)) {
    throw new Error("tracked input guard does not restrict index modes to regular blobs");
  }
  if (!source.includes("ls-tree -r -z \"$INDEX_TREE\" -- \"${SNAPSHOT_PATHS[@]}\"")) {
    throw new Error("index mode guard does not cover every archived package entry");
  }
  for (const required of ["git -C \"$REPO_ROOT\" write-tree", "git -C \"$REPO_ROOT\" archive", "SNAPSHOT_PACKAGE="]) {
    if (!source.includes(required)) throw new Error(`builder is missing index snapshot step: ${required}`);
  }
  for (const required of [
    "verify_snapshot_build_inputs",
    "diff --quiet --no-ext-diff",
    "ls-files --others --exclude-standard",
    "ls-files --others --ignored --exclude-standard",
    ":(exclude)macos/studio/.build/**",
  ]) {
    if (!source.includes(required)) throw new Error(`builder is missing complete live-input gate: ${required}`);
  }
  const afterGuard = source.slice(source.indexOf("verify_snapshot_build_inputs\n") + 1);
  if (afterGuard.includes(`--package-path "$PACKAGE"`)) {
    throw new Error("post-guard Swift command still references the live package");
  }
  const snapshotReferences = source.match(/--package-path "\$SNAPSHOT_PACKAGE"/g) || [];
  if (snapshotReferences.length !== 2) {
    throw new Error("swift build and show-bin-path must both use the snapshot package");
  }
' "$BUILD"

TMP="$(/usr/bin/mktemp -d /tmp/codex-dream-skin-release-test.XXXXXX)"
MOUNT_POINT=""
UNTRACKED_SWIFT=""
UNTRACKED_SWIFT_SYMLINK=""
MODE_SWIFT=""
DIRTY_INPUT=""
DIRTY_BACKUP=""
UNTRACKED_RELEASE_INPUT=""
UNREADABLE_DIR=""
RACE_PID=""
LEGACY_SENTINEL="$ROOT/macos/release/preserve-legacy-$$.keep"
NOTARIZED_SENTINEL="$ROOT/macos/release/notarized/preserve-notarized-$$.keep"
NOTARIZED_DIR_CREATED="false"
cleanup() {
  if [ -n "$MOUNT_POINT" ]; then
    /usr/bin/hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  [ -z "$UNTRACKED_SWIFT" ] || /bin/rm -f "$UNTRACKED_SWIFT"
  [ -z "$UNTRACKED_SWIFT_SYMLINK" ] || /bin/rm -f "$UNTRACKED_SWIFT_SYMLINK"
  [ -z "$MODE_SWIFT" ] || /bin/rm -f "$MODE_SWIFT"
  [ -z "$DIRTY_INPUT" ] || /bin/cp -p "$DIRTY_BACKUP" "$DIRTY_INPUT"
  [ -z "$UNTRACKED_RELEASE_INPUT" ] || /bin/rm -f "$UNTRACKED_RELEASE_INPUT"
  [ -z "$UNREADABLE_DIR" ] || /bin/chmod 700 "$UNREADABLE_DIR" 2>/dev/null || true
  [ -z "$RACE_PID" ] || /bin/kill -TERM "$RACE_PID" 2>/dev/null || true
  [ -z "$RACE_PID" ] || wait "$RACE_PID" 2>/dev/null || true
  /bin/rm -f "$LEGACY_SENTINEL" "$NOTARIZED_SENTINEL"
  if [ "$NOTARIZED_DIR_CREATED" = "true" ]; then /bin/rmdir "$ROOT/macos/release/notarized" 2>/dev/null || true; fi
  /bin/rm -rf "$TMP"
}
trap cleanup EXIT

snapshot_release() {
  /usr/bin/find "$ROOT/macos/release" -type f -print | LC_ALL=C /usr/bin/sort \
    | while IFS= read -r file; do
        /usr/bin/printf 'file %s ' "${file#"$ROOT/"}"
        /usr/bin/shasum -a 256 "$file" | /usr/bin/awk '{ print $1 }'
      done
  /usr/bin/find "$ROOT/macos/release" -type l -print | LC_ALL=C /usr/bin/sort \
    | while IFS= read -r link; do
        /usr/bin/printf 'link %s %s\n' "${link#"$ROOT/"}" "$(/usr/bin/readlink "$link")"
      done
}

expect_build_input_rejection() {
  local label="$1"
  snapshot_release > "$TMP/release-before-$label"
  if "$BUILD" --adhoc >"$TMP/$label.out" 2>"$TMP/$label.err"; then
    printf 'Studio release builder accepted an unsafe input: %s.\n' "$label" >&2
    exit 1
  fi
  /usr/bin/printf '%s\n' \
    'Studio build inputs must be tracked regular files matching the git index.' \
    > "$TMP/$label.expected"
  /usr/bin/cmp "$TMP/$label.expected" "$TMP/$label.err"
  [ ! -s "$TMP/$label.out" ]
  snapshot_release > "$TMP/release-after-$label"
  /usr/bin/cmp "$TMP/release-before-$label" "$TMP/release-after-$label"
}

expect_dirty_input_rejection() {
  local relative="$1"
  local label="$2"
  DIRTY_INPUT="$ROOT/$relative"
  DIRTY_BACKUP="$TMP/$label.original"
  /bin/cp -p "$DIRTY_INPUT" "$DIRTY_BACKUP"
  /usr/bin/printf '\nrelease-input-fixture-%s\n' "$label" >> "$DIRTY_INPUT"
  expect_build_input_rejection "$label"
  /bin/cp -p "$DIRTY_BACKUP" "$DIRTY_INPUT"
  DIRTY_INPUT=""
  DIRTY_BACKUP=""
}

VERSION_INDEX="$TMP/version-index-fixture"
/bin/cp -P "$(/usr/bin/git -C "$ROOT" rev-parse --git-path index)" "$VERSION_INDEX"
VERSION_BLOB="$(/usr/bin/git -C "$ROOT" rev-parse ':README.md')"
/usr/bin/env GIT_INDEX_FILE="$VERSION_INDEX" /usr/bin/git -C "$ROOT" update-index \
  --cacheinfo "100644,$VERSION_BLOB,macos/VERSION"
DIRTY_INPUT="$ROOT/macos/VERSION"
DIRTY_BACKUP="$TMP/version-live.original"
/bin/cp -p "$DIRTY_INPUT" "$DIRTY_BACKUP"
/bin/cp "$ROOT/README.md" "$DIRTY_INPUT"
snapshot_release > "$TMP/release-before-invalid-version"
if /usr/bin/env GIT_INDEX_FILE="$VERSION_INDEX" \
  "$BUILD" --adhoc >"$TMP/invalid-version.out" 2>"$TMP/invalid-version.err"; then
  printf 'Studio release builder accepted an invalid snapshot VERSION.\n' >&2
  exit 1
fi
/bin/cp -p "$DIRTY_BACKUP" "$DIRTY_INPUT"
DIRTY_INPUT=""
DIRTY_BACKUP=""
/usr/bin/printf 'The macOS release version is invalid.\n' > "$TMP/invalid-version.expected"
/usr/bin/cmp "$TMP/invalid-version.expected" "$TMP/invalid-version.err"
[ ! -s "$TMP/invalid-version.out" ]
snapshot_release > "$TMP/release-after-invalid-version"
/usr/bin/cmp "$TMP/release-before-invalid-version" "$TMP/release-after-invalid-version"

[ -d "$ROOT/macos/release/notarized" ] || {
  /bin/mkdir -p "$ROOT/macos/release/notarized"
  NOTARIZED_DIR_CREATED="true"
}
/usr/bin/printf 'preserve legacy root\n' > "$LEGACY_SENTINEL"
/usr/bin/printf 'preserve notarized channel\n' > "$NOTARIZED_SENTINEL"
"$BUILD" --adhoc
[ -f "$LEGACY_SENTINEL" ] || { printf 'Ad-hoc publication deleted a legacy release.\n' >&2; exit 1; }
[ -f "$NOTARIZED_SENTINEL" ] || { printf 'Ad-hoc publication deleted notarized output.\n' >&2; exit 1; }

[ -d "$APP" ] || { printf 'Studio app is missing: %s\n' "$APP" >&2; exit 1; }
[ -f "$DMG" ] || { printf 'Studio DMG is missing: %s\n' "$DMG" >&2; exit 1; }
[ -f "$RELEASE_DIR/SHA256SUMS.txt" ] || {
  printf 'Studio checksums are missing.\n' >&2
  exit 1
}
[ -f "$MANIFEST" ] || { printf 'Studio release manifest is missing.\n' >&2; exit 1; }
[ ! -e "$RELEASE_DIR/CodexDreamSkinStudio.app" ]
[ ! -e "$RELEASE_DIR/CodexDreamSkinStudio.dmg" ]
"$NODE" - "$MANIFEST" "$DMG" "$RELEASE_VERSION" "$DMG_NAME" <<'NODE'
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const [manifestPath, dmgPath, version, file] = process.argv.slice(2);
const sha256 = crypto.createHash("sha256").update(fs.readFileSync(dmgPath)).digest("hex");
assert.deepEqual(JSON.parse(fs.readFileSync(manifestPath, "utf8")), {
  schemaVersion: 1,
  version,
  architecture: "universal",
  signing: "adhoc",
  notarized: false,
  stapled: false,
  file,
  sha256,
});
NODE
{
  /usr/bin/printf '%s\n' "$APP_NAME" "$DMG_NAME" SHA256SUMS.txt release-manifest.json
} | LC_ALL=C /usr/bin/sort > "$TMP/expected-release-root"
/usr/bin/find "$RELEASE_DIR" -mindepth 1 -maxdepth 1 -exec /usr/bin/basename {} \; \
  | LC_ALL=C /usr/bin/sort > "$TMP/release-root"
/usr/bin/cmp "$TMP/expected-release-root" "$TMP/release-root"

expect_dirty_input_rejection macos/studio/Resources/Info.plist dirty-info-plist
expect_dirty_input_rejection macos/scripts/studio-adapter-macos.sh dirty-runtime-script
expect_dirty_input_rejection macos/assets/renderer-inject.js dirty-runtime-asset
expect_dirty_input_rejection macos/presets/preset-midnight-aurora/theme.json dirty-preset
expect_dirty_input_rejection studio/protocol/fixtures-v1.json dirty-protocol
expect_dirty_input_rejection macos/VERSION dirty-version

UNTRACKED_RELEASE_INPUT="$ROOT/macos/scripts/untracked-release-input-$$.sh"
/usr/bin/printf '#!/bin/bash\nexit 99\n' > "$UNTRACKED_RELEASE_INPUT"
expect_build_input_rejection untracked-runtime-input
/bin/rm -f "$UNTRACKED_RELEASE_INPUT"
UNTRACKED_RELEASE_INPUT="$ROOT/macos/presets/untracked-release-symlink-$$"
/bin/ln -s preset-midnight-aurora "$UNTRACKED_RELEASE_INPUT"
expect_build_input_rejection untracked-preset-symlink
/bin/rm -f "$UNTRACKED_RELEASE_INPUT"
UNTRACKED_RELEASE_INPUT="$ROOT/macos/scripts/ignored-release-input-$$.tmp"
/usr/bin/printf 'ignored release input\n' > "$UNTRACKED_RELEASE_INPUT"
expect_build_input_rejection ignored-runtime-input
/bin/rm -f "$UNTRACKED_RELEASE_INPUT"
UNTRACKED_RELEASE_INPUT="$ROOT/macos/presets/ignored-release-symlink-$$.tmp"
/bin/ln -s preset-midnight-aurora "$UNTRACKED_RELEASE_INPUT"
expect_build_input_rejection ignored-preset-symlink
/bin/rm -f "$UNTRACKED_RELEASE_INPUT"
UNTRACKED_RELEASE_INPUT=""

UNTRACKED_SWIFT_SYMLINK="$ROOT/macos/studio/Sources/DreamSkinStudioCore/Task10UntrackedSymlinkGuard_$$.swift"
/bin/ln -s EngineProtocol.swift "$UNTRACKED_SWIFT_SYMLINK"
expect_build_input_rejection untracked-symlink-input
/bin/rm -f "$UNTRACKED_SWIFT_SYMLINK"
UNTRACKED_SWIFT_SYMLINK=""

UNTRACKED_SWIFT="$ROOT/macos/studio/Sources/DreamSkinStudioCore/Task10UntrackedReleaseGuard_$$.swift"
/usr/bin/printf '#error("UNTRACKED_SWIFT_REACHED_COMPILER")\n' > "$UNTRACKED_SWIFT"
expect_build_input_rejection untracked-regular-input
/bin/rm -f "$UNTRACKED_SWIFT"
UNTRACKED_SWIFT=""

MODE_SWIFT="$ROOT/macos/studio/Sources/DreamSkinStudioCore/Task10IndexModeGuard_$$.swift"
/bin/cp "$ROOT/macos/studio/Sources/DreamSkinStudioCore/EngineProtocol.swift" "$MODE_SWIFT"
ALTERNATE_INDEX="$TMP/index-mode-fixture"
/bin/cp -P "$(/usr/bin/git -C "$ROOT" rev-parse --git-path index)" "$ALTERNATE_INDEX"
MODE_PATH="${MODE_SWIFT#"$ROOT/"}"
MODE_BLOB="$(/usr/bin/git -C "$ROOT" rev-parse ':macos/studio/Sources/DreamSkinStudioCore/EngineProtocol.swift')"
/usr/bin/env GIT_INDEX_FILE="$ALTERNATE_INDEX" /usr/bin/git -C "$ROOT" update-index --add \
  --cacheinfo "120000,$MODE_BLOB,$MODE_PATH"
snapshot_release > "$TMP/release-before-index-mode"
if /usr/bin/env GIT_INDEX_FILE="$ALTERNATE_INDEX" \
  "$BUILD" --adhoc >"$TMP/index-mode.out" 2>"$TMP/index-mode.err"; then
  printf 'Studio release builder accepted a non-regular index mode.\n' >&2
  exit 1
fi
/usr/bin/printf '%s\n' \
  'Studio build inputs must be tracked regular files matching the git index.' \
  > "$TMP/index-mode.expected"
/usr/bin/cmp "$TMP/index-mode.expected" "$TMP/index-mode.err"
[ ! -s "$TMP/index-mode.out" ]
snapshot_release > "$TMP/release-after-index-mode"
/usr/bin/cmp "$TMP/release-before-index-mode" "$TMP/release-after-index-mode"
/bin/rm -f "$MODE_SWIFT"
MODE_SWIFT=""

expect_scanner_failure() {
  if "$NODE" "$SCANNER" "$@" >"$TMP/scanner.out" 2>"$TMP/scanner.err"; then
    printf 'Scanner unexpectedly accepted invalid input: %s\n' "$*" >&2
    exit 1
  fi
  /usr/bin/grep -F -q 'FAIL: release contents rejected:' "$TMP/scanner.err"
}

expect_scanner_failure_reason() {
  local reason="$1"
  shift
  if "$NODE" "$SCANNER" "$@" >"$TMP/scanner.out" 2>"$TMP/scanner.err"; then
    printf 'Scanner unexpectedly accepted invalid input: %s\n' "$*" >&2
    exit 1
  fi
  /usr/bin/printf 'FAIL: release contents rejected: %s.\n' "$reason" > "$TMP/scanner.expected"
  /usr/bin/cmp "$TMP/scanner.expected" "$TMP/scanner.err"
}

make_allowed_tree() {
  local fixture="$1"
  /bin/mkdir -p "$fixture/Contents/MacOS" "$fixture/Contents/Resources/engine/bin" \
    "$fixture/Contents/Resources/engine/scripts"
  /usr/bin/printf '\317\372\355\376fixture' > "$fixture/Contents/MacOS/CodexDreamSkinStudio"
  /usr/bin/printf '\312\376\272\276fixture' > \
    "$fixture/Contents/Resources/engine/bin/dream-skin-config-restore"
  /usr/bin/printf '#!/bin/bash\nHOME="/Users/$CURRENT_USER" /usr/bin/true\nexit 0\n' > \
    "$fixture/Contents/Resources/engine/scripts/studio-adapter-macos.sh"
  /bin/chmod 755 "$fixture/Contents/MacOS/CodexDreamSkinStudio" \
    "$fixture/Contents/Resources/engine/bin/dream-skin-config-restore" \
    "$fixture/Contents/Resources/engine/scripts/studio-adapter-macos.sh"
}

FIXTURE="$TMP/allowed"
make_allowed_tree "$FIXTURE"
[ "$("$NODE" "$SCANNER" --root "$FIXTURE" --allowlist "$ALLOWLIST")" = \
  'PASS: release contents verified.' ]

CASE_ROOT="$TMP/missing-declared-native"
make_allowed_tree "$CASE_ROOT"
/bin/rm -f "$CASE_ROOT/Contents/Resources/engine/bin/dream-skin-config-restore"
expect_scanner_failure_reason 'missing declared native executable' \
  --root "$CASE_ROOT" --allowlist "$ALLOWLIST"

expect_scanner_failure --root "$FIXTURE" --allowlist "$ALLOWLIST" --extra value
expect_scanner_failure --root "$FIXTURE"
expect_scanner_failure --root "$FIXTURE" --root "$FIXTURE" --allowlist "$ALLOWLIST"
expect_scanner_failure --unknown "$FIXTURE" --allowlist "$ALLOWLIST"

/usr/bin/printf '{' > "$TMP/malformed.json"
expect_scanner_failure --root "$FIXTURE" --allowlist "$TMP/malformed.json"
/usr/bin/printf '["Contents/MacOS/CodexDreamSkinStudio","Contents/MacOS/CodexDreamSkinStudio"]\n' \
  > "$TMP/duplicate.json"
expect_scanner_failure --root "$FIXTURE" --allowlist "$TMP/duplicate.json"
/usr/bin/printf '["../escape"]\n' > "$TMP/escape.json"
expect_scanner_failure --root "$FIXTURE" --allowlist "$TMP/escape.json"

for forbidden in \
  state.json auth.json config.toml operation.log config.before-20260719 \
  theme-backup.json customer-screenshot.png 'Screen Shot 2026-07-19 at 12.34.56.png' \
  'Codex Dream Skin Verification.png'
do
  CASE_ROOT="$TMP/name-${forbidden//[^A-Za-z0-9]/_}"
  make_allowed_tree "$CASE_ROOT"
  : > "$CASE_ROOT/$forbidden"
  expect_scanner_failure --root "$CASE_ROOT" --allowlist "$ALLOWLIST"
done

CASE_ROOT="$TMP/git-directory"
make_allowed_tree "$CASE_ROOT"
/bin/mkdir "$CASE_ROOT/.git"
expect_scanner_failure --root "$CASE_ROOT" --allowlist "$ALLOWLIST"

CASE_ROOT="$TMP/screenshots-directory"
make_allowed_tree "$CASE_ROOT"
/bin/mkdir "$CASE_ROOT/screenshots"
: > "$CASE_ROOT/screenshots/customer.png"
expect_scanner_failure --root "$CASE_ROOT" --allowlist "$ALLOWLIST"

CASE_ROOT="$TMP/symlink"
make_allowed_tree "$CASE_ROOT"
/bin/ln -s Contents "$CASE_ROOT/link"
expect_scanner_failure --root "$CASE_ROOT" --allowlist "$ALLOWLIST"

CASE_ROOT="$TMP/nested-filesystem-error"
make_allowed_tree "$CASE_ROOT"
UNREADABLE_DIR="$CASE_ROOT/z-unreadable"
/bin/mkdir "$UNREADABLE_DIR"
/bin/chmod 000 "$UNREADABLE_DIR"
expect_scanner_failure_reason 'filesystem error' \
  --root "$CASE_ROOT" --allowlist "$ALLOWLIST"
/bin/chmod 700 "$UNREADABLE_DIR"
UNREADABLE_DIR=""

CASE_ROOT="$TMP/file-mutation"
make_allowed_tree "$CASE_ROOT"
/bin/dd if=/dev/zero of="$CASE_ROOT/a-race.bin" bs=1048576 count=16 2>/dev/null
(
  iteration=0
  while [ "$iteration" -lt 4000 ]; do
    /usr/bin/touch "$CASE_ROOT/a-race.bin"
    iteration=$((iteration + 1))
  done
) &
RACE_PID="$!"
expect_scanner_failure_reason 'filesystem changed' \
  --root "$CASE_ROOT" --allowlist "$ALLOWLIST"
wait "$RACE_PID"
RACE_PID=""

CASE_ROOT="$TMP/macos-absolute-path"
make_allowed_tree "$CASE_ROOT"
/usr/bin/printf '/Users/release-user/private/file\n' > "$CASE_ROOT/readme.txt"
expect_scanner_failure --root "$CASE_ROOT" --allowlist "$ALLOWLIST"

for template_escape in \
  '/Users/$CURRENT_USERevil/private/file' \
  '/Users/$CURRENT_USER /private/file' \
  '/Users/$CURRENT_USER/private/file'
do
  CASE_ROOT="$TMP/template-boundary-${template_escape//[^A-Za-z0-9]/_}"
  make_allowed_tree "$CASE_ROOT"
  /usr/bin/printf '%s\n' "$template_escape" > "$CASE_ROOT/readme.txt"
  expect_scanner_failure_reason 'absolute user path' \
    --root "$CASE_ROOT" --allowlist "$ALLOWLIST"
done

CASE_ROOT="$TMP/windows-absolute-path"
make_allowed_tree "$CASE_ROOT"
/usr/bin/printf 'C:\\Users\\release-user\\private\\file\n' > "$CASE_ROOT/readme.txt"
expect_scanner_failure --root "$CASE_ROOT" --allowlist "$ALLOWLIST"

CASE_ROOT="$TMP/macos-space-absolute-path"
make_allowed_tree "$CASE_ROOT"
/usr/bin/printf '/Users/Release User/private/file\n' > "$CASE_ROOT/readme.txt"
expect_scanner_failure_reason 'absolute user path' \
  --root "$CASE_ROOT" --allowlist "$ALLOWLIST"

CASE_ROOT="$TMP/windows-space-absolute-path"
make_allowed_tree "$CASE_ROOT"
/usr/bin/printf 'C:\\Users\\Release User\\private\\file\n' > "$CASE_ROOT/readme.txt"
expect_scanner_failure_reason 'absolute user path' \
  --root "$CASE_ROOT" --allowlist "$ALLOWLIST"

CASE_ROOT="$TMP/utf16le-macos-absolute-path"
make_allowed_tree "$CASE_ROOT"
"$NODE" -e '
  require("node:fs").writeFileSync(
    process.argv[1],
    Buffer.from("/Users/Release User/private/file\\n", "utf16le"),
  );
' "$CASE_ROOT/paths.bin"
expect_scanner_failure_reason 'absolute user path' \
  --root "$CASE_ROOT" --allowlist "$ALLOWLIST"

CASE_ROOT="$TMP/utf16le-windows-absolute-path"
make_allowed_tree "$CASE_ROOT"
"$NODE" -e '
  require("node:fs").writeFileSync(
    process.argv[1],
    Buffer.from(String.raw`C:\Users\客户\private\file` + "\n", "utf16le"),
  );
' "$CASE_ROOT/paths.bin"
expect_scanner_failure_reason 'absolute user path' \
  --root "$CASE_ROOT" --allowlist "$ALLOWLIST"

CASE_ROOT="$TMP/non-ascii-macos-absolute-path"
make_allowed_tree "$CASE_ROOT"
/usr/bin/printf '/Users/客户/private/file\n' > "$CASE_ROOT/readme.txt"
expect_scanner_failure --root "$CASE_ROOT" --allowlist "$ALLOWLIST"

CASE_ROOT="$TMP/non-ascii-windows-absolute-path"
make_allowed_tree "$CASE_ROOT"
/usr/bin/printf 'C:\\Users\\客户\\private\\file\n' > "$CASE_ROOT/readme.txt"
expect_scanner_failure --root "$CASE_ROOT" --allowlist "$ALLOWLIST"

CASE_ROOT="$TMP/unexpected-native"
make_allowed_tree "$CASE_ROOT"
/bin/cp "$CASE_ROOT/Contents/MacOS/CodexDreamSkinStudio" "$CASE_ROOT/extra-native"
expect_scanner_failure --root "$CASE_ROOT" --allowlist "$ALLOWLIST"

CASE_ROOT="$TMP/deterministic-byte-order"
make_allowed_tree "$CASE_ROOT"
: > "$CASE_ROOT/z.log"
/bin/cp "$CASE_ROOT/Contents/MacOS/CodexDreamSkinStudio" "$CASE_ROOT/ä-native"
expect_scanner_failure_reason 'forbidden name' \
  --root "$CASE_ROOT" --allowlist "$ALLOWLIST"

PE_ROOT="$TMP/windows-pe"
/bin/mkdir -p "$PE_ROOT/engine/runtime"
/bin/dd if=/dev/zero of="$PE_ROOT/CodexDreamSkinStudio.exe" bs=1 count=68 2>/dev/null
/usr/bin/printf 'MZ' | /bin/dd of="$PE_ROOT/CodexDreamSkinStudio.exe" bs=1 seek=0 conv=notrunc 2>/dev/null
/usr/bin/printf '\100\000\000\000' \
  | /bin/dd of="$PE_ROOT/CodexDreamSkinStudio.exe" bs=1 seek=60 conv=notrunc 2>/dev/null
/usr/bin/printf 'PE\000\000' \
  | /bin/dd of="$PE_ROOT/CodexDreamSkinStudio.exe" bs=1 seek=64 conv=notrunc 2>/dev/null
/bin/cp "$PE_ROOT/CodexDreamSkinStudio.exe" "$PE_ROOT/engine/runtime/node.exe"
[ "$("$NODE" "$SCANNER" --root "$PE_ROOT" --allowlist "$WINDOWS_ALLOWLIST")" = \
  'PASS: release contents verified.' ]
/bin/cp "$PE_ROOT/CodexDreamSkinStudio.exe" "$PE_ROOT/undeclared.exe"
expect_scanner_failure --root "$PE_ROOT" --allowlist "$WINDOWS_ALLOWLIST"

EXPECTED="$TMP/expected-files"
ACTUAL="$TMP/actual-files"
{
  printf '%s\n' \
    Contents/Info.plist \
    Contents/MacOS/CodexDreamSkinStudio \
    Contents/Resources/AppIcon.icns \
    Contents/Resources/engine/LICENSE \
    Contents/Resources/engine/NOTICE.md \
    Contents/Resources/engine/VERSION \
    Contents/Resources/engine/bin/dream-skin-config-restore \
    Contents/Resources/engine/protocol/README.md \
    Contents/Resources/engine/protocol/fixtures-v1.json \
    Contents/Resources/engine/scripts/common-macos.sh \
    Contents/Resources/engine/scripts/image-metadata.mjs \
    Contents/Resources/engine/scripts/injector.mjs \
    Contents/Resources/engine/scripts/install-dream-skin-macos.sh \
    Contents/Resources/engine/scripts/pause-dream-skin-macos.sh \
    Contents/Resources/engine/scripts/restore-dream-skin-macos.sh \
    Contents/Resources/engine/scripts/stage-theme.mjs \
    Contents/Resources/engine/scripts/start-dream-skin-macos.sh \
    Contents/Resources/engine/scripts/status-dream-skin-macos.sh \
    Contents/Resources/engine/scripts/studio-adapter-macos.sh \
    Contents/Resources/engine/scripts/switch-theme-macos.sh \
    Contents/Resources/engine/scripts/theme-config.mjs \
    Contents/Resources/engine/scripts/verify-dream-skin-macos.sh \
    Contents/_CodeSignature/CodeResources
  /usr/bin/find "$ROOT/macos/assets" "$ROOT/macos/presets" -type f -print \
    | /usr/bin/sed "s#^$ROOT/macos/#Contents/Resources/engine/#"
} | LC_ALL=C /usr/bin/sort > "$EXPECTED"
/usr/bin/find "$APP" -type f -print \
  | /usr/bin/sed "s#^$APP/##" \
  | LC_ALL=C /usr/bin/sort > "$ACTUAL"
/usr/bin/cmp "$EXPECTED" "$ACTUAL"

[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist")" = \
  'AppIcon' ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")" = \
  '12.0' ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$RELEASE_VERSION" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" = "$RELEASE_VERSION" ]

for binary in \
  "$APP/Contents/MacOS/CodexDreamSkinStudio" \
  "$APP/Contents/Resources/engine/bin/dream-skin-config-restore"
do
  ARCHS="$(/usr/bin/lipo -archs "$binary")"
  case " $ARCHS " in *' arm64 '*) ;; *) printf 'arm64 is missing from %s\n' "$binary" >&2; exit 1 ;; esac
  case " $ARCHS " in *' x86_64 '*) ;; *) printf 'x86_64 is missing from %s\n' "$binary" >&2; exit 1 ;; esac
done

"$NODE" "$SCANNER" --root "$APP" --allowlist "$ALLOWLIST"
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/bin/codesign --verify "$DMG"
for signed_artifact in "$APP" "$DMG"; do
  /usr/bin/codesign -d --verbose=4 "$signed_artifact" 2> "$TMP/codesign-info"
  /usr/bin/grep -F -q 'Signature=adhoc' "$TMP/codesign-info"
  /usr/bin/grep -F -q 'TeamIdentifier=not set' "$TMP/codesign-info"
done
(cd "$RELEASE_DIR" && /usr/bin/shasum -a 256 -c SHA256SUMS.txt)

ATTACH_OUTPUT="$(/usr/bin/hdiutil attach -nobrowse -readonly "$DMG")"
MOUNT_POINT="$(/usr/bin/printf '%s\n' "$ATTACH_OUTPUT" | /usr/bin/awk -F '\t' 'NF >= 3 { mount = $NF } END { print mount }')"
[ -d "$MOUNT_POINT" ] || { printf 'Studio DMG did not mount.\n' >&2; exit 1; }
/usr/bin/find "$MOUNT_POINT" -mindepth 1 -maxdepth 1 -exec /usr/bin/basename {} \; \
  | LC_ALL=C /usr/bin/sort > "$TMP/dmg-root"
/usr/bin/printf '%s\n' Applications "$APP_NAME" \
  | LC_ALL=C /usr/bin/sort > "$TMP/expected-dmg-root"
/usr/bin/cmp "$TMP/expected-dmg-root" "$TMP/dmg-root"
[ -L "$MOUNT_POINT/Applications" ]
[ "$(/usr/bin/readlink "$MOUNT_POINT/Applications")" = '/Applications' ]
/usr/bin/hdiutil detach "$MOUNT_POINT" >/dev/null
MOUNT_POINT=""

printf 'PASS: macOS Studio release assembly, scanner, signing, and DMG.\n'
