# Codex Dream Skin Studio 产品化设计

- 日期：2026-07-18
- 状态：已确认设计，待实施计划
- 优先级：普通用户一键安装与使用 > 主题打包分享 > 工作区场景与动态效果

## 1. 背景

Codex Dream Skin 已经具备较完整的主题运行内核：

- macOS 和 Windows 都通过 `127.0.0.1` 上的 CDP 向官方 Codex renderer 注入 CSS 与装饰 DOM。
- 不修改官方 `.app`、`app.asar`、WindowsApps 或代码签名。
- 已有官方应用身份校验、受管端口、长期 watcher、主题校验、图片安全限制、状态记录、暂停、验证和完整恢复。
- 已有本地主题库、macOS 菜单栏入口和 Windows 托盘入口。

当前主要缺口不是注入能力，而是产品控制层：安装依赖命令文件、PowerShell、Node、SwiftBar 或终端错误信息；主题仍以目录和单图为主，无法形成稳定的跨平台分享文件；renderer 只可靠地区分首页和非首页，没有工作区到主题的绑定模型。

本设计在现有内核之外增加一个薄型 Studio 控制层，不重写已经验证的 CDP、安全和恢复逻辑。

## 2. 目标与非目标

### 2.1 目标

1. 没有编程经验的用户可以通过一个签名安装包完成检测、安装、应用、暂停和完整恢复，不需要打开终端。
2. 安装和应用必须执行现有真实验证，不能仅凭进程存活报告成功。
3. 主题可以导出为一个跨平台文件，朋友双击后能预览、安装并应用。
4. 一个工作区可以绑定一个主题包，主题包可以按首页、任务、插件、计划任务和 Pull Request 使用不同场景。
5. 动态效果只能使用受控预设，并在任何失败情况下回退到上一主题或官方外观。

### 2.2 非目标

首个里程碑不包含：

- 云端账号、在线主题市场或远程同步。
- 自动安装官方 Codex。
- 视频背景、任意 GIF、任意 CSS 或任意 JavaScript 主题插件。
- 自动读取代码、对话、任务内容或 API 凭据来推断工作区。
- 重写 injector、配置事务、应用身份校验或进程停止逻辑。
- 首版自动更新。

## 3. 不可突破的边界

1. 官方 Codex 安装目录和签名保持不变。
2. CDP 只监听 loopback，并继续校验监听进程、Browser ID、目标 URL 和 renderer 标记。
3. Studio 不直接解析或写入 `config.toml`，不自行扫描端口，不自行结束 PID。
4. 配置修改继续使用现有严格 UTF-8、备份、并发检查和原子替换流程。
5. Studio 不读取或导出 `auth.json`、API Key、线程内容或客户截图；工作区原始标识只允许在用户主动绑定时由引擎临时规范化并哈希，不得持久化、展示或导出。
6. 取消关闭或重启必须零副作用；无法确认进程身份时必须 fail closed。
7. 原生侧栏、项目选择器、输入框、任务、插件和菜单继续保持真实 DOM 与交互。

## 4. 总体架构

```text
签名的 Studio 启动器 / 控制面板
        |
        | 固定命令参数 + JSON 结果
        v
平台引擎适配层
        |
        | 调用现有 install/start/status/pause/restore/verify
        v
现有 Dream Skin 内核
        |
        | 127.0.0.1 CDP
        v
官方 Codex Desktop
```

### 4.1 Studio 控制面板

Studio 只负责：

- 展示安装、Codex、主题会话和当前操作状态。
- 引导用户完成官方 Codex 首次运行、关闭和一次明确的重启授权。
- 调用平台引擎适配层。
- 将稳定错误代码翻译为用户可执行的提示。
- 提供应用、重新应用、暂停、完整恢复、诊断和卸载入口。

Studio 不直接拥有 Codex 生命周期，也不在后台开放 TCP 控制服务。

### 4.2 平台引擎适配层

macOS 和 Windows 各有一个薄适配层，对 Studio 提供相同命令和 JSON envelope，内部复用现有脚本：

- `preflight`
- `install`
- `apply`
- `status`
- `pause`
- `resume`
- `restore`
- `verify`
- `uninstall`

`resume` 是跨平台语义名：适配层在可以热恢复时复用现有恢复能力，否则调用 `apply`；Studio 不自行决定是否需要重启。

统一结果形状：

```json
{
  "schemaVersion": 1,
  "ok": true,
  "operation": "status",
  "state": {
    "install": "ready",
    "codex": "running",
    "session": "active",
    "operation": "idle",
    "themeName": "午夜极光",
    "requiresRestart": false,
    "availableActions": ["pause", "restore"]
  },
  "error": null
}
```

错误结果必须包含稳定的 `code`、简短用户消息和允许的恢复动作。普通界面不显示端口、PID、PowerShell、CDP 或绝对路径；诊断视图可以在用户主动打开时展示脱敏信息和日志位置。

