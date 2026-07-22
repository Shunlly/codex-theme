# Automatic Default Theme Apply Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the installed Studio automatically install and apply its existing default theme on first launch, with one existing Codex restart confirmation when required.

**Architecture:** Keep all lifecycle mutations in the existing platform adapters. Add only orchestration in the macOS model and Windows window controller: preflight selects an automatic install or apply action, successful install immediately hands off to apply, and paused/active states remain unchanged. Windows Inno Setup launches Studio by default after an interactive install.

**Tech Stack:** Swift 6/SwiftUI, .NET 8/WPF, Inno Setup 6, PowerShell 5.1, Node.js contract tests, shell release tests.

## Global Constraints

- Do not modify official Codex `.app`, `app.asar`, WindowsApps, signatures, authentication, API keys, or Base URLs.
- Keep CDP loopback-only and reuse all existing identity, restart authorization, strict verify, rollback, Pause, Restore, and Uninstall paths.
- Use existing `preset-midnight-aurora` on macOS and `preset-romantic-rose` on Windows.
- Never auto-resume a paused theme or silently force-stop Codex.
- Add no dependency, login item, background service, state database, or new engine operation.
- Interactive Windows install launches Studio by default; silent install remains non-launching through `skipifsilent`.
- Release version becomes `1.3.1` on both platforms.

---

### Task 1: macOS automatic install and apply

**Files:**
- Modify: `macos/studio/Tests/DreamSkinStudioCoreTests/StudioModelTests.swift:382-476`
- Modify: `macos/studio/Sources/DreamSkinStudioCore/StudioModel.swift:109-208`

**Interfaces:**
- Consumes: existing `StudioModel.launch()`, `perform`, `canRequest`, `EngineOperation.install`, and `EngineOperation.apply`.
- Produces: `launch()` automatically runs install/apply when allowed; every successful install follows with apply after a verified status refresh.

- [ ] **Step 1: Write failing automatic-flow tests**

Replace the preflight-only launch test with a clean-start sequence and add ready,
paused, active, and install-failure cases:

```swift
#if !canImport(XCTest)
@Test
#endif
@MainActor
func testLaunchInstallsAndAppliesDefaultThemeOnlyOnce() async {
    let preflight = makeEnvelope(operation: .preflight, install: "not-installed", session: "official", verified: nil, availableActions: ["install"])
    let installed = makeEnvelope(operation: .install, session: "official", verified: nil)
    let ready = makeEnvelope(operation: .status, session: "official", verified: nil, availableActions: ["apply"])
    let applied = makeEnvelope(operation: .apply)
    let verified = makeEnvelope(operation: .status)
    let engine = ScriptedEngine([.envelope(preflight), .envelope(installed), .envelope(ready), .envelope(applied), .envelope(verified)])
    let model = StudioModel(engine: engine)

    await model.launch()
    await model.launch()

    XCTAssertEqual(await engine.recordedCalls(), [call(.preflight), call(.install), call(.status), call(.apply), call(.status)])
    XCTAssertTrue(model.isVerified)
}

#if !canImport(XCTest)
@Test
#endif
@MainActor
func testLaunchAppliesReadyThemeButSkipsPausedAndActiveSessions() async {
    let readyEngine = ScriptedEngine([
        .envelope(makeEnvelope(operation: .preflight, session: "official", verified: nil, availableActions: ["apply"])),
        .envelope(makeEnvelope(operation: .apply)),
        .envelope(makeEnvelope(operation: .status)),
    ])
    let readyModel = StudioModel(engine: readyEngine)
    await readyModel.launch()
    XCTAssertEqual(await readyEngine.recordedCalls(), [call(.preflight), call(.apply), call(.status)])

    let pausedEngine = ScriptedEngine([.envelope(makeEnvelope(operation: .preflight, session: "paused", verified: false, availableActions: ["apply", "resume"]))])
    let pausedModel = StudioModel(engine: pausedEngine)
    await pausedModel.launch()
    XCTAssertEqual(await pausedEngine.recordedCalls(), [call(.preflight)])

    let activeEngine = ScriptedEngine([.envelope(makeEnvelope(
        operation: .preflight,
        session: "active",
        verified: true,
        availableActions: ["apply", "pause", "verify", "restore"]
    ))])
    let activeModel = StudioModel(engine: activeEngine)
    await activeModel.launch()
    XCTAssertEqual(await activeEngine.recordedCalls(), [call(.preflight)])
}

#if !canImport(XCTest)
@Test
#endif
@MainActor
func testFailedAutomaticInstallDoesNotApply() async {
    let preflight = makeEnvelope(
        operation: .preflight,
        install: "not-installed",
        session: "official",
        verified: nil,
        availableActions: ["install"]
    )
    let failed = makeEnvelope(
        operation: .install,
        ok: false,
        install: "not-installed",
        session: "official",
        verified: nil,
        errorCode: "OPERATION_FAILED",
        availableActions: ["install"]
    )
    let engine = ScriptedEngine([.envelope(preflight), .envelope(failed)])
    let model = StudioModel(engine: engine)

    await model.launch()

    XCTAssertEqual(await engine.recordedCalls(), [call(.preflight), call(.install)])
    XCTAssertFalse(model.isVerified)
}
```

