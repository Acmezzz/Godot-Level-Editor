# 2D游戏编辑器使用指南

游戏工程提供美术资产、控件和可调用的行为；你在编辑器里摆出画面、配置玩法、连接流程，然后启动游戏试玩。

日常制作主要在两个地方：**关卡**负责地图上的画面和摆放，**内容**负责实体行为、独立内容和流程。顶栏的「资产」用来查看素材、管理实体类型可挂接的功能。

## 快速上手

1. 启动编辑器，选择「打开项目文件夹…」，选中已接入编辑器的游戏工程。
2. 在「设置 ▾」新建地图，或从「地图 ▾」切换到已有地图。
3. 在左侧选图层和资产，在画布上铺地形、摆背景或放实体。
4. 选中实体后按 `Enter`，进入「内容」为它配置行为。
5. 按 `Ctrl+S` 保存，点「试玩」在游戏里查看结果。

开发者首次接入请看[游戏侧规范](GAME_SIDE_STANDARD.md)。

## 编辑地图与画面

| 想做什么 | 在哪里操作 |
| --- | --- |
| 画地形、摆背景和角色 | 在画布选图层。选择瓦片即可涂刷；选择图片或实体即可摆放。实体可移动、旋转、翻转和缩放。需要精确落点时，可关闭格点吸附。 |
| 调整绘制顺序 | 在图层管理中增删、排序图层，调整显隐、偏移、缩放和视差。同一层还可按位置排序。 |
| 编辑碰撞和出生点 | 在碰撞层选择类型和形状，再刷到地图上。也可从地形生成碰撞后手动修整。出生点可在画布上移动。 |
| 做巡逻路线、战棋格或区域连接 | 通过格图编辑区域和有向连接，也可从已有瓦片层生成格。游戏声明了对应字段后，可在内容里引用地图上的实例、端口、格或路径。 |
| 管理多张地图 | 「设置」提供改名、复制、调整尺寸和另存转换格空间；「地图 → 编辑项目世界布局」可查看和安排地图在项目中的位置。 |

地图可使用正交、等距、六边形或三角格，也可用自定义斜基。格系决定怎么铺格、取点；最终镜头和画面由游戏负责。游戏提供实景预览时，可以在画面里选点、放置资产或拾取引用。实景是单帧；连续刷瓦片和改碰撞仍在主画布完成。

主菜单、设置、HUD 和结算等画面，可以用地图或共享绘制层制作。游戏侧需要提供对应的图片、控件实体和行为。例如，背景图只负责摆放；音量滑块是实体，位置和外观在画布布置，改音量的行为在「内容」配置。**现有的独立屏幕布局也仍可使用**，它支持锚点、画幅适配、文案和目标连线；已经使用它的项目可以继续维护。

## 编辑行为与流程

**给地图实体配置行为：** 在「内容」选中地图里的实例，添加游戏允许的功能，再填写参数或选择要引用的内容。例如，给门配置出口，给 NPC 配置对话，给设置按钮配置打开目标地图的行为。背景等纯摆放素材不参与执行。

**制作可复用的内容：** 「内容 → 项目内容库」可创建独立内容，例如卡组、任务、对白或结算规则。多个实例可以引用同一份内容。改显示名不会改变引用；编辑器按地图码、实例码和内容 ID 定位数据。

**编排步骤和连接：** 「编辑演出」可用列表或时间轴编排步骤；时间单位由项目声明，可用秒、帧或拍。项目提供对应数据时，还可试听音频、编辑数值关键帧曲线，或在指定时刻取样游戏画面。「流程关系」可查看地图、内容和屏幕之间的连接，定位需要修改的引用。

## 给多张地图共用绘制、碰撞或事件

比如 A、E、G 三张关卡共用一段带碰撞的地形，并使用同一套结算事件：

