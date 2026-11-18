extends RefCounted
## _layout_ctrl：从 src/app.gd 拆出的控制器（审查 8.3 表）。宿主状态经 alias 引用。

var app   # 宿主引用
var _outline_timer   # PF-01：大纲重建防抖计时器（null=无在途重建）
# 状态栏的常驻指示（与左侧消息分离，避免互相覆盖）
var _meta_tool: Label
var _meta_cursor: Label
var _dirty_badge: PanelContainer
# 画布视图开关（网格 / 碰撞叠加 / 背景）
var _grid_btn: Button
var _collision_btn: Button
var _bg_btn: Button
## 画布上下文条容器（R3：按图层/工具动态重建）
var _context_bar: HBoxContainer

func _init(host) -> void:
	app = host
func _build_editor_ui() -> void:
	for c in app.get_children():
		app.remove_child(c)
		c.queue_free()
	DisplayServer.window_set_title("BIRD 关卡编辑器 — %s" % app.manifest.get("projectName", "?"))
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

	# 中列 = 画布工具条（贴顶）+ 画布本体（R3 三段式：左输入 / 中对象 / 右检查）
	var mid_col := VBoxContainer.new()
	mid_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mid_col.add_theme_constant_override("separation", 0)
	main.add_child(mid_col)
	mid_col.add_child(_build_canvas_toolbar())

	# 画布（SubViewport 包裹）——最深的底色，让内容跳出来
	var canvas_wrap := Control.new()
	canvas_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# 抽屉放大时不能让画布被压没：给一个下限，宁可让 HBox 溢出也不塌成一条线
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
		"用顶栏「新建」填名字创建，或从右侧地图列表双击打开")
	app._canvas_empty.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	app._canvas_empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
	app._canvas_empty.visible = false
	canvas_wrap.add_child(app._canvas_empty)

	# 内容抽屉：停靠在画布与侧栏之间，默认收起。它是「实例为主」的入口——
	# 选中实体后在这里直接给它建对话/事件/商店，地图和实体始终可见。
	app.content_dock = app.ContentDockScript.new(app)
	app.content_dock.visible = false
	app.content_dock.closed.connect(func(): app._set_content_dock(false))
	main.add_child(app.content_dock)

	# 右侧检查器：选中什么就检查什么（R2 三段式：左输入 / 中画布 / 右检查）
	app.side_panel = app.SidePanelScript.new()
	app.side_panel.build()
	main.add_child(app.side_panel)
	app.side_panel.attach_inspector(app.props_scroll)
	app.side_panel.map_open_requested.connect(app._open_map_by_name)
	# 缺口3：草稿条目单击 = 确认后打开草稿文件（保存时写回正式文件名）
	app.side_panel.draft_open_requested.connect(func(p: String):
		if not await app._confirm_discard("打开草稿 " + str(p.get_file())):
			return
		app._load_map_file(p))
	app.side_panel.refresh_maps_requested.connect(app._refresh_side_panel)
	app.side_panel.entity_focus_requested.connect(app._focus_entity)
	app.side_panel.entity_hover_requested.connect(func(id: String): app.canvas.set_hover_entity(id))
	app.side_panel.entity_delete_requested.connect(app._delete_entities_by_id)
	app.side_panel.issue_focus_requested.connect(app._focus_issue)
	# K18（批次 10）：地图右键管理（纯 rename / 复制）→ side_actions 控制器
	app.side_panel.map_rename_requested.connect(app._rename_map_by_name)
	app.side_panel.map_duplicate_requested.connect(app._duplicate_map_by_name)
	app.side_panel.validate_all_requested.connect(func(): app._run_validate(true))
	app.side_panel.validate_current_requested.connect(func(): app._run_validate(false))

	root.add_child(_build_status_bar())

	app.canvas.cursor_info.connect(_on_cursor)
	app.canvas.modified.connect(_on_modified)
	app.canvas.entity_selected.connect(app._on_entity_selected)
	# A1.1 吸管：画布请求切工具/层，统一走 _apply_state 单一写入口
	app.canvas.tool_requested.connect(app._apply_state)
	app._fill_palettes()
	app._apply_state("paint", 0)  # 初始：地形层 + 涂刷，按钮高亮由 _sync_ui 统一刷新
	app._set_map_loaded(false)  # 防呆：没开地图前禁用全部编辑交互
	app._build_project_view()
	app._refresh_side_panel()   # 启动即列出已有地图（未打开任何图也能看到清单）
	_set_status("无地图：先点「新建」填名字，或「打开」已有地图")


