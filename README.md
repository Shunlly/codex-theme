# Codex Dream Skin

<p align="center">
  <strong>中文</strong> · <a href="./README.en.md">English</a>
</p>

<p align="center">
  给 Codex Desktop 换上可恢复、可交互的全窗主题。<br>
  本机 CDP 注入，不修改官方 <code>.app</code>、<code>app.asar</code> 或 WindowsApps。
</p>

> 非 OpenAI 官方项目。当前下载是未签名测试版，只适合测试，不代表生产信任验收。

## 下载

测试版安装包放在 [GitHub Releases](https://github.com/Shunlly/codex-theme/releases)：

| 平台 | 文件 | 状态 |
| --- | --- | --- |
| Apple Silicon / Intel Mac | `CodexDreamSkinStudio-1.3.1-macos-universal-ADHOC.dmg` | ad-hoc 签名，未公证 |
| Windows x64 | `CodexDreamSkinStudio-1.3.1-win-x64-UNSIGNED.exe` | 未签名安装器 |
| Windows arm64 | 暂无 | 需要原生 arm64 Windows 构建机 |

macOS 可能显示开发者无法验证；Windows 可能显示 SmartScreen 警告。这些文件名会一直保留 `ADHOC` / `UNSIGNED`，直到真正完成 Developer ID、公证、Authenticode 和 SmartScreen 验收。

## 它能做什么

- 保留 Codex 原生侧栏、项目选择、卡片、输入框和任务交互。
- 用一张纯背景图连续覆盖首页和任务页，任务页自动降低干扰。
- Studio 提供 preflight、安装、应用、验证、Pause、恢复和卸载。
- macOS 菜单栏和 Windows 托盘继续提供换图、保存与切换本地主题。
- Complete Restore 可以移除实时注入并关闭受管 CDP。

<p align="center">
  <img src="docs/images/presets/romantic-rose-light.jpg" alt="浅色主题真实效果" width="860"><br>
  <sub>浅色 · 真实 Codex 首页；原生控件仍可交互</sub>
</p>

<p align="center">
  <img src="docs/images/presets/romantic-rose-dark.jpg" alt="暗色主题真实效果" width="860"><br>
  <sub>暗色 · 同一主题自动适配</sub>
</p>

截图只作预览，不能作为背景导入。可导入的素材必须是无窗口、无侧栏、无文字、无 Logo 的纯背景图；构图模板见[背景生成指南](./docs/reference-background-prompt-guide.md)。

## 快速开始

当前仓库不声称已有通过生产信任验收的 Studio 二进制发布。当前 Release 是方便测试的未签名构建；生产发布完成后，正式文件会使用 `CodexDreamSkinStudio.dmg`、`CodexDreamSkinStudio-1.3.1-win-x64.exe` 等不带测试标记的名称。

1. 从 [Releases](https://github.com/Shunlly/codex-theme/releases) 下载对应平台的测试安装包并打开。
2. 首次打开后，Studio 会完成 preflight，自动安装并应用内置默认主题，然后执行严格验证；仅在 Codex 正在运行且 Studio 明确请求时授权一次重启。
3. 等待严格验证成功。用 **Pause** 临时关闭主题，用 **Complete Restore** 恢复官方外观并关闭受管 CDP。

普通使用不需要 Terminal、PowerShell、Homebrew、全局 Node、管理员权限或手动编辑配置。首次运行前，请先安装并至少打开一次官方 Codex Desktop。

### 高级恢复

遇到异常时，先使用 **Pause**，再使用 **Complete Restore**。不要手动删除状态、备份或主题目录；需要进一步处理时按平台文档执行：

- [macOS 使用与恢复](./macos/README.md)
- [Windows 使用与恢复](./windows/SKILL.md)
- [平台路径与能力对照](./docs/platforms.md)

## 当前边界

Milestone 1 的原生 Studio 只负责可靠的生命周期操作。主题包分享、工作区场景/绑定、上下文配置档和动态/视频背景还没有进入当前版本。

下一阶段会优先实现 `.cdxtheme`：一个文件导出、导入和分享主题，同时保留素材来源、版本和兼容性信息。现在不要把整个引擎目录发给朋友。

## 安全边界

- CDP 只绑定 `127.0.0.1`，不会暴露到局域网，但同一用户下没有额外认证。
- 不修改官方 Codex 二进制、安装目录、代码签名、线程或认证信息。
- 不读取或改写 `auth.json`、API Key、Base URL 和模型供应商设置。
- 配置写入使用严格 UTF-8、备份、原子替换和可恢复事务。
- Pause 不关闭 CDP；不再使用主题时应执行 Complete Restore。

## 开发与构建

```bash
# macOS 测试
cd macos && npm test

# macOS 未签名测试 DMG
/bin/bash macos/scripts/build-studio-release.sh --adhoc

# Windows 测试（在 Windows PowerShell 5.1 中）
powershell -NoProfile -File windows/tests/run-tests.ps1

# Windows x64 未签名测试安装器（需要 .NET 8 + Inno Setup 6）
powershell -NoProfile -File windows/scripts/build-studio-release.ps1 -Architecture x64 -SkipSign
```

推送形如 `v1.3.1-test.1` 的 tag 会运行 [test-release 工作流](./.github/workflows/test-release.yml)，生成 DMG、EXE、SHA-256 和 release manifest，并创建 GitHub pre-release。

## 更多内容

- [可选用户主题](./user-themes/)
- [概念图库与提示词](./docs/background-generation-prompts.md)
- [Studio 协议](./studio/protocol/README.md)
- [项目记录](./docs/PROJECT.md)
- [Issue 模板](./.github/ISSUE_TEMPLATE/)

## 许可

项目代码使用 MIT License，见 [`macos/LICENSE`](./macos/LICENSE)。人物、IP、预设和预览素材不因代码许可证自动获得再分发授权，请自行确认肖像、素材和商标权利。
