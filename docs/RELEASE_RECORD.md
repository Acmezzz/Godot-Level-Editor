# 通用 2D 编辑器 · 发布记录

> 计划：[docs/superpowers/plans/2026-11-21-universal-2d-editor.md](superpowers/plans/2026-11-21-universal-2d-editor.md) §4 第 4 条要求的记录。
> 每项写清四件事：**制作输入 / 落盘结果 / 文件版本 / 试玩结果**。
> 坐标、存储、类型化引用、时钟换算由测试套件覆盖；手势与菜单靠 GUI 验收。
> 状态标记：`已验证`（有跑过的证据）/ `待试玩`（代码与测试到位，需游戏侧复核）/ `未做`。

本分支：`feat/universal-2d-editor-a1`。所有提交均为本地提交。

---

## 1. 保存与恢复（A2 / A3）

| 项 | 制作输入 | 落盘结果 | 文件版本 | 试玩结果 |
|---|---|---|---|---|
| 普通保存 | 画布改瓦片/摆实例/改尺寸后按 `Ctrl+S` | 按 清单补发码 → 内容暂存 → 地图 顺序写入；任一步失败即停，已写部分保留，`editor/pending/pending-<时间>.json` 记录逐条状态 | 地图 v7、清单 `editor/editor_manifest.json`、内容 `content/<功能id>/<内容ID>.json` | 待试玩 |
| 试玩前提交 | 顶栏「▶ 试玩」 | 同上；提交未成功即中止，不启动进程；只把项目 `maps/` 内的绝对路径交给游戏 | 同上 | 待试玩 |
| 中途失败恢复 | 提交过程中断（清单已写、内容未写） | 下次启动状态栏报「N 次未完成提交」，日志逐条判 `written/pending/manual`；`manual` 单独报「需人工复核」 | `editor/pending/*.json` | 已验证（`tests/test_stores.gd::test_pending_log_partial_detection`，三态齐全） |
| 自动草稿 | 有未保存修改且满 2 分钟；退出时无条件写一次 | `editor/drafts/<草稿键>.json`：快照 + 目标路径 + 正式图基线摘要 + 待提交文件/ID | 草稿 JSON（`kind: "draft"`） | 已验证（按文件名键寻址，`tests/test_stores.gd::test_draft_key_addressing`） |
| 草稿冲突 | 正式图在草稿后被外部改过，仍选择恢复 | 画布载入草稿、磁盘不动；原草稿与 `<键>.conflict-<时间>.json` 并存，冲突备份不列入可恢复列表 | 同上 | 已验证（同上测试断言备份不入列表） |
| 地图历史 | 每次正式保存前 | `editor/history/maps/<地图码>/<时间戳>.json`，最多 20 份；替换失败时快照丢弃、旧条目不减少 | 地图 v7 快照 | 已验证（`test_map_history_by_code_and_write_failure`） |

## 2. 空间与坐标（B1 / B3）

| 项 | 制作输入 | 落盘结果 | 文件版本 | 试玩结果 |
|---|---|---|---|---|
| 逐图投影 | 新建地图时选正交/等距/六边形 | `meta.gridProjection`；缺键沿用项目解析，首次保存冻结进地图 | v7 | 已验证（`tests/test_map_v4.gd:175-187`） |
| 另存并转换投影 | 「设置 ▾ → 另存并转换投影…」选目标投影 | 另存为新图：实例与出生点按锚点换算（像素位置不变）、副本重发实例码/内容 ID/地图码；瓦片与碰撞保留原格号 | v7 + 新内容文件 | 已验证（`tests/test_map_convert.gd`：锚点像素不变、往返回原值、瓦片/碰撞计入待核对、原图未改）；瓦片/碰撞的实际核对靠 GUI |
| 三角格 | 高级设置选 `triangles` 拓扑 | `meta.gridTopology: "triangles"`；半格自绘，`alt` 按 §3.2 消费 | v7 | 待试玩 |
| 斜切格 | `meta.gridBasis` 平行四边形基 | 画布/导出/校验共用同一解析 | v7 | 待试玩 |
| 发布前对照 | `tools/projection_baseline.gd` 只读逐图记录 | 生效投影、拓扑、每实例「数据坐标 → 锚点像素」；`--convert=` 另算「原坐标原锚点 → 像素 → 新坐标新锚点」 | 输出 JSON，不改源图 | 已验证（探针项目：等距图 `--convert=orthogonal` 后每个实例 `converted.pxAfter` 与原 `px` 完全相同，锚点不漂移） |
| 六边拾取/亚格 | 鼠标点选、离格拖动 | 无落盘差异（只影响输入换算） | — | 已验证（`tests/test_grid_space.gd::test_pick_cell_and_continuous`） |

