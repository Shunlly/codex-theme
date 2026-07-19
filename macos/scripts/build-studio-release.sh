#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
MACOS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
REPO_ROOT="$(cd "$MACOS_ROOT/.." && pwd -P)"
PACKAGE="$MACOS_ROOT/studio"
RELEASE_ROOT="$MACOS_ROOT/release"

if [ "$#" -ne 1 ]; then
  printf 'Usage: %s --adhoc|--notarize\n' "$0" >&2
  exit 2
fi
case "$1" in
  --adhoc)
    MODE="adhoc"
    IDENTITY="-"
    RELEASE_CHANNEL="adhoc"
    SIGNING_MODE="adhoc"
    NOTARIZED="false"
    STAPLED="false"
    ;;
  --notarize)
    MODE="notarize"
    RELEASE_CHANNEL="notarized"
    SIGNING_MODE="developer-id"
    NOTARIZED="true"
    STAPLED="true"
    [ -n "${CODE_SIGN_IDENTITY:-}" ] || {
      printf 'CODE_SIGN_IDENTITY is required for --notarize.\n' >&2
      exit 2
    }
    [ -n "${NOTARYTOOL_PROFILE:-}" ] || {
      printf 'NOTARYTOOL_PROFILE is required for --notarize.\n' >&2
      exit 2
    }
    IDENTITY="$CODE_SIGN_IDENTITY"
    ;;
  *)
    printf 'Usage: %s --adhoc|--notarize\n' "$0" >&2
    exit 2
    ;;
esac
RELEASE_DIR="$RELEASE_ROOT/$RELEASE_CHANNEL"

[ "$(/usr/bin/uname -s)" = "Darwin" ] || {
  printf 'Studio macOS releases must be built on macOS.\n' >&2
  exit 1
}
for tool in swift lipo strip sips iconutil codesign hdiutil xcrun git node ditto xattr shasum tar; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'Required release tool is unavailable: %s\n' "$tool" >&2
    exit 1
  }
done
NODE="$(command -v node)"
[ -x /usr/libexec/PlistBuddy ] || {
  printf 'Required release tool is unavailable: PlistBuddy\n' >&2
  exit 1
}
if [ "$MODE" = "notarize" ] && ! command -v spctl >/dev/null 2>&1; then
  printf 'Required release tool is unavailable: spctl\n' >&2
  exit 1
fi

INDEX_TREE="$(/usr/bin/git -C "$REPO_ROOT" write-tree 2>/dev/null)" || {
  printf 'Studio build inputs must be tracked regular files matching the git index.\n' >&2
  exit 1
}

release_input_error() {
  printf 'Studio build inputs must be tracked regular files matching the git index.\n' >&2
  exit 1
}

SNAPSHOT_PATHS=(
  macos/studio
  macos/assets
  macos/presets
  macos/scripts
  macos/LICENSE
  macos/NOTICE.md
  macos/VERSION
  studio/assets/app-icon-source.png
  studio/protocol/README.md
  studio/protocol/fixtures-v1.json
  studio/release/check-contents.mjs
  studio/release/allowlist-macos.json
)

verify_tracked_regular_file() {
  local source="$1"
  local absolute="$REPO_ROOT/$source"
  local index_entry=""
  local index_mode=""
  [ -f "$absolute" ] && [ ! -L "$absolute" ] || release_input_error
  index_entry="$(/usr/bin/git -C "$REPO_ROOT" ls-tree "$INDEX_TREE" -- "$source" 2>/dev/null)" \
    || release_input_error
  [ -n "$index_entry" ] || release_input_error
  case "$index_entry" in *$'\n'*) release_input_error ;; esac
  index_mode="${index_entry%% *}"
  case "$index_mode" in 100644|100755) ;; *) release_input_error ;; esac
  /usr/bin/git -C "$REPO_ROOT" cat-file blob "$INDEX_TREE:$source" 2>/dev/null \
    | /usr/bin/cmp -s - "$absolute" || release_input_error
}

verify_index_snapshot_modes() {
  local entry=""
  local mode=""
  /usr/bin/git -C "$REPO_ROOT" ls-tree -r -z "$INDEX_TREE" -- "${SNAPSHOT_PATHS[@]}" \
    >/dev/null 2>&1 \
    || release_input_error
  while IFS= read -r -d '' entry; do
    mode="${entry%% *}"
    case "$mode" in 100644|100755) ;; *) release_input_error ;; esac
  done < <(/usr/bin/git -C "$REPO_ROOT" ls-tree -r -z "$INDEX_TREE" -- "${SNAPSHOT_PATHS[@]}")
}

