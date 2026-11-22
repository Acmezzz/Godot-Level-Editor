# 通用 2D 编辑器 · 第二轮源码审查

审查基线为 `feat/universal-2d-editor-a1` 的 `b4157b9`。生产代码证据来自 `src/`。本轮逐条追入口、实际数据和写入结果，审查两份规范及源码头注释。初版审查、实施方案与发布记录用于对照目标和历史状态。本轮为静态复审，Godot、GUI 手势、性能采样和游戏试玩均未执行。 [初版审查](V1-EDITOR_AUDIT.md) · [实施方案](V1-IMPLEMENTATION-PLAN.md) · [发布记录](../RELEASE_RECORD.md)

## 1. 结论

普通正交地图和常见的实例、功能、步骤组装已有完整的编辑入口。混合层栈、逐图投影、类型化引用、复制计划、地图草稿与步骤工作副本均有实质实现。当前仍有数条日常操作能绕过提交、丢失待恢复内容或写错对象。普通制作已具备做真实试点的条件，距离可承诺安全交付还有一道数据一致性验收。

按通用 2D 编辑器的目标，完成度分布不均。空间型作品的基础摆放最成熟。跨图依赖、特殊拓扑的跨视图一致性、结构化重复数据、时间对齐和屏幕内参考仍限制部分类型。运行时行为、资源生产及游戏规则由游戏侧提供。复审以「模块公开声明 → 编辑器可录入与维护 → 保存重开 → 游戏消费与试玩」衡量每项任务。

优先修正保存、恢复、地图与实例身份、复制和删除。然后统一空间与引用口径，再按真实项目暴露的制作瓶颈补充通用编辑动作。现有四面板三入口可承载这些改造。

> `已证` 表示控制流或数据结构已足够证明差异。`待实测` 表示触发结果依赖引擎、实际项目或时序。`能力缺口` 表示当前缺少通用表达或维护方式。P0 表示可丢失作者数据、误改目标或误报保存成功，P1 表示重要功能或契约失效，P2 表示维护性、易用性或待量化性能问题。

## 2. 代码发现

### 2.1 正式写入与恢复

