# 可选用户主题

这里的主题包不会由安装脚本自动播种。每套只包含 `theme.json` 和一张纯背景图：

| 目录 | 主题名 |
| --- | --- |
| `iu-ivory-bridal` | IU 象牙婚礼 |
| `gojo-satoru` | 五条悟 |
| `sakura-spring-festival` | 木之本樱 春日祭 |
| `yuzuriha-inori` | 楪祈 |

macOS 安装项目后，可将任一目录复制到本地主题库并切换：

```bash
theme="gojo-satoru"
library="$HOME/Library/Application Support/CodexDreamSkinStudio/themes"
mkdir -p "$library"
cp -R "user-themes/$theme" "$library/$theme"
"$HOME/.codex/codex-dream-skin-studio/scripts/switch-theme-macos.sh" --id "$theme"
```

人物、角色及相关视觉素材不因软件采用 MIT 许可而自动获得再分发授权。公开或商业使用前，请自行确认肖像、版权和商标权利。