Replace `testInstallCloseRequirementUsesRestartConfirmation` with this exact
sequence so authorization remains scoped to Install and is not carried into Apply:

```swift
#if !canImport(XCTest)
@Test
#endif
@MainActor
func testInstallCloseRequirementUsesRestartConfirmation() async {
    let ready = makeEnvelope(
        operation: .status,
        install: "not-installed",
        session: "official",
        availableActions: ["install"]
    )
    let closeRequired = makeEnvelope(
        operation: .install,
        ok: false,
        session: "official",
        errorCode: "CODEX_CLOSE_REQUIRED",
        recoveryActions: ["authorize-restart", "cancel"]
    )
    let installed = makeEnvelope(operation: .install, session: "official", verified: nil)
    let installedStatus = makeEnvelope(
        operation: .status,
        session: "official",
        verified: nil,
        availableActions: ["apply"]
    )
    let applied = makeEnvelope(operation: .apply)
    let verified = makeEnvelope(operation: .status)
    let engine = ScriptedEngine([
        .envelope(ready),
        .envelope(closeRequired),
        .envelope(installed),
        .envelope(installedStatus),
        .envelope(applied),
        .envelope(verified),
    ])
    let model = StudioModel(engine: engine)

    await model.refresh(.status)
    await model.request(.install)

    XCTAssertEqual(await engine.recordedCalls(), [call(.status), call(.install)])
    XCTAssertEqual(model.presentation, .restartConfirmation(.install, deleteUserThemes: false))

    await model.confirmPresentation()

    XCTAssertEqual(await engine.recordedCalls(), [
        call(.status),
        call(.install),
        call(.install, restart: true),
        call(.status),
        call(.apply),
        call(.status),
    ])
    XCTAssertTrue(model.isVerified)
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --package-path macos/studio --filter StudioModelTests
```

Expected: launch tests fail because calls stop after preflight, and the install-confirmation test stops after install/status.

- [ ] **Step 3: Implement the minimal model orchestration**

Change launch to choose only install or apply:

```swift
public func launch() async {
    guard !hasLaunched else { return }
    hasLaunched = true
    await refresh(.preflight)
    guard envelope?.state.session == .official else { return }
    if canRequest(.install) {
        await perform(.install)
    } else if canRequest(.apply) {
        await perform(.apply)
    }
}
```

Refactor the current body of `perform` into a private `performActive(...) async -> Bool`. `perform` owns `beginOperation/endOperation`; after a successful install and status refresh it starts a normal apply only when `canRequest(.apply)` is true:

```swift
public func perform(
    _ operation: EngineOperation,
    restartAuthorized: Bool = false,
    forceAuthorized: Bool = false,
    deleteUserThemes: Bool = false
) async {
    guard beginOperation() else { return }
    let succeeded = await performActive(
        operation,
        restartAuthorized: restartAuthorized,
        forceAuthorized: forceAuthorized,
        deleteUserThemes: deleteUserThemes
    )
    endOperation()
    if succeeded, operation == .install, canRequest(.apply) {
        await perform(.apply)
    }
}
```

Move the existing mutation/status body into this helper. A failed status refresh
returns `false`, which prevents Install from advancing to Apply:

```swift
private func performActive(
    _ operation: EngineOperation,
    restartAuthorized: Bool,
    forceAuthorized: Bool,
    deleteUserThemes: Bool
) async -> Bool {
    let mutation: EngineEnvelope
    do {
        mutation = try await invoke(
            operation,
            restartAuthorized: restartAuthorized,
            forceAuthorized: forceAuthorized,
            deleteUserThemes: deleteUserThemes
        )
        envelope = mutation
    } catch {
        let clientError = normalized(error)
        self.clientError = clientError
        if clientError.isInterruption {
            await reconcileStatus(preserving: clientError)
        }
        return false
    }

    guard mutation.ok else {
        presentRecovery(for: mutation, operation: operation, deleteUserThemes: deleteUserThemes)
        return false
    }
    guard operation != .preflight, operation != .status else { return true }
    do {
        envelope = try await invoke(.status)
        return true
    } catch {
        let clientError = normalized(error)
        self.clientError = clientError
        if clientError.isInterruption {
            await reconcileStatus(preserving: clientError)
        }
        return false
    }
}
```

