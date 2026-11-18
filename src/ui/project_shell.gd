extends VBoxContainer
## 项目工作台外壳（重构 R1）：资产 / 内容 / 清单三个全屏视图共用一个壳。
##
## 设计基线：资产 / 内容 / 清单统一进项目工作台（旧的三全屏模式取消）。
##   左上是固定的「← 返回画布」（Esc 同效），左列三个视图页签可横跳，
##   底栏状态消息常驻，Ctrl+S 按当前视图分派保存目标。
##
## 各视图只负责自己的内容区（原来是各自带顶栏的全屏界面，顶栏已收进本壳）。

signal closed

const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")
const AssetPanelScript := preload("res://src/ui/asset_panel.gd")
const ContentPanelScript := preload("res://src/ui/content_panel.gd")
const ContentEditorScript := preload("res://src/ui/content_editor.gd")
const ManifestPanelScript := preload("res://src/ui/manifest_panel.gd")
const LevelsPanelScript := preload("res://src/ui/levels_panel.gd")

## 侧列页签，顺序即展示顺序：[视图键, 显示名, 一句话说明]
const VIEWS := [
	["asset", "资产", "实体模板与数值"],
	["content", "内容", "对话/事件/商店/定义"],
	["manifest", "清单", "背景图组、物品、关卡与世界"],
]

var app   # 宿主 app
var manifest := {}
var save_manifest: Callable

var asset_panel = null
var content_panel = null
var content_editor = null
var manifest_panel = null
var levels_panel = null

var _view := "asset"
var _tabs := {}
var _holder: Control
var _title: Label
var _status: Label
var _manifest_scroll: ScrollContainer
## 内容视图专属的地图切换（v2 §3.2：地图是全局状态，在顶栏切）。
## 为什么不在关卡顶栏那个菜单上加：内容视图下整个 _map_view 隐藏，那个菜单根本点不到。
var _map_switch_btn: Button
var _map_switch_menu: PopupMenu
var _map_switch_box: Control

func _init(host) -> void:
	app = host
	manifest = host.manifest
	save_manifest = Callable(host, "_save_manifest_file")

func build() -> void:
	add_theme_constant_override("separation", 0)
	add_child(_build_top_bar())
	var body := Kit.hbox(0)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(body)
	body.add_child(_build_side_column())
	_holder = Control.new()
	_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(_holder)
	add_child(_build_status_bar())
	_build_views()

## 顶栏：返回 + 当前视图名 + 项目徽章 + 保存
func _build_top_bar() -> PanelContainer:
	var wrap := PanelContainer.new()
	var sb := Th.box(Th.BG_BASE, Th.BORDER, 0, 12, 8)
	sb.set_border_width_all(0)
	sb.border_width_bottom = 1
	wrap.add_theme_stylebox_override("panel", sb)
	var bar := Kit.hbox(10)
	wrap.add_child(bar)
	var back := Kit.button("←  返回画布", func(): close(), "ghost")
	back.tooltip_text = "回到关卡编辑（Esc 同效）"
	bar.add_child(back)
	bar.add_child(Kit.vdivider())
	_title = Kit.text_label("项目", Th.TEXT, Th.FS_LG)
	bar.add_child(_title)
	bar.add_child(Kit.badge(str(manifest.get("projectName", "?")), Th.ACCENT))
	bar.add_child(Kit.spacer())
	# 地图切换（仅内容视图显示）：未填徽章挂在每个地图项上，与左列同口径
	bar.add_child(_build_map_switch())
	var save := Kit.button("保存", func(): save_current(), "primary")
	save.tooltip_text = "保存当前视图对应的数据（Ctrl+S）"
	bar.add_child(save)
	return wrap