1. 打开「地图 → 图组 · 绘制与事件」，新建一组并勾选 A、E、G。可按名称或码筛选地图，或只看已勾选的地图。选择「适用于全部地图」时，也包括将来新增的基础地图。
2. 点「保存并编辑绘制层」。图组和普通地图使用同一个画布：可以增减自己的图层、铺瓦片、摆场景图片和实体，并在自己的碰撞层涂碰撞。图组有独立地图码，只保存一份。
3. 在同一面板用「上移」「下移」调整绘制顺序。列表上方遮挡下方，「普通地图」是前后分界。每个图组整组移动，内部图层顺序保持不变。排序对所有地图生效；每张地图只叠放适用于自己的图组。
4. 切回 A、E 或 G，画布会按保存的顺序叠加绘制。在图组绘制文档也可用地图菜单中的「选择图组叠加参照」直接切换适用地图。参照只读，可关闭；编辑只写当前文档。
5. 可在同一个图组窗口选公共事件的时机和目标；内容库也会打开此窗口。图组可以只共享绘制和碰撞，也可以只绑定事件。游戏决定何时应用这些内容。

基础地图各自保留自己的图层、碰撞、摆放物和出口。保存图组不会改写基础地图；多个图组可以共同叠加在一张基础地图上。

## 使用游戏生成地图

游戏提供生成器时，可从「设置 → 从游戏生成地图」选生成器、填参数，生成结果会作为地图打开，之后照常手工编辑。重新生成会新建一张图，保留原图；已有手工改动不会自动合并到新结果。

## 保存、恢复和试玩

- **保存：** 按 `Ctrl+S` 保存当前编辑内容。切图前若有未保存修改，编辑器会提示。
- **恢复：** 「地图 → 恢复草稿」可找回可用的自动保存草稿。恢复的草稿须再次保存，才会成为正式版本。
- **审阅：** 「地图 → 查看 MCP 草稿」可核对地图、内容与项目配置的差异，预览涉及的地图，并校验发布所选版本。覆盖保存时，地图历史与正式地图存放在同目录下的 `.history`。
- **交付：** 「检查与试玩」集中显示正式入口、正式数据结构检查及最近试玩结果。加载回执只表明游戏加载了数据；游戏行为请实际操作确认。
- **试玩：** 普通「试玩」先保存，再启动游戏进入当前地图。项目接入相应入口后，也可从项目正式入口启动，或在内容库单独试玩一条已保存的内容。
- **快捷键：** `Ctrl+Z` 撤销，`Ctrl+Y` 重做，滚轮缩放，中键或空格拖动平移；按 `?` 查看完整列表。

## 复用与动态素材

- 「浏览项目地图」可按近期、相关、固定或全项目找图。用「参照其素材」从已有地图选材；「浏览素材」可按用途、标签、收藏和参照图使用情况筛选，落地仍在当前图及图层。
- 实例的「功能编排」先展示真实序号、时机和内容名。可按时机查看，选中一条后在它后面插入，或选其他同资产实例追加复用一组绑定并共享内容。项目内容库的「查看使用处 / 批量改绑」可把指定绑定的替换保存为待审阅草稿。
- 长演出可从摘要列表定位具体步骤，可在播放头时间添加步骤，也可以对一段步骤统一平移或设置时间间隔。
- 可把原型保留为一张普通地图，用「复制整张地图」制作变体；也可以复制一块区域，再粘贴到格空间兼容的地图。复制会按预览计划分配新实例身份并改接应当随副本迁移的引用。需要多张地图共同引用同一份绘制时，用图组。当前没有独立的区域模板库或嵌套实例。
- 瓦片可手选衔接片；规则化地形可用游戏声明的地图生成器铺好，再在编辑器里修改。当前画笔不会随邻格自动换片。运行时瓦片动画由游戏实现；画布显示图集格，动态效果在游戏预览或试玩里检查。

## 源码逐文件总览

下面列出 `src/` 内的脚本和入口场景，每个文件只说明主要职责。Godot 自动生成的 `.uid` 是对应资源的标识，不单列。

### 内容制作 MCP · `src/mcp/`

| 文件 | 主要职责 |
| --- | --- |
| [server.gd](../src/mcp/server.gd) | 在编辑器进程内接收本机 MCP 请求，分发工具并返回结构化结果与媒体。 |
| [workbench.gd](../src/mcp/workbench.gd) | 定义工具参数，提供工程描述、查询、校验、生成与发布入口。 |
| [drafts.gd](../src/mcp/drafts.gd) | 管理按项目隔离的草稿、修订历史和发布基线。 |
| [edits.gd](../src/mcp/edits.gd) | 把一批作者操作应用到候选地图、内容和清单，再统一校验。 |
| [media.gd](../src/mcp/media.gd) | 定位编辑器面板、截取画面、绘制草稿地图、请求游戏预览和管理试玩。 |