## 全局行（R3）：只剩项目身份 + 文件三键 + 项目页入口 + 试玩。
## 所有编辑工具移到画布工具条——顶栏不再是工具栏，宽度恒定在小窗内。
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

	# —— 文件组 ——
	app.map_name_edit = LineEdit.new()
	app.map_name_edit.placeholder_text = "地图名"
	app.map_name_edit.custom_minimum_size = Vector2(140, 0)
	app.map_name_edit.tooltip_text = "地图名（保存时写回）"
	bar.add_child(app.map_name_edit)
	bar.add_child(app.UiKitScript.button("新建", app._on_new, "plain"))
	bar.add_child(app.UiKitScript.button("打开", app._on_open, "plain"))
	var save: Button = app.UiKitScript.button("保存", app._on_save, "plain")
	save.tooltip_text = "保存当前地图（Ctrl+S）"
	bar.add_child(save)
	bar.add_child(app.UiKitScript.spacer())

	# —— 右侧：项目页入口 + 试玩 ——
	var proj: Button = app.UiKitScript.button("▣  项目", func(): app._set_mode("asset"), "ghost")
	proj.tooltip_text = "项目工作台：实体资产 / 内容库 / 清单（Esc 返回）"
	bar.add_child(proj)
	var cfg: Button = app.UiKitScript.button("试玩配置", app._open_play_cfg, "ghost")
	cfg.tooltip_text = "每图初始能力 / 血量"
	bar.add_child(cfg)
	var play = app.UiKitScript.button("▶  试玩", app._on_play, "primary")
	play.tooltip_text = "保存并启动游戏（当前地图）"
	bar.add_child(play)
	return panel_wrap

## 画布工具条（R3）：工具互斥 + 上下文条（随层随工具变化）+ 常驻编辑键。
## 上下文条的意义：碰撞类型/形状只在碰撞层有意义，笔刷尺寸只对涂刷/擦除/矩形有效——
## 平铺在顶栏时一半按钮长期无效，用户每次都要先辨认哪个能点。
func _build_canvas_toolbar() -> PanelContainer:
	var wrap := PanelContainer.new()
	var sb = app.UiThemeScript.box(app.UiThemeScript.BG_PANEL, app.UiThemeScript.BORDER, 0, 10, 5)
	sb.set_border_width_all(0)
	sb.border_width_bottom = 1
	wrap.add_theme_stylebox_override("panel", sb)
	var v: VBoxContainer = app.UiKitScript.vbox(4)
	wrap.add_child(v)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)
	# 工具条一行会随窗口变窄而挤爆布局（按钮有文字最小宽），HBox 溢出会把右侧检查器
	# 推出屏幕外。包一层横向滚动：宽度不够时横向滚，而不是撑开整行。
	# EXPAND 让 bar 在滚动容器里仍吃满可视宽度（否则 spacer 失效、右侧动作挤到左边）。
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var bar_scroll := ScrollContainer.new()
	bar_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	bar_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	bar_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar_scroll.custom_minimum_size = Vector2(0, 32)
	v.add_child(bar_scroll)
	bar_scroll.add_child(bar)
	bar.add_child(_build_tool_group())
	bar.add_child(app.UiKitScript.vdivider())
	# —— 常驻编辑组：剪切 / 复制 / 粘贴（Ctrl+X/C/V 的按钮形态） ——
	# 分组只用竖线表达：写「编辑 / 地图」这类文字标签会占掉一行宽度，
	# 抽屉打开时把右侧文件动作挤出可视区（已实证，故不加标签也不加额外空隙）。
	app._cut_btn = app.UiKitScript.button("剪切", func(): app._cut(), "ghost")
	app._cut_btn.tooltip_text = "剪切选中实体或框选区域（Ctrl+X）"
	bar.add_child(app._cut_btn)
	app._copy_btn = app.UiKitScript.button("复制", func(): app._copy(), "ghost")
	app._copy_btn.tooltip_text = "复制选中实体或框选区域（Ctrl+C）"
	bar.add_child(app._copy_btn)
	app._paste_btn = app.UiKitScript.button("粘贴", func(): app._paste(), "ghost")
	app._paste_btn.tooltip_text = "粘贴到光标处（Ctrl+V）"
	bar.add_child(app._paste_btn)
	bar.add_child(app.UiKitScript.spacer())
	# 地图级低频动作（导出 / 尺寸 / 背景组）收进一个下拉：
	# 三个平铺按钮在抽屉打开时（中列只剩 ~468px）会被挤出可视区，且没有溢出提示。
	# 展开后菜单自带文字，不再牺牲可发现性。
	var map_btn: Button = app.UiKitScript.button("地图 ▾", Callable(), "ghost")
	map_btn.tooltip_text = "导出当前地图 / 调整尺寸 / 选择背景图组"
	bar.add_child(map_btn)
	var map_menu := PopupMenu.new()
	map_menu.add_item("导出当前地图", 1)
	map_menu.add_item("调整地图尺寸", 2)
	map_menu.add_item("选择背景图组", 3)
	map_menu.id_pressed.connect(_on_map_menu_id)
	map_btn.pressed.connect(func(): _popup_below(map_menu, map_btn))
	bar.add_child(map_menu)

	# —— 上下文条：内容由 _refresh_context_bar 按「图层类型 + 工具」重建 ——
	_context_bar = HBoxContainer.new()
	_context_bar.add_theme_constant_override("separation", 6)
	v.add_child(_context_bar)
	return wrap

