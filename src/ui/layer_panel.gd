extends RefCounted
## LayerPanel：层下拉 + 层管理弹窗（从 editor_layout.gd 拆出，宿主 = editor_layout）


var host   # editor_layout 宿主
var app    # 根应用（= host.app）

func _init(h) -> void:
	host = h
	app = h.app

## 同名转发属性（读写穿透到宿主，搬动文本零改动）
var _layer_btn:
	get: return host._layer_btn
	set(v): host._layer_btn = v
var _layer_menu:
	get: return host._layer_menu
	set(v): host._layer_menu = v
var _layer_menu_body:
	get: return host._layer_menu_body
	set(v): host._layer_menu_body = v
var _layer_mgr:
	get: return host._layer_mgr
	set(v): host._layer_mgr = v
var _layer_mgr_body:
	get: return host._layer_mgr_body
	set(v): host._layer_mgr_body = v
var _layer_mgr_rows:
	get: return host._layer_mgr_rows
	set(v): host._layer_mgr_rows = v
var _layer_mgr_input:
	get: return host._layer_mgr_input
	set(v): host._layer_mgr_input = v

## 同名包装方法（真实实现经 host 转发）
func _open_popup(pop: PopupPanel, size := Vector2i.ZERO) -> void:
	host._open_popup(pop, size)
func _popup_body(title: String, subtitle := "") -> Dictionary:
	return host._popup_body(title, subtitle)
func _set_status(msg: String) -> void:
	host._set_status(msg)

## 层下拉 + 内联显隐/锁定。当前层用 ACCENT 底标出；
## 按钮文字同步成当前层名，这样「现在画哪一层」在左栏一眼可见，不用展开菜单。
func _refresh_layer_panel() -> void:
	if _layer_btn == null:
		return
	_layer_btn.text = "层：%s  ▾" % app._layer_label(app.canvas.active_layer)
	if _layer_menu_body == null:
		return
	for c in _layer_menu_body.get_children():
		_layer_menu_body.remove_child(c)
		c.queue_free()
	# 层数 = 地图 meta.layers 层栈 + 碰撞元层（下拉最后，名字走 app._layer_label）
	for i in app.canvas.layer_count() + 1:
		var lname: String = app._layer_label(i)
		var is_cur: bool = i == app.canvas.active_layer
		var row = app.UiKitScript.hbox(2)
		var sel_btn = app.UiKitScript.button(lname, func():
			_layer_menu.hide()
			app._on_layer(i), "ghost")
		sel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sel_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		sel_btn.add_theme_font_size_override("font_size", app.UiThemeScript.FS_SMALL)
		if is_cur:
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
		_layer_menu_body.add_child(row)

## 展开层下拉：定位在按钮正下方
func _toggle_layer_menu() -> void:
	if _layer_menu == null:
		return
	if _layer_menu.visible:
		_layer_menu.hide()
		return
	_refresh_layer_panel()
	var at: Vector2 = _layer_btn.get_screen_position()
	_layer_menu.position = Vector2i(at) + Vector2i(0, int(_layer_btn.size.y))
	_layer_menu.popup()

## 层管理弹窗：每层一行（改名 / 运行时可见 / ↑↓ / 删除），底部新建层。
## 行操作走画布 layer_* API；meta.layers 同步更新，弹窗内容直接读它重填
## （画布 load_data 重建是异步的，不阻塞弹窗刷新）。碰撞元层不是栈层，不进列表。
func _open_layer_manager() -> void:
	var shell: Dictionary = app._popup_body("图层管理",
		"新建 / 改名（回车提交）/ 上下排序 / 删除；「运行时」= 游戏开局该层是否显示")
	_layer_mgr = shell.pop
	_layer_mgr_body = shell.body
	_layer_mgr_rows = app.UiKitScript.vbox(2)
	_layer_mgr_body.add_child(_layer_mgr_rows)
	var row = app.UiKitScript.hbox(6)
	var input := LineEdit.new()
	input.placeholder_text = "新层名"
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_layer_mgr_input = input
	row.add_child(input)
	row.add_child(app.UiKitScript.button("新建层", func():
		app.canvas.layer_add(_layer_mgr_input.text)
		_layer_mgr_input.clear()
		_rebuild_layer_mgr()
		app._sync_ui()), "primary")
	_layer_mgr_body.add_child(row)
	var close_btn: Button = app.UiKitScript.button("关闭", func(): _layer_mgr.hide(), "plain")
	close_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	_layer_mgr_body.add_child(close_btn)
	_rebuild_layer_mgr()
	app._open_popup(_layer_mgr)

## 重填层管理列表：读 meta.layers（layers_decl）直接重建，不依赖画布异步重建完成
func _rebuild_layer_mgr() -> void:
	if _layer_mgr == null or not is_instance_valid(_layer_mgr):
		return
	if _layer_mgr_rows == null or not is_instance_valid(_layer_mgr_rows):
		return
	for c in _layer_mgr_rows.get_children():
		_layer_mgr_rows.remove_child(c)
		c.queue_free()
	var decl: Array = app.canvas.layers_decl()
	if decl.is_empty():
		_layer_mgr_rows.add_child(app.UiKitScript.hint_label(
			"还没有图层——下方输入名字后点「新建层」。", app.POPUP_BODY_W))
		return
	for i in decl.size():
		_layer_mgr_rows.add_child(_layer_mgr_row(i, decl[i] as Dictionary))

## 一层一行：名字（行内改名，回车提交）+ 运行时可见 + ↑ ↓ 删除
func _layer_mgr_row(i: int, decl: Dictionary) -> Control:
	var row = app.UiKitScript.hbox(4)
	var nm := LineEdit.new()
	nm.text = str(decl.get("name", ""))
	nm.placeholder_text = str(decl.get("id", ""))
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm.tooltip_text = "层名（改成新名字后回车提交）"
	nm.text_submitted.connect(func(s: String):
		app.canvas.layer_rename(i, s)
		app._sync_ui())
	row.add_child(nm)
	var vis := CheckBox.new()
	vis.button_pressed = bool(decl.get("visible", true))
	vis.tooltip_text = "运行时初始可见（差分视图用）"
	vis.toggled.connect(func(on: bool):
		app.canvas.layer_set_visible(i, on)
		app._sync_ui())
	row.add_child(vis)
	var up = app.UiKitScript.button("↑", func():
		app.canvas.layer_move(i, -1)
		_rebuild_layer_mgr()
		app._sync_ui(), "ghost")
	up.disabled = i == 0
	up.tooltip_text = "上移一层"
	row.add_child(up)
	var down = app.UiKitScript.button("↓", func():
		app.canvas.layer_move(i, 1)
		_rebuild_layer_mgr()
		app._sync_ui(), "ghost")
	down.disabled = i >= app.canvas.layer_count() - 1
	down.tooltip_text = "下移一层"
	row.add_child(down)
	var del = app.UiKitScript.button("删除", func():
		var before: int = app.canvas.layer_count()
		app.canvas.layer_del(i)
		if app.canvas.layer_count() == before:
			app._set_status("至少保留一个图层")
		_rebuild_layer_mgr()
		app._sync_ui(), "ghost")
	del.tooltip_text = "删除该层（层上瓦片与实体一并删除）"
	row.add_child(del)
	return row