### 应用入口 · `src/`

| 文件 | 主要职责 |
| --- | --- |
| [app.gd](../src/app.gd) | 应用入口；处理项目切换、视图切换和全局快捷键。 |
| [editor.tscn](../src/editor.tscn) | Godot 启动场景，加载应用脚本。 |

### 公共编辑逻辑 · `src/core/`

| 文件 | 主要职责 |
| --- | --- |
| [constants.gd](../src/core/constants.gd) | 地图默认尺寸、碰撞占位格等共享常量。 |
| [undo_history.gd](../src/core/undo_history.gd) | 记录瓦片、实例、区域和内容的改动，支持撤销与重做。 |

### 资产声明 · `src/assets/`

| 文件 | 主要职责 |
| --- | --- |
| [asset_decl.gd](../src/assets/asset_decl.gd) | 读取并整理图集、图片和实体声明，供画布和资产目录使用。 |
| [builtin_kinds.gd](../src/assets/builtin_kinds.gd) | 提供内置触发区域；加载时加入，保存清单时剥离。 |
| [collision_types.gd](../src/assets/collision_types.gd) | 读取游戏声明的碰撞类型，未声明时提供默认类型。 |
| [image_probe.gd](../src/assets/image_probe.gd) | 处理图片透明边缘，供缩略图使用。 |

### 地图画布 · `src/canvas/`

| 文件 | 主要职责 |
| --- | --- |
| [canvas_draw.gd](../src/canvas/canvas_draw.gd) | 绘制网格、选区、引用连线和笔刷预览。 |
| [canvas_input.gd](../src/canvas/canvas_input.gd) | 将鼠标操作分派给平移、缩放、笔刷、选择和拖动。 |
| [collision_view.gd](../src/canvas/collision_view.gd) | 按碰撞类型绘制可见的格子和形状。 |
| [editor_canvas.gd](../src/canvas/editor_canvas.gd) | 装载地图和图层，管理画布相机，并叠加基础地图与共享绘制层的只读参照。 |
| [editor_state.gd](../src/canvas/editor_state.gd) | 切换活动图层、资产类别和笔刷，并同步工具界面。 |
| [entity_node.gd](../src/canvas/entity_node.gd) | 表示画布上的图片或实体，处理位置、锚点、变换和命中。 |
| [entity_poly_view.gd](../src/canvas/entity_poly_view.gd) | 按实体局部坐标绘制多边形与路径。 |
| [geometry_draw_tool.gd](../src/canvas/geometry_draw_tool.gd) | 处理画布上新描路径、轮廓和几何部件的手势。 |
| [grid_space.gd](../src/canvas/grid_space.gd) | 定义正交、等距、六边和三角格，以及格坐标与像素的换算。 |
| [layer_ops.gd](../src/canvas/layer_ops.gd) | 管理图层增删、排序、显隐与锁定，以及摆放物归层。 |
| [ref_ops.gd](../src/canvas/ref_ops.gd) | 写回画布上选中的实例引用和连线目标。 |
| [region_ops.gd](../src/canvas/region_ops.gd) | 复制、剪切、粘贴或搬动选区，并重映射相关引用。 |
| [selection_ops.gd](../src/canvas/selection_ops.gd) | 单选、多选和拖动实体，处理实体剪贴板及编辑把手。 |
| [tile_replace.gd](../src/canvas/tile_replace.gd) | 计算批量替换瓦片的范围、替换结果和冲突。 |
| [tileset_cache.gd](../src/canvas/tileset_cache.gd) | 从图集构建并缓存画布使用的瓦片集。 |
| [tool_ops.gd](../src/canvas/tool_ops.gd) | 执行涂刷、擦除、摆放和从地形生成碰撞等工具操作。 |
| [tri_tile_view.gd](../src/canvas/tri_tile_view.gd) | 绘制原生瓦片节点不能直接显示的三角格和自定义斜基瓦片。 |
| [world_region_move.gd](../src/canvas/world_region_move.gd) | 处理跨图层框选和搬动，换算各层位置。 |

### 地图数据 · `src/map/`