Do not pass Install's restart or force authorization to the follow-up Apply.

- [ ] **Step 4: Run focused and full macOS Studio tests**

Run:

```bash
swift test --package-path macos/studio --filter StudioModelTests
swift test --package-path macos/studio
```

Expected: all 87 or more tests pass; automatic sequences match exactly; paused remains preflight-only.

- [ ] **Step 5: Commit macOS behavior**

```bash
git add macos/studio/Sources/DreamSkinStudioCore/StudioModel.swift macos/studio/Tests/DreamSkinStudioCoreTests/StudioModelTests.swift
git commit -m "feat(macos): auto-apply default theme on launch"
```

---

### Task 2: Windows automatic install and apply

**Files:**
- Modify: `windows/studio/MainWindow.xaml.cs:50-87,142-199,404`
- Modify: `windows/studio-tests/Program.cs:218-231`
- Modify: `windows/tests/studio-release-contract.test.mjs:1019-1026`

**Interfaces:**
- Consumes: existing `PrimaryOperation()`, `DispatchAsync`, `EngineEnvelope.State.Session`, and `AvailableActions`.
- Produces: `AutomaticOperation(string? session, IReadOnlyCollection<string> actions) -> EngineOperation?` and `DispatchWithInstallFollowUpAsync(EngineOperation operation) -> Task<bool>`.

- [ ] **Step 1: Write failing Windows policy and wiring tests**

Add console assertions:

```csharp
Assert(MainWindow.AutomaticOperation("official", new[] { "install" }) == EngineOperation.Install,
  "Clean startup did not select Install.");
Assert(MainWindow.AutomaticOperation("official", new[] { "apply" }) == EngineOperation.Apply,
  "Ready startup did not select Apply.");
Assert(MainWindow.AutomaticOperation("paused", new[] { "apply", "resume" }) is null,
  "Paused startup resumed automatically.");
Assert(MainWindow.AutomaticOperation("active", new[] { "apply", "pause", "restore" }) is null,
  "Active startup reapplied unnecessarily.");
```

Add these portable source contracts next to the existing Windows UI wiring checks:

```js
for (const contract of [
  "AutomaticOperation(string? session, IReadOnlyCollection<string> actions)",
  'session is "paused" or "active"',
  "DispatchWithInstallFollowUpAsync(EngineOperation operation)",
]) contains(window, contract, `automatic default-theme orchestration missing: ${contract}`);

const initializeStart = window.indexOf("private async Task InitializeAsync()");
const initializeEnd = window.indexOf("private Forms.NotifyIcon CreateTray()", initializeStart);
const initialize = window.slice(initializeStart, initializeEnd);
contains(initialize, "AutomaticOperation(", "startup does not select an automatic operation after preflight");
contains(initialize, "DispatchWithInstallFollowUpAsync(automaticOperation)",
  "startup does not run the selected automatic operation");

const followUpStart = window.indexOf("private async Task<bool> DispatchWithInstallFollowUpAsync");
const followUpEnd = window.indexOf("private async Task<bool> DispatchAsync", followUpStart);
const followUp = window.slice(followUpStart, followUpEnd);
contains(followUp, "if (!await DispatchAsync(operation)) return false;",
  "failed install still advances to Apply");
contains(followUp, "operation == EngineOperation.Install && CanRun(EngineOperation.Apply)",
  "successful install does not gate Apply on refreshed availability");
contains(followUp, "return await DispatchAsync(EngineOperation.Apply);",
  "successful install does not advance through the normal Apply dispatcher");
assert.ok((window.match(/DispatchWithInstallFollowUpAsync\(PrimaryOperation\(\)\)/g) || []).length >= 2,
  "main button and tray primary action do not share install-follow-up dispatch");
```

- [ ] **Step 2: Run Windows tests and verify RED**

Run on the current host:

```bash
node windows/tests/studio-release-contract.test.mjs
```

Expected: FAIL because the automatic selector and shared install-follow-up dispatcher are absent. On Windows, also run `dotnet run --project windows/studio-tests/CodexDreamSkinStudio.Tests.csproj -c Release -r win-x64` and expect compile failure for the missing selector.

- [ ] **Step 3: Implement the shared Windows orchestration**

Add the pure selector:

```csharp
internal static EngineOperation? AutomaticOperation(string? session, IReadOnlyCollection<string> actions)
{
  if (session is "paused" or "active") return null;
  if (actions.Contains("install")) return EngineOperation.Install;
  if (actions.Contains("apply")) return EngineOperation.Apply;
  return null;
}
```

Add a single dispatcher:

