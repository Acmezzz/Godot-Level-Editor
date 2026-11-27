# 2D 游戏编辑器全面审查（2026-11-28）

## 0. 审查范围与方法

- 范围：`src/` 全部 109 个 GDScript 文件（core 2 / assets 4 / content 16 / map 13 / project 18 / canvas 18 / ui 41 / mcp 5 / app.gd 1）+ `editor.tscn`，逐文件通读。
- 基准文档：`docs/EDITOR_FEATURES.md`（职责总览表逐条核对 109 条）、`docs/GAME_SIDE_STANDARD.md`（全文逐节）、`docs/EDITOR_MCP.md`、`docs/EDITOR_PROTOCOL.md`。
- 方法：通读 + 定点验证。所有列入本文档的 BUG 结论都追过实际数据流（调用点全集、读写链路、校验前置条件），不采信注释。
- 验证过**安全**、不列入问题的两个候选点：
  - MCP publish 与人工保存共用 `DocumentCommit.apply`（src/project/document_commit.gd:39）：内容文件统一走 `content_store.write_ex`（写/删均轮转 `.history`），地图走 `MapStore.write`（不轮转，靠 pending log + 撤销 + MCP 草稿快照兜底）——人工与 MCP 完全一致，非缺陷。
  - `clone_plan.gd:628` 的 `meta[section][field]` 下标链：`ref` 本身枚举自同一棵 `meta` 子树（`MapFlow.references`），非字典形态已被 `targets()` 过滤，实际不可达崩溃。

## 1. 总体结论

- **能承担"通用 2D 游戏编辑器"目标**：主链路（地形、实体摆放、碰撞、引用、功能绑定、演出、屏幕、世界布局、图组、生成器、MCP 批量、试玩）已闭环，核心设计（身份码、声明池、双基结构）自洽。
- 文档与代码高度对齐：109 条职责表零漂移；GAME_SIDE_STANDARD 全部条款与实现一致。
- 未发现数据损坏级 BUG。问题集中在：1 个 P2 性能点、1 个 P3 边缘崩溃、若干架构债务与 5 个覆盖缺口（§3–§5）。
- 一句话：**架构与数据模型是强项，债务集中在 UI 层样板与少数大函数；距"所有 2D 游戏"差 5 个可枚举缺口（§4），没有一个需要推翻现有结构。**

## 2. 任务一：文档 ↔ 代码对齐

**结论：对齐良好。未发现"文档描述了但代码不存在"的功能，也未发现反向漂移。**

- EDITOR_FEATURES 源码逐文件总览表：109 条逐一与实现核对，全部一致。
- GAME_SIDE_STANDARD 全文逐节核对：声明位置表、ID 规则（地图/实体/实例/功能执行码 4 位 + 内容码 6 位）、流程目标四形态、parallax 参数、图组事件层、最小接入例，全部与实现一致。
- EDITOR_MCP.md 工具表 11 工具 + 22 操作与 `src/mcp/workbench.gd` / `src/mcp/edits.gd` 完全对应；`manifest_validation.gd:22` INPUT_TYPES 14 种与 `field_widgets.gd` 控件能力一一对应。
- 小瑕疵（不影响正确性）：`src/canvas/canvas_draw.gd:188` 与 `:265` 注释逐字重复；`src/canvas/geometry_draw_tool.gd` 头注释为英文，与全库中文注释风格不一致。

## 3. 任务二：问题清单与方案

### 3.1 P2 — 性能

**P2-1 层操作走双全图快照（layer_ops 内 6 处：layer_add/del/move/set_tile_grid/apply_tile_layer_copy/_set_layer_field）**
- 现象：先 `push_undo`（内部 `MapFormat.encode(cvs.extract(), true)` 做一次全图快照），随后自己再 `extract()` 一份用于在快照上改——同一帧内两份全图快照。
- 影响：大图单次层操作双倍耗时（单次 `extract()` 在 1000×1000 图约百毫秒级），且增删层是低频操作，实际体感有限，但属于纯浪费。
- 方案：给 `push_undo` 加返回值（返回 encode 前的快照字典；存量 30+ 调用点忽略返回值即可，GDScript 不告警），层操作改用 `var snap := cvs.push_undo()`，删除第二次 `extract()`。