### 4.3 状态来源

不新增平行状态数据库：

- macOS 继续使用 `~/Library/Application Support/CodexDreamSkinStudio`。
- Windows 继续使用 `%LOCALAPPDATA%\CodexDreamSkin`。
- Studio 状态由现有 state、主题目录、备份文件和只读 status 命令派生。
- 状态文件损坏时保留现场，不自动删除，也不结束无法证明身份的进程。

## 5. 一键安装与首启流程

### 5.1 状态机

```text
未安装
  -> 检查中
  -> 需要首次打开 Codex | 需要关闭 Codex | 可安装
  -> 安装中
  -> 待应用
  -> 重启确认
  -> 应用中
  -> 已应用 <-> 已暂停
  -> 恢复确认
  -> 官方模式

任一阶段 -> 失败 -> 重试 | 查看诊断 | 安全恢复
```

### 5.2 用户流程

1. 用户双击一个安装包并打开 Studio。
2. Studio 自动检查操作系统、官方 Codex、官方身份、首次运行配置和运行时。
3. 官方 Codex 尚未首次运行时，Studio 只引导用户打开官方应用并完成首次设置，然后返回重试。
4. Codex 正在运行且安装需要关闭时，显示“关闭并继续”和“取消”。先正常退出；只有用户再次明确授权后才允许沿用现有强制停止能力。
5. 引擎安装到稳定用户目录，播种默认主题并保存可恢复的外观备份。
6. Studio 显示“启动并应用主题”。如果当前 Codex 没有受管 CDP，会再次明确说明一次重启及未保存输入风险。
7. 应用阶段展示“启动 Codex、等待连接、应用主题、验证界面”四个可理解阶段。
8. 只有 `verify` 通过后才显示“已验证”。
9. 失败时沿用现有回滚，保证官方 Codex 可以正常启动，并提供重试、诊断和安全恢复。

### 5.3 主界面

首版主界面保持单窗口，只提供：

- 当前状态和当前主题。
- 应用或重新应用。
- 暂停皮肤。
- 完全恢复官方外观。
- 查看诊断。

“暂停”必须明确说明可能仍保留调试会话；“完全恢复”才会移除 live skin、停止受管 injector、恢复保存的外观键并正常重开 Codex。

卸载与恢复分开：卸载必须先完成恢复；默认保留用户主题库，用户可以单独选择删除。

## 6. 软件形态与发布

### 6.1 第一版形态

第一版采用两个很薄的平台原生壳，行为由统一引擎协议约束：

- macOS：SwiftUI 应用，必要的系统集成使用 AppKit；签名并公证为 `.app`，通过 `.dmg` 分发；用户级安装，不要求 `sudo`，不把 SwiftBar 或 Homebrew 作为前置。
- Windows：.NET 8 WPF 自包含应用和签名的 per-user 安装器；不要求管理员权限，不要求用户手工运行 PowerShell。

现有 `.command`、PowerShell 和托盘脚本继续保留一版，作为高级诊断和故障恢复入口。

当后续 Studio 需要复杂预览、主题编辑和工作区管理时，再评估迁移为统一的 Tauri UI。首版不使用 Electron，也不因 Tauri sidecar、WebView2 和更新系统阻塞一键安装。

### 6.2 运行时

- macOS 继续发现并校验官方 Codex 自带的签名 Node，不额外携带 Node。
- Windows 安装包携带固定版本、按架构选择并经过构建期哈希校验的私有 Node runtime；调用固定绝对路径，不读取用户 PATH 中的 Node。
- Windows runtime 必须携带对应 LICENSE 和 NOTICE。
- 完整恢复不得依赖当前 Node 仍然存在。

### 6.3 发布门禁

- macOS Developer ID 签名、公证和 stapled ticket。
- Windows Authenticode 或 MSIX 签名。
- 发布 SHA-256、构建来源说明、LICENSE 和 NOTICE。
- 发布包不得包含用户状态、备份、日志、截图、凭据或本机绝对路径。
- 首版不启用自动更新；安装升级使用临时目录和原子切换，不覆盖运行中的引擎。

## 7. 可移植主题包

主题分享文件扩展名为 `.cdxtheme`，物理格式为受限 ZIP。

```text
manifest.json
profiles/
  default/
    theme.json
    background.jpg
  home/
    theme.json
    background.jpg
  task/
    theme.json
    background.jpg
preview.jpg
LICENSE.txt
```

### 7.1 Manifest

