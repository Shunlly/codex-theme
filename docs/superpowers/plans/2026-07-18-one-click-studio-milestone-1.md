# One-Click Studio Milestone 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship signed macOS and Windows Studio applications that let a non-programmer preflight, install, apply, verify, pause, resume, restore, and uninstall Dream Skin without opening a terminal.

**Architecture:** Keep the existing shell, PowerShell, Node injector, state, and config transaction code as the only runtime authority. Add one versioned JSON-lines-free adapter per platform: stdout contains exactly one protocol envelope, stderr contains only fixed progress markers, and raw command output goes to the managed Studio log. SwiftUI and WPF are thin native process clients; they never read Codex config/state directly or manage CDP/PIDs themselves.

**Tech Stack:** Bash and signed Codex Node 20+ on macOS; Swift 6/SwiftUI/AppKit with macOS 12 minimum; Windows PowerShell 5.1, .NET 8 WPF, Inno Setup 6; private Node.js 22.23.1 on Windows; Node standard-library contract/release checks.

## Global Constraints

- This plan implements milestone 1 only. Do not add `.cdxtheme`, theme import/export, workspace bindings, context profiles, motion, video, cloud accounts, or auto-update.
- Never modify official `.app`, `app.asar`, WindowsApps, official signatures, API keys, Base URLs, threads, or `auth.json`.
- CDP remains loopback-only and keeps all existing listener PID, Browser ID, target URL, renderer marker, and process start-time checks.
- Studio runs per-user only: no `sudo`, administrator elevation, system service, launch daemon, or background TCP control API.
- The GUI invokes only fixed adapter paths, operation enums, authorization flags, and the uninstall-only `deleteUserThemes` boolean. It does not parse/write `config.toml`, scan ports, inspect PIDs, or kill processes.
- Adapter stdout is exactly one compact UTF-8 JSON object without BOM. Raw logs go to `studio-operation.log`; stderr may contain only the fixed `DREAM_SKIN_PROGRESS=checking|preparing|installing|launching|connecting|applying|verifying|pausing|restoring|uninstalling` markers.
- Exit codes are `0` for `ok: true`, `1` for a complete domain-error envelope, and `2` for `INVALID_REQUEST` with a complete envelope.
- Restart authorization has two levels: `restartAuthorized` permits normal quit only; `forceAuthorized` is legal only with `restartAuthorized` and permits a verified force stop after the normal 15-second timeout.
- A successful `apply`, `resume`, or `verify` must end with strict renderer verification. Soft verification cannot produce Studio success.
- `pause` must verify live skin removal. `restore` and `uninstall` must close the managed CDP session. `uninstall` must not remove anything until restore succeeds, preserves user themes by default, and deletes them only after a separate explicit opt-in.
- macOS continues to use the Node binary signed inside official Codex for normal operation; full restore must also work when that Node is missing or invalid.
- Windows Studio must use bundled Node.js `22.23.1`; it must not fall back to PATH. Legacy PowerShell entry points may keep PATH fallback when no explicit Node path is supplied.
- Keep mutable data in `~/Library/Application Support/CodexDreamSkinStudio` on macOS and `%LOCALAPPDATA%\CodexDreamSkin` on Windows. Keep the macOS engine at `~/.codex/codex-dream-skin-studio` and the Windows release engine under `%LOCALAPPDATA%\Programs\CodexDreamSkinStudio\versions\1.3.0\engine`. Do not add another state database.
- Run all existing platform tests. Do not bypass failures. Real home and task routes remain required for live acceptance.

---

## File Map

### Shared

- Create `studio/protocol/README.md`: Studio Engine Protocol v1 enums, envelope, exit codes, authorization semantics, and privacy rules.
- Create `studio/protocol/fixtures-v1.json`: canonical success/error states consumed by Swift and C# tests.
- Create `studio/protocol/validate-fixtures.mjs`: dependency-free fixture validator.
- Create `studio/assets/README.md`: provenance for the generated application icon source.
- Create `studio/assets/app-icon-source.png`: 1024x1024 square derived from the MIT procedural Midnight Aurora preset.
- Create `studio/release/check-contents.mjs`: shared staged/release content scanner.
- Create `studio/release/allowlist-macos.json` and `studio/release/allowlist-windows.json`: exact release-relative executable allowlists.

### macOS

- Create `macos/scripts/studio-adapter-macos.sh`: sole native-app engine entry point.
- Create `macos/tests/studio-adapter.test.sh`: adapter protocol, authorization, and no-side-effect tests.
- Modify `macos/scripts/status-dream-skin-macos.sh`: full Studio status projection while preserving current `--json` output.
- Modify `macos/scripts/install-dream-skin-macos.sh`: explicit authorized-close mode and no-launch Studio install.
- Modify `macos/scripts/start-dream-skin-macos.sh`: strict Studio verification and complete failure rollback.
- Modify `macos/scripts/pause-dream-skin-macos.sh`: stable failure mapping and verified removal result.
- Modify `macos/scripts/restore-dream-skin-macos.sh`: native restore fallback and engine uninstall after successful restore.
- Modify `macos/scripts/verify-dream-skin-macos.sh`: stable strict-verification result.
- Modify `macos/scripts/common-macos.sh`: non-fatal preflight helpers without weakening existing fatal wrappers.
- Create `macos/studio/Package.swift`: dependency-free Swift package with app, core, restore helper, and tests.
- Create `macos/studio/Sources/DreamSkinStudioCore/EngineProtocol.swift`: Codable protocol types.
- Create `macos/studio/Sources/DreamSkinStudioCore/EngineClient.swift`: fixed-path adapter process client.
- Create `macos/studio/Sources/DreamSkinStudioCore/StudioModel.swift`: main-actor UI state machine.
- Create `macos/studio/Sources/CodexDreamSkinStudio/CodexDreamSkinStudioApp.swift`: window and menu-bar app entry.
- Create `macos/studio/Sources/CodexDreamSkinStudio/ContentView.swift`: single operational screen and confirmations.
- Create `macos/studio/Sources/CodexDreamSkinStudio/StatusItemController.swift`: AppKit `NSStatusItem` integration compatible with macOS 12.
- Create `macos/studio/Sources/DreamSkinConfigRestoreCore/SelectiveConfigRestore.swift`: Node-free selective restore implementation.
- Create `macos/studio/Sources/DreamSkinConfigRestore/main.swift`: restore helper CLI.
- Create focused XCTest files under `macos/studio/Tests/`.
- Create `macos/studio/Resources/Info.plist`: bundle metadata and macOS 12 floor.
- Create `macos/scripts/build-studio-release.sh`: universal app, DMG, signing, notarization, hashes.
- Create `macos/tests/studio-release.test.sh`: ad-hoc app/DMG and content tests.

### Windows

- Create `windows/VERSION`, `windows/LICENSE`, and `windows/NOTICE.md`: version and redistribution notices.
- Create `windows/build/node-runtime.lock.json`: Node archive URLs and SHA-256 values.
- Create `windows/build/NODE-NOTICE.txt`: Node redistribution notice shipped beside its license.
- Create `windows/scripts/fetch-node-runtime.ps1`: verified x64/arm64 runtime acquisition.
- Modify `windows/scripts/common-windows.ps1`: optional explicit Node path and private-runtime validation.
- Modify `windows/scripts/install-dream-skin.ps1`: explicit Node path and two-level authorized close while preserving legacy CLI behavior.
- Modify `windows/scripts/start-dream-skin.ps1`: explicit Node path and two-level restart/force authorization.
- Modify `windows/scripts/verify-dream-skin.ps1`: explicit Node path.
- Create `windows/scripts/status-dream-skin.ps1`: read-only Studio status projection.
- Create `windows/scripts/pause-dream-skin.ps1`: immediate pause and verified live removal.
- Create `windows/scripts/studio-windows.ps1`: envelope/error/status helper functions.
- Create `windows/scripts/studio-adapter.ps1`: sole WPF engine entry point.
- Create `windows/tests/studio-protocol.tests.ps1`: protocol, authorization, and lifecycle regression tests.
- Modify `windows/tests/run-tests.ps1`: invoke the focused Studio protocol test.
- Create WPF files under `windows/studio/` and a dependency-free console self-check under `windows/studio-tests/`.
- Create `windows/build/dream-skin-studio.iss`: Inno Setup 6 per-user installer with restore-before-uninstall guard.
- Create `windows/scripts/build-studio-release.ps1`: runtime, publish, stage, scan, sign, Inno, hashes.

### Documentation and Versioning

- Modify `README.md`, `README.en.md`, `macos/README.md`, `windows/SKILL.md`, and `docs/platforms.md`.
- Modify `macos/references/qa-inventory.md`, `windows/references/qa-inventory.md`, and both runtime notes.
- Modify `macos/CHANGELOG.md`, `windows/CHANGELOG.md`, `macos/VERSION`, and `macos/package.json`.
- Create platform Studio acceptance records only after real VM/live checks have actually run.