## 3. 引用与复制（C1 / C2 / C3）

| 项 | 制作输入 | 落盘结果 | 文件版本 | 试玩结果 |
|---|---|---|---|---|
| 同图实例引用 | 表单「画布选…」或下拉选目标 | 字段存**实例码**；取消不改原值、不重建控件 | 内容文件 v1 | 已验证（`tests/test_ref_fields.gd`） |
| 跨图引用 | 填「目标地图」+ 目标实例 | 字段存 `(地图码, 实例码)`；地图未填 = 取所属图 | 内容文件 v1 | 待试玩 |
| 整图复制 | 「设置 ▾ → 复制地图」 | 先出 C2 计划预览（实例/内容/瓦片/碰撞/摆放物条数 + 冲突逐条）→ 确认才写；副本实例码/内容 ID 全部新发、组内引用重映射、目标图重发地图码 | v7 + 新内容文件 | 待试玩 |
| 挂载补齐 | 放置带 `functions` 声明的实体 | 绑定行写入 `mounted: true` 的唯一继承行；已有手动行不覆盖 | v7 | 已验证（`tests/test_audit_c3.gd::test_fill_bindings`；复制侧 `test_clone_plan.gd`） |
| 内容删除 | 内容库「删除…」 | 先跑引用检查：范围不完整 / 实例引用 / 内容间入边 任一命中即停；通过才删（`.history` 有备份） | 内容文件 | 判定逻辑已验证（`tests/test_audit_c3.gd::test_content_usage_and_inbound_refs`）；三道拦截的 UI 串接（`content_form.gd:1016-1075`）靠 GUI 验收 |

## 4. 步骤与时间（D1 / D2）

| 项 | 制作输入 | 落盘结果 | 文件版本 | 试玩结果 |
|---|---|---|---|---|
| 列表↔时间轴 | 演出面板切换视图 | 同一工作副本；结构版本变化才重建，旧控件/拖拽回调按版本丢弃 | 内容文件 v1 | 已验证（`tests/test_step_timeline_d1.gd`） |
| 显式起点 / 随前序 | 起点留空（随前序）或填 `0`（从零） | 留空 = 键 `at` 不写；`0` = 显式写 0 | 内容文件 v1 | 已验证（同上） |
| 帧基预览 | 声明 `timePreview.fpsField` + 播过 12 帧 | 只对齐显示，不改数据 | 内容文件 v1 | 已验证（`tests/test_timeline_clock_d2.gd:12`，60fps 第 12 帧 = 0.2 秒） |
| 拍基预览 | 声明 `tempoStep`/`bpmField`/`offsetField`/`subdivisionsPerBeat` | 只对齐显示；缺项按原单位编辑并列出缺什么 | 内容文件 v1 | 已验证（`:29,39,40`：第 6 拍 = 4.25 秒；第 3–5 拍 = 1.75–3.25 秒） |
| 小数帧 | 旧数据里有非整数帧 | 只标记待修；量化是显式动作 | 内容文件 v1 | 已验证（`:64-77`） |

## 5. 资产扫描与身份（A4）

| 项 | 制作输入 | 落盘结果 | 文件版本 | 试玩结果 |
|---|---|---|---|---|
| 新素材落目录 | 往扫描目录放文件、重开清单 | 自动补条目 + 发码，`scanFingerprint` 记 md5；随下次清单保存落盘 | 清单 | 已验证（`tests/test_asset_scan.gd::test_scan_add_codes`、`test_scan_minimal_manifest`） |
| 改名 | 改文件名后重开清单 | 按同指纹重链，保留原 ID | 清单 | 已验证（`test_scan_rename_relink`、`test_scan_rename_after_restart`、`test_scan_ambiguous_two_candidates`） |
| 停用 / 恢复 | 删除文件 / 资产页「重新启用」 | 保留停用记录与原 ID（`disabled`），可恢复，不重发新 ID | 清单 | 已验证（`test_scan_disable_keeps_id`、`test_scan_retire_restore_keeps_id`） |
| 内置种类 | 打开没有 `trigger_zone` 的清单 | 并入内存并标 `builtin`，保存时剥掉，不污染游戏清单 | 清单 | 仅有实现（`builtin_kinds.gd`），无专门测试 |

