extends HBoxContainer
## 共享顶栏片段：地图 ▾ + 三个模式按钮（关卡 / 内容 / 资产）。
## 关卡视图顶栏与项目页顶栏都嵌这一个对象——「为什么两处做得不一样」的答案就是
## 以前各建各的，现在这四样只有这一处实现。试玩 / 保存等各自顶栏的其它东西不在这里。
##
## 地图菜单每次弹出前用 MapStore.list_maps 重建：只列已有地图，点一个就切。
## 切图是协程，await 完成后触发 after_switch（无论是否真的切成功；项目页用它留在当前视图）。

const Kit := preload("res://src/ui/ui_kit.gd")
const CellGraphEditor := preload("res://src/ui/cell_graph_editor.gd")
const References := preload("res://src/project/reference_index.gd")
const WorldEditor := preload("res://src/ui/world_layout_editor.gd")
const EventLayers := preload("res://src/project/event_layers.gd")
const EventLayerDialog := preload("res://src/ui/event_layers_dialog.gd")

var app
var after_switch: Callable   # 切图后宿主可选回调（项目页用它回到内容视图）

var _switch_btn: Button
var _switch_menu: PopupMenu
var _mode_btns := {}
var _mode_names := [["map", "关卡"], ["content", "内容"], ["asset", "资产"]]

func _init(host) -> void:
	app = host
	add_theme_constant_override("separation", 6)

func build() -> void:
	# —— 地图 ▾：只列已有地图，与「设置」分开 ——
	_switch_btn = Kit.button("地图 ▾", Callable(), "plain")
	_switch_btn.tooltip_text = "切换地图（只列已有地图文件）"
	_switch_btn.custom_minimum_size = Vector2(104, 0)
	add_child(_switch_btn)
	_switch_menu = PopupMenu.new()
	_switch_menu.id_pressed.connect(_on_map_selected)
	_switch_btn.pressed.connect(func():
		_refresh_map_menu()
		var at := Vector2i(_switch_btn.get_screen_position()) + Vector2i(0, int(_switch_btn.size.y))
		_switch_menu.popup(Rect2i(at, Vector2i.ZERO)))
	add_child(_switch_menu)

	for spec in _mode_names:
		var mode := str(spec[0])
		var btn: Button = Kit.button(str(spec[1]), _on_mode.bind(mode), "toggle")
		btn.tooltip_text = {"map": "关卡：摆放地图（Esc 返回）",
			"content": "内容：给实例挂功能、填内容（Esc 返回）",
			"asset": "资产：资产图鉴与功能挂载（Esc 返回）"}.get(mode, "")
		_mode_btns[mode] = btn
		add_child(btn)

func set_mode(mode: String) -> void:
	for k in _mode_btns.keys():
		var b := _mode_btns[k] as Button
		if b != null:
			b.button_pressed = (str(k) == mode)

func _on_mode(mode: String) -> void:
	app._set_mode(mode)

## 菜单按弹出时的地图码绑定，图名用于显示和打开还没有地图码的文件。
var _menu_binds: Array = []

func _refresh_map_menu() -> void:
	_switch_menu.clear()
	_menu_binds.clear()
	var names: Array = app.MapStore.list_maps(app.manifest)
	if names.is_empty():
		_switch_menu.add_item("（还没有地图）")
		_switch_menu.set_item_disabled(0, true)
	else:
		var codes: Dictionary = app.MapStore.name_to_code(app.manifest)
		for i in names.size():
			var nm := str(names[i])
			_switch_menu.add_item(nm, i)
			_menu_binds.append({"name": nm, "code": str(codes.get(nm, ""))})
			if nm == app.cur_map_name:
				_switch_menu.set_item_as_checkable(i, true)
				_switch_menu.set_item_checked(i, true)
	_switch_menu.add_separator()
	_switch_menu.add_item("编辑当前地图格图…", _MENU_CELL_GRAPH)
	_switch_menu.set_item_disabled(_switch_menu.item_count - 1, not app.map_loaded)
	_switch_menu.add_item("编辑项目世界布局…", _MENU_WORLD)
	if not EventLayers.types(app.manifest).is_empty() or not app.manifest.get(EventLayers.KEY, {}).is_empty():
		_switch_menu.add_item("图组事件层…", _MENU_EVENTS)
	# 草稿恢复入口（A3）：只列真正有草稿的地图码，避免菜单变成大杂烩
	var draft_keys: Array = preload("res://src/map/recovery.gd").list_drafts(app.manifest)
	if draft_keys.is_empty():
		return
	_switch_menu.add_separator()
	_switch_menu.add_item("恢复草稿…", _MENU_DRAFTS)

