import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const read = (relative) => fs.readFileSync(path.join(repo, relative), "utf8");
const contains = (text, expected, message) => assert.ok(text.includes(expected), message);

assert.equal(read("windows/VERSION").trim(), "1.3.0");

const inno = read("windows/build/dream-skin-studio.iss");
contains(inno, "AppId=com.feiaway.codex-dream-skin-studio", "fixed AppId missing");
contains(inno, "PrivilegesRequired=lowest", "per-user privilege mode missing");
contains(inno, "DisableDirPage=yes", "fixed install directory is user-editable");
contains(inno, "DefaultDirName={localappdata}\\Programs\\CodexDreamSkinStudio\\versions\\{#AppVersion}", "versioned LocalAppData path missing");
contains(inno, "UsePreviousAppDir=no", "immutable version directory policy missing");
contains(inno, '#elif Architecture == "arm64"', "arm64 architecture branch missing");
contains(inno, "#error Unsupported Architecture", "unknown architecture does not fail closed");
contains(inno, "#ifdef TestAppId", "isolated installer-test AppId override missing");
contains(inno, "ExpandConstant('{app}\\CodexDreamSkinStudio.exe')", "installed restore-guard executable missing");
contains(inno, "'--prepare-uninstall'", "exact restore-guard argument missing");
contains(inno, "ewWaitUntilTerminated", "uninstall guard is not synchronous");
contains(inno, "ResultCode = 0", "uninstall guard does not fail closed");
assert.doesNotMatch(inno, /PrivilegesRequiredOverridesAllowed|deleteUserThemes|CodexDreamSkin\\(?:themes|images|active-theme)/i);

const builder = read("windows/scripts/build-studio-release.ps1");
const adapter = read("windows/scripts/studio-adapter.ps1");
const common = read("windows/scripts/common-windows.ps1");
const config = read("windows/scripts/config-utf8.ps1");
const protocolTests = read("windows/tests/studio-protocol.tests.ps1");
for (const contract of [
  "[ValidateSet('x64', 'arm64')]", "fetch-node-runtime.ps1", "--self-contained", "check-contents.mjs",
  "allowlist-windows.json", "WINDOWS_SIGN_CERT_THUMBPRINT", "Get-AuthenticodeSignature", "SHA256SUMS.txt",
  "UNSIGNED", "[IO.Directory]::Move", "/p:ApplicationIcon=", "RuntimeInformation]::OSArchitecture",
  "Windows Studio releases require a matching X64 or Arm64 build host.",
]) contains(builder, contract, `builder contract missing: ${contract}`);
assert.doesNotMatch(builder, /studio-release-contract\.test\.mjs/, "builder duplicates the aggregate portable contract gate");
for (const contract of [
  "function Remove-DreamSkinUserThemeData",
  "-not $status.State.requiresRestart",
  "Get-DreamSkinStudioRecoveryState -StateRoot $stateRoot",
  "$recovery.Completed -or $recovery.NeverApplied",
]) contains(adapter, contract, `uninstall recovery proof is missing: ${contract}`);
assert.equal((adapter.match(/Remove-DreamSkinUserThemeData -StateRoot \$stateRoot/g) || []).length, 2,
  "ordinary and already-restored uninstall do not share theme deletion");
contains(adapter, "$uninstallRecoveryAvailable", "uninstall is not gated by shared safe recovery classification");
const legacyShortcutCleanup = "Remove-DreamSkinManagedLegacyShortcuts";
const helperStart = common.indexOf(`function ${legacyShortcutCleanup}`);
const helper = helperStart < 0 ? "" : common.slice(helperStart);
assert.ok(helperStart >= 0, "legacy shortcut cleanup is not shared by the adapter and restore child");
for (const signaturePart of [
  "CreateShortcut(", "TargetPath", "Arguments", "Codex Dream Skin.lnk",
  "Codex Dream Skin - Restore.lnk", "Codex Dream Skin - Tray.lnk",
  "start-dream-skin.ps1", "restore-dream-skin.ps1", "tray-dream-skin.ps1",
]) contains(helper, signaturePart, `legacy shortcut cleanup does not verify ${signaturePart}`);
assert.match(helper, /Test-Path[\s\S]*Remove-Item/, "legacy shortcut cleanup is not idempotent when a shortcut is absent");
assert.match(helper, /if\s*\([\s\S]*?TargetPath[\s\S]*?Arguments[\s\S]*?\)[\s\S]*?Remove-Item/,
  "legacy shortcut cleanup can remove an unrelated shortcut by filename alone");
contains(helper, "Test-DreamSkinManagedLegacyScriptPath",
  "legacy shortcut cleanup does not recognize guarded historical product paths");
contains(helper, "CodexDreamSkinStudio\\versions",
  "legacy shortcut cleanup omits versioned sibling engines");
const skipUninstallStart = adapter.indexOf("if ($canSkipCompletedUninstall)");
const skipUninstallEnd = adapter.indexOf("if (($Operation -eq 'restore'", skipUninstallStart);
const skipUninstall = adapter.slice(skipUninstallStart, skipUninstallEnd);
contains(skipUninstall, legacyShortcutCleanup,
  "already-restored and never-applied uninstall skip legacy shortcut cleanup");
assert.doesNotMatch(skipUninstall, /Invoke-DreamSkinLifecycleChild|Restore-DreamSkin/,
  "completed uninstall reruns config restore instead of cleanup only");
const restoreScript = read("windows/scripts/restore-dream-skin.ps1");
const startScript = read("windows/scripts/start-dream-skin.ps1");
const recoveryWrite = startScript.indexOf("recoveryKind = 'managed-cdp'");
const debugLaunch = startScript.indexOf("Start-Process -FilePath $codex.Executable -ArgumentList $arguments");
assert.ok(recoveryWrite >= 0 && recoveryWrite < debugLaunch,
  "Apply/Resume does not publish durable CDP-only recovery authority before launch");
const recoveryRetryGuard = startScript.indexOf("$previousState.schemaVersion -eq 4");
const ordinaryProcessProbe = startScript.indexOf("$currentProcesses = Get-DreamSkinCodexProcesses");
assert.ok(recoveryRetryGuard >= 0 && recoveryRetryGuard < ordinaryProcessProbe,
  "direct start reinterprets retained schema-4 recovery through fail-open legacy probes");
contains(startScript, "Invoke-DreamSkinStartupCleanup",
  "Apply/Resume startup failures do not share one cleanup gate");
assert.equal((startScript.match(/Invoke-DreamSkinStartupCleanup/g) || []).length, 2,
  "Apply/Resume has more than one startup cleanup implementation or call site");
const foregroundStart = startScript.indexOf("if ($ForegroundInjector)");
const foregroundEnd = startScript.indexOf("$injectorArgs =", foregroundStart);
const foreground = startScript.slice(foregroundStart, foregroundEnd);
contains(foreground, "throw 'The foreground injector exited during startup.'",
  "foreground watcher failure bypasses the unified startup cleanup gate");
assert.doesNotMatch(foreground, /\b(?:DeleteExpectedFile|Remove-Item -LiteralPath \$StatePath)\b/,
  "foreground startup consumes recovery evidence before watcher success");
assert.doesNotMatch(foreground, /exit \$foregroundExitCode/,
  "foreground nonzero exit bypasses PowerShell catch semantics");
contains(foreground, "--browser-id $foregroundCleanupCdpIdentity.BrowserId",
  "foreground watcher does not use its captured Browser identity after outer authority is disarmed");
const foregroundCandidateManaged = foreground.indexOf("$foregroundCleanupNewManagedCdp = $newManagedCdp");
const foregroundCandidateIdentity = foreground.indexOf("$foregroundCleanupCdpIdentity = $cdpIdentity",
  foregroundCandidateManaged);
const foregroundCandidateSnapshot = foreground.indexOf("$foregroundCleanupSnapshot = $publishedStateSnapshot",
  foregroundCandidateIdentity);
const foregroundCandidateClosed = foreground.indexOf("$foregroundCleanupClosedCodex = $closedCodex",
  foregroundCandidateSnapshot);
const foregroundCandidateClosedPort = foreground.indexOf("$foregroundCleanupClosedCodexPort = $closedCodexPort",
  foregroundCandidateClosed);
const foregroundCandidatePauseWasSet = foreground.indexOf("$foregroundCleanupPauseWasSet = $pauseWasSet",
  foregroundCandidateClosedPort);
const foregroundCandidatePauseCleared = foreground.indexOf("$foregroundCleanupPauseCleared = $pauseCleared",
  foregroundCandidatePauseWasSet);
const foregroundDisarmManaged = foreground.indexOf("$newManagedCdp = $false", foregroundCandidatePauseCleared);
const foregroundDisarmIdentity = foreground.indexOf("$cdpIdentity = $null", foregroundDisarmManaged);
const foregroundDisarmSnapshot = foreground.indexOf("$publishedStateSnapshot = $null", foregroundDisarmIdentity);
const foregroundDisarmClosed = foreground.indexOf("$closedCodex = $null", foregroundDisarmSnapshot);
const foregroundDisarmClosedPort = foreground.indexOf("$closedCodexPort = $null", foregroundDisarmClosed);
const foregroundDisarmPauseWasSet = foreground.indexOf("$pauseWasSet = $false", foregroundDisarmClosedPort);
const foregroundDisarmPauseCleared = foreground.indexOf("$pauseCleared = $false", foregroundDisarmPauseWasSet);
const foregroundLockRelease = foreground.indexOf("Exit-DreamSkinOperationLock -Mutex $operationLock",
  foregroundDisarmPauseCleared);
const foregroundFailure = foreground.indexOf("if ($LASTEXITCODE -ne 0)", foregroundLockRelease);
const foregroundLockReentry = foreground.indexOf("$operationLock = Enter-DreamSkinOperationLock", foregroundFailure);
const foregroundEvidenceProof = foreground.indexOf(
  "Assert-DreamSkinStableFileSnapshotUnchanged -Snapshot $foregroundCleanupSnapshot", foregroundLockReentry);
const foregroundCurrentProcessProbe = foreground.indexOf(
  "$foregroundCurrentProcesses = @(Get-DreamSkinCodexProcessesStrict -Codex $codex)", foregroundEvidenceProof);
const foregroundCurrentProcessProof = foreground.indexOf(
  "$foregroundCurrentProcesses.Count -eq 0", foregroundCurrentProcessProbe);
const foregroundCurrentListenerProbe = foreground.indexOf(
  "$foregroundCurrentListeners = @(Get-DreamSkinPortListenersStrict -Port $Port)", foregroundCurrentProcessProof);
const foregroundCurrentListenerProof = foreground.indexOf(
  "$foregroundCurrentListeners.Count -eq 0", foregroundCurrentListenerProbe);
const foregroundIdentityRecheck = foreground.indexOf(
  "$foregroundIdentity = Get-DreamSkinVerifiedCdpIdentity -Port $Port -Codex $codex",
  foregroundCurrentListenerProof);
const foregroundIdentityMatch = foreground.indexOf(
  "$foregroundIdentity.BrowserId -cne $foregroundCleanupCdpIdentity.BrowserId", foregroundIdentityRecheck);
const foregroundClosedMatch = foreground.indexOf(
  "$foregroundClosedMatchesCurrent = Test-DreamSkinPathEqual", foregroundIdentityMatch);
const foregroundClosedIdentityProof = foreground.indexOf(
  "Get-DreamSkinCodexProcessesStrict -Codex $foregroundCleanupClosedCodex", foregroundClosedMatch);
const foregroundClosedPortMatch = foreground.indexOf(
  "$foregroundClosedPortMatchesCurrent = [int]$foregroundCleanupClosedCodexPort -eq $Port",
  foregroundClosedIdentityProof);
const foregroundClosedPortProof = foreground.indexOf(
  "Get-DreamSkinPortListenersStrict -Port ([int]$foregroundCleanupClosedCodexPort)",
  foregroundClosedPortMatch);
const foregroundRearmManaged = foreground.indexOf(
  "$newManagedCdp = $foregroundCleanupNewManagedCdp", foregroundClosedPortProof);
const foregroundRearmIdentity = foreground.indexOf(
  "$cdpIdentity = $foregroundCleanupCdpIdentity", foregroundRearmManaged);