### 3.2 P3 — 边缘崩溃与健壮性

**P3-1 `mcp/edits.gd:226` `_cells` 对未迁移 v5 碰撞条目崩溃**
- 现象：`int(row[0] if tiles else row.x)`——collision 行为 v5 数组形态时，`row.x` 对数组取属性直接脚本崩溃。
- 前提：校验器已把数组条目标为 error（`map_data_validation.gd:112`"v5 arrays are retired"），正常流程先 validate 就能看到；但 MCP `collision.set` 直接操作未迁移工程时是**崩溃而非干净报错**，且 MCP 单线程 `_busy` 互斥下一次崩溃卡死后续请求。
- 方案：`_cells` 构建索引前对非 Dictionary 行给一条"需要先跑 tools/migrate_project.gd"的干净错误返回（一行改动），或 validate 前置到 apply_changes 的 collision.set 分支。

### 3.3 P3 — 架构债务

**P3-2 跨模块私有访问**
- `media.gd` capture 面板截图直接调 `steps_panel._set_steps_view()`；`_navigate` 直接调 `_library.open()`。
- `reference_view_library.gd` 绑定 `content_editor._form._resolve_options.bind(true, true)`——跨两层私有链。
- `workbench.gd` 取选项列表直接伸进 `content_editor._form.project_reference_options`。
- 影响：这些私有成员成为事实上的模块接口，改名/重构会静默破坏 MCP 渲染与引用视图，且无法从类内可见性判断被谁依赖。
- 方案：提升为公开方法并补一行注释声明"供 MCP capture/引用视图跨面板调用"；`_resolve_options` 这类带布尔位参数的，封装成两个语义化包装（如 `options_for_bind()` / `options_for_library()`）。

**P3-3 巨型函数**
- `project_content_library.gd` `_open_flow` 约 450 行闭包链（流程关系图节点点击 → 布局 → 渲染 → 交互全在一个函数里）。
- `app.gd` `_shortcut_input` 约 220 行 match，键盘通道全部内联。
- 影响：修改任一交互行为要在几百行里定位上下文；两处是全库最大的两块可读性债务。
- 方案：`_open_flow` 按阶段拆（`_flow_layout` / `_flow_render` / `_flow_hit`）；`_shortcut_input` 按"画布手势 / 选点会话 / 全局快捷键"拆成三个私有方法，match 只做分发。

**P3-4 控制器拆分的转发样板**
- 现状：canvas/ui 子控制器（RefCounted + `_init(host)`）普遍带同名转发属性与同名包装方法（如 `extract()` → `cvs.extract()`、`host` → `_host_ref.get_ref()`），单文件 30-60 行纯样板。
- 评价：这是"搬动文本零改动"的拆分代价，方向正确（保持调用点不变），但样板已积累到需要正视的量级。
- 方案：不再新增转发（新代码直接引用 `host.xxx`），存量转发在下次触碰对应文件时顺手清理；不做一次性大扫除（改动面大、收益低）。

**P3-5 `content_store._cache` 无上限**
- 现象：内容文件读缓存是 static 表（路径→{digest, data}），跨工程不清表、无上限，长会话累积驻留。
- 缓解因素：命中比对 digest 不吃脏数据（L132）；写/删均失效对应路径；单文件 KB 级，实际风险低。
- 方案：不加 LRU（避免无谓复杂度）；切工程时顺手 `_cache.clear()` 一行即可，也可不动，仅记录。

