# 编辑器全面代码审查报告

日期：2026-11-19　|　范围：`src/` 全部 33 个文件共 8590 行（不审查 tests/，测试待重写）　|　基准 commit：`21e0cb0`

> **状态：全部条目已修复。** 修复分五批落地（`998ace2` / `4125854` / `b64b9ed` / `e4e81af` / 收尾批次），
> P0-1…P0-3、P1-4…P1-13、P2-1…P2-13、P3-1…P3-14 与 O1/O3/O4/O5/O6 的选定方向均已改完，
> 每题的行内说明见下文各节末尾的「修复」行。本文件现在仅作历史记录，不再代表未完成清单。

## 0. 方法

- 分五个子系统：数据层与宿主、画布核心、画布操作、UI 骨架、内容系统。
- 两个子系统由并行审查代理逐行通读（画布核心、内容系统），三个子系统人工逐行通读。
- **每条发现都经过二次复核**：用 rg/Read 回查调用点与上下文后才收录。
- 复核中否决了 1 条代理误报（画布滚轮缩放锚定公式，见 §3 画布节的说明）。
- 级别定义：P0 = 必现 bug / 数据丢失；P1 = 条件触发 bug、数据一致性缺陷、设计硬伤；P2 = 性能 / 维护性；P3 = 打磨。

## 1. 总览

| 级别 | 数量 | 主题 |
|---|---|---|
| P0 | 3 | 剪贴板丢附加功能、平移状态粘滞、碰撞元数据跨图污染 |
| P1 | 12 | 数据同步（4）、协程链（2）、画布空引用（2）、内容/资产面板（3）、死功能（1） |
| P2 | 12 | 性能（6）、缓存生命周期（3）、手势互斥、死代码（2） |
| P3 | 9 | 文案、死状态、样式细节 |

---

## 2. P0 —— 必现 bug / 数据丢失

### P0-1 剪贴板完全不携带 `functions`，复制粘贴静默丢失附加功能

- 位置：`src/canvas/selection_ops.gd:174-201`（copy_selection）、`src/canvas/selection_ops.gd:535-587`（copy_region 实体段）、`src/app.gd:317-340`（Ctrl+D）
- 证据：三条复制路径的剪贴板条目字段都是 `scene / ent_id / dx / dy / flip_h / def_id / props`，全文件 rg `functions` **零匹配**。
- 后果：Ctrl+C/V、Ctrl+X/V、区域复制粘贴（含块内引用重映射）、Ctrl+D 原位复制，全部**静默丢掉实例的附加功能绑定**。绑了对话的 NPC 复制出来就是普通实体，无任何提示。
- 修复：剪贴板条目补 `"functions": (spr.get_meta("functions", []) as Array).duplicate(true)`，粘贴时 `set_meta("functions", ...)`；Ctrl+D 同理。区域粘贴的引用重映射顺带覆盖 functions 里对实例 id 的文本引用（与 props 重映射同一段逻辑）。

### P0-2 Space+左键平移松手后 `_panning` 永久残留，画布粘滞跟手

- 位置：`src/canvas/canvas_input.gd:74-76`（置位）、`canvas_input.gd:175-195`（_on_left_release 无清理）
- 证据：`_panning = false` 全工程只有两处——中键释放（canvas_input.gd:38）与 load_data 复位（editor_canvas.gd:162）。左键释放路径不碰它。
- 后果：Space+左键拖拽平移，松开左键后鼠标一动视图就继续平移，必须再按放一次中键才能解除。必现。
- 修复：`_on_left_release` 开头加 `cvs._panning = false`；根治见 §6-O1（手势状态机收敛）。

### P0-3 `load_data` 复位块漏掉 `_collision_meta`，跨图碰撞类型污染（视觉 + 落盘）