## 顶栏地图切换：内容视图下唯一的地图入口（关卡编辑器用画布顶栏那个菜单）。
## 不用 editor_layout 的菜单：内容视图下整个 _map_view 隐藏，那个按钮点不到。
func _build_map_switch() -> Control:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	_map_switch_btn = Kit.button("地图 ▾", Callable(), "ghost")
	_map_switch_btn.tooltip_text = "切换当前地图（每个地图名后跟未填数）"
	_map_switch_menu = PopupMenu.new()
	_map_switch_menu.id_pressed.connect(_on_map_switch_id)
	_map_switch_btn.pressed.connect(func():
		_refresh_map_switch()
		var at := Vector2i(_map_switch_btn.get_screen_position()) + Vector2i(0, int(_map_switch_btn.size.y))
		_map_switch_menu.popup(Rect2i(at, Vector2i.ZERO)))
	box.add_child(_map_switch_btn)
	box.add_child(_map_switch_menu)
	box.visible = false
	_map_switch_box = box
	return box

## 地图项文字：`名字 · n 未填`；当前地图打勾。内容视图每次进入都重建一次。
func _refresh_map_switch() -> void:
	if _map_switch_menu == null or content_editor == null:
		return
	_map_switch_menu.clear()
	var entries: Array = content_editor.map_menu_entries()
	if entries.is_empty():
		_map_switch_menu.add_item("（还没有地图）")
		_map_switch_menu.set_item_disabled(0, true)
		return
	var cur := str(app.cur_map_name)
	var n := 0
	for row in entries:
		var nm := str(row.name)
		var todo := int(row.todo)
		_map_switch_menu.add_item(nm + (("  ·  %d 未填" % todo) if todo > 0 else ""), n)
		if nm == cur:
			_map_switch_menu.set_item_as_checkable(n, true)
			_map_switch_menu.set_item_checked(n, true)
		n += 1
	_map_switch_btn.text = ("%s ▾" % cur) if cur != "" else "地图 ▾"

func _on_map_switch_id(id: int) -> void:
	if content_editor == null:
		return
	var entries: Array = content_editor.map_menu_entries()
	if id < 0 or id >= entries.size():
		return
	var nm := str(entries[id].name)
	if nm == str(app.cur_map_name):
		return
	# 切图会连带丢弃未保存改动，确认框由 _open_map_by_name 内部处理
	app._open_map_by_name(nm)
	show_view("content")

## 侧列：三个视图页签竖排，当前视图高亮
func _build_side_column() -> PanelContainer:
	var col := PanelContainer.new()
	col.custom_minimum_size = Vector2(132, 0)
	var sb := Th.box(Th.BG_PANEL, Th.BORDER, 0, 8, 10)
	sb.set_border_width_all(0)
	sb.border_width_right = 1
	col.add_theme_stylebox_override("panel", sb)
	var v := Kit.vbox(4)
	col.add_child(v)
	v.add_child(Kit.section_label("项目视图"))
	for spec in VIEWS:
		var key := str(spec[0])
		var btn := Kit.button(str(spec[1]), func(): show_view(key), "toggle")
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.tooltip_text = str(spec[2])
		_tabs[key] = btn
		v.add_child(btn)
	v.add_child(Kit.spacer())
	return col

## 底栏：消息常驻（左侧）+ 当前视图（右侧），与画布状态栏同一套视觉
func _build_status_bar() -> PanelContainer:
	var wrap := PanelContainer.new()
	var sb := Th.box(Th.BG_BASE, Th.BORDER, 0, 12, 5)
	sb.set_border_width_all(0)
	sb.border_width_top = 1
	wrap.add_theme_stylebox_override("panel", sb)
	var h := Kit.hbox(10)
	wrap.add_child(h)
	_status = Kit.text_label("就绪", Th.TEXT_DIM, Th.FS_SMALL)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	h.add_child(_status)
	return wrap