| 文件 | 主要职责 |
| --- | --- |
| [cell_graph.gd](../src/map/cell_graph.gd) | 定义格图的空间、多边形和连边，提供格的查找和选取。 |
| [cell_graph_clip.gd](../src/map/cell_graph_clip.gd) | 随选区搬动或复制格、连边及其引用。 |
| [cell_graph_tiles.gd](../src/map/cell_graph_tiles.gd) | 从瓦片生成多边形格和邻接关系。 |
| [edge_ref.gd](../src/map/edge_ref.gd) | 生成和解析稳定格边引用，判断两格是否共边。 |
| [map_convert.gd](../src/map/map_convert.gd) | 计算整图改用另一种格空间时的实例坐标和出生点。 |
| [map_data_validation.gd](../src/map/map_data_validation.gd) | 检查地图、图层、瓦片、碰撞和实例数据结构。 |
| [map_flow.gd](../src/map/map_flow.gd) | 读取和整理单张地图的规则槽与流程出口。 |
| [map_format.gd](../src/map/map_format.gd) | 定义地图格式及瓦片翻转、旋转的编码。 |
| [map_store.gd](../src/map/map_store.gd) | 读写地图，维护地图码索引，并处理改名和整图复制。 |
| [map_view_data.gd](../src/map/map_view_data.gd) | 计算图层变换、地图范围和摆放物位置，供画布与预览使用。 |
| [object_geometry.gd](../src/map/object_geometry.gd) | 校核和整理实体多边形、路径及其点集。 |
| [recovery.gd](../src/map/recovery.gd) | 管理自动保存草稿和未完成的多文件提交记录。 |
| [tile_layer_convert.gd](../src/map/tile_layer_convert.gd) | 计算单个瓦片层转换格系后的落点，并报告越界和重叠。 |

### 内容数据 · `src/content/`

| 文件 | 主要职责 |
| --- | --- |
| [authoring_catalog.gd](../src/content/authoring_catalog.gd) | 从游戏声明和地图用量组织资产与功能候选，供人工界面和 MCP 共用。 |
| [audio_decl.gd](../src/content/audio_decl.gd) | 读取游戏的音频声明，分配并解析音频码。 |
| [clone_plan.gd](../src/content/clone_plan.gd) | 复制地图或区域时为新实例和内容分配身份，并改接内部引用。 |
| [condition_decl.gd](../src/content/condition_decl.gd) | 读取条件及其字段声明，管理对应执行码。 |
| [content_id.gd](../src/content/content_id.gd) | 生成地图、实体、实例和功能码，并组合实例内容 ID。 |
| [content_store.gd](../src/content/content_store.gd) | 按功能声明 ID 和内容 ID 读写、列出或删除内容文件。 |
| [declaration_pool.gd](../src/content/declaration_pool.gd) | 为各声明表提供共用的读取、缓存和补码逻辑。 |
| [flow_target.gd](../src/content/flow_target.gd) | 定义内容、地图、地图端口和屏幕的目标格式及允许范围。 |
| [function_decl.gd](../src/content/function_decl.gd) | 读取功能声明，维护功能执行码和实体类型自带的绑定。 |
| [keyframe_curve.gd](../src/content/keyframe_curve.gd) | 整理数值曲线关键帧并计算插值。 |
| [ref_fields.gd](../src/content/ref_fields.gd) | 解释地图、实例、端口、格等引用字段及其配对范围。 |
| [rel_graph.gd](../src/content/rel_graph.gd) | 从已保存的地图、内容和屏幕引用生成关系图，并提供改接逻辑。 |
| [step_decl.gd](../src/content/step_decl.gd) | 读取演出步骤声明，管理步骤及其字段码。 |
| [step_interval_index.gd](../src/content/step_interval_index.gd) | 按轨道查找落在可见时间区间内的步骤。 |
| [step_timeline.gd](../src/content/step_timeline.gd) | 计算步骤起止时间和轨道，整理时间轴改动与重叠提示。 |
| [timeline_clock.gd](../src/content/timeline_clock.gd) | 根据帧率或速度段在帧、拍和秒之间换算。 |
| [trigger_decl.gd](../src/content/trigger_decl.gd) | 读取游戏声明的触发时机，管理时机码。 |

### 项目、预览与试玩 · `src/project/`

