# BIRD 关卡编辑器

自用的 Godot 4.7.2 关卡编辑器，为游戏工程 `D:\Game\BIRD\bird` 开发。编辑器不依赖游戏运行时，
只读取游戏工程里的 `editor/editor_manifest.json`、地图 JSON 和 `content/` 内容资源。

## 文档

| 文档 | 定位 |
|---|---|
| [docs/EDITOR_FEATURES.md](docs/EDITOR_FEATURES.md) | **唯一权威功能描述**：架构、全部功能、快捷键、已知边界、已删除功能索引 |
| [docs/code-review-2026-11-19.md](docs/code-review-2026-11-19.md) | 2026-11-19 代码审查报告（全部条目已修复，现作历史记录） |
| [docs/demo-editor-v2.html](docs/demo-editor-v2.html) | 交互演示稿（单文件 HTML） |

## 快速上手

```
godot --path "D:\Game\BIRD\Level Editor"     # 打开编辑器（主场景 src/editor.tscn）
```

首次使用：顶栏「设置 ▾ → 打开项目」选定游戏工程文件夹 → 读清单 → 开始编辑。

日常三条主线：

1. **关卡编辑器**（默认视图）：左栏选图层与资产，画布**左键放置、右键擦除**。
   地形 / 装饰 / 碰撞层按住拖动连续涂；实体层点空处放置、点实体选中并拖动。
2. **内容编辑器**（顶栏「内容」）：给实例挂功能、填内容。左列本图实例 / 中列只读预览 / 右列功能与内容表单。
3. **资产目录**（顶栏「资产」）：实体图鉴，可改固定功能参数、查看每图实例分布并就地改实例数值。

`Esc` 回关卡视图；`?` 查快捷键。

## 目录结构

```
src/
├── app.gd / editor.tscn   宿主：项目选择、快捷键、模式切换、跨控制器委托
├── *.gd                   清单读取与校验、地图数据读写、导出、试玩
├── core/                  状态流、撤销栈、侧栏动作
├── canvas/                画布宿主与控制器（绘制 / 输入 / 工具执行 / 选区）
├── content/               内容资源存储、分层身份码、内置种类、数值合并
└── ui/                    设计系统、布局骨架、三面板、各种弹窗
tests/                     测试脚本（待重写，不作验收口径）
tools/screenshot.gd        截图辅助（开发期）
docs/                      EDITOR_FEATURES + 审查报告 + 演示稿
```

## 验证

`src/` 下每个 GDScript 都应能单独解析通过：

```
godot --headless --path . --check-only --script res://src/app.gd
```

完整清单与测试说明见 `docs/EDITOR_FEATURES.md` §11。**测试套件处于待重写状态**，
门禁脚本（`tests/run_gates.ps1`）不再是验收口径。

## 约定（改代码前必读）

- **含 `await` 的委托链必须每层 `await`**：漏一层协程就被丢弃、调用方立即返回，
  且 `--check-only` 查不出来。
- 所有项目数据写盘只走 `MapStore.write` / `write_json` / `write_text`
  （原子替换、历史轮转、写后缓存失效）。
- 连续控件（SpinBox）只在失焦 / 回车 / 松手时提交；离散控件即时写盘。
- 画布手势状态收敛在 `EditorCanvas.gesture` 单一枚举里：起手 `begin_gesture`、松手 `end_gesture`，
  不要新增独立布尔手势位。
- 注释会过时：判断某段代码是否还活着，用 `rg` 查调用点，不要信文件头注释。
