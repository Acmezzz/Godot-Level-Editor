# 2D 游戏编辑器全面审查 R2（2026-11-28）

## 0. 审查范围与方法

- 基线：上一轮审查（[EDITOR_FULL_REVIEW_2026-11-28.md](EDITOR_FULL_REVIEW_2026-11-28.md) §1-§7）之后，项目以 `927ac6c`（22 文件，+136/−50）落实修复；本轮 = **diff 驱动复核 17 个 src 改动文件 + docs/tools 改动逐行读 + 其余 101 个未改动文件沿用上轮逐行基线**（两轮之间无其他提交，工作区干净）。
- 范围修正：`src/` 实际 **118 个 GDScript**（core 2 / assets 4 / content 16 / map 13 / project 18 / canvas 18 / ui 41 / mcp 5 / app.gd 1）。上轮文档写"109"是漏算 assets 4 + mcp 5，本轮起更正；FEATURES 职责表对应核对口径同更正（118 条全对齐）。
- 方法：不采信注释与旧结论；每个修复都追实际数据流（push_undo 快照链、validate 错误传播、公开包装的调用点全集）；四缺口按"能否创作**和**执行该内容"标准独立重判，不沿用上轮口径。
- 本轮文件：`EDITOR_FULL_REVIEW_2026-11-28_R2.md`；上轮文档 §8 已由项目方补记核实与处理结果，本轮在其基础上独立复核，不重复引用其结论作依据。

## 1. 总体结论

- **修复核验全部通过**：上轮 1 个 P2 + 3 个 P3（性能/健壮性）修复正确且方案克制；P3-3/P3-4（大函数/转发样板）按项目方决定暂缓，合理。
- 新发现仅 **2 处 P3-2 同型残留**（跨面板私有访问漏改 2 处）+ 1 条记录级说明，无新 BUG、无回归。
- docs 三个新节（复用与动态素材 / MCP validate 提示 / STANDARD 动画与本地化约定）与实现一致，且把上轮缺口改写成了可操作的工作流说明。
- 任务三口径修正后（按"能否创作和执行"），**上轮缺口全部降级为效率/体验/精细度缺口，无阻断性缺口**；编辑器符合"2D 全能"的能力标准，剩余是手工量问题（§4 排序）。
- 一句话：**R1 的问题清单已清账（除 2 处漏改），覆盖结论维持"主链路全覆盖"，下一档价值在效率工作台（组模板 > autotiling > 本地化 > 动画预览）。**

## 2. 任务一：文档 ↔ 代码对齐（R2）

**结论：对齐保持良好。R1 后的新增文档全部与实现一致；"109 文件/零漏列"说法由 118 更正。**

- FEATURES 新增「复用与动态素材」节：整图复制（ClonePlan.whole_map_document，map_file.gd:197 调用）、跨图区域粘贴（region_ops.gd:543 格拓扑兼容检查）、图组/生成器/瓦片动画约定、"当前没有独立的区域模板库或嵌套实例"——逐条与代码一致，如实声明了没有的东西。
- FEATURES 补齐 `src/mcp/` 5 文件职责表（server/workbench/drafts/edits/media），描述与实现一致。
- EDITOR_MCP.md 新增 validate 提示（找不到可编辑地图→先无参 validate；旧碰撞数组→tools/migrate_project.gd）与 edits.gd 新错误文案、workbench._validate 字段级错误传播一致。
- GAME_SIDE_STANDARD 新增两条约定：①瓦片动画入口 = `(资产 ID, 图集坐标)`，运行时切帧，**不要把帧数写进 alt**（与 map_format.gd:16 alt=变换位 0-7 定义一致）；②内容本地化走 `array`/`of: "record"` 字段（choice 语言 + string multiline），textLocales 是屏幕文本另一套格式——与 field_widgets 的 record/array 能力一致。
- 上轮"小瑕疵"两项已修：canvas_draw.gd 重复注释已删、geometry_draw_tool.gd 头注释已改中文。

## 3. 任务二：问题清单（R2）

### 3.1 上轮问题状态账（逐项核验）

