# 通用 2D 编辑器 · 发布记录

> 计划：[V1-IMPLEMENTATION-PLAN.md](reviews/V1-IMPLEMENTATION-PLAN.md) §4 第 4 条要求的记录。
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
| 另存并转换投影 | 「设置 ▾ → 另存并转换投影…」选目标投影 | 另存为新图：**实例**按锚点换算（连续坐标，前后锚点像素相同）、**出生点**是离散格，只保证落回「原锚点像素所在格」，格中心可有 ≤ 半格偏移；副本重发实例码/内容 ID/地图码；瓦片与碰撞保留原格号 | v7 + 新内容文件 | 已验证（`tests/test_map_convert.gd`：实例锚点像素不变、出生点落回原像素所在格、往返回原值、瓦片/碰撞计入待核对、原图未改）；瓦片/碰撞的实际核对靠 GUI |
| 三角格 | 高级设置选 `triangles` 拓扑 | `meta.gridTopology: "triangles"`；半格自绘，`alt`（变换位 0-7）施加在切片 UV 内、不越出切片（§3.2） | v7 | `tri_uvs` 纯函数已验证（`tests/test_tri_render.gd::test_tri_uv_alt`：翻转/转置生效、UV 不越界）；观感待 GUI 验收 |
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
| 单图 PNG/统计 | 「设置 ▾ → 导出」选精度 | `editor/exports/<图名>.png` / `.txt`；写前跑 v7 校验，超预算先给可用缩放倍率。层 `offset/scale` 参与边界与落位（与内容预览同一 `MapViewData.layer_transform`），`parallax`/`ySort` 不参与 | v7 | 已验证（`tests/test_map_export_a5.gd`：几何/预算/碰撞对象/统计/渲染一致性 + 层变换扩边界 2 例） |
| 批量导出 | 「导出全部地图」 | 逐图 PNG + 统计，`_export_report.txt` 逐条结果；项目切换自动取消，已写文件保留 | v7 | 仅有实现（`map_dialogs.gd:318-408`），取消/互斥路径靠 GUI 验收 |

---

## 性能采样（§7.5）

`tools/perf_sample.gd`（headless，`--script res://tools/perf_sample.gd`）在 `user://` 临时工程里
造两份夹具后逐场景多次采样，打印中位数 / P95 / 最长；跑完自清，不改真实项目。

- **机器**：Intel Core Ultra 5 250K Plus（18 逻辑核）· 16 GB · Windows 11 Pro 10.0.26200 · Godot 4.7.2.stable。
- **夹具**：`小图` = 256 宽、1 万瓦片 + 40 实体 + 40 碰撞 + 2 层；`大图` = 256 宽、10 万瓦片，
  同数量实体/碰撞；工程内另有 18 张小图参与全项目自检。实体带 `props.f1` 引用与功能声明。
- **采样次数**：读盘与查表类 11 次，写盘/序列化/自检类 5 次（每轮都先改一格模拟真实脏图）。

| 场景 | 中位数 | P95 | 最长 | 读法 |
|---|---|---|---|---|
| 冷开 小图（1 万瓦片） | 42.9 ms | 44.9 ms | 44.9 ms | 清缓存后读盘 + 全量校验 |
| 热开 小图 | 44.0 ms | 45.1 ms | 45.1 ms | `MapStore.read` 命中 mtime 缓存 |
| 冷开 大图（10 万瓦片） | 527.4 ms | 610.0 ms | 610.0 ms | 同上，规模 ×10 |
| 热开 大图 | 531.1 ms | 589.9 ms | 589.9 ms | 缓存对本规模几乎无收益（JSON 解析占主导） |
| 单格改 + 保存 大图 | 660.4 ms | 698.6 ms | 698.6 ms | 校验 + 序列化 + 原子替换 + 历史快照 |
| 整图快照序列化 大图 | 142.4 ms | 150.6 ms | 150.6 ms | 全局操作/实例增删的撤销条目成本 |
| 切实例查表 ×2000 | 7.8 ms | 9.1 ms | 9.1 ms | 每帧绘制出口量级（约 3.9 µs/次） |
| 地图码表重建（冷） | 641.2 ms | 686.7 ms | 686.7 ms | 20 图全读一遍；仅在写盘/改名后第一次发生 |
| 地图码表重建（热） | 1.1 ms | 1.2 ms | 1.2 ms | 命中签名缓存（绘制出口走这条） |
| 全项目自检 | 1228.4 ms | 1259.7 ms | 1259.7 ms | 19 张图（含 10 万瓦片大图）+ 内容扫描 |

**结论与预算对照**：单格撤销、单实例改值、鼠标悬停都走差量/查表路径，与全图瓦片数无关
（差量条目只存改动格；`used_cells` 过滤 3×256×256 从 7.3 ms 降到 0.65 ms，见 `tools/f1_bench.gd`）。
16.7 ms 编辑帧预算**未能由本工具判定**——帧时间依赖视口与绘制，headless 拿不到；
需要用 GUI 采样补测（见下）。已知超出 16.7 ms 的是「全局操作」与「大图保存」两类**非逐帧**动作，
它们本就是秒级同步作业，缓存/分块是后续优化方向。
**未测量项**：编辑帧 P95、拖动/涂刷实时帧、缩略图重建、导出大图耗时——都需要带视口的 GUI 采样，
本轮按约定不做 GUI 验收，明确留空。

