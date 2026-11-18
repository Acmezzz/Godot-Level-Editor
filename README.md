# BIRD 关卡编辑器

自用的 Godot 4.7.2 关卡编辑器，为游戏工程 `D:\Game\BIRD\bird` 开发。编辑器不依赖游戏运行时，
只读取游戏工程里的 `editor/editor_manifest.json`、地图 JSON 和 `content/` 内容资源。

## 文档索引

| 文档 | 定位 | 读者 |
|---|---|---|
| [EDITOR_FEATURES.md](EDITOR_FEATURES.md) | **项目说明**：架构、全部功能、测试、已知边界 | 开发时查阅 |
| [content-development-standard.md](content-development-standard.md) | **开发标准**：编辑器 ↔ 游戏的数据契约，双方实现都以此为准 | 写游戏侧代码时 |
| [content-authoring.md](content-authoring.md) | **使用教程**：从放实体到写对话/演出/商店的操作流程 | 做关卡/剧情时 |

## 快速上手

```
godot --path "D:\Game\BIRD\Level Editor"     # 打开编辑器（主场景 src/editor.tscn）
```

首次使用：顶栏「项目」选定游戏工程文件夹 → 读清单 → 开始编辑。
日常工作流（实例为主）：画布放实体 → 选中 → 属性面板「＋ 为此实体创建内容组」→
右侧内容抽屉里就地写对话/事件/商店。详细操作见使用教程。

## 验证

```
# 门禁（10 个脚本，一子系统一个；新增 src/测试文件必须登记进 parse_all）
godot --headless --path . --script res://tests/parse_all.gd
godot --headless --path . --script res://tests/regress.gd
# ……全部清单见 EDITOR_FEATURES.md §11；data_layer / portal 两项需环境变量 BIRD_PROJECT=D:/Game/BIRD/bird
```

规则：测试按完整工作批次跑，一子系统只留一个脚本，新增覆盖并入既有脚本；
跑完必须确认进程退出（headless 卡在 await 会永久挂起）。

## 项目结构

```
src/
├── app.gd / editor_canvas.gd   两个宿主：装配控制器，只留引导代码 + 薄包装器
├── core/ canvas/ ui/           控制器（RefCounted，经 app./cvs. 别名访问宿主）
├── content/                    内容系统数据层（store / model / validate / templates / builtin_kinds）
└── ui/content_editors/         对话/事件/商店/定义四个编辑器控制器（全屏库与内容抽屉共用）
tests/                          10 个门禁脚本 + tools/screenshot.gd 截图辅助
docs/                           上面三份文档
```

宿主 + 控制器约定、清单驱动、纯代码构建 UI 等设计原则详见 `EDITOR_FEATURES.md` §1。