| 上轮编号 | 处理 | 核验结论 |
| --- | --- | --- |
| P2-1 层操作双全图快照 | `push_undo(clone_contents, before)` 新增 before 参数复用已提取快照；layer_ops 5 处（add/del/move/set_tile_grid/_set_layer_field）改为 `extract() → push_undo([], snap)` 单次提取；layer_del 免除整图 deep copy | **修复正确**。`apply_tile_layer_copy` 保留双段也正确——预览候选图是"改动后"文档，不能替代"改动前"撤销快照（undo_history.gd:42 新签名 `before.is_empty()` 分支与 editor_canvas.gd:1733 转发一致） |
| P3-1 v5 碰撞数组崩溃 | 项目方复现推翻了 R1 的崩溃定性：正常 MCP 链路读图时 `MapStore.decode_text` 校验即拒绝旧数组，`_cells` 不可达；真正缺陷是**无参 validate 丢弃字段级原因** | **修复正确且比 R1 更准**。workbench.gd:328 区间对 unreadable 图逐个 `Maps.read_path` 列出 `maps.<名>.<字段>` 级错误；`tiles: null` 漏网由 map_data_validation.gd:56（`data.has("tiles")`）在共同入口拒绝。测试用例锁住 `maps.旧碰撞地图.collision[0]` 断言 |
| P3-2 私有访问 | content_editor 新增 4 个公开入口（open_project_library / project_reference_options / saved_reference_options / open_content_timeline） | **大部分修复，2 处同型残留**（见 3.2） |
| P3-3/P3-4 大函数/转发样板 | 保留现状，待实际变更时按职责拆 | 暂缓决定合理（改动面大、无功能影响）；R2 维持记录 |
| P3-5 内容缓存跨工程不清 | `ContentStore.clear_read_cache()` 挂 `_clear_project_session`；`_ent_thumbs_cache.clear()` 同步挪入同函数（app.gd:238） | **修复正确**，且挪位让缩略图缓存清理更早更稳（`_clear_project_session` 是切工程必经） |
| 小瑕疵×2 | 已修 | ✓ |

### 3.2 新发现（本轮唯一实质问题：同型漏改）

**N1（P3）`map_flow_dialog.gd:55` 跨面板私有访问漏改**
- `var library = app.project_shell.content_editor._library`——与 R1 点名的 `media._navigate→_library.open()` 完全同型；修复时 media 已改走 `open_project_library()`，map_flow_dialog 漏改。
- 方案：改为 `app.project_shell.content_editor.open_project_library()`（公开包装已存在，一行）。

**N2（P3）`steps_panel.gd:73` 私有方法调用残留**
- `_resolve_options` 处理器：`_project_target` 分支已改走公开包装 `host.project_reference_options(...)`，但 else 分支仍是 `host._form._resolve_options(decl, _project_scope)`——R1 点名的 `_resolve_options` 私有链在家族内路径上残留。`steps_panel.gd:258/1208` 的 `host._form.reference_context_selector / can_pick_on_canvas` 属 content_editor 家族内对 _form 公开方法的访问，可接受。
- 方案：content_form 加公开包装 `func reference_options(decl: Dictionary, project_scope: bool) -> Array: return _resolve_options(decl, project_scope)`，steps_panel.gd:73 改调之（两行）。

### 3.3 记录级说明（不列问题）

- workbench._validate 的 unreadable 拼接逻辑（`"" if error.path == path else "." + str(error.path)`）依赖 read_path 错误的 path 形态（文件级=绝对路径、字段级=相对路径）；测试已锁住该形态。形态约定目前只在 map_store.read_path 返回结构里隐式体现，若未来 read_path 改变错误 path 语义需同步这里——仅记录，不加防御。
- 新公开包装 `project_reference_options(decl, context, snapshot := {})` 签名与 `_form` 版本一致，map_generator_dialog 的 `.bind("")` 绑定语义不变（context=""）。
- 测试新增 4 断言（旧碰撞拒改+版本不推进 / validate 字段级 / tiles:null 定位）设计正确，失败批次不推进草稿版本的契约被显式锁住。

## 4. 任务三：2D 全类型覆盖重评（R2）

### 4.1 口径修正（本轮最重要的修正）

R1 用"有没有编辑入口"判定覆盖；R2 改用项目方在 §8 提出并被本轮独立复核认可的口径：**覆盖 = 作者能否创作该内容 + 游戏能否执行它**——手工量、缺专用面板不再等同于"做不了"。该口径与设计思想一致：游戏侧提供能力声明，编辑器负责拼装，执行在游戏侧。

### 4.2 缺口重判（R1 缺口 1/2/4/5 + 缺口 3 跟进）

- **瓦片动画 → 可制作**。入口存在：作者摆放图集格，游戏按 `(资产ID, 图集坐标)` 切帧（STANDARD 已定义该入口约定与 alt 语义边界）。剩余边界：画布内无通用动画预览，动态效果要靠游戏实景预览/试玩确认——**体验缺口**。
- **autotiling → 可制作**。手工选片 + 声明驱动的地图生成器已覆盖创作；若做自动衔接，应由地形声明驱动画笔求解并明确拓扑邻接与擦除重算（与 R1 方案一致）。剩余边界：连续涂画不自动换片——**效率缺口**（大地图手工选片负担显著）。
- **自由碰撞轮廓 → 可制作**。碰撞格模板（collisionTypes 含 polygon）+ 实体 visual 轮廓（游戏解释是否障碍）。剩余边界：碰撞层无每格顶点编辑——**精细度缺口**。
- **组模板 → 可制作（四者中手工量最大）**。整图复制（新身份+引用改接）、跨图区域粘贴、图组分别覆盖、生成器铺底，创作路径已闭环；剩余边界：缺"命名、持久化、反复放置"的模板工作台——**效率缺口**。
- **内容本地化 → 可制作**。record 数组字段（choice 语言 + string multiline）可表达任意多语言内容，游戏运行时按语言匹配与回退；textLocales 是屏幕文本的另一套格式，不混淆。剩余边界：缺批量管理语言与缺译检查的专用工作台——**效率缺口**。