const _MENU_DRAFTS := 100000
const _MENU_CELL_GRAPH := 100001
const _MENU_WORLD := 100002
const _MENU_EVENTS := 100003

## 草稿列表弹窗：每份草稿给「恢复 / 查看正式图 / 丢弃」三个选择。
func _open_draft_picker() -> void:
	var rec := preload("res://src/map/recovery.gd")
	var keys: Array = rec.list_drafts(app.manifest)
	if keys.is_empty():
		app._set_status("没有可恢复的草稿")
		return
	var shell: Dictionary = app._popup_body("恢复草稿", "草稿在 editor/drafts/：恢复只改画布，Ctrl+S 才写回正式图。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	for k in keys:
		# 草稿文件名 = 草稿键（有地图码用码、否则图名）。按文件名直接读，
		# 不能拿空码 + 图名去重算路径——带码地图会算出另一种键，读不到自己的草稿（A3）。
		var key := str(k)
		var d: Dictionary = rec.read_draft_key(app.manifest, key)
		var row: HBoxContainer = app.UiKitScript.hbox(6)
		var label: Label = app.UiKitScript.text_label("%s  ·  %s" % [str(d.get("mapName", key)), key], app.UiThemeScript.TEXT, app.UiThemeScript.FS_SMALL)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		row.add_child(app.UiKitScript.button("恢复", func():
			pop.hide()
			draft_pick(key, "restore"), "primary"))
		row.add_child(app.UiKitScript.button("查看正式图", func():
			pop.hide()
			draft_pick(key, "open"), "ghost"))
		row.add_child(app.UiKitScript.button("丢弃", func():
			pop.hide()
			draft_pick(key, "discard"), "ghost"))
		body.add_child(row)
	app._open_popup(pop)

## 由弹窗按钮调用的实际动作入口（地图控制器负责载入/丢弃）。
## 参数是**草稿键**（文件名），不是图名：地图改名后图名会变，键仍指向同一份草稿。
func draft_pick(draft_key: String, action: String) -> void:
	if app._map_file_ctrl == null:
		return
	match action:
		"restore":
			await app._map_file_ctrl.restore_draft_key(draft_key)
		"open":
			await app._map_file_ctrl.open_draft_target(draft_key)
		"discard":
			var rec := preload("res://src/map/recovery.gd")
			rec.remove_draft_key(app.manifest, draft_key)
			app._set_status("已丢弃草稿：" + draft_key)
	if after_switch.is_valid():
		after_switch.call()

func _on_map_selected(id: int) -> void:
	if id == _MENU_EVENTS:
		EventLayerDialog.open(app)
		return
	if id == _MENU_WORLD:
		WorldEditor.open(app)
		return
	if id == _MENU_CELL_GRAPH:
		CellGraphEditor.open(app)
		return
	if id == _MENU_DRAFTS:
		_open_draft_picker()
		return
	if id < 0 or id >= _menu_binds.size():
		return
	var selected: Dictionary = _menu_binds[id]
	var name_: String = selected.name
	var code: String = selected.code
	if code != "":
		var resolved := References.resolve_map_code(app.MapStore.code_index(app.manifest), code)
		if resolved.status != "ok":
			app._set_status("无法按地图码打开：%s [%s]" % [name_, code])
			return
		name_ = resolved.key
	await app._open_map_by_name(name_)
	if after_switch.is_valid():
		after_switch.call()
