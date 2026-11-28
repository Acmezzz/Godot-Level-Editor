# 全面代码审查报告：2D 游戏编辑器 `src/`

**日期**：2026-11-28
**工作流**：工作流 1 · 全面代码审查
**参与成员**：Cody（core/canvas）、Archi（app/mcp/project）、Tessa（map/content）、Rex（ui）、Docu（assets/文档一致性）
**审查范围**：`src/` 全部 124 个 `.gd`（39,329 行）+ `src/editor.tscn`；对照 README、EDITOR_FEATURES、EDITOR_MCP、EDITOR_SOURCE_INDEX、GAME_SIDE_STANDARD、GAME_SIDE_PROTOCOL。`docs/reviews/archive-无需查看/` 为历史归档，按要求跳过。
**方法**：逐文件静态审查 + 调用点 Grep 验证；未修改源码、未运行测试、未启动 Godot。

---

## 📌 TL;DR（执行摘要）

- 整体结论：🟡 **有条件通过**——核心数据层与提交链设计自洽，未发现普遍的数据丢失缺陷；但存在 1 项严重交互缺陷、13 项高危问题，涉及写盘风暴、MCP 并发与状态、跨图数据一致性、协议字段空转。
- 严重度分布：🔴 严重 1 项 / 🟠 高 13 项 / 🟡 中 27 项 / 🟢 低 24 项（其中明确标注为优化项 7 项）。
- 阻塞 / 非阻塞：`steps_panel.gd:1443` 逐格写盘 + 整表重建属用户可复现的严重交互缺陷；MCP 切工程/永久忙碌、预览进程竞态、三角格网格线缺失、格图剪贴板缺层崩溃为高优先级但可排期。
- 审查覆盖：5 位成员共提交 66 条原始发现，去重合并 1 条后为 65 条；全部发现均列于下表，未做删减。

---

## 🎯 核心结论卡片

| 项目 | 内容 |
|------|------|
| 整体评级 | 🟡 有条件通过 |
| 阻塞项数量 | 1（轨号 SpinBox 写盘风暴 + 控件重建） |
| 关键行动项 | 7 条（见行动清单） |
| 高危项数量 | 13（MCP 并发 2、协议/文档 3、UI 2、可视化 1、数据一致性 2、进程/截图 2、其他 1） |
| 建议下一步 | 先修 1 项严重 + 4 项「一行/一处可修」高危（帧基拼写、三角格缩进、颜色校验、码表缓存签名），再处理 MCP 并发模型与测试补齐 |

---

## 🔍 审查发现（按严重度排序）

### 🔴 严重（1 项）

| # | 严重度 | 类别 | 文件:行 | 问题描述 | 证据 / 影响 | 建议修复 | 来源 |
|---|--------|------|---------|----------|-------------|----------|------|
| 1 | 🔴严重 | 交互 / 写盘风暴 | `src/ui/steps_panel.gd:1443-1445` | 轨号 SpinBox 的 `value_changed` 直接触发写盘与整表重建；箭头/滚轮连续改轨号时每变一格写一次内容文件，并销毁重建含自身在内的整个表单，输入被打断、焦点丢失 | `trk.value_changed.connect(... _apply_time_patch(tok, {"track": int(v)}, []))` → `_apply_time_patch`(1643) → `_steps_write`(749) → `_bump_steps_rev()` → `_rebuild_steps_all()`；违反 README「连续控件只在失焦/回车/松手时提交」 | 参照同文件 `at/duration` 走 `text_submitted`/`focus_exited`，或纳入 `_pending_commits` 统一提交；重建改为只刷行 | Rex |

### 🟠 高（13 项）

