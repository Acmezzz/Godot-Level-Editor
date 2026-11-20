extends RefCounted
## _layout_ctrl：从 src/app.gd 拆出的控制器。宿主状态经 app 引用。

const TopBarNavScript := preload("res://src/ui/top_bar_nav.gd")
const CollisionTypes := preload("res://src/core/collision_types.gd")
const ProjectAudit := preload("res://src/core/project_audit.gd")
const EntityNodeScript := preload("res://src/canvas/entity_node.gd")
const IssuesDrawer := preload("res://src/ui/issues_drawer.gd")
const LayerPanel := preload("res://src/ui/layer_panel.gd")
const Popups := preload("res://src/ui/popups.gd")

var app   # 宿主引用
## 拆分出的子控制器
var _issues_ctrl   # issues_drawer.gd：问题抽屉
var _layer_ctrl   # layer_panel.gd：层下拉+层管理
var _popups_ctrl   # popups.gd：弹窗外壳/主题/速查
# 状态栏的常驻指示（与左侧消息分离，避免互相覆盖）
var _meta_tool: Label
var _meta_cursor: Label
var _dirty_badge: PanelContainer
# 画布视图开关（网格 / 框选）
var _grid_btn: Button
var _select_btn: Button
var _snap_btn: Button
## 层下拉（决定画在哪）。按钮显示当前层名，弹层里每层一行 + 👁/🔒。
var _layer_btn: Button
var _layer_menu: PopupPanel
var _layer_menu_body: VBoxContainer
## 层管理弹窗（新建/改名/上下移/删除/运行时可见）
var _layer_mgr: PopupPanel
var _layer_mgr_body: VBoxContainer
var _layer_mgr_rows: VBoxContainer
var _layer_mgr_input: LineEdit
## 选中实体信息条（不做属性表单，只给类型名 / 内容状态 / 去内容编辑器）
var _sel_bar: PanelContainer
var _sel_name: Label
var _sel_state: Label
var _sel_eye: Button
## 问题抽屉（REFACTOR_PLAN 4.6-3）：审计条目缓存 + 折叠面板 + 状态栏徽标
var _issues_btn: Button
var _issues_drawer: PanelContainer
var _issues_list: VBoxContainer
var _issues_scroll: ScrollContainer
var _issues_items: Array = []

func _init(host) -> void:
	app = host
	_issues_ctrl = IssuesDrawer.new(self)
	_layer_ctrl = LayerPanel.new(self)
	_popups_ctrl = Popups.new(self)
func _build_editor_ui() -> void:
	app._nav_bars.clear()  # 重建时丢弃旧顶栏导航条引用（控件已 queue_free）
	for c in app.get_children():
		app.remove_child(c)
		c.queue_free()
	DisplayServer.window_set_title("关卡编辑器 — %s" % app.manifest.get("projectName", "?"))
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	app.add_child(root)
	app._map_view = root

	root.add_child(_build_global_bar())

	var main := HBoxContainer.new()
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_theme_constant_override("separation", 0)
	root.add_child(main)
	main.add_child(_build_palette_column())

	# 中列 = 画布本体。画布上方不再有横带，画布吃满剩余宽高。
	var mid_col := VBoxContainer.new()
	mid_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mid_col.add_theme_constant_override("separation", 0)
	main.add_child(mid_col)

	# 画布（SubViewport 包裹）——最深的底色，让内容跳出来
	var canvas_wrap := Control.new()
	canvas_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	canvas_wrap.custom_minimum_size = Vector2(240, 0)
	mid_col.add_child(canvas_wrap)

	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var sv_bg = app.UiThemeScript.flat(app.UiThemeScript.BG_VOID, 0)
	svc.add_theme_stylebox_override("panel", sv_bg)
	canvas_wrap.add_child(svc)
	var sv := SubViewport.new()
	sv.handle_input_locally = false
	sv.size = Vector2i(100, 100)
	svc.add_child(sv)
	app.canvas = EditorCanvas.new()
	app.canvas.manifest = app.manifest
	app.canvas.set_entity_sizes(app._entity_sizes())
	sv.add_child(app.canvas)

	# 没开地图时画布是全空的：铺一层引导，别让人对着一片空白猜
	app._canvas_empty = app.UiKitScript.empty_state("▦", "没有正在编辑的地图",
		"用左上角地图名旁「▾」新建，或从菜单里打开已有地图")
	app._canvas_empty.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	app._canvas_empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
	app._canvas_empty.visible = false
	canvas_wrap.add_child(app._canvas_empty)

	# 选中实体信息条：浮在画布下沿，只给「类型 / 内容状态 / 去内容编辑器」。
	# 不做属性表单——参数属内容，归内容编辑器与资产目录。
	canvas_wrap.add_child(_build_sel_bar())

	root.add_child(_build_issues_drawer())
	root.add_child(_build_status_bar())

	app.canvas.cursor_info.connect(_on_cursor)
	app.canvas.modified.connect(_on_modified)
	app.canvas.entity_selected.connect(app._on_entity_selected)
	# 吸管：画布请求切工具/层，统一走 _apply_state 单一写入口
	app.canvas.tool_requested.connect(app._apply_state)
	app._fill_palettes()
	app._apply_state("paint", 0)  # 初始：地形层 + 涂刷，按钮高亮由 _sync_ui 统一刷新
	app._set_map_loaded(false)  # 防呆：没开地图前禁用全部编辑交互
	app._build_project_view()
	app._sync_panel_buttons("map")  # 两个顶栏导航条都建好了，初始按下「关卡」
	_set_status("无地图：先点「新建」填名字，或「打开」已有地图")


