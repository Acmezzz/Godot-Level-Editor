extends VBoxContainer
## 项目工作台外壳（重构 R1）：资产 / 内容两个全屏视图共用一个壳。
##
## 设计基线：资产 / 内容统一进项目工作台（旧的三全屏模式取消）。
##   右上角与画布顶栏同一套「关卡 / 内容 / 资产」模式切换（Esc 回画布），
##   底栏状态消息常驻，Ctrl+S 按当前视图分派保存目标。
##   没有左侧页签栏——切换全靠右上角三个模式按钮。
##   清单设置、背景图组、关卡清单与世界拓扑均已删除。
##
## 各视图只负责自己的内容区（原来是各自带顶栏的全屏界面，顶栏已收进本壳）。

const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")
const AssetPanelScript := preload("res://src/ui/asset_panel.gd")
const ContentEditorScript := preload("res://src/ui/content_editor.gd")

var app   # 宿主 app
var manifest := {}
var save_manifest: Callable

var asset_panel = null
var content_editor = null

var _view := "asset"
var _mode_btns := {}
var _holder: Control
var _title: Label
var _status: Label
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
	_holder = Control.new()
	_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_holder)
	add_child(_build_status_bar())
	_build_views()

## 顶栏：模式切换（关卡/内容/资产）+ 当前视图名 + 项目徽章 + 保存
func _build_top_bar() -> PanelContainer:
	var wrap := PanelContainer.new()
	var sb := Th.box(Th.BG_BASE, Th.BORDER, 0, 12, 8)
	sb.set_border_width_all(0)
	sb.border_width_bottom = 1
	wrap.add_theme_stylebox_override("panel", sb)
	var bar := Kit.hbox(10)
	wrap.add_child(bar)
	_title = Kit.text_label("项目", Th.TEXT, Th.FS_LG)
	bar.add_child(_title)
	bar.add_child(Kit.badge(str(manifest.get("projectName", "?")), Th.ACCENT))
	bar.add_child(Kit.spacer())
	# 地图切换（仅内容视图显示）：未填徽章挂在每个地图项上，与左列同口径
	bar.add_child(_build_map_switch())
	# 模式切换（关卡/内容/资产）：放右上角，紧挨保存
	for spec in [["map", "关卡"], ["content", "内容"], ["asset", "资产"]]:
		var mode := str(spec[0])
		var btn: Button = Kit.button(str(spec[1]), func(): app._set_mode(mode), "toggle")
		btn.tooltip_text = {"map": "回到关卡画布", "content": "给实例挂功能、填内容",
			"asset": "资产图鉴与实例分布"}.get(mode, "")
		_mode_btns[mode] = btn
		bar.add_child(btn)
	bar.add_child(Kit.vdivider())
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
	_holder.add_child(asset_panel)
	asset_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	asset_panel.build()

	content_editor = ContentEditorScript.new(app)
	var editor_root: Control = content_editor.build()
	_holder.add_child(editor_root)
	editor_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

## 切视图（可横跳）。focus 用于资产/内容定位到某条资源
func show_view(view: String, focus := "") -> void:
	_view = view
	# 顶栏模式切换：只有 map/content/asset 三个键，按下态与视图一一对应
	for k in _mode_btns.keys():
		(_mode_btns[k] as Button).button_pressed = str(k) == view
	asset_panel.visible = view == "asset"
	content_editor.root.visible = view == "content"
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

func _label_of(view: String) -> String:
	if view == "content":
		return "内容"
	if view == "asset":
		return "资产"
	return "项目"

## Ctrl+S / 顶栏保存：按当前视图分派保存目标
func save_current() -> void:
	match _view:
		"content":
			# 新内容编辑器改动即时写盘，commit 只回报成功与否
			content_editor.commit()
			_set_status("内容已保存（改动即时写盘）")
		_:
			save_manifest.call()
			_set_status("资产清单已保存")

func _set_status(msg: String) -> void:
	if _status != null:
		_status.text = msg.strip_edges()