## 地图下拉：id 按 1/2/3 分派到三个原有弹窗入口
func _on_map_menu_id(id: int) -> void:
	match id:
		1:
			app._open_export_dialog()
		2:
			app._open_size_dialog()
		3:
			app._open_bg_dialog()

## 在锚点控件正下方弹菜单（宽高交给引擎按内容测算）
func _popup_below(pm: PopupMenu, anchor: Control) -> void:
	var at := Vector2i(anchor.get_screen_position()) + Vector2i(0, int(anchor.size.y))
	pm.popup(Rect2i(at, Vector2i.ZERO))

## 上下文条重建：只看状态，不自己存状态（真实状态在 canvas 上）
func _refresh_context_bar() -> void:
	if _context_bar == null:
		return
	for c in _context_bar.get_children():
		_context_bar.remove_child(c)
		c.queue_free()
	var show_brush: bool = app.canvas.tool in ["paint", "erase", "rect"]
	var on_collision := _layer_type_of(app.canvas.active_layer) == "grid"
	# 笔刷尺寸：只对涂刷/擦除/矩形有意义
	if show_brush:
		_context_bar.add_child(app.UiKitScript.text_label("笔刷",
			app.UiThemeScript.TEXT_MUTE, app.UiThemeScript.FS_META))
		app.brush_opt = OptionButton.new()
		app.brush_opt.tooltip_text = "笔刷尺寸"
		for s in ["1×1", "2×2", "3×3", "4×4", "6×6"]:
			app.brush_opt.add_item(s)
		var idx: int = [1, 2, 3, 4, 6].find(app.canvas.brush_size)
		app.brush_opt.selected = maxi(idx, 0)
		app.brush_opt.item_selected.connect(func(i: int): app.canvas.brush_size = [1, 2, 3, 4, 6][i])
		_context_bar.add_child(app.brush_opt)
	# 碰撞类型/形状 + 对齐/生成碰撞：只在碰撞层（与「碰撞涂刷」语义绑定）
	if on_collision:
		_context_bar.add_child(app.UiKitScript.vdivider())
		app.collision_type_opt = OptionButton.new()
		for it in ["实心", "单向", "梯子", "危险"]:
			app.collision_type_opt.add_item(it)
		app.collision_type_opt.item_selected.connect(func(i: int):
			app.canvas.collision_type = ["solid", "one_way", "ladder", "hazard"][i])
		app.collision_type_opt.tooltip_text = "碰撞类型（碰撞层涂刷时生效）"
		_context_bar.add_child(app.collision_type_opt)
		app.collision_shape_opt = OptionButton.new()
		for it in ["矩形", "斜坡右高 r45", "斜坡左高 l45"]:
			app.collision_shape_opt.add_item(it)
		app.collision_shape_opt.item_selected.connect(func(i: int):
			app.canvas.collision_shape = ["", "r45", "l45"][i])
		app.collision_shape_opt.tooltip_text = "碰撞形状（斜坡朝向）"
		_context_bar.add_child(app.collision_shape_opt)
		var gen: Button = app.UiKitScript.button("生成碰撞", app._open_collision_gen, "ghost")
		gen.tooltip_text = "按当前地形自动生成碰撞"
		_context_bar.add_child(gen)
		var align: Button = app.UiKitScript.button("对齐", app._open_align_menu, "ghost")
		align.tooltip_text = "按网格/相邻格对齐（Ctrl+L）"
		_context_bar.add_child(align)
	if _context_bar.get_child_count() == 0:
		_context_bar.add_child(app.UiKitScript.text_label("当前层无额外选项",
			app.UiThemeScript.TEXT_MUTE, app.UiThemeScript.FS_META))