### 4.3 结论

- 按"能否创作和执行"标准，**当前没有阻断任何 2D 游戏类型创作的缺口**；上轮 5 个缺口全部降级为效率/体验/精细度缺口。
- 编辑器符合"2D 全能游戏编辑器"的能力标准；距离"顺手"，剩余工作全部是工作台类功能，且都不动地图格式核心与身份码体系。
- 效率负担排序（供排期参考）：组模板工作台 > autotiling 画笔求解 > 本地化工作台 > 画布动画预览。
- 附注：项目方决定不为四缺口新增协议/数据段（当前没有区域模板库、画笔不自动换片等已在 FEATURES 如实声明）——R2 认可该决定：先让工作流文档化，等真实制作反馈再定协议形态，避免过早设计。

## 5. 任务四：架构与效率（R2）

### 5.1 修复质量评价（架构视角）

- **push_undo(before:) 是教科书式的向后兼容扩展**：新参数可选、存量 30+ 调用点零改动、语义只增不改（before 为空走原 `_snapshot()` 路径），且把"快照复用"的决策留给调用方，没有引入状态或分支复杂度。
- **公开包装的收敛方向正确**：content_editor 现在是跨面板调用的唯一门面（4 个公开入口），MCP 层不再穿透到 `_form`/`_steps` 内部——这符合"宿主持门面，子控制器保持内部"的分层意图。
- **错误信息改进遵循既有约定**：edits.gd 的错误文案指向下一步动作（"请调用 validate"），workbench 把字段级原因从 read_path 透传而不是重新措辞——不造新格式，复用校验器的 path/message 结构。
- **tiles:null 修复选对了层**：在 map_data_validation 共同入口拒绝（所有读者共享），而不是在画布/MCP 各自设防——符合 AGENTS "不在各处设防"约定：单入口拦截优于多点防御。

### 5.2 全局框架再评

- R1 §5 的结构性结论维持成立：单写盘入口、校验/存储分离、声明驱动、缓存键纪律（*_rev）、撤销竞态防护、MCP 五层单向依赖。927ac6c 未触碰这些层，全部基线复核无漂移。
- 债务分布判断不变：结构性债务（大函数/转发样板）仍集中在 UI 层，按项目方决定暂缓；R1 §5.2 的"债务不传染核心"判断继续成立。
- 新增代码风格与全库一致：公开包装带注释声明用途（content_editor.gd:988 区间）、`_set_steps_view` 改返回 bool 顺带把提交失败语义显式化——小改动都在加强既有约定而非引入新模式。
- 结论：**框架设计合理、逻辑分明，R2 未发现新的架构级问题；效率上除已修的 P2-1 外无热点。**

## 6. 行动清单（R2）

| 级别 | 事项 | 动作 |
| --- | --- | --- |
| P3 | map_flow_dialog.gd:55 私有访问漏改（N1） | 改调 `content_editor.open_project_library()`，一行 |
| P3 | steps_panel.gd:73 私有方法残留（N2） | content_form 加公开包装 `reference_options(decl, project_scope)`，steps_panel 改调，两行 |
| 记录 | read_path 错误 path 形态约定（§3.3） | 不加防御；若 read_path 语义变化需同步 workbench 拼接 |
| 效率 | 组模板工作台（§4.2） | 排期首位；协议形态等真实制作反馈再定 |
| 效率 | autotiling 画笔求解 / 本地化工作台 / 动画预览 | 依次后排；均不动地图格式核心 |
| 文档 | 无 | R1 两处小瑕疵已修，本轮无新增 |

## 7. 验证记录（R2）

- push_undo 全调用点：`before` 参数仅在 layer_ops 5 处使用，存量调用点不受影响（editor_canvas.gd:1733 转发签名一致）✓
- open_timeline 安全性：open_content→_mount_target 重建 → _set_steps_view("timeline")→_rebuild_steps_all 新建 `_steps_tl`，成功路径必非 null ✓
- `Maps.read_path` 返回 `{ok, data, errors[{path,message}], warnings, migrated}`（map_store.gd:72），字段级错误 path 为相对路径，与 workbench 拼接约定一致（测试断言锁住）✓
- `data.has("tiles")` 修复语义：显式 `tiles: null` 报 error、省略键仍可读，与测试断言 `maps.空瓦片表.tiles` 一致 ✓
- content_editor 4 个公开包装的调用点全集（media/workbench/reference_view_library/map_generator_dialog/project_content_library/steps_panel）签名与语义等价 ✓
- _ent_thumbs_cache.clear() 挪位：app.gd:238 位于 _clear_project_session 内（切工程必经）✓