const foregroundRearmSnapshot = foreground.indexOf(
  "$publishedStateSnapshot = $foregroundCleanupSnapshot", foregroundRearmIdentity);
const foregroundRearmClosed = foreground.indexOf(
  "$closedCodex = $foregroundCleanupClosedCodex", foregroundRearmSnapshot);
const foregroundRearmClosedPort = foreground.indexOf(
  "$closedCodexPort = $foregroundCleanupClosedCodexPort", foregroundRearmClosed);
const foregroundRearmPauseWasSet = foreground.indexOf(
  "$pauseWasSet = $foregroundCleanupPauseWasSet", foregroundRearmClosedPort);
const foregroundRearmPauseCleared = foreground.indexOf(
  "$pauseCleared = $foregroundCleanupPauseCleared", foregroundRearmPauseWasSet);
const foregroundThrow = foreground.indexOf(
  "throw 'The foreground injector exited during startup.'", foregroundRearmPauseCleared);
assert.ok(foregroundCandidateManaged >= 0 && foregroundCandidateIdentity > foregroundCandidateManaged &&
  foregroundCandidateSnapshot > foregroundCandidateIdentity &&
  foregroundCandidateClosed > foregroundCandidateSnapshot &&
  foregroundCandidateClosedPort > foregroundCandidateClosed &&
  foregroundCandidatePauseWasSet > foregroundCandidateClosedPort &&
  foregroundCandidatePauseCleared > foregroundCandidatePauseWasSet &&
  foregroundDisarmManaged > foregroundCandidatePauseCleared &&
  foregroundDisarmIdentity > foregroundDisarmManaged && foregroundDisarmSnapshot > foregroundDisarmIdentity &&
  foregroundDisarmClosed > foregroundDisarmSnapshot && foregroundDisarmClosedPort > foregroundDisarmClosed &&
  foregroundDisarmPauseWasSet > foregroundDisarmClosedPort &&
  foregroundDisarmPauseCleared > foregroundDisarmPauseWasSet &&
  foregroundLockRelease > foregroundDisarmPauseCleared && foregroundFailure > foregroundLockRelease &&
  foregroundLockReentry > foregroundFailure && foregroundEvidenceProof > foregroundLockReentry &&
  foregroundCurrentProcessProbe > foregroundEvidenceProof &&
  foregroundCurrentProcessProof > foregroundCurrentProcessProbe &&
  foregroundCurrentListenerProbe > foregroundCurrentProcessProof &&
  foregroundCurrentListenerProof > foregroundCurrentListenerProbe &&
  foregroundIdentityRecheck > foregroundCurrentListenerProof &&
  foregroundIdentityMatch > foregroundIdentityRecheck &&
  foregroundClosedMatch > foregroundIdentityMatch &&
  foregroundClosedIdentityProof > foregroundClosedMatch &&
  foregroundClosedPortMatch > foregroundClosedIdentityProof &&
  foregroundClosedPortProof > foregroundClosedPortMatch &&
  foregroundRearmManaged > foregroundClosedPortProof && foregroundRearmIdentity > foregroundRearmManaged &&
  foregroundRearmSnapshot > foregroundRearmIdentity && foregroundRearmClosed > foregroundRearmSnapshot &&
  foregroundRearmClosedPort > foregroundRearmClosed &&
  foregroundRearmPauseWasSet > foregroundRearmClosedPort &&
  foregroundRearmPauseCleared > foregroundRearmPauseWasSet &&
  foregroundThrow > foregroundRearmPauseCleared,
  "new-managed foreground reentry does not strictly revalidate current Browser, process, and listener authority");
const strictProcessesStart = common.indexOf("function Get-DreamSkinCodexProcessesStrict");
const strictProcessesEnd = common.indexOf("\nfunction ", strictProcessesStart + 1);
const strictProcesses = common.slice(strictProcessesStart, strictProcessesEnd < 0 ? undefined : strictProcessesEnd);
for (const contract of ["Get-CimInstance Win32_Process", "-ErrorAction Stop", "Get-DreamSkinProcessExecutablePath"]) {
  contains(strictProcesses, contract, `strict Codex absence probe is incomplete: ${contract}`);
}
const strictListenersStart = common.indexOf("function Get-DreamSkinPortListenersStrict");
const strictListenersEnd = common.indexOf("\nfunction ", strictListenersStart + 1);
const strictListeners = common.slice(strictListenersStart, strictListenersEnd < 0 ? undefined : strictListenersEnd);
for (const contract of [
  "Get-NetTCPConnection -State Listen -ErrorAction Stop",
  "Where-Object { [int]$_.LocalPort -eq $Port }",
]) {
  contains(strictListeners, contract, `strict listener absence probe is incomplete: ${contract}`);
}
assert.doesNotMatch(strictListeners, /Get-NetTCPConnection[^\r\n]*-LocalPort/,
  "strict listener absence mistakes an empty LocalPort query for provider failure");
const recordedInjectorStopStart = common.indexOf("function Stop-DreamSkinRecordedInjector");
const recordedInjectorStopEnd = common.indexOf("\nfunction ", recordedInjectorStopStart + 1);
const recordedInjectorStop = common.slice(recordedInjectorStopStart,
  recordedInjectorStopEnd < 0 ? undefined : recordedInjectorStopEnd);
contains(recordedInjectorStop,
  'Get-CimInstance Win32_Process -Filter "ProcessId = $processId" -ErrorAction Stop',
  "recorded watcher cleanup treats CIM provider failure as process absence");
assert.doesNotMatch(recordedInjectorStop, /Get-CimInstance[^\r\n]*-ErrorAction SilentlyContinue/,
  "recorded watcher cleanup suppresses CIM provider failure");
const startupRollbackStart = startScript.indexOf("function Invoke-DreamSkinStartupCleanup");
const startupRollbackEnd = startScript.indexOf("\n}", startupRollbackStart) + 2;
const startupRollback = startScript.slice(startupRollbackStart, startupRollbackEnd);
contains(startupRollback, "[AllowNull()][object]$ClosedCodex",
  "pre-launch closed Codex identity is not carried into unified cleanup");
contains(startupRollback, "[AllowNull()][Nullable[int]]$ClosedCodexPort",
  "pre-launch closed Codex port is not carried into unified cleanup");
contains(startupRollback, "[bool]$PriorInjectorCleanupProven",
  "unified cleanup does not receive prior recorded-watcher cleanup authority");
contains(startupRollback, "$injectorStopped = $PriorInjectorCleanupProven",
  "unified cleanup assumes prior recorded-watcher cleanup succeeded");
contains(startupRollback, "$cleanupProven = $false",
  "Apply/Resume rollback has no positive renderer-or-session cleanup proof");
contains(startupRollback, "$cleanupProven = $true",
  "Apply/Resume rollback never records successful renderer-or-session cleanup");
contains(startupRollback,
  "if ($null -eq $rollbackIdentity -or $rollbackIdentity.BrowserId -cne $CdpIdentity.BrowserId)",
  "Apply/Resume rollback treats a missing or mismatched Browser ID as successful cleanup");
contains(startupRollback, "Get-DreamSkinPortListenersStrict -Port $Port",
  "new-CDP rollback does not prove that its listener closed");
contains(startupRollback, "(Get-DreamSkinCodexProcessesStrict -Codex $Codex).Count -ne 0",
  "new-CDP rollback does not prove that Codex closed");
contains(startupRollback,
  "$cleanupComplete = $injectorStopped -and $cleanupProven",
  "Apply/Resume rollback discards state without both watcher and live-cleanup proof");
contains(startupRollback, "[DreamSkinConfigNative]::DeleteExpectedFile",
  "successful Apply/Resume cleanup does not strictly consume its exact recovery state");
const strictStateConsumption = startupRollback.indexOf("[DreamSkinConfigNative]::DeleteExpectedFile");
const cleanupReturn = startupRollback.indexOf("return $cleanupComplete", strictStateConsumption);
assert.ok(strictStateConsumption >= 0 && cleanupReturn > strictStateConsumption,
  "Apply/Resume reports cleanup complete before strict recovery-state consumption");
const rollbackRemove = startupRollback.indexOf("--remove --port $Port --browser-id $CdpIdentity.BrowserId");
const rollbackRemoveExit = startupRollback.indexOf("$LASTEXITCODE -ne 0", rollbackRemove);
const existingCleanupProof = startupRollback.indexOf("$cleanupProven = $true", rollbackRemoveExit);
const rollbackStopCodex = startupRollback.indexOf("Stop-DreamSkinCodex -Codex $Codex -AllowForce");
const rollbackNoProcesses = startupRollback.indexOf("(Get-DreamSkinCodexProcessesStrict -Codex $Codex).Count -ne 0",
  rollbackStopCodex);
const rollbackPortClosed = startupRollback.indexOf("Get-DreamSkinPortListenersStrict -Port $Port",
  rollbackNoProcesses);
const launchedCleanupProof = startupRollback.indexOf("$cleanupProven = $true", rollbackPortClosed);
assert.ok(rollbackRemove >= 0 && rollbackRemoveExit > rollbackRemove && existingCleanupProof > rollbackRemoveExit,
  "existing-CDP rollback marks cleanup before anchored removal succeeds");
assert.ok(rollbackStopCodex >= 0 && rollbackNoProcesses > rollbackStopCodex &&
  rollbackPortClosed > rollbackNoProcesses && launchedCleanupProof > rollbackPortClosed,
  "new-CDP rollback marks cleanup before Codex and its listener are confirmed closed");
const closedCleanupStart = startupRollback.indexOf(
  "if ($injectorStopped -and $null -ne $ClosedCodex)");
const closedNoProcesses = startupRollback.indexOf(
  "(Get-DreamSkinCodexProcessesStrict -Codex $ClosedCodex).Count -ne 0", closedCleanupStart);
const closedCurrentDiffers = startupRollback.indexOf(
  "Test-DreamSkinPathEqual -Left $ClosedCodex.Executable -Right $Codex.Executable", closedNoProcesses);
const closedCurrentNoProcesses = startupRollback.indexOf(
  "(Get-DreamSkinCodexProcessesStrict -Codex $Codex).Count -ne 0", closedCurrentDiffers);
const closedPortAbsent = startupRollback.indexOf(
  "Get-DreamSkinPortListenersStrict -Port ([int]$ClosedCodexPort)", closedCurrentNoProcesses);
const closedCleanupProof = startupRollback.indexOf("$cleanupProven = $true", closedPortAbsent);
assert.ok(closedCleanupStart >= 0 && closedNoProcesses > closedCleanupStart &&
  closedCurrentDiffers > closedNoProcesses && closedCurrentNoProcesses > closedCurrentDiffers &&
  closedPortAbsent > closedCurrentNoProcesses && closedCleanupProof > closedPortAbsent,
  "pre-launch closed Codex cleanup does not strictly prove closed/current identities and port absence");
contains(startupRollback, "$closedMatchesCurrent = Test-DreamSkinPathEqual",
  "combined closed/new cleanup cannot deduplicate the current package identity");
contains(startupRollback, "$closedPortMatchesCurrent = [int]$ClosedCodexPort -eq $Port",
  "combined closed/new cleanup cannot deduplicate the active port proof");
contains(startupRollback, "$cleanupProven = $cleanupProven -and $closedCleanupProven",
  "combined closed/new cleanup replaces rather than conjoins independent authority proofs");
contains(startupRollback, "($NewManagedCdp -or $null -eq $ClosedCodex)",
  "pre-launch closed cleanup can delete state published before snapshot failure");
const authorizedStop = startScript.indexOf("Stop-DreamSkinCodex -Codex $codexToStop");
const closedIdentityCapture = startScript.indexOf("$closedCodex = $codexToStop", authorizedStop);
const closedPortCapture = startScript.indexOf("$closedCodexPort = $Port", closedIdentityCapture);
const resetToCurrent = startScript.indexOf("$codex = $currentCodex", authorizedStop);
const startupTransaction = startScript.indexOf("try {", closedIdentityCapture);
const firstPostCloseBoundary = startScript.indexOf("Ensure-DreamSkinManagedDirectory", authorizedStop);
assert.ok(authorizedStop >= 0 && closedIdentityCapture > authorizedStop && closedPortCapture > closedIdentityCapture &&
  resetToCurrent > closedPortCapture,
  "successful restart authorization does not retain the exact closed package identity and port before resetting to current");