## 图层类型小工具（editor_layout 自用，避免依赖 app 的私有方法）
func _layer_type_of(i: int) -> String:
	var layers: Array = app.manifest.get("layers", [])
	if i < 0 or i >= layers.size():
		return "entities"
	return str((layers[i] as Dictionary).get("type", "tiles"))


## 工具按钮组：互斥切换，选中态由 ToolButton 变体表达
## 含「盖章」——实体层的主要操作，没有按钮时点资产后会出现「没有任何工具高亮」。

func _build_tool_group() -> HBoxContainer:
	var h = app.UiKitScript.hbox(2)
	app.tool_group = ButtonGroup.new()
	var keys := {"paint": "1", "erase": "2", "rect": "3", "stamp": "4", "select": "5", "spawn": "6"}
	var next := 1
	for t in [["涂刷", "paint"], ["擦除", "erase"], ["矩形", "rect"],
			["盖章", "stamp"], ["属性", "select"], ["出生点", "spawn"]]:
		var name := str(t[1])
		var b = app.UiKitScript.button(str(t[0]), func(): app._set_tool(name), "tool")
		b.tooltip_text = "%s（%s）" % [str(t[0]), str(keys.get(name, str(next)))]
		b.button_group = app.tool_group
		if name == "paint":
			b.button_pressed = true
		app.tool_buttons[name] = b
		h.add_child(b)
		next += 1
	return h

## 左侧资产栏：两组调色板各自撑半高，中间用细线分段

var _palette_col: PanelContainer

func _build_palette_column() -> PanelContainer:
	var col := PanelContainer.new()
	col.custom_minimum_size = Vector2(252, 0)
	_palette_col = col
	var sb = app.UiThemeScript.box(app.UiThemeScript.BG_PANEL, app.UiThemeScript.BORDER, 0, 10, 10)
	sb.set_border_width_all(0)
	sb.border_width_right = 1
	col.add_theme_stylebox_override("panel", sb)

	var v = app.UiKitScript.vbox(8)
	col.add_child(v)

	# 调色板一次只显示一套：瓦片和实体平分高度会让两边都只剩两行，
	# 名称全被省略号截断。改成页签切换，当前这套独占全部可用高度。
	var seg = app.UiKitScript.hbox(4)
	app._pal_tile_btn = app.UiKitScript.button("地形瓦片", func(): _set_palette_page("tiles"), "toggle")
	app._pal_ent_btn = app.UiKitScript.button("实体", func(): _set_palette_page("entities"), "toggle")
	for b in [app._pal_tile_btn, app._pal_ent_btn]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		seg.add_child(b)
	app._pal_tile_btn.button_pressed = true
	v.add_child(seg)

	# A1.3 图层面板：这一列是显隐/锁定的唯一操作面（R3 单点真相）。
	# 当前层用 ACCENT 底高亮；行内 👁/🔒 是开关；顶栏那对 ●/○ 已删除（唯一一套符号）。
	var lp = app.UiKitScript.vbox(2)
	var lp_head = app.UiKitScript.hbox(4)
	lp_head.add_child(app.UiKitScript.section_label("图层"))
	lp_head.add_child(app.UiKitScript.spacer())
	var lp_body = VBoxContainer.new()
	app._layer_panel_body = lp_body
	var lp_collapse = app.UiKitScript.button("▾", func(): lp_body.visible = not lp_body.visible, "ghost")
	lp_collapse.tooltip_text = "展开 / 收起图层列表"
	lp_head.add_child(lp_collapse)
	lp.add_child(lp_head)
	lp.add_child(lp_body)
	v.add_child(lp)

	var holder := Control.new()
	# 调色板吃掉剩余高度（属性区已迁右栏）
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(holder)
	var full := func(c: Control) -> void:
		c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	app.tile_list = ItemList.new()
	app.tile_list.icon_mode = ItemList.ICON_MODE_TOP
	app.tile_list.fixed_icon_size = Vector2i(40, 40)
	app.tile_list.max_columns = 4
	app.tile_list.same_column_width = true
	app.tile_list.allow_reselect = true
	app.tile_list.fixed_column_width = 68
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

	# 属性面板迁到右栏检查器（R2）：左栏只管「给画布喂什么」（图层 + 调色板），
	# 三个控制器仍在这里建，供 app 的委托调用不变。
	app._props_panel_ctrl = preload("res://src/ui/props_panel.gd").new(app)
	app._picker_ctrl = preload("res://src/ui/cross_map_picker.gd").new(app)
	app._map_file_ctrl = preload("res://src/ui/map_file.gd").new(app)
	app._editor_state_ctrl = preload("res://src/core/editor_state.gd").new(app)
	app.props_panel = VBoxContainer.new()
	app.props_panel.add_theme_constant_override("separation", 6)
	app.props_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	app.props_scroll = ScrollContainer.new()
	app.props_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	app.props_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	app.props_scroll.add_child(app.props_panel)
	return col