- 位置：`src/canvas/editor_canvas.gd:141-170`（复位块）、`undo_history.gd:79-88`（extract）、`collision_view.gd:41`（分色）
- 证据：复位块清了选区/剪贴板/拖拽/图层显隐等全部状态，唯独没有 `_collision_meta.clear()`。solid+矩形按"零冗余"契约不落 meta、也不落盘（extract 只输出 `[x,y]`），载入新图同格 solid 时走 `set_cell` 直写、不写 meta。
- 后果：A 图 (5,5) 画 one_way → 打开 B 图（同格 solid）→ B 图该格被画成 one_way 琥珀色（CollisionView 读残留 meta 分色）；Ctrl+S 时 extract 把旧图类型写进 B 图文件。**跨图数据污染。**
- 修复：复位块加一行 `_collision_meta.clear()`（undo 恢复同图不受影响，数据随后按条目重写）。

---

## 3. P1 —— 条件触发 bug / 数据一致性 / 设计硬伤

### 3.1 数据同步专题（回应"一个地方改了别处没同步"）

本轮靶向审查的结论：**写盘入口本身是干净的**——全工程只有 MapStore/ContentStore 两个写入口，原子替换 + 写后缓存失效都到位；`MapStore.write` 事务回滚、`.history` 轮转复核无误。不同步的根源不是"写盘没共享"，而是以下四个机制：

### P1-4 实例分布视图 = 磁盘底册 + 内存补丁的混合体

- 位置：`src/ui/asset_panel.gd:238-267`（_instance_distribution）、`asset_panel.gd:331-334`
- 证据：实体清单永远取 `MapStore.read_all`（磁盘 + mtime 缓存），画布只对"磁盘上已存在的同 id 实体"覆盖 props/def；坐标/增删完全用磁盘值。autosave 只写 `.autosave.json`，不回主文件。
- 后果：画布上**新增未保存的实例在分布列表里不出现**；**已删除的实例仍然显示**（改值时 `spr == null → return`，静默 no-op 无提示）；tooltip 坐标是旧位置。
- 修复：`is_cur` 时改从 `host.canvas` 遍历实体生成该图行；或对 spr==null 的行禁用输入并提示"该实例已在画布删除"。

### P1-5 自动保存草稿是黑洞：存得进、捞不出

- 位置：`src/ui/map_store.gd:247`（list_maps 过滤 `.autosave.json`）、`src/ui/map_file.gd:314-331`（autosave）
- 证据：autosave 每 2 分钟把未保存修改写 `<名>.autosave.json`，但地图切换菜单明确排除该文件；草稿只有在用户手动「打开」该文件时才有 A4 草稿归位逻辑接住。
- 后果：自动保存承诺的"保险"在最高频的丢数据场景（改完→切图→手滑放弃修改）里**不存在**：切图确认"放弃修改"后草稿文件其实还在，但没有任何入口提示或恢复它。
- 修复：切图放弃修改时提示"草稿已存为 X.autosave.json，可从 打开 找回"；或地图菜单里对有草稿的地图加标记。

### P1-6 内容表单 SpinBox 每个 tick 全文件写盘 + 左列全重建

- 位置：`src/ui/content_editor.gd:968-969`（value_changed→_set_field）、`content_editor.gd:1001-1004`
- 证据：每个增量 = 读内容文件→改→JSON 全量 stringify→tmp+rename 原子写；再 `_refresh_status_only` → `_rebuild_rows`（左列根本不展示内容信息，纯浪费）。拖一个数值从 0 到 100 ≈ 100 次原子写。
- 对照：asset_panel.gd:121 已有明文口径「编辑态只改内存；失焦/回车统一提交（每击键全量写盘+整表重建太重）」——**本文件漏改**。
- 修复：数值字段改内存 + `focus_exited` 统一提交，与 asset_panel 口径一致。

### P1-7 资产页非当前图就地改值：每 tick 全量读改写 + 挤占历史备份

- 位置：`src/ui/asset_panel.gd:313-318, 345-361`、`src/map_store.gd:102-107`
- 证据：每个 value_changed = `MapStore.read`（全量解析）→ 改 → `MapStore.write`（`_rotate_history` 读当前文件写 .1/.2/.3 + tmp + rename）。拖动一个框的中间值会把 3 层历史备份全部占满，真正的上一版状态反而被挤掉。另外**这条路径不进任何撤销栈**（当前图路径有撤销），行为不一致。
- 修复：与当前图同口径——改内存暂存 + 失焦/松手统一落盘；顺带补齐撤销语义或明示"跨图直写不可撤销"。

