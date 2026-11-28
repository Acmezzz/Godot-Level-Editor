# 源码逐文件总览

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
| [canvas_snapshot.gd](../src/canvas/canvas_snapshot.gd) | 将画布状态序列化成地图快照、瓦片与摆放物记录，供保存和撤销使用。 |
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
| [layer_stack.gd](../src/map/layer_stack.gd) | 修改图层顺序或删除图层，并同步图层所属数据。 |
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
| [content_value_validation.gd](../src/content/content_value_validation.gd) | 对照游戏声明检查内容值，报告字段和步骤数据错误。 |
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
| [event_layers.gd](../src/project/event_layers.gd) | 管理图组事件层数据，按基础地图码找适用的共享绘制层。 |
| [frame_picks.gd](../src/project/frame_picks.gd) | 读取游戏预览的选点区域，将实景点击换算成目标或局部坐标。 |
| [game_preview.gd](../src/project/game_preview.gd) | 请求游戏渲染预览，并读取游戏返回的图像和拾取数据。 |
| [manifest.gd](../src/project/manifest.gd) | 读取游戏清单、准备编辑器所需的路径和声明。 |
| [manifest_validation.gd](../src/project/manifest_validation.gd) | 检查项目清单的资产、功能、时机等声明。 |
| [map_generators.gd](../src/project/map_generators.gd) | 读取游戏生成器的参数声明、预设和重生成所需信息。 |
| [playtest.gd](../src/project/playtest.gd) | 根据项目配置启动并跟踪独立游戏进程。 |
| [project_data_check.gd](../src/project/project_data_check.gd) | 汇总工程的地图、内容和引用问题，供界面和 MCP 校验使用。 |
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
| [map_file.gd](../src/ui/map_file.gd) | 管理地图会话、新建、打开、保存、复制、恢复和共享绘制层切换。 |
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