## 左侧调色板页签切换（tiles / entities）

func _set_palette_page(which: String) -> void:
	if app.tile_list:
		app.tile_list.visible = which == "tiles"
	if app.ent_list:
		app.ent_list.visible = which == "entities"
	if app._pal_tile_btn:
		app._pal_tile_btn.button_pressed = which == "tiles"
	if app._pal_ent_btn:
		app._pal_ent_btn.button_pressed = which == "entities"

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

	# 视图开关：常驻在状态栏右侧，看一眼就知道网格/碰撞显示开着没
	_grid_btn = app.UiKitScript.button("网格", app._toggle_grid, "toggle")
	_grid_btn.tooltip_text = "显示 / 隐藏网格"
	_grid_btn.button_pressed = true
	h.add_child(_grid_btn)
	# 背景图组预览的显隐开关（P0：此前建了但没 add_child，按钮不可达）
	_bg_btn = app.UiKitScript.button("背景", app._toggle_bg, "toggle")
	_bg_btn.tooltip_text = "显示 / 隐藏背景图组"
	h.add_child(_bg_btn)

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
	# R4：快捷键速查入口常驻状态栏（? 键同效）——功能存在但没人知道等于不存在
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
		# PF-01：拖刷每格都会 modified——大纲全量重建按 250ms 防抖合并，连刷期间只建一次
		if _outline_timer == null:
			_outline_timer = app.get_tree().create_timer(0.25)
			_outline_timer.timeout.connect(func():
				_outline_timer = null
				app._refresh_entity_outline())

## 脏标记徽章：未保存时在状态栏常驻亮起

func _refresh_dirty_badge() -> void:
	if _dirty_badge:
		_dirty_badge.visible = app.map_loaded and app.canvas != null and app.canvas.modified_flag

## 当前工具/笔刷指示

func _refresh_tool_meta() -> void:
	if _meta_tool == null:
		return
	var names := {"paint": "涂刷", "erase": "擦除", "rect": "矩形", "stamp": "盖章", "select": "属性", "spawn": "出生点"}
	_meta_tool.text = "%s · %d×%d" % [names.get(app.canvas.tool, app.canvas.tool), app.canvas.brush_size, app.canvas.brush_size]



func _refresh_view_toggles() -> void:
	if _grid_btn:
		_grid_btn.button_pressed = app.canvas.show_grid
	if _bg_btn:
		_bg_btn.button_pressed = app.canvas != null and app.canvas.bg_visible
	_refresh_layer_panel()
	_refresh_context_bar()