**复查中证伪、不列入问题的候选点**
- `undo_history.gd:720-723` "双重 duplicate"：浅拷贝后先 erase 将重建的大键（tiles/collision/objects）再深拷贝，避免深拷贝即将丢弃的大数组——是正确优化，非冗余。
- MCP publish 不轮转 `.history`：与人工保存共用 `DocumentCommit.apply`，内容文件走 `write_ex` 统一轮转，地图不轮转是设计约定（.history 只保内容文件），非不一致。
- push_undo 快照链路再核：`push_undo`→`_snapshot()` = `MapFormat.encode(cvs.extract(), true)`，单次登记 = 一次全图 extract + encode，符合"改动前压栈"设计；层操作双 extract 见 P2-1，属调用方重复，非 extract 自身缺陷。

## 4. 任务三：2D 全类型覆盖分析

### 4.1 已覆盖（编辑入口存在，即"可做"）

按游戏构成要素逐项确认（判定标准：编辑器里有实际编辑入口，不依赖外部工具）：

- **视角/投影**：正交、等距、六边、三角/斜基格（`grid_basis`/`tri_tile_view.gd` 全套自绘与拾取），格系统双基（格基 + 世界基）。
- **地形**：多图集、图集三级导航、任意层栈（纯 z 槽/ySort/parallax/offset/scale/blend/tileGrid）、层码重定位。
- **碰撞**：矩形/45°/135°/one-way（tileGrid 槽）+ 对象条目 {x,y,type,shape}，图组共享碰撞与叠加显示。
- **实体**：prefab 场景与 visual 声明两形态，帧动画、sortAnchor、sizeFields、props 白名单重建（保留游戏侧自定义键）、任意 transform。
- **逻辑组装**：功能绑定（七类引用 + 流程目标四形态）、步骤时间轴（区间索引/拖拽补丁/时钟与音频参考）、条件、触发、音频声明池。
- **结构**：有限格图（多空间格图编辑器）、图组（事件层/drawOrder/共享碰撞）、世界布局（分块/生成键）、屏幕布局（焦点导航/热区/本地化 textLocales）、启动入口/平台槽位。
- **外围**：地图生成器（声明参数/预设/继承来源）、MCP 批量编辑（22 操作/草稿/候选/publish 冲突基线）、试玩四入口（project/map/content/screen）、撤销/草稿恢复/引用完整性检查。

### 4.2 缺口（无编辑入口 = 完全做不了），按影响排序

**缺口 1：瓦片级动画**
- 现状：瓦片记录是静态六元组 `[x,y,资产id,ax,ay,alt]`，画布与 palette 均无动画维度；游戏侧 TileSet 构建也不支持动画切片。
- 挡住的游戏：水面/岩浆/传送门等循环地形动画——所有带动态地形的游戏（RPG/平台/塔防）。
- 方案：声明池加 `tileAnimations`（资产级声明：图集内帧序列 + fps），瓦片六元组不动（第 7 位可选 alt 扩展或按资产默认），游戏侧构建 TileSet 时展开成 TileSetAtlasSource 动画切片；编辑器画布画第 0 帧并打"动画瓦片"角标，palette 预览播循环。此方案不需要动地图格式与撤销快照。

**缺口 2：autotiling（地形自动衔接）**
- 现状：瓦片 alt 仅 8 种 D4 变换，无地形集合/掩码规则；大面积地形需手动选边角衔接片。
- 挡住的游戏：任何需要大片连续地形（草地/悬崖/水面边缘）的游戏——工作量大时实际上等于"做不了"。
- 方案：游戏侧声明地形组（terrain set：成员瓦片 + 掩码表或 peering bits），编辑器在画笔层实现掩码求解（涂抹时按邻域自动选瓦片+alt），MCP tiles.set 复用同一求解器；地图格式零改动（仍是六元组，只是选片逻辑自动化）。