| # | 严重度 | 类别 | 文件:行 | 问题描述 | 证据 / 影响 | 建议修复 | 来源 |
|---|--------|------|---------|----------|-------------|----------|------|
| 2 | 🟠高 | 并发 / 跨模块 | `src/mcp/server.gd:157-163`、`src/mcp/workbench.gd:189-201`、`src/mcp/drafts.gd:16-20` | 全局 `_busy` 只保护 `tools/call`；`describe_project(path=…)` 可在长工具 await 期间切换工程，恢复后草稿/发布代码读 `app.manifest._dir`，把候选写进另一工程草稿目录或读旧 canvas | `_generate` 在 `await Runner.render(...)`（最长 12s）后才 `drafts.append(...)`；`drafts.folder()` 现算路径 | 切工程工具纳入 `_busy` 或单请求队列；用不可变 ProjectContext 在请求入口快照 root/manifest/digest | Archi |
| 3 | 🟠高 | 协程 / 错误处理 | `src/mcp/server.gd:160-163` | `_busy = true` 后 `await _workbench.invoke(...)` 无兜底复位；任一运行时错误使协程异常终止后，所有 `tools/call` 永久返回「正在处理另一个操作」 | `drafts.state()` 越界索引、`workbench._query` 字段直取等未守卫；`_busy = false` 为顺序下一句 | 用请求状态机 / wrapper 统一复位；外部可控草稿数据先做结构校验 | Archi |
| 4 | 🟠高 | 进程时序 | `src/project/game_preview.gd:97-110` | 进程存活轮询在 `await` 前先检查，进程快速退出时循环体一次都不执行便 `_read_result`，结果文件尚未写完 → 合法预览被误报失败；12s 后 kill 不保证清理子进程树 | `while OS.is_process_running(pid): ... await tree.create_timer(0.08).timeout` 后直接 `_read_result` | 改为以 `result.json` 出现为完成条件的带 deadline 轮询；进程退出后给短宽限期；按进程组 kill | Archi |
| 5 | 🟠高 | 截图坐标 / 安全边界 | `src/mcp/media.gd:67-93` | `capture_editor(target:"control")` 把 canvas 全局变换直接套到视口像素图上；视口有 canvas 变换/缩放时裁剪框偏移或截错目标 | `get_global_transform_with_canvas()` → `Rect2i(area.position * scale, ...)` 用于 `viewport.get_texture().get_image()` | 改用 `get_viewport_transform() * get_global_transform()`，抽公共函数并补单测 | Archi |
| 6 | 🟠高 | 正确性 / 可视化 | `src/canvas/grid_space.gd:536-540` | 三角格对角线绘制的 `return out` 误缩进在 `for i2` 循环体内，`for j2` 只跑第一个 `i2` 即返回；除第一平行四边形列外全部缺少对角半格线 | 已读源码确认：`^I^Ifor i2` / `^I^I^Ifor j2` / `^I^I^Ireturn out` | 把 `return out` 移到两个循环之外（与 `for i2` 同级） | Cody |
| 7 | 🟠高 | 约定 / 竞态 | `src/canvas/editor_canvas.gd:149-165`（尤其 161） | `show_drawing_context` 未 await `drawing.load_data(...)`，违反 README 第 1 条约定；当前靠新建画布的同步路径掩盖，一旦 `load_data` 增加前置 await，后续 `map_root.z_index` / `set_layer_hidden` 会作用在刚 `queue_free` 的旧 root 上 | 调用点 `src/ui/map_file.gd:148`、`src/mcp/media.gd:189` 亦无 await；对比 `undo_history.gd:35`、`layer_ops.gd:43` 正确 await | 改为 async 并 `await drawing.load_data(...)`；三个调用点同步 await | Cody |
| 8 | 🟠高 | 缓存一致性 / 码表 | `src/map/map_store.gd:144-148`（合并 Cody#16） | code_index 缓存签名只含 `_maps_dir + manifest.hash()`，与注释「目录列举清单 + 各图 mtime」不符；清单不变但外部新增/删除/改名地图时，同会话持续返回陈旧码表，影响码分配冲突检测、跨图引用解析、重复码审计。另 `editor_canvas.gd:568-572` 的 1Hz Timer 同步枚举全工程地图码，主线程周期性 IO | 已读源码确认第 130-148 行；下游 `allocate_code`、`identity_error`、`code_conflicts`、`reference_index.resolve_map_code` 均依赖此表 | 签名纳入 `list_maps` + 各图 mtime/size，或显式失效；1Hz 刷新改事件驱动（保存/切换/改名）或后台轮询 | Tessa + Cody（合并） |
| 9 | 🟠高 | 边界崩溃 | `src/map/cell_graph_clip.gd:69-81`（75） | `merge_spaces` 对 `layers[lid]` 无保护索引；跨图粘贴时 mapping 仅由可见层构建，目标层不可见/已删时 KeyError 崩溃 | `if lid != "": space.layer = layers[lid]`，调用链 `world_region_move.gd:209-214` | 改 `layers.has(lid)` 判断，缺失时按函数既有风格返回 `{"error": ...}` | Tessa |
| 10 | 🟠高 | 功能缺陷 | `src/ui/steps_panel.gd:1746` | 播放头添加步骤时帧基判断写成 `"frame"`（单数），而 `_steps_timebase()` 只返回 `seconds`/`frames`/`beats`，条件永远 false；帧基下新步骤 `at` 不取整帧，产生小数帧 | 已读源码确认；与 D2「新输入按声明粒度吸附」矛盾，表单随后显示「小数帧待修」 | 改为 `== "frames"` 并复用 `_steps_clock.snap_step()` | Rex |
| 11 | 🟠高 | 连续控件约定 | `src/ui/field_widgets.gd:910-927` | viewport_ref 的 4 个归一化坐标 SpinBox 用 `value_changed` 直接 `commit.call()`，拖动时每格写一次；注释自承「SpinBox 即改即写」 | 已读源码确认；与同文件 int/float(223-236)、range(330-332) 的失焦/回车/drag_ended 口径不一致 | 改 pending 值 + `text_submitted`/`focus_exited`，统一 flush | Rex |
| 12 | 🟠高 | 协议 / 死字段 | `docs/GAME_SIDE_PROTOCOL.md:990` + `src/canvas/collision_view.gd:23-31,79-84` + `src/ui/editor_layout.gd:487-499` | `collisionTypes[].shape` 文档声明「编辑器画什么形状」，但全 `src` 无任何位置消费该字段；形状实际来自逐格 `collision[].shape`（r45/l45），颜色来自 `color`/id。属声称支持但未实现 | `collision_view.gd` 只用 `decl_of()` 结果取 color/id；形状下拉框硬编码 `["", "r45", "l45"]` | 让类型 shape 真正作为缺省形状生效，或从协议/校验/注释中移除并明确形状由 `collision[].shape` 决定 | Docu |
| 13 | 🟠高 | 协议 / 语义矛盾 | `docs/GAME_SIDE_PROTOCOL.md:994` + `src/assets/collision_types.gd:32-49` | 文档写「声明即整体覆盖」，但显式空池 `collisionTypes: {}` / `[]` 或声明项全非法时，`pool()` 仍回退内置四类；纯 UI/无碰撞游戏无法声明「零碰撞类型」 | `return out if not out.is_empty() else FALLBACK`（第 49 行） | 仅缺键时回退；显式空声明返回空数组；同步修订 §2.8 | Docu |
| 14 | 🟠高 | 校验 / 渲染 | `src/project/manifest_validation.gd:197-198` + `src/canvas/collision_view.gd:23-31` | `color` 校验只检查「是 String」，报错文案却写「must be a #rrggbb string」；非法字符串穿过滤网进入 `Color(cs)`，导入不报错、渲染期才出问题 | 校验条件仅 `body.has("color") and not (body.color is String)`；协议 §2.8 要求 `#rrggbb` | 正则 `^#[0-9a-fA-F]{6}$` 校验 + 消费端安全兜底 | Docu |