assert.ok(startupTransaction > resetToCurrent && startupTransaction < firstPostCloseBoundary,
  "the first post-close pre-launch failure bypasses unified cleanup");
contains(startScript, "-ClosedCodex $closedCodex", "unified startup cleanup call omits the closed package identity");
contains(startScript, "-ClosedCodexPort $closedCodexPort", "unified startup cleanup call omits the closed session port");
contains(startScript, "-PriorInjectorCleanupProven $priorInjectorCleanupProven",
  "unified startup cleanup call omits prior recorded-watcher cleanup authority");
contains(startScript, "$priorInjectorCleanupProven = [bool]$recordedInjectorStopped",
  "Start does not retain the result of prior recorded-watcher cleanup");
contains(startScript, "if (($newManagedCdp -or $null -ne $closedCodex) -and $cleanupProven)",
  "official Codex relaunch ignores proven pre-launch closed-session cleanup");
for (const contract of [
  "foreach ($operation in @('start', 'resume'))",
  "foreach ($closedIdentity in @('current', 'saved'))",
  "foreach ($failure in @('prior-state', 'state-write', 'state-snapshot'))",
  '$scenario = "prelaunch-closed-$operation-$closedIdentity-$failure-fail"',
  "'prelaunch-closed-start-saved-state-snapshot-fail-cleanup-closed-cim-error'",
  "'prelaunch-closed-start-saved-state-snapshot-fail-cleanup-current-cim-error'",
  "'prelaunch-closed-start-saved-state-snapshot-fail-cleanup-tcp-error'",
]) contains(protocolTests, contract, `matching-host pre-launch closed-session fixture missing: ${contract}`);
for (const contract of [
  "'prior-watcher-provider-error-state-snapshot-fail'",
  "$env:DREAM_SKIN_TEST_SCENARIO -notlike 'prior-watcher-provider-error-*'",
  "recorded-injector-cim-provider-error",
]) contains(protocolTests, contract, `matching-host production recorded-watcher fixture missing: ${contract}`);
for (const contract of [
  "foreach ($closedIdentity in @('current', 'saved'))",
  '$scenario = "combined-closed-new-$operation-$closedIdentity-early-wait-success"',
  "'combined-closed-new-start-saved-early-wait-cleanup-new-cim-error'",
  "'combined-closed-new-start-saved-early-wait-cleanup-new-tcp-error'",
  "'combined-closed-new-start-saved-early-wait-cleanup-closed-cim-error'",
  "'combined-closed-new-start-saved-early-wait-cleanup-closed-tcp-error'",
]) contains(protocolTests, contract, `matching-host combined closed/new cleanup fixture missing: ${contract}`);
contains(adapter, "$status.StateDamaged",
  "adapter does not distinguish malformed state from readable stale state");
contains(adapter, "$childArguments += '-RecoverDamagedState'",
  "adapter cannot dispatch its advertised malformed-state recovery path");
contains(restoreScript, "[switch]$RecoverDamagedState",
  "restore child has no private malformed-state recovery mode");