verify_swift_build_inputs() {
  local source_root="$PACKAGE/Sources"
  local entry=""
  local relative=""
  verify_tracked_regular_file macos/studio/Package.swift
  [ -d "$source_root" ] && [ ! -L "$source_root" ] || release_input_error
  /usr/bin/find "$source_root" -print >/dev/null 2>&1 || release_input_error
  while IFS= read -r -d '' entry; do
    [ ! -L "$entry" ] || release_input_error
    if [ -d "$entry" ]; then continue; fi
    [ -f "$entry" ] || release_input_error
    relative="${entry#"$REPO_ROOT/"}"
    [ "$relative" != "$entry" ] || release_input_error
    verify_tracked_regular_file "$relative"
  done < <(/usr/bin/find "$source_root" -mindepth 1 -print0)
}

verify_swift_build_inputs
verify_index_snapshot_modes
[ "$(/usr/bin/git -C "$REPO_ROOT" write-tree 2>/dev/null)" = "$INDEX_TREE" ] \
  || release_input_error

TMP="$(/usr/bin/mktemp -d "$MACOS_ROOT/.studio-release.XXXXXX")"
OLD_RELEASE="$MACOS_ROOT/.release-old.$RELEASE_CHANNEL.$$"
cleanup() {
  /bin/rm -rf "$TMP"
  if [ -d "$OLD_RELEASE" ] && [ ! -e "$RELEASE_DIR" ]; then
    /bin/mv "$OLD_RELEASE" "$RELEASE_DIR"
  fi
}
trap cleanup EXIT

SNAPSHOT_ROOT="$TMP/index"
SNAPSHOT_SOURCE_ROOT="$SNAPSHOT_ROOT"
SNAPSHOT_PACKAGE="$SNAPSHOT_ROOT/macos/studio"
/bin/mkdir -p "$SNAPSHOT_ROOT"
/usr/bin/git -C "$REPO_ROOT" archive --format=tar "$INDEX_TREE" -- "${SNAPSHOT_PATHS[@]}" \
  | /usr/bin/tar -xf - -C "$SNAPSHOT_ROOT" || release_input_error
[ -f "$SNAPSHOT_PACKAGE/Package.swift" ] && [ ! -L "$SNAPSHOT_PACKAGE/Package.swift" ] \
  && [ -d "$SNAPSHOT_PACKAGE/Sources" ] && [ ! -L "$SNAPSHOT_PACKAGE/Sources" ] \
  || release_input_error
/usr/bin/find "$SNAPSHOT_ROOT" -type f -exec /bin/chmod a-w {} +

VERSION="$(/usr/bin/tr -d '[:space:]' < "$SNAPSHOT_ROOT/macos/VERSION")"
[ "$VERSION" = "1.3.0" ] || {
  printf 'The macOS release version is invalid.\n' >&2
  exit 1
}
if [ "$MODE" = "adhoc" ]; then
  APP_NAME="CodexDreamSkinStudio-$VERSION-macos-universal-ADHOC.app"
  DMG_NAME="CodexDreamSkinStudio-$VERSION-macos-universal-ADHOC.dmg"
else
  APP_NAME="CodexDreamSkinStudio.app"
  DMG_NAME="CodexDreamSkinStudio.dmg"
fi

PUBLISH="$TMP/publish"
APP="$PUBLISH/$APP_NAME"
CONTENTS="$APP/Contents"
RESOURCES="$CONTENTS/Resources"
ENGINE="$RESOURCES/engine"
ICONSET="$TMP/AppIcon.iconset"
DMG_ROOT="$TMP/dmg-root"
/bin/mkdir -p "$CONTENTS/MacOS" "$ENGINE/bin" "$ENGINE/scripts" \
  "$ENGINE/protocol" "$ICONSET" "$DMG_ROOT" "$PUBLISH"

copy_snapshot_file() {
  local source="$1"
  local destination="$2"
  local source_path="$SNAPSHOT_SOURCE_ROOT/$source"
  [ -f "$source_path" ] && [ ! -L "$source_path" ] || release_input_error
  /bin/mkdir -p "$(/usr/bin/dirname "$destination")"
  /bin/cp -P "$source_path" "$destination"
  [ -f "$destination" ] && [ ! -L "$destination" ] || release_input_error
  /usr/bin/git -C "$REPO_ROOT" cat-file blob "$INDEX_TREE:$source" 2>/dev/null \
    | /usr/bin/cmp -s - "$destination" || release_input_error
  /bin/chmod 644 "$destination"
}