---

### Task 1: Freeze Studio Engine Protocol v1

**Files:**
- Create: `studio/protocol/README.md`
- Create: `studio/protocol/fixtures-v1.json`
- Create: `studio/protocol/validate-fixtures.mjs`

**Interfaces:**
- Consumes: approved design at `docs/superpowers/specs/2026-07-18-theme-studio-productization-design.md`.
- Produces: the exact `EngineOperation`, state enum, error-code, recovery-action, envelope, progress-marker, and exit-code contract used by every later task.

- [ ] **Step 1: Write the fixture validator before the fixtures exist**

Create `studio/protocol/validate-fixtures.mjs` with strict allowed-key and enum checks:

```js
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const fixtures = JSON.parse(fs.readFileSync(path.join(here, "fixtures-v1.json"), "utf8"));
const operations = new Set(["preflight", "install", "apply", "status", "pause", "resume", "restore", "verify", "uninstall"]);
const installs = new Set(["not-installed", "ready"]);
const codexStates = new Set(["not-installed", "needs-first-run", "stopped", "running"]);
const sessions = new Set(["official", "active", "paused", "stale"]);
const operationStates = new Set(["idle", "busy"]);
const availableActions = new Set(["install", "apply", "pause", "resume", "restore", "verify", "uninstall"]);
const recoveryActions = new Set([
  "open-codex", "authorize-restart", "authorize-force-stop", "retry", "restore", "diagnostics", "cancel",
]);
const errorCodes = new Set([
  "INVALID_REQUEST", "OPERATION_BUSY", "CODEX_NOT_INSTALLED", "CODEX_FIRST_RUN_REQUIRED",
  "CODEX_IDENTITY_INVALID", "RUNTIME_INVALID", "CODEX_CLOSE_REQUIRED", "RESTART_REQUIRED",
  "FORCE_STOP_REQUIRED", "STATE_UNSAFE", "PORT_UNAVAILABLE", "CONFIG_UNSAFE", "CONFIG_CHANGED",
  "CONFIG_BACKUP_MISSING", "THEME_INVALID", "INJECTOR_FAILED", "VERIFY_FAILED",
  "LIVE_REMOVE_FAILED", "OPERATION_FAILED", "INTERNAL_ERROR",
]);
const topKeys = ["error", "ok", "operation", "schemaVersion", "state"];
const stateKeys = ["availableActions", "codex", "install", "operation", "requiresRestart", "session", "themeName", "verified"];
const fixtureNames = [
  "not-installed", "needs-first-run", "installed-official", "active-verified", "paused", "stale-state",
  "restart-required", "force-stop-required", "verify-failed", "restored-official",
  "uninstalled-themes-preserved", "uninstalled-themes-deleted",
];

assert(Array.isArray(fixtures));
assert.deepEqual(fixtures.map((fixture) => fixture.name).sort(), fixtureNames.sort());
for (const fixture of fixtures) {
  assert.deepEqual(Object.keys(fixture.response).sort(), topKeys);
  assert.deepEqual(Object.keys(fixture.response.state).sort(), stateKeys);
  assert.equal(fixture.response.schemaVersion, 1);
  assert(operations.has(fixture.response.operation));
  assert(installs.has(fixture.response.state.install));
  assert(codexStates.has(fixture.response.state.codex));
  assert(sessions.has(fixture.response.state.session));
  assert(operationStates.has(fixture.response.state.operation));
  assert([true, false, null].includes(fixture.response.state.verified));
  assert(Array.isArray(fixture.response.state.availableActions));
  assert.equal(new Set(fixture.response.state.availableActions).size, fixture.response.state.availableActions.length);
  assert(fixture.response.state.availableActions.every((action) => availableActions.has(action)));
  if (fixture.response.state.session === "active") {
    assert.equal(fixture.response.state.install, "ready");
    assert.equal(fixture.response.state.codex, "running");
  }
  if (fixture.response.ok && ["apply", "resume", "verify"].includes(fixture.response.operation)) {
    assert.equal(fixture.response.state.verified, true);
  }
  if (fixture.response.ok) {
    assert.equal(fixture.response.error, null);
  } else {
    assert.deepEqual(Object.keys(fixture.response.error).sort(), ["code", "message", "recoveryActions"]);
    assert(errorCodes.has(fixture.response.error.code));
    assert(Array.isArray(fixture.response.error.recoveryActions));
    assert(fixture.response.error.recoveryActions.every((action) => recoveryActions.has(action)));
  }
  const serialized = JSON.stringify(fixture.response);
  assert(!/(?:port|pid|cdp|powershell|\/Users\/|[A-Z]:\\Users\\)/i.test(serialized));
}
console.log("PASS: Studio protocol fixtures v1.");
```

- [ ] **Step 2: Run the validator and confirm the expected failure**

Run:

```bash
NODE=/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node
"$NODE" studio/protocol/validate-fixtures.mjs
```

Expected: FAIL with `ENOENT` for `studio/protocol/fixtures-v1.json`.

- [ ] **Step 3: Add the exact contract and canonical fixtures**

Document these fixed enums in `studio/protocol/README.md`:

```text
operation: preflight | install | apply | status | pause | resume | restore | verify | uninstall
install: not-installed | ready
codex: not-installed | needs-first-run | stopped | running
session: official | active | paused | stale
operation state: idle | busy
verified: true | false | null
exit: 0 success | 1 domain error | 2 invalid request
progress: checking | preparing | installing | launching | connecting | applying | verifying | pausing | restoring | uninstalling
available action: install | apply | pause | resume | restore | verify | uninstall
recovery action: open-codex | authorize-restart | authorize-force-stop | retry | restore | diagnostics | cancel
```

Document one non-envelope request option: `deleteUserThemes` defaults to `false`, is valid only for `uninstall`, and returns `INVALID_REQUEST` for every other operation. Platform spellings are `--delete-user-themes` on macOS and `-DeleteUserThemes` on Windows. Theme deletion is the final uninstall action after restore, CDP closure, and engine cleanup eligibility have all succeeded.

Add exactly these named fixtures to `fixtures-v1.json`, with every field populated: `not-installed`, `needs-first-run`, `installed-official`, `active-verified`, `paused`, `stale-state`, `restart-required`, `force-stop-required`, `verify-failed`, `restored-official`, `uninstalled-themes-preserved`, and `uninstalled-themes-deleted`. Use `午夜极光` in `active-verified` to prove UTF-8 round-trip. `restart-required` must use:

```json
{
  "schemaVersion": 1,
  "ok": false,
  "operation": "apply",
  "state": {
    "install": "ready",
    "codex": "running",
    "session": "official",
    "operation": "idle",
    "themeName": "午夜极光",
    "requiresRestart": true,
    "availableActions": ["apply", "restore", "uninstall"],
    "verified": null
  },
  "error": {
    "code": "RESTART_REQUIRED",
    "message": "Codex must restart once to apply the theme.",
    "recoveryActions": ["authorize-restart", "cancel"]
  }
}
```

- [ ] **Step 4: Run the validator and inspect the public contract**

Run:

```bash
NODE=/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node
"$NODE" studio/protocol/validate-fixtures.mjs
```

Expected: `PASS: Studio protocol fixtures v1.`

- [ ] **Step 5: Commit the protocol**

```bash
git add studio/protocol
git commit -m "docs(protocol): define Studio engine v1"
```

---

### Task 2: Add Read-Only macOS Studio Status and Adapter

**Files:**
- Create: `macos/scripts/studio-adapter-macos.sh`
- Create: `macos/tests/studio-adapter.test.sh`
- Modify: `macos/scripts/status-dream-skin-macos.sh:8-139`

**Interfaces:**
- Consumes: Protocol v1 from Task 1 and current legacy status JSON.
- Produces: `studio-adapter-macos.sh preflight|status` with one protocol envelope and no writes; later macOS lifecycle and Swift tasks use the same adapter.

- [ ] **Step 1: Write failing read-only adapter tests**

Create a temporary `HOME`, capture a recursive file/hash snapshot before and after `preflight` and `status`, parse stdout with Node, and assert the snapshots match. Include these assertions:

```bash
STATUS_JSON="$($ROOT/scripts/studio-adapter-macos.sh status)"
"$NODE" -e '
  const value = JSON.parse(process.argv[1]);
  if (value.schemaVersion !== 1 || value.operation !== "status") process.exit(1);
  if (!value.state || !Array.isArray(value.state.availableActions)) process.exit(1);
  if (/(port|pid|cdp|powershell|\/Users\/)/i.test(JSON.stringify(value))) process.exit(1);
' "$STATUS_JSON"
```

Also test an unknown operation exits `2` and returns `error.code === "INVALID_REQUEST"`.

- [ ] **Step 2: Run the focused test and confirm it fails**

Run:

```bash
NODE=/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node macos/tests/studio-adapter.test.sh
```

Expected: FAIL because `macos/scripts/studio-adapter-macos.sh` does not exist.