| 文件 | 主要职责 |
| --- | --- |
| [asset_scan.gd](../src/project/asset_scan.gd) | 扫描约定目录，为新发现的资产添加清单条目。 |
| [document_commit.gd](../src/project/document_commit.gd) | 按顺序发布改名或复制涉及的地图和内容文件。 |
| [document_session.gd](../src/project/document_session.gd) | 记录当前地图会话、编辑修订和磁盘摘要。 |
| [event_layers.gd](../src/project/event_layers.gd) | 管理图组事件层数据，按基础地图码找适用的共享绘制层。 |
| [frame_picks.gd](../src/project/frame_picks.gd) | 读取游戏预览的选点区域，将实景点击换算成目标或局部坐标。 |
| [game_preview.gd](../src/project/game_preview.gd) | 请求游戏渲染预览，并读取游戏返回的图像和拾取数据。 |
| [manifest.gd](../src/project/manifest.gd) | 读取游戏清单、准备编辑器所需的路径和声明。 |
| [manifest_validation.gd](../src/project/manifest_validation.gd) | 检查项目清单的资产、功能、时机等声明。 |
| [map_generators.gd](../src/project/map_generators.gd) | 读取游戏生成器的参数声明、预设和重生成所需信息。 |
| [playtest.gd](../src/project/playtest.gd) | 根据项目配置启动并跟踪独立游戏进程。 |
| [project_content_slots.gd](../src/project/project_content_slots.gd) | 读取旧项目的具名规则槽和内容绑定。 |
| [reference_index.gd](../src/project/reference_index.gd) | 按稳定地图码、实例码等解析引用，并读取共享绘制地图。 |
| [reference_usage.gd](../src/project/reference_usage.gd) | 查询资产、内容和屏幕被哪些地方引用，供删除检查使用。 |
| [screen_layout.gd](../src/project/screen_layout.gd) | 定义屏幕元素、父级、锚点、画幅覆盖和焦点导航。 |
| [screen_reference_validation.gd](../src/project/screen_reference_validation.gd) | 检查屏幕模块字段和出口引用。 |
| [spatial_reference_check.gd](../src/project/spatial_reference_check.gd) | 检查地图上的实例、图层、端口、格和格边引用。 |
| [startup_targets.gd](../src/project/startup_targets.gd) | 检查和解析游戏启动入口允许的目标。 |
| [world_layout.gd](../src/project/world_layout.gd) | 读取和整理项目中的地图位置与生成分块配置。 |

### 界面和工具 · `src/ui/`