```json
{
  "schemaVersion": 1,
  "id": "com.example.midnight",
  "name": "午夜主题",
  "version": "1.0.0",
  "minEngineVersion": "1.3.0",
  "author": "Theme Author",
  "defaultProfile": "default",
  "preview": "preview.jpg",
  "profiles": {
    "default": "profiles/default",
    "home": "profiles/home",
    "task": "profiles/task"
  },
  "contexts": {
    "home": "home",
    "task": "task"
  },
  "license": {
    "name": "Personal use",
    "file": "LICENSE.txt"
  },
  "credits": [],
  "integrity": {
    "profiles/default/theme.json": "sha256:6b86b273ff34fce19d6b804eff5a3f5747ada4eaa22f1d49c01e52ddb7875b4b",
    "profiles/default/background.jpg": "sha256:d4735e3a265e16eee03f59718b9b5d03019c07d8b6c51f90da3a666eec13ab35"
  }
}
```

### 7.2 兼容约定

- `default` profile 必须存在。
- 每个 profile 继续使用现有 schema 1 `theme.json` 和一张相对路径图片。
- 旧主题目录导入后自动成为 `default`。
- `colors` 作为跨平台完整颜色配置；Windows 补齐同等字段支持。
- 旧的 `palette.accent` 作为兼容别名保留。
- 新引擎不认识的 context 可以忽略，但不能阻止 `default` 使用。
- 工作区绑定不写入主题包。
- `preview` 可省略；如果声明则文件必须存在并通过图片校验。
- `license` 元数据必须存在；权利不明确时使用 `Unknown`，`file` 可以省略。
- `integrity` 必须覆盖所有 profile 配置和图片，值使用 `sha256:<64 位小写十六进制>`；preview 与 license 文件存在时也必须覆盖。

### 7.3 导入

1. 双击 `.cdxtheme` 由 Studio 打开。
2. 展示预览、名称、作者、版本、兼容性、许可和素材说明。
3. 用户点击“安装并应用”。
4. 解包到受管根目录下的临时目录。
5. 拒绝 zip slip、绝对路径、symlink、junction、reparse point、压缩炸弹、脚本和可执行文件。schema 1 最多允许 16 个 profile、64 个文件、64 MB 压缩包和 128 MB 解压后总大小。
6. 每个 profile 复用现有 JSON、路径、图片格式、16 MB、16384px 和 50MP 校验。
7. 全部 profile 通过后原子发布到主题库；活动主题最后更新。
8. 任一步失败时删除临时目录，当前主题和已安装版本保持不变。

### 7.4 导出

- 只打包选中的主题资源、manifest、预览和许可说明。
- 清除 state、日志、备份、绝对路径、Codex 配置、身份信息和工作区绑定。
- 为文件记录 SHA-256，以便导入时发现损坏。
- 缺少明确许可时允许个人导出，但 Studio 必须标注“权利状态未知”；公开分享不获得项目 MIT 许可的自动授权。

## 8. 工作区场景选择

### 8.1 两层选择

```text
当前工作区绑定的主题包
  -> 当前路由 context 对应的 profile
  -> 主题包 default
  -> 全局默认主题
```

- 用户在 Studio 中主动执行“将当前工作区绑定到这个主题”。
- 工作区绑定保存在本机独立文件中，只记录引擎临时规范化后生成的 SHA-256 和主题 ID。
- 不保存、显示或导出原始项目路径和名称。
- 当前 Codex 版本没有稳定标识时不猜测 DOM 文本，直接使用全局主题。

### 8.2 Context

首版 context：

- `home`
- `task`
- `plugin`
- `scheduled`
- `pull-request`

未识别路由统一回退 `default`。Context 检测必须 feature detect，并经过 debounce，避免 SPA 短暂中间状态造成连续切换。

### 8.3 Profile 切换

- 引擎一次只向 renderer 注入一个完整活动背景，不能把所有工作区图片放进同一个 payload。
- 新 profile 完成路径、schema、图片和 payload 校验后才替换旧 profile。
- 活动配置使用主题 JSON 作为最后提交标记，保持现有原子发布语义。
- 新 profile 失败时继续显示上一主题。

## 9. 动态效果

Profile 可以声明受控 motion：

```json
{
  "motion": {
    "preset": "slow-pan",
    "intensity": 0.15,
    "durationSeconds": 60
  }
}
```

首版允许：

- `none`
- `slow-pan`
- `breathe`
- `subtle-parallax`

约束：

- 仅通过受控的 `transform` 和 `opacity` 实现。
- 装饰层保持 `pointer-events: none`。
- 遵循 `prefers-reduced-motion`，命中时退化为静态背景。
- `intensity` 限制为 `0..1`，`durationSeconds` 限制为 `10..300`；越界配置拒绝导入，不做静默截断。
- 主题包不得提供任意 CSS、JavaScript、shader 或外部 URL。
- 视频和任意 GIF 延后，只有性能、内存和跨平台解码测试证明可接受时再设计。

## 10. 错误处理与回退