- [ ] **Step 3: Extend status without breaking its current callers**

Keep `--json`, `--short`, and text output byte-compatible. Add `--studio-json`, `--operation "$OPERATION"`, and optional `--deep`; reject an operation outside the nine Protocol v1 values. Derive, without creating directories:

```text
install = ready only when ~/.codex/codex-dream-skin-studio/VERSION exactly matches the bundled engine VERSION, its adapter/start/restore scripts are executable, ~/Library/Application Support/CodexDreamSkinStudio/theme-backup.json exists, and ~/Library/Application Support/CodexDreamSkinStudio/theme/theme.json exists
codex = not-installed when no official bundle exists
codex = needs-first-run when the bundle exists but ~/.codex/config.toml does not
codex = running when ChatGPT or Codex main process is present; otherwise stopped
session = active | paused | stale from existing identity checks; otherwise official
verified = true only after a deep verified CDP probe; otherwise null
requiresRestart = codex is running and deep CDP is not verified
```

Emit JSON with the existing `json_escape` helper and an action array derived only from those states.

- [ ] **Step 4: Implement the non-mutating adapter core**

Start `studio-adapter-macos.sh` with this fixed parser and error shape:

```bash
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
OPERATION="${1:-status}"
shift || true

emit_invalid_request() {
  printf '%s\n' '{"schemaVersion":1,"ok":false,"operation":"status","state":{"install":"not-installed","codex":"not-installed","session":"official","operation":"idle","themeName":null,"requiresRestart":false,"availableActions":[],"verified":null},"error":{"code":"INVALID_REQUEST","message":"The Studio operation is invalid.","recoveryActions":["cancel"]}}'
  exit 2
}

case "$OPERATION" in
  preflight|status)
    [ "$#" -eq 0 ] || emit_invalid_request
    exec "$SCRIPT_DIR/status-dream-skin-macos.sh" --studio-json --deep --operation "$OPERATION"
    ;;
  install|apply|pause|resume|restore|verify|uninstall)
    emit_invalid_request
    ;;
  *) emit_invalid_request ;;
esac
```

Task 3 replaces the intentional lifecycle `INVALID_REQUEST` branches.

- [ ] **Step 5: Run focused and existing tests**

```bash
NODE=/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node macos/tests/studio-adapter.test.sh
cd macos && npm test
```

Expected: focused test prints its adapter PASS line, and the existing suite prints `PASS: syntax, payload, bundled presets, preset seeding, runtime-state safety, custom-theme, config round-trips, HOME recovery, signature, and doctor checks.`

- [ ] **Step 6: Commit read-only status**

```bash
git add macos/scripts/status-dream-skin-macos.sh macos/scripts/studio-adapter-macos.sh macos/tests/studio-adapter.test.sh
git commit -m "feat(macos): add read-only Studio status"
```

---

### Task 3: Wire Authorized macOS Lifecycle Operations

**Files:**
- Modify: `macos/scripts/studio-adapter-macos.sh`
- Modify: `macos/scripts/install-dream-skin-macos.sh:6-61`
- Modify: `macos/scripts/start-dream-skin-macos.sh:15-135`
- Modify: `macos/scripts/pause-dream-skin-macos.sh:9-77`
- Modify: `macos/scripts/restore-dream-skin-macos.sh:6-69`
- Modify: `macos/scripts/verify-dream-skin-macos.sh:6-29`
- Modify: `macos/tests/studio-adapter.test.sh`

**Interfaces:**
- Consumes: Task 2 adapter and existing platform scripts.
- Produces: all nine macOS operations, `--restart-authorized`, `--force-authorized`, uninstall-only `--delete-user-themes`, strict verification, verified pause, and restore-before-uninstall behavior.

- [ ] **Step 1: Add failing authorization and mutation tests**

Copy the adapter into a temporary `scripts/` directory with executable sibling stubs. Have each stub append its argv to a marker file and return a known status fixture. Assert:

```text
apply with no authorization -> RESTART_REQUIRED and no marker
apply --restart-authorized -> start receives no force flag
apply --restart-authorized --force-authorized -> start receives both explicit flags
--force-authorized alone -> INVALID_REQUEST exit 2 and no marker
--delete-user-themes with any operation except uninstall -> INVALID_REQUEST exit 2 and no write
install without close authorization -> CODEX_CLOSE_REQUIRED when Codex is reported running
install upgrade -> verified managed injector and Codex stop before the first engine-directory rename
install with stale/foreign process identity -> STATE_UNSAFE and no engine-directory write
restore while running with restart authorization only -> normal quit, no force flag
restore normal-quit timeout -> FORCE_STOP_REQUIRED before injector, state, backup, or config mutation
restore with both authorization levels -> force flag reaches restore
uninstall -> restore stub runs before delete stub
restore failure -> delete stub never runs
uninstall default -> saved themes/images remain; explicit delete -> themes/images/active theme are removed last
stdout contains one JSON line for every case
```

- [ ] **Step 2: Run the test and confirm lifecycle cases fail**

```bash
NODE=/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node macos/tests/studio-adapter.test.sh
```

Expected: FAIL because lifecycle operations still return `INVALID_REQUEST`.

- [ ] **Step 3: Add explicit authorization flags to existing scripts**

Add `--close-running` and `--force-stop-authorized` to install and propagate both through the existing `--in-place` re-exec. Before `deploy_project`, revalidate any recorded injector and Codex identity, require close authorization, stop them, and only then perform the first directory rename. Identity mismatch or a cancelled/failed normal quit must leave the existing engine directory byte-for-byte unchanged. Replace the current unconditional running-app failure with:

```bash
if codex_is_running; then
  [ "$CLOSE_RUNNING" = "true" ] || fail "Close Codex before installation so config.toml cannot be rewritten while the app is saving it."
  stop_codex "$FORCE_STOP_AUTHORIZED"
fi
```

Add `--force-stop-authorized` to start and restore as well. Every pre-existing Codex close first calls `stop_codex false`; if that times out, return `FORCE_STOP_REQUIRED` before changing injector state, config, backups, or engine files. Only a second adapter call containing both authorization levels may pass `true`. Keep old CLI defaults unchanged, including their existing interactive behavior.

Add `--studio-strict-verify` to start. In strict mode, do not accept the existing `"installed": true` soft-success branch. On final verify failure: safely stop the recorded injector, remove live skin through the verified endpoint, remove state only after the injector stops, close the authorized CDP Codex instance, and reopen official Codex without debugging flags.

- [ ] **Step 4: Complete the adapter command map**

Use only these script mappings:

```text
install   -> install-dream-skin-macos.sh --no-launchers --no-launch
apply     -> start-dream-skin-macos.sh --studio-strict-verify
pause     -> pause-dream-skin-macos.sh
resume    -> start-dream-skin-macos.sh --studio-strict-verify
restore   -> restore-dream-skin-macos.sh --restore-base-theme --restart-codex
verify    -> verify-dream-skin-macos.sh --reload
uninstall -> restore-dream-skin-macos.sh --restore-base-theme --restart-codex --uninstall
```

The adapter inside the `.app` is always the GUI entry point. For `preflight`, `status`, and `install`, it uses scripts beside itself; install atomically publishes them to `~/.codex/codex-dream-skin-studio` and re-executes there. For `apply`, `pause`, `resume`, and `verify`, it requires installed `VERSION` to equal the bundled `VERSION` and invokes only that installed engine, so the watcher never depends on a mounted DMG or movable `.app`. For `restore` and `uninstall`, it prefers the installed engine but may use the bundled restore script/helper when the install is partial or its Node is unavailable.

The table lists base arguments. When a running Codex must close, `restartAuthorized` adds `--close-running` for install, `--restart-existing` for apply/resume, or permits `--restart-codex` for restore/uninstall; `forceAuthorized` additionally adds `--force-stop-authorized`. The adapter rejects `forceAuthorized` without `restartAuthorized`. Engine and launcher deletion for uninstall occurs only after the restore command returns success and the final status is `session: official`. `--delete-user-themes` then removes only `$STATE_ROOT/themes`, `$STATE_ROOT/images`, and `$STATE_ROOT/theme`, as the last successful action; without it all three remain.

The adapter must capture raw stdout/stderr into `~/Library/Application Support/CodexDreamSkinStudio/studio-operation.log`, emit fixed progress markers on stderr, and call `status-dream-skin-macos.sh --studio-json --deep --operation "$OPERATION"` for the final success envelope. Map underlying failures to the stable Task 1 error codes; never copy a raw exception or path into the envelope.

- [ ] **Step 5: Prove pause, strict verify, and uninstall ordering**

Run:

```bash
NODE=/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node macos/tests/studio-adapter.test.sh
cd macos && npm test
```

Expected: all operation/authorization fixtures PASS; existing PID/state/config tests still pass.

- [ ] **Step 6: Commit the macOS lifecycle**

```bash
git add macos/scripts macos/tests/studio-adapter.test.sh
git commit -m "feat(macos): wire Studio lifecycle operations"
```