### P1-8 删除最后一个资产后右栏残留已删资产的完整详情

- 位置：`src/ui/asset_panel.gd:156-160`（refresh_list 只在 `focus_idx >= 0` 时调 _show_detail）、`asset_panel.gd:387-391`
- 证据：`_delete_asset_checked` 清了 `_edef` 但 `refresh_list()` 在列表为空时不调 `_show_detail`——名称框、stats 行、实例分布、删除按钮全部滞留；残留闭包仍往已 erase 的字典里写，再点删除变成带确认框的静默 no-op。
- 修复：`refresh_list` 在 `item_count == 0` 时也走空态清理（复用 `_show_detail("")` 的 no-match 分支）。

### 3.2 协程链（连续两起事故的同类残留）

### P1-9 undo/redo 恢复链路调用 load_data 未 await

- 位置：`src/core/undo_history.gd:16-23`
- 证据：四个 load_data 调用点中，打开（map_file.gd:244）/尺寸重载（map_file.gd:411）已 await；新建（map_file.gd:103）未 await 但后续无重建依赖（降 P3）；唯独 undo 核心 `_restore` 未 await——`undo()` 返回 true 时重建尚未发生。
- 现状危害被 A7 代数 + 一帧窗口掩盖（人手两次 Ctrl+Z 间隔必大于一帧），但这是结构性缺口：未来任何在 undo 后同步读画布（extract/保存/内容页刷新）的代码都会踩进一帧旧态窗口。
- 修复：`_restore`/`undo()`/`redo()` 改 async 链透传，或把 load_data 拆成同步 `rebuild()` + 外层薄协程。

### P1-10 新建地图 load_data 未 await

- 位置：`src/ui/map_file.gd:103-107`
- 证据：create_map_from_dialog 调 `canvas.load_data` 后立刻 `_set_map_loaded(true)` 并 `_sync_ui()`——发生在重建完成前的一帧窗口里。
- 修复：`await app.canvas.load_data(...)`（同 load_map_file 已修的写法）。

### 3.3 画布空引用与死功能

### P1-11 Alt+左键吸管在 map_root 检查之前分派，未载图报空引用

- 位置：`src/canvas/canvas_input.gd:70-72`（分派顺序 alt → space → paste → map_root 检查）、`editor_canvas.gd:501-503`（_pick_tile 直接访问 terrain）
- 修复：`_pick_tile` 分支移到 map_root 检查之后，或 _pick_tile 入口加守卫。

### P1-12 Home 键 `_fit_view` 无地图守卫

- 位置：`src/canvas/editor_canvas.gd:520-521`、`src/app.gd:369`（同函数里 Del 有守卫、Home 没有）
- 修复：_fit_view 入口加 `map_root`/`terrain` 守卫，或 app.gd Home 分支加 `map_loaded` 检查。

### P1-13 死功能代码：align_selection / bulk_update

- 位置：`src/canvas/selection_ops.gd:308-361, 402-435`
- 证据：上一轮功能性分析已认定 UI 不可达（入口随检查器/对齐栏删除），随 cross_map 批次漏删。`content_store.find_references`（content_store.gd:216-232）同为无调用方死代码。
- 修复：三段整删（连带 `_distribute` 私有助手）。

---

## 4. P2 —— 性能 / 缓存生命周期 / 维护性

### P2-1 K26b 发号每次做全工程引用扫描，被批量操作线性放大

- 位置：`src/canvas/editor_canvas.gd:458-494`（_referenced_ent_ids：read_all 全部地图 + 逐条读全部 events）
- 调用点：每次盖章放置（tool_ops.gd:105）、Ctrl+D 每副本（app.gd:337）、区域粘贴每实体（selection_ops.gd:674）——粘贴 50 实体 = 50 次全工程文件扫描。
- 修复：引用集做会话级缓存 + 在保存/切图/内容提交时置脏。