### 🟡 中（27 项）

| # | 严重度 | 类别 | 文件:行 | 问题描述 | 证据 / 影响 | 建议修复 | 来源 |
|---|--------|------|---------|----------|-------------|----------|------|
| 15 | 🟡中 | 撤销正确性 | `src/core/undo_history.gd:237-249,258-287` | 新增实例差量不记录 child index，redo 走 `place_object()` append 到末尾；非 ySort 层「撤销新增→重做新增」后同层绘制顺序改变（删除路径有 index，两侧不对称） | `inst_commit_add` 只写 before/after；`_restore_ents` 仅 `undo-of-del` 分支 `move_child` | `inst_commit_add` 写 `"index": n.get_index()`，forward 也按 index `move_child` | Cody |
| 16 | 🟡中 | 状态残留 | `src/canvas/selection_ops.gd:141-160`（151-153） | 组内锁定成员导致整组拖动被拒时，`_drag_entity/_drag_entities/_drag_origins` 已写入却直接 return，无 `begin_gesture` 也无清理；`canvas_draw.gd:258` 据此永久抑制「可整体移动」角标，后续手势判断也可能误判 | 已读源码确认赋值在锁检查之前 | 三个字段赋值移到锁检查通过之后，或提前 return 前清空 | Cody |
| 17 | 🟡中 | 性能热点 | `src/canvas/collision_view.gd:53-63` | `refresh()` 置 `_cell_count = -1` 后 `_draw` 首帧无条件 `get_used_cells()` 全层扫描，注释声称的视口裁剪在该帧失效；逐笔涂刷/擦除都触发一次 | `if _cell_count < 0: cells = layer.get_used_cells()` | 首帧也走 `cell_window` 扫描，或先用 `get_used_rect().intersection(window)` 判定 | Cody |
| 18 | 🟡中 | 缓存陈旧 | `src/canvas/entity_node.gd:156-178` | `_img_cache` 命中后无条件返回，只有负缓存检查 `file_exists`；同路径图片被替换后仍显示旧贴图。与 `tileset_cache.gd:33` 把 mtime 纳入键不一致 | `if hit != null: return hit as Texture2D` | 缓存值改 `{tex, mtime}`，命中时比对修改时间 | Cody |
| 19 | 🟡中 | 撤销历史共享引用 | `src/core/undo_history.gd:524-532` | `_collision_state()` 返回的 `raw` 是 `_collision_meta[c]["raw"]` 字典引用，进历史 before/after 未深拷贝；原地修改会静默改写已入栈状态 | 对比 `set_collision_cell:1309-1310` 对入参 raw 有 `duplicate(true)` | 改为 `...duplicate(true)` | Cody |
| 20 | 🟡中 | 边界崩溃 | `src/canvas/world_region_move.gd:249-254` | `target.layers[clip.objects[i].layer]` 直接索引；`_paste_plan:179` 对 `lid == ""` 是 continue 不写入 layers，剪贴板含空层码实例时跨层粘贴 KeyError | `copy()` 127 行可写入空串键 | `target.layers.get(str(...), 0)` 兜底，或 copy 阶段拒绝空层码 | Cody |
| 21 | 🟡中 | 边界崩溃 | `src/canvas/canvas_draw.gd:127-132` | `manifest.get("screenSize", [640,360])` 后直接 `ss[0]`/`ss[1]`（两处）；清单写成字典/单元素/非数字时 `_draw` 每帧崩溃 | 同函数对 meta.w/h 均有守卫，唯独 screenSize 没有 | 加类型/长度/数值校验 helper | Cody |
| 22 | 🟡中 | 边界崩溃 | `src/canvas/editor_canvas.gd:504-509` | `data.get("spawn", [2,2])` 后直接 `sp[0]`/`sp[1]`；畸形 spawn（字典、长度 1、字符串）导致载图中断 | 同函数对 tiles/collision/objects 均有 `is Dictionary/Array` 守卫 | 校验 Array、长度 ≥2、元素数值 | Cody |
| 23 | 🟡中 | 校验漏项 | `src/map/edge_ref.gd:23-35`（24,29） | `split("|", false)` / `split(",", false)` 丢弃空段，`1,2\|\|3,4`、`\|1,2\|3,4`、`1,,2\|3,4` 被误判合法（size 恰为 2），审计接受不存在的边 | 已读调用链；`test_edge_ref::test_parse_edge` 未测空段 | 改 `split(..., true)` 并严格校验每段非空 `x,y`；补畸形用例 | Tessa |
| 24 | 🟡中 | 边界崩溃 | `src/map/cell_graph_clip.gd:94-110`（109）、41-58（55） | `copy.neighbors.map(... ids[id])` 与 `spaces[sid] = graph.spaces[sid]` 无保护索引；旧草稿/MCP 手工构造的 clip 含外部 id 或缺失 space 时 KeyError | `ids` 仅由 clip.cells 构建；capture 对 space 缺失的 cell 不跳过 | `ids.get(id, id)` 过滤外部 neighbor；capture 加 `graph.spaces.has(sid)` | Tessa |
| 25 | 🟡中 | 边界崩溃 | `src/map/map_view_data.gd:14-16` | `object_layer` 对空 layers 取 `layers[0]` 越界；工作副本/MCP 草稿 layers 异常且对象无 layer 键时崩溃 | 调用点 `layer_stack.gd:13,20`、`canvas_snapshot.gd:74`、`workbench.gd:338` | 空数组返回 `""`；删层后给无层对象重定归属 | Tessa |
| 26 | 🟡中 | 边界崩溃 | `src/content/rel_graph.gd:42-53`（52） | `navigation` 只校验 `edge.to` 是否在 nodes，未校验 `edge.from`；陈旧 graph 中 from 缺失时 `index.outgoing[edge.from]` KeyError | `if not index.nodes.has(edge.to): continue` 后直取 | 同样校验 from 或用 `.get(edge.from, [])` | Tessa |
| 27 | 🟡中 | 身份格式 | `src/content/clone_plan.gd:332-344`（335）+ `src/content/content_id.gd:77-78` | scoped content 克隆新 ID 由 `rfind("-")` 截前缀生成 6 段（如 `MAP-ENT-INST-FN-XXXXXX-YYYYYY`），与 `content_id()` 正规 5 段格式不一致；`is_valid_id` 不校验段数故可通过 | `candidate = "%s-%s" % [cid, target_key]` | 确认是否有意；否则从 4 段身份前缀组装；补段数断言 | Tessa |
| 28 | 🟡中 | MCP 参数校验 | `src/mcp/workbench.gd:114-128,86-102` + `src/mcp/edits.gd:81-86` | `invoke()` 只校验顶层参数类型；`operations[]` 嵌套 schema 依赖零散检查，`project.set.value` 在 schema 里连 `type` 都没有，错误值先写入 batch 再靠整图 validate 兜底 | 已读源码确认非递归 | 递归 schema validator（复用 properties/items/required）+ JSON Pointer 错误路径 | Archi |
| 29 | 🟡中 | 别名契约 | `src/mcp/edits.gd:66-74` + `docs/EDITOR_MCP.md:47` | `_replace_handles` 同时替换 Dictionary 的 key 和 value；文档只承诺值别名，客户端在 `data` 放字面键 `$alias` 会被静默改写 | `out[handles.get(key, key)] = _replace_handles(value[key], handles)` | 只替换 value；或 schema 禁止 `$` 开头键 | Archi |
| 30 | 🟡中 | 协程类型 / 约定 | `src/app.gd:145-146` 等（`map_file.gd:1333`、`media.gd:121,163,337`、`project_shell.gd:89`） | 多条含 await 的委托声明为 `-> void`；漏写 await 时 --check-only 查不出、协程被丢弃。当前调用点均已 await，属结构性风险 | README:74-75 明确警告该场景 | 改为 `-> bool`/`-> Dictionary` 显式 return，让漏 await 变编译期错误；或统一 `_async` 后缀 | Archi |
| 31 | 🟡中 | 空值守卫 | `src/mcp/workbench.gd:216-218`、`src/mcp/media.gd:124-127`、`src/app.gd:628-634` | 工程切换/UI 重建窗口期 `_playtest_ctrl/_map_file_ctrl/project_shell.content_editor` 被置 null，MCP 请求或 `_process` 可落在窗口上导致运行时错误 | `app.gd:219-238` 置空；`app.gd:631-634` 只判 `_map_file_ctrl == null` | 引入 `app.is_session_ready()` 单一守卫 | Archi |
| 32 | 🟡中 | 状态机残留 | `src/mcp/media.gd:418-421` + `src/ui/playtest_controller.gd:135-155` | `playtest(action:"stop")` 只 `OS.kill(pid)`，不立即清零 `_play_pid`、清屏幕草稿、更新 last_run；最多 1 秒内 `status` 仍报 running，回执 token 指向旧请求 | `media.gd:419` 只 kill；`poll_playtest` 每秒才清理 | stop 直接调 controller 统一清理方法 | Archi |
| 33 | 🟡中 | await 委托链 | `src/ui/content_editor.gd:764,862`（对比 880） | `_set_prop_ref` 是 async（929 行有 await），764/862 两处未 await，仅 880 正确；异步写盘结果无法反馈控件提交，失败被吞 | `func _set_prop_ref(...) -> void: var res = await ...set_entity_ref(...)` | 每层 await；若 apply 必须同步则改同步暂存 + 统一提交 | Rex |
| 34 | 🟡中 | 性能热点 | `src/ui/map_file.gd:221-222,197-222` | 整图复制弹窗 `name_edit.text_changed` 每次击键都 `refresh_plan` → `app.canvas.extract()` 全量导出并重算 ClonePlan；大图逐键卡顿 | 已读源码；`_plan_preview:238` 直接 extract | 200ms 防抖或焦点离开/确认时计算 | Rex |
| 35 | 🟡中 | 协程挂起 | `src/ui/map_file.gd:499-514` | 通用确认框用 `while dlg.visible: await process_frame` 轮询而非信号；dlg 被外部 queue_free 或异常隐藏未置 false 时，保存/放弃等关键协程永久挂起 | 未连 `popup_hide` | 改 `await dlg.confirmed` / `await dlg.cancelled` 二选一 | Rex |
| 36 | 🟡中 | 异步竞态 | `src/ui/mcp_draft_review.gd:140-141` | 信号回调 lambda 内直接 await，快速连续切换草稿/地图时多个 show_maps/render 协程并发，可能后发先至覆盖选中态或读过期 plan | `item_selected.connect(func(_i): await show_maps.call(""))` | 加串行令牌/revision 校验（参照 steps_panel 令牌做法） | Rex |
| 37 | 🟡中 | 死代码 / 静默丢数据 | `src/assets/asset_decl.gd:216-233,50-52` + `src/assets/builtin_kinds.gd:34-38` + `src/project/manifest_validation.gd:290` | `_items()/live_list()` 声称支持 `{id: body}` 字典资产，但该分支不可达：校验强制 assets 为 Array，`merge_into` 把非 Array 直接替换成 `[]` 丢弃 | 协议 §2.1 也只写 array；Grep 无字典调用方 | 删除字典分支与注释，或全链路支持并在协议声明 | Docu |
| 38 | 🟡中 | 缓存污染陷阱 | `src/assets/asset_decl.gd:26-45` | `all()` 返回内部 `_cache` 字典本体，`by_id()` 返回声明引用；消费方就地改动会污染全局静态缓存且缓存键不变。当前 src 内未发现实际写入 | `if _cache_key == key: return _cache`；`tests/test_assets.gd::test_live_list_is_original` 本身在改 `by_id()` 返回值 | 返回 `_cache.duplicate(true)`，或明确只读语义 | Docu |
| 39 | 🟡中 | 文档 / 数据一致 | `docs/GAME_SIDE_PROTOCOL.md:393-394` + `src/assets/asset_decl.gd:137-145` | 文档承诺 `palette[].name` 缺省 `"x,y"`、`cat` 缺省资产名再退「未分类」，但 `palette_of()` 恒写 `name:""`/`cat:""`；回退只在 `palette_panel.gd:234,288-293` UI 实现，画布/MCP/详情消费者拿到空串 | `test_palette_flatten` 断言 `pal[1].cat == ""` | 缺省回退下沉到 `palette_of`，或文档注明仅 UI 显示时兜底 | Docu |
| 40 | 🟡中 | 保留码冲突 | `src/assets/builtin_kinds.gd:21` + `src/project/manifest.gd:96,103-112` | 内置 trigger_zone 固定 `code=TZ99`；游戏工程自身声明同码时校验阶段（无内置）能通过，载入时实体码冲突检查直接 `_error`，整个项目打不开 | 已读 merge/冲突路径；文档只说「merge 不覆盖游戏声明」 | 冲突时重发内置码并标 `_codes_issued`，或将 TZ99 列入保留码并在校验前置报错 | Docu |
| 41 | 🟡中 | 缩略图裁边 | `src/assets/image_probe.gd:6-22`（9） | `get_used_rect()` 以「任意通道非零」判有效像素，alpha=0 但 RGB 非 0 的透明边被当成有效像素，裁边失效；`Image.create(...,img.get_format())` 对压缩/mipmap 格式不稳健 | 调用点 `app.gd:280`、`asset_panel.gd:575` 均为缩略图 | 按 alpha 通道判定或裁后校验；压缩格式先 decompress | Docu |

