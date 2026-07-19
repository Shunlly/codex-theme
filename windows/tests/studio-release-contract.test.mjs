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
for (const contract of [
  "[ValidateSet('x64', 'arm64')]", "fetch-node-runtime.ps1", "--self-contained", "check-contents.mjs",
  "allowlist-windows.json", "WINDOWS_SIGN_CERT_THUMBPRINT", "Get-AuthenticodeSignature", "SHA256SUMS.txt",
  "UNSIGNED", "[IO.Directory]::Move", "/p:ApplicationIcon=", "RuntimeInformation]::OSArchitecture",
  "Windows Studio releases require a matching X64 or Arm64 build host.",
]) contains(builder, contract, `builder contract missing: ${contract}`);
assert.doesNotMatch(builder, /studio-release-contract\.test\.mjs/, "builder duplicates the aggregate portable contract gate");
for (const contract of [
  "function Test-DreamSkinPathEntry",
  "function Remove-DreamSkinUserThemeData",
  "$appearanceMarker = Get-DreamSkinAppearanceMarkerPath -BackupPath $restoreBackup",
  "$status.State.codex -ne 'running'",
  "Assert-DreamSkinNoReparseComponents -Path $stateRoot",
  "foreach ($path in @($restoreBackup, $appearanceMarker, $statePath, $pausedPath))",
  "Assert-DreamSkinNoReparseComponents -Path $path",
  "Test-DreamSkinPathEntry -Path $path",
]) contains(adapter, contract, `uninstall recovery proof is missing: ${contract}`);
assert.equal((adapter.match(/Remove-DreamSkinUserThemeData -StateRoot \$stateRoot/g) || []).length, 2,
  "ordinary and already-restored uninstall do not share theme deletion");
assert.doesNotMatch(adapter, /Test-Path -LiteralPath \$restoreBackup -PathType Leaf/,
  "a non-file backup entry can be mistaken for completed restoration");
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
  "internal static bool AllowsTermination(bool busy) => !busy;",
  'Items["exit"]!.Enabled = AllowsTermination(_busy)',
  "if (!AllowsTermination(_busy)) return Task.CompletedTask;",
  "if (!_explicitExit && !AllowsTermination(_busy))",
]) contains(window, contract, `busy termination policy missing: ${contract}`);
assert.doesNotMatch(window, /_operationCancellation\.Cancel\(\)/, "normal UI termination still cancels the engine tree");
assert.doesNotMatch(app, /DeleteUserThemes/);

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