## 全局横带：项目名 · 设置▾ · 地图 ▾（固定文案）+ 三模式按钮 · 试玩。
## 地图 ▾ 点开容纳全部地图级动作；编辑工具与剪贴板按钮一概不在顶栏——
## 任一层 / 任一窗口宽度下都只有这几组东西，没有挤出可视区的风险。
func _build_global_bar() -> PanelContainer:
	var panel_wrap := PanelContainer.new()
	var sb = app.UiThemeScript.box(app.UiThemeScript.BG_BASE, app.UiThemeScript.BORDER, 0, 12, 6)
	sb.set_border_width_all(0)
	sb.border_width_bottom = 1
	panel_wrap.add_theme_stylebox_override("panel", sb)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)
	panel_wrap.add_child(bar)

	# 项目名做品牌锚点
	bar.add_child(app.UiKitScript.text_label(str(app.manifest.get("projectName", "?")),
		app.UiThemeScript.TEXT, app.UiThemeScript.FS_MD))
	bar.add_child(app.UiKitScript.vdivider())

	# —— 地图设置：新建 / 打开 / 保存 / 重命名 / 导出 / 尺寸 ——
	# 放在顶栏左侧。地图**切换**是另一件事，见右侧「地图 ▾」下拉。
	app._map_btn = app.UiKitScript.button("设置 ▾", Callable(), "plain")
	app._map_btn.tooltip_text = "地图设置：新建 / 打开 / 保存 · 重命名 / 导出 / 尺寸"
	app._map_btn.custom_minimum_size = Vector2(92, 0)
	bar.add_child(app._map_btn)
	var map_menu := PopupMenu.new()
	map_menu.add_item("新建地图", 1)
	map_menu.add_item("打开地图…", 2)
	map_menu.add_item("保存", 3)
	map_menu.add_separator()
	map_menu.add_item("重命名地图…", 10)
	map_menu.add_item("导出当前地图", 4)
	map_menu.add_item("调整地图尺寸", 5)
	map_menu.add_separator()
	map_menu.add_separator()
	map_menu.add_item("检查项目完整性", 30)
	map_menu.add_item("切换项目…", 20)
	map_menu.id_pressed.connect(_on_map_menu_id)
	app._map_btn.pressed.connect(func(): _popup_below(map_menu, app._map_btn))
	bar.add_child(map_menu)

	bar.add_child(app.UiKitScript.spacer())

	# —— 地图 ▾ + 三个模式按钮：与项目页共用同一套实现 ——
	app._nav_bars.append(TopBarNavScript.new(app))
	app._nav_bars.back().build()
	bar.add_child(app._nav_bars.back())

	bar.add_child(app.UiKitScript.vdivider())
	var cfg: Button = app.UiKitScript.button("试玩配置", app._open_play_cfg, "ghost")
	cfg.tooltip_text = "每图初始能力 / 血量"
	bar.add_child(cfg)
	var play = app.UiKitScript.button("▶  试玩", app._on_play, "primary")
	play.tooltip_text = "保存并启动游戏（当前地图）"
	bar.add_child(play)
	return panel_wrap