**缺口 3：碰撞多边形自由度（降级：接近覆盖）**
- 现状：collisionTypes 声明池合法 shape 枚举含 **polygon**（manifest_validation.gd:195：rect/triangle_r/triangle_l/circle/polygon），类型级模板可表达任意轮廓；实体 visual poly/path（geometry_draw_tool 有完整绘制入口，含孔洞）可承载自由轮廓障碍。
- 剩余缺口：地图 collision[] 条目无**每实例顶点编辑**入口——碰撞画笔画格+类型模板，"一格一个多边形模板"能拼出复杂障碍，但像素级贴合仍需游戏侧在类型声明里备好模板集，编辑器内不能逐实例调顶点。
- 挡住的游戏：基本不挡——可拼装出复杂障碍；像素级贴合场景（精确斜坡）会繁琐但不失能。

**缺口 4：实体组合与嵌套复用（无"保存为组/实例化组"）**
- 现状：区域复制粘贴有（region_ops/剪贴板协议），但没有把一组实体+瓦片存成可复用模板、放置时统一替换内容映射的入口；也没有嵌套实例（组里放组）。
- 拦下的游戏：塔防波次/房间模板（Roguelike 房间、塔防炮塔组合、RPG 村庄套路化拼装）——每个副本都要重新摆一遍，工作量大到实际不可用。
- 方案：分两步——① 组模板：地图文档顶层 `templates` 段存 {name, tiles/objects 映射 + 内容映射表}，画布多选后"保存为模板"，palette 加模板页签，放置时按身份码规则发新实例码并按映射表克隆内容（复用 clone_plan.build 的 scoped_ids 机制）；② 嵌套不必做（有模板页签+MCP 批量已够，嵌套会让撤销/引用检查复杂化，收益低）。

**缺口 5：内容级本地化工作台**
- 现状：屏幕布局有 textLocales（screen_layout_form 有本地化编辑），但**内容 fields 的文本**（对话、任务描述）没有本地化编辑入口——field_widgets 的 string 输入只有单值。
- 拦下的游戏：任何多语言内容型游戏（AVG/ RPG / 叙事探索）——对话文本无法按语言维护。
- 方案：不加新控件家族——在 field_widgets 的 string 控件上加"语言页签"变体（声明 input type=string+localized:true 时启用），值改为 {zh: "...", en: "..."}；游戏侧运行时按当前语言取值。MCP content.put 的 fields 已是声明驱动，天然兼容。

### 4.3 结论

- 判定标准回顾：做不了 = 完全没有可做的入口。按此标准分档：缺口 1（瓦片动画）、缺口 5（内容本地化）**完全无入口**；缺口 2（autotiling）有入口但工作量不可行（大面积手动选边角片）；缺口 4（组模板）有区域粘贴但无模板复用；缺口 3 已降级为"繁琐但不失能"。
- 全部 5 个缺口都不需要动地图格式核心（tiles 六元组、objects 条目、身份码体系全部不动），都能在现有声明池/画笔/表单框架内落地。
- 优先级建议：缺口 4（组模板）> 缺口 2（autotiling）> 缺口 5（内容本地化）> 缺口 1（瓦片动画）> 缺口 3（可暂缓）。
- 全部 5 个缺口都不需要动地图格式核心（tiles 六元组、objects 条目、身份码体系全部不动），都能在现有声明池/画笔/表单框架内落地。
- 优先级建议：缺口 4（组模板）> 缺口 2（autotiling）> 缺口 5（内容本地化）> 缺口 1（瓦片动画）> 缺口 3（可暂缓）。

## 5. 任务四：架构与效率

### 5.1 做得好的（有意识的设计纪律，值得保持）

