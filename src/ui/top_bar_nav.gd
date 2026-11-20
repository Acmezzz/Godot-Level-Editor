extends HBoxContainer
## 共享顶栏片段：地图 ▾ + 三个模式按钮（关卡 / 内容 / 资产）。
## 关卡视图顶栏与项目页顶栏都嵌这一个对象——「为什么两处做得不一样」的答案就是
## 以前各建各的，现在这四样只有这一处实现。试玩 / 保存等各自顶栏的其它东西不在这里。
##
## 地图菜单每次弹出前用 MapStore.list_maps 重建：只列已有地图，点一个就切。
## 切图是协程，await 完成后触发 after_switch（无论是否真的切成功；项目页用它留在当前视图）。

const Kit := preload("res://src/ui/ui_kit.gd")

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
			"asset": "资产：资产图鉴与实例分布（Esc 返回）"}.get(mode, "")
		_mode_btns[mode] = btn
		add_child(btn)

func set_mode(mode: String) -> void:
	for k in _mode_btns.keys():
		var b := _mode_btns[k] as Button
		if b != null:
			b.button_pressed = (str(k) == mode)

func _on_mode(mode: String) -> void:
	app._set_mode(mode)

func _refresh_map_menu() -> void:
	_switch_menu.clear()
	var names: Array = app.MapStore.list_maps(app.manifest)
	if names.is_empty():
		_switch_menu.add_item("（还没有地图）")
		_switch_menu.set_item_disabled(0, true)
		return
	for i in names.size():
		var nm := str(names[i])
		_switch_menu.add_item(nm, i)
		if nm == app.cur_map_name:
			_switch_menu.set_item_as_checkable(i, true)
			_switch_menu.set_item_checked(i, true)

func _on_map_selected(id: int) -> void:
	var names: Array = app.MapStore.list_maps(app.manifest)
	if id < 0 or id >= names.size():
		return
	var nm := str(names[id])
	if nm == app.cur_map_name:
		return
	var p: String = EditorManifest.map_path(app.manifest, nm)
	if p == "" or not FileAccess.file_exists(p):
		app._set_status("地图不存在: " + nm)
		return
	# 切图是协程（可能有未保存确认弹窗）：必须等加载完成再回调宿主刷新，
	# 否则内容/资产页会在旧画布内容上刷新（列表与地图名对不上）。
	await app._open_map_by_name(nm)
	if after_switch.is_valid():
		after_switch.call()