| 编号 | 判定 | 从入口到结果 | 建议修正 |
|---|---|---|---|
| R01 | P0 · 已证 | 内容页保存用 `content_editor.commit()` 直接写暂存，地图未写。补码时先写内容再发起清单保存，且成功提示覆盖了内容失败分支，也未等待清单结果。资产页同样先报保存成功。内容页选另一个实例也会调用 `commit()`。 [project_shell.gd:144](../src/ui/project_shell.gd#L144) · [content_editor.gd:351](../src/ui/content_editor.gd#L351) · [content_editor.gd:536](../src/ui/content_editor.gd#L536) | 用统一提交入口执行正式写入。选实例只收集控件值，成功提示等所有依赖的结果。 |
| R02 | P0 · 已证，切图后果待实测 | 暂存键只有内容 ID，条目有实体码、绑定下标和数据，缺文档所有权。冲刷遍历全表，无图过滤，也未校验绑定仍存在。切图复用工作台，放弃 A 后保存 B 或撤销 A 的新绑定后保存，仍可能写出旧条目。 [content_form.gd:535](../src/ui/content_form.gd#L535) · [map_file.gd:572](../src/ui/map_file.gd#L572) | 以项目、地图码和绑定身份持有暂存。明确保存、保留草稿、放弃三种去向，绑定删除与撤销同步处理工作副本。 |
| R03 | P0 · 已证 | 草稿可拿到深拷贝的暂存数据，却只写路径与 ID，并把路径固定拼成 `content/`。恢复只加载地图快照。创建绑定、填字段与步骤、写草稿并重启后，地图能找回 ID，尚未落盘的内容无法复原。 [content_form.gd:550](../src/ui/content_form.gd#L550) · [map_file.gd:959](../src/ui/map_file.gd#L959) · [map_file.gd:981](../src/ui/map_file.gd#L981) · [map_file.gd:1000](../src/ui/map_file.gd#L1000) | 草稿保存待提交数据及所需补码，恢复时校验工作副本并按地图码定位正式图。真实内容路径由 `ContentStore` 解析。 |
| R04 | P0 · 已证 | `commit_document` 拿不到日志路径仍继续写。日志在最终收集控件值之前枚举内容。批量暂存的每个成功项会立即从表中删除，整体成功才统一标记日志。第二项失败时，第一项已写与后来新增目标无法完整从日志还原。 [map_file.gd:742](../src/ui/map_file.gd#L742) · [recovery.gd:255](../src/map/recovery.gd#L255) · [content_form.gd:535](../src/ui/content_form.gd#L535) | 先收集并验证全部数据，冻结目标和基线，确保日志可写后再替换。每个文件成功即登记，用计划结果摘要辨认写成但来不及登记的条目。 |
| R05 | P0 · 已证，竞态待实测 | 普通内容字段编辑时取当下的磁盘摘要，演出写内容没有传基线。清单以 mtime 比较，确认后未复验。地图确认覆盖后重新取摘要，可能把确认期间出现的新版本当作已认可的版本。 [content_form.gd:392](../src/ui/content_form.gd#L392) · [app.gd:755](../src/app.gd#L755) · [map_file.gd:869](../src/ui/map_file.gd#L869) | 记录开始编辑时的摘要。每次确认绑定到特定磁盘版本，真正写前重查摘要与会话代次。读取、工作副本、外部新版本应各自可辨认。 |
| R06 | P0 · 已证 | 未保存图改名可直接写图并置干净。已有图改名后对 `meta.name` 补写失败仍可报成功。整图复制先写内容再用通用 JSON 入口写图。外部图复制进项目会带入源地图码与绑定，未证明依赖同源。草稿按码找得到，但改名后草稿的恢复目标可仍是旧名。 [map_file.gd:511](../src/ui/map_file.gd#L511) · [map_file.gd:572](../src/ui/map_file.gd#L572) · [map_store.gd:344](../src/map/map_store.gd#L344) · [map_store.gd:378](../src/map/map_store.gd#L378) | 区分改名、复制和外部导入的身份语义。由同一提交机制处理各自的文件计划，冲突与依赖不足时阻止写入。 |
| R07 | P1 · 已证 | 清单保存只验证序列化后可解析为对象。装载时给无码实体资产补码未随其它声明补码一起置 `_codes_issued`，该码能进入新引用而无需触发正式保存清单。 [app.gd:755](../src/app.gd#L755) · [manifest.gd](../src/project/manifest.gd) | 统一声明发码和变更记录。按落盘形态做语义校验，再提交依赖它的地图和内容。 |
| R08 | P1 · 已证 | 草稿基线来自写草稿时的正式文件。若外部编辑发生在打开之后、写草稿之前，则摘要可把外部版本记作本会话基线。恢复用草稿快照和保存的目标路径，缺少正式装载路径的验证及地图码归位。 [map_file.gd:959](../src/ui/map_file.gd#L959) · [map_file.gd:1000](../src/ui/map_file.gd#L1000) | 草稿基线取本会话已打开或已提交的摘要，恢复前按版本校验并解析目标身份。 |

### 2.2 身份、复制、引用与清理

| 编号 | 判定 | 从入口到结果 | 建议修正 |
|---|---|---|---|
| R09 | P0 · 已证 | `code_conflicts()` 能列撞码图，`code_map()` 却把同码保留为一个后遍历项，引用选择与自检继续使用。图名先于码解析也允许历史名字和现有码冲突。改名无法消除同码。 [map_store.gd:128](../src/map/map_store.gd#L128) · [map_store.gd:185](../src/map/map_store.gd#L185) · [ref_fields.gd:193](../src/content/ref_fields.gd#L193) · [project_audit.gd:70](../src/project/project_audit.gd#L70) | 用可区分唯一、缺失和歧义的索引。码和兼容名字显式分路，撞码时阻止写引用，提供可预览的重发码和修复操作。 |
| R10 | P0 · 已证 | 若 A、C 各有实例 `AB23`，A 的对象引用 C 的 `AB23`，复制 A 到 B 时部分重映射先命中裸实例码，可能改指 B 的副本。普通粘贴构造的两端文档缺图名，跨图策略也可能被判作同图。同一地图配对字段服务多条引用时，不同重映射结果可能互相覆盖。 [clone_plan.gd:240](../src/content/clone_plan.gd#L240) · [clone_plan.gd:324](../src/content/clone_plan.gd#L324) · [selection_ops.gd:710](../src/canvas/selection_ops.gd#L710) | 先解析原引用所属图，再按 `(地图码, 实例码)` 改写。共享配对冲突列入计划并停止执行。 |
| R11 | P0 · 已证 | 区域粘贴跳过不可摆放资产时，实例序号在 `continue` 后才递增，后续实例可能消费上一行的计划项。瓦片可按层码或唯一层名落位，实例仅按层码，找不到时落底层。 [region_ops.gd:191](../src/canvas/region_ops.gd#L191) · [region_ops.gd:335](../src/canvas/region_ops.gd#L335) | 为每条源记录保留明确映射，先解析资产、绑定和图层，再预览、写入与落位。 |
| R12 | P1 · 已证 | `ClonePlan` 从磁盘读取内容，未保存绑定的有效内容可能被报缺失。内容映射按裸 ID。普通与区域粘贴当场创建内容文件，撤销只重建地图，留下孤立副本。 [clone_plan.gd:110](../src/content/clone_plan.gd#L110) · [selection_ops.gd:710](../src/canvas/selection_ops.gd#L710) · [undo_history.gd:71](../src/core/undo_history.gd#L71) | 克隆读取同一个会话快照，用 `(功能id, 内容ID)` 寻址。副本的地图改动与暂存内容组成同一编辑命令。 |
| R13 | P1 · 已证 | 摆放物引用会把 `mapField` 解析结果传为 `_mapKey`。通用内容/步骤控件没有相同的注入路径，目标候选可能仍来自当前图。`asset:` 在内容候选中丢空段，与 `asset::ID` 的声明语义不一致。地图候选还可回退到图名，内容候选未覆盖有效的暂存对象。 [content_editor.gd:689](../src/ui/content_editor.gd#L689) · [content_form.gd:287](../src/ui/content_form.gd#L287) · [ref_fields.gd](../src/content/ref_fields.gd) | 用同一个描述、配对更新和候选入口供摆放物、功能、步骤及审计使用。会话内合并正式与暂存对象，旧名字只用于明确的迁移。 |
| R14 | P0 · 已证 | 内容删除查磁盘绑定、磁盘入边和当前选中实例。未保存的其它活体实例或暂存内容仍可指向被删项，确认后也未重查。自检的孤立判定接收由地图绑定构造的 `used`，仅被其它内容引用的条目也可能被列孤立。 [content_form.gd:1026](../src/ui/content_form.gd#L1026) · [project_audit.gd:127](../src/project/project_audit.gd#L127) | 删除使用包括活体、暂存和磁盘的完整引用图。区分无入口、仍有入边和读不全，确认后按同一范围复验。 |
| R15 | P0 · 已证 | 资产删除依赖实例分布，未保留扫描不完整标志，也无法据此覆盖瓦片和公开字段的一般用法。移除声明后，未知资源的旧 `objects` 行在画布中不再被认作实体，提取时会擦掉原 `code`。 [asset_panel.gd:498](../src/ui/asset_panel.gd#L498) · [entity_node.gd:384](../src/canvas/entity_node.gd#L384) · [undo_history.gd:71](../src/core/undo_history.gd#L71) | 默认停用保码。永久删除前按类型扫描完整引用。未解析的摆放物以原行往返，显式转换才可删除身份。 |
| R16 | P1 · 已证，批量效果待实测 | 问题抽屉清理会先处理脏图保存，再逐图修改并重开当前图。实现已有不完整守卫，也会重跑检查、比对原值。需要补足的是批量作用范围、保存与清理的确认边界、部分成功的呈现，以及清空配对地图后留存实例码的语义。 [issues_drawer.gd:198](../src/ui/issues_drawer.gd#L198) · [project_audit.gd:308](../src/project/project_audit.gd#L308) | 把清理计划和目标摘要纳入统一提交，按配对单元预览和修改，部分完成时逐图列结果。 |

### 2.3 空间、画布与往返保真

| 编号 | 判定 | 从入口到结果 | 建议修正 |
|---|---|---|---|
| R17 | P1 · 已证 | `new_map()` 省略正交键，显式选择正交和沿用项目默认混在一起。校验拓扑时无投影键按正交，画布却走项目默认。三角图在六边默认项目下可通过前者而在后者被解释成另一种空间。加载冻结投影的动作也没有单独标脏。 [map_store.gd:88](../src/map/map_store.gd#L88) · [map_data_validation.gd:50](../src/map/map_data_validation.gd#L50) · [editor_canvas.gd:188](../src/canvas/editor_canvas.gd#L188) | 用统一的生效格空间解析。新图显式选项按原值落盘，缺键保留给旧图继承或明确选择继承。 |
| R18 | P1 · 已证 | `gridBasis` 影响拾取、几何和对象锚点，普通瓦片仍由预设布局的 `TileMapLayer` 绘制。导出解析基向量后返回，未应用 `gridTopology`。三角自绘逐格取图集坐标，未消费 `alt`，且单个绘制节点粒度无法提供逐瓦片 Y 交错。 [editor_canvas.gd:131](../src/canvas/editor_canvas.gd#L131) · [map_export.gd:31](../src/map/map_export.gd#L31) · [tri_tile_view.gd:35](../src/canvas/tri_tile_view.gd#L35) | 共用格原语与瓦片位姿。内建瓦片层用于匹配的预设，其他形状走自绘。无法支持的排序和变换显示限制，之后按参考样例补齐。 |
| R19 | P1 · 已证 | 内容预览的瓦片和网格按 `x * step_x, y * step_y` 绘制，未应用 `alt` 与完整层变换。实体和命中走另一条变换路径，因此在非正交图或变换层上，参考图中的地形与目标可能脱节。画布材质也只挂部分容器和瓦片节点，需验证实体和三角瓦片是否都消费混合模式。 [content_preview.gd:141](../src/ui/content_preview.gd#L141) · [content_preview.gd:168](../src/ui/content_preview.gd#L168) · [layer_ops.gd](../src/canvas/layer_ops.gd) | 共享包含层顺序、变换、可见性、瓦片位姿的只读视图数据。PNG 概览允许色块简化，仍应保留格形、落点与范围。 |
| R20 | P1 · 已证，丢格范围待实测 | 存在但不可解码的图集可使整次 `TilesetCache.build()` 返回空，画布失败分支未统一清理历史图集状态。碰撞内部用源 `0` 和格 `(4,0)` 作为隐形载体。无图集、窄图集及切到坏图集后是否影响碰撞录入、刷擦及保存，需要引擎复核。 [tileset_cache.gd:25](../src/canvas/tileset_cache.gd#L25) · [editor_canvas.gd:131](../src/canvas/editor_canvas.gd#L131) · [tool_ops.gd](../src/canvas/tool_ops.gd) | 隔离单个坏源，坏格仍以原记录往返。碰撞数据独立于用户图集，由专用载体或自绘呈现。 |
| R21 | P1 · 已证 | 校验允许非整数的格号和图集索引，没拒绝同层同坐标多瓦片及同格多碰撞。入画布后转整型或同格覆写。导出/存储与编辑重建会消费成不同结果。提取还会量化实例到 `0.001`，重建碰撞行时只保留已知键。 [map_data_validation.gd:75](../src/map/map_data_validation.gd#L75) · [editor_canvas.gd:188](../src/canvas/editor_canvas.gd#L188) · [undo_history.gd:71](../src/core/undo_history.gd#L71) | 定义必需整数、范围、唯一性和有效变换。无修改保存不得悄悄改写精度及扩展键，遇歧义数据提示作者。 |
| R22 | P1 · 已证，几何细节待实测 | 换投影计划能换算普通对象数据锚点，也明确保留瓦片/碰撞原格号。出生点保存为离散格，换算后受量化约束，不能承诺任意投影都保持完全相同的屏幕像素。层变换、Y 排序脚点和不同拓扑叠加后还要做对照。区域移动与粘贴的格平移需覆盖六边奇偶行和三角半格。 [map_convert.gd:24](../src/map/map_convert.gd#L24) · [map_convert.gd:106](../src/map/map_convert.gd#L106) · [region_ops.gd](../src/canvas/region_ops.gd) | 把连续锚点、离散出生格和格数据分别预览，明示量化误差。用同一空间规则定义区域平移与跨图转换。 |

### 2.4 演出、试玩与日常操作

| 编号 | 判定 | 从入口到结果 | 建议修正 |
|---|---|---|---|
| R23 | P1 · 待实测 | 演出写入有步骤版本保护。停靠内容的身份检查依赖实例码、功能、绑定下标及可选内容 ID，未包含地图码。需验证换到另一张拥有同码实例和同类空绑定的地图时，停靠面板是否总先关闭或重新挂载。 [steps_panel.gd:367](../src/ui/steps_panel.gd#L367) · [steps_panel.gd:495](../src/ui/steps_panel.gd#L495) · [steps_panel.gd:1084](../src/ui/steps_panel.gd#L1084) | 面板令牌带文档代次和稳定绑定身份，地图切换与绑定重排使旧令牌失效。 |
| R24 | P1 · 已证，启动结果待实测 | 结构化启动与命令模板回退确实存在，`_play_args()` 却对可选键 `playtest` 直接取值。模板项目无此键时需要验证 Godot 对缺键求值的实际影响。进程跟踪在非 Windows 返回恒真，Windows 按 `tasklist` 输出判断，只能识别进程消失。 [map_file.gd:1087](../src/ui/map_file.gd#L1087) · [map_file.gd:1205](../src/ui/map_file.gd#L1205) · [playtest.gd:10](../src/project/playtest.gd#L10) · [playtest.gd:55](../src/project/playtest.gd#L55) | 可选键用一致的默认解析。明确游戏进程与包装进程的身份，跟踪不可用时给出可理解的状态。验证路径含空格、模板和启动工作目录。 |
| R25 | P1 · 能力缺口 | 视野框提供 `screenSize` 构图参考。图层、路径、事件及引用可以表达镜头和区块数据。公共字段和画布没有可互选的多个视口、屏幕坐标域、安全区或游戏侧参考图映射。 [canvas_draw.gd](../src/canvas/canvas_draw.gd) · [field_widgets.gd:105](../src/ui/field_widgets.gd#L105) | 先支持带坐标域的参考点和参考矩形，实际试点需要时再接游戏生成的只读预览与热点映射。 |
| R26 | P1 · 能力缺口 | 时间轴有秒、帧、拍转换、速度段、显式起点、轨道与帧序对齐。音频只解析并显示曲目身份，当前没有编辑器内听觉对齐或波形，也没有把指定帧的形状与画布几何一起修改的工作流。 [timeline_clock.gd:157](../src/content/timeline_clock.gd#L157) · [steps_panel.gd:78](../src/ui/steps_panel.gd#L78) · [timeline_view.gd:255](../src/ui/timeline_view.gd#L255) | 先用真实帧拍片段验证保存重开，随后按需要接音频试听和声明驱动的采样帧/形状参考。 |
| R27 | P2 · 已证 | 同步字段已有多种控件和由声明生成的提示，尺寸裁剪及菜单身份也有独立纯逻辑。大量重复的结构化字段仍需拆成多条步骤、多个实体或手录。内容视图定位与演出播放头能在会话内记忆，跨重启定位仍依赖人工。 [field_widgets.gd:105](../src/ui/field_widgets.gd#L105) · [map_resize.gd:18](../src/ui/map_resize.gd#L18) · [map_menu_identity.gd:16](../src/ui/map_menu_identity.gd#L16) · [session_context.gd](../src/ui/session_context.gd) | 先补可增删、调序、逐行校验的声明式重复字段。跨重启定位按项目和地图做轻量本地状态，优先级低于正文恢复。 |
| R28 | P1 · 待实测 | 正式提交在 `dry_run` 分支前就调用 `end_gesture()`，它会清手势类型而不回滚预览。提取时的 `cancel_preview_gesture()` 依赖该类型判断。需要验证拖动或改尺寸未松手时按保存、取消确认或自动写草稿，是否留下未入撤销的预览位置。 [map_file.gd:742](../src/ui/map_file.gd#L742) · [editor_canvas.gd:1088](../src/canvas/editor_canvas.gd#L1088) · [editor_canvas.gd:1314](../src/canvas/editor_canvas.gd#L1314) | 纯盘点保持无副作用。提交前显式提交或取消预览手势并统一记撤销。 |
| R29 | P1 · 已证 | 地图批量读取用 mtime 和尺寸缓存，而正式保存使用摘要。外部工具在同一秒写入同长度文件时，列表、自检或跨图候选可以继续用旧结构。 [map_store.gd:17](../src/map/map_store.gd#L17) · [map_file.gd:901](../src/ui/map_file.gd#L901) | 浏览可用快速索引，破坏性操作与正式写入读取实际摘要。给人工刷新明确的缓存失效入口。 |

## 3. 文档与模块注释

### 3.1 功能文档校订

| 文档位置 | 对齐情况与建议 |
|---|---|
| [§1、§8、§9](EDITOR_FEATURES.md#L9) | 拓扑口径改成「关卡、内容、资产三个一级入口，演出从绑定打开，可弹窗或停靠」。新建和项目内切图分别说明设置与地图选择菜单。`Ctrl+S` 说明焦点及视图分派，保存成功的承诺需等 R01 修复。 [app.gd:344](../src/app.gd#L344) · [top_bar_nav.gd:24](../src/ui/top_bar_nav.gd#L24) · [steps_panel.gd:135](../src/ui/steps_panel.gd#L135) |
| [§3、§12](EDITOR_FEATURES.md#L185) | 两套地图历史写法并存。当前地图是 `editor/history/maps/<地图码或兼容键>/`、上限 20，内容是 `.history` 三轮。旧 `.autosave.json` 需要 `_autosave_of`，普通同后缀地图仍可列出。草稿保全范围写为地图快照及待写清单，待 R03 修复后再承诺恢复字段和步骤。 [map_store.gd:319](../src/map/map_store.gd#L319) · [recovery.gd:180](../src/map/recovery.gd#L180) · [map_file.gd:959](../src/ui/map_file.gd#L959) |
| [§3 尺寸、§4.1 图层](EDITOR_FEATURES.md#L185) | 缩小会预览并裁掉越界瓦片、碰撞和摆放物，撤销粒度为一次尺寸操作。层管理已有参数 UI。混合模式应明确当前呈现范围，完整一致性待 R19 验证。 [map_resize.gd:18](../src/ui/map_resize.gd#L18) · [layer_panel.gd:155](../src/ui/layer_panel.gd#L155) |
| [§6.1、§6.5、§12](EDITOR_FEATURES.md#L371) | 删除事件 `w/h` 只能手改 JSON 的说法。实际有 `sizeFields` 驱动的画布尺寸把手。几何和普通功能表单分别说明，顶点坐标写清是相对锚点的局部像素。 [entity_node.gd:396](../src/canvas/entity_node.gd#L396) · [builtin_kinds.gd](../src/assets/builtin_kinds.gd) |
| [§7.3 内容与演出](EDITOR_FEATURES.md#L498) | 已有内容的普通字段、演出工作副本、新绑定各有写入时机。更新为逐操作的保存表，覆盖选实例、切面板、切图、关闭和试玩。中列是交互参考图，说明几何及绘制限制。 [content_form.gd:392](../src/ui/content_form.gd#L392) · [content_preview.gd:168](../src/ui/content_preview.gd#L168) · [steps_panel.gd:1084](../src/ui/steps_panel.gd#L1084) |
| [§7.4 资产、§10.3 自检](EDITOR_FEATURES.md#L549) | 实例分布用于浏览。删除前的引用覆盖范围按 R14–R16 修正。清除悬空时脏图会进入保存分支，和「自动跳过该图」说法冲突。 [asset_panel.gd:498](../src/ui/asset_panel.gd#L498) · [issues_drawer.gd:198](../src/ui/issues_drawer.gd#L198) |
| [§8 试玩、§10 校验](EDITOR_FEATURES.md#L569) | 保留结构化启动和模板行为说明。退出提示提供进程消失及已运行时长，平台和包装进程限制需写清。校验表分开说明结构错误、可打开的警告及项目级引用问题。 [playtest.gd:55](../src/project/playtest.gd#L55) · [map_data_validation.gd:26](../src/map/map_data_validation.gd#L26) |

### 3.2 游戏接入规范校订

| 文档位置 | 需更正的契约或示例 |
|---|---|
| [§1 文件布局](GAME_SIDE_STANDARD.md#L19) | 正式关卡在 `maps/`。草稿、地图历史、导出和待写日志在 `editor/` 下各自目录。兼容旧草稿按 `_autosave_of` 判定。内容路径必须考虑 `contentDir`。 [map_store.gd:321](../src/map/map_store.gd#L321) · [content_store.gd:40](../src/content/content_store.gd#L40) |
| [§2.2、§3.3、§9.2 图集与碰撞](GAME_SIDE_STANDARD.md#L90) | 游戏侧读取 `collision[]` 并解释类型和形状。固定 `terrain_tiles.tres` 和源 `0` 的 `(4,0)` 是旧接入方式或编辑器内部载体，通用游戏契约移除这两个要求。声明图集才需配置相应图源。 [map_data_validation.gd:100](../src/map/map_data_validation.gd#L100) · [tool_ops.gd](../src/canvas/tool_ops.gd) |
| [§2.3、§2.7 图层与事件](GAME_SIDE_STANDARD.md#L127) | 层参数的录入方式对齐 UI。`trigger_zone` 资产在编辑器并入声明池，游戏按文档实现消费。更新 `sizeFields` 的画布操作并明确尺寸单位。 [layer_panel.gd:155](../src/ui/layer_panel.gd#L155) · [builtin_kinds.gd](../src/assets/builtin_kinds.gd) |
| [§2.4.2、§2.5、§2.5.3 声明](GAME_SIDE_STANDARD.md#L243) | 删除复制时全替换实例码字符串的说法。说明声明类型、`source`、`mapField`、实例域、数组和目标缺失的语义，并标明 R13 的当前 UI 限制。补齐时间基、速度段、显式 `0`、省略 `at` 及试听现状。 [clone_plan.gd:324](../src/content/clone_plan.gd#L324) · [timeline_clock.gd:157](../src/content/timeline_clock.gd#L157) |
| [§3、§4、§5 格式和身份](GAME_SIDE_STANDARD.md#L549) | 保留 v7 六元瓦片、对象变换、无实例码的图片及字段码索引。稳定功能码能保留执行身份，功能人类 id 仍参与目录及新内容 ID，改名需要迁移文件和对应引用。 `gridProjection`、双基向量、拓扑分开描述，按 R17–R19 标明当前支持边界。 [content_id.gd](../src/content/content_id.gd) · [content_store.gd:77](../src/content/content_store.gd#L77) |
| [§6.3 摆放物实例化](GAME_SIDE_STANDARD.md#L815) | 给出图片、prefab、只有 `visual` 的实体和内置种类四条路径。正交锚点片段只适用于正交，同层排序脚点和层变换有独立语义。 [manifest_validation.gd:556](../src/project/manifest_validation.gd#L556) · [entity_node.gd:239](../src/canvas/entity_node.gd#L239) |
| [§6.4 地图读取骨架](GAME_SIDE_STANDARD.md#L874) | 示例虽解析投影和基向量，却没有设置内建 TileSet 的格形、布局或按基向量绘制瓦片，也没有完整搭建三段层。六边 `object_px` 忽略传入的 `anchor`，沿 y 的亚格位移也用了整格高度。示例应先缩小为明确的正交最小版，再提供跨投影对照样例，验证后再标为可运行。 [grid_space.gd:205](../src/canvas/grid_space.gd#L205) · [entity_node.gd:255](../src/canvas/entity_node.gd#L255) · [tileset_cache.gd:25](../src/canvas/tileset_cache.gd#L25) |
| [§7.2 功能例子](GAME_SIDE_STANDARD.md#L1070) | `fields` 以字段码为键，示例查 `f.get(field_by_code.get("F1A2", ""), "")` 会用人类 id `require_flag` 查，合法值被默认值吞掉。直接用 `f.get("F1A2", "")`、`f.get("B3C4", false)`、`f.get("E5D6", 2.0)`，或先转换整个字典。功能索引示例也应接受规范所列的数组和字典两种写法。 [content_form.gd:411](../src/ui/content_form.gd#L411) · [function_decl.gd](../src/content/function_decl.gd) |
| [§8、§10 接入检查](GAME_SIDE_STANDARD.md#L1108) | 移动平台条目补 `"kind": "entity"`，地图查 `asset`。`thumb` 可省。`prefab` 与 `visual` 可提供不同呈现入口。图集和试玩配置按项目需要选择，结构化 `playtest` 或模板其一可用于启动。 [manifest_validation.gd:556](../src/project/manifest_validation.gd#L556) · [playtest.gd:10](../src/project/playtest.gd#L10) |

### 3.3 源码头注释与模块边界

| 模块 | 现有说明需收敛到的行为 |
|---|---|
| `manifest`、`map_store` | 清单定义资产与功能等声明池，图层由地图持有。存储模块的整图复制已含依赖内容复制和引用重映射，应与简单改名的行为分开说明。 [manifest.gd:2](../src/project/manifest.gd#L2) · [map_store.gd:2](../src/map/map_store.gd#L2) |
| `map_file`、`project_shell`、`recovery` | 说明真实的入口及结果。替换、地图历史、草稿和提交日志分别给出各自保证。更新旧 `maps/.history` 文案。等 R01–R08 落地后再写统一时序和日志失败守卫。 [map_file.gd:2](../src/ui/map_file.gd#L2) · [project_shell.gd:144](../src/ui/project_shell.gd#L144) · [recovery.gd:255](../src/map/recovery.gd#L255) |
| `content_editor`、`content_form`、`steps_panel` | 用「控件待收集值、已有文件工作副本、新绑定暂存」解释写入时机。暂存按内容 ID 查，不按功能码。删除逐字节搬迁和同名透传叙事，写清身份令牌、打开基线、落盘责任。 [content_editor.gd:2](../src/ui/content_editor.gd#L2) · [content_form.gd:2](../src/ui/content_form.gd#L2) · [steps_panel.gd:2](../src/ui/steps_panel.gd#L2) |
| `ref_fields`、`project_audit` | 撞码警告与实际解析需要统一。把 `mapField` 配对、缺键及多目标处理写成可验证约束。 [ref_fields.gd:193](../src/content/ref_fields.gd#L193) · [project_audit.gd:70](../src/project/project_audit.gd#L70) |
| `asset_panel`、`batch_ops` | 资产图鉴涵盖图集、场景图片和实体。批改的预览可纯计算，`apply_field()` 通过回调或 `ContentStore` 执行 I/O，头注释应覆盖两种职责。 [asset_panel.gd](../src/ui/asset_panel.gd) · [batch_ops.gd:82](../src/content/batch_ops.gd#L82) |
| `map_export`、`tri_tile_view` | 当前共享部分格基运算。三角节点由层控制器同步显隐，数据瓦片节点常隐。`refresh()` 请求重绘，`_draw()` 仍遍历该层。注释按实际缓存和绘制粒度描述。 [map_export.gd:2](../src/map/map_export.gd#L2) · [tri_tile_view.gd:3](../src/canvas/tri_tile_view.gd#L3) |
| `playtest` | 头注释的 `tracked_kind` 改成实际返回的 `tracked` 和 `kind`，说明 `tracked` 区分进程身份。 [playtest.gd:2](../src/project/playtest.gd#L2) |

规范中建议继续保留资产和功能分离、字段按执行码读取、地图与内容独立版本及游戏负责执行的条款。发布记录应把已跑的纯逻辑断言、入口串接和真人试玩分别列出。记录里三角格消费 `alt`、任意转投影保持出生点像素、提交日志逐文件覆盖等结论需按 R04、R18、R22 重新验收。 [游戏侧规范](GAME_SIDE_STANDARD.md) · [发布记录](../RELEASE_RECORD.md)

## 4. 通用 2D 制作覆盖

**可制作**表示源码已有常规编辑环节，仍需保存重开与试玩验收。**受限**表示可借现有载体、字段或步骤做代表玩法，关键制作任务仍有明显断点。**缺入口**表示表中高阶任务目前缺少合适的声明、录入或验证路径。实际项目还要应用第 2 节的公共数据正确性条件。每行的补强指向编辑器的数据和操作能力，游戏侧继续交付规则、行为、资产和实际呈现。

### 4.1 类型与制作任务

| 类型 | 当前可做 | 第一个明显断点及建议 |
|---|---|---|
| 动作、平台、清版、砍杀、奔跑射击 | **可制作**。铺地形和碰撞，摆出生点、敌群、拾取物、移动平台路线和锁屏事件。 | 平台首尾和首领阶段可用路径点与步骤。若需要在动作指定帧改打击形状，先用独立几何实体，补帧与几何的双向定位（R26）。 |
| 横纵版飞行射击、弹幕、自动卷轴 | **可制作**。布置背景、出现位置和区段事件，用步骤填波次、队形、时间。 | 当波次以镜头进度或屏幕边缘为基准，现有数据靠项目换算与试玩。为同一时间点提供进度、视野框和地图点的对照（R25–R26）。 |
| 格斗 | **受限**。可搭擂台、摆站位和边界，为动作填整数帧、时长、音频码及独立几何。 | 精确找出第 N 帧并调整该帧的多段攻击/受击区缺少原位编辑。补采样帧、形状列表和帧区间联合核验（R26–R27）。 |
| 动作冒险、银河恶魔城、RPG、JRPG、ARPG | **可制作，跨图受限**。房间、门、交互、任务、商店和传送落点有可用载体。 | 已有地图、实例配对和复制计划，跨图同码和副本依赖仍可能指错。先修 R09–R13，再用两个同码落点与房间副本验收。 |
| 视觉小说、叙事驱动 | **受限**。章节载体上能填长文本、选音频或图像资产，编排选择和跳转。 | 分支仍靠载体、内容 ID 和步骤维护。需要对项、多入边和缺目标定位。先修引用图，再给已有内容列表与关系图稳定定位（R13–R14）。 |
| 回合策略、战棋、塔防、RTS | **可制作，特殊格受限**。可摆单位、塔位、占领区、路线和波次，现有六边有格拾取。 | 难在逐条录入格边、跨行邻接与有向路径代价。可先用边中心实体，按声明补格边引用并修空间口径（R17–R22）。 |
| 益智、点击解谜、物理解谜、三消 | **可制作，连接受限**。可摆热点、棋盘初态、可交互物件并引用连动目标。 | 目标为物件内部哪个关节或槽位时只能用独立标记或手填。补实例端口引用及实时几何定位（R13、R27）。 |
| 模拟、经营、建造、生存、基地、种田 | **可制作，规模受限**。可摆资源点和设施，填产出、时长、范围，用内容表格批改单字段。 | 多格占地、生产配方及需求行需要多条步骤或标记。补声明式集合与局部占用预览，批改和撤销走共享命令（R12、R27）。 |
| 放置、超休闲 | **可制作**。单屏摆放、奖励频率、阶段阈值和界面文案可用默认表单。 | 内容逐渐独立于地图时仍要回到载体。先用单图控制实体，扩展时保留稳定的内容定位（R27）。 |
| 卡牌、集换式与牌组构筑 | **受限**。卡图引用、费用、规则文本、效果步骤和牌组引用有表达手段。 | 管理数百卡牌、共享效果行和牌组条目时，地图占位和原始 ID 查找成本高。先让库能按功能筛选、定位及安全复制，再接结构化重复项（R12–R14、R27）。 |
| Roguelike、Roguelite | **可制作，依赖受限**。可制作房间、出口、奖励和敌群，以地图引用填生成输入，种子可由游戏声明为试玩参数。 | 目录化管理多房间权重、拼接端点和房间副本时缺联合验证。用类型化端口和权重行验收，保持生成器在游戏侧（R10–R13、R27）。 |
| 节奏、音乐游戏 | **受限**。可选音频、填写轨道、编排起点和时长，声明速度段并换算到秒。 | 校偏移、试听变速后的跨段长音、批量调谱需要出编辑器。优先提供试听和拍秒对照，波形及密集批改按项目试点决定（R26）。 |
| 社交推理、派对、多人合作与对抗 | **可制作**。用实体区分多个出生点、队伍点和目标，人数和回合等走已声明字段。 | 默认 `spawn` 是一处。多位置采用实体模块。多人联动应由游戏侧消费同一提交版本验收，可先用游戏程序作为试玩入口（R24）。 |
| 体育与竞速 | **可制作**。可放场地、检查点、发车位和计时区，配置路径与过线顺序。 | 修改路径节点的方向或线路支路时，单一视觉路径和裸实例引用不够。用点实体过渡，补端口及有向连接（R13、R27）。 |
| 潜行、潜入、躲藏 | **可制作**。可摆巡逻线、区域、藏身点和角色出生点。 | 视野和巡逻段需要能够定位并联动编辑。先用路径和多边形，必要时接游戏侧只读空间参考（R25）。 |
| 侦探、调查、密室、找茬 | **可制作，屏幕构图受限**。可在背景上圈热点，填证据和后续条目。 | 热点必须随图片缩放或响应式布局时，世界像素不可靠。补画面内归一化锚点及多画幅核对（R25）。 |
| 工厂自动化、物流、铁路、线路解谜 | **受限**。可放设备、线路实体和连接目标。 | 难在同机多端口配线、格边方向和复制后的端口级重映射。先用端口实体，再用有类型的端口引用（R10–R13）。 |
| 自走棋、MOBA、幸存者、自动战斗 | **可制作，批量维护受限**。可放阵容槽、刷新点和路线，用步骤表示多个波次。 | 编队、升级池和重复波次需要逐条编辑。补结构化清单和同声明批改，核对未命中条目保持原值（R27）。 |
| 抽象棋盘、数字逻辑、落块、推箱子、拼图 | **常规格可制作**。可录入盘面初态、目标格和禁用区。 | 任意格图、绕回、跨边移动及同格多个拓扑端点只有标记和引用方案。用拓扑与格边声明接入稳定的选点和验证（R17–R22）。 |
| 弹珠台、台球、迷你高尔夫、绳索解谜 | **受限**。支持离格摆放、旋转、缩放，能画路径和多边形。 | 单对象多形状与关节端点配对缺通用原位编辑。可用已声明的几何标记实体，补局部坐标锚点与成组几何字段（R27）。 |
| 交互小说、打字、屏幕交互 | **受限**。用逻辑实体绑定文案、分支、提示和区域。 | 长文本条目需要脱离画布逐项搜索、检查回跳，屏幕热点还需不同窗口下可复核。先增强内容库定位及坐标域（R13、R25）。 |
| 程序生成输入、玩家共创的样块 | **可制作，依赖受限**。可做房间样块、出口和权重，复制后交给生成器。 | 配对引用、重复身份及全项目预检会决定样块是否真的独立。修 R06、R09–R13，用固定种子比较源图与副本的消费结果。 |

### 4.2 投影、拓扑、镜头与屏幕

| 场景 | 当前可做 | 断点与验收条件 |
|---|---|---|
| 侧视、横向卷轴 | **可制作**。正交图、横向范围、层视差、地图坐标及视野框已有。 | 同一画幅核对远景层、锁屏区和不同出发位置。游戏侧执行实际跟随、锁屏及卷轴。 |
| 俯视、纵向卷轴 | **可制作**。正交图支持脚点、混合层、层内排序和纵向编排。 | 交叠时核对遮挡、编辑器命中与脚点一致，尤其是转过或缩放过的层（R19）。 |
| 等距、菱形 | **受限**。主画布有预设几何、瓦片层和离格实例。 | 内容参考图和游戏示例的布局未对齐。用非方像素格、异形实体和翻转瓦片核对画布、参考和游戏（R18–R19）。 |
| 四分之三、斜 45° | **受限**。素材自带透视时可用正交加脚点，菱形地图可用等距。 | 自定义斜格线与实际瓦片会偏离。确认素材透视与格投影各自生效，补非预设的瓦片绘制（R18）。 |
| 2.5D 画面 | **受限**。层栈、视差、排序和高度字段能表达平面上的深度提示。 | 高度影响实际选点或遮挡时靠试玩。需要时让游戏输出只读参考及身份映射（R25）。 |
| 固定视角、单屏与横竖屏 | **可制作，画幅受限**。能对单个 `screenSize` 构图并摆热点。 | 适屏缩放和安全区靠项目核对。给同一内容预设多个画幅，核对热点及归一化区域（R25）。 |
| 多视角、分屏 | **受限**。不同图能有不同投影，也能摆镜头区和切换点。 | 不能同时检查两个玩家视窗内的目标，也不能在副窗选点回写。先分图加字段，之后接只读参考（R25）。 |
| 六边格、自由离格 | **受限**。尖顶 odd-r 有格轮廓及连续坐标。正交和等距也可离格摆放。 | 测奇偶行、非整数锚点和区域搬迁。需用点对点往返对照游戏侧的换算（R18–R22）。 |
| 二等轴测、任意斜平行投影 | **受限**。可用预设菱形或 `gridBasis` 录入平面双基。 | 双基还未完整应用到瓦片与内容预览。用非对称基向量核对格线、摆放、绘制和导出（R18–R19）。 |
| 三角格、不规则格、节点图 | **三角受限，不规则格缺入口**。半格拾取及主画布自绘可用，节点图可用实体与引用。 | 三角要验证奇偶、邻接、`alt` 与导出。任意格形的批量绘制、格边拾取和数据身份缺通用接口（R18、R22）。 |
| 环形、首尾相接、多楼层同位置 | **受限**。离格节点能闭环，楼层可分图或用层隔离。 | 格型的实际环绕邻接和同位置多域选择缺直接支持。先用分图配对引用，必要时再给拓扑和空间域独立身份（R09、R13）。 |
| 房间翻屏、轨道镜头、旋转跟随、多机位 | **受限**。可放区域、路径、观察点，公开镜头配置可用表单或步骤。 | 当前没有按轨道取样后核对视窗及切换边界的入口。由游戏侧提供采样参考，编辑器按身份定位对应点（R25）。 |
| 第一人称静态图、伪 3D 第一人称迷宫 | **底图可做，透视回写缺入口**。背景加热点或平面底图加门墙可录入。 | 透视画面和地图点无映射。待游戏提供参考图、热点位置与目标身份后，支持参照图和画布互选（R25）。 |
| 画中画、主副视窗与屏幕坐标布局 | **缺入口**。可填写窗口参数或手录归一化坐标，试玩检查实际布局。 | 缺每个视口的坐标域和命中映射。用宽、窄窗口测试同一热点对应同一目标，限定接口为参考视图和数据选点（R25）。 |

### 4.3 通用能力的补齐方式

1. 先让已有声明可可靠写入和验证。一个字段定义应决定存储键、值类型、候选域、格式化、校验和引用迁移，同一规则覆盖画布、表单、步骤、批改和自检。
2. 优先实现少量重复使用的编辑动作。支持结构化数组及逐行引用，支持实例端口、格边和带坐标域的几何选点。由资产或功能声明这些结构，编辑器负责录入、定位、复制和校验。
3. 内容库先具备按功能筛选、查入边、在不同地图间定位、编辑被多个实例共享的内容。无空间作品可先用专用地图内的逻辑实体。若真人试点证明作者仍大量受限，再论证独立项目级功能载体的身份与迁移。
4. 参考画面和时间参考按试点接入。游戏侧提供可读的帧、音频源、参考图和目标映射。编辑器复用现有时间轴或画布侧栏做对齐、查找和选点。

## 5. 架构与性能

### 5.1 现有设计的取舍

| 范围 | 建议保留 | 优先改进 |
|---|---|---|
| 项目接入、资产与声明池 | 游戏侧交付成品模块。声明池统一登记资产、功能、步骤、条件和时机。扫描指纹、停用保码和可恢复重链适合资产迭代。 | 装载、补码、扫描、验证及发布目前分担在多处。由项目会话持有生效声明和未保存变更，保存时统一生成磁盘形态。 [manifest.gd](../src/project/manifest.gd) · [asset_scan.gd](../src/project/asset_scan.gd) · [manifest_validation.gd](../src/project/manifest_validation.gd) |
| 宿主、面板与会话 | 三个一级入口加演出子面板符合工作流。面板各管操作，`UI Kit` 和会话内定位减少重复。`MapMenuIdentity`、`MapResize` 是职责清晰的提取。 | `app` 和 `canvas` 经大量无类型宿主透传读写状态。重构按状态所有权切分，给提交、选中身份、格空间和指令建立少量明确接口，迁完调用即删除旧透传。 [app.gd](../src/app.gd) · [editor_canvas.gd](../src/canvas/editor_canvas.gd) · [session_context.gd](../src/ui/session_context.gd) |
| 地图、内容与恢复 | 单文件先临时写再替换有价值。按地图码寻址的历史与草稿、正文与草稿分别存放有利于保留多个版本。 | 让正式写入共享冻结计划、基线校验、日志和结果。地图数据、工作内容、待写声明通过文档会话关联。存储层负责序列化和替换，协调者排依赖、处理失败和刷新基线。 [map_file.gd:742](../src/ui/map_file.gd#L742) · [map_store.gd](../src/map/map_store.gd) · [content_store.gd](../src/content/content_store.gd) · [recovery.gd](../src/map/recovery.gd) |
| 画布、图层与空间 | 混合层栈、稳定层码、按职责划分工具和绘制的方向合理。匹配预设时用 Godot 原生瓦片层，`GridSpace` 提供连续坐标及格形。 | 当前权威数据散于场景节点、原图、未解析行和控件。先给会话保存完整地图快照及变更集。空间统一解析后向主画布、参考图、导出和选择提供相同原语。 [grid_space.gd](../src/canvas/grid_space.gd) · [layer_ops.gd](../src/canvas/layer_ops.gd) · [undo_history.gd:71](../src/core/undo_history.gd#L71) |
| 引用、复制、自检与表单 | `RefFields.describe`、`ClonePlan` 的计划先行和自检的期待值比对值得保留。声明生成提示及控件能避免大量游戏专用 UI。 | 先统一地图、实例和内容身份及声明解析，把候选、重映射、审计、删除接入同一个会话索引。索引明确标识歧义、缺失和读不全。计划计算与执行分别持有明确的输入、输出。 [ref_fields.gd](../src/content/ref_fields.gd) · [clone_plan.gd](../src/content/clone_plan.gd) · [project_audit.gd](../src/project/project_audit.gd) · [field_widgets.gd](../src/ui/field_widgets.gd) |
| 演出、导出和试玩 | 列表与时间轴共用 `steps`。时间转换和绘制分离。导出面积预算和试玩参数数组都有直接价值。 | 演出工作身份与会话绑定，导出共用几何和图层数据。试玩消费已成功提交的准确版本，统一报告启动、跟踪与结束。 [timeline_clock.gd](../src/content/timeline_clock.gd) · [step_timeline.gd](../src/content/step_timeline.gd) · [map_export.gd](../src/map/map_export.gd) · [playtest.gd](../src/project/playtest.gd) |

现阶段保留项目接入契约与 UI 布局，按提交、引用、空间三个边界逐步改造。优先构建能被多个入口直接调用的纯计划及带基线执行器。等可重复测得当前交互成本后，再决定哪类快照与重绘需要替换。

### 5.2 性能热点与量化方法

| 编号 | 源码成本 | 优先调整与测法 |
|---|---|---|
| H01 | 撤销每步 `extract()` 串行扫描全图并序列化。恢复再解析和重建瓦片、摆放物及图层节点。空间占用随地图大小和保留步数增长。 [undo_history.gd:13](../src/core/undo_history.gd#L13) · [editor_canvas.gd:188](../src/canvas/editor_canvas.gd#L188) | 保留全图快照处理全局变更。先给单笔瓦片、区域和简单实例改动使用命令差量。测 1 万、10 万格的推栈、撤销、重做到首帧及常驻内存。 |
| H02 | 放置实例作混放提示会取整层瓦片和实例。在图层已有大量数据时，同层逐个恢复实例会重复枚举。实体全集还会反复跨三段容器收集。 [layer_ops.gd:85](../src/canvas/layer_ops.gd#L85) · [layer_ops.gd:113](../src/canvas/layer_ops.gd#L113) | 把提示延后到载入完成，或维护层内计数。按图层代次缓存并拆开实体集合、位姿和显示变化。记录大图装载及放一个实体的耗时。 |
| H03 | `code_map()` 即使命中也会列图并查元数据，跨图引用可多次触发。内容读缓存每次先读正文和计算摘要，只省解析。表单候选、关系图和自检重复读取相同数据。 [map_store.gd:128](../src/map/map_store.gd#L128) · [content_store.gd:113](../src/content/content_store.gd#L113) · [project_audit.gd:21](../src/project/project_audit.gd#L21) | 单次审计或候选会话持有同一索引快照，按写入代次和明确刷新失效。提交时仍校验正文。以读文件次数、读取字节和审计耗时量化。 |
| H04 | 内容预览、三角瓦片和碰撞重画会遍历使用格。内容表单重建控件可能连带重算候选。刷新粒度常大于单次变化。 [content_preview.gd:168](../src/ui/content_preview.gd#L168) · [tri_tile_view.gd:35](../src/canvas/tri_tile_view.gd#L35) · [collision_view.gd:41](../src/canvas/collision_view.gd#L41) · [content_editor.gd:603](../src/ui/content_editor.gd#L603) | 先拆分几何、数据、相机和高亮的失效，记录每次鼠标移动及笔画扫过的格数。确认瓶颈后再按需做视口裁剪、分块与控件局部更新。 |
| H05 | 图集构建、素材扫描与指纹、导出图像绘制和进程轮询均有同步成本。像素上限控制单图内存，单次导出计算仍占前台，批量可取消的粒度主要在图间。 [tileset_cache.gd:25](../src/canvas/tileset_cache.gd#L25) · [asset_scan.gd:22](../src/project/asset_scan.gd#L22) · [map_export.gd:81](../src/map/map_export.gd#L81) · [map_file.gd:1128](../src/ui/map_file.gd#L1128) | 测冷/热打开、单图与批量导出、持续试玩时的最长帧。先缩短重复 I/O，必要时把可独立计算的图像、扫描任务分段调度，并检查取消后的结果完整性。 |

上表给出代码可证明的重复工作和复杂度来源。性能优化前后使用同一地图、操作和机器比较响应时间分布、最长帧及内存。发布记录中的历史耗时属于对应试点的记录。

## 6. 修复顺序与验收

| 顺序 | 交付边界 | 最小通过条件 |
|---|---|---|
| 1. 正式提交和恢复（A2/A3/A4） | R01–R08、R28。统一写入入口、工作副本归属、摘要和日志。 | 新建绑定后分别从关卡、内容和试玩入口提交，核对清单、内容、地图都能重开。A 图有暂存时放弃或撤销再保存 B，磁盘不出现旧条目。强制第二个文件及日志写入失败，检查可重试、部分结果和实际磁盘一致。用自定义 `contentDir` 写草稿，改名、重启后恢复字段及步骤。 |
| 2. 保身份和依赖（C1/C2/C3） | R09–R16、R29。统一身份键、引用索引、复制和破坏性计划。 | A、C 有同码实例，复制或跨图粘贴 A 的子集，组内引用更新，C 的引用原样保留。包含不可摆放条目、暂存内容和共享配对字段。删除前查到未落盘入边，确认期间发生变化时中止。停用或缺资源的图打开再保存仍保留原码与原行。 |
| 3. 统一格空间和接入（A5/A6/B1–B3） | R17–R22、R24。先保证常规格，再补斜基和三角。同步修游戏示例。 | 在非正交默认项目显式建正交图。对等距、六边、斜基和三角的同一份夹具，对比格中心、选点、图层、翻转、导出和游戏读取。核对六边奇偶行、转换后的出生格及无图集碰撞。以含空格路径分别验证两种试玩入口。 |
| 4. 演出与实际制作（D1/D2/E1–E3/F2） | R23、R25–R27。先用已有通用录入做完整试点。 | 真人完成刷怪第二波和跨图落点、两选项一回跳、固定帧或带速度段节奏各一个片段。保存重开后核对结果并试玩。记录耗时和误操作，用第一个制作断点选择结构化行、试听、端口或视口参考的后续改动。 |
| 5. 性能（F1） | 按 H01–H05 记录成本，在同一操作下比较。 | 固定数据规模，分别测打开、落笔、撤销、选内容、审计和导出。达到实际交互瓶颈时先做局部修正，再扩大到差量和分块。 |

**发布门槛建议**。完成前两批并验证完整提交，才适合承诺安全的常规项目制作。格空间和游戏读取通过对照后，再声明对应投影已支持。保留四面板三入口，按试点结果在现有面板内补动作。

## 7. 实施设计

本节给出下一轮开发可采用的接口、变更顺序与失败行为。下文的接口和新增声明键均为提案。按现版 v7 地图、内容 v1、四面板三入口实施。存量文件沿用既有解释，新增数据能力由项目显式声明，涉及既有语义变化的操作通过一次明确迁移完成。实施方案 A2–F2 是任务归属，本节的复审用例补足既有勾选项的验收范围。 [原实施方案](V1-IMPLEMENTATION-PLAN.md)

| 原请求 | 审查结果所在位置 | 对应实施设计 |
|---|---|---|
| 1. 功能文档、游戏契约、源码头与模块注释 | §3.1–3.3 | §7.6 给出规范分工、可执行示例和同批更新规则 |
| 2. 缺陷、逻辑、性能及基础功能 | §2、§5.2 | §7.1–7.4 修复数据、引用和空间，§7.5 拆解性能迭代 |
| 3. 各种 2D 类型和视角的制作能力 | §4 的 22 类制作任务和 14 类空间、视口场景 | §7.3–7.4 给出可复用的数据结构、录入方法和各类试点 |
| 4. 模块及全局架构是否合理 | §5.1–5.2 | §7.5 给出状态所有权、调用方向和渐进迁移 |

### 7.1 统一提交、恢复和地图生命周期（R01–R08、R28）

**工作副本归属。** 新建 `src/project/document_session.gd` 持有地图码、切图代次、编辑修订号、地图快照和待写内容。内容按 `ContentStore` 解析后的 `(功能id, 内容ID)` 寻址，并记录归属文档及打开时基线。有多个实例共享同一内容时，在当前会话内共用一条工作副本。清单由项目持有，记录补码、资产变更及地图依赖。切换地图前，当前文档明确执行保存、保留草稿或放弃。放弃只撤回该文档自己的未写内容和绑定，项目级资产编辑仍按自己的保存动作处理。

**入口与接口。** 将 `content_form.gd::_content_write()` 和 `content_editor.gd::write_content_staged()` 迁为会话里的值更新。`content_editor.gd::commit_fields()` 只收集控件值，选实例、切面板和关闭演出复用这个入口。`map_file.gd` 保留提交与确认 UI，`project_shell.gd` 的保存复用它。增加 `src/project/document_commit.gd` 负责编排，继续由 `MapStore` 和 `ContentStore` 提供底层写入及历史接口。

```text
DocumentSession.stage_content(fn_id, cid, data, opened_state) -> {status, error}
DocumentSession.snapshot() -> {token, revision, map, contents, manifest_changes}
DocumentCommit.prepare(snapshot, operation) -> {status, plan, issues}
DocumentCommit.apply(plan, confirmed_states) -> {status, written, pending, conflicts, receipt}
Plan = {token, revision, operation, targets}
Target = {op, relative_path, baseline, expected, payload}
FileState = {status: present | absent | unreadable, digest}
Receipt = {map_code, absolute_path, map_digest}   # 仅成功的地图提交有值
```

准备时先还原未松手的拖动、尺寸和顶点预览，再收集控件。已有涂刷笔画沿用原撤销边界。只读盘点可看待写项，正式确认以冻结计划为准。`prepare` 对地图、内容和磁盘形态清单校验，先计算最终输出字节、摘要与历史项。`apply` 用同一字节序列写入，依次替换清单、内容、地图。每次 `await` 返回都检查项目、文档和修订号。等待确认时若编辑状态变了，重新预览本次保存的内容。

- [x] **统一保存与会话。** 已实现：关卡/内容/试玩都走 `map_file.gd::commit_document`（`save_all` 为 Ctrl+S 入口，`on_play` 为试玩入口），资产页只提交清单范围（`project_shell.gd::save_current` 的 `_` 分支）。正文写入前读目标实际状态（内容写前摘要复验见 `document_commit.gd:64-71`），`absent` 与 `unreadable` 分开（`content_store.gd::read_ex` 的 status；`MapStore.read_path` 的 ok/errors）。试玩只消费本次成功提交路径（`map_file.gd:1170-1183`）。证据：`tests/test_stores.gd`、`tests/test_audit_c3.gd`。**「编辑新绑定 → 换选实例 → 内容页保存 → 重开」的端到端复读需 GUI 验收，标注排除。**
- [x] **完善日志和草稿。** 已实现：`document_commit.gd:52-59` 先 `Recovery.begin_pending` 再替换；日志逐目标记 path/baseline/expect/kind（`recovery.gd::begin_pending`）。`scan_pending` 三态 written/pending/manual（`recovery.gd:306-369`，`tests/test_stores.gd::test_pending_log_partial_detection`）。替换成功但进度回填失败 → 停手并保留日志（`document_commit.gd:96-101`、`tests/test_stores.gd::test_pending_mark_fails_when_log_gone`）。草稿记地图快照 + 待提交内容 + **清单补码待写标记**（`recovery.gd::write_draft` 的 `codesPending`；恢复在 `map_file.gd:1108-1116`），按项目与地图码恢复（`draft_key`）。**四个回归点中的「第二次内容写入失败」「替换后立即中断」「自定义 contentDir 重启恢复」需构造进程中断，标注排除。**
- [x] **接管改名、克隆、导入。** 已实现：改名走 `map_store.gd::rename_map`（一条两目标日志：写新 + 删旧，删除项 `op: delete` 在 `scan_pending` 里按 absent 判定）；保地图码（纯 rename 不动码，跨图引用本就写码）；同名检查先于动盘（`rename_map:364-365`）。复制走 `duplicate_map`（N 内容 + 1 地图一条日志，内容先写）。外部导入见 `map_file.gd:644-669`：先确认、目标名冲突自动改名、源图码**丢弃重发**。**「改名中途失败后冲突图不进入可写引用」的现场构造需 GUI/进程中断，标注排除。**

复用现有备份和单文件替换即可。多文件提交的保证定义为逐文件可识别、可恢复及失败可见。恢复载荷与日志应随完成结果一起清理。普通编辑入口在磁盘提交完成后再清对应修订的脏标记。若同一文件被后续编辑，保留后续变更。项目内的提交串行执行。计划中的相对路径由现有存储接口解析并验证属于对应的项目目录，恢复时使用同一规则。日志的 `expected` 对删除是 `absent`，对写入是最终字节摘要。

```text
require session.token_and_revision == plan.token_and_revision
require every target.state == confirmed_states.get(target.path, target.baseline)
require persist_journal(plan) succeeds before the first replacement
for target in dependency_order(plan.targets):
    if read_state(target) != target.accepted_state: stop_with_conflict(target)
    preserve_previous_version_if_present(target)
    if not perform_and_verify(target, target.expected): stop_with_pending(target)
    if not record_progress(target): stop_with_pending(target)
return verified_result(plan)
```

### 7.2 稳定身份、声明引用与安全复制（R09–R16、R29）

增加 `src/project/reference_index.gd`，每次内容候选、自检或操作计划共享一个项目索引快照。正式版本和当前工作副本用同一身份，工作副本替代对应源。只读列表允许快速索引，写入、复制和删除按实际版本构建操作范围。被保留的草稿按潜在入边计入破坏性检查，其中有读不全的条目就阻止删除。

```text
MapKey = map_code
InstanceKey = (map_code, instance_code)
ContentKey = (function_id, content_id)
ReferenceIndex.resolve(ref, context) -> {status, key, candidates, sources}
ReferenceIndex.inbound(key) -> {complete, edges, unreadable_sources}
```

`status` 为 `ok`、`unset`、`missing`、`ambiguous` 或 `incomplete`。`RefFields.describe()` 补上字段实际存储键和配对域。表单、步骤、布置物及审计统一把声明与所在行传入解析器。`mapField` 按兄弟字段的人类 ID 查声明，再按该表单的实际存储键读写。更换地图时一次确认并同时修改地图与相关实例引用。普通文本、注释和未声明字段保留原值。

- [x] **统一候选与审计。** 已实现：`reference_index.gd` 提供 `resolve_map`（ok/unset/missing/ambiguous，撞码返回空 + 候选，不猜），`ref_fields.gd:176,279-280`、`project_audit.gd:827-828`、`content_form.gd` 删除检查共用同一入口。`asset::ID`、引用数组、`mapField` 同一组样例：`tests/test_ref_fields.gd`（含 `test_describe_asset_keeps_empty_kind`、`test_local_entity_refs_and_accepts`）、`tests/test_audit.gd::test_ref_checks_paired_map`、`tests/test_audit_c3.gd::test_paired_map_unknown_reports_once`。
- [x] **合并克隆与落位计划。** 已实现：`clone_plan.gd` 产出 `{instance_map, content_map, map_patch, pending_contents, conflicts}`，先校验再分配身份。整图复制用同一份计划生成保存计划（`map_store.gd::duplicate_map` 消费 `pending_contents` 按内容先、地图后写）。区域粘贴/复制走 `region_ops.gd`/`selection_ops.gd` 的同源计划（`staged_rows_current_doc` 取源内容）。证据：`tests/test_clone_plan.gd`（组内重映射、跨图保留外组目标、整图复制、内容独立 5 例）。**「无图层匹配时预览让作者确认落位」的交互靠 GUI 验收，标注排除。**
- [x] **统一永久删除和清理。** 已实现：`asset_panel.gd:501-564` 扫描资产「删除」= 停用保 ID，已停用再删才真抹条目；抹条目前跑 `ProjectAudit.asset_content_refs`/`asset_draft_refs`（内容字段与草稿都算入边）。内容删除统一走 `ReferenceIndex.inbound_content`（`content_form.gd:1329-1335`，`complete=false` 直接中止并列出读不全的源）。**清除悬空引用检查所有共享配对字段、保留仍有用途的地图字段**：`project_audit.gd::apply_ref_fixes` + `_pair_still_used`，证据 `tests/test_audit_c3.gd::test_clear_dangling_keeps_still_used_pair_map`。**文件删除前由提交器保存历史、部分成功按文件报告**：`content_store.gd::remove_ex`（轮转失败拒绝删）+ `map_file.gd` 逐图 per_map 结果，证据 `tests/test_stores.gd::test_content_remove_backs_up_history_first`、`test_content_remove_refuses_without_history`。

```text
old_key = index.resolve(field_value, source_row_context).key
new_key = cloned_instances.get(old_key, old_key)
required_map[paired_field].add(new_key.map_code)
reject_plan_if_any_shared_map_requires_multiple_codes(required_map)
```

用 A、C 都含 `AB23` 的三图夹具验证。A 的两个引用分别指 A 与 C。复制 A 到 B 后分别读到 B 的新实例和 C 的 `AB23`。同一配对字段无法表达两个目标图时应得到冲突，磁盘和会话均保持原值。再以一个缺图层或缺资产的源行夹在两条正常记录之间，验证其余记录所获身份和内容均与原行对应。

### 7.3 一个生效格空间和一份场景几何（R17–R22）

在 `grid_space.gd` 增加 `static resolve(meta: Dictionary, manifest: Dictionary) -> Dictionary`，统一返回 `{grid, issues}`。按「明确的逐图投影 → 项目默认 → 正交」确定预设，基向量和拓扑按同一生效预设验证，再配置 `GridSpace`。`new_map` 区分继承与显式正交。`map_data_validation.gd`、`map_export.gd`、`map_convert.gd` 和 `editor_canvas.gd` 消费这一入口。对无效组合阻止正式写入，兼容旧图时保留输入及诊断，避免读入后静默丢键改形。

- [x] **统一几何读取。** 已实现 `src/map/map_view_data.gd`：`effective_grid` / `layer_transform`（offset 数组 + **scale 标量**，与 `layer_ops.gd:369`、`editor_canvas.gd:325-331` 同值）/ `cell_poly` / `anchor_px`。消费方：`content_preview.gd:219,279`、`map_export.gd:60,154,203`（主画布建层本就按同一组参数）。证据：`tests/test_grid_space.gd::test_map_view_layer_transform`、`test_map_view_cell_and_anchor`；`tests/test_map_export_a5.gd::test_layer_transform_expands_bounds`、`test_layer_scale_expands_bounds`。**层三段遮挡在预览里的完整复用（混色细节、材质）仍需 GUI 观感验收，标注排除。**
- [x] **明确瓦片后端。** 已实现：正交/等距/六边走 `TileMapLayer`（`editor_canvas.gd` 建层），三角拓扑叠 `TriTileView` 自绘（`:312-318`），数据仍住 TileMapLayer。`tri_uvs(poly, atl, cs, tex_size, alt)` 是纯函数：先在图集切片内施加 v7 变换，再映射到格多边形。证据：`tests/test_tri_render.gd::test_tri_uv_alt`（翻转/垂直/转置/90° 四点）、`test_tri_uv_degenerate`（退化不退化成 NaN）。图集解码失败按源跳过（`tileset_cache.gd`），瓦片数据与碰撞录入不受影响。**八种 alt 的几何与纹理观察需 GUI，标注排除。**
- [x] **保证往返和转换。** 已实现：`undo_history.gd::extract` 对未解析条目按 `n.raw` 原行往返（`:288-296`）；碰撞行未知键挂 `raw` 原样带回（`:263-265`、`editor_canvas.gd:407-415`）。校验覆盖重复格、非整数索引（`_is_integral_number`）、有限坐标（`grid_space.gd::_finite2`）、不可逆基（`grid_space.gd:163` 两向量共线报错）。转换预览报连续对象锚点/离散出生格误差/瓦片与碰撞待核对计数（`tests/test_map_convert.gd` 8 例）。**跨图区域粘贴的格型差异提示需 GUI 交互，标注排除。**

同一个空间夹具放一块旋转且非方形的图集瓦片、一段碰撞、两个不同脚点的实例和一个出生点。分别应用正交、等距、odd-r 六边、斜双基和三角拓扑。断言 `pick_cell(cell_center_px(c)) == c`，对比预览、导出、游戏侧实际锚点。三角要覆盖两种半格，六边覆盖奇偶两行。再把图集临时移除并保存，确认瓦片记录和碰撞可恢复。

### 7.4 提升类型覆盖的通用编辑能力（R23–R27）

按字段、空间和时间三条路径扩展。发布顺序由试点的第一个断点决定。对以下示例，游戏侧提供声明和可消费样例，编辑器侧逐项实现录入、引用定位、保存往返和人工校验。镜头、规则、编队及动作执行继续由相应模块负责。

每个新增值形状至少实现校验、默认值、表单、引用遍历和未知版本往返五个入口。按声明启用的字段若当前编辑器读不了，显示实际值与版本，保存其它字段时保留原值，被复制或删除的依赖无法解析则拦截。新键先由接入规范和消费示例确定，再在 GUI 中开放。

- [x] **给已有数组增加结构化元素。** 已实现：`manifest_validation.gd` 接受 `kind: input, type: array, of: record, fields: [...]`（`tests/test_c1_records.gd::test_validation_accepts_record_decl`、`test_validation_rejects_record_without_fields`）。`field_widgets.gd` 递归构建子字段（`_build_record`），支持添加/删除/复制/上移/下移（`_array_row_buttons`）。`ref_fields.gd::ref_fields_deep` 递归收集子记录引用，兄弟配对作用域为该行声明。证据：`tests/test_c1_records.gd::test_ref_fields_deep_paths`、`test_elem_decl_and_default`、`test_clone_remaps_record_rows`。**拿配方/牌组/叙事实例验收需真实项目数据，标注排除。**
- [x] **让关卡中同一个对象的不同端点可选择。** 端口引用已完成（`assets[].ports` 校验 + `port_candidates` 按类型过滤 + `{map, inst, port}` 存值，`tests/test_c1_records.gd::test_ports_validation`、`test_port_ref_describe_candidates_remap`）。**格边字段**：新增 `src/map/edge_ref.gd`——边身份完全由编辑器从格拓扑推导，无需游戏侧声明键；`canonical_edge(a,b)` 把两端点按 `(y,x)` 排序成 `"x1,y1|x2,y2"`，因此无向共享边只有一个代表 ID（`edge(a,b)==edge(b,a)`），字段值存 `{map: 地图码, cell: [x,y]（代表边首端点）, edge: 代表边 ID}`（`value_of`）。清单接受 `type: "edge_ref"`（`manifest_validation.gd::INPUT_TYPES`），`RefFields.describe` 归一成 `kind="edge"` 且 `is_ref=true`，可选 `mapField` 配对目标图。表单控件是下拉 + 「画布选…」：候选由 `RefFields.edge_candidates_of` 纯函数求（画布对内存文档调 `editor_canvas.gd::_edge_candidates()`，配对图下拉走 `RefFields.edge_candidates` 读盘），列两侧都有瓦片的相邻格对（quad/hex/tri 都走 `grid.neighbors_any`），点选走选点模式 `accept="edge"`（`pick_edge_at` 按光标到两格连线的垂距就近命中），画布画边线高亮（`canvas_draw.gd::_draw_pick_edges`），`app.gd::_end_canvas_pick` 用 `focus_edge` 对准边中点。复制只改 `map` 分量（`clone_plan.gd::_remap_edge_refs`，跨图钉源图码，边/格号不动）。审计复查格式非法 / 两格不相邻 / `cell` 与 `edge` 不自洽（`project_audit.gd::_edge_ref_problem`，带 `clear_prop` 修复）。证据：`tests/test_edge_ref.gd`（9 例）。**画布点选手感需 GUI 验收，标注排除。**
- [x] **让内容库直接维护已存在的功能内容。** 已实现：`content_form.gd` 库面板按功能池列内容，带名称/id 搜索 + 引用状态筛选 + 每行入边数（`◆n`），三个动作复制成新 ID / 共享改绑（先列受影响实例）/ 改名与删除（先跑引用检查）。证据：`tests/test_c2_lib.gd::test_bulk_edges_instances_and_contents`、`tests/test_audit_c3.gd::test_content_usage_and_inbound_refs`、`test_unbind_keeps_content_and_rebinds`。**100 条内容的实际筛选/改引用体感需 GUI，标注排除。**
- [x] **把特殊拓扑接入同一套格操作。** 已实现：`cell_graph.gd` 校验 `{cells: [{id, polygon, neighbors}]}` + 按多边形命中 `pick_cell` + 显式邻接（含回绕边），`cell_id` 走公开内容字段的 `cell:` 枚举（`tests/test_c4_cell.gd`）。**画布接入**：`editor_canvas.gd::cell_graph()/pick_cell_id_at()/focus_cell_id()`，选点模式 accept=`"cell"` 时命中走多边形而不是 `GridSpace.pick_cell`，画布按多边形绘制悬停/已选高亮（`canvas_draw.gd::_draw_pick_cells`），`content_form.gd` 给 `source: "cell:"` 字段出「画布选…」按钮。证据：`test_polygon_and_centroid`、`test_pick_matches_centroid_hit`（每格重心命中的就是自己）。
- [x] **给屏幕位置和预览明确的坐标域。** 已实现声明与校验：清单 `viewports: [{id, w, h}]`（`manifest_validation.gd::_validate_viewports`），只读参考 `views: [{view_id, image, pixel_size, hotspots}]`（`_validate_views`，hotspot 矩形必须归一化 0..1）。字段侧 `viewport_ref` 工作值 `{viewport, point|rect}`（`field_widgets.gd::_build_viewport_ref`，候选来自 `viewport:` 解析器）。证据：`tests/test_c1_records.gd::test_viewports_views_validation`。**热点点选回填（从画布点热点 → 回填目标身份）未接线；「两画幅选同一门得同一身份」需 GUI 验收，标注排除。**
- [x] **时间轴把播放参考和编辑数据分开。** 已实现：`TimelineClock` 只解释帧→拍→秒（`tests/test_timeline_clock_d2.gd` 12 例：60fps 第 12 帧 = 0.2 秒、跨变速段 2+1+0.25=3.25 秒、拍细分取整、小数帧只标记不量化）。`step_change_requested(index, revision, patch)` 与 revision 失效检测在 `tests/test_step_timeline_d1.gd`（`test_patch_rejects_non_time_keys`、`test_stale_index_after_reorder_is_detectable`）。`steps_panel.gd:1012-1016` 把项目声明的音频码反查为名称+秒数显示。**音频试听（真正播放并反查播放头）与波形未实现——缺项目侧音频资源路径的可播放约定，标注排除。**

可复用的验收例：只用公开字段制作「地图 A 的门连接地图 B；同一交互触发两条分支，其中一条回跳」；在宽屏和竖屏参考选择同一热点；在 60fps 下把第 12 帧的形状移 2 像素，另用音频对齐一个跨变速点的持续步骤。每次重开后由游戏读取同一组身份、锚点和时间值。

### 7.5 架构迁移与性能目标（H01–H05）

推荐分层：`UI → 文档会话/编辑命令 → 已验证的快照或补丁 → 引用索引、几何、存储`。`App` 保留项目切换、面板布局和事件路由。`EditorCanvas` 持有可见节点、相机和手势预览。会话持有可保存数据和修订。项目索引返回只读查询结果，存储和绘制都不反向修改会话。团队可以按操作入口逐批迁移，每批都能保存、关闭和重开。

- [x] **阶段一：钉住权威数据。** 已实现：`document_session.gd` 持有地图码/图名/代次/修订号/暂存内容，`snapshot()` 是提交的唯一冻结输入；内容工作副本在 `content_form.gd`，提交走 `document_commit.gd`，草稿在 `recovery.gd`。**撤销栈也已收口**：`undo_stack`/`redo_stack`/`UNDO_MAX` 归 `undo_history.gd` 所有，`editor_canvas.gd` 的 `_snapshot()`/`_restore()`/`_push_undo()` 三个宿主透传已删除（`layer_ops.gd`、`tool_ops.gd` 的同名转发同样删除），调用方只走 `push_undo()`/`undo()`/`redo()` 或控制器的差量入口；换图清历史走 `clear_history()`。
- [x] **阶段二：按操作迁差量。** 已实现三类差量：格差量（`{kind:"delta", cells:[...]}`，`undo_history.gd` 笔画 API）、实例差量（`{kind:"ents", ops:[{op, key:<实例码>, before, after}]}`，`inst_rows`/`inst_commit`/`inst_commit_add`，读的是与落盘同一份行口径 `_object_row`）、内容差量（`{kind:"content", fn, cid, before, after, digest_before, digest_after}`，`record_content`；盘面摘要不符即拒绝回滚）。已迁的入口：放置/右键擦除/删选/剪切/粘贴/Ctrl+D、拖动/尺寸/顶点、翻转/旋转/缩放、引用字段、功能绑定写回、显隐开关、方向键微调（1 秒窗口合并）。无实例码的场景图片与全局操作（区域/层/尺寸/转换/批量替换/自动碰撞）仍走整图快照。证据：`tests/test_undo_delta.gd`（9 例）。
- [x] **阶段三：按代次失效。** 已实现：码表按「目录列举 + 各图 mtime」签名缓存、内容读缓存按全文摘要、引用集按 `project_rev`、图集纹理按路径+mtime。**本轮补齐三处脏区**：① 按层失效——`editor_canvas.gd` 新增窄入口 `_mark_ents()`（只置实体脏，不重建碰撞红块与三角自绘）、`_mark_tiles_layer(li)`（只重画指定层），涂刷/擦除/撤销差量全部改走它们，实例类操作（拖动/尺寸/顶点/翻转/旋转/缩放/删选/剪切/粘贴/Ctrl+D/引用/绑定/显隐/微调/撤销差量）从 `_mark()` 换成 `_mark_ents()`；`undo_history._restore_delta` 按条目里的层码逐层失效，不再补一刀全量 `_mark`。② 悬停只失效高亮——`canvas_input.gd` 记录上次悬停格/像素点/框选组热区，无手势时仅在换格、进出热区或位移 ≥ 2px 时重画（手势中照常逐帧跟手）。③ 表单控件复用——`content_editor._rebuild_right` 按「实例码+类型+props+绑定+展开功能+内容数据+定位字段」算签名，签名不变直接留用现有右栏控件（不销毁重建，输入焦点/滚动位置/未提交值都保住）；`layer_ops` 混放提示改读 `layer_has_tiles()` 缓存（层重建与瓦片写入时失效），不再每次放置全层 `used_cells` 重扫。证据：`tests/test_undo_delta.gd::test_restore_marks_only_touched_layer`（瓦片差量只重画 L2，碰撞/实体/全量都是 0 次）、`test_restore_ents_skips_tile_mirrors`（实例撤销只打实体脏）。**格块级（跨层一块矩形）脏区未做——按层已经足够覆盖当前所有写入入口，格块要等分区渲染真有必要再拆。**
- [x] **阶段四：限定同步作业。** 已实现：图集解码结果按 source 缓存在 `tileset_cache.gd`（键含图集路径 + 切片尺寸 + mtime），换版只失效相关图源；导出先算像素预算再决定缩放（`test_map_export_a5.gd::test_budget_rejects_4000_square`、`test_render_refuses_over_budget`）；试玩 `_play_args()` 缺键按空字典（`playtest.gd:13`）、报告 `tracked`/`kind`、平台无法查询时显示「跟踪不可用」（`tracking_available`，`tests/test_validators.gd::test_playtest_structured_launch`）。cwd 约定已写入 `GAME_SIDE_STANDARD.md` §6.2（不可配置，靠显式参数）。**分批导出取消后续跑未做（当前整图一次性渲染），标注排除。**

建议初始性能验收以同一台目标开发机、固定两份夹具为准：常规图 1 万瓦片，大图 10 万瓦片，均包含实体、引用、多个层和碰撞。分别记录冷开、热开、短涂刷、撤销、切换实例与全项目自检的中位数、P95 及最长编辑帧。单格撤销、单实例改值和鼠标悬停的工作量不应随全图瓦片数增长。将常规编辑帧 P95 预算设为 16.7 ms（60 Hz 开发机目标），达不到时依据采样决定缓存或分块方案。实际数据和机器配置记入发布记录，本轮没有测量结果。

### 7.6 文档和示例随实现交付（F2）

- [x] **为同一个行为定义唯一的规范位置。** 已实现：`EDITOR_FEATURES.md` §7.3「各入口提交哪些文件」表 = 唯一文件清单（11 个入口 × 按序写哪些文件 × 日志/历史 × 代码位置），紧随其后「历史深度」= 地图 20 份、内容 3 轮的两个数字。`GAME_SIDE_STANDARD.md` §1 与 `document_commit.gd`/`map_file.gd`/`content_store.gd`/`map_store.gd`/`recovery.gd` 的模块头均改为**引用**该处而不复述。`GAME_SIDE_STANDARD.md` 只写字段类型/身份/单位/缺省值/版本/消费方式；模块头只写职责/状态所有权/副作用。
- [x] **先给一个能手算对照的游戏读取示例。** 规范 §7.2 给出 `door_toggle` 三字段（`F1A2`/`B3C4`/`E5D6`）按执行码直读的示例 + 缺键夹具。运行时等价断言在 `tests/test_f2_read_example.gd`：`test_door_toggle_hand_checked_example`（读到 `"key"`/`true`/`3.25`，缺键回落 `""`/`false`/`2.0`）；`test_dict_and_array_forms_share_content_dir`（dict/array 两种写法解析到同一内容路径）；`test_object_shapes_readable`（`scene/image`、有 prefab 的实体、只有 `visual` 的实体三种摆放形态都能按 asset id 找到声明）。
- [x] **把地图示例拆成可分别验收的部分。** 已实现：规范 §6.4 骨架分三段——投影解析（`resolve_projection`）+ 格↔像素（`cell_to_px_g`/`anchor_unit`/`object_px`）、建层与瓦片六元组（含 `alt` 与运行时层开关）、碰撞对象。正交路径按编辑器实现逐行核对，等距/六边/三角只给公式并显式声明「没有在真实工程里跑过」。地图侧格式口径由 `tests/test_map_v4.gd` 覆盖（`test_tiles_key_and_tuple`、`test_alt_roundtrip`、`test_layers_validation`、`test_collision_objects`），投影对照由 `tests/test_map_convert.gd` 与 `tools/projection_baseline.gd` 提供。

### 7.7 最终验收：通用性、易用性和高上限

**通用性的判定。** 合格的新 2D 项目由游戏侧提供资产、运行模块和公开数据声明。作者使用现有面板即可合法创建、修改、定位、复用、撤销和验证这些数据，保存重开后游戏读到完全同一份身份、空间和时序定义。新类型遇到的缺口应归到可复用的编辑原语或项目提供的参考接口，例如坐标域、拓扑、结构化数据、引用图或时间参考。增加一个新游戏类型的正常路径不改编辑器核心；新增通用能力之后至少由两类不同任务复用，避免落成类型专用功能。

| 发布门槛 | 代表性验收 |
|---|---|
| 默认制作不依赖手改 JSON | 在空白项目从扫描资产开始，完成平台关卡及俯视房间，摆放、改参数、撤销、复制、保存、重开、试玩。普通操作不要求先了解执行码、草稿目录和投影公式。 |
| 复杂内容的批量维护不依赖占位技巧 | 用公开模块完成跨图传送、关系分支、配方或牌组、不同端口配线。目标可定位，批量读写能预览影响并撤销。逻辑地图可以是兼容载体，但日常维护应能从内容库独立完成。 |
| 投影和空间域可扩展 | 验收正交、等距、六边、三角、斜基和一个非规则格图；至少一次世界、局部、屏幕域联用，以及两个视口参考互选。项目使用未接入格型时，明确提示需提供的格形或热点数据。 |
| 时间和形状可精确维护 | 同时验收帧序形状、变速节拍、音频偏移和卷轴进度参考；步骤列表与时间轴重开后内容一致，试玩读取相同单位。 |
| 日常错误和中断可恢复 | 对保存取消、断写、同码冲突、坏图集、删除阻断和旧草稿跑针对性回归。恢复保留所有仍未提交的数据，发现未知值时保留原内容并指出不可编辑处。 |
| 可验证的品质和性能 | 代表项目从接入到试玩有可复查记录；分别报告源码、纯逻辑、GUI、真人制作和游戏消费证据。实际采样达到 §7.5 的帧预算或公开对应数据规模与限制。 |

**扩展优先级。** P0 数据正确性、现有格式保真和基本试玩是当前版本的发布阻塞项。结构化内容、拓扑、端口、坐标域及时间参考是「全能」验收项，按 §7.4 分批实现并最终验证；波形样式、专用关系图排版和复杂视窗组合可按试点决定实现深度。规则新增由游戏模块完成，超出默认编辑原语的需求通过可版本化的数据描述接入现有面板。未识别的新描述以只读显示和原样保存兜底，不能把手工改 JSON 算作通过。