---

### Task 4: Make Complete macOS Restore Independent of Node

**Files:**
- Create: `macos/studio/Package.swift`
- Create: `macos/studio/Sources/DreamSkinConfigRestoreCore/SelectiveConfigRestore.swift`
- Create: `macos/studio/Sources/DreamSkinConfigRestore/main.swift`
- Create: `macos/studio/Tests/DreamSkinConfigRestoreCoreTests/SelectiveConfigRestoreTests.swift`
- Modify: `macos/scripts/common-macos.sh:94-164,330-354`
- Modify: `macos/scripts/restore-dream-skin-macos.sh:21-59`
- Modify: `macos/tests/run-tests.sh`

**Interfaces:**
- Consumes: schema 1 backup contract in `macos/scripts/theme-config.mjs`.
- Produces: `dream-skin-config-restore "$CONFIG_PATH" "$THEME_BACKUP_PATH"`, copied into the installed engine and usable when Codex Node is absent.

- [ ] **Step 1: Create failing selective-restore XCTest cases**

The test matrix must include: Chinese content with LF; CRLF preservation; UTF-8 BOM preservation; invalid UTF-8; NUL; symlink config; multiple `[desktop]` tables; duplicate target keys; multiline strings/arrays; malicious backup keys; config byte change before rename; missing backup; successful restore deletes backup only after atomic replacement.

Use this public API in the tests:

```swift
public enum SelectiveConfigRestore {
    public static func restore(configURL: URL, backupURL: URL) throws
}
```

- [ ] **Step 2: Run the targeted test and confirm it fails**

```bash
swift test --package-path macos/studio --filter DreamSkinConfigRestoreCoreTests
```

Expected: FAIL because the target and implementation do not exist.

- [ ] **Step 3: Add the dependency-free Swift package and restore helper**