```csharp
private async Task<bool> DispatchWithInstallFollowUpAsync(EngineOperation operation)
{
  if (!await DispatchAsync(operation)) return false;
  if (operation == EngineOperation.Install && CanRun(EngineOperation.Apply))
    return await DispatchAsync(EngineOperation.Apply);
  return true;
}
```

After successful preflight, call the selector and dispatch only its Install/Apply
result:

```csharp
if (!await DispatchAsync(EngineOperation.Preflight) || _envelope is null) return;
if (AutomaticOperation(_envelope.State.Session, _envelope.State.AvailableActions)
    is { } automaticOperation)
  await DispatchWithInstallFollowUpAsync(automaticOperation);
```

Change both manual primary entry points to the shared dispatcher:

```csharp
tray.ContextMenuStrip.Items.Add("应用主题", null,
  async (_, _) => await DispatchWithInstallFollowUpAsync(PrimaryOperation())).Name = "primary";

private async void PrimaryButton_Click(object sender, RoutedEventArgs e) =>
  await DispatchWithInstallFollowUpAsync(PrimaryOperation());
```

The paused guard keeps Resume manual; no startup path calls Resume.

- [ ] **Step 4: Run portable and Windows-native tests**

Run:

```bash
node windows/tests/studio-release-contract.test.mjs
node studio/protocol/validate-fixtures.mjs
```

On Windows run:

```powershell
dotnet run --project windows/studio-tests/CodexDreamSkinStudio.Tests.csproj -c Release -r win-x64
powershell -NoProfile -File windows/tests/run-tests.ps1
```

Expected: all checks pass and the console policy assertions cover install, apply, paused, and active states.

- [ ] **Step 5: Commit Windows behavior**

```bash
git add windows/studio/MainWindow.xaml.cs windows/studio-tests/Program.cs windows/tests/studio-release-contract.test.mjs
git commit -m "feat(windows): auto-apply default theme on launch"
```

---

### Task 3: Launch Windows Studio after interactive installation

**Files:**
- Modify: `windows/build/dream-skin-studio.iss:70-71`
- Modify: `windows/tests/studio-release-contract.test.mjs:1048`

**Interfaces:**
- Consumes: Inno Setup `[Run]` postinstall entry.
- Produces: checked-by-default interactive launch while retaining `skipifsilent`.

- [ ] **Step 1: Add a failing installer contract**

Add:

```js
assert.match(inno,
  /Filename:\s*"\{app\}\\CodexDreamSkinStudio\.exe";[^\r\n]*Flags:\s*nowait postinstall skipifsilent\s*$/m,
  "interactive setup does not launch Studio by default");
assert.doesNotMatch(inno, /Flags:[^\r\n]*\bunchecked\b/,
  "Studio launch remains unchecked by default");
```

- [ ] **Step 2: Run the contract and verify RED**

Run `node windows/tests/studio-release-contract.test.mjs`.

Expected: FAIL because the `[Run]` flags still contain `unchecked`.

- [ ] **Step 3: Remove only the unchecked flag**

Use exactly:

```ini
[Run]
Filename: "{app}\CodexDreamSkinStudio.exe"; Description: "Launch Codex Dream Skin Studio"; Flags: nowait postinstall skipifsilent
```

- [ ] **Step 4: Run contract and PowerShell parse checks**

Run:

```bash
node windows/tests/studio-release-contract.test.mjs
pwsh -NoProfile -Command '$errors=@(); [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path "windows/scripts/build-studio-release.ps1"),[ref]$null,[ref]$errors)>$null; if($errors.Count){exit 1}'
```

Expected: PASS.

- [ ] **Step 5: Commit installer behavior**

```bash
git add windows/build/dream-skin-studio.iss windows/tests/studio-release-contract.test.mjs
git commit -m "feat(windows): launch Studio after install"
```

---

### Task 4: Version 1.3.1 and ordinary-user documentation

**Files:**
- Modify: `macos/VERSION`
- Modify: `macos/package.json`
- Modify: `macos/studio/Resources/Info.plist`
- Modify: `macos/scripts/build-studio-release.sh:163`
- Modify: `windows/VERSION`
- Modify: `windows/scripts/build-studio-release.ps1:577`
- Test: `macos/tests/run-tests.sh:19,58-62,1527`
- Test: `macos/tests/lifecycle-v4-behavior.test.sh:389,561,830`
- Test: `macos/tests/studio-adapter.test.sh:822,1933`
- Test: `windows/tests/run-tests.ps1:6,40-43`
- Test: `windows/tests/studio-protocol.tests.ps1:7,455,2085-2115`
- Test: `windows/tests/studio-release-contract.test.mjs:10`
- Modify: `README.md`
- Modify: `README.en.md`
- Modify: `macos/README.md`
- Modify: `windows/SKILL.md`
- Modify: `docs/platforms.md`
- Modify: `macos/references/runtime-notes.md`
- Modify: `windows/references/runtime-notes.md`
- Modify: `macos/references/qa-inventory.md`
- Modify: `windows/references/qa-inventory.md`
- Modify: `macos/CHANGELOG.md`
- Modify: `windows/CHANGELOG.md`