## 地图菜单：新建 / 打开 / 保存 / 重命名 / 导出 / 尺寸。
func _on_map_menu_id(id: int) -> void:
	match id:
		1:
			app._on_new()
		2:
			app._on_open()
		3:
			app._on_save()
		4:
			app._open_export_dialog()
		5:
			app._open_size_dialog()
		10:
 # 顶栏名字输入框已删：改名只能从菜单进弹窗
			app._on_rename()
		20:
			app._switch_project()
		30:
			_run_audit(true)

## 在锚点控件正下方弹菜单（宽高交给引擎按内容测算）
func _popup_below(pm: PopupMenu, anchor: Control) -> void:
	var at := Vector2i(anchor.get_screen_position()) + Vector2i(0, int(anchor.size.y))
	pm.popup(Rect2i(at, Vector2i.ZERO))


## 左栏：层下拉 + 瓦片/实体两组列表（互斥显示）+ 碰撞类型/形状控件（grid 层）

func _build_palette_column() -> PanelContainer:
	var col := PanelContainer.new()
	# 左栏 200px（原 252）。它是「选一次、用很久」的低频操作，宽度让步给画布。
	col.custom_minimum_size = Vector2(200, 0)
	var sb = app.UiThemeScript.box(app.UiThemeScript.BG_PANEL, app.UiThemeScript.BORDER, 0, 10, 10)
	sb.set_border_width_all(0)
	sb.border_width_right = 1
	col.add_theme_stylebox_override("panel", sb)

	var v = app.UiKitScript.vbox(8)
	col.add_child(v)

	# —— 层下拉 + 管理按钮：层决定画在哪，place_kind（调色板）决定画什么——
	var layer_row = app.UiKitScript.hbox(4)
	_layer_btn = app.UiKitScript.button("层：—", Callable(), "plain")
	_layer_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_layer_btn.tooltip_text = "选择图层：图层决定画在哪，place_kind 决定画什么"
	_layer_btn.pressed.connect(_toggle_layer_menu)
	_layer_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layer_row.add_child(_layer_btn)
	var mgr_btn = app.UiKitScript.button("管理", func(): _open_layer_manager(), "ghost")
	mgr_btn.tooltip_text = "图层管理：新建 / 改名 / 排序 / 删除 / 运行时可见"
	layer_row.add_child(mgr_btn)
	v.add_child(layer_row)

	# 弹层内容按清单重建：每层一行 = 层名 + 👁 + 🔒，显隐/锁定内联在项里（不占额外高度）。
	# 本控制器是 RefCounted（没有 add_child），弹层挂到窗口根——和所有其他弹窗一致。
	_layer_menu = PopupPanel.new()
	_layer_menu_body = app.UiKitScript.vbox(2)
	_layer_menu_body.custom_minimum_size = Vector2(196, 0)
	_layer_menu.add_child(_layer_menu_body)
	app.add_child(_layer_menu)

	var holder := Control.new()
	# 资产列表吃掉剩余高度（右栏检查器已删，画布与列表各得其所）
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(holder)
	var full := func(c: Control) -> void:
		c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	app.tile_list = ItemList.new()
	app.tile_list.icon_mode = ItemList.ICON_MODE_TOP
	app.tile_list.fixed_icon_size = Vector2i(40, 40)
	# 左栏收到 200px 后 4 列 × 68px 会横向溢出（文字被省略成「一 岩块件…」）。
	# 3 列 × 56px 刚好吃满，图标尺寸不变。
	app.tile_list.max_columns = 3
	app.tile_list.same_column_width = true
	app.tile_list.allow_reselect = true
	app.tile_list.fixed_column_width = 56
	app.tile_list.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	# 瓦片列表点击走调色板控制器路由（两级导航：类别 → 资产）
	app.tile_list.item_clicked.connect(func(i: int, at: Vector2, mb: int): app._palette_ctrl.on_tile_click(i, at, mb))
	holder.add_child(app.tile_list)
	full.call(app.tile_list)

	app.ent_list = ItemList.new()
	# 实体名较长（如「羽毛（冲刺）」），单列横排图标+名称，保证完整可读
	app.ent_list.icon_mode = ItemList.ICON_MODE_LEFT
	app.ent_list.fixed_icon_size = Vector2i(36, 36)
	app.ent_list.max_columns = 1
	app.ent_list.allow_reselect = true
	app.ent_list.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	app.ent_list.item_clicked.connect(app._on_ent_pick)
	app.ent_list.visible = false
	holder.add_child(app.ent_list)
	full.call(app.ent_list)

	# 碰撞层：左栏没有可选资产（碰撞块是画上去的，不是挑出来的）。
	# 但碰撞**类型**必须可选——类型决定游戏里的物理行为，画之前就得定下来。
	var grid_hint: VBoxContainer = app.UiKitScript.vbox(8)
	grid_hint.visible = false

	# 类型：清单 collisionTypes 声明（没声明用内置缺省池）；gameplay 语义归游戏侧
	var type_row: HBoxContainer = app.UiKitScript.hbox(8)
	type_row.add_child(app.UiKitScript.text_label("类型", app.UiThemeScript.TEXT_DIM, app.UiThemeScript.FS_SMALL))
	var type_opt := OptionButton.new()
	type_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for row in CollisionTypes.pool(app.manifest):
		var d: Dictionary = row
		var tid := str(d.get("id", ""))
		var nm := str(d.get("name", tid))
		type_opt.add_item("%s（%s）" % [nm, tid] if nm != tid else tid)
		type_opt.set_item_metadata(type_opt.item_count - 1, tid)
	type_opt.tooltip_text = "这一笔画下去的碰撞类型；类型池与形状/颜色由清单 collisionTypes 声明"
	type_opt.item_selected.connect(func(i: int):
		app.canvas.collision_type = str(type_opt.get_item_metadata(i))
		app._set_status("碰撞类型：%s" % str(type_opt.get_item_text(i)))
		_refresh_tool_meta())
	type_row.add_child(type_opt)
	grid_hint.add_child(type_row)

	# 形状：矩形 / r45 / l45（斜坡只对实心/单向有意义，其余类型仍按整格处理）
	var shape_row: HBoxContainer = app.UiKitScript.hbox(8)
	shape_row.add_child(app.UiKitScript.text_label("形状", app.UiThemeScript.TEXT_DIM, app.UiThemeScript.FS_SMALL))
	var shape_opt := OptionButton.new()
	shape_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for spec in [["", "矩形（整格）"], ["r45", "斜坡 ◣（右高）"], ["l45", "斜坡 ◤（左高）"]]:
		shape_opt.add_item(str(spec[1]))
		shape_opt.set_item_metadata(shape_opt.item_count - 1, str(spec[0]))
	shape_opt.tooltip_text = "实心/单向碰撞的格子形状；斜坡画成三角"
	shape_opt.item_selected.connect(func(i: int):
		app.canvas.collision_shape = str(shape_opt.get_item_metadata(i))
		app._set_status("碰撞形状：%s" % str(shape_opt.get_item_text(i)))
		_refresh_tool_meta())
	shape_row.add_child(shape_opt)
	grid_hint.add_child(shape_row)

	var gh: Control = app.UiKitScript.empty_state("▨", "碰撞层直接画", "左键拖动涂碰撞块，右键擦除。先选上面的类型与形状。")
	gh.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 只占最小高度，让下面的「自动生成碰撞…」紧贴提示文字，而不是被顶到栏底
	gh.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	grid_hint.add_child(gh)
	var collision_gen: Button = app.UiKitScript.button("自动生成碰撞…", func(): app._open_collision_gen(), "plain")
	collision_gen.tooltip_text = "按地形轮廓整层生成（全部/仅边缘，可替换或叠加）"
	collision_gen.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid_hint.add_child(collision_gen)
	holder.add_child(grid_hint)
	full.call(grid_hint)
	app.grid_hint = grid_hint
	app._coll_type_opt = type_opt
	app._coll_shape_opt = shape_opt

	# 左栏只管「给画布喂什么」（图层 + 调色板）；
	# 碰撞生成 / 地图文件 / 状态控制器仍在这里建，供 app 的委托调用不变。
	app._props_panel_ctrl = preload("res://src/ui/props_panel.gd").new(app)
	app._map_file_ctrl = preload("res://src/ui/map_file.gd").new(app)
	app._editor_state_ctrl = preload("res://src/core/editor_state.gd").new(app)
	return col

