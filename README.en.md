# Codex Dream Skin

<p align="center">
  <a href="./README.md">中文</a> · <strong>English</strong>
</p>

<p align="center">
  A reversible, interactive full-window theme for Codex Desktop.<br>
  Local CDP injection without modifying the official <code>.app</code>, <code>app.asar</code>, or WindowsApps package.
</p>

> Unofficial and not affiliated with OpenAI. Current downloads are unsigned test builds, not production-trusted releases.

## Download

Test installers are published on [GitHub Releases](https://github.com/Shunlly/codex-theme/releases):

| Platform | File | Status |
| --- | --- | --- |
| Apple Silicon / Intel Mac | `CodexDreamSkinStudio-1.3.1-macos-universal-ADHOC.dmg` | ad-hoc signed, not notarized |
| Windows x64 | `CodexDreamSkinStudio-1.3.1-win-x64-UNSIGNED.exe` | unsigned installer |
| Windows arm64 | Not available yet | requires a native Windows arm64 build host |

macOS may report that the developer cannot be verified, and Windows may show a SmartScreen warning. The filenames retain `ADHOC` / `UNSIGNED` until Developer ID, notarization, Authenticode, and SmartScreen acceptance are complete.

## What It Does

- Keeps the native Codex sidebar, project picker, cards, composer, and task interactions.
- Places one continuous wallpaper behind home and task routes, with quieter task-page treatment.
- Studio provides preflight, install, apply, verify, Pause, restore, and uninstall.
- The macOS menu bar and Windows tray retain advanced image import, save, and local theme switching.
- Complete Restore removes the live injection and closes managed CDP.

<p align="center">
  <img src="docs/images/presets/romantic-rose-light.jpg" alt="Real light theme preview" width="860"><br>
  <sub>Light · real Codex home screen with interactive native controls</sub>
</p>

<p align="center">
  <img src="docs/images/presets/romantic-rose-dark.jpg" alt="Real dark theme preview" width="860"><br>
  <sub>Dark · the same theme adapting automatically</sub>
</p>

These screenshots are previews, not importable backgrounds. Import UI-free art with no window, sidebar, text, logo, or watermark. See the [background prompt guide](./docs/reference-background-prompt-guide.en.md) for composition templates.

## Quick start

No trusted Studio binary is currently claimed as published or accepted. The current Release contains unsigned test builds. After a production release, canonical artifacts will use names such as `CodexDreamSkinStudio.dmg` and `CodexDreamSkinStudio-1.3.1-win-x64.exe` without test labels.

1. Download the test installer for your platform from [Releases](https://github.com/Shunlly/codex-theme/releases), then open it.
2. On first launch, Studio runs preflight, automatically installs and applies the bundled default theme, then waits for strict verified success; authorize one Codex restart only when Studio requests it.
3. Wait for strict verified success. Use **Pause** for temporary soft-off and **Complete Restore** to restore the stock appearance and close managed CDP.

Ordinary use needs no Terminal, PowerShell, Homebrew, global Node, administrator elevation, or manual config editing. Install and open the official Codex Desktop app at least once before first use.

### Advanced recovery

If something looks stuck, use **Pause** first and then **Complete Restore**. Do not manually delete state, backup, or theme directories. Use the platform guides for further recovery:

- [macOS usage and recovery](./macos/README.md)
- [Windows usage and recovery](./windows/SKILL.md)
- [Platform paths and capabilities](./docs/platforms.md)

## Current Scope

Milestone 1 native Studio handles reliable lifecycle operations only. The current build does not include theme-package sharing, workspace scenes/bindings, context profiles, or motion/video backgrounds.

The next milestone prioritizes `.cdxtheme`: one-file theme export, import, and sharing with provenance, version, and compatibility metadata. Do not send friends the entire engine directory.

## Safety Boundary

- CDP binds only to `127.0.0.1`. It is not exposed to the LAN, but has no extra same-user authentication.
- Official Codex binaries, install directories, signatures, threads, and authentication data remain unchanged.
- The project does not read or rewrite `auth.json`, API keys, Base URLs, or model-provider settings.
- Config writes use strict UTF-8, backups, atomic replacement, and recoverable transactions.
- Pause leaves CDP open; use Complete Restore when you are finished.

## Development and Builds

```bash
# macOS tests
cd macos && npm test

# macOS unsigned test DMG
/bin/bash macos/scripts/build-studio-release.sh --adhoc

# Windows tests (Windows PowerShell 5.1)
powershell -NoProfile -File windows/tests/run-tests.ps1

# Windows x64 unsigned test installer (.NET 8 + Inno Setup 6 required)
powershell -NoProfile -File windows/scripts/build-studio-release.ps1 -Architecture x64 -SkipSign
```

Pushing a tag such as `v1.3.1-test.1` runs the [test-release workflow](./.github/workflows/test-release.yml), builds the DMG and EXE with SHA-256 files and release manifests, and creates a GitHub pre-release.

## More

- [Optional user themes](./user-themes/)
- [Concept gallery and prompts](./docs/background-generation-prompts.md)
- [Studio protocol](./studio/protocol/README.md)
- [Project notes](./docs/PROJECT.md)
- [Issue templates](./.github/ISSUE_TEMPLATE/)

## License

Project code is MIT licensed; see [`macos/LICENSE`](./macos/LICENSE). People, IP, presets, and preview assets do not receive automatic redistribution rights from the code license. Confirm likeness, asset, and trademark rights before redistribution.