**Interfaces:**
- Consumes: platform VERSION files and existing release-name contracts.
- Produces: synchronized `1.3.1` metadata and accurate automatic-first-launch guidance.

- [ ] **Step 1: Write failing version and documentation contracts**

Change the test-side current version first:

```text
macos/tests/run-tests.sh: EXPECTED_STUDIO_VERSION="1.3.1"
windows/tests/run-tests.ps1: $ExpectedStudioVersion = '1.3.1'
windows/tests/studio-release-contract.test.mjs:
  assert.equal(read("windows/VERSION").trim(), "1.3.1");
```

Update every `1.3.0` current-version fixture in the five remaining test files
listed above to `1.3.1`; in the invalid UTF-8 byte fixture use
`0x31,0x2E,0x33,0x2E,0x31,0xFF`. Preserve the intentional `1.2.9` old-engine
upgrade fixture.

Add these macOS metadata/release-guard assertions to `macos/tests/run-tests.sh`:

```bash
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/studio/Resources/Info.plist")" = "$EXPECTED_STUDIO_VERSION" ] || {
  printf 'macOS Studio Info.plist version must match VERSION.\n' >&2
  exit 1
}
/usr/bin/grep -F -q '[ "$VERSION" = "1.3.1" ]' "$ROOT/scripts/build-studio-release.sh" || {
  printf 'macOS Studio release guard must match VERSION.\n' >&2
  exit 1
}
```

Add the matching Windows builder contract after `builder` is loaded:

```js
contains(builder, "if ($Version -cne '1.3.1')", "Windows release guard does not match VERSION");
```

In the five quick-start contracts, retain the existing trust-boundary terms and
add the automatic-flow term shown here:

```js
const contracts = [
  ["## 快速开始", "### 高级恢复", ["当前仓库不声称已有通过生产信任验收的 Studio 二进制发布", "生产发布完成后", "CodexDreamSkinStudio.dmg", "CodexDreamSkinStudio-1.3.1-win-x64.exe", "preflight", "自动安装并应用内置默认主题", "授权一次", "严格验证", "Pause", "Complete Restore"], ["主题包分享", "工作区场景/绑定", "上下文配置档", "动态/视频"]],
  ["## Quick start", "### Advanced recovery", ["No trusted Studio binary is currently claimed as published or accepted", "After a production release", "CodexDreamSkinStudio.dmg", "CodexDreamSkinStudio-1.3.1-win-x64.exe", "preflight", "automatically installs and applies the bundled default theme", "authorize one", "strict verified success", "Pause", "Complete Restore"], ["theme-package sharing", "workspace scenes/bindings", "context profiles", "motion/video"]],
  ["## Quick start (Studio)", "## Advanced recovery", ["No trusted Studio binary is currently claimed as published or accepted", "Developer ID", "notarization", "CodexDreamSkinStudio.dmg", "preflight", "automatically installs and applies the bundled default theme", "Authorize one", "strict verified success", "Pause", "Complete Restore"], ["theme-package sharing", "workspace scenes/bindings", "context profiles", "motion/video"]],
  ["## Studio 日常路径", "## 高级恢复", ["当前仓库不声称已有通过生产信任验收的 Studio 二进制发布", "生产发布完成后", "CodexDreamSkinStudio.dmg", "CodexDreamSkinStudio-1.3.1-win-x64.exe", "preflight", "自动安装并应用内置默认主题", "授权一次", "严格验证", "Pause", "Complete Restore"], ["主题包分享", "工作区场景/绑定", "上下文配置档", "动态/视频"]],
  ["## Ordinary-user workflow (Studio)", "## Advanced recovery", ["No trusted Studio binary is currently claimed as published or accepted", "Authenticode", "SmartScreen", "CodexDreamSkinStudio-1.3.1-win-x64.exe", "preflight", "automatically installs and applies the bundled default theme", "authorize a single restart", "strict verified success", "Pause", "Complete Restore"], ["theme-package sharing", "workspace scenes/bindings", "context profiles", "motion/video"]],
];
```

Replace the four Windows quick-start assertions with:

