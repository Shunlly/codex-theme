# 默认主题自动应用设计

- 日期：2026-07-22
- 状态：方案 A 已确认，可实施
- 范围：macOS Studio、Windows Studio、Windows 安装器

## 目标

普通用户安装并首次打开 Studio 后，无需再依次点击 Install 和 Apply。Studio 自动执行：

```text
preflight -> install 默认主题 -> apply -> verify
```

Windows 安装完成后默认启动 Studio。macOS 遵循系统 DMG 规则，用户拖入 Applications 后首次打开 Studio 即开始该流程。

## 行为

1. 首次启动只在状态允许 `install` 或 `apply` 时自动继续。
2. `install` 成功后立即调用现有 `apply`，使用各平台已经播种的默认主题。
3. Codex 正在运行时保留现有重启确认；取消必须停止流程且不强制关闭 Codex。
4. 正常关闭失败时保留现有第二次强制停止确认。
5. `apply` 必须通过现有严格验证后才显示成功。
6. 已暂停状态不自动 `resume`，尊重用户的暂停选择。
7. 已处于 active/verified 状态时不重复应用。
8. 任一步失败即停止，保留现有诊断、恢复和重试入口。

## 平台接线

### macOS

- `StudioModel.launch()` 完成 preflight 后自动执行允许的 `install` 或 `apply`。
- `install` 成功并刷新到 ready 状态后，在同一用户流程中继续 `apply`。
- 重启/强制停止确认后继续原操作；若原操作为 install，成功后仍继续 apply。
- 不新增登录项、后台服务或新的引擎命令。

### Windows

- `MainWindow.InitializeAsync()` 完成 preflight 后自动执行允许的 install 或 apply。
- 主操作和托盘手动触发 install 时也复用 install-then-apply 串联逻辑。
- Inno Setup 完成页默认勾选“启动 Studio”；静默安装继续不自动启动。
- 不新增管理员权限、外部 Node 或新的常驻服务。

## 默认主题

不新增选择逻辑：macOS 继续使用现有 `preset-midnight-aurora`，Windows 继续使用现有 `preset-romantic-rose`。主题选择和跨平台统一默认值不属于本次改动。

## 验收标准

- 干净状态首次打开 Studio 会依次调用 preflight、install、status、apply、status。
- 已安装但未应用时首次打开只自动 apply。
- paused 状态首次打开不会 resume。
- install 或 apply 需要重启时只沿用现有明确授权，不静默强制停止。
- install/apply/verify 任一步失败后不继续后续步骤。
- Windows 图形安装完成页默认启动 Studio。
- Pause、Complete Restore、卸载和官方 Codex 原有功能保持不变。

## 测试

- macOS StudioModel 单元测试覆盖自动 install/apply、已安装自动 apply、paused 不恢复、重启确认后续跑和失败停止。
- Windows Studio 控制测试覆盖自动操作选择、install 后 apply、paused 不恢复；发布契约覆盖安装器默认启动。
- 运行 macOS 完整测试、Windows portable contracts、PowerShell 解析和发布包构建检查。
- 最终发布前仍需 clean-machine + 真实 Codex 的首页/任务页实机验收。