## A1.3 图层面板（R3 单点真相）：每层一行 = 切层按钮 + 👁 + 🔒；
## 当前层用 ACCENT 底 + 亮字高亮，一眼看出「现在在画哪一层」。
## 载图/换图/切层后由 _refresh_view_toggles 链刷新。
func _refresh_layer_panel() -> void:
	if app._layer_panel_body == null:
		return
	for c in app._layer_panel_body.get_children():
		app._layer_panel_body.remove_child(c)
		c.queue_free()
	var layers: Array = app.manifest.get("layers", [])
	for i in layers.size() + 1:
		var is_ent := i == layers.size()
		var lname := "实体" if is_ent else str((layers[i] as Dictionary).get("name", (layers[i] as Dictionary).get("id", "?")))
		var is_cur: bool = i == app.canvas.active_layer
		var row = app.UiKitScript.hbox(2)
		var sel_btn = app.UiKitScript.button(lname, func(): app._apply_state("", i), "ghost")
		sel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sel_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		sel_btn.add_theme_font_size_override("font_size", app.UiThemeScript.FS_SMALL)
		if is_cur:
			# 当前层：底色 + 亮字（按钮变体只管形状，语义色在这里叠）
			var sb = app.UiThemeScript.box(app.UiThemeScript.ACCENT_BG,
				app.UiThemeScript.ACCENT, app.UiThemeScript.R_INNER, 4, 4)
			sel_btn.add_theme_stylebox_override("normal", sb)
			sel_btn.add_theme_color_override("font_color", app.UiThemeScript.TEXT)
		row.add_child(sel_btn)
		var vis_btn = app.UiKitScript.button("👁" if app.canvas.is_layer_visible(i) else "·", func():
			app.canvas.set_layer_hidden(i, app.canvas.is_layer_visible(i))
			_refresh_layer_panel(), "ghost")
		vis_btn.tooltip_text = "显示 / 隐藏本层（👁 显示中 · · 已隐藏）"
		row.add_child(vis_btn)
		var lock_btn = app.UiKitScript.button("🔒" if app.canvas.is_layer_locked(i) else "·", func():
			app.canvas.set_layer_locked(i, not app.canvas.is_layer_locked(i))
			_refresh_layer_panel(), "ghost")
		lock_btn.tooltip_text = "锁定 / 解锁本层（🔒 已锁定 · · 可编辑）"
		row.add_child(lock_btn)
		app._layer_panel_body.add_child(row)

## 剪切 / 复制 / 粘贴：按当前图层分发到实体或区域，
## 和画布快捷键（Ctrl+X/C/V）走同一套画布方法，避免两处行为分叉。

## R3：顶栏的图层 ●/○ 按钮已删除，图层面板是显隐/锁定的唯一操作面。
## 保留空实现供既有调用点（editor_state._sync_ui）使用，内部只同步图层面板。
func _sync_layer_buttons() -> void:
	_refresh_layer_panel()

func _build_theme() -> void:
	app.theme = app.UiThemeScript.build()


func _btn(t: String, cb: Callable) -> Button:
	return app.UiKitScript.button(t, cb, "plain")


func _label(t: String) -> Label:
	return app.UiKitScript.text_label(t, app.UiThemeScript.TEXT_DIM, app.UiThemeScript.FS_BASE)

## 原地切换徽章状态（继承 → 覆盖）

func _set_badge(p: PanelContainer, text: String, color: Color) -> void:
	app.UiKitScript.set_badge(p, text, color)

## 统一的弹窗挂载：挂到窗口根（不再挂进资产栏，避免被布局裁切与节点泄漏），
## 居中显示，关闭后自动释放。所有弹窗面板都必须走这里。

func _open_popup(pop: PopupPanel, size := Vector2i.ZERO) -> void:
	app.add_child(pop)
	pop.popup_hide.connect(func(): pop.queue_free())
	# 先按内容算出最小尺寸（此刻子控件还没排版，直接量会偏小），
	# 再用 popup_centered() 让引擎按最小尺寸开窗——不带参数的 popup_centered()
	# 会沿用上次窗口大小，必须显式给尺寸。
	# C6 回退（批次 12 修正）：单次居中量取不准会裁切内容——恢复两段式（先 1×1 弹出再按
	# 实际最小尺寸居中；首帧闪烁是小瑕疵，内容被裁是硬伤）。
	pop.popup_centered(Vector2i(1, 1))
	var want := pop.get_contents_minimum_size().ceil()
	var vp = app.get_viewport_rect().size
	want.x = minf(want.x, vp.x - 40)
	want.y = minf(want.y, vp.y - 40)
	if size != Vector2i.ZERO:
		want = Vector2(size)
	pop.popup_centered(Vector2i(want))