Use this package boundary:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexDreamSkinStudio",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "DreamSkinConfigRestoreCore", targets: ["DreamSkinConfigRestoreCore"]),
        .executable(name: "dream-skin-config-restore", targets: ["DreamSkinConfigRestore"]),
    ],
    targets: [
        .target(name: "DreamSkinConfigRestoreCore"),
        .executableTarget(name: "DreamSkinConfigRestore", dependencies: ["DreamSkinConfigRestoreCore"]),
        .testTarget(name: "DreamSkinConfigRestoreCoreTests", dependencies: ["DreamSkinConfigRestoreCore"]),
    ]
)
```

Implement only restore, not install. Match `theme-config.mjs` schema 1 exactly: strict UTF-8, only `appearanceTheme` and `appearanceDarkCodeThemeId`, same `.dream-skin.lock`, inode/device and original-byte recheck, same-directory exclusive temp file, atomic rename, and backup deletion after success.

- [ ] **Step 4: Add non-fatal runtime discovery wrappers without changing old behavior**

Keep `discover_codex_app` and `require_macos_runtime` fatal for existing callers. Add `try_discover_codex_app` and `try_require_macos_runtime` that return nonzero and write diagnostics to stderr. Restore should use validated Codex Node when available, otherwise execute `$INSTALL_ROOT/bin/dream-skin-config-restore`. Process identity checks remain mandatory before stopping any process.

- [ ] **Step 5: Run Swift and shell regression tests**

```bash
swift test --package-path macos/studio --filter DreamSkinConfigRestoreCoreTests
cd macos && npm test
```

Expected: Swift tests PASS; existing config round-trip/security tests PASS; a new fixture with `NODE` unset invokes the native helper and restores successfully.

- [ ] **Step 6: Commit Node-free restore**

```bash
git add macos/studio macos/scripts/common-macos.sh macos/scripts/restore-dream-skin-macos.sh macos/tests/run-tests.sh
git commit -m "fix(macos): restore appearance without Codex Node"
```

---

### Task 5: Bundle and Validate the Windows Private Node Runtime

**Files:**
- Create: `windows/build/node-runtime.lock.json`
- Create: `windows/build/NODE-NOTICE.txt`
- Create: `windows/scripts/fetch-node-runtime.ps1`
- Modify: `windows/scripts/common-windows.ps1:78-95`
- Modify: `windows/tests/run-tests.ps1`

**Interfaces:**
- Consumes: official Node.js archives.
- Produces: `windows/runtime/{x64|arm64}/node.exe`, `LICENSE.node.txt`, and `NOTICE.node.txt`; `Get-DreamSkinNodeRuntime -NodePath "$PrivateNodePath"` validates the absolute Studio runtime without PATH fallback.

- [ ] **Step 1: Add failing runtime lock and tamper tests**

In a temp directory, create a ZIP with a fake `node.exe` and LICENSE, build a temporary lock with the correct hash, and prove extraction succeeds. Change one hash nibble and prove extraction fails without publishing any runtime. Add a static assertion that explicit `-NodePath` never calls `Get-Command node`.

- [ ] **Step 2: Run Windows tests and confirm the expected failure**

```powershell
powershell -NoProfile -File windows/tests/run-tests.ps1
```

Expected: FAIL because `fetch-node-runtime.ps1` and explicit `-NodePath` do not exist.

- [ ] **Step 3: Add the pinned runtime manifest**

Use these exact values:

```json
{
  "schemaVersion": 1,
  "version": "22.23.1",
  "minimumMajor": 22,
  "archives": {
    "x64": {
      "file": "node-v22.23.1-win-x64.zip",
      "url": "https://nodejs.org/dist/v22.23.1/node-v22.23.1-win-x64.zip",
      "sha256": "7df0bc9375723f4a86b3aa1b7cc73342423d9677a8df4538aca31a049e309c29"
    },
    "arm64": {
      "file": "node-v22.23.1-win-arm64.zip",
      "url": "https://nodejs.org/dist/v22.23.1/node-v22.23.1-win-arm64.zip",
      "sha256": "b470fdfe3502c05151656e06d495e3f47544f2ee8b1d9c8705090f2dd5996bd0"
    }
  }
}
```

- [ ] **Step 4: Implement verified fetch and explicit runtime selection**

`fetch-node-runtime.ps1` accepts `-Architecture x64|arm64`, `-Destination`, optional `-ManifestPath`, and optional `-ArchivePath` for offline/release tests. Download or read the archive, compare `Get-FileHash -Algorithm SHA256`, expand to a temp directory, copy only `node.exe` and the complete Node LICENSE, add `NOTICE.node.txt`, run `node.exe -p process.versions.node`, then atomically publish.

Change the existing function signature to:

```powershell
function Get-DreamSkinNodeRuntime {
  param([int]$MinimumMajor = 22, [string]$NodePath)
  if ($NodePath) {
    $runtimePath = [System.IO.Path]::GetFullPath($NodePath)
    if (-not (Test-Path -LiteralPath $runtimePath -PathType Leaf)) { throw 'The private Node.js runtime is missing.' }
  } else {
    $command = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $command) { $command = Get-Command node -ErrorAction SilentlyContinue }
    if (-not $command) { throw "Node.js $MinimumMajor or newer is required and was not found in PATH." }
    $runtimePath = $command.Source
  }
  $version = "$(& $runtimePath -p 'process.versions.node' 2>$null)".Trim()
  $realPath = "$(& $runtimePath -p 'process.execPath' 2>$null)".Trim()
  $major = 0
  if (-not [int]::TryParse(($version -split '\.')[0], [ref]$major) -or $major -lt $MinimumMajor) { throw 'The Node.js runtime version is invalid.' }
  if (-not (Test-DreamSkinPathEqual -Left $runtimePath -Right $realPath)) { throw 'The Node.js executable path could not be validated.' }
  return [pscustomobject]@{ Path = $realPath; Version = $version; Major = $major }
}
```

- [ ] **Step 5: Run tests and fetch the real x64 runtime on Windows**

```powershell
powershell -NoProfile -File windows/tests/run-tests.ps1
powershell -NoProfile -File windows/scripts/fetch-node-runtime.ps1 -Architecture x64 -Destination windows/runtime/x64
```

Expected: existing suite PASS and fetch prints `PASS: Node.js 22.23.1 win-x64 verified.`

- [ ] **Step 6: Commit runtime acquisition code, not binaries**

```bash
git add windows/build windows/scripts/fetch-node-runtime.ps1 windows/scripts/common-windows.ps1 windows/tests/run-tests.ps1
git commit -m "build(windows): add verified private Node runtime"
```

---

### Task 6: Add Read-Only Windows Studio Status and Adapter

**Files:**
- Create: `windows/scripts/studio-windows.ps1`
- Create: `windows/scripts/status-dream-skin.ps1`
- Create: `windows/scripts/studio-adapter.ps1`
- Create: `windows/tests/studio-protocol.tests.ps1`
- Modify: `windows/tests/run-tests.ps1`

**Interfaces:**
- Consumes: Protocol v1 and existing read-only process/state helpers.
- Produces: `studio-adapter.ps1 -Operation preflight|status [-Deep]`; later WPF and lifecycle tasks use the same entry point.

- [ ] **Step 1: Write failing status purity and envelope tests**

Cover missing Codex, missing config, stopped/running, paused, stale PID, damaged state, operation mutex busy, Chinese theme name, and deep status. Snapshot every file under the temp state root before and after status; lists and hashes must match. Assert stdout is one no-BOM JSON object and does not contain `port`, `pid`, `path`, `cdp`, `powershell`, or a user profile path.

- [ ] **Step 2: Run the focused test and confirm it fails**

```powershell
powershell -NoProfile -File windows/tests/studio-protocol.tests.ps1
```

Expected: FAIL because `status-dream-skin.ps1` does not exist.

- [ ] **Step 3: Implement reusable envelope/status helpers**

In `studio-windows.ps1`, expose only:

```powershell
function New-DreamSkinStudioState { param([string]$Install, [string]$Codex, [string]$Session, [string]$Operation = 'idle', [AllowNull()][string]$ThemeName, [bool]$RequiresRestart = $false, [AllowNull()][Nullable[bool]]$Verified, [string[]]$AvailableActions = @()) }
function Write-DreamSkinStudioEnvelope { param([string]$Operation, [bool]$Ok, [object]$State, [AllowNull()][object]$Error) }
function Get-DreamSkinStudioStatus { param([switch]$Deep) }
```

`Write-DreamSkinStudioEnvelope` uses `ConvertTo-Json -Compress -Depth 8` and `[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)`. `Get-DreamSkinStudioStatus` reports `install: ready` only when the adapter's fixed version root contains `VERSION` `1.3.0`, `engine\runtime\node.exe`, readable adapter/start/restore files, `%LOCALAPPDATA%\CodexDreamSkin\config.before-dream-skin.toml`, and `%LOCALAPPDATA%\CodexDreamSkin\active-theme\theme.json`. It must not call initialization, state archival, process stop, or config write helpers.

- [ ] **Step 4: Implement status/preflight adapter operations**

Use a ValidateSet for all nine operations but return `INVALID_REQUEST` for the seven lifecycle operations until Task 7. Adapter syntax:

```powershell
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('preflight','install','apply','status','pause','resume','restore','verify','uninstall')]
  [string]$Operation,
  [switch]$RestartAuthorized,
  [switch]$ForceAuthorized,
  [switch]$DeleteUserThemes,
  [switch]$Deep
)
```

Reject `-DeleteUserThemes` unless `-Operation uninstall`; this is an `INVALID_REQUEST` exit `2` and must happen before loading any mutating script.

- [ ] **Step 5: Run focused and existing Windows tests**

```powershell
powershell -NoProfile -File windows/tests/studio-protocol.tests.ps1
powershell -NoProfile -File windows/tests/run-tests.ps1
```

Expected: focused test prints `PASS: Windows Studio status protocol.` and the existing suite prints `PASS: config transactions, restore scoping, state safety, argument quoting, and loopback CDP validation.`

- [ ] **Step 6: Commit Windows read-only status**

```bash
git add windows/scripts/studio-windows.ps1 windows/scripts/status-dream-skin.ps1 windows/scripts/studio-adapter.ps1 windows/tests
git commit -m "feat(windows): add read-only Studio status"
```

---

### Task 7: Wire Authorized Windows Lifecycle Operations

**Files:**
- Create: `windows/scripts/pause-dream-skin.ps1`
- Modify: `windows/scripts/studio-adapter.ps1`
- Modify: `windows/scripts/install-dream-skin.ps1:1-89`
- Modify: `windows/scripts/start-dream-skin.ps1:1-285`
- Modify: `windows/scripts/verify-dream-skin.ps1:1-49`
- Modify: `windows/scripts/restore-dream-skin.ps1:1-183`
- Modify: `windows/tests/studio-protocol.tests.ps1`
- Modify: `windows/tests/run-tests.ps1`

**Interfaces:**
- Consumes: explicit `-NodePath` from Task 5 and adapter/status from Task 6.
- Produces: all nine operations from the versioned per-user engine root, strict verify, immediate pause, two-level restart authorization, uninstall-only theme deletion, and restore-before-uninstall.

- [ ] **Step 1: Add failing operation/authorization tests**

Use sibling script stubs for adapter argv tests and existing fake Store/state fixtures for safety tests. Assert:

```text
install while running and unauthorized -> CODEX_CLOSE_REQUIRED, no writes
install restart-authorized -> normal quit only; timeout -> FORCE_STOP_REQUIRED with no writes
install with both authorization levels -> verified force flag reaches install
apply unauthorized -> RESTART_REQUIRED, state/config/theme hashes unchanged
apply restart-authorized -> normal quit only
normal quit timeout -> FORCE_STOP_REQUIRED, process still alive
apply with both authorizations -> force flag reaches start
pause -> pause marker written after identity validation and live removal verified
resume hot path -> no restart; cold path -> RESTART_REQUIRED
restore failure -> state/backup/engine preserved
restore restart-authorized -> normal quit only; timeout leaves state/backup/config untouched
uninstall failure -> engine/runtime/shortcuts preserved
uninstall default -> themes/images/active-theme preserved
uninstall -DeleteUserThemes -> themes/images/active-theme deleted only after restore succeeds
explicit Node path missing -> RUNTIME_INVALID, no PATH fallback
```

- [ ] **Step 2: Run the focused test and confirm lifecycle failures**

```powershell
powershell -NoProfile -File windows/tests/studio-protocol.tests.ps1
```

Expected: FAIL because lifecycle operations still return `INVALID_REQUEST`.

- [ ] **Step 3: Propagate explicit Node and split restart authorization**

Add `[string]$NodePath` to install, start, pause, and verify; pass it to `Get-DreamSkinNodeRuntime -NodePath $NodePath`. Keep legacy behavior when omitted.

Add `[switch]$CloseRunning` and `[switch]$ForceRestart` to install. A Studio install with a running verified Codex requires `-CloseRunning`; it first attempts `Stop-DreamSkinCodex -AllowForce:$false` and makes no theme/config write until that succeeds. A timeout is mapped to `FORCE_STOP_REQUIRED`; only the second authorized call passes `-ForceRestart`.

Add `[switch]$ForceRestart` to start and change the current forced call to:

```powershell
Stop-DreamSkinCodex -Codex $codexToStop -AllowForce:$ForceRestart
```

The adapter derives `runtime\node.exe` from its fixed versioned engine root and passes it explicitly. It must reject `ForceAuthorized` without `RestartAuthorized`. First authorized call never passes `-ForceRestart`; only the second, separately confirmed call passes it. Apply this same ordering to install, apply/resume, restore, and uninstall; no operation may stop a pre-existing Codex forcibly on its first confirmation.

- [ ] **Step 4: Fix the versioned engine root and add immediate pause**

The signed installer in Task 12 owns deployment. Its executable and engine share `%LOCALAPPDATA%\Programs\CodexDreamSkinStudio\versions\1.3.0`; the WPF executable is at the version root and the adapter is at `engine\scripts\studio-adapter.ps1`. Inside the adapter use only:

```powershell
$EngineRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$PrivateNodePath = Join-Path $EngineRoot 'runtime\node.exe'
```

Never copy or replace the directory from a running adapter. Installer upgrades after this release use a new sibling such as `versions\1.3.1`, so an active `versions\1.3.0` engine is not overwritten; obsolete versions are removed only after their recorded process identities are proven stopped.

`pause-dream-skin.ps1` sets the managed pause marker only after state/identity validation, invokes the injector remove mode against the verified Browser ID when Codex is active, and treats removal verification failure as `LIVE_REMOVE_FAILED`.

- [ ] **Step 5: Complete adapter operation mappings**

Use these exact mappings:

```text
install   -> install-dream-skin.ps1 -NoShortcuts -NodePath $PrivateNodePath
apply     -> start-dream-skin.ps1 -NodePath $PrivateNodePath
pause     -> pause-dream-skin.ps1 -NodePath $PrivateNodePath
resume    -> start-dream-skin.ps1 -NodePath $PrivateNodePath
restore   -> restore-dream-skin.ps1 -RestoreBaseTheme
verify    -> verify-dream-skin.ps1 -NodePath $PrivateNodePath
uninstall -> restore-dream-skin.ps1 -RestoreBaseTheme -Uninstall
```

The table lists base arguments. `RestartAuthorized` adds `-CloseRunning` for install or `-RestartExisting` for apply/resume and authorizes the normal close in restore/uninstall; `ForceAuthorized` additionally adds `-ForceRestart`. Adapter raw output goes only to `%LOCALAPPDATA%\CodexDreamSkin\studio-operation.log`. Restore remains Node-free. On uninstall, the adapter restores and removes legacy shortcuts but leaves its running version directory for Inno Setup; Inno may delete that directory only after the adapter returns success. Without `-DeleteUserThemes`, `%LOCALAPPDATA%\CodexDreamSkin\themes`, `images`, and `active-theme` remain. With it, those three directories are removed as the final action after successful restore.

- [ ] **Step 6: Run focused and full Windows tests**

```powershell
powershell -NoProfile -File windows/tests/studio-protocol.tests.ps1
powershell -NoProfile -File windows/tests/run-tests.ps1
```

Expected: both PASS; existing config, PID identity, Store update, and loopback tests remain green.

- [ ] **Step 7: Commit the Windows lifecycle**

```bash
git add windows/scripts windows/tests
git commit -m "feat(windows): wire Studio lifecycle operations"
```

---

### Task 8: Build the macOS Swift Engine Client and State Model

**Files:**
- Modify: `macos/studio/Package.swift`
- Create: `macos/studio/Sources/DreamSkinStudioCore/EngineProtocol.swift`
- Create: `macos/studio/Sources/DreamSkinStudioCore/EngineClient.swift`
- Create: `macos/studio/Sources/DreamSkinStudioCore/StudioModel.swift`
- Create: `macos/studio/Tests/DreamSkinStudioCoreTests/EngineClientTests.swift`
- Create: `macos/studio/Tests/DreamSkinStudioCoreTests/StudioModelTests.swift`

**Interfaces:**
- Consumes: Task 1 fixtures and Task 3 adapter.
- Produces: a testable async process client and main-actor model used by SwiftUI.

- [ ] **Step 1: Add failing decode, process, and state-transition tests**

Tests must cover success/error fixtures, unknown schema, invalid JSON, nonzero exit without JSON, progress markers, cancellation, busy re-entry, UTF-8 theme name, and exact authorization argv. Use:

```swift
public protocol EngineRunning: Sendable {
    func run(
        _ operation: EngineOperation,
        restartAuthorized: Bool,
        forceAuthorized: Bool,
        deleteUserThemes: Bool,
        onProgress: @escaping @Sendable (EngineProgress) -> Void
    ) async throws -> EngineEnvelope
}
```

- [ ] **Step 2: Run core tests and confirm compilation fails**

```bash
swift test --package-path macos/studio --filter DreamSkinStudioCoreTests
```

Expected: FAIL because `DreamSkinStudioCore` types do not exist.

- [ ] **Step 3: Add exact Codable types**

Define `EngineOperation`, `EngineProgress`, `EngineState`, `EngineError`, and `EngineEnvelope` with the exact Task 1 raw values. Reject `schemaVersion != 1`. `EngineState.verified` is `Bool?`; `themeName` is `String?`.

- [ ] **Step 4: Implement fixed-path asynchronous process execution**

Use `Process` with an injected executable URL, fixed enum operation, and only these optional flags:

```swift
var arguments = [operation.rawValue]
if restartAuthorized { arguments.append("--restart-authorized") }
if forceAuthorized { arguments.append("--force-authorized") }
if deleteUserThemes { arguments.append("--delete-user-themes") }
```

Never invoke a shell or accept a free-form argument. Reject `deleteUserThemes` unless `operation == .uninstall` before launching the process. Parse `DREAM_SKIN_PROGRESS=` stderr lines, decode the single stdout object, and preserve the envelope for exit `1` or `2`; throw only for launch, timeout, cancellation, or malformed protocol.

- [ ] **Step 5: Implement the main-actor state model**

Use this public shape:

```swift
@MainActor
public final class StudioModel: ObservableObject {
    @Published public private(set) var envelope: EngineEnvelope?
    @Published public private(set) var progress: EngineProgress?
    @Published public private(set) var isBusy = false