| 文件 | 主要职责 |
| --- | --- |
| [content_usage_dialog.gd](../src/ui/content_usage_dialog.gd) | 选择正式实例绑定的确切来向，生成待核对的批量改绑草稿。 |
| [asset_panel.gd](../src/ui/asset_panel.gd) | 显示资产目录、编辑资产声明与实体类型的功能挂载。 |
| [cell_graph_editor.gd](../src/ui/cell_graph_editor.gd) | 提供格图编辑窗口，用于画格、改属性和连边。 |
| [collision_dialog.gd](../src/ui/collision_dialog.gd) | 提供从瓦片生成碰撞的范围和策略选项。 |
| [content_editor.gd](../src/ui/content_editor.gd) | 组织实例列表、内容绑定、表单和演出入口。 |
| [content_form.gd](../src/ui/content_form.gd) | 编辑单条内容的字段，处理新建、共享绑定、保存和删除。 |
| [content_preview.gd](../src/ui/content_preview.gd) | 显示内容工作台中的地图预览，支持点选和定位。 |
| [destination_slot_field.gd](../src/ui/destination_slot_field.gd) | 按允许的目标类型生成地图、屏幕、内容或端口选择控件。 |
| [editor_layout.gd](../src/ui/editor_layout.gd) | 搭建关卡编辑界面，连接地图画布、工具栏和状态栏。 |
| [event_layers_dialog.gd](../src/ui/event_layers_dialog.gd) | 配置图组范围和共享事件，保存并打开共享绘制地图。 |
| [field_widgets.gd](../src/ui/field_widgets.gd) | 根据游戏声明构建数字、选项、数组、引用等字段控件。 |
| [fn_bind.gd](../src/ui/fn_bind.gd) | 显示和编辑实例上的功能绑定，包括顺序、时机和启用状态。 |
| [game_frame_dialog.gd](../src/ui/game_frame_dialog.gd) | 提供游戏实景渲染、取景和确认选点的共用弹窗。 |
| [grid_basis_fields.gd](../src/ui/grid_basis_fields.gd) | 提供自定义格基向量的输入控件。 |
| [keyframe_curve_field.gd](../src/ui/keyframe_curve_field.gd) | 提供加点、拖点和修改插值的曲线控件。 |
| [layer_panel.gd](../src/ui/layer_panel.gd) | 提供活动图层切换、显隐、锁定和图层管理。 |
| [map_file.gd](../src/ui/map_file.gd) | 协调新建、打开、保存、复制和恢复地图，以及共享绘制层切换。 |
| [map_flow_dialog.gd](../src/ui/map_flow_dialog.gd) | 编辑当前地图的流程出口和规则槽。 |
| [map_game_preview.gd](../src/ui/map_game_preview.gd) | 将地图工作副本交给游戏预览，接收资产摆放和引用选点。 |
| [map_generator_dialog.gd](../src/ui/map_generator_dialog.gd) | 收集生成参数，调用游戏生成器并打开生成的地图。 |
| [map_resize.gd](../src/ui/map_resize.gd) | 调整地图尺寸，预览并裁掉越界数据。 |
| [mcp_draft_review.gd](../src/ui/mcp_draft_review.gd) | 选择、刷新和预览当前工程的 MCP 草稿地图，与人工画布分开。 |
| [palette_panel.gd](../src/ui/palette_panel.gd) | 列出瓦片图集、图片和实体，供画布选用。 |
| [playtest_controller.gd](../src/ui/playtest_controller.gd) | 协调试玩前的保存、游戏启动、配置和加载回执。 |
| [popups.gd](../src/ui/popups.gd) | 提供共用弹窗外壳和快捷键速查。 |
| [project_content_library.gd](../src/ui/project_content_library.gd) | 浏览和编辑独立内容，提供流程图与图组事件入口。 |
| [project_picker.gd](../src/ui/project_picker.gd) | 提供项目选择页，记录已打开的项目。 |
| [project_shell.gd](../src/ui/project_shell.gd) | 承载内容和资产工作台，并在切换后还原编辑位置。 |
| [reference_view_library.gd](../src/ui/reference_view_library.gd) | 管理参考视图和独立屏幕的草稿、保存与试玩入口。 |
| [rel_graph_view.gd](../src/ui/rel_graph_view.gd) | 绘制流程关系图，处理节点、连线选择和改接。 |
| [screen_layout_canvas.gd](../src/ui/screen_layout_canvas.gd) | 绘制独立屏幕布局，处理元素的点选、拖动和缩放。 |
| [screen_layout_form.gd](../src/ui/screen_layout_form.gd) | 编辑屏幕元素的布局、文案、模块字段和流程目标。 |
| [session_context.gd](../src/ui/session_context.gd) | 按绑定 ID、内容 ID 或步骤索引恢复上一次选中的位置。 |
| [startup_dialog.gd](../src/ui/startup_dialog.gd) | 选择游戏正式启动目标及可选的地图上下文。 |
| [steps_panel.gd](../src/ui/steps_panel.gd) | 提供演出步骤列表、步骤表单、时间轴和预览入口。 |
| [tile_replace_dialog.gd](../src/ui/tile_replace_dialog.gd) | 选择替换前后的瓦片，预览冲突并应用批量替换。 |
| [timeline_audio_preview.gd](../src/ui/timeline_audio_preview.gd) | 播放、定位时间轴音频，并生成 WAV 波形概览。 |
| [timeline_view.gd](../src/ui/timeline_view.gd) | 绘制时间轴轨道，支持拖动、调时长和换轨。 |
| [top_bar_nav.gd](../src/ui/top_bar_nav.gd) | 提供地图切换、图组绘制层入口及关卡、内容、资产切换按钮。 |
| [ui_kit.gd](../src/ui/ui_kit.gd) | 提供按钮、字段行、标题和空状态等共用界面组件。 |
| [ui_theme.gd](../src/ui/ui_theme.gd) | 集中定义编辑器颜色、字号和控件样式。 |
| [viewport_library.gd](../src/ui/viewport_library.gd) | 新增和编辑项目的参考画幅。 |
| [world_layout_editor.gd](../src/ui/world_layout_editor.gd) | 在项目地图总览中编辑地图位置和生成分块键。 |