### P2-2 `_mark` 粒度过粗，涂瓦片也重建实体索引

- 位置：`editor_canvas.gd:643-662`：每格涂刷 → `modified.emit()` + `_ent_by_id_dirty = true`；脏标记在 `_draw` 触发 O(实体数) 索引重建。涂地形根本没动实体集。
- 修复：拆 `_mark(ents_changed := true)`，索引置脏下沉到实体增删/改 id 的唯一路径。

### P2-3 `_draw` 每次重绘 6 遍实体全遍历 + 网格无视口裁剪

- 位置：`canvas_draw.gd:20-29`（网格逐格画线，120×56 ≈ 176 条抗锯齿线）、`canvas_draw.gd:89-256`（连线/角标/landing/占位框/悬停/触发区各自遍历 entities）。鼠标每动一像素 queue_redraw，这些成本每帧全付。
- 修复：一次遍历按 scene/role 分类收集后分段绘制；网格按可视格区间裁剪。

### P2-4 预览每个鼠标事件重建排序实体数组，每次重绘重建全量瓦片数组

- 位置：`content_editor.gd:534-541`（motion→_hit_ent_at→_entities() 构建+排序）、`content_editor.gd:459/477`（重绘重建 terrain/decor 全量数组）。95×56 满图 ≈ 每事件 1 万+ 临时 Array。
- 修复：motion 节流；实例/瓦片数组挂脏标记缓存（`_mark`/`modified` 链路现成）。

### P2-5 缩略图缓存不随清单失效

- 位置：`src/app.gd:200-215`：`_ent_thumbs_cache` 只按项目目录做键。清单新增实体/换 thumb 后调色板不刷新，重启才生效。
- 修复：键加清单 mtime，或保存清单时失效。

### P2-6 tileset 静态缓存无 mtime，外部改图集后本会话用旧纹理

- 位置：`src/canvas/tileset_cache.gd:15-18`：键 = 路径列表 + tileSize，不看文件 mtime。
- 修复：键拼入各图集 mtime（读盘时顺带拿，成本零）。

### P2-7 mtime 秒级粒度：同秒内外部改动被脏缓存吃掉

- 位置：`map_store.gd:20-28`（_read_cached）、`content_store.gd:106-124`
- 说明：自写路径有显式失效，只影响"外部编辑器改文件 + 恰好同秒"场景；量级低但与 [[godot-mtime-cache-pitfalls]] 记忆同族，值得在 read 前对 cache 命中加一次 `Time.get_ticks_msec()` 与 mtime 的组合校验或接受现状记录在案。

### P2-8 手势标志无互斥，多手势可并行叠加

- 位置：`canvas_input.gd:45-64`（motion 各分支无 return 隔离）、`canvas_input.gd:170`（拖动中右键可同时擦除）
- 可复现：拖实体时按中键 → 平移+拖动并行；拖出生点时按右键 → 出生点拖动+实体擦除并行。
- 修复：单一"当前手势"枚举（见 §6-O1）。

### P2-9 隐藏面板 select_inst 全量重建

- 位置：`app.gd:475-478`（entity_selected 无条件转发）+ `content_editor.gd:366-387`（不判可见性就重建左列+右栏）
- 后果：关卡编辑器里每点一次实体，隐藏的内容面板都在做整套 UI 重建 + 读内容文件。
- 修复：隐藏时只更新 `_selected_ent`，进入视图时 refresh_list 再重建。

### P2-10 manifest.functions() 每次全量重扫

- 位置：`manifest.gd:264-292`；function_decl/function_fields/function_name 每次调用都重建归一化字典。content_editor 重建右栏时逐字段调用。
- 修复：manifest 实例上做惰性缓存（_dir 变化或清单保存时失效）。

### P2-11 实例分布 SpinBox 数量随"实例数 × stats 数"线性爆炸

- 位置：`asset_panel.gd:228-229`：_show_detail 同步构建全部行，ScrollContainer 内无懒构建。
- 修复：按地图折叠（默认收起、点开再建）。

### P2-12 内容编辑器/资产页的"选中同步"会绕过撤销