```powershell
Assert-StudioQuickStartContract (Join-Path $Root '..\README.md') '## 快速开始' '### 高级恢复' @('当前仓库不声称已有通过生产信任验收的 Studio 二进制发布', '生产发布完成后', 'CodexDreamSkinStudio.dmg', 'CodexDreamSkinStudio-1.3.1-win-x64.exe', 'preflight', '自动安装并应用内置默认主题', '授权一次', '严格验证', 'Pause', 'Complete Restore') @('主题包分享', '工作区场景/绑定', '上下文配置档', '动态/视频')
Assert-StudioQuickStartContract (Join-Path $Root '..\README.en.md') '## Quick start' '### Advanced recovery' @('No trusted Studio binary is currently claimed as published or accepted', 'After a production release', 'CodexDreamSkinStudio.dmg', 'CodexDreamSkinStudio-1.3.1-win-x64.exe', 'preflight', 'automatically installs and applies the bundled default theme', 'authorize one', 'strict verified success', 'Pause', 'Complete Restore') @('theme-package sharing', 'workspace scenes/bindings', 'context profiles', 'motion/video')
Assert-StudioQuickStartContract (Join-Path $Root '..\docs\platforms.md') '## Studio 日常路径' '## 高级恢复' @('当前仓库不声称已有通过生产信任验收的 Studio 二进制发布', '生产发布完成后', 'CodexDreamSkinStudio.dmg', 'CodexDreamSkinStudio-1.3.1-win-x64.exe', 'preflight', '自动安装并应用内置默认主题', '授权一次', '严格验证', 'Pause', 'Complete Restore') @('主题包分享', '工作区场景/绑定', '上下文配置档', '动态/视频')
Assert-StudioQuickStartContract (Join-Path $Root 'SKILL.md') '## Ordinary-user workflow (Studio)' '## Advanced recovery' @('No trusted Studio binary is currently claimed as published or accepted', 'Authenticode', 'SmartScreen', 'CodexDreamSkinStudio-1.3.1-win-x64.exe', 'preflight', 'automatically installs and applies the bundled default theme', 'authorize a single restart', 'strict verified success', 'Pause', 'Complete Restore') @('theme-package sharing', 'workspace scenes/bindings', 'context profiles', 'motion/video')
```

- [ ] **Step 2: Run current tests and verify RED**

Run:

```bash
(cd macos && npm test)
node windows/tests/studio-release-contract.test.mjs
```

Expected: FAIL because production metadata and ordinary-user documentation still
say `1.3.0` and describe a manual preflight flow.

- [ ] **Step 3: Synchronize version metadata**

Set the production version values exactly:

```text
macos/VERSION                                      1.3.1
macos/package.json                                 "version": "1.3.1"
macos/studio/Resources/Info.plist                  CFBundleShortVersionString = 1.3.1
macos/scripts/build-studio-release.sh              [ "$VERSION" = "1.3.1" ]
windows/VERSION                                    1.3.1
windows/scripts/build-studio-release.ps1           if ($Version -cne '1.3.1')
```

Use these ordinary-user flow sentences so the behavior and consent boundary are
unambiguous:

```markdown
<!-- README.md and docs/platforms.md -->
首次打开后，Studio 会完成 preflight，自动安装并应用内置默认主题，然后执行严格验证；仅在 Codex 正在运行且 Studio 明确请求时授权一次重启。

<!-- README.en.md -->
On first launch, Studio runs preflight, automatically installs and applies the bundled default theme, then waits for strict verified success; authorize one Codex restart only when Studio requests it.

<!-- macos/README.md -->
On first launch, Studio runs preflight, automatically installs and applies the bundled default theme (`preset-midnight-aurora`), then waits for strict verified success. Authorize one Codex restart only when Studio requests it.

<!-- windows/SKILL.md -->
On first launch, Studio runs preflight, automatically installs and applies the bundled default theme (`preset-romantic-rose`), then waits for strict verified success; authorize a single restart only when requested.
```

Keep the existing download/install step and Pause/Complete Restore step around
those sentences. Update current artifact names to `1.3.1`, the README tag example
to `v1.3.1-test.1`, and the local ad-hoc DMG example in `docs/platforms.md` to
`CodexDreamSkinStudio-1.3.1-macos-universal-ADHOC.dmg`.

Replace the first runtime-note bullet on both platforms with:

```markdown
- Studio is the ordinary-user entry point for 1.3.1: first launch runs preflight, automatically installs and applies the bundled default theme, preserves explicit restart consent, and requires strict verify. Pause and Complete Restore remain manual controls.
```

Use these QA current-version lines:

```markdown
<!-- macos/references/qa-inventory.md -->
- Version contracts keep `VERSION`, package metadata, injector payload, renderer, client release text, and Studio release metadata at `1.3.1`.
- Live verification after `Page.reload` returns version `1.3.1` and `pass: true`.

<!-- windows/references/qa-inventory.md -->
- Version contracts keep `VERSION`, injector payload, renderer, Studio metadata, and release names at `1.3.1`; Protocol v1 retains all nine operations and release assembly invokes the content scanner.
```