- **单写盘入口**：所有项目数据落盘走 `MapStore.write_text`（tmp+原子替换）→ Recovery；多文件提交走 `DocumentCommit`（预检 → pending log → 写 → 清 log），崩溃恢复语义完整。
- **校验与存储分离**：`MapValidator`/`manifest_validation`/`map_data_validation` 纯函数校验器，写前校验（D11：坏图不落盘覆盖好文件）。
- **声明驱动一致贯彻**：assets/functions/conditions/steps/triggers/audio/screenModules 声明池，三池字段码共用空间 + ensure_codes 补码；编辑器不硬编码游戏语义，新增能力=加声明而不改编辑器。
- **缓存键纪律**：*_rev 体系（project_rev/mtime/digest）统一失效锚点，画布引用集/缩略图/图集导航等派生缓存都能正确失效；写后失效（D3）防同秒重写吃脏缓存。
- **撤销系统**：差量条目 + 整图快照混合栈，内容差量带两侧摘要防外部改写（refused_external 语义）；手势/恢复/保存期的竞态防护（_restoring/doc_busy/重建窗口哨兵）成体系。
- **MCP 分层**：server（传输/安全）→ workbench（工具表/schema）→ drafts（状态/基线/快照历史）→ edits（22 操作）→ media（截图/渲染/试玩），职责单向依赖，schema 与实现同表维护。
- **面板令牌纪律**：异步回调带会话代数+revision+manifest 校验，过期丢弃——异步 UI 竞态在全库是一致的处理方式。

### 5.2 债务与边界（已在 §3 编目，此处只说结构性判断）

- 三个结构性债务（P3-2 私有访问 / P3-3 巨型函数 / P3-4 转发样板）全部集中在 **UI/集成层**；数据层与 MCP 层没有同类问题。这个分布本身说明分层是对的——债务不会传染核心。
- 复杂度守恒做得好：编辑器把复杂度压在"声明校验 + 引用检查"两处集中处理，没有在画布/表单各处零散设防（符合 AGENTS "不防御性编程"约定，也确实简化了主干）。
- 效率上无热点误用：画布绘制有视区裁剪、瓦片块缓存（BLOCK=16）、图集 MRU、引用连线 O(n) 索引；MCP 请求有 deadline 与单请求互斥。真正的效率问题只有 P2-1（层操作双 extract）一处。

## 6. 优先级行动清单

| 级别 | 事项 | 动作 |
| --- | --- | --- |
| P2 | 层增删双全图快照（layer_ops，P2-1） | push_undo 加返回值，层操作复用；layer_ops 内调用点各删一次 extract |
| P3 | MCP `_cells` 对 v5 碰撞数组崩溃（P3-1） | `_cells` 索引构建前对非字典行返回干净错误（一行） |
| P3 | 跨模块私有访问（P3-2） | 提升公开方法+语义化包装；触碰相关文件时顺手做 |
| P3 | 巨型函数 `_open_flow` / `_shortcut_input`（P3-3） | 按阶段拆；下次触碰时做 |
| P3 | content_store._cache 切工程清空（P3-5） | `_cache.clear()` 一行，可不做 |
| 缺口 | 组模板（4.2 缺口 4） | 新功能：templates 段 + palette 页签 + clone_plan 复用 |
| 缺口 | autotiling（4.2 缺口 2） | 新功能：terrain set 声明 + 画笔掩码求解器 |
| 缺口 | 内容本地化（4.2 缺口 5） | 新功能：string 控件语言页签变体 |
| 缺口 | 瓦片动画（4.2 缺口 1） | 新功能：tileAnimations 声明 + 游戏侧展开动画切片 |
| 文档 | canvas_draw 重复注释、geometry_draw_tool 英文头注释 | 两行清理，随下次触碰 |

## 7. 复查用验证记录

- flow_target 四形态 kind 判定（flow_target.gd:35 全文）✓
- `_wav_clip` WAV 头字节布局（44 字节 RIFF 手算核对）✓
- rotate_history 调用点全集（content_store:189/247、drafts:208、map_store 定义）✓
- manifest_validation INPUT_TYPES 14 种 ↔ field_widgets 能力一一对应 ✓
- map_data_validation collision v5 数组形态=error（L112）、collisionTypes polygon 合法（manifest_validation:195）✓
- push_undo→_snapshot→encode(extract) 单次快照链路 ✓