    public func refresh(_ operation: EngineOperation = .preflight) async
    public func perform(_ operation: EngineOperation, restartAuthorized: Bool = false, forceAuthorized: Bool = false, deleteUserThemes: Bool = false) async
}
```

Reject a second operation while busy. Initial launch calls `refresh(.preflight)`. A successful mutation stores its result and then calls `refresh(.status)`; a domain-error mutation keeps that error envelope visible and does not overwrite it with a status refresh, so `RESTART_REQUIRED` and `FORCE_STOP_REQUIRED` can drive the two confirmation steps.

- [ ] **Step 6: Run tests and commit**

```bash
swift test --package-path macos/studio --filter DreamSkinStudioCoreTests
git add macos/studio
git commit -m "feat(macos): add Studio process client"
```

Expected: targeted tests PASS.

---

### Task 9: Build the Single-Window macOS Studio Application

**Files:**
- Modify: `macos/studio/Package.swift`
- Create: `macos/studio/Sources/CodexDreamSkinStudio/CodexDreamSkinStudioApp.swift`
- Create: `macos/studio/Sources/CodexDreamSkinStudio/ContentView.swift`
- Create: `macos/studio/Sources/CodexDreamSkinStudio/StatusItemController.swift`
- Create: `macos/studio/Resources/Info.plist`
- Modify: `macos/studio/Tests/DreamSkinStudioCoreTests/StudioModelTests.swift`

**Interfaces:**
- Consumes: `StudioModel` from Task 8.
- Produces: a macOS 12 SwiftUI window and AppKit `NSStatusItem` with the complete approved first-run/daily-use flow.

- [ ] **Step 1: Extend model tests for confirmation choreography**

Use fake envelopes to prove: first launch runs preflight; `RESTART_REQUIRED` requests restart confirmation without rerunning automatically; `FORCE_STOP_REQUIRED` requires a second destructive confirmation; cancel makes no adapter call; restore/uninstall are destructive; uninstall defaults `deleteUserThemes` to false and passes true only after the separate checkbox is selected; successful apply displays verified only when `verified == true`.

- [ ] **Step 2: Run the tests and confirm the missing UI state fails**

```bash
swift test --package-path macos/studio --filter StudioModelTests
```

Expected: FAIL for missing confirmation/presentation state.

- [ ] **Step 3: Add the app entry and fixed adapter location**

The app resolves only `Bundle.main.resourceURL/engine/scripts/studio-adapter-macos.sh`. Add a `WindowGroup`; `StatusItemController` owns one `NSStatusItem`, uses the SF Symbol `paintpalette.fill`, and dispatches Show, Apply/Resume, Pause, Restore, and Quit through closures back to the main-actor model. Do not use `MenuBarExtra`, which requires macOS 13 and would violate the macOS 12 floor.

- [ ] **Step 4: Implement the quiet operational screen**

Use native SwiftUI controls with no nested cards. Required symbols: `paintpalette.fill`, `play.fill`, `pause.fill`, `arrow.counterclockwise`, and `wrench.and.screwdriver`. Required visible areas: status/theme, primary action, pause/resume, complete restore, diagnostics. Hide ports/PIDs/CDP/path details. Disable controls while busy and provide accessibility labels for every icon button.

The confirmation sequence passes only the corresponding boolean flags to `StudioModel.perform`; the view never closes Codex itself. The uninstall sheet includes an unchecked “同时删除我的主题” checkbox and explains that this cannot be undone.

- [ ] **Step 5: Build and test the app**

```bash
swift build --package-path macos/studio
swift test --package-path macos/studio
```

Expected: both exit `0` with no test failures.

- [ ] **Step 6: Commit the macOS app**

```bash
git add macos/studio
git commit -m "feat(macos): add Dream Skin Studio app"
```

---

### Task 10: Package, Sign, and Scan the macOS Studio Release

**Files:**
- Create: `studio/assets/README.md`
- Create: `studio/assets/app-icon-source.png`
- Create: `studio/release/check-contents.mjs`
- Create: `studio/release/allowlist-macos.json`
- Create: `studio/release/allowlist-windows.json`
- Create: `macos/scripts/build-studio-release.sh`
- Create: `macos/tests/studio-release.test.sh`
- Modify: `macos/.gitignore`

**Interfaces:**
- Consumes: Swift app/helper, bundled engine, procedural preset, shared protocol.
- Produces: universal signed `.app`, DMG, SHA-256 file, and reusable release content scanner.

- [ ] **Step 1: Write failing release-assembly tests**

Test that an ad-hoc app contains only the Studio executable, native restore helper, selected engine files, Info.plist, app icon, licenses, and protocol fixtures. Reject state, logs, backups, screenshots, `.git`, absolute user paths, and unexpected executables. Assert `lipo -archs` contains both architectures and `codesign --verify --deep --strict` succeeds.

- [ ] **Step 2: Run the release test and confirm it fails**

```bash
macos/tests/studio-release.test.sh
```

Expected: FAIL because `build-studio-release.sh` does not exist.

- [ ] **Step 3: Create the shared icon source from existing MIT art**

```bash
sips -c 1024 1024 macos/presets/preset-midnight-aurora/background.jpg --out studio/assets/app-icon-source.png
```

Record the exact source and procedural/MIT provenance in `studio/assets/README.md`.

- [ ] **Step 4: Implement the release content scanner**

`check-contents.mjs` accepts exactly `--root PATH --allowlist FILE`. The macOS release test invokes:

```bash
"$NODE" studio/release/check-contents.mjs \
  --root macos/release/CodexDreamSkinStudio.app \
  --allowlist studio/release/allowlist-macos.json