| 情况 | 行为 |
| --- | --- |
| 用户取消关闭或重启 | 保持原状态，零副作用 |
| 官方 Codex 未安装或未首次运行 | 引导完成官方步骤，不尝试代装或改包 |
| 签名或 Store 身份异常 | 停止，不连接或结束该进程 |
| state 损坏或 PID 身份不匹配 | 保留 state 和日志，不杀未知进程 |
| 端口被占用 | 沿用现有自动选择；显式端口冲突则失败 |
| 安装事务失败 | 恢复上一引擎目录和配置状态 |
| 应用或 verify 失败 | 移除本次残余样式，保证官方 Codex 可正常启动 |
| 主题包导入失败 | 不改变主题库和活动主题 |
| 工作区识别失败 | 使用全局主题 |
| context 识别失败 | 使用主题包 `default` |
| profile 加载失败 | 保留上一主题 |
| 完全恢复 | 移除 live skin、停止受管 injector、恢复外观键、关闭受管 CDP 并正常重开 Codex |

## 11. 测试与验收

### 11.1 一键安装

- 干净 macOS 用户双击 `.dmg/.app`，无需终端完成安装、应用和验证。
- 干净 Windows 用户在未安装 Node 的情况下完成安装、应用和验证。
- 中文用户名、中文项目名和包含空格的路径可用。
- Codex 未首次运行、正在运行、取消重启、端口冲突和签名异常都有明确分支。
- 安装、启动、验证、暂停、恢复、卸载全链路接通。
- 恢复后官方 Codex 正常启动，官方签名和安装文件未变化。
- 失败注入不会留下半开启的受管会话或虚假成功状态。

### 11.2 主题包

- 同一 `.cdxtheme` 在 macOS 和 Windows 导入后使用相同图片、颜色、art 配置和默认 profile。
- 旧主题目录导入、导出、再导入 round trip 保持等价。
- zip slip、symlink/junction、压缩炸弹、非法格式、超大图片、坏 JSON 和路径逃逸全部失败且无部分写入。
- 导出包不包含 state、备份、日志、配置、工作区绑定或绝对路径。
- 不支持的新 context 正确回退 `default`。

### 11.3 工作区与动态效果

- 工作区手动绑定、解绑和刷新恢复正确。
- 工作区标识无法获得时使用全局主题，不阻塞 Codex。
- home/task/plugin/scheduled/pull-request profile 匹配和 fallback 正确。
- 切换失败保留上一主题，没有空白帧或不可点击遮罩。
- 减少动态效果开启时所有 motion 退化为静态。
- 首页和任务页仍需真实截图和交互检查；侧栏、项目选择器、输入框、菜单、插件和任务均可使用。

### 11.4 发布门禁

- 继续运行 `cd macos && npm test` 和 `powershell -File windows/tests/run-tests.ps1`。
- 新增 Studio 协议、安装状态机、主题包 round trip、跨平台 parity、context fallback 和发布内容扫描测试。
- macOS 在干净 VM 验证 codesign、notarization 和 Gatekeeper。
- Windows 在干净 VM 验证无 Node 安装、SmartScreen/签名、Store Codex 更新后的应用和恢复。
- 更新 `docs/platforms.md`、两端 README、对应 changelog；用户可见发布时同步更新 `macos/VERSION`。

## 12. 交付顺序

### 里程碑 1：普通用户一键安装与使用

1. 为现有命令补齐稳定 JSON 协议和 Windows 只读 status。
2. 统一暂停、完整恢复、端口恢复和错误代码语义。
3. 构建 macOS 签名启动器和 Windows 签名启动器。
4. Windows 打包私有 Node runtime。
5. 接通 preflight、install、apply、verify、pause、restore 和 uninstall。
6. 完成干净环境、失败回滚和真实 Codex 验收。

### 里程碑 2：主题打包分享

1. 实现 `.cdxtheme` schema、导入、导出和文件关联。
2. 统一 Windows 与 macOS 的颜色和文案契约。
3. 增加主题预览、许可提示和跨平台 round trip。

### 里程碑 3：工作区场景与动态效果

1. 增加 context resolver 和 profile resolver。
2. 增加本机工作区绑定。
3. 增加受控 motion 预设与减少动态效果降级。
4. 扩展 home/task/plugin/scheduled/pull-request 实机验收。

## 13. 完成定义

设计目标完成必须同时满足：

1. 普通用户只通过一个签名软件入口完成安装、应用、暂停和恢复。
2. 安装和应用结果来自真实 verify，而非进程或文件存在判断。
3. `.cdxtheme` 可以跨平台导入、导出且不携带隐私或可执行内容。
4. 工作区和路由规则失败时始终可回退，不影响官方 Codex 功能。
5. 完整恢复可以关闭受管调试会话并恢复官方外观。
6. 所有平台测试、干净环境测试、真实首页和任务页验收通过。