build_thin() {
  local product="$1"
  local architecture="$2"
  local triple="$3"
  local scratch="$TMP/build-$product-$architecture"
  /usr/bin/swift build --package-path "$SNAPSHOT_PACKAGE" --scratch-path "$scratch" \
    --configuration release --triple "$triple" --product "$product"
  local bin_path
  bin_path="$(/usr/bin/swift build --package-path "$SNAPSHOT_PACKAGE" --scratch-path "$scratch" \
    --configuration release --triple "$triple" --show-bin-path)"
  local binary="$bin_path/$product"
  [ -f "$binary" ] || {
    printf 'Swift product is missing after build: %s (%s)\n' "$product" "$architecture" >&2
    exit 1
  }
  [ "$(/usr/bin/lipo -archs "$binary")" = "$architecture" ] || {
    printf 'Swift product has the wrong architecture: %s (%s)\n' "$product" "$architecture" >&2
    exit 1
  }
  /bin/cp "$binary" "$TMP/$product-$architecture"
}

for specification in \
  'arm64 arm64-apple-macosx12.0' \
  'x86_64 x86_64-apple-macosx12.0'
do
  architecture="${specification%% *}"
  triple="${specification#* }"
  build_thin CodexDreamSkinStudio "$architecture" "$triple"
  build_thin dream-skin-config-restore "$architecture" "$triple"
done

/usr/bin/lipo -create \
  "$TMP/CodexDreamSkinStudio-arm64" "$TMP/CodexDreamSkinStudio-x86_64" \
  -output "$CONTENTS/MacOS/CodexDreamSkinStudio"
/usr/bin/lipo -create \
  "$TMP/dream-skin-config-restore-arm64" "$TMP/dream-skin-config-restore-x86_64" \
  -output "$ENGINE/bin/dream-skin-config-restore"
/usr/bin/strip -S "$CONTENTS/MacOS/CodexDreamSkinStudio"
/usr/bin/strip -S "$ENGINE/bin/dream-skin-config-restore"
/bin/chmod 755 "$CONTENTS/MacOS/CodexDreamSkinStudio" \
  "$ENGINE/bin/dream-skin-config-restore"
for binary in \
  "$CONTENTS/MacOS/CodexDreamSkinStudio" \
  "$ENGINE/bin/dream-skin-config-restore"
do
  archs=" $(/usr/bin/lipo -archs "$binary") "
  case "$archs" in *' arm64 '*) ;; *) printf 'Universal binary is missing arm64.\n' >&2; exit 1 ;; esac
  case "$archs" in *' x86_64 '*) ;; *) printf 'Universal binary is missing x86_64.\n' >&2; exit 1 ;; esac
done

copy_snapshot_file macos/studio/Resources/Info.plist "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$CONTENTS/Info.plist"
copy_snapshot_file studio/assets/app-icon-source.png "$TMP/app-icon-source.png"
if /usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$CONTENTS/Info.plist" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile AppIcon' "$CONTENTS/Info.plist"
else
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$CONTENTS/Info.plist"
fi

for icon in \
  '16 icon_16x16.png' \
  '32 icon_16x16@2x.png' \
  '32 icon_32x32.png' \
  '64 icon_32x32@2x.png' \
  '128 icon_128x128.png' \
  '256 icon_128x128@2x.png' \
  '256 icon_256x256.png' \
  '512 icon_256x256@2x.png' \
  '512 icon_512x512.png' \
  '1024 icon_512x512@2x.png'
do
  size="${icon%% *}"
  name="${icon#* }"
  /usr/bin/sips -s format png -z "$size" "$size" \
    "$TMP/app-icon-source.png" --out "$ICONSET/$name" >/dev/null
done
/usr/bin/iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"
/bin/chmod 644 "$RESOURCES/AppIcon.icns"

while IFS= read -r -d '' source; do
  relative="${source#macos/}"
  copy_snapshot_file "$source" "$ENGINE/$relative"
done < <(/usr/bin/git -C "$REPO_ROOT" ls-tree -r -z --name-only \
  "$INDEX_TREE" -- macos/assets macos/presets)

RUNTIME_SCRIPTS=(
  common-macos.sh
  image-metadata.mjs
  injector.mjs
  install-dream-skin-macos.sh
  pause-dream-skin-macos.sh
  restore-dream-skin-macos.sh
  stage-theme.mjs
  start-dream-skin-macos.sh
  status-dream-skin-macos.sh
  studio-adapter-macos.sh
  switch-theme-macos.sh
  theme-config.mjs
  verify-dream-skin-macos.sh
)
for script in "${RUNTIME_SCRIPTS[@]}"; do
  copy_snapshot_file "macos/scripts/$script" "$ENGINE/scripts/$script"
  case "$script" in *.sh) /bin/chmod 755 "$ENGINE/scripts/$script" ;; esac