### 🟢 低（24 项）

| # | 严重度 | 类别 | 文件:行 | 问题描述 | 证据 / 影响 | 建议修复 | 来源 |
|---|--------|------|---------|----------|-------------|----------|------|
| 42 | 🟢低 | 提示误导 | `src/canvas/editor_canvas.gd:1454-1486` + `src/canvas/canvas_input.gd:83-84` | `cancel_preview_gesture()` 的 BOX 分支 `pass` 后仍 `end_gesture(); return true`；中键/空格起手平移时若正处于框选，误报「已取消未完成的编辑」 | 已读调用链 | BOX 分支静默 end 后返回 false，或区分返回码 | Cody |
| 43 | 🟢低 | 交互一致性 | `src/canvas/selection_ops.gd:257-258` vs `src/canvas/canvas_draw.gd:222-223` | 尺寸把手绘制半径 `maxf(cell_max()*0.3, 6.0)` 与命中半径 `cell_max()*0.6` 不一致，可点区域约为可视 2 倍，与注释「所见即所点」相悖 | 已读两处 | 抽 `handle_side()` 共用或命中加 2px 容差 | Cody |
| 44 | 🟢低 | 约定（fire-and-forget） | `src/canvas/canvas_input.gd:394-397` + `src/canvas/editor_canvas.gd:1666-1667` | LINK_DRAG 松手 `_finish_link_drag(pos)` 未 await，wrapper 内部有 await；确认框期间新起手存在重入窗口 | `cvs.end_gesture(); cvs._finish_link_drag(pos)` | 改 `await`，或显式标注 fire-and-forget 并加输入互斥 | Cody |
| 45 | 🟢低 | 状态哨兵 | `src/canvas/editor_state.gd:15-20` | 离开碰撞层恢复笔刷判据是 `_brush_before_collision != ""`；进入时 `place_kind` 本就为空则不恢复且哨兵不清（默认 "tiles"，常规路径不受影响） | 已读源码 | 用独立布尔 `_has_saved_brush` | Cody |
| 46 | 🟢低 | 状态恢复 | `src/canvas/layer_ops.gd:203,366-369` | 在碰撞元层执行 layer_add/rename/set_param 时传 `layer_id(active_layer)` 得空串，重载后 active_layer 被强制置 0，用户被踢回第一层 | `_load_snap_layers` 里 `active_layer = ni if ni >= 0 else 0` | 传 `_layer_key(active_layer)` 并按 key 恢复（参照 `apply_layer_move:242,249`） | Cody |
| 47 | 🟢低 | **优化项** | `src/canvas/grid_space.gd:648-670` | `cells_between` 按 1/4 格采样逐点 `pick_cell`；六边每次 9 组多边形命中，超长跳格拖动 O(steps×9) | `steps = ceili(dist / maxf(cell_max()*0.25,1.0))` | 正交/等距走 Bresenham 格步进，六边按距离自适应步长 | Cody |
| 48 | 🟢低 | **优化项** | `src/canvas/entity_node.gd:584-591` | 帧动画计时到点 `_frame_t = 0.0` 而非减 0.125，低帧率下每帧丢超额时间，帧间隔漂移 | 已读源码 | `_frame_t -= 0.125`（while 处理长 delta） | Cody |
| 49 | 🟢低 | 边界 | `src/canvas/region_ops.gd:582-589` | 目标图无图层时 `_paste_layer_index` 返回 0 后 `cvs.layer_tiles[0]` 越界；正常图 load_data 补默认两层，仅畸形数据/重建窗口触发 | 已读源码 | 循环开头 `if li < 0 or li >= cvs.layer_tiles.size(): continue` 并计 missed | Cody |
| 50 | 🟢低 | 悬挂引用 | `src/canvas/selection_ops.gd:891-909` | `transform_instances` 未过滤 `is_instance_valid`，同文件 delete/copy/_live_selection 均有；选中集含已释放节点时崩溃 | `for s in targets: node.rotate_90()` | 入口 filter `is_instance_valid` | Cody |
| 51 | 🟢低 | 边界崩溃 | `src/map/map_view_data.gd:18-26`（21） | `collision_polygon` 空 poly 取 `poly[0]` 越界（r45/l45 形状）；正常传格多边形 ≥3 点，仅脏数据触发 | `var r := Rect2(poly[0], Vector2.ZERO)` | 空 poly 直接返回空 PackedVector2Array | Tessa |
| 52 | 🟢低 | 边界崩溃 | `src/content/step_timeline.gd:46-58`（51,55） | `copy_range` 未校验 first/last，越界时 `timeline[i]` 崩溃；全空区间 origin=INF | `for i in range(first,last+1): ... float(timeline[i].at)` | clamp first/last 并防 INF | Tessa |
| 53 | 🟢低 | 状态判定 | `src/map/recovery.gd:238-280`（239,277） | `scan_pending` 跳过非 Dictionary entry 但计数仍含它，`written == entries.size()` 永不成立 → status 停留 stale，脏日志误判 | 已读源码 | 用有效 entry 数判定 done；补脏日志用例 | Tessa |
| 54 | 🟢低 | 校验宽松 | `src/map/edge_ref.gd:37-43` | `_is_int` 接受前导 `+`（`"+5".is_valid_int()` 为 true），可解析非规范串；canonical_edge 只产标准格式，仅外部数据触发 | 已读源码 | 显式拒绝 `+`，要求纯数字与可选单个 `-` | Tessa |
| 55 | 🟢低 | 健壮性 | `src/content/authoring_catalog.gd:8-15`（10-11） | `functions()` 假设 `map.objects[]` 每项含数组型 functions；非数组或 object 非字典时崩溃 | `for row in object.get("functions",[]): used[row.fn]=...` | 加类型守卫 | Tessa |
| 56 | 🟢低 | **优化项** | `src/content/content_id.gd:72` | `unique()` 每次 `load()` 而非 `preload` 动态加载 content_store，热路径重复取脚本 | `var store := load("res://src/content/content_store.gd") as GDScript` | 改 const preload | Tessa |
| 57 | 🟢低 | 边界 | `src/mcp/drafts.gd:28-29,42-46` | `state()` 对 `draft.history[int(draft.cursor)]` 无边界检查；损坏/手工编辑草稿 JSON 使 MCP 运行时错误而非结构化 error | 已读源码 | 读草稿时校验 cursor 范围，异常返回 `{"error": ...}` | Archi |
| 58 | 🟢低 | HTTP 鲁棒性 | `src/mcp/server.gd:64-75` | 请求头超限回 431 时 `client.bytes` 未清、`offset` 仍 -1，响应体为空；依赖 response 分支兜底关闭 | `if client.bytes.size() >= MAX_HEADER: _reply(client, 431); return` | 显式 `_close(client)` 或清 buffer，附简短原因 | Archi |
| 59 | 🟢低 | **优化项** | `src/assets/collision_types.gd:17-28,32-49` | `_decl_items`（校验）与 `pool`（运行）重复实现 dict/array 两套解析，当前行为一致但无单一真相 | 两函数结构近乎相同却互不调用 | `pool()` 复用 `_decl_items()` | Docu |
| 60 | 🟢低 | 过时注释 | `src/assets/asset_decl.gd:159-160` + `src/project/manifest.gd:294-298` | 注释称「prefab 碰撞形状兜底在 manifest.entity_editor_size 里」，但该函数只读 `editorSize`，缺则 ZERO，从不读 prefab | 已读源码（5 行） | 删除括注或补实现 | Docu |
| 61 | 🟢低 | 过时注释 | `src/assets/builtin_kinds.gd:31-38` | 注释写「局部变量不能标 Array」，下一行却写 `var assets: Array = raw if raw is Array else []`（三元保证类型安全） | 第 31-32 行 vs 35 行 | 修正注释 | Docu |
| 62 | 🟢低 | 口径不一 | `src/assets/asset_decl.gd:77-82` | `category_of_decl` 对 kind 非 scene/entity 的畸形声明默认返回「瓦片」，把坏数据伪装成正常瓦片；`placeable:198-204` 判断更严格 | 已读源码 | 增加 unknown 分支或返回空串 | Docu |
| 63 | 🟢低 | 数值边界 | `src/assets/asset_decl.gd:152-157` | `declared_cell_size` 的 `v > 0 and v == floor(v)` 未排除 INF/NaN；公开 static API，JSON 清单不会产生 | 对比 `grid_space.gd:212-218` 有 `is_finite` | 加 `is_finite(float(v))` | Docu |
| 64 | 🟢低 | 保留键污染 | `src/assets/collision_types.gd:49-57` + `src/assets/builtin_kinds.gd:49-57` | `strip_from` 仅凭 `builtin==true` 剥离；游戏侧未知键碰巧写 `builtin:true` 时保存清单被静默删除；协议未声明该保留键 | 剥离条件只有 `get("builtin",false)` | 仅剥离已知 id，或文档标注保留键并校验禁止使用 | Docu |
| 65 | 🟢低 | **优化项** | `src/assets/asset_decl.gd:129-145`（143） | `palette_of` 循环内为每个缺 ySortOrigin 的条目调 `cell_size` → `by_id` → `all()`，重复取缓存 | 第 143 行 vs 第 93 行已有「别在循环里重复取」优化 | 循环前取一次 `var def = cell_size(m, aid).y` | Docu |