```

It recursively rejects symlinks and names matching `state.json`, `auth.json`, `config.toml`, `*.log`, `config.before-*`, `theme-backup.json`, `.git`, customer screenshots, `/Users/[^/]+/`, or `C:\\Users\\[^\\]+\\`. It also rejects executable files not named by the exact release-relative allowlist. The scanner exits nonzero on the first violation and prints `PASS: release contents verified.` on success. `allowlist-macos.json` contains only `Contents/MacOS/CodexDreamSkinStudio` and `Contents/Resources/engine/bin/dream-skin-config-restore`; `allowlist-windows.json` contains only `CodexDreamSkinStudio.exe` and `engine/runtime/node.exe`.

- [ ] **Step 5: Build a universal app and DMG**

The script builds app and helper separately for `arm64-apple-macosx12.0` and `x86_64-apple-macosx12.0`, finds each bin path with `swift build --show-bin-path`, merges with `lipo`, creates the iconset with `sips`/`iconutil`, copies only `assets`, `presets`, runtime `scripts`, LICENSE, NOTICE, VERSION, protocol fixtures, and helper into `Contents/Resources/engine`, then signs helper before app. The DMG root contains only the `.app` and an `/Applications` symlink.

Support exactly `--adhoc` and `--notarize`. `--adhoc` uses identity `-`; `--notarize` requires `CODE_SIGN_IDENTITY` and `NOTARYTOOL_PROFILE`, enables hardened runtime, submits with `xcrun notarytool --wait`, staples and validates both app and DMG, runs `spctl --assess --type execute` on the app, and writes `SHA256SUMS.txt`.

- [ ] **Step 6: Run ad-hoc release checks**

```bash
macos/scripts/build-studio-release.sh --adhoc
macos/tests/studio-release.test.sh
```

Expected: universal app and DMG exist, scanner passes, `codesign --verify` exits `0`.

- [ ] **Step 7: Commit macOS release tooling**

```bash
git add studio/assets studio/release macos/scripts/build-studio-release.sh macos/tests/studio-release.test.sh macos/.gitignore
git commit -m "build(macos): package signed Studio app"
```

---

### Task 11: Build the Windows WPF Studio and Dependency-Free Self-Check

**Files:**
- Create: `windows/studio/CodexDreamSkinStudio.csproj`
- Create: `windows/studio/App.xaml`
- Create: `windows/studio/App.xaml.cs`
- Create: `windows/studio/Properties/AssemblyInfo.cs`
- Create: `windows/studio/EngineProtocol.cs`
- Create: `windows/studio/EngineClient.cs`
- Create: `windows/studio/MainWindow.xaml`
- Create: `windows/studio/MainWindow.xaml.cs`
- Create: `windows/studio-tests/CodexDreamSkinStudio.Tests.csproj`
- Create: `windows/studio-tests/Program.cs`

**Interfaces:**
- Consumes: shared fixtures and Task 7 adapter.
- Produces: .NET 8 self-contained WPF application with single-instance window/tray behavior and no third-party runtime packages.

- [ ] **Step 1: Create the failing console self-check**

The console project references the WPF project and asserts fixture deserialization, schema rejection, invalid JSON, operation-to-lowercase mapping, exact authorization argv, uninstall-only theme deletion, progress parsing, busy-operation rejection, and UTF-8 theme names. It prints only `PASS: Dream Skin Studio engine client.` when all assertions pass.

- [ ] **Step 2: Run it and confirm compilation fails**

```powershell
dotnet run --project windows/studio-tests/CodexDreamSkinStudio.Tests.csproj -c Release
```

Expected: build failure because the WPF project and `EngineClient` do not exist.

- [ ] **Step 3: Add the minimal WPF projects and protocol types**

Use `net8.0-windows10.0.17763.0`, `UseWPF=true`, `UseWindowsForms=true`, nullable enabled, implicit usings enabled, and no NuGet package references. Define:

```csharp
internal enum EngineOperation { Preflight, Install, Apply, Status, Pause, Resume, Restore, Verify, Uninstall }
internal enum EngineProgress { Checking, Preparing, Installing, Launching, Connecting, Applying, Verifying, Pausing, Restoring, Uninstalling }
internal sealed record EngineState(string Install, string Codex, string Session, string Operation, string? ThemeName, bool RequiresRestart, string[] AvailableActions, bool? Verified);
internal sealed record EngineError(string Code, string Message, string[] RecoveryActions);
internal sealed record EngineEnvelope(int SchemaVersion, bool Ok, string Operation, EngineState State, EngineError? Error);
```

Set the console project's assembly name to `CodexDreamSkinStudio.Tests` and add `[assembly: InternalsVisibleTo("CodexDreamSkinStudio.Tests")]` in `Properties/AssemblyInfo.cs`, so the dependency-free self-check can exercise the internal protocol client. Deserialize with one shared `JsonSerializerOptions { PropertyNameCaseInsensitive = true }` and reject any envelope whose `SchemaVersion` is not `1`.

- [ ] **Step 4: Implement the fixed PowerShell process client**

Use this exact `EngineClient.RunAsync` signature:

```csharp
internal Task<EngineEnvelope> RunAsync(
    EngineOperation operation,
    bool restartAuthorized = false,
    bool forceAuthorized = false,
    bool deleteUserThemes = false,
    bool deep = true,
    IProgress<EngineProgress>? progress = null,
    CancellationToken cancellationToken = default);