done
copy_snapshot_file macos/LICENSE "$ENGINE/LICENSE"
copy_snapshot_file macos/NOTICE.md "$ENGINE/NOTICE.md"
copy_snapshot_file macos/VERSION "$ENGINE/VERSION"
copy_snapshot_file studio/protocol/README.md "$ENGINE/protocol/README.md"
copy_snapshot_file studio/protocol/fixtures-v1.json "$ENGINE/protocol/fixtures-v1.json"

/usr/bin/xattr -cr "$APP"
/usr/bin/find "$APP" -type f \( -name '.DS_Store' -o -name '._*' \) -delete

if [ "$MODE" = "notarize" ]; then
  /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    "$ENGINE/bin/dream-skin-config-restore"
else
  /usr/bin/codesign --force --sign "$IDENTITY" \
    "$ENGINE/bin/dream-skin-config-restore"
fi
"$NODE" "$SNAPSHOT_ROOT/studio/release/check-contents.mjs" \
  --root "$APP" --allowlist "$SNAPSHOT_ROOT/studio/release/allowlist-macos.json"
if [ "$MODE" = "notarize" ]; then
  /usr/bin/codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
  /usr/bin/codesign --force --deep --sign "$IDENTITY" "$APP"
fi
/usr/bin/codesign --verify --deep --strict "$APP"

if [ "$MODE" = "notarize" ]; then
  APP_ZIP="$TMP/CodexDreamSkinStudio.zip"
  COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --keepParent --norsrc --noextattr "$APP" "$APP_ZIP"
  /usr/bin/xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
  /usr/bin/xcrun stapler staple "$APP"
  /usr/bin/xcrun stapler validate "$APP"
fi

COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc --noextattr "$APP" "$DMG_ROOT/$APP_NAME"
/bin/ln -s /Applications "$DMG_ROOT/Applications"
/usr/bin/xattr -cr "$DMG_ROOT"
/usr/bin/find "$DMG_ROOT" -type f \( -name '.DS_Store' -o -name '._*' \) -delete
COPYFILE_DISABLE=1 /usr/bin/hdiutil create -quiet -ov -format UDZO \
  -volname 'Codex Dream Skin Studio' -srcfolder "$DMG_ROOT" "$PUBLISH/$DMG_NAME"
if [ "$MODE" = "notarize" ]; then
  /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$PUBLISH/$DMG_NAME"
else
  /usr/bin/codesign --force --sign "$IDENTITY" "$PUBLISH/$DMG_NAME"
fi

if [ "$MODE" = "notarize" ]; then
  /usr/bin/xcrun notarytool submit "$PUBLISH/$DMG_NAME" \
    --keychain-profile "$NOTARYTOOL_PROFILE" --wait
  /usr/bin/xcrun stapler staple "$PUBLISH/$DMG_NAME"
  /usr/bin/xcrun stapler validate "$PUBLISH/$DMG_NAME"
  /usr/sbin/spctl --assess --type execute "$APP"
fi

(
  cd "$PUBLISH"
  hash="$(/usr/bin/shasum -a 256 "$DMG_NAME" | /usr/bin/awk '{print $1}')"
  /usr/bin/printf '%s  %s\n' "$hash" "$DMG_NAME" > SHA256SUMS.txt
  "$NODE" - release-manifest.json "$VERSION" "$SIGNING_MODE" "$NOTARIZED" "$STAPLED" \
    "$DMG_NAME" "$hash" <<'NODE'
const fs = require("node:fs");
const [path, version, signing, notarized, stapled, file, sha256] = process.argv.slice(2);
const manifest = {
  schemaVersion: 1,
  version,
  architecture: "universal",
  signing,
  notarized: notarized === "true",
  stapled: stapled === "true",
  file,
  sha256,
};
fs.writeFileSync(path, `${JSON.stringify(manifest, null, 2)}\n`, { encoding: "utf8", flag: "wx" });
NODE
)

/bin/rm -rf "$OLD_RELEASE"
/bin/mkdir -p "$RELEASE_ROOT"
if [ -e "$RELEASE_DIR" ]; then /bin/mv "$RELEASE_DIR" "$OLD_RELEASE"; fi
if ! /bin/mv "$PUBLISH" "$RELEASE_DIR"; then
  [ ! -e "$OLD_RELEASE" ] || /bin/mv "$OLD_RELEASE" "$RELEASE_DIR"
  exit 1
fi
/bin/rm -rf "$OLD_RELEASE"

/usr/bin/printf 'Created %s\nCreated %s\n' \
  "$RELEASE_DIR/$APP_NAME" "$RELEASE_DIR/$DMG_NAME"