## 资产列表跟随层类型：地形/装饰 → 瓦片，碰撞（grid）无资产 → 空，实体层 → 实体。
func _set_palette_page(which: String) -> void:
	if app.tile_list:
		app.tile_list.visible = which == "tiles"
	if app.ent_list:
		app.ent_list.visible = which == "entities"
	if app.grid_hint:
		app.grid_hint.visible = which == ""

## 图层类型小工具（editor_layout 自用）：栈层都是瓦片层，只有碰撞是栈外元层
func _layer_type_of(i: int) -> String:
	if i == app.canvas.collision_index():
		return "collision"
	return "tiles"

## 状态栏：左侧操作提示，右侧常驻坐标/工具/脏标记

func _build_status_bar() -> PanelContainer:
	var panel_wrap := PanelContainer.new()
	var sb = app.UiThemeScript.box(app.UiThemeScript.BG_BASE, app.UiThemeScript.BORDER, 0, 12, 5)
	sb.set_border_width_all(0)
	sb.border_width_top = 1
	panel_wrap.add_theme_stylebox_override("panel", sb)

	var h = app.UiKitScript.hbox(10)
	panel_wrap.add_child(h)

	app.status = app.UiKitScript.text_label("就绪", app.UiThemeScript.TEXT_DIM, app.UiThemeScript.FS_SMALL)
	app.status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	app.status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	h.add_child(app.status)

	# 框选开关（不用快捷键）：打开后左键拖动就是框选，再点关闭回到涂刷/放置
	_select_btn = app.UiKitScript.button("框选", app._toggle_select_mode, "toggle")
	_select_btn.tooltip_text = "打开后左键拖动框选；关闭则正常涂刷 / 放置"
	h.add_child(_select_btn)
	# 吸附开关：关掉后摆放物可落在任意像素位置（存浮点格坐标），默认开
	_snap_btn = app.UiKitScript.button("吸附", app._toggle_snap, "toggle")
	_snap_btn.tooltip_text = "摆放/拖动吸附到格（关掉后可按像素摆放，坐标存浮点）"
	_snap_btn.button_pressed = true
	h.add_child(_snap_btn)
	# 视图开关：常驻在状态栏右侧，看一眼就知道网格/碰撞显示开着没
	_grid_btn = app.UiKitScript.button("网格", app._toggle_grid, "toggle")
	_grid_btn.tooltip_text = "显示 / 隐藏网格"
	_grid_btn.button_pressed = true
	h.add_child(_grid_btn)
	# 独立的状态指示：光标位置 / 当前工具 / 未保存标记
	_meta_tool = app.UiKitScript.text_label("", app.UiThemeScript.TEXT_MUTE, app.UiThemeScript.FS_META)
	_meta_tool.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(_meta_tool)

	_meta_cursor = app.UiKitScript.text_label("", app.UiThemeScript.TEXT_MUTE, app.UiThemeScript.FS_META)
	_meta_cursor.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(_meta_cursor)

	_dirty_badge = app.UiKitScript.badge("未保存", app.UiThemeScript.WARN)
	_dirty_badge.visible = false
	h.add_child(_dirty_badge)
	# 快捷键速查入口常驻状态栏（? 键同效）——功能存在但没人知道等于不存在
	var help: Button = app.UiKitScript.button("?", func(): app._open_shortcut_help(), "ghost")
	help.tooltip_text = "快捷键速查（?）"
	help.custom_minimum_size = Vector2(26, 0)
	h.add_child(help)
	return panel_wrap

