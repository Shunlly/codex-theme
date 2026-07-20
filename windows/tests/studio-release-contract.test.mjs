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
const skipUninstallStart = adapter.indexOf("if ($canSkipCompletedUninstall)");
const skipUninstallEnd = adapter.indexOf("if (($Operation -eq 'restore'", skipUninstallStart);
const skipUninstall = adapter.slice(skipUninstallStart, skipUninstallEnd);
contains(skipUninstall, legacyShortcutCleanup,
  "already-restored and never-applied uninstall skip legacy shortcut cleanup");
assert.doesNotMatch(skipUninstall, /Invoke-DreamSkinLifecycleChild|Restore-DreamSkin/,
  "completed uninstall reruns config restore instead of cleanup only");
const restoreScript = read("windows/scripts/restore-dream-skin.ps1");
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

const config = read("windows/scripts/config-utf8.ps1");
const installScript = read("windows/scripts/install-dream-skin.ps1");
const windowsTests = read("windows/tests/run-tests.ps1");
const studioProtocolTests = read("windows/tests/studio-protocol.tests.ps1");
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
]) contains(config, contract, `stable config identity contract missing: ${contract}`);
assert.ok((config.match(/Get-DreamSkinStableFileSnapshot -Path \$ConfigPath/g) || []).length >= 3,
  "install, selective restore, and exact restore do not snapshot config identity before reading");
assert.ok((config.match(/-ExpectedSnapshot \$configSnapshot/g) || []).length >= 3,
  "install, selective restore, and exact restore do not bind atomic replacement to config identity");
contains(installScript, "$configSnapshot = Get-DreamSkinStableFileSnapshot -Path $ConfigPath",
  "install preflight reads config before establishing its no-reparse identity");
for (const regression of [
  "config-file-symlink-install", "config-file-symlink-selective", "config-file-symlink-exact",
  "config-directory-junction-install", "config-directory-junction-selective", "config-directory-junction-exact",
  "same-byte-identity-install", "same-byte-identity-selective", "same-byte-identity-exact",
  "same-byte-identity-rollback",
]) contains(windowsTests, regression, `matching-host config trust regression missing: ${regression}`);
const configCommit = config.indexOf("Write-DreamSkinUtf8FileAtomically -Path $ConfigPath");
const configCommitted = config.indexOf("$configCommitted = $true", configCommit);
const markerPublish = config.indexOf("Write-DreamSkinAppearanceMarker", configCommit);
assert.ok(configCommit >= 0 && configCommitted > configCommit && markerPublish > configCommitted,
  "config commit is not recorded before marker publication");

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
]) contains(restoreScript, contract, `missing-config restore contract missing: ${contract}`);
const stateCommit = restoreScript.indexOf("Remove-DreamSkinRecoveryArtifact -Path $StatePath");
const pauseCommit = restoreScript.indexOf("Remove-DreamSkinRecoveryArtifact -Path (Join-Path $StateRoot 'paused')");
const archiveCommit = restoreScript.indexOf("Publish-DreamSkinConfigBackupArchive");
const markerCleanupToken = "Remove-DreamSkinRecoveryArtifact -Path $backupMarkerPath";
const markerCommit = restoreScript.indexOf(markerCleanupToken, pauseCommit);
const backupCommit = restoreScript.indexOf("Remove-DreamSkinRecoveryArtifact -Path $backup",
  markerCommit + markerCleanupToken.length);
const committed = restoreScript.indexOf("$transactionCommitted = $true", backupCommit);
const relaunch = restoreScript.indexOf("Start-Process -FilePath $relaunchCodex.Executable", committed);
assert.ok(archiveCommit >= 0 && stateCommit > archiveCommit && pauseCommit > stateCommit &&
  markerCommit > pauseCommit && backupCommit > markerCommit && committed > backupCommit && relaunch > committed,
"restore does not publish proof, stage cleanup, remove live recovery artifacts, commit, then relaunch");

contains(adapter, "$Operation = 'status'", "missing or unknown operation is not normalized to Protocol v1 status");
contains(adapter, "$restoreRecoveryAvailable", "node-free Restore lacks an artifact-backed recovery gate");
contains(adapter, "CODEX_NOT_INSTALLED", "Restore cannot pass a recoverable missing-Codex status");
const studioWindows = read("windows/scripts/studio-windows.ps1");
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
contains(adapter, "$status.State.requiresRestart -and -not $RestartAuthorized",
  "Restore/Uninstall authorization is still coupled to the codex display state");
for (const regression of [
  "running-missing-config", "missing-config-restore-stopped-first", "missing-config-restore-stopped-retry",
  "missing-config-restore-running-unauthorized", "missing-config-restore-running-authorized",
  "missing-config-uninstall-stopped-first", "missing-config-uninstall-stopped-retry",
  "missing-config-uninstall-running-unauthorized", "missing-config-uninstall-running-authorized",
]) contains(studioProtocolTests, regression, `missing-config lifecycle regression missing: ${regression}`);

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
contains(builder, "$setupVersionInfo.ProductVersion -cne $Version", "setup ProductVersion is not verified");
contains(builder, "$setupVersionInfo.FileVersion -cne \"$Version.0\"", "setup FileVersion is not verified");
assert.ok(builder.indexOf("$setupVersionInfo =", builder.indexOf("$setupPath =")) <
  builder.indexOf("Sign-And-Verify -Path $setupPath"), "setup metadata is checked only after signing/publication");

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

console.log("PASS: Windows Studio release contracts verified.");