## 弹窗标准外壳：标题 + 副标题 + 内容区，保证所有面板视觉一致
## 内容列宽度固定（body_w），所有内部换行标签都以此为准，避免弹窗高度失控。

func _popup_body(title: String, subtitle := "") -> Dictionary:
	var pop := PopupPanel.new()
	var col = app.UiKitScript.vbox(10)
	col.custom_minimum_size = Vector2(app.POPUP_BODY_W, 0)
	pop.add_child(col)
	col.add_child(app.UiKitScript.text_label(title, app.UiThemeScript.TEXT, app.UiThemeScript.FS_MD))
	if subtitle != "":
		col.add_child(app.UiKitScript.hint_label(subtitle, app.POPUP_BODY_W))
	var body = app.UiKitScript.vbox(8)
	body.custom_minimum_size = Vector2(app.POPUP_BODY_W, 0)
	col.add_child(body)
	return {"pop": pop, "root": col, "body": body}

## R4：快捷键速查（? 键或状态栏入口）。罗列全部键盘入口，避免只能靠记忆和 tooltip 摸索。
func _open_shortcut_help() -> void:
	var shell: Dictionary = app._popup_body("快捷键速查", "画布编辑相关的全部键盘入口")
	var pop: PopupPanel = shell.pop
	var rows := [
		["文件", "Ctrl+S 保存地图 · Ctrl+N 新建 · Ctrl+O 打开"],
		["撤销", "Ctrl+Z 撤销 · Ctrl+Y / Ctrl+Shift+Z 重做"],
		["工具", "1 涂刷 · 2 擦除 · 3 矩形 · 4 盖章 · 5 属性 · 6 出生点"],
		["编辑", "Ctrl+X 剪切 · Ctrl+C 复制 · Ctrl+V 粘贴 · Ctrl+D 原位复制"],
		["实体", "Del 删除选中 · F 水平翻转 · 方向键 微调 1 格（Shift = 4 格）"],
		["选择", "Tab 循环选中实体 · Enter 打开内容抽屉"],
		["视图", "滚轮 缩放 · 中键/空格拖拽 平移 · Home 适应窗口 · = / - 缩放"],
		["生成", "Ctrl+L 对齐菜单"],
		["项目页", "Esc 返回画布 · Ctrl+S 保存当前视图 · ? 本速查"],
	]
	for r in rows:
		var line: HBoxContainer = app.UiKitScript.hbox(8)
		var k: Label = app.UiKitScript.text_label(str(r[0]), app.UiThemeScript.ACCENT_HI, app.UiThemeScript.FS_SMALL)
		k.custom_minimum_size = Vector2(56, 0)
		line.add_child(k)
		line.add_child(app.UiKitScript.wrap_label(str(r[1]), app.POPUP_BODY_W - 64))
		shell.body.add_child(line)
	shell.body.add_child(app.UiKitScript.hint_label(
		"输入框内（地图名、字段名、台词）不触发画布快捷键；Tab 在输入框里是补全/切换焦点。",
		app.POPUP_BODY_W))
	var close_btn: Button = app.UiKitScript.button("关闭", func(): pop.hide(), "primary")
	close_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	shell.body.add_child(close_btn)
	app._open_popup(pop)


func _build_project_view() -> void:
	app.project_shell = app.ProjectShellScript.new(app)
	app.project_shell.closed.connect(func(): app._set_mode("map"))
	app.project_shell.set_anchors_preset(Control.PRESET_FULL_RECT)
	app.project_shell.visible = false
	app.add_child(app.project_shell)
	app.project_shell.build()
	# 别名：三个视图面板的既有调用点（app.asset_panel / content_panel / manifest_panel）保持不变
	app.asset_panel = app.project_shell.asset_panel
	app.asset_view = app.asset_panel
	app.content_panel = app.project_shell.content_panel
	app.content_view = app.content_panel
	app.manifest_panel = app.project_shell.manifest_panel
	app.manifest_view = app.manifest_panel

## 清单写回：剥内部键（_开头 / tiles[].atlas_abs），写前 JSON 校验