**去重合并说明**：Tessa #1（code_index 缓存签名缺目录/mtime）与 Cody #16（1Hz Timer 同步枚举全图）合并为第 8 项——同一根因与补偿机制，合并后按高优先级计 1 条。其余 65 条一一对应原始发现，未删减。

---

## 🏗️ 架构影响评估（Archi）

当前架构的主线设计是健康的：控制器拆分、差量撤销、内容寻址草稿、原子写 + pending 日志、MCP 只读查询与写入工具边界、Host/Origin/Token 校验均正确；**未发现非原子写或已写文件丢失风险**。主要架构性风险集中在三处：

1. **宿主状态没有不可变上下文**：MCP 各层在每次调用（含 await 之后）现读 `app.manifest`，导致切工程竞态（第 2 项）。建议引入 `ProjectContext(root, manifest, digest)` 在请求入口快照并贯穿全链路。
2. **并发模型是单一布尔**：`_busy` 无复位兜底、无读写区分（第 3 项）。建议升级为 `Idle/Reading/Computing/Publishing` 状态机并排队只读请求。
3. **协程契约靠人遵守**：多处 `-> void` 的 async 委托使漏 await 不可被编译器发现（第 7、30、33 项）。建议非 void 返回 + `_async` 命名 + CI 静态检查。