## 状态栏左侧消息（覆盖「已修改」提示时不会冲掉坐标显示）

func _set_status(msg: String) -> void:
	if app.status:
		app.status.text = msg.strip_edges()


func _on_cursor(t: String) -> void:
	# 光标坐标走独立指示位，不再覆盖左侧操作消息
	if _meta_cursor:
		_meta_cursor.text = "光标 %s" % t


func _on_modified() -> void:
	if app.canvas.modified_flag:
		_set_status("已修改 —— Ctrl+S 保存")
		_refresh_dirty_badge()


## 脏标记徽章：未保存时在状态栏常驻亮起

func _refresh_dirty_badge() -> void:
	if _dirty_badge:
		_dirty_badge.visible = app.map_loaded and app.canvas != null and app.canvas.modified_flag



## 状态栏右侧的层指示（工具概念已废除，这里只说「在哪一层、笔刷多大」）
func _refresh_tool_meta() -> void:
	if _meta_tool == null:
		return
	var lt := _layer_type_of(app.canvas.active_layer)
	var suffix := ""
	if lt == "collision":
 # 碰撞层没有涂抹尺寸的说法，真正要知道的是「这一笔画的是什么」
		suffix = " · %s %s" % [_collision_type_label(app.canvas.collision_type),
			_diagonal_shape_label(app.canvas.collision_shape)]
	elif app.canvas.place_kind == "object":
		suffix = " · 单击放置"
	else:
		suffix = " · %d×%d 拖动涂" % [app.canvas.brush_size, app.canvas.brush_size]
	_meta_tool.text = "%s%s" % [app._layer_label(app.canvas.active_layer), suffix]