func _build_views() -> void:
	asset_panel = AssetPanelScript.new()
	asset_panel.manifest = manifest
	asset_panel.save_manifest = save_manifest
	asset_panel.host = app
	asset_panel.closed.connect(func(): close())
	_holder.add_child(asset_panel)
	asset_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	asset_panel.build()

	content_panel = ContentPanelScript.new()
	content_panel.manifest = manifest
	content_panel.app = app
	content_panel.closed.connect(func(): close())
	# 批次 C：内容视图换用新内容编辑器；旧 content_panel 保留文件、保留构建（既有调用点
	# app.content_panel / show_kind 仍能安全调用），但不再挂进 _holder 的可见位。
	# 挂到 _holder 并隐藏：脱离树的 Node 永不释放（孤儿），隐藏节点不绘制也不吃输入。
	content_panel.build()
	_holder.add_child(content_panel)
	content_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content_panel.visible = false
	content_editor = ContentEditorScript.new(app)
	var editor_root: Control = content_editor.build()
	_holder.add_child(editor_root)
	editor_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	manifest_panel = ManifestPanelScript.new()
	manifest_panel.manifest = manifest
	manifest_panel.save_manifest = save_manifest
	manifest_panel.host = app
	manifest_panel.closed.connect(func(): close())

	levels_panel = LevelsPanelScript.new()
	levels_panel.manifest_ref = manifest
	levels_panel.level_open_requested.connect(func(nm: String): close(); app._open_map_by_name(nm))
	levels_panel.levels_changed.connect(func(d: Dictionary): app._save_levels(d))
	levels_panel.world_refresh_requested.connect(func(): app._refresh_world())

	# 「清单」视图 = 上段清单管理 + 下段关卡与世界，共用一条滚动（P0-3 图层多时不被裁）
	_manifest_scroll = ScrollContainer.new()
	_manifest_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_holder.add_child(_manifest_scroll)
	_manifest_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var m_margin := MarginContainer.new()
	m_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	m_margin.add_theme_constant_override("margin_left", 16)
	m_margin.add_theme_constant_override("margin_right", 16)
	m_margin.add_theme_constant_override("margin_top", 12)
	m_margin.add_theme_constant_override("margin_bottom", 24)
	_manifest_scroll.add_child(m_margin)
	var m_col := Kit.vbox(14)
	m_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	m_margin.add_child(m_col)
	m_col.add_child(manifest_panel)
	m_col.add_child(Kit.divider())
	m_col.add_child(levels_panel)
	manifest_panel.build()
	levels_panel.build()

## 切视图（可横跳）。focus 用于资产/内容定位到某条资源
func show_view(view: String, focus := "") -> void:
	_view = view
	for spec in VIEWS:
		var key := str(spec[0])
		if _tabs.has(key):
			(_tabs[key] as Button).button_pressed = key == view
	asset_panel.visible = view == "asset"
	content_editor.root.visible = view == "content"
	_manifest_scroll.visible = view == "manifest"
	_map_switch_box.visible = view == "content"
	_title.text = "项目 · %s" % _label_of(view)
	match view:
		"asset":
			if focus == "":
				asset_panel.show_quick()
			else:
				asset_panel.show_detail(focus)
			_set_status("资产模板改动后点「保存」写回清单，下次试玩生效")
		"content":
			# focus 语义在此视图 = 实例 id（右栏定位），空则保留上次选中
			content_editor.refresh_list(focus)
			_refresh_map_switch()
			_set_status("点实例挂功能、填内容；改动即时写盘（Esc 回关卡编辑器）")
		"manifest":
			manifest_panel.refresh()
			# 关卡/世界与清单同一刷新链：进入视图时同步一次（图被改名/删除后清单要跟上）
			var levels = app.LevelList.load_levels(manifest)
			levels_panel.set_levels(levels, manifest)
			app._refresh_world()
			_set_status("清单改动点「保存」写回 editor_manifest.json；关卡清单单独保存")

func _label_of(view: String) -> String:
	for spec in VIEWS:
		if str(spec[0]) == view:
			return str(spec[1])
	return "项目"

## Ctrl+S / 顶栏保存：按当前视图分派——资产与清单写清单文件，内容写当前资源
func save_current() -> void:
	match _view:
		"content":
			# 新内容编辑器改动即时写盘，commit 只回报成功与否（旧面板不参与）
			content_editor.commit()
			_set_status("内容已保存（改动即时写盘）")
		"manifest":
			save_manifest.call()
			_set_status("清单已保存（背景图组 / 物品）")
		_:
			save_manifest.call()
			_set_status("资产清单已保存")

func close() -> void:
	closed.emit()

func _set_status(msg: String) -> void:
	if _status != null:
		_status.text = msg.strip_edges()