## 接入自检（每次发布前跑）

```
godot --headless --path . --script res://tools/f2_pilot.gd        # §3 刷怪片段端到端，24 项断言，跑完自清
godot --headless --path . --script res://tools/projection_baseline.gd -- <项目目录> [--out=<文件>]
godot --headless --path . --script res://tests/run_tests.gd       # 全套件 253 用例
godot --headless --path . --script res://tools/warn_scan.gd       # 全量加载 + 警告扫描
godot --headless --path . --script res://tools/perf_sample.gd     # §7.5 性能采样（数字见上）
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
- 区域操作未做事务差量：整图快照（`JSON.stringify`，140 ms / 10 万瓦片、约 5 ms / 1 万瓦片）仍是主要成本，见性能采样与 F1 记录。

**§7 明确排除项（不是遗漏，是前置条件不在编辑器侧）**：

| 项 | 排除原因 |
|---|---|
| 格边引用（地图码 + 规范格号 + 拓扑边 ID、无向边取排序代表） | 缺项目侧「拓扑边身份」声明键；端口引用（`assets[].ports`）已做 |
| 参考视图热点点选回填 | `views[].hotspots` 校验已完成；从画布点热点回填目标身份需 GUI 选点会话 |
| 音频试听与波形 | 缺项目侧「音频可播放路径」约定（`audio[].path` 的解释权在游戏侧），编辑器只做名称+时间显示 |
| 实例 `InstanceKey` / 内容 `ContentKey` 差量撤销 | **已实现**（`undo_history.gd` 的 `{kind:"ents"}` / `{kind:"content"}`，见 §9.4）：实例增删改与内容字段只写受影响数据。仍走整图快照的只有**无实例码的场景图片**与全局操作（区域/层/尺寸/转换/批量替换/自动碰撞）。逐项见 `tests/test_undo_delta.gd` |
| 编辑帧 P95、拖动/涂刷实时帧、缩略图重建、导出大图耗时 | 依赖视口，headless 测不到；需 GUI 采样 |
| 批量导出取消后续跑 | 当前整图一次性渲染，取消即中止，已写文件保留 |

## 8. 真人试点记录（待填）

| 项 | 首次完成时间 | 误操作 | 需询问的步骤 | 备注 |
|---|---|---|---|---|
| E1 刷怪试点（第二波数量 + 画布选出生点，取消一次再确认） | 待填 | 待填 | 待填 | 数据往返已由 `tools/f2_pilot.gd` 24 项断言覆盖 |
---

## 9. 第二轮审查修复（2026-11-22，[V2-EDITOR_REAUDIT.md](reviews/V2-EDITOR_REAUDIT.md)）

> 覆盖 R01–R29 与 §7.1–§7.4（B/C 系列能力扩展）中的下列条目；纯逻辑断言 **253/253** 通过、
> `warn_scan` **81 文件 0 失败**；GUI 手势、试玩与「第二个文件写失败」等中断回归仍按审查报告 §6 待验收。

| 审查项 | 修复落点 | 证据 |
|---|---|---|
| R01 统一提交入口 | 内容页/资产页保存改走 `commit_document`（清单→内容→地图，提示基于真实结果）；选实例只收集控件值不落盘 | 静态审查 |
| R02 暂存按文档归属 | 暂存条目带 `doc` 键（项目根+地图码），冲刷只写当前文档；绑定复核失败（撤销/切图放弃）就地丢弃并报告 | 静态审查 |
| R03 草稿带内容载荷 | 草稿存 `pendingContents`（{fn_id, id, data}）；恢复按绑定复核后重新暂存，未收的逐条报告 | `tests/test_stores.gd::test_draft_roundtrip_by_map_code` 更新后通过 |
| R04 提交日志覆盖 | `DocumentCommit.apply`：`prepare` 时收集控件值并冻结全部目标+基线 → `begin_pending` 登记（写不出日志即中止、零文件写入）→ 逐目标写前复验 → **每个文件写成功当场 `mark_pending_written` 回填结果摘要** | 静态审查（`document_commit.gd:51-98`）；中断后三态判定由 `tests/test_stores.gd::test_pending_log_partial_detection` 覆盖；「第二份写失败」的真实中断回归待 GUI |
| R05 基线绑定 | 地图/清单确认绑定到确认前抓的摘要并复验；演出写回带磁盘基线 | 静态审查 |
| R06 改名/复制/导入 | `rename_map` 回写失败不报成功且进提交日志（写新+删旧）；整图复制进日志；外部导入重发地图码 | `tests/test_stores.gd` 改名/复制用例通过 |
| R07 补码标记 | 装载时实体资产补码置 `_codes_issued` | 静态审查 |
| R09 撞码不猜 | `ref_fields.map_instances` 一码多图返回空候选（控件保留原值），由自检报冲突 | 静态审查 |
| R10 跨图复制 | 重映射先看配对地图字段现值（目标非源图原样保留）；共享配对冲突列入计划并停止 | `tests/test_clone_plan.gd` 全过 |
| R11 区域粘贴对账 | 计划项按剪贴板行序对账（跳过的实例不消费计划项）；实例落层与瓦片同一条规则 | 静态审查 |
| R12 暂存内容参与复制 | `ClonePlan.build` 接受会话暂存快照；普通/区域粘贴传入 | 静态审查 |
| R13 配对地图注入 | 功能/条件/步骤字段控件的实例引用注入 `_mapKey`；`asset::ID` 空段语义与 RefFields 一致 | 静态审查 |
| R14 删除前引用图 | 内容删除扫全部活体绑定 + 暂存内容入边 | 静态审查 |
| R15 未解析行保码 | 声明解析不出的摆放物按原行往返（保留原码） | 静态审查 |
| R16 清理确认边界 | 「清除悬空引用」先列逐图作用范围确认再批量写盘 | 静态审查 |
| R17 生效投影 | 校验拓扑用生效投影；`new_map` 显式正交落盘 `gridProjection` | `tests/test_map_v4.gd` 全过 |
| R18 导出拓扑 | `map_export.grid_of` 应用 `gridTopology` | `tests/test_map_export_a5.gd` 全过 |
| R19 预览几何 | 内容预览非正交图按 GridSpace 格多边形落位，地形与实例对齐；正交保持纹理块（`alt≠0` 走同一 `tri_uvs` 施加切片内变换）；层 `offset/scale` 与实例同一条 `MapViewData.layer_transform`（地形不再与实例各算一套） | `tests/test_grid_space.gd::test_map_view_*`；几何观感靠 GUI 验收 |
| R21 校验加严 | 瓦片元组与碰撞坐标要求整数；新增重复瓦片/碰撞格诊断 | `tests/test_map_v4.gd` 全过 |
| R24 试玩参数 | `_play_args` 可选键安全解析；非 Windows 明示「无法跟踪进程退出」 | 静态审查 |
| R23 演出面板令牌 | 面板身份检查加入地图键，切图即失效 | 面板逻辑静态审查 |
| R28 手势副作用 | `commit_document` 纯盘点无副作用；正式提交先归位预览手势再清类型 | 静态审查 |
| R29 缓存刷新入口 | `MapStore.invalidate_read_cache()` 公开人工刷新入口 | 静态审查 |
| 文档硬伤 | `GAME_SIDE_STANDARD.md` §7.2 改为按字段码直读、§8.1 补 `"kind": "entity"` | 静态审查 |
| B4 H01 撤销差量 | 格差量（`kind:"delta"`）+ 实例差量（`kind:"ents"`，`InstanceKey` 为键）+ 内容差量（`kind:"content"`，`ContentKey` 为键），均一次操作一条；无码场景图片与全局操作仍走整图快照；内容回滚前比对盘面摘要，被外部改过就拒绝 | `tests/test_undo_delta.gd`（9 例）；GUI 手感待验收 |
| C1 结构化行 | `of: "record"` + `fields` 子字段声明（限深 4），行级 ↑↓/复制/删除；记录内引用与 `mapField` 作用域收窄到本行 | `tests/test_c1_records.gd` |
| C2 内容库维护 | 库列表加名称/引用状态筛选与 `◆n` 入边数；共享改绑（确认框列受影响实例）、改显示名、删除前引用检查；批量入边一次读盘 | `tests/test_c2_lib.gd`（磁盘夹具） |
| C3 端口引用 | `assets[].ports = [{id, x, y, type?}]`；字段 `type: "port_ref"`、值 `{map, inst, port}`；复制只改 map/inst；候选走配对图优先 | `tests/test_c1_records.gd` 的 ports/port_ref 用例 |
| C4 有限格图 | 地图 `meta.cellGraph` 只读参考层：id/多边形/邻接校验 + 多边形命中；字段 `source: "cell:"` 枚举，且可「画布选…」按多边形点选（选点 accept=`"cell"`，多边形高亮） | `tests/test_c4_cell.gd`（含 polygon/centroid/命中一致性 2 例）；画布点选手感待 GUI 验收 |
| C5 坐标域/视口 | 清单 `viewports` + `views` 校验与展示；字段 `type: "viewport_ref"` 存 `{viewport, point|rect}`，归一化 0..1 | `tests/test_c1_records.gd` 的 viewports/views 用例 |
| D1/D2/D3 文档 | 游戏侧规范删去固定图集名与 `(4,0)` 占位瓦片要求、补新键与支持边界；功能文档改历史/草稿/撤销/写入时机四处旧说法；15 个模块头注释按其真实职责收敛 | 逐条静态核对 |