## 6. 试玩（A6）

| 项 | 制作输入 | 落盘结果 | 文件版本 | 试玩结果 |
|---|---|---|---|---|
| 结构化启动 | 清单写 `playtest.executable` + `args`（含 `%mapfile%`/`%projectpath%`） | 数组直启，空格路径无需转义；状态栏显示程序名、退出状态、`editor/playtest.log` 最后几行 | 清单 | 待试玩（需游戏侧给真实 exe） |
| 模板回退 | 只有 `playCommand` | 原模板启动，状态栏标明「跟踪的是包装进程」 | 清单 | 待试玩 |
| 每图试玩配置 | 弹窗勾 flag / 填 param | 只存编辑器 `user://playtest_prefs.json`，键 = 项目根 + `|` + 地图码；不写地图 JSON | — | 仅有实现（`map_file.gd:1100-1116`，含旧键回退迁移），无专门测试 |

## 7. 导出（A5）

| 项 | 制作输入 | 落盘结果 | 文件版本 | 试玩结果 |
|---|---|---|---|---|
| 单图 PNG/统计 | 「设置 ▾ → 导出」选精度 | `editor/exports/<图名>.png` / `.txt`；写前跑 v7 校验，超预算先给可用缩放倍率 | v7 | 已验证（`tests/test_map_export_a5.gd`：几何/预算/碰撞对象/统计/渲染一致性） |
| 批量导出 | 「导出全部地图」 | 逐图 PNG + 统计，`_export_report.txt` 逐条结果；项目切换自动取消，已写文件保留 | v7 | 仅有实现（`map_dialogs.gd:318-408`），取消/互斥路径靠 GUI 验收 |

---

## 接入自检（每次发布前跑）

```
godot --headless --path . --script res://tools/f2_pilot.gd        # §3 刷怪片段端到端，24 项断言，跑完自清
godot --headless --path . --script res://tools/projection_baseline.gd -- <项目目录> [--out=<文件>]
godot --headless --path . --script res://tests/run_tests.gd       # 24 套件 215 用例
godot --headless --path . --script res://tools/warn_scan.gd       # 全量加载 + 警告扫描
```

## 已知限制（不隐瞒）

- 字段声明的**悬浮说明**由编辑器从已声明的键拼出（id · 执行码 · 类型与 `min/max` · 可选值/`source` · `default`，
  `field_widgets.gd::decl_tooltip`）。契约里**没有**独立的「说明 / 单位」键，单位按惯例写进 `name`
  （如 `时长(秒)`，见 `GAME_SIDE_STANDARD.md` §2.5）；要自由文字说明须先改契约再接，不自行发明键。
- 带内容的地图**不能**在普通设置里直接切投影；要换投影走「设置 ▾ → 另存并转换投影…」。瓦片与碰撞格号在格系变化下没有唯一对应，转换时保留原格号，需在副本里自行核对或清空。
- 演出播放头/视图模式、画布缩放/居中都只在本次会话内保留（切视图不丢：`steps_panel.gd:119-126`、画布节点不重建）；
  关掉编辑器再开项目不恢复这些视图状态（数据本身不受影响）。
- 时间视图的波形、拍号段、逐帧形状轨与卷轴联动未做（D2 末条：前置是「基础帧拍试点通过后按实测瓶颈加」，
  当前无试点实测数据，且「标记步骤」「时间/镜头参考点」在清单契约里没有键）。
- 参考视图（伪 3D / 多窗 / 局部只读参考图）未做（B3 末条、E2 末条）：缺游戏侧「参考图 → 地图码/实例码」
  与热点归一化坐标的声明键；平面侧（三种投影、`screenSize` 视野框、实例码选中）已具备。
- 刷怪试点的人工观察项（首次完成时间、误操作、需询问的步骤）未填——机器无法代填，见 §8 预留行。
- 区域操作未做事务差量：整图快照（`JSON.stringify`，约 5 ms / 1 万瓦片）仍是主要成本，见 F1 记录。

## 8. 真人试点记录（待填）

| 项 | 首次完成时间 | 误操作 | 需询问的步骤 | 备注 |
|---|---|---|---|---|
| E1 刷怪试点（第二波数量 + 画布选出生点，取消一次再确认） | 待填 | 待填 | 待填 | 数据往返已由 `tools/f2_pilot.gd` 24 项断言覆盖 |