其他建议：嵌套 schema 统一校验层；`ProjectWriter.commit(entries, plan)` 收敛三层写盘职责；`DraftPreviewSession` 统一草稿预览生命周期；截图坐标换算公共函数。

---

## 🧪 测试覆盖评估（Tessa）

已有专门/充分测试：map_format、tile_layer_convert、cell_graph_tiles、object_geometry、edge_ref（9 例）、map_data_validation、recovery、map_view_data（部分）、map_convert、map_store、content_id、clone_plan、declaration_pool、各 declaration、content_store、timeline_clock、step_timeline、content_value_validation、ref_fields、rel_graph。

高风险但缺专门测试（按优先级）：

| 优先级 | 模块 / 函数 | 理由 | 对应发现 |
|---|---|---|---|
| P0 | `cell_graph_clip.gd` 全部（capture/paste/merge_spaces/translated_rows） | 跨层搬动、space 烘焙、引用重映射零单测 | #9、#24 |
| P0 | `map_store.code_index`「外部新增地图 + manifest 不变」场景 | 现有测试只覆盖写路径失效，漏外部变更 | #8 |
| P1 | `layer_stack.gd`（move/remove） | 删层时 objects/tiles/cellGraph space 三步同步、无层对象归属规则无断言 | #25 |
| P1 | `step_interval_index.gd`（rebuild/query） | 纯数据逻辑零测试，leaf 扩容/空 track/重叠查询/MIN_BLOCK_WIDTH 边界 | — |
| P1 | `keyframe_curve.gd::interpolate` | 只测 valid()；hold 在 ratio==1 切段、smooth 端点、单调性未断言 | — |
| P2 | `authoring_catalog.gd`（functions/used_assets/asset_rows） | 完全无测试 | #55 |
| P2 | `edge_ref.parse_edge` 空段畸形输入 | 直接对应校验漏项 | #23 |
| P2 | `map_flow.gd` declaration_issues/scoped_content/targets | 仅间接覆盖，context 拒绝分支无直接测试 | — |
| P2 | `rel_graph.navigation` from 缺失、`clone_plan` scoped ID 段数 | 各补一条 | #26、#27 |