func _collision_type_label(t: String) -> String:
	var d: Dictionary = CollisionTypes.decl_of(app.manifest, t)
	return str(d.get("name", t))

func _diagonal_shape_label(s: String) -> String:
	match s:
		"r45": return "斜坡◣"
		"l45": return "斜坡◤"
		_: return "矩形"


func _refresh_view_toggles() -> void:
	if _grid_btn:
		_grid_btn.button_pressed = app.canvas.show_grid
	if _select_btn:
		_select_btn.button_pressed = app.canvas != null and app.canvas.select_mode
	if _snap_btn:
		_snap_btn.button_pressed = app.canvas == null or app.canvas.snap_to_grid
	_refresh_layer_panel()
	_refresh_sel_bar()

## 选中实体信息条：类型名 + 内容状态 + 「在工作台编辑 →」。
## 不做属性表单——参数属内容，归内容编辑器与资产目录。
func _build_sel_bar() -> PanelContainer:
	_sel_bar = PanelContainer.new()
	var sb = app.UiThemeScript.box(Color(app.UiThemeScript.BG_PANEL, 0.94),
		app.UiThemeScript.BORDER, app.UiThemeScript.R_INNER, 8, 5)
	_sel_bar.add_theme_stylebox_override("panel", sb)
	_sel_bar.anchor_left = 0.0
	_sel_bar.anchor_top = 1.0
	_sel_bar.anchor_right = 0.0
	_sel_bar.anchor_bottom = 1.0
	_sel_bar.offset_left = 10
	_sel_bar.offset_top = -46
	_sel_bar.offset_right = 10
	_sel_bar.offset_bottom = -10
	_sel_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	var h = app.UiKitScript.hbox(8)
	_sel_bar.add_child(h)
	_sel_name = app.UiKitScript.text_label("", app.UiThemeScript.TEXT, app.UiThemeScript.FS_SMALL)
	h.add_child(_sel_name)
	_sel_state = app.UiKitScript.text_label("", app.UiThemeScript.TEXT_MUTE, app.UiThemeScript.FS_META)
	h.add_child(_sel_state)
	# 眼睛开关：隐藏的是「编辑器显示替身」（objects[].visible，缺省 true），游戏侧忽略
	_sel_eye = app.UiKitScript.button("👁", Callable(), "toggle")
	_sel_eye.toggled.connect(func(v: bool): _toggle_sel_visible(v))
	_sel_eye.add_theme_font_size_override("font_size", app.UiThemeScript.FS_META)
	_sel_eye.tooltip_text = "隐藏 / 显示此实例（仅编辑器显示状态，游戏侧忽略；隐藏后点不中，再点一次恢复）"
	h.add_child(_sel_eye)
	var go: Button = app.UiKitScript.button("在工作台编辑 →", func(): app._set_mode("content"), "ghost")
	go.tooltip_text = "去内容编辑器给这个实例挂功能（Enter 同效）"
	go.add_theme_font_size_override("font_size", app.UiThemeScript.FS_META)
	h.add_child(go)
	_sel_bar.visible = false
	return _sel_bar