assert.match(restoreScript,
  /Archive-DreamSkinStateFile -Path \$StatePath\s+`?\s*-ExpectedSnapshot \$stateArtifactSnapshot/,
  "malformed state quarantine is not bound to its classified identity and bytes");
const damagedSnapshot = restoreScript.indexOf(
  "$stateArtifactSnapshot = Get-DreamSkinStableFileSnapshot -Path $StatePath -AllowMissing");
const damagedParse = restoreScript.indexOf("Read-DreamSkinState -Path $StatePath -Bytes $stateArtifactSnapshot.Bytes");
assert.ok(damagedSnapshot >= 0 && damagedParse > damagedSnapshot,
  "state classification does not parse the one stable no-reparse snapshot");
assert.equal((restoreScript.match(/Get-DreamSkinStableFileSnapshot -Path \$StatePath/g) || []).length, 1,
  "Restore takes more than one state snapshot after classification");
contains(restoreScript, "$managedCdpRecovery = $null -ne $state -and $state.schemaVersion -eq 4",
  "ordinary Restore does not recognize retained schema-4 cleanup evidence");
assert.equal((restoreScript.match(/Get-DreamSkinRegisteredCodexInstalls/g) || []).length, 1,
  "Restore does not derive saved and current Codex identities from one Appx inventory snapshot");
assert.doesNotMatch(restoreScript, /(?<!Resolve-)Get-DreamSkinCodexInstall(?:FromState)?\b/,
  "Restore re-enumerates or suppresses failure while resolving saved/current Codex identities");
const appxInventory = restoreScript.indexOf(
  "$registeredCodexInstalls = @(Get-DreamSkinRegisteredCodexInstalls)");
const currentFromInventory = restoreScript.indexOf("$registeredCodexInstalls[0]", appxInventory);
const savedFromInventory = restoreScript.indexOf(
  "Resolve-DreamSkinCodexInstallFromState -State $state -RegisteredInstalls $registeredCodexInstalls",
  currentFromInventory);
assert.ok(appxInventory >= 0 && currentFromInventory > appxInventory && savedFromInventory > currentFromInventory,
  "Restore does not use one terminating Appx snapshot for both current and saved identities");
const managedRecoveryDetection = restoreScript.indexOf("$managedCdpRecovery = $null -ne $state");
const managedRecoveryPortBinding = restoreScript.indexOf(
  "$managedCdpRecovery -and $PortExplicit -and [int]$state.port -ne $Port");
const firstManagedRecoveryProcessScan = restoreScript.indexOf(
  "Get-DreamSkinCodexProcessesStrict -Codex $savedCodex");
assert.ok(managedRecoveryDetection >= 0 && managedRecoveryPortBinding > managedRecoveryDetection &&
  firstManagedRecoveryProcessScan > managedRecoveryPortBinding,
  "schema-4 Restore does not reject an explicit port that differs from retained recovery authority before probing");
contains(restoreScript, "Get-DreamSkinCodexProcessesStrict -Codex $savedCodex",
  "schema-4 Restore does not fail closed on CIM enumeration");
contains(restoreScript, "Get-DreamSkinPortListenersStrict -Port $Port",
  "schema-4 Restore does not fail closed on listener enumeration");
const transactionStart = restoreScript.indexOf("try {", restoreScript.indexOf("$transactionCommitted = $false"));
const transactionSavedProcessScan = restoreScript.indexOf(
  "Get-DreamSkinCodexProcessesStrict -Codex $savedCodex", firstManagedRecoveryProcessScan + 1);
const transactionCurrentProcessScan = restoreScript.indexOf(
  "Get-DreamSkinCodexProcessesStrict -Codex $currentCodex", transactionSavedProcessScan);
const transactionListenerScan = restoreScript.indexOf(
  "Get-DreamSkinPortListenersStrict -Port $Port", transactionSavedProcessScan);
const firstManagedMutation = restoreScript.indexOf("Ensure-DreamSkinManagedDirectory", transactionStart);
const managedStateProof = restoreScript.indexOf(
  "Assert-DreamSkinStableFileSnapshotUnchanged -Snapshot $stateArtifactSnapshot", transactionStart);
assert.ok(transactionStart >= 0 && managedStateProof > transactionStart &&
  transactionSavedProcessScan > managedStateProof &&
  transactionCurrentProcessScan > transactionSavedProcessScan &&
  transactionListenerScan > transactionCurrentProcessScan && firstManagedMutation > transactionListenerScan,
  "schema-4 Restore does not reprove its exact state and strict process/listener absence before mutation");
assert.doesNotMatch(restoreScript, /Get-DreamSkinRecoveryArtifactSnapshot -Path \$StatePath/,
  "Restore captures state.json through classification-dependent pathname rollback");
assert.doesNotMatch(restoreScript, /Remove-DreamSkinRecoveryArtifact -Path \$StatePath/,
  "Restore deletes state.json through a classification-dependent pathname operation");
const initialMissingStateGuard = restoreScript.indexOf(
  "if (-not $RecoverDamagedState -and -not $stateArtifactSnapshot.Exists)");
const initialMissingStateHold = restoreScript.indexOf(
  "$statePathGuard = [DreamSkinConfigNative]::HoldMissingPath($StatePath)", initialMissingStateGuard);
assert.ok(initialMissingStateGuard > damagedParse && initialMissingStateHold > initialMissingStateGuard &&
  initialMissingStateHold < appxInventory,
  "initially missing state.json is not guarded before later lifecycle discovery or mutation");
const exactStateDelete = restoreScript.indexOf("[DreamSkinConfigNative]::DeleteExpectedFile(", firstManagedMutation);
const exactStateDeleteIdentity = restoreScript.indexOf(
  "$StatePath, $stateArtifactSnapshot.Identity, $stateArtifactSnapshot.Bytes", exactStateDelete);
const exactStateGuard = restoreScript.indexOf(
  "$statePathGuard = [DreamSkinConfigNative]::HoldMissingPath($StatePath)", exactStateDeleteIdentity);
const exactStateGuardComplete = restoreScript.indexOf("$statePathGuard.Complete()", exactStateGuard);
const exactStateCommit = restoreScript.indexOf("$transactionCommitted = $true", exactStateGuardComplete);
assert.ok(exactStateDelete > firstManagedMutation && exactStateDeleteIdentity > exactStateDelete &&
  exactStateGuard > exactStateDeleteIdentity && exactStateGuardComplete > exactStateGuard &&
  exactStateCommit > exactStateGuardComplete,
  "initially existing readable state is not consumed exactly under one commit path guard");
for (const scenario of [
  "schema4-restore-process-appears",
  "schema4-restore-listener-appears",
  "schema4-current-running",
  "schema4-explicit-port-mismatch",
  "schema4-appx-provider-error",
  "schema4-appx-update-race",
  "schema4-appx-distinct-current-running",
]) contains(protocolTests, scenario, `matching-host retained-state fixture missing: ${scenario}`);
for (const contract of [
  "foreach ($race in @('replacement', 'same-bytes', 'reparse', 'post-proof', 'post-delete'))",
  "foreach ($operation in @('restore', 'uninstall'))",
  '$scenario = "schema4-state-race-$race-$operation"',
]) contains(protocolTests, contract, `matching-host schema-4 state race matrix missing: ${contract}`);
for (const contract of [
  "foreach ($initialState in @('missing', 'schema3'))",
  "foreach ($phase in @('before-snapshot', 'after-snapshot', 'during-rollback'))",
  "foreach ($operation in @('restore', 'uninstall'))",
  '$scenario = "state-transition-$initialState-$phase-$operation"',
]) contains(protocolTests, contract, `matching-host state classification transition matrix missing: ${contract}`);
assert.doesNotMatch(protocolTests, /real-restore-state-unlink-fail|remove:\$realState/,
  "matching-host rollback fixtures still assume pathname-based state cleanup");
const watcherAbsenceStart = common.indexOf("function Assert-DreamSkinNoManagedWatcherProcess");
const watcherAbsenceEnd = common.indexOf("\nfunction ", watcherAbsenceStart + 1);
const watcherAbsence = common.slice(watcherAbsenceStart, watcherAbsenceEnd < 0 ? undefined : watcherAbsenceEnd);
assert.ok(watcherAbsenceStart >= 0, "shared malformed-state watcher absence proof is missing");
for (const contract of [
  "Name = 'node.exe'", "-ErrorAction Stop", "CodexDreamSkinStudio\\versions",
  "engine\\runtime\\node.exe", "engine\\scripts\\injector.mjs",
  "windows\\scripts\\injector.mjs", "--watch",
]) contains(watcherAbsence, contract, `watcher absence proof is incomplete: ${contract}`);
assert.doesNotMatch(watcherAbsence, /\bStop-(?:Process|DreamSkinRecordedInjector)\b/,
  "malformed-state absence proof kills a process it cannot authorize");
for (const [name, expected] of [
  ["versionedNodeSuffix", "engine\\runtime\\node.exe"],
  ["versionedInjectorSuffix", "engine\\scripts\\injector.mjs"],
  ["historicalInjectorSuffix", "windows\\scripts\\injector.mjs"],
]) {
  contains(watcherAbsence, `$${name} = '${expected}'`, `${name} is not a single-separator Windows path`);
  assert.ok(!watcherAbsence.includes(`$${name} = '${expected.replaceAll("\\", "\\\\")}'`),
    `${name} contains literal doubled path separators`);
}
const archiveStateStart = common.indexOf("function Archive-DreamSkinStateFile");
const archiveStateEnd = common.indexOf("\nfunction ", archiveStateStart + 1);
const archiveState = common.slice(archiveStateStart, archiveStateEnd < 0 ? undefined : archiveStateEnd);
const normalizedArchiveSource = archiveState.indexOf(
  "$normalizedPath = [DreamSkinConfigNative]::NormalizePath($Path)");
const normalizedArchiveSnapshot = archiveState.indexOf(
  "$normalizedSnapshotPath = [DreamSkinConfigNative]::NormalizePath(\"$($ExpectedSnapshot.FullPath)\")");
const normalizedArchiveCompare = archiveState.indexOf(
  "$normalizedPath.Equals($normalizedSnapshotPath, [System.StringComparison]::OrdinalIgnoreCase)");
assert.ok(normalizedArchiveSource >= 0 && normalizedArchiveSnapshot > normalizedArchiveSource &&
  normalizedArchiveCompare > normalizedArchiveSnapshot,
  "state quarantine compares native snapshot and input paths without normalizing both extended-path forms");
contains(archiveState, "[DreamSkinConfigNative]::QuarantineExpectedFile",
  "state quarantine does not rename the classified handle by identity and bytes");
contains(config, "public static void QuarantineExpectedFile",
  "native stable-handle quarantine boundary is missing");
for (const contract of [
  "expectedIdentity", "expectedBytes", "RenameRelative(file, parent",
  "ResolvedPath(file, fullPath)", "Identity(Inspect(file, fullArchivePath))",
]) {
  contains(config, contract, `native state quarantine is incomplete: ${contract}`);
}
const codexAbsenceStart = common.indexOf("function Assert-DreamSkinNoRegisteredCodexProcessOrListener");
const codexAbsenceEnd = common.indexOf("\nfunction ", codexAbsenceStart + 1);
const codexAbsence = common.slice(codexAbsenceStart, codexAbsenceEnd < 0 ? undefined : codexAbsenceEnd);
assert.ok(codexAbsenceStart >= 0, "malformed recovery has no registered Codex/process/listener absence proof");
for (const contract of [
  "Name = 'ChatGPT.exe'", "Get-DreamSkinProcessExecutablePath",
  "Get-NetTCPConnection -State Listen -ErrorAction Stop",
  "Where-Object { [int]$_.LocalPort -eq $Port }",
]) {
  contains(codexAbsence, contract, `registered Codex absence proof is incomplete: ${contract}`);
}
assert.doesNotMatch(codexAbsence, /Test-DreamSkinPortAvailable/,
  "damaged-state listener proof reuses a fail-open availability probe");
assert.doesNotMatch(codexAbsence, /\bStop-(?:Process|DreamSkinCodex)\b/,
  "registered Codex absence proof kills a process instead of observing it");
const trayAbsenceStart = common.indexOf("function Assert-DreamSkinNoManagedTrayProcess");
const trayAbsenceEnd = common.indexOf("\nfunction ", trayAbsenceStart + 1);
const trayAbsence = common.slice(trayAbsenceStart, trayAbsenceEnd < 0 ? undefined : trayAbsenceEnd);
assert.ok(trayAbsenceStart >= 0, "malformed recovery has no managed tray absence proof");
for (const contract of [
  "Name = 'powershell.exe' OR Name = 'pwsh.exe'", "tray-dream-skin.ps1",
  "CodexDreamSkinStudio\\versions", "windows\\scripts\\tray-dream-skin.ps1",
]) contains(trayAbsence, contract, `managed tray absence proof is incomplete: ${contract}`);
assert.doesNotMatch(trayAbsence, /\bStop-Process\b/,
  "malformed-state tray proof kills a process instead of observing it");
const damagedRecoveryStart = restoreScript.indexOf("if ($RecoverDamagedState)");
const firstWatcherAbsence = restoreScript.indexOf("Assert-DreamSkinNoManagedWatcherProcess", damagedRecoveryStart);
const configRestore = restoreScript.indexOf("Restore-DreamSkinBaseTheme -ConfigPath $config", firstWatcherAbsence);
const secondWatcherAbsence = restoreScript.indexOf("Assert-DreamSkinNoManagedWatcherProcess", firstWatcherAbsence + 1);
const configArchive = restoreScript.indexOf("Publish-DreamSkinConfigBackupArchive", configRestore);
const damagedStateQuarantine = restoreScript.indexOf("Archive-DreamSkinStateFile -Path $StatePath", configArchive);
const damagedPathGuard = restoreScript.indexOf("HoldMissingPath($StatePath)", damagedStateQuarantine);
const damagedCommit = restoreScript.indexOf("$transactionCommitted = $true", damagedStateQuarantine);
assert.ok(damagedRecoveryStart >= 0 && firstWatcherAbsence > damagedRecoveryStart &&
  configRestore > firstWatcherAbsence && secondWatcherAbsence > configRestore &&
  configArchive > secondWatcherAbsence && damagedStateQuarantine > configArchive &&
  damagedPathGuard > damagedStateQuarantine && damagedCommit > damagedPathGuard,
  "malformed recovery does not prove watcher absence around config restore and quarantine state before commit");
const firstCodexAbsence = restoreScript.indexOf("Assert-DreamSkinNoRegisteredCodexProcessOrListener",
  firstWatcherAbsence);
const secondCodexAbsence = restoreScript.indexOf("Assert-DreamSkinNoRegisteredCodexProcessOrListener",
  firstCodexAbsence + 1);
assert.ok(firstCodexAbsence > firstWatcherAbsence && firstCodexAbsence < configRestore &&
  secondCodexAbsence > configRestore && secondCodexAbsence < configArchive,
  "malformed recovery does not disprove every registered Codex process/listener around config restore");
const firstTrayAbsence = restoreScript.indexOf("Assert-DreamSkinNoManagedTrayProcess", firstWatcherAbsence);
const secondTrayAbsence = restoreScript.indexOf("Assert-DreamSkinNoManagedTrayProcess", firstTrayAbsence + 1);
assert.ok(firstTrayAbsence > firstWatcherAbsence && firstTrayAbsence < configRestore &&
  secondTrayAbsence > configRestore && secondTrayAbsence < configArchive,
  "malformed recovery does not disprove managed tray processes around config restore");
contains(restoreScript, "if (-not $RecoverDamagedState) { Stop-DreamSkinTrayProcess }",
  "malformed recovery still kills an unproven tray-like PowerShell process");
assert.doesNotMatch(restoreScript,
  /\$artifactSnapshots\s*=\s*@\(\s*\$stateArtifactSnapshot/,
  "malformed recovery sends its stable state snapshot through generic artifact rollback");
const ordinaryUninstallStart = restoreScript.indexOf("if ($Uninstall)");
const ordinaryUninstall = restoreScript.slice(ordinaryUninstallStart);
contains(ordinaryUninstall, legacyShortcutCleanup,
  "ordinary uninstall does not share guarded legacy shortcut cleanup");
assert.ok(ordinaryUninstallStart > restoreScript.indexOf("$transactionCommitted = $true"),
  "ordinary uninstall cleans legacy shortcuts before its restore transaction commits");
for (const contract of [
  "git -C $RepoRoot write-tree",
  "git -C $RepoRoot read-tree $IndexTree",
  "git -C $RepoRoot checkout-index --all --force",
  "$env:GIT_INDEX_FILE",
  "diff --quiet $IndexTree",
  "ls-files --others --exclude-standard",
  "$SnapshotRepoRoot",
  "$SnapshotWindowsRoot",
]) contains(builder, contract, `immutable Git-index snapshot contract missing: ${contract}`);
contains(builder, "$SnapshotTemporaryRoot = Join-Path ([IO.Path]::GetTempPath())",
  "snapshot remains nested under the live repository");
contains(builder, "$SnapshotRepoRoot = Join-Path $SnapshotTemporaryRoot 'snapshot'",
  "snapshot is not rooted in isolated temporary storage");
for (const externalOutput of [
  "$SnapshotIndex = Join-Path $SnapshotTemporaryRoot 'snapshot.index'",
  "$PublishOutput = Join-Path $SnapshotTemporaryRoot 'dotnet-publish'",
  "$TestArtifactsRoot = Join-Path $SnapshotTemporaryRoot 'test-artifacts'",
  "$IconPath = Join-Path $SnapshotTemporaryRoot 'CodexDreamSkinStudio.ico'",
]) contains(builder, externalOutput, `compiler scratch remains under live windows: ${externalOutput}`);
contains(builder, "Remove-Item -LiteralPath $SnapshotTemporaryRoot -Recurse -Force",
  "external release scratch is not cleaned");
assert.doesNotMatch(builder, /\$SnapshotRepoRoot = Join-Path \$TemporaryRoot\b/,
  "snapshot can discover live repository build customizations");
contains(builder, "Push-Location $SnapshotRepoRoot", "dotnet publish does not run from the isolated snapshot");
for (const customization of [
  "'Directory.Build.props'", "'Directory.Build.targets'",
  "'windows/Directory.Build.props'", "'windows/Directory.Build.targets'",
]) contains(builder, customization, `release input closure omits ${customization}`);
assert.doesNotMatch(builder, /\bgit\b[^\r\n]*\barchive\b/, "Windows release snapshot uses forbidden git archive");
for (const snapshotSource of [
  "Join-Path $SnapshotRepoRoot 'studio\\assets\\app-icon-source.png'",
  "Join-Path $SnapshotWindowsRoot 'studio\\CodexDreamSkinStudio.csproj'",
  "Join-Path $SnapshotWindowsRoot 'scripts\\fetch-node-runtime.ps1'",
  "Join-Path $SnapshotRepoRoot 'studio\\release\\check-contents.mjs'",
  "Join-Path $SnapshotRepoRoot 'studio\\release\\allowlist-windows.json'",
  "Join-Path $SnapshotWindowsRoot 'build\\dream-skin-studio.iss'",
]) contains(builder, snapshotSource, `release stage still lacks exact snapshot source: ${snapshotSource}`);
for (const [property, value] of [
  ["Version", "$Version"],
  ["FileVersion", "$Version.0"],
  ["AssemblyVersion", "$Version.0"],
  ["InformationalVersion", "$Version"],
]) contains(builder, `\"/p:${property}=${value}\"`, `.NET publish does not receive windows/VERSION as ${property}`);
contains(builder, "/p:IncludeSourceRevisionInInformationalVersion=false",
  "informational version can acquire an unverified source suffix");
contains(builder, "[Diagnostics.FileVersionInfo]::GetVersionInfo", "staged executable metadata is not inspected");
contains(builder, "$versionInfo.ProductVersion -cne $Version", "staged product version is not verified");
contains(builder, "$versionInfo.FileVersion -cne \"$Version.0\"", "staged file version is not verified");
contains(builder, "$TestArtifactsRoot = Join-Path $SnapshotTemporaryRoot 'test-artifacts'",
  ".NET test artifacts are not isolated from release inputs");
contains(builder, "Join-Path $SnapshotWindowsRoot 'studio-tests\\CodexDreamSkinStudio.Tests.csproj'",
  "non-SkipTests builder still compiles the live Studio test project");
assert.doesNotMatch(builder, /Join-Path \$WindowsRoot 'studio-tests\\CodexDreamSkinStudio\.Tests\.csproj'/,
  "non-SkipTests builder can create obj/bin under guarded live inputs");
contains(builder, "--artifacts-path $TestArtifactsRoot",
  "non-SkipTests builder can dirty its own required input tree");
const liveTestsIndex = builder.indexOf("Join-Path $WindowsRoot 'tests\\run-tests.ps1'");
const postTestGuardIndex = builder.lastIndexOf("Assert-ReleaseInputsMatchIndex -Paths $releaseInputPaths");
const checkoutIndex = builder.indexOf("git -C $RepoRoot checkout-index --all --force");
const snapshotTestsIndex = builder.indexOf("Join-Path $SnapshotWindowsRoot 'studio-tests\\CodexDreamSkinStudio.Tests.csproj'");
assert.ok(liveTestsIndex >= 0 && postTestGuardIndex > liveTestsIndex && checkoutIndex > postTestGuardIndex &&
  snapshotTestsIndex > checkoutIndex,
"release builder does not guard live test effects before exposing its immutable snapshot");

const releaseTests = read("windows/tests/studio-release.tests.ps1");
for (const regression of [
  "dirty tracked release input",
  "untracked release payload",
  "post-snapshot mutation",
  "outer untracked build customization",
  "codex-dream-skin-studio-release-$($process.Id)-*",
  ".studio-release-$($process.Id)-*",
  "git -C $RepoRoot hash-object --path=windows/assets/theme.json",
  "prepare-never-applied",
  "prepare-already-restored",
  "prepare-missing-codex",
  "prepare-cancellation",
  "prepare-restore-failure",
  "real Studio restore guard changed installed files",
  "real Studio guarded uninstall failed",
]) contains(releaseTests, regression, `Windows release regression is missing: ${regression}`);
const firstRealPrepare = releaseTests.indexOf("prepare-never-applied");
const installedStubOverwrite = releaseTests.indexOf(
  "Copy-Item -LiteralPath $stub -Destination (Join-Path $InstallRoot 'CodexDreamSkinStudio.exe') -Force");
const realStudioRestore = releaseTests.indexOf(
  "Copy-Item -LiteralPath $RealStudioBackup -Destination $InstalledStudio -Force");
assert.ok(firstRealPrepare >= 0 && installedStubOverwrite >= 0 && realStudioRestore > installedStubOverwrite &&
  firstRealPrepare > realStudioRestore,
"installed Studio stub is not confined to an isolated Inno unit check");

const app = read("windows/studio/App.xaml.cs");
contains(app, "e.Args.Length == 1", "argument match is not exact");
contains(app, '"--prepare-uninstall"', "prepare-uninstall argument missing");
contains(app, "Shutdown(1)", "unknown arguments or mutex contention do not fail closed");

const window = read("windows/studio/MainWindow.xaml.cs");
const engineClient = read("windows/studio/EngineClient.cs");
const xaml = read("windows/studio/MainWindow.xaml");
contains(window, "EngineOperation.Uninstall", "existing uninstall operation is not reused");
contains(window, "DispatchAsync", "existing dispatcher is not reused");
contains(window, "Shutdown(exitCode)", "prepare result is not returned to Inno");
contains(window, "Shutdown(_prepareUninstall ? 1 : 0)", "tray exit does not fail closed during prepare-uninstall");
contains(window, "ConfirmPrepareUninstall() && await DispatchAsync(EngineOperation.Uninstall, bypassAvailability: true)",
  "prepare-uninstall does not bypass ordinary preflight and action availability after confirmation");
contains(window, "if (!bypassAvailability && !CanRun(operation)) return false;",
  "prepare-uninstall bypass is not scoped to the dispatcher availability guard");
contains(window, "MessageBoxButton.YesNo", "prepare-uninstall confirmation is not yes/no");
for (const contract of [
  "internal static bool AllowsTermination(bool busy, bool handoffReserved = false) => !busy && !handoffReserved;",
  'Items["exit"]!.Enabled = AllowsTermination(_busy, _handoff.IsActive)',
  "if (!AllowsTermination(_busy, _handoff.IsActive)) return Task.CompletedTask;",
  "if (!_explicitExit && !AllowsTermination(_busy, _handoff.IsActive))",
]) contains(window, contract, `busy termination policy missing: ${contract}`);
assert.doesNotMatch(window, /_operationCancellation\.Cancel\(\)/, "normal UI termination still cancels the engine tree");
for (const contract of [
  "DispatchAsync(EngineOperation.Uninstall, bypassAvailability: true, cancellationToken: cancellationToken)",
  "CancellationToken cancellationToken = default",
  "RunOnceAsync(operation, restartAuthorized, forceAuthorized, deleteUserThemes, cancellationToken)",
  "cancellationToken: cancellationToken",
]) contains(window, contract, `production cancellation chain missing: ${contract}`);
assert.doesNotMatch(window, /cancellationToken:\s*CancellationToken\.None/,
  "production engine invocation discards cancellation");
const cancellationCatch = window.indexOf("catch (OperationCanceledException)");
const dispatchFinally = window.indexOf("finally", cancellationCatch);
const busyRecovery = window.indexOf("_busy = false", dispatchFinally);
assert.ok(cancellationCatch >= 0 && dispatchFinally > cancellationCatch && busyRecovery > dispatchFinally,
  "cancelled production dispatch does not recover UI busy state");
for (const contract of [
  "DefaultOperationTimeout", "CreateLinkedTokenSource(cancellationToken)",
  "CancelAfter(_operationTimeout)",
  "Task.WhenAll(process.WaitForExitAsync(cancellationToken), stdoutTask, stderrTask)",
  "WaitAsync(cancellationToken)", "process.Kill(entireProcessTree: true)",
]) contains(engineClient, contract, `bounded production engine runner missing: ${contract}`);
assert.doesNotMatch(app, /DeleteUserThemes/);

const installScript = read("windows/scripts/install-dream-skin.ps1");
const windowsTests = read("windows/tests/run-tests.ps1");
const studioProtocolTests = read("windows/tests/studio-protocol.tests.ps1");
for (const regression of [
  "start-rollback-identity-lost", "resume-rollback-remove-fail",
  "start-rollback-close-fail", "start-rollback-listener-stuck",
  "start-rollback-remove-fail", "resume-rollback-identity-lost",
  "resume-rollback-close-fail", "resume-rollback-listener-stuck",
]) contains(studioProtocolTests, regression, `Apply/Resume rollback regression missing: ${regression}`);
for (const contract of [
  "foreach ($operation in @('start', 'resume'))",
  '$earlySuccessName = "$operation-early-wait-cleanup-success"',
  '$scenario = "$operation-early-wait-$failure"',
  '$priorFailureName = "$operation-prior-state-fail"',
  "foreach ($failure in @('cleanup-force-fail', 'cleanup-cim-error', 'cleanup-tcp-error'))",
  "start-foreground-new-fail",
  "start-foreground-state-replaced", "start-foreground-success",
  "start-foreground-existing-fail", "start-foreground-existing-identity-replaced",
  "combined-closed-new-foreground-resume-saved-state-replaced",
  "combined-closed-new-foreground-resume-saved-lock-reentry-fail",
  "combined-closed-new-foreground-resume-saved-browser-replaced",
  "foreground-browser-replaced",
  "pause-write:True", "lock-reentry-error",
  "schema4-direct-retry", "schema4-restore-cim-error",
  "schema4-restore-tcp-error", "schema4-restore-absent",
]) contains(studioProtocolTests, contract, `early Apply/Resume matching-host matrix missing: ${contract}`);
for (const regression of [
  "damaged-recovery-restore-absent", "damaged-recovery-uninstall-absent",
  "damaged-recovery-matching-watcher", "damaged-recovery-mismatched-watcher",
  "damaged-recovery-uninspectable-watcher", "damaged-recovery-watcher-appears",
  "damaged-recovery-versioned-watcher", "damaged-recovery-historical-watcher",
  "damaged-recovery-older-codex", "damaged-recovery-uninspectable-codex",
  "damaged-recovery-unmatched-codex",
  "damaged-recovery-residual-listener", "damaged-recovery-tray-like",
  "damaged-recovery-listener-probe-fail", "damaged-recovery-uninspectable-tray",
]) contains(studioProtocolTests, regression, `malformed-state lifecycle regression missing: ${regression}`);
contains(studioProtocolTests, "damaged-recovery-normalized-snapshot",
  "matching-host normalized stable-snapshot quarantine fixture missing");
for (const contract of [
  "foreach ($race in @('replacement', 'same-bytes', 'reparse', 'post-proof'))",
  "foreach ($operation in @('restore', 'uninstall'))",
  '$scenario = "damaged-race-$phase-$race-$operation"',
]) contains(studioProtocolTests, contract, `malformed-state race matrix missing: ${contract}`);
for (const regression of [
  "deep-fresh-wrong-runtime", "deep-official-wrong-runtime",
  "deep-paused-wrong-runtime", "deep-active-wrong-runtime", "deep-missing-runtime",
  "restore-missing-runtime", "uninstall-missing-runtime",
]) contains(studioProtocolTests, regression, `deep runtime regression missing: ${regression}`);
const matchingHostTests = windowsTests + studioProtocolTests;
const studioProgramTests = read("windows/studio-tests/Program.cs");
for (const regression of [
  "malformed-regular-backup", "malformed-regular-marker", "direct-restore-orphan-marker",
  "orphan-archive-marker",
  "real-restore-backup-unlink-fail", "real-restore-archive-marker-publish-fail",
  "real-restore-archive-marker-unlink-fail",
]) contains(studioProtocolTests, regression, `Windows recovery regression is missing: ${regression}`);
for (const fault of [
  "real-restore-backup-unlink-fail", "real-restore-archive-marker-publish-fail",
  "real-restore-archive-marker-unlink-fail",
]) contains(studioProtocolTests, `-Scenario '${fault}' -Arguments`,
  `Windows recovery fault is injected but never exercised: ${fault}`);
contains(windowsTests, "managed-missing-recovery", "direct install missing-recovery regression is absent");
contains(windowsTests, "completion-proof-config-commit-failure",
  "config commit failure does not exercise completion-proof rollback");
contains(windowsTests, "completion-proof-uncertain-config-commit",
  "uncertain config commit does not preserve recovery instead of restoring stale proof");
contains(studioProgramTests, 'mode == "delivery-failure"', "real pipe delivery-failure regression is absent");
for (const regression of [
  "disconnect-active-engine", "active-engine-cancelled", "Production engine invocation ignored its deadline",
  "Production deadline did not reach the process boundary", "Runner cancellation left the controlled grandchild alive",
]) contains(studioProgramTests, regression, `Windows cancellation/deadline regression is missing: ${regression}`);
contains(config, "function Test-DreamSkinLiveConfigBackup", "live config recovery evidence has no shared strict validator");
contains(config, "function Test-DreamSkinRestoreCompleted", "completed restore state has no shared predicate");
contains(config, "completion evidence marker exists without its archive",
  "an orphan archive marker can be classified as never-applied");
contains(config, "$configCommitted = $false", "config transaction does not track config commit");
contains(config, "$configCommitted = $true", "config transaction never records config commit");
contains(config, "$backupCreated -and -not $configCommitted", "marker failure can delete the only recovery backup after config commit");
for (const contract of [
  "function Get-DreamSkinStableFileSnapshot",
  "function Assert-DreamSkinStableFileSnapshotUnchanged",
  "FILE_FLAG_OPEN_REPARSE_POINT",
  "GetFileInformationByHandle",
  "BeginAtomicWrite",
  "FileRenameInfoEx",
  "RollbackConfirmed",
  "VerifyTemporaryContent",
  "HoldMissingPath",
  "public static string NormalizePath",
]) contains(config, contract, `stable config identity contract missing: ${contract}`);
assert.equal((config.match(/Path\.GetFullPath\(/g) || []).length, 1,
  "production config paths still bypass the native long-path normalizer");
assert.match(config, /return absolute \?\? NormalizeAbsolutePath\(Path\.GetFullPath\(path\)\)/,
  "only genuinely relative paths may use legacy GetFullPath");
const atomicStart = config.indexOf("public sealed class AtomicWriteTransaction");
const missingGuardStart = config.indexOf("public sealed class MissingPathGuard", atomicStart);
const atomic = config.slice(atomicStart, missingGuardStart);
assert.doesNotMatch(atomic, /Path\.GetFullPath\(requestedPath\)/,
  "atomic long-path construction still uses legacy GetFullPath before native open");
const comparableStart = config.indexOf("private static string ComparablePath");
const nativePathStart = config.indexOf("public static string NormalizePath", comparableStart);
const pathHelpers = config.slice(comparableStart, config.indexOf("private static void ValidateComponentLength", nativePathStart));
assert.doesNotMatch(pathHelpers, /Substring\(8\)[\s\S]*Path\.GetFullPath|Substring\(4\)[\s\S]*Path\.GetFullPath/,
  "comparable path strips the extended prefix before legacy normalization");
contains(pathHelpers, "NormalizeAbsolutePath", "native path helpers do not share extended absolute normalization");
const candidateCreate = atomic.indexOf("CreateFileW(NormalizePath(candidatePath)");
const candidatePlacement = atomic.indexOf("RenameRelative(temporary, parent, temporaryName, 0)");
const candidateWrite = atomic.indexOf("WriteAll(temporary, bytes");
const candidateVerify = atomic.indexOf("VerifyTemporaryContent()");
assert.ok(candidateCreate >= 0 && candidatePlacement > candidateCreate && candidateWrite > candidatePlacement &&
  candidateVerify > candidateWrite,
  "atomic candidate is not placed in the held parent before exclusive write and read-back verification");
const candidateOpen = atomic.slice(candidateCreate, candidatePlacement);
assert.ok(!candidateOpen.includes("FILE_SHARE_WRITE"), "atomic candidate permits external write mutation");
assert.ok(!candidateOpen.includes("FILE_SHARE_DELETE"),
  "atomic candidate can be renamed or deleted before the final commit decision");
for (const contract of [
  "FILE_TRAVERSE", "FILE_RENAME_FLAG_REPLACE_IF_EXISTS", "FILE_RENAME_FLAG_POSIX_SEMANTICS",
  "FILE_DISPOSITION_FLAG_DELETE", "FILE_DISPOSITION_FLAG_POSIX_SEMANTICS", "NormalizePath",
  "ValidateComponentLength",
]) contains(config, contract, `atomic native contract missing: ${contract}`);
assert.ok(!atomic.includes("rollbackName"),
  "existing-target commit still creates a two-rename canonical-name gap");
assert.match(atomic,
  /RenameRelative\(temporary,\s*parent,\s*fileName,\s*FILE_RENAME_FLAG_REPLACE_IF_EXISTS\s*\|\s*FILE_RENAME_FLAG_POSIX_SEMANTICS\)/,
  "existing target is not published with one POSIX replacement operation");
contains(atomic, "RenameRelative(temporary, parent, fileName, 0)",
  "initially absent target no longer uses a no-replace publication");
const targetOpen = atomic.slice(atomic.indexOf("target = TryOpenStableFile"), candidateCreate);
assert.ok(targetOpen.includes("FILE_SHARE_READ") && !targetOpen.includes("FILE_SHARE_DELETE"),
  "held existing target does not pin its namespace through publication");
const parentOpenStart = atomic.indexOf("parent = OpenStable");
const parentOpen = atomic.slice(parentOpenStart, atomic.indexOf(";", parentOpenStart) + 1);
assert.ok(parentOpen.includes("FILE_TRAVERSE | FILE_READ_ATTRIBUTES") &&
  parentOpen.includes("FILE_SHARE_READ | FILE_SHARE_WRITE") && !parentOpen.includes("FILE_SHARE_DELETE"),
  "held rename root lacks traverse access or permits namespace substitution");
const constructorStart = atomic.indexOf("internal AtomicWriteTransaction");
const constructorTry = atomic.indexOf("try", constructorStart);
const parentAcquire = atomic.indexOf("parent = OpenStable", constructorStart);
const constructorCatch = atomic.indexOf("catch", parentAcquire);
assert.ok(constructorTry >= 0 && constructorTry < parentAcquire && constructorCatch > candidateCreate &&
  atomic.slice(constructorCatch, atomic.indexOf("private void AssertParentUnchanged")).includes("Dispose()"),
  "atomic constructor does not release every acquired handle on early failure");
contains(atomic, "temporaryAtTarget", "Dispose cannot distinguish a committed candidate from an internal temp");
const missingGuard = config.slice(missingGuardStart, config.indexOf("public static AtomicWriteTransaction", missingGuardStart));
for (const contract of ["anchorPath", "firstMissingPath", "FindNearestExistingAncestor"]) {
  contains(missingGuard, contract, `missing-path guard does not hold the nearest existing ancestor: ${contract}`);
}
assert.ok(!missingGuard.includes("private readonly string path;"), "missing-path guard retains dead path state");
contains(missingGuard, "public void Complete()", "missing-path guard has no compensatable completion boundary");
const guardConstructor = missingGuard.indexOf("internal MissingPathGuard");
const guardAcquire = missingGuard.indexOf("anchor = FindNearestExistingAncestor", guardConstructor);
assert.ok(missingGuard.indexOf("try", guardConstructor) < guardAcquire &&
  missingGuard.indexOf("catch", guardAcquire) > guardAcquire,
  "missing-path guard constructor can leak its held ancestor on failure");
contains(config, "public static void DeleteExpectedFile", "completion proof has no identity-bound delete helper");
const proofRemovalStart = config.indexOf("function Remove-DreamSkinConfigCompletionEvidence");
const proofRemovalEnd = config.indexOf("function Get-DreamSkinConfigCompletionEvidenceSnapshots", proofRemovalStart);
const proofRemoval = config.slice(proofRemovalStart, proofRemovalEnd);
contains(proofRemoval, "[DreamSkinConfigNative]::DeleteExpectedFile",
  "completion proof is still invalidated by pathname after validation");
assert.ok(!proofRemoval.includes("Remove-Item"), "completion proof invalidation still deletes a pathname");
const proofRestoreStart = config.indexOf("function Restore-DreamSkinConfigCompletionEvidenceSnapshots");
const proofRestoreEnd = config.indexOf("function Install-DreamSkinBaseTheme", proofRestoreStart);
const proofRestoreBody = config.slice(proofRestoreStart, proofRestoreEnd);
contains(proofRestoreBody, "$current.Identity -ceq $snapshot.Identity",
  "completion proof compensation accepts a same-byte unexpected creator");
assert.ok((config.match(/Get-DreamSkinStableFileSnapshot -Path \$ConfigPath/g) || []).length >= 3,
  "install, selective restore, and exact restore do not snapshot config identity before reading");
assert.ok((config.match(/-ExpectedSnapshot \$configSnapshot/g) || []).length >= 3,
  "install, selective restore, and exact restore do not bind atomic replacement to config identity");
contains(installScript, "$configSnapshot = Get-DreamSkinStableFileSnapshot -Path $ConfigPath",
  "install preflight reads config before establishing its no-reparse identity");
for (const regression of [
  "config-file-symlink-install", "config-file-symlink-selective", "config-file-symlink-exact",
  "config-directory-junction-install", "config-directory-junction-selective", "config-directory-junction-exact",
  "commit-identity-install", "commit-identity-selective", "commit-identity-exact",
  "commit-identity-rollback", "commit-parent-junction-install", "commit-parent-junction-selective",
  "commit-parent-junction-exact", "commit-parent-junction-rollback", "atomic-late-creator",
  "atomic-temp-mutation", "missing-parent-guard", "commit-parent-junction-native-boundary",
  "atomic-existing-posix-replace", "atomic-final-proof-handle-pin", "atomic-posix-rollback",
  "atomic-kill-before-commit", "atomic-kill-after-commit", "atomic-constructor-create-failure-retry",
  "missing-guard-constructor-appearance-retry", "proof-replaced-before-handle-delete",
  "proof-same-bytes-creator-compensation", "missing-config-complete-boundary", "native-long-path",
]) contains(matchingHostTests, regression, `matching-host config trust regression missing: ${regression}`);
contains(windowsTests, "BeginAtomicWrite($nativeLongDirectTarget",
  "matching-host long-path fixture does not preserve its extended path into the atomic constructor");
contains(windowsTests, "BeginAtomicWrite($nativeUncTarget",
  "matching-host UNC fixture does not preserve its extended path into the atomic constructor");
contains(windowsTests, "Write-DreamSkinBytesAtomically -Path $longTarget",
  "matching-host long-path fixture does not exercise the public PowerShell write wrapper");
const longFixtureStart = windowsTests.indexOf("$longPathRoot =");
const longFixtureEnd = windowsTests.indexOf("$overlongComponent =", longFixtureStart);
const longFixture = windowsTests.slice(longFixtureStart, longFixtureEnd);
const nativeLongAssignment = longFixture.indexOf("$nativeLongTarget =");
const nativeLongUse = longFixture.indexOf("[IO.File]::ReadAllBytes($nativeLongTarget)");
assert.ok(nativeLongAssignment >= 0 && nativeLongUse > nativeLongAssignment,
  "matching-host long-path fixture uses its extended target before assignment");
const identityFixtureStart = windowsTests.indexOf("foreach ($identityCase in @(");
const identityFixtureEnd = windowsTests.indexOf("$lateCreatorRoot", identityFixtureStart);
const identityFixture = windowsTests.slice(identityFixtureStart, identityFixtureEnd);
contains(identityFixture, "Attempted = $false; Denied = $false; Replaced = $false; Replacement = $null",
  "identity switch fixture does not record a denied replacement attempt and preserved external source");
contains(identityFixture, "or $identityRejected",
  "identity switch fixture still expects caller rejection after a denied replacement");
const identityCandidateCheck = identityFixture.indexOf("$temporaryExists =");
const identityReplace = identityFixture.indexOf("[IO.File]::Replace($replacement, $raceTarget, $null)");
assert.ok(identityCandidateCheck >= 0 && identityReplace > identityCandidateCheck,
  "identity switch fixture can inject before BeginAtomicWrite has prepared its candidate");
const parentFixtureStart = windowsTests.indexOf("$nativeParentRoot");
const parentFixtureEnd = windowsTests.indexOf("if (-not (Test-DreamSkinWebSocketUrl", parentFixtureStart);
const parentFixture = windowsTests.slice(parentFixtureStart, parentFixtureEnd);
contains(parentFixture, "Attempted = $false; Denied = $false",
  "parent substitution fixture does not record a denied post-BeginAtomicWrite move attempt");
contains(parentFixture, "$candidateExists = $null -ne (Get-ChildItem",
  "parent substitution fixture can inject before BeginAtomicWrite has prepared its candidate");
const parentCandidateCheck = parentFixture.indexOf("$candidateExists = $null -ne (Get-ChildItem");
const parentMove = parentFixture.indexOf("Move-Item -LiteralPath $configDirectory -Destination $heldDirectory", parentCandidateCheck);
assert.ok(parentCandidateCheck >= 0 && parentMove > parentCandidateCheck,
  "parent substitution fixture does not delay its move attempt until the final commit boundary");
const rollbackFixtureStart = windowsTests.indexOf("$rollbackRoot");
const rollbackFixtureEnd = windowsTests.indexOf("$constructorRoot", rollbackFixtureStart);
const rollbackFixture = windowsTests.slice(rollbackFixtureStart, rollbackFixtureEnd);
contains(rollbackFixture, "atomic-posix-rollback final publication marker",
  "rollback fixture does not use a local final-publication marker");
assert.ok(!rollbackFixture.includes("$rollbackSource.Replace($rollbackNeedle"),
  "rollback fixture replaces every AssertCommitted occurrence instead of the final publication proof");
const installBaseStart = config.indexOf("function Install-DreamSkinBaseTheme");
const installBaseEnd = config.indexOf("function Restore-DreamSkinBaseTheme", installBaseStart);
const installBase = config.slice(installBaseStart, installBaseEnd);
const proofSnapshot = installBase.indexOf("Get-DreamSkinConfigCompletionEvidenceSnapshots");
const configPrepare = installBase.indexOf("[DreamSkinConfigNative]::BeginAtomicWrite");
const backupMutation = installBase.indexOf("Write-DreamSkinBytesAtomically -Path $BackupPath");
const proofInvalidation = installBase.indexOf("Remove-DreamSkinConfigCompletionEvidence");
const configCommit = installBase.indexOf("Write-DreamSkinUtf8FileAtomically -Path $ConfigPath");
const installCatch = installBase.indexOf("} catch {");
const configRollbackCheck = installBase.indexOf(
  "$configWrite.RollbackConfirmed", installCatch);
const proofRestore = installBase.indexOf("Restore-DreamSkinConfigCompletionEvidenceSnapshots", installCatch);
assert.ok(proofSnapshot >= 0 && proofSnapshot < configPrepare && configPrepare < backupMutation &&
  proofInvalidation > backupMutation && proofInvalidation < configCommit,
  "completion proof is not snapshotted before mutations and invalidated before config commit");
assert.ok(installCatch > configCommit && proofRestore > installCatch,
  "config commit failure cannot restore the invalidated completion proof");
assert.ok(configRollbackCheck > installCatch && configRollbackCheck < proofRestore,
  "uncertain config commit can restore stale completion proof and discard its recovery backup");
const configCommitted = installBase.indexOf("$configCommitted = $true", configCommit);
const markerPublish = installBase.indexOf("Write-DreamSkinAppearanceMarker", configCommit);
assert.ok(configCommit >= 0 && configCommitted > configCommit && markerPublish > configCommitted,
  "config commit is not recorded before marker publication");

for (const contract of [
  "CreateShortcut($managedShortcutPath)", "ManagedShortcutPath = $managedShortcutPath",
  "UnrelatedShortcutPath = $unrelatedShortcutPath",
  "-DesktopPath (Join-Path $env:DREAM_SKIN_REAL_CASE_ROOT 'desktop')",
]) contains(studioProtocolTests, contract, `real uninstall shortcut fixture is missing: ${contract}`);

contains(restoreScript, "$configBeforeRestoreSnapshot = Get-DreamSkinStableFileSnapshot -Path $config",
  "restore preflight reads config before establishing its no-reparse identity");
contains(restoreScript, "-ExpectedSnapshot $currentConfigSnapshot",
  "restore rollback is not bound to the post-restore config identity");
contains(restoreScript, "config.restored.toml", "restore completion archive is not fixed and retryable");
contains(restoreScript, "$transactionCommitted = $false", "restore transaction has no commit boundary");
contains(restoreScript, "$transactionCommitted = $true", "restore transaction never commits");
contains(restoreScript, "Remove-DreamSkinRecoveryArtifact", "state and paused cleanup are not strict");
contains(restoreScript, "Codex could not be reopened automatically. The restore is complete", "post-commit relaunch failure is not nonfatal");
contains(restoreScript, "Get-DreamSkinRecoveryArtifactSnapshot", "restore cannot roll lifecycle artifacts back exactly");
contains(restoreScript, "Restore-DreamSkinRecoveryArtifactSnapshot", "restore does not restore entry artifacts on failure");
contains(restoreScript, "Publish-DreamSkinConfigBackupArchive", "restore consumes its live backup before publishing completion evidence");
contains(restoreScript, "Test-DreamSkinRestoreCompleted", "direct restore does not share the completed-state predicate");
for (const contract of [
  "$configMissingAtStart = -not $configBeforeRestoreSnapshot.Exists",
  "$suppressFirstRunRelaunch = $RestoreBaseTheme -and $configMissingAtStart",
  "-not $configMissingAtStart",
  "-not $suppressFirstRunRelaunch",
  "$missingConfigGuard.AssertUnchanged()",
  "$missingConfigGuard.Complete()",
]) contains(restoreScript, contract, `missing-config restore contract missing: ${contract}`);
const pauseCommit = restoreScript.indexOf("Remove-DreamSkinRecoveryArtifact -Path (Join-Path $StateRoot 'paused')");
const archiveCommit = restoreScript.indexOf("Publish-DreamSkinConfigBackupArchive");
const markerCleanupToken = "Remove-DreamSkinRecoveryArtifact -Path $backupMarkerPath";
const markerCommit = restoreScript.indexOf(markerCleanupToken, pauseCommit);
const backupCommit = restoreScript.indexOf("Remove-DreamSkinRecoveryArtifact -Path $backup",
  markerCommit + markerCleanupToken.length);
const missingGuardComplete = restoreScript.indexOf("$missingConfigGuard.Complete()", backupCommit);
const exactStateDeleteCommit = restoreScript.indexOf("[DreamSkinConfigNative]::DeleteExpectedFile(", missingGuardComplete);
const statePathGuardComplete = restoreScript.indexOf("$statePathGuard.Complete()", exactStateDeleteCommit);
const committed = restoreScript.indexOf("$transactionCommitted = $true", statePathGuardComplete);
const relaunch = restoreScript.indexOf("Start-Process -FilePath $relaunchCodex.Executable", committed);
assert.ok(archiveCommit >= 0 && pauseCommit > archiveCommit &&
  markerCommit > pauseCommit && backupCommit > markerCommit && missingGuardComplete > backupCommit &&
  exactStateDeleteCommit > missingGuardComplete && statePathGuardComplete > exactStateDeleteCommit &&
  committed > statePathGuardComplete && relaunch > committed,
"restore does not publish proof, stage cleanup, remove live recovery artifacts, commit, then relaunch");

contains(adapter, "$Operation = 'status'", "missing or unknown operation is not normalized to Protocol v1 status");
contains(adapter, "$restoreRecoveryAvailable", "node-free Restore lacks an artifact-backed recovery gate");
contains(adapter, "CODEX_NOT_INSTALLED", "Restore cannot pass a recoverable missing-Codex status");
const studioWindows = read("windows/scripts/studio-windows.ps1");
contains(studioWindows, "StateDamaged = $stateDamaged",
  "malformed-state classification is not available to the adapter");
const studioStatusStart = studioWindows.indexOf("function Get-DreamSkinStudioStatus");
const studioStatusEnd = studioWindows.indexOf("\n}", studioStatusStart) + 2;
const studioStatus = studioWindows.slice(studioStatusStart, studioStatusEnd);
const retainedManagedRecovery = studioStatus.indexOf(
  "$managedCdpRecovery = $null -ne $savedState -and $savedState.schemaVersion -eq 4");
const retainedRecoverySession = studioStatus.indexOf(
  "if ($stateDamaged -or $managedCdpRecovery)", retainedManagedRecovery);
const ordinaryPausedSession = studioStatus.indexOf("if ($pausedMarker)", retainedRecoverySession);
assert.ok(retainedManagedRecovery >= 0 && retainedRecoverySession > retainedManagedRecovery &&
  ordinaryPausedSession > retainedRecoverySession,
  "retained managed-CDP recovery is projected as an ordinary paused Resume session");
const unconditionalRuntime = studioStatus.indexOf(
  "Get-DreamSkinNodeRuntime -NodePath (Join-Path $EngineRoot 'runtime\\node.exe') -ExpectedVersion '22.23.1'");
const statusStateRoot = studioStatus.indexOf("$stateRoot = Join-Path $env:LOCALAPPDATA");
assert.ok(unconditionalRuntime >= 0 && unconditionalRuntime < statusStateRoot,
  "deep status validates the private runtime only for a later session branch");
assert.equal((studioStatus.match(/Get-DreamSkinNodeRuntime/g) || []).length, 1,
  "deep status has conditional or duplicate private-runtime validation");
const lifecycleStatusStart = adapter.indexOf("function Get-DreamSkinLifecycleStatus");
const lifecycleStatusEnd = adapter.indexOf("\n}", lifecycleStatusStart) + 2;
const lifecycleStatus = adapter.slice(lifecycleStatusStart, lifecycleStatusEnd);
contains(lifecycleStatus, "$Operation -notin @('restore', 'uninstall')",
  "Restore/Uninstall lifecycle status still requests deep Node validation");
contains(lifecycleStatus, "Get-DreamSkinStudioStatus -Deep:$deep",
  "lifecycle status does not apply the operation-specific deep validation policy");
contains(studioWindows, "Get-DreamSkinSafeThemeDisplayName", "theme names are not sanitized at the protocol boundary");
contains(studioWindows, "[char]0x2028", "Unicode line separators are not redacted from theme display names");
contains(studioWindows, "Get-DreamSkinStudioRecoveryState", "status and adapter do not share recovery classification");
contains(studioWindows, "Test-DreamSkinLiveConfigBackup", "status treats an unvalidated live backup as recovery evidence");
contains(studioWindows, "Test-DreamSkinRestoreCompleted", "status duplicates or weakens completed-state classification");
contains(studioWindows, "'stale' { $availableActions = @('restore', 'uninstall') }",
  "stale status still advertises Apply or Verify");
contains(studioWindows, "$completed = -not $liveBackupInvalid", "invalid live backup can be classified as completed");
contains(studioWindows, "Test-DreamSkinRestoreCompleted -StateRoot $StateRoot",
  "fixed completion evidence ignores a leftover live backup marker");
contains(studioWindows, "$activeThemePresent = Test-DreamSkinStudioPathEntry -Path $activeThemeRoot",
  "never-applied recovery ignores an orphan active-theme entry");
contains(studioWindows, "$codexProcessRunning = $null -ne $runningCodex",
  "first-run status discards the observed running Codex process");
contains(studioWindows, "$requiresRestart = $codexProcessRunning -and $session -eq 'official'",
  "first-run status does not preserve close authorization");
contains(adapter, "$status.State.codex -eq 'running' -or $status.State.requiresRestart",
  "Restore/Uninstall authorization does not combine observed running state with restart projection");
for (const regression of [
  "running-missing-config", "missing-config-restore-stopped-first", "missing-config-restore-stopped-retry",
  "missing-config-restore-running-unauthorized", "missing-config-restore-running-authorized",
  "missing-config-uninstall-stopped-first", "missing-config-uninstall-stopped-retry",
  "missing-config-uninstall-running-unauthorized", "missing-config-uninstall-running-authorized",
]) contains(studioProtocolTests, regression, `missing-config lifecycle regression missing: ${regression}`);
contains(studioProtocolTests, "retained-schema4-paused-status-resume",
  "sequential retained schema-4 status-to-Resume refusal fixture missing");

for (const contract of [
  'x:Name="RefreshButton"', 'Click="RefreshButton_Click"',
  'x:Name="VerifyButton"', 'Click="VerifyButton_Click"',
]) contains(xaml, contract, `Windows UI control missing: ${contract}`);
for (const contract of [
  "RefreshButton.IsEnabled", "VerifyButton.IsEnabled", "RefreshButton_Click", "VerifyButton_Click",
  "DispatchAsync(EngineOperation.Verify)", "RefreshStatusAsync()", "_confirming = true",
]) contains(window, contract, `Windows UI dispatcher/busy contract missing: ${contract}`);
const uninstallStart = window.indexOf("UninstallButton_Click");
const uninstallHandler = window.slice(uninstallStart, window.indexOf("ShowSafeOperationFailure", uninstallStart));
assert.match(uninstallHandler, /_confirming = true[\s\S]*ShowDialog\(\)[\s\S]*finally[\s\S]*_confirming = false/,
  "uninstall modal does not hold confirmation policy for its full lifetime");

const coordinatorPath = path.join(repo, "windows/studio/SingleInstanceCoordinator.cs");
assert.ok(fs.existsSync(coordinatorPath), "per-user single-instance IPC coordinator is missing");
const coordinator = fs.existsSync(coordinatorPath) ? fs.readFileSync(coordinatorPath, "utf8") : "";
for (const contract of [
  "NamedPipeServerStream", "NamedPipeClientStream", "PipeOptions.CurrentUserOnly",
  '"activate"', '"prepare-uninstall"', "OwnerProcessId", "WaitForExit", "CancellationTokenSource",
  "RequestReadTimeout", "MonitorClientDisconnectAsync", "responseTimeout",
]) contains(coordinator, contract, `single-instance handoff missing: ${contract}`);
contains(app, "SingleInstanceCoordinator", "App startup does not use the IPC coordinator");
contains(app, "prepareUninstall ? null : TimeSpan.FromSeconds(15)",
  "interactive prepare-uninstall still has activation's short response deadline");
contains(window, "ActivateFromSecondInstance", "existing owner cannot activate from a second launch");
contains(window, "PrepareUninstallFromOwnerAsync", "existing owner cannot perform delegated uninstall");
contains(window, "TryReserveHandoff", "owner promises release without synchronously reserving the UI");
contains(window, "CancelHandoffReservation", "failed response delivery cannot cancel the handoff reservation");

contains(inno, "VersionInfoVersion={#AppVersion}.0", "setup FileVersion is not derived from windows/VERSION");
contains(inno, "VersionInfoProductVersion={#AppVersion}.0", "setup ProductVersion is not derived from windows/VERSION");
contains(inno, "VersionInfoProductTextVersion={#AppVersion}", "setup textual ProductVersion is not derived from windows/VERSION");
contains(builder, "$setupVersionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($setupPath)",
  "matching-host builder does not inspect setup PE metadata");
contains(builder, "$setupProductVersion -notin @($Version, \"$Version.0\")",
  "setup ProductVersion does not accept only the equivalent text and binary forms");
contains(builder, "$setupVersionInfo.FileVersion -cne \"$Version.0\"", "setup FileVersion is not verified");
const pinnedSetupIndex = builder.indexOf("[DreamSkinReleaseFilePin]::Open($setupPath, $false)");
const pinnedSetupSignatureIndex = builder.indexOf("Assert-FileSignature -Path $setupPath", pinnedSetupIndex);
const pinnedSetupVersionIndex = builder.indexOf("$setupVersionInfo =", pinnedSetupSignatureIndex);
assert.ok(pinnedSetupIndex >= 0 && pinnedSetupSignatureIndex > pinnedSetupIndex &&
  pinnedSetupVersionIndex > pinnedSetupSignatureIndex,
"setup signature and metadata are not checked while pathname replacement is denied");

const status = read("windows/scripts/status-dream-skin.ps1");
const protocol = read("windows/studio/EngineProtocol.cs");
contains(adapter, "@('STATE_UNSAFE', 'RUNTIME_INVALID', 'CODEX_NOT_INSTALLED', 'CODEX_FIRST_RUN_REQUIRED')",
  "uninstall recovery does not admit recoverable status errors");
contains(adapter, "$status.State.install -eq 'not-installed' -and $status.State.session -eq 'official'",
  "already-restored uninstall is not idempotent");
assert.doesNotMatch(adapter, /\$Operation -eq 'uninstall' -and \$postStatus\.State\.codex -ne 'stopped'/,
  "missing Codex still blocks a completed uninstall");
contains(status, "DREAM_SKIN_PROGRESS=checking", "status progress format is not canonical");
contains(adapter, "DREAM_SKIN_PROGRESS=$progress", "adapter progress format is not canonical");
contains(protocol, 'const string prefix = "DREAM_SKIN_PROGRESS="', "C# progress parser is not canonical");
for (const [name, source] of [["status", status], ["adapter", adapter], ["protocol", protocol]]) {
  assert.doesNotMatch(source, /DREAM_SKIN_PROGRESS /, `${name} still accepts or emits legacy progress`);
}
const liveRemoveRecoveries = [...adapter.matchAll(/-Code 'LIVE_REMOVE_FAILED'[\s\S]*?-RecoveryActions @\(([^)]*)\)/g)]
  .map((match) => match[1].replace(/\s/g, ""));
assert.equal(liveRemoveRecoveries.length, 2, "both live-remove failure paths must be explicit");
assert.deepEqual(liveRemoveRecoveries, ["'restore','diagnostics','cancel'", "'restore','diagnostics','cancel'"],
  "live-remove failure advertises an unusable retry");

const fetchRuntime = read("windows/scripts/fetch-node-runtime.ps1");
const scanner = read("studio/release/check-contents.mjs");
const releaseSecurityFailures = [];
const releaseSecurityContract = (name, check) => {
  try {
    check();
  } catch (error) {
    releaseSecurityFailures.push(`${name}: ${error.message}`);
  }
};

releaseSecurityContract("C1 stage-to-ISCC identity", () => {
  contains(inno, "#include StageFilesManifest", "Inno does not consume the explicit held file manifest");
  assert.doesNotMatch(inno, /Source:\s*"\{#StageRoot\}\\\\\*"/,
    "Inno still recursively reopens a wildcard stage");
  for (const contract of [
    "DreamSkinReleaseTreePin", "Write-InnoFileManifest", "manifestPin", "innoSourcePin", "scannerPin",
    "$stagePins.AssertUnchanged($StageRoot)",
    "stage-after-scan", "stage-adapter-replacement-denied", "manifest-before-iscc",
  ]) contains(builder, contract, `stage identity contract missing: ${contract}`);
  const pinStage = builder.indexOf("[DreamSkinReleaseTreePin]::Open($StageRoot)");
  const scanStage = builder.indexOf("--root $StageRoot", pinStage);
  const compileSetup = builder.indexOf("& $InnoSetup $innoArguments", scanStage);
  const recheckStage = builder.indexOf("$stagePins.AssertUnchanged($StageRoot)", compileSetup);
  assert.ok(pinStage >= 0 && scanStage > pinStage && compileSetup > scanStage && recheckStage > compileSetup,
    "stage pins do not span scanner, ISCC, and the post-ISCC identity/hash proof");
  for (const regression of [
    "stage-adapter-replacement-denied", "stage replacement race replaced prior release",
    "manifest-replacement-denied", "manifest replacement race replaced prior release",
  ]) {
    contains(releaseTests, regression, `stage replacement regression missing: ${regression}`);
  }
});

releaseSecurityContract("C1 setup publication identity", () => {
  for (const contract of [
    "DreamSkinReleaseFilePin", "$setupPin", "$movableSetupPin", "$finalSetupPin",
    "setup-after-signature", "setup-replacement-denied", "Assert-ReleaseMetadata",
  ]) contains(builder, contract, `setup identity contract missing: ${contract}`);
  const setupPin = builder.indexOf("[DreamSkinReleaseFilePin]::Open($setupPath, $false)");
  const setupSignature = builder.indexOf("Assert-FileSignature -Path $setupPath", setupPin);
  const setupHash = builder.indexOf("$setupPin.Sha256", setupSignature);
  const setupMetadata = builder.indexOf("Assert-ReleaseMetadata", setupHash);
  const publishMove = builder.indexOf("[IO.Directory]::Move($PublishRoot, $ReleaseRoot)", setupMetadata);
  const finalPin = builder.indexOf("[DreamSkinReleaseFilePin]::Open($finalSetupPath, $false)", publishMove);
  const finalMetadata = builder.indexOf("Assert-ReleaseMetadata", finalPin);
  assert.ok(setupPin >= 0 && setupSignature > setupPin && setupHash > setupSignature &&
    setupMetadata > setupHash && publishMove > setupMetadata && finalPin > publishMove &&
    finalMetadata > finalPin,
  "one proven setup object does not span signature, hash, metadata, and final publication checks");
  for (const regression of ["setup-replacement-denied", "setup replacement race replaced prior release"]) {
    contains(releaseTests, regression, `setup replacement regression missing: ${regression}`);
  }
});

releaseSecurityContract("C2 one-open Node archive", () => {
  contains(fetchRuntime, "$archiveStream = [IO.File]::Open", "Node archive is not opened once as a stream");
  contains(fetchRuntime, "[IO.FileShare]::Read", "Node archive stream does not deny write/delete sharing");
  contains(fetchRuntime, "[IO.Compression.ZipArchive]::new($archiveStream",
    "Node extraction does not consume the hashed stream");
  contains(fetchRuntime, "$entry.Open()", "Node payload is not extracted from ZipArchive entries");
  assert.doesNotMatch(fetchRuntime, /Get-FileHash[^\r\n]*\$runtimeArchivePath|Expand-Archive/,
    "Node verification and extraction still reopen the archive pathname");
  contains(windowsTests, 'foreach ($mode in @(\'offline\', \'download\'))',
    "Node replacement regression does not exercise both archive branches");
  contains(windowsTests, 'node-$mode-replace-after-hash',
    "Node replacement regression does not retain a deterministic post-hash scenario");
});

releaseSecurityContract("I1 aggregate release isolation", () => {
  assert.doesNotMatch(windowsTests,
    /&\s*\(Join-Path \$PSScriptRoot 'studio-release\.tests\.ps1'\)/,
    "the aggregate gate still invokes the release-producing test");
  for (const regression of [
    "protected production release changed", "forced-post-test-release-failure",
    "post-test outer builder failure changed production release",
  ]) contains(releaseTests, regression, `aggregate isolation regression missing: ${regression}`);
});

releaseSecurityContract("I2 actual builder setup install", () => {
  contains(builder, "TestOnlyToken", "builder has no strictly gated isolated test AppId");
  contains(releaseTests, "$BuilderTestArguments", "release test does not invoke the test-gated real builder");
  contains(releaseTests, "Invoke-TestProcess $Setup", "release test does not install the builder-produced setup");
  assert.doesNotMatch(releaseTests, /\$TestSetup\b|Isolated Inno test installer compilation failed|& \$InnoSetup \$compileArguments/,
    "release test still recompiles and installs a different setup");
  contains(releaseTests, "production setup payload mismatch",
    "actual production setup payload is not hashed and scanned after install");
  contains(builder, "payload-fault-omit-engine-adapter", "builder has no gated payload omission seam");
  contains(releaseTests, "payload-fault-omit-engine-adapter", "release test does not exercise the omitted-payload negative case");
  contains(releaseTests, "faulty builder-produced setup", "release test does not install the faulty builder setup");
});

releaseSecurityContract("I3 immutable same-version target", () => {
  contains(inno, "function IsDirectoryEmpty", "Inno cannot distinguish a nonempty same-version target");
  contains(inno, "function InitializeSetup", "Inno does not reject a nonempty same-version target before writes");
  contains(inno, "same-version target directory is not empty", "same-version refusal is not explicit");
  contains(inno, "Abort", "same-version refusal does not terminate setup with a failure code");
  for (const regression of [
    "same-version reinstall changed original tree", "running same-version reinstall changed original tree",
    "running-private-node same-version reinstall changed original tree",
  ]) contains(releaseTests, regression, `same-version collision regression missing: ${regression}`);
});

releaseSecurityContract("I4 Windows floor", () => {
  assert.match(inno, /^MinVersion=10\.0\.17763$/m,
    "Inno does not enforce the WPF Windows 10 build 17763 floor");
});

releaseSecurityContract("I5 exact asset stage", () => {
  assert.doesNotMatch(builder, /Join-Path \$SnapshotWindowsRoot 'assets\\\\\*'/,
    "builder still stages assets through a wildcard");
  for (const asset of ["dream-reference.jpg", "dream-skin.css", "renderer-inject.js", "theme.json"]) {
    contains(builder, `'${asset}'`, `explicit staged asset missing: ${asset}`);
  }
  for (const regression of ["extra .env asset entered release", "staged asset set is not exact"]) {
    contains(releaseTests, regression, `asset allowlist regression missing: ${regression}`);
  }
});

releaseSecurityContract("I6 mixed Windows user paths", () => {
  contains(scanner, String.raw`const WINDOWS_USER_PATH_RE = /[A-Za-z]:[\\/]Users[\\/]`,
    "scanner has no drive/user regex accepting both separators");
  assert.match(scanner, /WINDOWS_USER_PATH_RE\s*=\s*\/[^\n]+\/i;/,
    "Windows drive/user scan is not case-insensitive");
  for (const fixture of ["windows-user-path-latin1", "windows-user-path-utf16le"]) {
    contains(read("macos/tests/studio-release.test.sh"), fixture,
      `shared scanner fixture missing: ${fixture}`);
  }
});

releaseSecurityContract("I7 release metadata truth", () => {
  contains(builder, "sourceTree = $IndexTree", "release manifest omits the immutable index tree");
  contains(builder, "function Assert-ReleaseMetadata", "builder has no strict metadata verifier");
  assert.ok((builder.match(/Assert-ReleaseMetadata/g) || []).length >= 3,
    "metadata is not verified before and after publication");
  for (const contract of [
    "schemaVersion,version,architecture,signing,file,sha256,sourceTree",
    "exactly one checksum entry", "fresh setup SHA-256",
  ]) contains(builder, contract, `strict metadata contract missing: ${contract}`);
  for (const regression of [
    "manifest-schemaVersion-mutation", "manifest-version-mutation", "manifest-architecture-mutation",
    "manifest-signing-mutation", "manifest-file-mutation", "manifest-sha256-mutation",
    "manifest-sourceTree-mutation", "manifest-extra-key-mutation", "checksum-hash-mutation",
    "checksum-file-mutation", "checksum-extra-entry-mutation", "setup-byte-mutation",
  ]) contains(releaseTests, regression, `metadata mutation regression missing: ${regression}`);
});

assert.deepEqual(releaseSecurityFailures, [],
  `Windows release/security contracts failed:\n${releaseSecurityFailures.join("\n")}`);

console.log("PASS: Windows Studio release contracts verified.");
