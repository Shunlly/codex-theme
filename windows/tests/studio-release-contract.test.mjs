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
for (const contract of [
  "[ValidateSet('x64', 'arm64')]", "fetch-node-runtime.ps1", "--self-contained", "check-contents.mjs",
  "allowlist-windows.json", "WINDOWS_SIGN_CERT_THUMBPRINT", "Get-AuthenticodeSignature", "SHA256SUMS.txt",
  "UNSIGNED", "[IO.Directory]::Move", "/p:ApplicationIcon=", "RuntimeInformation]::OSArchitecture",
  "Windows Studio releases require a matching X64 or Arm64 build host.",
]) contains(builder, contract, `builder contract missing: ${contract}`);

const app = read("windows/studio/App.xaml.cs");
contains(app, "e.Args.Length == 1", "argument match is not exact");
contains(app, '"--prepare-uninstall"', "prepare-uninstall argument missing");
contains(app, "Shutdown(1)", "unknown arguments or mutex contention do not fail closed");

const window = read("windows/studio/MainWindow.xaml.cs");
contains(window, "EngineOperation.Uninstall", "existing uninstall operation is not reused");
contains(window, "DispatchAsync", "existing dispatcher is not reused");
contains(window, "Shutdown(exitCode)", "prepare result is not returned to Inno");
contains(window, "Shutdown(_prepareUninstall ? 1 : 0)", "tray exit does not fail closed during prepare-uninstall");
contains(window, "if (success && ConfirmPrepareUninstall())", "prepare-uninstall skips its initial confirmation");
contains(window, "MessageBoxButton.YesNo", "prepare-uninstall confirmation is not yes/no");
assert.doesNotMatch(app, /DeleteUserThemes/);

console.log("PASS: Windows Studio release contracts verified.");