- 位置：`content_editor.gd:366-387`：select_inst 直接写 `canvas.selected_entity/selected_multi` 不发信号、不重绘画布——关卡画布的选择框要等下一次任意重绘才消失。同族：asset_panel 画布路径改 props 有 push_undo（好），但**内容编辑器的 _set_prop/_set_field 对画布 meta 的改动不进撤销栈**，Ctrl+Z 撤的是上一个地图操作，实例绑定/参数改动原地保留。
- 修复：内容/资产面板写画布 meta 的路径统一 `_push_undo()`（或明确宣布"面板改动不进撤销、以即时写盘为恢复手段"并写进约定）。

### P2-13 死代码补充

- `content_store.find_references`（content_store.gd:216-232）无调用方。
- `hover_id` / `set_hover_entity` / 画布"常驻悬停高亮"（editor_canvas.gd:802-803、canvas_draw.gd:232-256）——唯一消费者（实体大纲列表）已删，全工程无写入点，画布悬停高亮永不触发。死状态+死绘制块。
- 修复：随下一次死代码清扫删净。

---

## 5. P3 —— 打磨

| # | 位置 | 问题 |
|---|---|---|
| P3-1 | editor_canvas.gd:463 | `_assign_id` 尾部二次补发 code 不可达（开头已保证非空），死代码 |
| P3-2 | canvas_input.gd:170 | 锁定层/空白处右键也压入空撤销快照（先 push 后判空），Ctrl+Z 一次"无感"撤销 |
| P3-3 | selection_ops.gd:295 | 删除提示"先用属性工具点选"——属性工具已删 |
| P3-4 | palette_panel.gd:233 | 内置种类 tooltip"尺寸在属性面板里调"——属性面板已删 |
| P3-5 | content_editor.gd:1077 | `_ensure_failed` 把缺身份码/非法 kind 一律报"目录权限"，误导排查（对照 _duplicate_from_lib 有准确文案） |
| P3-6 | content_editor.gd:310 vs 658 | 地图名双数据源（canvas.cur_map_name vs app.cur_map_name），协程窗口期可能短暂不一致 |
| P3-7 | content_editor.gd:703 vs 975 | 字符串字段空白处理不一致（固定块 strip_edges，内容表单存原文） |
| P3-8 | asset_panel.gd:303-306 | 有效值超出声明 min/max 时被静默截断显示，首次微调即以截断值覆盖落盘 |
| P3-9 | builtin_kinds.gd:28-31 | merge_into 类型化局部变量让非 Array 防御分支不可达（损坏清单会中断启动而非走兜底） |
| P3-10 | map_file.gd:57-58, 370 | 字符串字面量内嵌真实换行（合法但易被工具误判，建议换 "\n"） |
| P3-11 | app.gd:374-379 | KEY_ENTER 不含 KP_ENTER，小键盘回车进不了内容编辑器 |
| P3-12 | editor_layout.gd:544-559 | _open_popup 两段式居中首帧闪烁（注释自认"小瑕疵"） |
| P3-13 | map_data_validation.gd:63 | 注释还提到「未填」系统（已删），注释会骗人 |
| P3-14 | playtest 内容文件无 .history 轮转 | 地图写盘有 3 层备份，内容文件误写无回滚——内容条目是可复用资产，值得同权补齐 |

---

## 6. 设计层观察（修复方向，非逐行问题）

**O1 手势状态机是画布的结构性风险。** 宿主平铺 8 个布尔手势位（_panning/_drag_paint/_drag_box/_drag_spawn/_rmb_erase/_drag_entity/_move_active/_paste_mode），无互斥、进入/退出不配对。P0-2 和 P2-8 都是这个结构的必然产物。收敛为单一"当前手势"枚举：进入即记录、释放即清零，P0-2/P2-8 整类消失。

**O2 协程 await 契约必须类型化。** load_data/confirm_discard/_open_map_by_name 的 await 要求靠注释跨 5 个文件维持，已经连续出过三起事故（顶栏切图刷新旧画布、切图刷新拿到半重建画布、undo 链未 await）。建议把 load_data 拆成同步 rebuild() + 薄协程外壳，让契约由类型系统保证；委托链逐层 await 写进规范。

