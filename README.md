# 2D 关卡编辑器

自用的 Godot 4.7.2 通用 2D 关卡编辑器。**不绑定任何具体游戏**：
每个游戏工程只要按规范放入 `editor/editor_manifest.json`，编辑器打开即用；
多个工程可在编辑器里按项目列表切换、并行开发。

## 文档

| 文档 | 定位 |
|---|---|
| [docs/EDITOR_FEATURES.md](docs/EDITOR_FEATURES.md) | **编辑器功能权威描述**：架构、全部功能、快捷键、已知边界 |
| [docs/GAME_SIDE_STANDARD.md](docs/GAME_SIDE_STANDARD.md) | **游戏侧开发规范**：清单/地图/内容三种数据的完整契约，怎么声明资产与功能，游戏侧怎么读 |

## 快速上手

```
godot --path "<Level Editor 目录>"     # 打开编辑器（主场景 src/editor.tscn）
```

首次使用：启动页「打开项目文件夹…」选定游戏工程 → 读清单 → 开始编辑。
之后启动会自动打开上次的项目；顶栏「设置 ▾ → 切换项目…」可回到项目列表。

日常三条主线：

1. **关卡编辑器**（默认视图）：左栏选图层与资产，画布**左键放置、右键擦除**。
   混合层栈每层都可涂瓦片、放实体；碰撞元层涂类型/形状。
2. **内容编辑器**（顶栏「内容」）：给实例挂功能、填内容。左列本图实例 / 中列只读预览 / 右列功能与内容表单。
3. **资产目录**（顶栏「资产」）：实体图鉴；给类型挂「自带功能」，按图清点实例分布，删除前查引用。

`Esc` 回关卡视图；`?` 查快捷键。

## 目录结构

```
src/
├── app.gd / editor.tscn   宿主：项目列表与切换、快捷键、模式切换、跨控制器委托
├── core/                  常量、撤销栈
├── project/               清单读取与校验、项目审计、试玩启动
├── map/                   地图存取、格式常量与瓦片变换互转、数据校验、导出、侧栏动作
├── assets/                资产声明归一化、内置种类、碰撞类型池、图像探测
├── canvas/                画布宿主与控制器（绘制 / 输入 / 左右键语义执行 / 选区）
├── content/               功能/条件/步骤/音频/时机声明池、五段身份数、内容文件读写
└── ui/                    设计系统、布局骨架、三面板、各种弹窗
tests/                     数据层回归测试（10 套件 73 用例，run_tests.gd 一条命令跑完）
tools/                     开发期脚本：截图 / 迁移(migrate_project.gd) / 警告扫描(warn_scan.gd)
mcp/                       bird-editor MCP server（AI 协作验证链，见 mcp/README.md）
docs/                      EDITOR_FEATURES + GAME_SIDE_STANDARD
```

## 验证

`src/` 下每个 GDScript 都应能单独解析通过：

```
godot --headless --path . --check-only --script res://src/app.gd
```

完整清单与测试说明见 `docs/EDITOR_FEATURES.md` §11。覆盖数据层纯逻辑（10 套件 73 用例，
崩溃即判失败——断言计数守卫），一条命令跑完：

```
godot --headless --path . --script res://tests/run_tests.gd
```


## 约定（改代码前必读）

- **含 `await` 的委托链必须每层 `await`**：漏一层协程就被丢弃、调用方立即返回，
  且 `--check-only` 查不出来。
- 所有项目数据写盘只走 `MapStore.write` / `write_json` / `write_text`
  （原子替换、历史轮转、写后缓存失效）。
- 连续控件（SpinBox）只在失焦 / 回车 / 松手时提交；离散控件即时写盘。
- 画布手势状态收敛在 `EditorCanvas.gesture` 单一枚举里：起手 `begin_gesture`、松手 `end_gesture`，
  不要新增独立布尔手势位。
- 注释会过时：判断某段代码是否还活着，用 `rg` 查调用点，不要信文件头注释。