## 信息条内容：随选中实例刷新；没选中就整条隐藏（不占画布视线）
func _refresh_sel_bar() -> void:
	if _sel_bar == null:
		return
	var n = app.selected_spr
	if n == null or not is_instance_valid(n):
		_sel_bar.visible = false
		return
	var sid: String = n.asset
	var eid: String = n.code
	var count: int = n.functions.size()
	# 场景实例没有实例码：只显示资产名（它不参与内容/引用体系）
	_sel_name.text = "%s  %s" % [app._scene_name(sid), eid] if eid != "" else app._scene_name(sid)
	if count == 0:
		_sel_state.text = "无附加功能" if n.is_entity() else "场景实例（不挂功能）"
		_sel_state.add_theme_color_override("font_color", app.UiThemeScript.TEXT_MUTE)
	else:
		_sel_state.text = "%d 个附加功能" % count
		_sel_state.add_theme_color_override("font_color", app.UiThemeScript.ACCENT_HI)
	if _sel_eye:
		_sel_eye.button_pressed = n.visible_flag
	_sel_bar.visible = true

## 眼睛开关：切换选中实例的编辑器可见性（objects[].visible，游戏侧忽略）。
func _toggle_sel_visible(v: bool) -> void:
	var n = app.selected_spr
	if n == null or not is_instance_valid(n):
		return
	app.canvas._push_undo()
	n.visible_flag = v
	app.canvas._mark()

## 图层面板已收进层下拉，保留下钻点供既有调用方（editor_state._sync_ui）使用。
func _sync_layer_buttons() -> void:
	_refresh_layer_panel()


func _build_project_view() -> void:
	app.project_shell = app.ProjectShellScript.new(app)
	app.project_shell.set_anchors_preset(Control.PRESET_FULL_RECT)
	app.project_shell.visible = false
	app.add_child(app.project_shell)
	app.project_shell.build()
	# 别名：视图面板的既有调用点（app.asset_panel）保持不变
	app.asset_panel = app.project_shell.asset_panel


## —— 拆到 src/ui/issues_drawer.gd / layer_panel.gd / popups.gd（调用点保持不变） ——

func _build_issues_drawer() -> PanelContainer:
	return _issues_ctrl._build_issues_drawer()
func _run_audit(open_after := true) -> void:
	_issues_ctrl._run_audit(open_after)
func _toggle_layer_menu() -> void:
	_layer_ctrl._toggle_layer_menu()
func _open_layer_manager() -> void:
	_layer_ctrl._open_layer_manager()
func _refresh_layer_panel() -> void:
	_layer_ctrl._refresh_layer_panel()
func _build_theme() -> void:
	_popups_ctrl._build_theme()
func _set_badge(p: PanelContainer, text: String, color: Color) -> void:
	_popups_ctrl._set_badge(p, text, color)
func _open_popup(pop: PopupPanel, size := Vector2i.ZERO) -> void:
	_popups_ctrl._open_popup(pop, size)
func _popup_body(title: String, subtitle := "") -> Dictionary:
	return _popups_ctrl._popup_body(title, subtitle)
func _open_shortcut_help() -> void:
	_popups_ctrl._open_shortcut_help()