**O3 声明式字段编辑器出现了 3 份且提交时机各异。** content_editor 固定块（内存改+即时标脏）、content_editor 内容字段（每 tick 写盘）、asset_panel 分布行/stats 行（内存改+失焦写盘）。同一个"按声明渲染 SpinBox/CheckBox/LineEdit"的组件抽到 Kit 层并统一提交时机（建议项目约定：**离散控件即时写盘，连续控件失焦/松手提交**），P1-6/P1-7/P3-7 会一并消失。

**O4 "实例分布"应单一数据源化。** 磁盘真相 + 内存补丁的混合体（P1-4）是三处入口共享数据的必然摩擦。要么全部走画布内存模型（未打开的图临时 load 成轻量模型），要么接受"分布=已保存状态"并在表头明示"当前图有 N 处未保存改动"。

**O5 "随整图重建的状态"需要一张清单做生命周期审计。** _collision_meta（P0-3 漏清）、_ent_thumbs_cache（P2-5）、tileset_cache（P2-6）、预览数组（P2-4）、hover_id（P2-13 死状态）——同类派生数据有的有脏标记、有的没有、有的连清空都没有。建议一次性列全，统一"换图清空 + 写路径置脏"的约定。

**O6 K26b 引用集应缓存化。** 正确性无可挑剔，但"每次发号读全工程"被批量操作线性放大（P2-1）。引用集缓存 + 保存/切图时失效即可。

**O7 大文件继续拆分。** editor_canvas.gd 831 行剩 130 行纯转发胶水，宿主仍握 generate_collision 系/发码器/_pick_tile 三块可拆逻辑（发码器几乎零耦合，最容易的下一刀）；content_editor.gd 1179 行五件事挤一个 RefCounted，PreviewControl 的绘制+命中（约 200 行）和内容表单/库（约 300 行）可各拆一控制器。

**O8 校验模块的现役角色需要对齐口径。** 校验 UI 已按拍板删净，但 manifest_validation / map_data_validation 仍在清单加载与地图 decode_text 数据路径上服役（作为读入防线，坏数据拒载）。这是合理的"后端"，但与"删除所有校验"的口径存在张力——建议明确它为"数据完整性防线"保留，或者干脆也删（坏 JSON 现在靠 parse 失败兜底）。

**O9 自动保存需要产品设计而不是只写文件。** P1-5 的黑洞感来自"存了但无处可用"。三个选项：切图放弃时提示草稿存在；地图菜单对有草稿的地图加标记；或干脆砍掉 autosave（它的存在感目前为零）。

## 7. 修复路线建议

1. **第一批（数据正确性，半天）**：P0-1 剪贴板补 functions、P0-3 _collision_meta.clear()、P1-8 refresh_list 空态、P1-9/P1-10 await 补齐。
2. **第二批（手感，半天）**：P0-2 平移粘滞、P1-11/P1-12 守卫、P2-8 手势互斥（做 O1 的话直接吸收）。
3. **第三批（同步链，1-2 天）**：P1-4 分布视图数据源、P1-5 草稿入口、P1-6/P1-7 提交时机统一（做 O3 的话直接吸收）。
4. **第四批（性能与清扫，1 天）**：P2-1 引用集缓存、P2-2/P2-3/P2-4 绘制与索引、P1-13/P2-13 死代码删净、P3 批量打磨。
5. **规范沉淀**：O2/O3 两条约定写进项目规范（协程逐层 await；离散控件即时写盘、连续控件失焦提交），防复发。

## 8. 复核记录

- 代理误报 1 条已否决：画布滚轮缩放锚定公式（canvas_input.gd:28）——数学推导 `cam1 = cam0 + L/z0 − L/z1` 数值验证正确，代理把屏幕局部坐标当世界坐标用了。
- 每条 P0/P1 发现均经 rg 全字引用计数 + Read 上下文二次确认；无法验证的传闻未收录。
