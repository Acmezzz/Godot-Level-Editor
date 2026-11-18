extends Control
## 独立关卡编辑器应用（Godot EXE）：
## 启动 → 读 user:// 上次项目 → 无则显示"打开项目文件夹"；
## 选定项目 = 读清单 → 顶栏/资产栏/画布/状态栏，全部由清单驱动。

const SettingsCfg := "user://settings.cfg"
const ProjectShellScript := preload("res://src/ui/project_shell.gd")
const SidePanelScript := preload("res://src/ui/side_panel.gd")
const UiThemeScript := preload("res://src/ui/ui_theme.gd")
const UiKitScript := preload("res://src/ui/ui_kit.gd")
const MapValidate := preload("res://src/map_validate.gd")
const MapStore := preload("res://src/map_store.gd")
const MapExport := preload("res://src/map_export.gd")
const LevelList := preload("res://src/level_list.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const ContentTemplates := preload("res://src/content/content_templates.gd")

var manifest := {}
var canvas: EditorCanvas
var cur_map_path := ""
var cur_map_name := ""
var tile_list: ItemList
var ent_list: ItemList
## 碰撞层专属左栏页（v2 §2.2）：碰撞类型/形状/自动生成——层决定左栏显示什么
var coll_page: VBoxContainer
var status: Label
## v2：工具概念已废除——画笔行为由层类型决定，笔刷尺寸/碰撞类型不再有 UI 入口，
## 这两个字段保留为画布状态的直写点（默认值即唯一值）。
var last_tiles_layer := 0       # 最近使用的瓦片层（选瓦片时切回它）
var _hover_list: ItemList = null  # 打开中的目标候选列表（悬停高亮轮询用）
var _hover_ids: Array = []
## 属性面板容器保留为「无界面的构建目标」：props_panel 的控制器仍要一个 VBox 来装配，
## 但它不上屏（v2 §7.1 删右栏检查器）。参数编辑走内容编辑器与资产目录。
var props_panel: VBoxContainer
var props_scroll: ScrollContainer
var _props_panel_ctrl   # ui/props_panel.gd 控制器
var _picker_ctrl   # ui/cross_map_picker.gd 控制器
var _map_file_ctrl   # ui/map_file.gd 控制器
var _editor_state_ctrl   # core/editor_state.gd 控制器（审查 8.2-4 状态流）
var _layout_ctrl   # ui/editor_layout.gd 控制器（审查 8.2-2 界面搭建）
var _side_actions_ctrl   # core/side_actions.gd 控制器（审查 8.2-5 侧栏联动）
var _palette_ctrl   # ui/palette_panel.gd 控制器（调色板两级导航）
var selected_spr: Sprite2D = null
var map_loaded := false          # 防呆：是否已载入地图
var map_name_edit: LineEdit
## 顶栏地图菜单锚点（v2 §2.4：地图名本身就是下拉按钮）
var _map_btn: Button
## 顶栏三个面板入口（关卡 / 内容 / 资产），_sync_panel_buttons 同步按下态
var _panel_btns := {}
# 画布空态引导（未打开地图时显示）
var _canvas_empty: Control

func _ready() -> void:
	_load_prefs()
	_layout_ctrl = preload("res://src/ui/editor_layout.gd").new(self)
	_side_actions_ctrl = preload("res://src/core/side_actions.gd").new(self)
	_palette_ctrl = preload("res://src/ui/palette_panel.gd").new(self)
	_build_theme()
	manifest = _load_last_project()
	get_tree().auto_accept_quit = false
	if manifest.is_empty() or manifest.has("_error"):
		_show_picker(manifest.get("_error", ""))
	else:
		_build_editor_ui()

## 关窗口前拦截：有未保存修改就确认，并把草稿落盘
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		call_deferred("_handle_close_request")

func _handle_close_request() -> void:
	if map_loaded and canvas and canvas.modified_flag:
		_maybe_autosave()
		if not await _confirm_discard("退出编辑器"):
			return
	get_tree().auto_accept_quit = true
	get_tree().quit()

# —— 上次项目记忆（user://settings.cfg） ——
func _load_last_project() -> Dictionary:
	var cf := ConfigFile.new()
	if cf.load(SettingsCfg) != OK:
		return {}
	var dir := str(cf.get_value("project", "dir", ""))
	if dir == "":
		return {}
	return EditorManifest.load_from(dir)

func _save_last_project(dir: String) -> void:
	var cf := ConfigFile.new()
	cf.set_value("project", "dir", dir)
	cf.save(SettingsCfg)

# —— 项目选择页 ——
func _show_picker(err := "") -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(v)
	var t := Label.new()
	t.text = "关卡编辑器"
	t.add_theme_font_size_override("font_size", 28)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var hint := Label.new()
	hint.text = "选择一个游戏项目文件夹（内含 editor/editor_manifest.json）"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(hint)
	if err != "":
		var el := Label.new()
		el.text = err
		el.modulate = Color(1, 0.4, 0.4)
		v.add_child(el)
	var btn := Button.new()
	btn.text = "打开项目文件夹…"
	btn.pressed.connect(_pick_project)
	var hb := HBoxContainer.new()
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	hb.add_child(btn)
	v.add_child(hb)

func _pick_project() -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.dir_selected.connect(_on_project_picked)
	add_child(fd)
	fd.popup_centered(Vector2i(700, 500))

# —— 项目选定：读清单 → 进编辑器界面 ——
func _on_project_picked(dir: String) -> void:
	var m := EditorManifest.load_from(dir)
	if m.has("_error"):
		_show_picker(m["_error"])
		return
	manifest = m
	_ent_thumbs_cache.clear()   # D1：换项目清缩略图缓存
	_save_last_project(dir)
	_build_editor_ui()

# —— 编辑器主界面 ——
# —— 顶栏：按语义分四组（文件 / 视图 / 工具 / 试玩），组间用细线分隔 ——
# —— 资产面板填充（拆到 ui/palette_panel.gd；调用点保持不变） ——
func _fill_palettes() -> void:
	_palette_ctrl.fill_all()

# —— 地图操作 ——
## 有未保存修改时先询问；返回 true 表示可以继续
## 地图文件生命周期（拆到 ui/map_file.gd，调用点保持不变）
func _confirm_discard(action: String) -> bool:
	return await _map_file_ctrl.confirm_discard(action)

func _confirm_action(title: String, text: String, ok_text := "确定") -> bool:
	return await _map_file_ctrl.confirm_action(title, text, ok_text)

func _load_map_file(p: String) -> void:
	_map_file_ctrl.load_map_file(p)

## 保存当前地图；返回是否成功（试玩前依赖它决定是否继续）
func _on_save() -> bool:
	return _map_file_ctrl.on_save()

func _on_new() -> void:
	_map_file_ctrl.on_new()

func _on_open() -> void:
	_map_file_ctrl.on_open()

func _maybe_autosave() -> void:
	_map_file_ctrl.maybe_autosave()

func _on_play(spawn_tiles := Vector2i(-1, -1)) -> void:
	_map_file_ctrl.on_play(spawn_tiles)

func _poll_playtest() -> void:
	_map_file_ctrl.poll_playtest()

func _open_size_dialog() -> void:
	_map_file_ctrl.open_size_dialog()

func _open_export_dialog() -> void:
	_map_file_ctrl.open_export_dialog()

func _open_bg_dialog() -> void:
	_map_file_ctrl.open_bg_dialog()

# —— 右侧侧边面板（地图列表 / 实体大纲 / 校验） ——
var side_panel = null

# —— 试玩配置（每图独立）：初始能力/血量，存编辑器用户数据不污染地图 JSON ——
var play_cfg := {}                 # 当前图配置 {abilities:[], hp:int}
var _prefs: Dictionary = {}        # 全部图配置 {mapname: cfg}
const PREFS_PATH := "user://playtest_prefs.json"

func _load_prefs() -> void:
	if not FileAccess.file_exists(PREFS_PATH):
		return
	var f := FileAccess.open(PREFS_PATH, FileAccess.READ)
	if f == null:
		return   # 文件不可读不致命（BUG-09：原来 null 直接赋给硬类型变量会崩 _ready）
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		_prefs = parsed

func _save_prefs() -> void:
	var f := FileAccess.open(PREFS_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(_prefs, "\t"))
	f.close()

## D1（批次 10）：实体缩略图按项目目录缓存——启动/换图不再重复读盘；打开项目时清缓存
var _ent_thumbs_cache := {}

func _entity_thumbs() -> Dictionary:
	var dk := str(manifest.get("_dir", ""))
	if _ent_thumbs_cache.has(dk):
		return _ent_thumbs_cache[dk]
	var out := {}
	for e in manifest.get("entities", []):
		var tpath: String = manifest["_dir"].path_join(str(e.get("thumb", "")))
		if FileAccess.file_exists(tpath):
			var img := Image.load_from_file(tpath)
			if img != null:
				out[str(e.get("id", ""))] = ImageTexture.create_from_image(
					EditorManifest.trim_alpha(img))
	_ent_thumbs_cache[dk] = out
	return out

## 实体占位尺寸：清单 editorSize 优先，其次从 prefab 的碰撞形状读取
func _entity_sizes() -> Dictionary:
	var out := {}
	for e in manifest.get("entities", []):
		var sz := EditorManifest.entity_editor_size(manifest, e)
		if sz != Vector2.ZERO:
			out[str(e.get("id", ""))] = sz
	return out

# —— 快捷键（app 级唯一键盘通道：画布在 SubViewport 里收不到键盘，见审查报告 K9c） ——
# A2.2：方向键微调的撤销会话窗口——1 秒内的连续按键合并为一个撤销步
var _nudge_undo_msec := 0
# K3：最近使用瓦片（会话内记忆，最多 8 格；_on_tile_pick 记录，palette_panel 置顶渲染）
var tile_mru: Array = []
# A1.3：图层面板已并入层下拉，行容器字段随之删除
## 只在真正处理了按键时才 set_input_as_handled；未匹配的键放行，不再无条件吞键。
func _shortcut_input(event: InputEvent) -> void:
	if not (event is InputEventKey and (event as InputEventKey).pressed):
		return
	# A7：过滤 echo——长按 Ctrl+Z 约 30 次/秒重入 load_data 协程，是孤儿 map_root 的触发源之一
	if (event as InputEventKey).is_echo():
		return
	var focus := get_viewport().gui_get_focus_owner()
	var k := (event as InputEventKey).keycode
	var ctrl := (event as InputEventKey).ctrl_pressed
	# —— 项目页（资产/内容/清单）接管：Esc 返回画布，Ctrl+S 保存当前视图 ——
	# 放在输入框守卫之前：项目页的 Esc 语义是「离开项目页」，输入框也不该吞掉它；
	# 其余键全部放行给视图内部的控件（表单/列表/搜索框）。
	if _in_project_view():
		if k == KEY_ESCAPE:
			_set_mode("map")
			get_viewport().set_input_as_handled()
			return
		if ctrl and k == KEY_S:
			project_shell.save_current()
			get_viewport().set_input_as_handled()
		return
	# A1：TextEdit（对话编辑器等）同样不能触发画布快捷键，否则编辑台词时 Ctrl+Z 撤的是地图
	if focus is LineEdit or focus is TextEdit:
		return
	# 保存 / 撤销 / 重做
	if ctrl and k == KEY_S:
		_on_save()
		get_viewport().set_input_as_handled()
		return
	if ctrl and k == KEY_Z:
		# A6：Ctrl+Shift+Z = 重做别名（与 Ctrl+Y 等效，肌肉记忆兼容）
		if (event as InputEventKey).shift_pressed:
			_set_status(" 已重做" if canvas.redo() else " 没有可重做的操作")
		else:
			if canvas.undo():
				_set_status(" 已撤销（剩余 %d 步）" % canvas.undo_stack.size())
			else:
				_set_status(" 没有可撤销的操作")
		get_viewport().set_input_as_handled()
		return
	if ctrl and k == KEY_Y:
		_set_status(" 已重做" if canvas.redo() else " 没有可重做的操作")
		get_viewport().set_input_as_handled()
		return
	# 复制 / 剪切 / 粘贴（按当前图层分发实体或区域，BUG-02：键盘入口从画布移到 app）
	if ctrl and k == KEY_C:
		_copy()
		get_viewport().set_input_as_handled()
		return
	if ctrl and k == KEY_X:
		_cut()
		get_viewport().set_input_as_handled()
		return
	if ctrl and k == KEY_V:
		_paste()
		get_viewport().set_input_as_handled()
		return
	# 删除选中实体（Del，BUG-02 家族：delete_selection 此前无键盘入口）
	if k == KEY_DELETE:
		# P0：没开地图时 delete_selection 会动到未初始化的画布状态，先守卫
		if not map_loaded:
			_set_status("无地图：先新建或打开一张地图")
			get_viewport().set_input_as_handled()
			return
		canvas.delete_selection()
		get_viewport().set_input_as_handled()
		return
	# A2.2 方向键微调：有选中实体时整格移动（Shift = 4 格）；1 秒会话内合并撤销
	if k in [KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN]:
		var sel: Array = canvas.selected_multi if not canvas.selected_multi.is_empty() else ([] if canvas.selected_entity == null else [canvas.selected_entity])
		if not sel.is_empty():
			var step := 4 if (event as InputEventKey).shift_pressed else 1
			var delta := Vector2i(-step, 0) if k == KEY_LEFT else (Vector2i(step, 0) if k == KEY_RIGHT else (Vector2i(0, -step) if k == KEY_UP else Vector2i(0, step)))
			var now := Time.get_ticks_msec()
			if now - _nudge_undo_msec > 1000:
				canvas._push_undo()
			_nudge_undo_msec = now
			for s in sel:
				var spr := s as Sprite2D
				if spr and is_instance_valid(spr):
					spr.position += Vector2(delta) * canvas.tile_px
			canvas._mark()
			get_viewport().set_input_as_handled()
			return
	# A2.3：Ctrl+D 原位复制（+1 格偏移；def_id/props/朝向随复制，新号照发）
	if ctrl and k == KEY_D:
		var srcs: Array = canvas.selected_multi if not canvas.selected_multi.is_empty() else ([] if canvas.selected_entity == null else [canvas.selected_entity])
		if not srcs.is_empty():
			canvas._push_undo()
			for s in srcs:
				var orig := s as Sprite2D
				if orig == null or not is_instance_valid(orig):
					continue
				var sid := str(orig.get_meta("scene", ""))
				var dup := Sprite2D.new()
				dup.texture = orig.texture
				dup.flip_h = orig.flip_h
				dup.position = orig.position + Vector2(canvas.tile_px, 0)
				dup.set_meta("scene", sid)
				dup.set_meta("props", (orig.get_meta("props", {}) as Dictionary).duplicate(true))
				if orig.has_meta("def_id"):
					dup.set_meta("def_id", str(orig.get_meta("def_id", "")))
				canvas.entities.add_child(dup)
				canvas._fit_sprite(dup, sid)
				canvas._assign_id(dup)
			canvas._mark()
			get_viewport().set_input_as_handled()
			return
	# A6：Ctrl+N/O 新建/打开
	if ctrl and k == KEY_N:
		_on_new()
		get_viewport().set_input_as_handled()
		return
	if ctrl and k == KEY_O:
		_on_open()
		get_viewport().set_input_as_handled()
		return
	# Esc 只在区域粘贴预览时消费：取消预览
	if k == KEY_ESCAPE and canvas._paste_mode:
		canvas.cancel_paste_mode()
		_set_status(" 已取消区域粘贴预览")
		get_viewport().set_input_as_handled()
		return
	match k:
		KEY_F:
			if canvas.flip_selected():
				get_viewport().set_input_as_handled()
		KEY_EQUAL:
			canvas.zoom = clampf(canvas.zoom * 1.15, 0.5, 6.0)
			canvas._update_cam()
			get_viewport().set_input_as_handled()
		KEY_MINUS:
			canvas.zoom = clampf(canvas.zoom / 1.15, 0.5, 6.0)
			canvas._update_cam()
			get_viewport().set_input_as_handled()
		KEY_HOME:
			canvas._fit_view()
			get_viewport().set_input_as_handled()
		KEY_SLASH, KEY_QUESTION:
			_open_shortcut_help()
			get_viewport().set_input_as_handled()
		KEY_ENTER:
			# v2 §2.3：Enter 的去处从「打开内容抽屉」改成「去内容编辑器」——
			# 抽屉已删，功能搬到了独立面板。
			if canvas.selected_entity != null:
				_set_mode("content")
				get_viewport().set_input_as_handled()

## A6：Tab 循环选中实体（画布子节点顺序；无实体时不动）
func _cycle_entity_selection() -> void:
	var ents := canvas.entities.get_children()
	if ents.is_empty():
		return
	var idx := ents.find(canvas.selected_entity)
	var nxt := ents[(idx + 1) % ents.size()]
	var nxt_spr := nxt as Sprite2D
	if nxt_spr == null:
		return
	canvas.selected_multi.clear()
	canvas.selected_entity = nxt_spr
	canvas.entity_selected.emit(nxt_spr)

# —— 工具 / 图层 / 资产 三者联动 ——
#
# 这三者本来是互相触发的，谁都能改另外两方，结果互相覆盖：
#   点资产 A 改工具 → 工具又改图层 → 图层又改工具…
# 旧实现里就会出现「点了资产变成涂刷，但工具按钮还高亮着原工具」，
# 或者「在实体层点涂刷，图层被悄悄踢回地形」。
#
# 现在只有一个方向：**一个入口写状态，其它全部从状态派生**。
#   _apply_state(tool=?, layer=?) 是唯一的写入口；
#   _sync_ui() 把按钮高亮/页签/辅助控件从 canvas 的真实状态刷出来。
# 任何交互（点工具按钮、切图层、点资产、按快捷键）都只调用这两者，不各写一份。

## 唯一写入口。参数留空表示「保持当前值」。
func _layer_label(i: int) -> String:
	var layers: Array = manifest.get("layers", [])
	if i >= layers.size():
		return "实体"
	return str(layers[i].get("name", layers[i].get("id", "?")))

## 把界面从 canvas 的真实状态刷出来（单向：状态 → UI，不反向写状态）
## 碰撞图层的显隐（走统一图层接口；地形/装饰/实体也走同一个）

func _collision_visible() -> bool:
	var ci := canvas._collision_layer_index()
	return ci >= 0 and canvas.is_layer_visible(ci)

func _toggle_grid() -> void:
	canvas.show_grid = not canvas.show_grid
	_refresh_view_toggles()


func _toggle_bg() -> void:
	_map_file_ctrl.toggle_bg()

func _toggle_collision() -> void:
	# 直接切碰撞图层的可见性——和地形/装饰用同一个图层接口
	var ci := canvas._collision_layer_index()
	if ci < 0:
		_set_status("清单没有碰撞图层")
		return
	canvas.set_layer_hidden(ci, canvas.is_layer_visible(ci))
	_refresh_view_toggles()
	_sync_layer_buttons()

## 视图开关按钮的按下态与画布状态保持同步
func _cut() -> void:
	if not map_loaded:
		_set_status("无地图：先新建或打开一张地图")
		return
	if _layer_type(canvas.active_layer) == "entities":
		canvas.cut_selection()
	else:
		canvas.cut_region()

func _copy() -> void:
	if not map_loaded:
		_set_status("无地图：先新建或打开一张地图")
		return
	if _layer_type(canvas.active_layer) == "entities":
		canvas.copy_selection()
	else:
		canvas.copy_region()

func _paste() -> void:
	if not map_loaded:
		_set_status("无地图：先新建或打开一张地图")
		return
	# 区域剪贴板走幽灵预览（左键落位），实体剪贴板直接贴到光标处
	if canvas._last_copy_region and not canvas._region_clip.is_empty():
		canvas._paste_mode = true
		canvas.queue_redraw()
		_set_status("区域粘贴预览：左键落位，右键或 Esc 取消")
	else:
		canvas.paste_at(canvas.get_global_mouse_position())


## 眼睛/锁按钮反映当前图层状态。
## 三个信号同时给：图标（睁眼/闭眼、开锁/上锁）+ 按钮按下态（底色高亮）+ 文字色。
## 只用字色区分太弱，深色底上几乎看不出「启用」和「未启用」的差别。
# —— 主题：全部样式集中在 src/ui/ui_theme.gd，此处只挂上去 ——
# —— UI 辅助（转发到 UiKit，保证所有弹窗内控件与主界面同风格） ——
const POPUP_BODY_W := 340
# —— 悬停高亮轮询：候选列表开着时，鼠标指到哪项 → 画布实时黄框那个实体 ——
func _process(_delta: float) -> void:
	_maybe_autosave()
	_poll_playtest()
	if _hover_list == null or not is_instance_valid(_hover_list):
		return
	if not _hover_list.is_visible_in_tree():
		return
	var mp := _hover_list.get_local_mouse_position()
	var idx := _hover_list.get_item_at_position(mp, true)
	if idx >= 0 and idx < _hover_ids.size():
		var hid := str(_hover_ids[idx])
		if hid != "":
			canvas.flash_entity(hid, 250)

# 按 ent_id 找实体精灵（画布 Entities 子节点里查）
func _ent_by_id(id: String) -> Sprite2D:
	for e in canvas.entities.get_children():
		if str(e.get_meta("ent_id", "")) == id:
			return e as Sprite2D
	return null

# —— 实体属性面板（拆到 ui/props_panel.gd，这里只留委托：调用点保持不变） ——
func _open_align_menu() -> void:
	_props_panel_ctrl.open_align_menu()

func _open_collision_gen() -> void:
	_props_panel_ctrl.open_collision_gen()

func _on_entity_selected(spr: Sprite2D) -> void:
	# 右栏检查器已删（v2 §2.3）：属性控制器仍要吃选中事件（它维护 selected_spr 等状态），
	# 但用户看到的是画布下沿那条极简信息条。
	_props_panel_ctrl.on_entity_selected(spr)
	_refresh_sel_bar()
	# v2 §3.2 双向同步的另一半：画布选中的实例，切到内容编辑器时左列要定位到它。
	# 载入地图会以 null 清选（P-10），先挡掉。
	if spr != null and project_shell != null and project_shell.content_editor != null:
		var eid := str(spr.get_meta("ent_id", ""))
		if eid != "":
			project_shell.content_editor.select_inst(eid)

func _rebuild_props_panel() -> void:
	_props_panel_ctrl.rebuild()

func _open_asset_editor(sid: String) -> void:
	_set_mode("asset", sid)

func _set_map_loaded(loaded: bool) -> void:
	map_loaded = loaded
	if _canvas_empty:
		_canvas_empty.visible = not loaded
	if not loaded:
		tile_list.modulate = Color(1, 1, 1, 0.35)
		ent_list.modulate = Color(1, 1, 1, 0.35)
	else:
		tile_list.modulate = Color(1, 1, 1, 1)
		ent_list.modulate = Color(1, 1, 1, 1)
		_sync_ui()
		# 地图载入后：清掉引导态，换成「未选中实体」的提示
		selected_spr = null
		_rebuild_props_panel()
	_refresh_dirty_badge()
	_refresh_tool_meta()
	_refresh_sel_bar()

# —— 跨图选点器（拆到 ui/cross_map_picker.gd，调用点保持不变） ——
func _clear_exit_pair(map_name: String, exit_id: String, peer_map: String, peer_id: String) -> void:
	_picker_ctrl.clear_exit_pair(map_name, exit_id, peer_map, peer_id)

func _open_map_point_picker(tmap: String, map_fid: String, point_fid: String, props: Dictionary) -> void:
	_picker_ctrl.open_map_point_picker(tmap, map_fid, point_fid, props)

# —— 模式切换：关卡 / 内容 / 资产 三个平级面板 + 旧的项目页外壳 ——
var _map_view: VBoxContainer = null
var project_shell = null        # ProjectShell（项目页外壳，含三个视图）
# 三个视图面板由 project_shell 持有；这里保留别名方便既有调用点
var asset_panel = null
var asset_view: Control = null
var content_panel = null
var content_view: Control = null
var manifest_view: Control = null
var manifest_panel = null
## v2：内容抽屉已从界面上删除（功能迁入内容编辑器）。字段保留为 null，
## 供既有 _set_content_dock / _selected_def_id 调用点安全短路。
var content_dock = null

const ContentDockScript := preload("res://src/ui/content_dock.gd")

## 内容入口（v2 §3）：抽屉不再上屏，改为切到内容编辑器面板。
## 旧调用点（props_panel 的「在工作台编辑」按钮等）因此自动落到新落点。
func _set_content_dock(on: bool, def_id := "") -> void:
	if on:
		_set_mode("content")

## 当前选中实体用的内容组 id；没有时为空
func _selected_def_id() -> String:
	if selected_spr == null or not is_instance_valid(selected_spr):
		return ""
	return str(selected_spr.get_meta("def_id", ""))

## 内容组被编辑后，把引用它的实体标记为脏（内容在 defs 里，地图本身不变）
func _mark_def_used(_def_id: String) -> void:
	canvas._mark()

## 为当前选中实体创建内容组（defs 资源）并挂上去，然后打开抽屉。
## 粒度是"这个实体"，id 里带地图名与实体 id，一眼看出归属；仍可被别的实体复用。
func _create_def_for_selected(sid: String) -> void:
	if selected_spr == null or not is_instance_valid(selected_spr):
		return
	var map_name := str(canvas.cur_map_name)
	var ent_id := str(selected_spr.get_meta("ent_id", ""))
	var base := "grp.%s.%s" % [map_name, ent_id] if map_name != "" and ent_id != "" else "grp"
	var existing: Array = ContentStore.list_ids(manifest, "defs")
	var new_id := base
	var i := 2
	while existing.has(new_id):
		new_id = "%s.%d" % [base, i]
		i += 1
	var template := ContentTemplates.for_kind("defs")
	template["kind"] = sid
	template["name"] = str(ent_id) if ent_id != "" else new_id
	if not ContentStore.write(manifest, "defs", new_id, template):
		_set_status(" 内容组创建失败，检查 content/defs 目录权限")
		return
	canvas._push_undo()
	selected_spr.set_meta("def_id", new_id)
	canvas._mark()
	_rebuild_props_panel()
	_set_content_dock(true, new_id)
	_set_status(" 已创建内容组 %s" % new_id)

## 跳到全屏内容库并定位到某资源（抽屉里的"在内容库中打开"）
func _open_content_at(kind_key: String, res_id: String) -> void:
	_set_mode("content")
	content_panel.show_kind(kind_key)
	content_panel.refresh_list(res_id)

## 模式切换：mode = map（关卡编辑器）/ content（内容编辑器）/ asset（资产目录）/ manifest。
## 三个面板是平级关系（v2 §1），顶栏三个入口直接切，Esc 回关卡编辑器。
func _set_mode(mode: String, focus_sid := "") -> void:
	var on_map := mode == "map"
	if _map_view:
		_map_view.visible = on_map
	_sync_panel_buttons(mode)
	if project_shell == null:
		return
	project_shell.visible = not on_map
	if on_map:
		_rebuild_props_panel()
		return
	project_shell.show_view(mode, focus_sid)

## 当前是否在项目页（非画布）
func _in_project_view() -> bool:
	return project_shell != null and project_shell.visible

## 顶栏三个面板入口的按下态：单一真相是 _set_mode 的入参，
## 不依赖按钮自己记状态（点 Esc 返回、点地图菜单的路径都要同步）。
func _sync_panel_buttons(mode: String) -> void:
	for k in _panel_btns.keys():
		var b := _panel_btns[k] as Button
		if b != null:
			b.button_pressed = (str(k) == mode)

func _save_manifest_file() -> void:
	var out := {}
	for k in manifest.keys():
		if not str(k).begins_with("_"):
			out[k] = manifest[k]
	var tiles: Array = out.get("tiles", [])
	for t in tiles:
		(t as Dictionary).erase("atlas_abs")
	# 内置种类由编辑器提供，不写进游戏工程清单
	out = preload("res://src/content/builtin_kinds.gd").strip_from(out)
	var txt := JSON.stringify(out, "\t")
	if not (JSON.parse_string(txt) is Dictionary):
		_set_status(" 清单写回校验失败，未保存")
		return
	var p: String = str(manifest.get("_dir", "")).path_join("editor/editor_manifest.json")
	# P-02/S-02：清单写盘走 MapStore 原子写单入口
	if not MapStore.write_text(p, txt):
		_set_status(" 清单写入失败: " + p)
		return
	_set_status(" 清单已保存（资产模板变更下次试玩生效）")
## —— 拆到 src/core/editor_state.gd 的委托（调用点保持不变） ——
func _apply_state(tool := "", layer := -1) -> void:
	_editor_state_ctrl._apply_state(tool, layer)

func _sync_ui() -> void:
	_editor_state_ctrl._sync_ui()

func _layer_type(i: int) -> String:
	return _editor_state_ctrl._layer_type(i)

func _is_tiles_layer(i: int) -> bool:
	return _editor_state_ctrl._is_tiles_layer(i)

func _layer_kind_for_tool(tool_name: String) -> String:
	return _editor_state_ctrl._layer_kind_for_tool(tool_name)

func _layer_for_tool(tool_name: String, cur_layer: int) -> int:
	return _editor_state_ctrl._layer_for_tool(tool_name, cur_layer)

func _first_tiles_layer() -> int:
	return _editor_state_ctrl._first_tiles_layer()

func _set_tool(tool_name: String) -> void:
	_editor_state_ctrl._set_tool(tool_name)

func _on_layer(i: int) -> void:
	_editor_state_ctrl._on_layer(i)

func _tool_for_layer(i: int) -> String:
	return _editor_state_ctrl._tool_for_layer(i)

func _on_tile_pick(i: int, _at: Vector2 = Vector2.ZERO, _mb: int = 0) -> void:
	_editor_state_ctrl._on_tile_pick(i, _at, _mb)

func _on_ent_pick(i: int, _at: Vector2 = Vector2.ZERO, _mb: int = 0) -> void:
	_editor_state_ctrl._on_ent_pick(i, _at, _mb)
## —— 拆到 src/ui/editor_layout.gd 的委托（调用点保持不变） ——
func _build_editor_ui() -> void:
	_layout_ctrl._build_editor_ui()

func _set_palette_page(which: String) -> void:
	_layout_ctrl._set_palette_page(which)

func _set_status(msg: String) -> void:
	_layout_ctrl._set_status(msg)

func _on_cursor(t: String) -> void:
	_layout_ctrl._on_cursor(t)

func _on_modified() -> void:
	_layout_ctrl._on_modified()

func _refresh_dirty_badge() -> void:
	_layout_ctrl._refresh_dirty_badge()

func _refresh_tool_meta() -> void:
	_layout_ctrl._refresh_tool_meta()

func _refresh_view_toggles() -> void:
	_layout_ctrl._refresh_view_toggles()

func _sync_layer_buttons() -> void:
	_layout_ctrl._sync_layer_buttons()

func _refresh_sel_bar() -> void:
	_layout_ctrl._refresh_sel_bar()

func _build_theme() -> void:
	_layout_ctrl._build_theme()

func _set_badge(p: PanelContainer, text: String, color: Color) -> void:
	_layout_ctrl._set_badge(p, text, color)

func _open_popup(pop: PopupPanel, popup_size := Vector2i.ZERO) -> void:
	_layout_ctrl._open_popup(pop, popup_size)

func _popup_body(title: String, subtitle := "") -> Dictionary:
	return _layout_ctrl._popup_body(title, subtitle)

## R4：快捷键速查弹窗（? 键 / 状态栏「?」入口）
func _open_shortcut_help() -> void:
	_layout_ctrl._open_shortcut_help()
## —— 拆到 src/ui/map_file.gd 的委托（调用点保持不变） ——
func _open_play_cfg() -> void:
	_map_file_ctrl._open_play_cfg()

func _play_args(spawn_tiles := Vector2i(-1, -1)) -> PackedStringArray:
	return _map_file_ctrl._play_args(spawn_tiles)

func _sync_play_cfg_to_map() -> void:
	_map_file_ctrl._sync_play_cfg_to_map()
## —— 拆到 src/ui/editor_layout.gd 的委托（调用点保持不变） ——
## 项目页：三个全屏视图合并进一个外壳（src/ui/project_shell.gd）
func _build_project_view() -> void:
	_layout_ctrl._build_project_view()
## —— 拆到 src/core/side_actions.gd 的委托（调用点保持不变） ——
func _refresh_side_panel() -> void:
	_side_actions_ctrl._refresh_side_panel()

## T16/K18（批次 10）：地图改名/复制——委托 side_actions 控制器
func _rename_map_by_name(old_name: String, new_name: String) -> void:
	_side_actions_ctrl._rename_map_by_name(old_name, new_name)

func _duplicate_map_by_name(old_name: String, new_name: String) -> void:
	_side_actions_ctrl._duplicate_map_by_name(old_name, new_name)

func _refresh_world() -> void:
	_side_actions_ctrl._refresh_world()

func _save_levels(data: Dictionary) -> void:
	_side_actions_ctrl._save_levels(data)

func _refresh_entity_outline() -> void:
	_side_actions_ctrl._refresh_entity_outline()

func _scene_name(sid: String) -> String:
	return _side_actions_ctrl._scene_name(sid)

func _open_map_by_name(map_name: String) -> void:
	_side_actions_ctrl._open_map_by_name(map_name)

func _focus_entity(ent_id: String) -> void:
	_side_actions_ctrl._focus_entity(ent_id)

func _delete_entities_by_id(ids: Array) -> void:
	_side_actions_ctrl._delete_entities_by_id(ids)

func _run_validate(all_maps: bool) -> void:
	_side_actions_ctrl._run_validate(all_maps)

## 校验问题的纯数据出口（内容编辑器弹窗用；不落隐藏侧栏的 UI）
func _collect_issues(all_maps: bool) -> Array:
	return _side_actions_ctrl._collect_issues(all_maps)

func _focus_issue(map_name: String, ent_id: String) -> void:
	_side_actions_ctrl._focus_issue(map_name, ent_id)
