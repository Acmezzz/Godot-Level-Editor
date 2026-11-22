extends HBoxContainer
## 共享顶栏片段：地图 ▾ + 三个模式按钮（关卡 / 内容 / 资产）。
## 关卡视图顶栏与项目页顶栏都嵌这一个对象——「为什么两处做得不一样」的答案就是
## 以前各建各的，现在这四样只有这一处实现。试玩 / 保存等各自顶栏的其它东西不在这里。
##
## 地图菜单每次弹出前用 MapStore.list_maps 重建：只列已有地图，点一个就切。
## 切图是协程，await 完成后触发 after_switch（无论是否真的切成功；项目页用它留在当前视图）。

const Kit := preload("res://src/ui/ui_kit.gd")
const MapMenuIdentity := preload("res://src/ui/map_menu_identity.gd")

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

## E3：菜单项绑定弹出时的地图身份（图名 + 路径 + 地图码）。外部增删文件会让排序下标
## 指向另一张图——点击一律按绑定身份解析，不看当下数组下标。
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
			_menu_binds.append({"name": nm, "code": str(codes.get(nm, "")),
				"path": app.MapStore.path_for(app.manifest, nm)})
			if nm == app.cur_map_name:
				_switch_menu.set_item_as_checkable(i, true)
				_switch_menu.set_item_checked(i, true)
	# 草稿恢复入口（A3）：只列真正有草稿的地图码，避免菜单变成大杂烩
	var draft_keys: Array = preload("res://src/map/recovery.gd").list_drafts(app.manifest)
	if draft_keys.is_empty():
		return
	_switch_menu.add_separator()
	_switch_menu.add_item("恢复草稿…", _MENU_DRAFTS)

const _MENU_DRAFTS := 100000

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
	if id == _MENU_DRAFTS:
		_open_draft_picker()
		return
	# E3：按弹出时绑定的图名解析。点击时条目可能已失效（外部新增/改名/删除让排序下标漂移）。
	# 绑定的图名 + 地图码仍指向同一个文件才切；否则刷新菜单并报告失效，
	# 绝不按下标去读一份新的 list_maps。
	var at := id
	var nm := ""
	var p := ""
	if at >= 0 and at < _menu_binds.size():
		nm = str((_menu_binds[at] as Dictionary).get("name", ""))
		p = EditorManifest.map_path(app.manifest, nm)
	# 身份校验：文件还在但地图码变了 = 同一个名字现在指着另一张图（重新生成/替换过）
	var cur_code := ""
	if nm != "" and p != "" and FileAccess.file_exists(p):
		cur_code = str((app.MapStore.read(app.manifest, nm).get("meta", {}) as Dictionary).get("code", ""))
	var res: Dictionary = MapMenuIdentity.resolve(_menu_binds, at,
		p != "" and FileAccess.file_exists(p), cur_code, str(app.cur_map_name))
	match str(res.get("status", "")):
		MapMenuIdentity.STALE:
			_refresh_map_menu()
			app._set_status("地图菜单条目已失效，列表已刷新：请重新选择")
			return
		MapMenuIdentity.MISSING:
			_refresh_map_menu()
			app._set_status("地图条目已失效：%s 已不存在（列表已刷新）" % nm)
			return
		MapMenuIdentity.RECODE:
			_refresh_map_menu()
			app._set_status("地图条目已失效：%s 的地图码已变化（列表已刷新，请重新选择）" % nm)
			return
		MapMenuIdentity.SAME:
			return
	# 切图是协程（可能有未保存确认弹窗）：必须等加载完成再回调宿主刷新，
	# 否则内容/资产页会在旧画布内容上刷新（列表与地图名对不上）。
	await app._open_map_by_name(nm)
	if after_switch.is_valid():
		after_switch.call()