Add changelog entries:

```markdown
## 1.3.1 — 2026-07-22

- Studio automatically installs and applies the bundled default theme on first launch.
- Windows interactive setup launches Studio by default.
- Existing restart consent, Pause, Complete Restore, and uninstall safety remain unchanged.
```

- [ ] **Step 4: Run full portable verification**

Run:

```bash
(cd macos && npm test)
node studio/protocol/validate-fixtures.mjs
node windows/tests/studio-release-contract.test.mjs
pwsh -NoProfile -Command '$allErrors=@(); Get-ChildItem windows -Recurse -Filter *.ps1 | ForEach-Object { $tokens=$null; $parseErrors=$null; [System.Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$parseErrors)>$null; $allErrors += $parseErrors }; if($allErrors.Count){$allErrors | ForEach-Object { Write-Error $_ }; exit 1}'
if rg -n '1\.3\.0' README.md README.en.md docs/platforms.md macos windows --glob '!CHANGELOG.md' --glob '!**/release/**' --glob '!**/.build/**'; then exit 1; fi
git diff --check
```

Expected: all commands exit 0. Historical `1.3.0` changelog sections and old
`docs/superpowers/` design records remain unchanged.

- [ ] **Step 5: Commit release metadata and docs**

```bash
git add README.md README.en.md docs/platforms.md macos windows
git commit -m "docs(release): prepare automatic apply 1.3.1"
```

---

### Task 5: Final review, build, publish, and asset verification

**Files:**
- Verify all files changed by Tasks 1-4.
- Create no new production source file.

**Interfaces:**
- Consumes: release builders and `.github/workflows/test-release.yml`.
- Produces: pushed `dev`, tag `v1.3.1-test.1`, and a GitHub pre-release with DMG/EXE/checksums/manifests.

- [ ] **Step 1: Review requirement coverage and the final diff**

Run:

```bash
PLAN_COMMIT="$(git rev-list --max-count=1 --grep='^docs: plan automatic default theme apply$' HEAD)"
test -n "$PLAN_COMMIT"
git status --short --branch
git diff --check "$PLAN_COMMIT"..HEAD
git diff --exit-code "$PLAN_COMMIT"..HEAD -- \
  macos/scripts/studio-adapter-macos.sh macos/scripts/start-dream-skin-macos.sh \
  macos/scripts/restore-dream-skin-macos.sh macos/scripts/injector.mjs \
  windows/scripts/studio-adapter.ps1 windows/scripts/start-dream-skin.ps1 \
  windows/scripts/restore-dream-skin.ps1 windows/scripts/injector.mjs
rg -n 'preset-midnight-aurora' macos/scripts/install-dream-skin-macos.sh
rg -n 'preset-romantic-rose' windows/scripts/theme-windows.ps1
rg -n 'session is "paused" or "active"|DispatchWithInstallFollowUpAsync' windows/studio/MainWindow.xaml.cs
rg -n 'canRequest\(\.install\)|canRequest\(\.apply\)|operation == \.install' macos/studio/Sources/DreamSkinStudioCore/StudioModel.swift
if rg -n '\bunchecked\b' windows/build/dream-skin-studio.iss; then exit 1; fi
test "$(cat macos/VERSION)" = '1.3.1'
test "$(cat windows/VERSION)" = '1.3.1'
```

Expected: the engine/injection/restore diff is empty; both existing default
preset IDs remain; paused/active guards and install-follow-up dispatch exist;
Inno contains no `unchecked`; both versions are `1.3.1`.

- [ ] **Step 2: Run final local checks**

Run:

```bash
(cd macos && npm test)
swift test --package-path macos/studio
node studio/protocol/validate-fixtures.mjs
node windows/tests/studio-release-contract.test.mjs
while IFS= read -r file; do bash -n "$file"; done < <(rg --files -g '*.sh' -g '*.command' -g '!**/release/**')
while IFS= read -r file; do node --check "$file" >/dev/null; done < <(rg --files -g '*.js' -g '*.mjs' -g '!**/release/**')
pwsh -NoProfile -Command '$allErrors=@(); Get-ChildItem windows -Recurse -Filter *.ps1 | ForEach-Object { $tokens=$null; $parseErrors=$null; [System.Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$parseErrors)>$null; $allErrors += $parseErrors }; if($allErrors.Count){$allErrors | ForEach-Object { Write-Error $_ }; exit 1}'
git diff --check
test -z "$(git status --short)"
```

Expected: every command exits 0 and the worktree is clean. Run the Windows-native
commands from Task 2 on a Windows host when available; do not claim those or live
Codex visual acceptance from a macOS-only run.