**验证限制**：本次为静态审查，未运行 `tests/run_tests.gd`、`tools/release_check.py` 或任何 Godot 进程；所有「已验证」结论均沿用 RELEASE_RECORD 的历史记录，不能替代本轮回归。

---

## ✅ 行动清单（按优先级排序）

| # | 行动 | 负责角色 | 紧急度 | 预期完成 |
|---|------|---------|--------|---------|
| 1 | 修复 `steps_panel.gd:1443` 轨号 SpinBox 即时写盘 + 整表重建；改为失焦/回车提交或统一 pending 提交，仅刷新行不重建表 | Rex（UI） | P0 | 立即 |
| 2 | 修复 MCP 并发：`server.gd:160-163` 加 finally 式 busy 复位，`describe_project(path)` 纳入互斥；用 ProjectContext 快照工程根 | Archi（架构） | P0 | 立即 |
| 3 | 修复四处「一行级」高危：`grid_space.gd:540` 缩进、`steps_panel.gd:1746` `frame`→`frames`、`manifest_validation.gd:197-198` 颜色正则、`map_store.gd:144-148` 缓存签名纳入 mtime/目录 | Cody / Rex / Docu / Tessa | P0 | 立即 |
| 4 | 修复数据一致性：`cell_graph_clip.merge_spaces` 缺层索引保护、`paste/capture` 外部 id 过滤、`canvas.editor_canvas.spawn` 与 `canvas_draw.screenSize` 类型守卫 | Tessa / Cody | P1 | 本迭代 |
| 5 | 统一 await 委托链：`editor_canvas.show_drawing_context`、`content_editor._set_prop_ref` 两处、LINK_DRAG；async 委托改非 void 返回 + CI 检查 | Cody / Rex / Archi | P1 | 本迭代 |
| 6 | 补齐 P0/P1 测试：`cell_graph_clip` 全模块、code_index 外部变更、`layer_stack` 删层同步、`step_interval_index`、`keyframe_curve.interpolate` | Tessa（测试） | P1 | 下个迭代 |
| 7 | 协议与文档收口：`collisionTypes[].shape` 生效或移除、显式空池语义、`palette[]` 缺省值下沉、字典资产死代码、TZ99 保留码策略 | Docu（文档） | P2 | 下个迭代 |