```

It invokes only `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`. The adapter path is exactly `Path.Combine(AppContext.BaseDirectory, "engine", "scripts", "studio-adapter.ps1")`; arguments start with `-NoProfile -NonInteractive -ExecutionPolicy Bypass -File adapterPath -Operation operation.ToString().ToLowerInvariant()`. It may then add only `-RestartAuthorized`, `-ForceAuthorized`, uninstall-only `-DeleteUserThemes`, and `-Deep`; reject theme deletion for every other operation before launch. It parses fixed stderr progress markers, requires one stdout JSON object, accepts domain envelopes at exit `1/2`, and throws on malformed protocol or process failure.

- [ ] **Step 5: Implement the single operational window and tray**

Use code-behind, not an MVVM/DI framework. On launch run preflight. Show status/theme, primary install/apply/resume, pause, complete restore, diagnostics folder, and uninstall. Use two separate confirmations for restart and force stop. The uninstall dialog has an unchecked “同时删除我的主题” checkbox and forwards its value only to uninstall. Add a single per-user mutex, `NotifyIcon`, Show, Apply/Resume, Pause, Restore, and Exit menu actions. Disable every mutating control while an operation is active. Show “已验证” only for `Verified == true`.

- [ ] **Step 6: Run self-check and publish tests**

```powershell
dotnet run --project windows/studio-tests/CodexDreamSkinStudio.Tests.csproj -c Release
dotnet publish windows/studio/CodexDreamSkinStudio.csproj -c Release -r win-x64 --self-contained true
```

Expected: self-check PASS and publish reports `Build succeeded` with zero errors.

- [ ] **Step 7: Commit the Windows app**

```bash
git add windows/studio windows/studio-tests
git commit -m "feat(windows): add Dream Skin Studio app"
```

---

### Task 12: Build the Signed Windows per-User Installer

**Files:**
- Create: `windows/VERSION`
- Create: `windows/LICENSE`
- Create: `windows/NOTICE.md`
- Create: `windows/build/dream-skin-studio.iss`
- Create: `windows/scripts/build-studio-release.ps1`
- Modify: `windows/studio/App.xaml.cs`
- Create: `windows/tests/studio-release.tests.ps1`

**Interfaces:**
- Consumes: WPF publish, private Node, engine files, icon source, shared release scanner.
- Produces: signed x64/arm64 per-user setup executables, SHA-256 files, and restore-before-uninstall behavior.

- [ ] **Step 1: Write failing staging and uninstall-guard tests**

Assert `PrivilegesRequired=lowest`, fixed AppId, exact `versions\1.3.0` LocalAppData install path, no administrator request, and `InitializeUninstall()` calling the installed Studio with `--prepare-uninstall`. Stub that command to return nonzero and assert uninstall is cancelled with every installed file preserved; return zero and assert deletion proceeds while `%LOCALAPPDATA%\CodexDreamSkin\themes` remains. Scan staged and extracted installer contents with the shared scanner.

- [ ] **Step 2: Run the focused release test and confirm it fails**

```powershell
powershell -NoProfile -File windows/tests/studio-release.tests.ps1
```

Expected: FAIL because the Inno script and release builder do not exist.

- [ ] **Step 3: Add per-user Inno Setup configuration**

Use AppId `com.feiaway.codex-dream-skin-studio`, `PrivilegesRequired=lowest`, and `%LOCALAPPDATA%\Programs\CodexDreamSkinStudio\versions\{#AppVersion}`; for this plan `{#AppVersion}` resolves to `1.3.0`. Put the self-contained WPF publish at the version root. Put platform `scripts`, `assets`, private `runtime\node.exe`, Node/software licenses, protocol fixtures, and version under its `engine\` child so Task 11's fixed adapter path resolves. Start Menu points to the versioned executable and the finish page launches it with a normal `postinstall` checkbox. Do not delete user themes.

An upgrade installs a new version sibling before changing shortcuts or uninstall registration, never overwrites an active older engine, and keeps the prior directory if setup fails. Cleanup may remove an older sibling only after its saved injector path/PID/start-time identity is proven stopped; an unverifiable old directory is preserved for diagnostics.

`InitializeUninstall()` launches `CodexDreamSkinStudio.exe --prepare-uninstall`, waits, and returns false on cancellation or restore failure. `--prepare-uninstall` uses the normal WPF confirmation choreography and exits `0` only after adapter `uninstall` succeeds.

- [ ] **Step 4: Implement the release builder**

Accept `-Architecture x64|arm64`, `-SkipSign`, and `-SkipTests`. Fetch the matching pinned Node runtime, run PowerShell and console self-checks, self-contained publish, stage the exact version-root/`engine` layout, generate `.ico` from `studio/assets/app-icon-source.png`, sign the WPF executable, invoke Inno Setup 6, sign setup, verify Authenticode, and write SHA-256. Before Inno, scan with:

```powershell
& $PrivateNodePath studio/release/check-contents.mjs `
  --root $StageRoot `
  --allowlist studio/release/allowlist-windows.json
if ($LASTEXITCODE -ne 0) { throw 'Release content scan failed.' }
```

Formal signing requires `WINDOWS_SIGN_CERT_THUMBPRINT`; `-SkipSign` is development-only and the script labels its output `UNSIGNED`.

- [ ] **Step 5: Build and inspect an unsigned development installer**

```powershell
powershell -NoProfile -File windows/scripts/build-studio-release.ps1 -Architecture x64 -SkipSign
powershell -NoProfile -File windows/tests/studio-release.tests.ps1
```

Expected: unsigned setup, manifest, and SHA-256 exist; scanner/test pass.

- [ ] **Step 6: Verify a formal signed build on Windows**

```powershell
powershell -NoProfile -File windows/scripts/build-studio-release.ps1 -Architecture x64
signtool verify /pa /all windows/release/CodexDreamSkinStudio-1.3.0-win-x64.exe
```

Expected: signature verification succeeds and `Get-AuthenticodeSignature` reports `Valid` for the app and installer.

- [ ] **Step 7: Commit Windows release tooling**

```bash
git add windows/VERSION windows/LICENSE windows/NOTICE.md windows/build windows/scripts/build-studio-release.ps1 windows/studio/App.xaml.cs windows/tests/studio-release.tests.ps1
git commit -m "build(windows): package signed Studio installer"
```

---

### Task 13: Unify Versions, Documentation, Full-Chain Tests, and Acceptance

**Files:**
- Modify: `macos/VERSION`
- Modify: `macos/package.json`
- Modify: `macos/scripts/common-macos.sh`
- Modify: `macos/scripts/injector.mjs`
- Modify: `macos/scripts/build-client-release.sh`
- Modify: `macos/tests/run-tests.sh`
- Modify: `macos/references/qa-inventory.md`
- Modify: `windows/VERSION`
- Modify: `windows/scripts/injector.mjs`
- Modify: `windows/assets/renderer-inject.js`
- Modify: `windows/tests/run-tests.ps1`
- Modify: `windows/references/qa-inventory.md`
- Modify: `README.md`, `README.en.md`, `macos/README.md`, `windows/SKILL.md`, `docs/platforms.md`
- Modify: `macos/references/runtime-notes.md`, `windows/references/runtime-notes.md`
- Modify: `macos/CHANGELOG.md`, `windows/CHANGELOG.md`
- Modify: `.github/pull_request_template.md`
- Create after actual execution: `macos/references/studio-acceptance-2026-07-18.md`
- Create after actual execution: `windows/references/studio-acceptance-2026-07-18.md`

**Interfaces:**
- Consumes: all prior tasks.
- Produces: release `1.3.0`, updated user guidance, full install/apply/status/pause/resume/verify/restore/uninstall checks, and truthful acceptance evidence.

- [ ] **Step 1: Add failing version and full-chain static checks**

Assert macOS and Windows `VERSION` are `1.3.0`, macOS package version matches, injectors/renderers report the same value, client release text reads VERSION instead of a literal, adapters expose all nine operations, release scanners run, and README quick starts lead with the signed Studio artifacts rather than shell commands.

- [ ] **Step 2: Run platform tests and confirm version/document failures**

```bash
cd macos && npm test
```

```powershell
powershell -NoProfile -File windows/tests/run-tests.ps1
```

Expected: FAIL on the old `1.2.0` literals and missing Studio documentation.

- [ ] **Step 3: Make platform VERSION files authoritative**

Set both to `1.3.0`. Load the value from each platform VERSION in common/injector/build code; replace hard-coded renderer versions with generated payload values or a build-time token. Update tests so future drift fails. Keep `macos/package.json` synchronized.

- [ ] **Step 4: Update all user and maintainer documentation**

Quick start order becomes: download signed Studio, open it, finish preflight, authorize one restart, wait for verified success, use Pause for soft-off, use Complete Restore to close CDP. Document that macOS no longer needs SwiftBar and Windows no longer needs user-installed Node/PowerShell commands. Keep legacy CLI in an “advanced recovery” section. State explicitly that milestone 1 does not yet include theme package sharing or workspace scenes.

- [ ] **Step 5: Run complete automated gates**

```bash
NODE=/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node
"$NODE" studio/protocol/validate-fixtures.mjs
cd macos && npm test
swift test --package-path studio
./scripts/build-studio-release.sh --adhoc
./tests/studio-release.test.sh
```

```powershell
powershell -NoProfile -File windows/tests/run-tests.ps1
powershell -NoProfile -File windows/tests/studio-protocol.tests.ps1
dotnet run --project windows/studio-tests/CodexDreamSkinStudio.Tests.csproj -c Release
powershell -NoProfile -File windows/scripts/build-studio-release.ps1 -Architecture x64 -SkipSign
powershell -NoProfile -File windows/tests/studio-release.tests.ps1
```

Expected: every command exits `0`; the shared validator prints `PASS: Studio protocol fixtures v1.`; the macOS shell suite prints its full syntax/payload/config/doctor PASS line; Swift reports zero failures; the Windows shell suite prints `PASS: config transactions, restore scoping, state safety, argument quoting, and loopback CDP validation.`; the C# self-check prints `PASS: Dream Skin Studio engine client.`; both release tests print their platform Studio release PASS line.

- [ ] **Step 6: Execute clean-VM and real-Codex acceptance before creating reports**

On each platform execute, in order:

```text
preflight -> install -> apply -> status -> pause -> resume -> verify -> restore -> reinstall/apply -> uninstall
```

Cover: Codex absent; first run missing; Codex open; cancel restart; normal quit timeout and separate force authorization; occupied port; stale/foreign PID; Chinese user and project names; paths with spaces; Codex update; no Node on Windows; invalid/missing Codex Node on macOS restore; uninstall preserves themes by default and deletes them only with explicit opt-in; installer signature/Gatekeeper/SmartScreen; real home and task routes; sidebar/project selector/composer/menu interaction; restore closes CDP and leaves official files/signatures unchanged.

Only after these checks actually pass, create the two acceptance records with OS build, Codex version, Studio version, exact commands/results, verify `pass: true`, screenshots paths, signature results, and any platform-only blocker. Do not create a report that claims an unrun result.

- [ ] **Step 7: Commit release documentation and evidence**

```bash
git add README.md README.en.md docs/platforms.md macos windows .github/pull_request_template.md
git commit -m "docs(release): ship one-click Studio 1.3.0"
```

---

## Plan Completion Check

Before declaring milestone 1 complete, verify every item below:

- [ ] No user-facing path requires Terminal, PowerShell entry, PATH Node, SwiftBar, Homebrew, administrator, or sudo.
- [ ] Both adapters pass Protocol v1 parity and privacy tests.
- [ ] Unauthorized close/restart/force-stop paths are byte-for-byte side-effect free.
- [ ] Apply/resume success always has strict `verified: true`.
- [ ] Pause verifies live removal; Restore closes CDP; Uninstall first completes Restore, preserves themes by default, and deletes them only after separate opt-in.
- [ ] macOS complete restore passes with Codex Node missing/invalid.
- [ ] Windows install/apply/verify passes on a clean machine with no PATH Node.
- [ ] macOS app/DMG and Windows app/setup signatures validate on clean machines.
- [ ] Release scans contain no state, config, backups, logs, screenshots, credentials, absolute user paths, or undeclared executables.
- [ ] Existing macOS/Windows engine suites and real home/task interaction checks pass.
- [ ] Theme packaging, workspace binding, context profiles, and motion remain absent; they get separate plans after this milestone.