- [ ] **Step 3: Push dev and publish the test release**

```bash
TAG='v1.3.1-test.1'
git push -u origin dev
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
  printf 'Remote tag already exists: %s\n' "$TAG" >&2
  exit 1
fi
git tag -a "$TAG" -m "Codex Dream Skin Studio v1.3.1 test 1"
git push origin "$TAG"

RUN_ID=''
for _ in {1..24}; do
  RUN_ID="$(gh run list --workflow test-release.yml --commit "$(git rev-list -n 1 "$TAG")" --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
  [ -z "$RUN_ID" ] || break
  sleep 5
done
test -n "$RUN_ID"
gh run watch "$RUN_ID" --exit-status
gh run view "$RUN_ID" --json status,conclusion,jobs --jq '{status,conclusion,jobs:[.jobs[]|{name,conclusion}]}'
```

Expected: `macos`, `windows-x64`, and `release` all conclude `success`; the
pre-release exists only after both platform builds complete.

- [ ] **Step 4: Download and verify every release asset**

Require exactly:

```text
CodexDreamSkinStudio-1.3.1-macos-universal-ADHOC.dmg
CodexDreamSkinStudio-1.3.1-win-x64-UNSIGNED.exe
SHA256SUMS-macos.txt
SHA256SUMS-windows-x64.txt
release-manifest-macos.json
release-manifest-windows-x64.json
```

Run:

```bash
TAG='v1.3.1-test.1'
ASSET_DIR="$(mktemp -d)"
gh release download "$TAG" --repo Shunlly/codex-theme --dir "$ASSET_DIR"
gh api "repos/Shunlly/codex-theme/releases/tags/$TAG" > "$ASSET_DIR/release.json"

(cd "$ASSET_DIR" && shasum -a 256 -c SHA256SUMS-macos.txt)
(cd "$ASSET_DIR" && shasum -a 256 -c SHA256SUMS-windows-x64.txt)
hdiutil verify "$ASSET_DIR/CodexDreamSkinStudio-1.3.1-macos-universal-ADHOC.dmg"
file "$ASSET_DIR/CodexDreamSkinStudio-1.3.1-win-x64-UNSIGNED.exe" | grep -E 'PE32\+ executable.*x86-64'

node - "$ASSET_DIR" "$(git rev-parse "$TAG^{tree}")" <<'NODE'
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const [root, sourceTree] = process.argv.slice(2);
const sha256 = (file) => crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
const expectedAssets = [
  "CodexDreamSkinStudio-1.3.1-macos-universal-ADHOC.dmg",
  "CodexDreamSkinStudio-1.3.1-win-x64-UNSIGNED.exe",
  "SHA256SUMS-macos.txt",
  "SHA256SUMS-windows-x64.txt",
  "release-manifest-macos.json",
  "release-manifest-windows-x64.json",
];
const release = JSON.parse(fs.readFileSync(path.join(root, "release.json"), "utf8"));
assert.deepEqual(release.assets.map(({ name }) => name).sort(), [...expectedAssets].sort());
for (const { name, digest } of release.assets) {
  const hash = sha256(path.join(root, name));
  assert.equal(digest, `sha256:${hash}`, `GitHub digest mismatch: ${name}`);
}
const mac = JSON.parse(fs.readFileSync(path.join(root, "release-manifest-macos.json"), "utf8"));
assert.equal(mac.version, "1.3.1");
assert.equal(mac.architecture, "universal");
assert.equal(mac.signing, "adhoc");
assert.equal(mac.notarized, false);
assert.equal(mac.stapled, false);
assert.equal(mac.file, expectedAssets[0]);
assert.equal(mac.sha256, sha256(path.join(root, mac.file)));
const windows = JSON.parse(fs.readFileSync(path.join(root, "release-manifest-windows-x64.json"), "utf8"));
assert.equal(windows.version, "1.3.1");
assert.equal(windows.architecture, "x64");
assert.equal(windows.signing, "UNSIGNED");
assert.equal(windows.file, expectedAssets[1]);
assert.equal(windows.sha256, sha256(path.join(root, windows.file)));
assert.equal(windows.sourceTree, sourceTree);
NODE
```

Expected: both checksum checks say `OK`, the DMG verifies, `file` reports an
x86-64 PE32+ executable, GitHub has exactly six assets with matching digests,
and both manifests describe `1.3.1`. Only the Windows manifest currently carries
the exact Git source tree; do not invent that field in the macOS manifest for this
feature.

- [ ] **Step 5: Record the remaining acceptance boundary**

State explicitly that macOS remains ad-hoc/not notarized, Windows remains unsigned x64, Windows arm64 is unavailable, and clean-machine live Codex home/task visual signoff remains required before claiming production trust.