---

## ⚠️ 待完善 / 已知局限

- 本轮为**静态审查**：未启动 Godot、未执行测试、未做 GUI/试玩验收；并发与时序类发现（#2、#3、#4、#32、#36）需构造场景复现后确认。
- 严重度为审查团队依据静态证据的排序，不代表实际故障概率；#38、#30 等属「潜在 API 陷阱/结构性风险」，当前调用点未观测到实际错误。
- `docs/reviews/archive-无需查看/` 内的历史审计按要求未读；本报告不重复其结论，也不验证其修复状态。
- `docs/GAME_SIDE_PROTOCOL.md` 1493 行按主题抽样查阅；文档—源码一致性核查覆盖与本轮改动相关的章节，非全文逐行校对。
- 未审计 `tests/`、`tools/`、`mcp/`、`addons/` 与 `dist/`；测试目录仅用于覆盖缺口分析。
- 仓库当前有大量未提交的文档移动（`docs/reviews/*` → `archive-无需查看/`）与 `.import` 未跟踪文件，属审查前既有状态，本报告未改动。

---

## 📚 数据来源 & 成员产出索引

| 成员 | 审查范围 | 原始发现 | 主要结论 |
|---|---|---|---|
| Cody（代码审查师） | `src/core/` + `src/canvas/` 21 文件 / 8775 行 | 20 条 | 三角格网格线、await 约定、撤销顺序、碰撞视图性能 |
| Archi（架构师） | `src/app.gd`、`src/mcp/` 5 文件、`src/project/` 20 文件 | 11 条 + 7 项架构建议 | MCP 并发与 busy、进程时序、截图坐标、嵌套校验 |
| Tessa（测试专家） | `src/map/` 14 + `src/content/` 18 文件 + tests 清单 | 13 条 + 9 项测试缺口 | 码表缓存、格图剪贴板、边引用解析、测试债 |
| Rex（SRE） | `src/ui/` 43 文件 | 7 条 | 轨号 SpinBox 写盘风暴、帧基拼写、viewport_ref 即改即写 |
| Docu（技术文档师） | `src/assets/` 4 文件 + 6 份文档一致性 | 15 条 | 协议死字段、空池回退、颜色校验、资产死代码 |

- 抽查复核：主理人已读取 `grid_space.gd:520-548`、`cell_graph_clip.gd:60-117`、`map_store.gd:125-155`、`editor_canvas.gd:140-169`、`selection_ops.gd:135-164`、`steps_panel.gd:1436-1453,1738-1751`、`field_widgets.gd:906-930`、`server.gd:150-174`、`game_preview.gd:90-114`，确认严重/高危项证据属实。
- 报告生成：2026-11-28，工作流 1（全面代码审查）。

---

> 本报告由工程保障团队 AI 协作生成，关键决策请由人类工程负责人复核。
