extends Control
## 独立关卡编辑器应用（Godot EXE）：
## 启动 → 读 user:// 项目列表 → 自动打开上次项目，否则进项目选择页；
## 选定项目后搭界面：顶栏（设置▾ / 地图▾+三模式 / 试玩）、左栏（层下拉+调色板）、画布、状态栏。
## 不绑定具体游戏：多个工程并行管理，顶栏「设置 ▾ → 切换项目…」切换。

const SettingsCfg := "user://settings.cfg"
const ProjectShellScript := preload("res://src/ui/project_shell.gd")
const ProjectPicker := preload("res://src/ui/project_picker.gd")
const ImageProbe := preload("res://src/assets/image_probe.gd")
const MapDialogs := preload("res://src/ui/map_dialogs.gd")
const UiThemeScript := preload("res://src/ui/ui_theme.gd")
const UiKitScript := preload("res://src/ui/ui_kit.gd")
const MapStore := preload("res://src/map/map_store.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const ConditionDecls := preload("res://src/content/condition_decl.gd")
const StepDecls := preload("res://src/content/step_decl.gd")
const AudioDecls := preload("res://src/content/audio_decl.gd")
const TriggerDecls := preload("res://src/content/trigger_decl.gd")

var manifest := {}
var canvas: EditorCanvas
var cur_map_path := ""
var _cur_map_name := ""
## 地图名单一来源 = canvas.cur_map_name。app 侧保留同名属性做代理——
## 原来两个字段各自被赋值，切图协程窗口期会短暂不一致，读的那一方拿到旧名。
var cur_map_name: String:
	get:
		if canvas != null and str(canvas.cur_map_name) != "":
			return str(canvas.cur_map_name)
		return _cur_map_name
	set(v):
		_cur_map_name = v
		if canvas != null:
			canvas.cur_map_name = v
var tile_list: ItemList
var ent_list: ItemList
## 碰撞层左栏：说明 + 类型/形状选择器
var grid_hint: VBoxContainer
# 下面三个成员只在 ui/editor_layout.gd（赋值）与 canvas/editor_state.gd（读取）经 app. 访问，
# 本类确实不直接使用——但必须在这里声明（动态赋值会静默失败），故定向压制警告。
@warning_ignore("unused_private_class_variable")
var _coll_type_opt: OptionButton
@warning_ignore("unused_private_class_variable")
var _coll_shape_opt: OptionButton
var status: Label
var _props_panel_ctrl   # ui/props_panel.gd 控制器（只剩「从地形生成碰撞」弹窗）
var _map_file_ctrl   # ui/map_file.gd 控制器
var _editor_state_ctrl   # canvas/editor_state.gd 控制器（状态流）
var _layout_ctrl   # ui/editor_layout.gd 控制器（界面搭建）
var _picker_ctrl   # ui/project_picker.gd 控制器（项目选择页）
var _map_dialogs_ctrl   # ui/map_dialogs.gd 控制器（尺寸/导出弹窗）
var _side_actions_ctrl   # map/side_actions.gd 控制器（侧栏动作）
var _palette_ctrl   # ui/palette_panel.gd 控制器（调色板导航：多图集三级/单图集两级）
var selected_spr: EntityNode = null
var map_loaded := false          # 防呆：是否已载入地图
## 顶栏左侧「设置 ▾」锚点（「地图 ▾」按钮是固定文案，不显示当前地图名）
# 同上：赋值在 editor_layout.gd，连接也在那边（app._map_btn.pressed），本类不直接使用。
@warning_ignore("unused_private_class_variable")
var _map_btn: Button
## 顶栏导航条（地图 ▾ + 关卡/内容/资产）：关卡视图顶栏与项目页顶栏各嵌一个，
## 统一登记在这里同步按下态——_set_mode 是唯一真相。
var _nav_bars := []
# 画布空态引导（未打开地图时显示）
var _canvas_empty: Control

func _ready() -> void:
	_picker_ctrl = ProjectPicker.new(self)
	_map_dialogs_ctrl = MapDialogs.new(self)
	_load_prefs()
	_load_projects()
	_ensure_editor_controllers()
	manifest = _load_last_project()
	get_tree().auto_accept_quit = false
	if manifest.is_empty() or manifest.has("_error"):
		_show_picker(manifest.get("_error", ""))
	else:
		_enter_project(cur_project_dir, manifest)

## 首次进入或项目切换后重建编辑器控制器；选择页阶段不提前创建，
## 避免布局控制器在宿主没有项目上下文时被误用（A1/E00）。
func _ensure_editor_controllers() -> void:
	if _picker_ctrl == null:
		_picker_ctrl = ProjectPicker.new(self)
	if _map_dialogs_ctrl == null:
		_map_dialogs_ctrl = MapDialogs.new(self)
	if _layout_ctrl == null:
		_layout_ctrl = preload("res://src/ui/editor_layout.gd").new(self)
	if _side_actions_ctrl == null:
		_side_actions_ctrl = preload("res://src/map/side_actions.gd").new(self)
	if _palette_ctrl == null:
		_palette_ctrl = preload("res://src/ui/palette_panel.gd").new(self)
	_build_theme()

## 启动时尝试打开上次的项目；失败返回 {} 或带 _error 的字典（选择页据此显示原因）。
func _load_last_project() -> Dictionary:
	if cur_project_dir == "":
		return {}
	return EditorManifest.load_from(cur_project_dir)

## 关窗口前拦截：有未保存修改就确认，并把草稿落盘
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		call_deferred("_handle_close_request")

func _handle_close_request() -> void:
	if map_loaded and canvas and canvas.modified_flag:
		# 退出前先强制写草稿（绕过节流）：用户可能选「保留草稿」，
		# 那份草稿必须是最新内容，不能因为距上次自动保存太近而缺失（A3）。
		_map_file_ctrl.write_draft_now()
		if not await _confirm_discard("退出编辑器"):
			return
	get_tree().auto_accept_quit = true
	get_tree().quit()

# —— 项目记忆（user://settings.cfg）：多项目列表 + 上次打开的那个 ——
## 顺序 = 最近使用倒序。names 记住 projectName，项目目录暂时不可达时选择页仍显示得出来。
var project_dirs: Array = []
var project_names := {}
var cur_project_dir := ""


# —— 编辑器主界面 ——
# —— 调色板填充（控制器在 ui/palette_panel.gd） ——
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
	await _map_file_ctrl.load_map_file(p)

## 保存当前地图；返回是否成功（试玩前依赖它决定是否继续）
func _on_save() -> bool:
	return await _map_file_ctrl.on_save()

func _on_new() -> void:
	_map_file_ctrl.on_new()

func _on_open() -> void:
	_map_file_ctrl.on_open()

## 顶栏名字输入框已删：改名走地图菜单弹窗
func _on_rename() -> void:
	_map_file_ctrl.on_rename()

func _maybe_autosave() -> void:
	_map_file_ctrl.maybe_autosave()

func _on_play(spawn_tiles := Vector2i(-1, -1)) -> void:
	_map_file_ctrl.on_play(spawn_tiles)

func _poll_playtest() -> void:
	_map_file_ctrl.poll_playtest()

func _open_size_dialog() -> void:
	_map_dialogs_ctrl.open_size_dialog()

func _open_export_dialog() -> void:
	_map_dialogs_ctrl.open_export_dialog()

## 切换项目：有未保存修改先确认，然后回选择页。
## 回选择页会 free 掉整个编辑器界面（画布/三面板）；再进项目统一走 _enter_project，
## 不残留上一个项目的清单、缩略图、地图路径与撤销栈。
func _switch_project() -> void:
	if map_loaded and canvas != null and canvas.modified_flag:
		if not await _confirm_discard("切换项目"):
			return
	_clear_project_session()
	_picker_ctrl.show_picker()

## 项目进入唯一入口：启动恢复、选择页手选都走这里。
## 控制器必须先建好，_build_editor_ui 才不会打到空宿主（E00/D05）。
func _enter_project(dir: String, loaded_manifest: Dictionary) -> void:
	_clear_project_session()
	manifest = loaded_manifest
	_ent_thumbs_cache.clear()
	_picker_ctrl.remember_project(dir, str(manifest.get("projectName", "")))
	_build_editor_ui()
	_report_recovery_items()

## 进入项目后报告未完成草稿与提交日志（A3）：草稿可恢复、提交日志提示哪些文件已写。
func _report_recovery_items() -> void:
	if _map_file_ctrl == null:
		return
	var parts: Array[String] = []
	var drafts: Array = preload("res://src/map/recovery.gd").list_drafts(manifest)
	if not drafts.is_empty():
		parts.append("%d 份草稿（地图菜单可恢复）" % drafts.size())
	var pending: Array = preload("res://src/map/recovery.gd").scan_pending(manifest)
	var partial := 0
	for p in pending:
		if str((p as Dictionary).get("status", "")) != "done":
			partial += 1
	if partial > 0:
		parts.append("%d 次未完成提交（已写文件保留，可同 ID 重试）" % partial)
	if parts.is_empty():
		return
	_set_status(" 上次会话有 %s" % "；".join(PackedStringArray(parts)))

## 释放当前项目会话。控制器随界面一起失效，必须全部清空。
func _clear_project_session() -> void:
	manifest = {}
	cur_map_path = ""
	_cur_map_name = ""
	map_loaded = false
	canvas = null
	_map_view = null
	project_shell = null
	asset_panel = null
	# 控制器由 editor_layout 建界面时赋值，界面已释放就必须全部置空，
	# 否则切项目回选择页后 _process / 菜单委托仍会打到旧控制器上（见 6b0c5de）。
	_map_file_ctrl = null
	_props_panel_ctrl = null
	_editor_state_ctrl = null
	_layout_ctrl = null
	_side_actions_ctrl = null
	_palette_ctrl = null
	_nav_bars.clear()
	_ent_thumbs_cache.clear()

# —— 试玩配置（每图独立）：初始能力/血量，存编辑器用户数据不污染地图 JSON ——
var play_cfg := {}                 # 当前图试玩配置 {flag_id: bool, param_id: int}（清单 playtest 声明驱动）
var _prefs: Dictionary = {}        # 全部图配置 {mapname: cfg}
const PREFS_PATH := "user://playtest_prefs.json"

func _load_prefs() -> void:
	if not FileAccess.file_exists(PREFS_PATH):
		return
	var f := FileAccess.open(PREFS_PATH, FileAccess.READ)
	if f == null:
		return   # 文件不可读不致命（null 直接赋给硬类型变量会崩 _ready）
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		_prefs = parsed

func _save_prefs() -> void:
	var f := FileAccess.open(PREFS_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("偏好写盘失败: " + PREFS_PATH)
		return
	f.store_string(JSON.stringify(_prefs, "\t"))
	f.close()

## D1：实体缩略图按项目目录缓存——启动/换图不再重复读盘；打开项目时清缓存
var _ent_thumbs_cache := {}

func _entity_thumbs() -> Dictionary:
	# 键带项目数据版本号——清单新增资产/换 thumb 后保存会让版本号 +1，
	# 缓存自动失效，不必重启编辑器。
	var dk := str(manifest.get("_dir", "")) + "#" + str(MapStore.project_rev)
	if _ent_thumbs_cache.has(dk):
		return _ent_thumbs_cache[dk]
	var out := {}
	for a in manifest.get("assets", []):
		if not (a is Dictionary):
			continue
		var tpath: String = manifest["_dir"].path_join(str((a as Dictionary).get("thumb", "")))
		if FileAccess.file_exists(tpath):
			var img := Image.load_from_file(tpath)
			if img != null:
				out[str((a as Dictionary).get("id", ""))] = ImageTexture.create_from_image(
					ImageProbe.trim_alpha(img))
	_ent_thumbs_cache[dk] = out
	return out

## 资产占位尺寸：清单 editorSize 优先，其次从 prefab 的碰撞形状读取
func _entity_sizes() -> Dictionary:
	var out := {}
	for a in manifest.get("assets", []):
		if not (a is Dictionary):
			continue
		var sz := EditorManifest.entity_editor_size(manifest, a)
		if sz != Vector2.ZERO:
			out[str((a as Dictionary).get("id", ""))] = sz
	return out

# —— 快捷键（app 级唯一键盘通道：画布在 SubViewport 里收不到键盘） ——
# 方向键微调的撤销会话窗口——1 秒内的连续按键合并为一个撤销步
var _nudge_undo_msec := 0
# 最近使用瓦片（会话内记忆，最多 8 格；_on_tile_pick 记录，palette_panel 置顶渲染）
var tile_mru: Array = []
# 图层面板已并入层下拉，行容器字段随之删除
## 只在真正处理了按键时才 set_input_as_handled；未匹配的键放行，不再无条件吞键。
func _shortcut_input(event: InputEvent) -> void:
	if not (event is InputEventKey and (event as InputEventKey).pressed):
		return
	# 过滤 echo——长按 Ctrl+Z 约 30 次/秒重入 load_data 协程，是孤儿 map_root 的触发源之一
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
	# 编辑器 UI 未就绪（启动早期 / 切项目重建窗口期）：canvas 为 null，
	# 下方所有分支都默认画布存在——统一拦住，不响应任何快捷键。
	if canvas == null:
		return
	# TextEdit（对话编辑器等）同样不能触发画布快捷键，否则编辑台词时 Ctrl+Z 撤的是地图
	if focus is LineEdit or focus is TextEdit:
		return
	# 保存 / 撤销 / 重做
	if ctrl and k == KEY_S:
		_on_save()
		get_viewport().set_input_as_handled()
		return
	if ctrl and k == KEY_Z:
		# Ctrl+Shift+Z = 重做别名（与 Ctrl+Y 等效，肌肉记忆兼容）
		if (event as InputEventKey).shift_pressed:
			_set_status(" 已重做" if await canvas.redo() else " 没有可重做的操作")
		else:
			if await canvas.undo():
				_set_status(" 已撤销（剩余 %d 步）" % canvas.undo_stack.size())
			else:
				_set_status(" 没有可撤销的操作")
		get_viewport().set_input_as_handled()
		return
	if ctrl and k == KEY_Y:
		_set_status(" 已重做" if await canvas.redo() else " 没有可重做的操作")
		get_viewport().set_input_as_handled()
		return
	# 复制 / 剪切 / 粘贴（按 place_kind 分发实体或区域；键盘入口在 app 级——画布收不到键盘）
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
	# 删除选中实体（Del；delete_selection 的键盘入口）
	if k == KEY_DELETE:
		# P0：没开地图时 delete_selection 会动到未初始化的画布状态，先守卫
		if not map_loaded:
			_set_status("无地图：先新建或打开一张地图")
			get_viewport().set_input_as_handled()
			return
		canvas.delete_selection()
		get_viewport().set_input_as_handled()
		return
	# 方向键微调：有选中实体时整格移动（Shift = 4 格）；1 秒会话内合并撤销
	if k in [KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN]:
		var sel: Array = canvas.selected_multi if not canvas.selected_multi.is_empty() else ([] if canvas.selected_entity == null else [canvas.selected_entity])
		if not sel.is_empty():
			# 锁层/隐藏层不可写（E04）：键盘微调走与拖动同一个选区级检查
			if canvas.selection_touches_locked(sel):
				_set_status(" 选中实例所在图层已锁定：解锁后再微调")
				get_viewport().set_input_as_handled()
				return
			var step := 4 if (event as InputEventKey).shift_pressed else 1
			var delta := Vector2i(-step, 0) if k == KEY_LEFT else (Vector2i(step, 0) if k == KEY_RIGHT else (Vector2i(0, -step) if k == KEY_UP else Vector2i(0, step)))
			var now := Time.get_ticks_msec()
			if now - _nudge_undo_msec > 1000:
				canvas._push_undo()
			_nudge_undo_msec = now
			for s in sel:
				var n := s as EntityNode
				if n and is_instance_valid(n):
					n.position += canvas.grid_dir_px(delta.x, delta.y)
			canvas._mark()
			get_viewport().set_input_as_handled()
			return
	# Ctrl+D 原位复制（+1 格偏移；props/functions/朝向随复制，新号照发）
	if ctrl and k == KEY_D:
		var srcs: Array = canvas.selected_multi if not canvas.selected_multi.is_empty() else ([] if canvas.selected_entity == null else [canvas.selected_entity])
		if not srcs.is_empty():
			# 源在锁层 = 不许复制（副本会落回同层）；先查再压撤销，别留空快照
			if canvas.selection_touches_locked(srcs):
				_set_status(" 选中实例所在图层已锁定：解锁后再复制")
				get_viewport().set_input_as_handled()
				return
			canvas._push_undo()
			for s in srcs:
				var orig := s as EntityNode
				if orig == null or not is_instance_valid(orig):
					continue
				var dup := canvas.make_object(orig.asset)
				dup.props = orig.props.duplicate(true)
				dup.functions = orig.functions.duplicate(true)
				dup.data_transform = orig.data_transform.duplicate(true)
				dup.z_policy = orig.z_policy
				dup.visible_flag = orig.visible_flag
				dup.refresh_visual()
				dup.position = orig.position + canvas.grid_dir_px(1, 0)
				# 副本跟随原件所在层（层栈化后实例散在各层容器）
				var oi: int = canvas._layer_index_of(orig.layer_id)
				if oi < 0:
					oi = 0
				dup.layer_id = canvas.layer_id(oi)
				canvas._place_in_layer(dup, oi)
				canvas._ensure_code(dup)
			canvas._mark()
			get_viewport().set_input_as_handled()
			return
	# Ctrl+N/O 新建/打开
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
		KEY_R:
			# 瓦片笔刷变换（v7）：R 循环旋转档位；摆放模式 = 选中实例旋转 90°（互不冲突）
			if canvas.place_kind == "tiles":
				canvas.cycle_tile_rotation()
				get_viewport().set_input_as_handled()
			elif canvas.rotate_selected_90():
				get_viewport().set_input_as_handled()
		KEY_BRACKETLEFT:
			if canvas.scale_selected(-0.1):
				get_viewport().set_input_as_handled()
		KEY_BRACKETRIGHT:
			if canvas.scale_selected(0.1):
				get_viewport().set_input_as_handled()
		KEY_X:
			# 纯 X = 瓦片水平翻转（Ctrl+X 剪切在上面已提前返回，不会到这里）
			if canvas.place_kind == "tiles":
				canvas.toggle_tile_flip()
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
		KEY_ENTER, KEY_KP_ENTER:
			# Enter 的去处从「打开内容抽屉」改成「去内容编辑器」——
			# 抽屉已删，功能搬到了独立面板。小键盘回车同权。
			if canvas.selected_entity != null:
				_set_mode("content")
				get_viewport().set_input_as_handled()

# —— 工具 / 图层 / 资产 三者联动 ——
#
# 这三者本来是互相触发的，谁都能改另外两方，结果互相覆盖：
# 点资产 A 改工具 → 工具又改图层 → 图层又改工具…
# 旧实现里就会出现「点了资产变成涂刷，但工具按钮还高亮着原工具」，
# 或者「在实体层点涂刷，图层被悄悄踢回地形」。
#
# 现在只有一个方向：**一个入口写状态，其它全部从状态派生**。
# _apply_state(tool=?, layer=?) 是唯一的写入口；
# _sync_ui() 把按钮高亮/层下拉/辅助控件从 canvas 的真实状态刷出来。
# 任何交互（点导航按钮、切图层、点资产、按快捷键）都只调用这两者，不各写一份。

func _layer_label(i: int) -> String:
	# 层名来自地图 meta.layers；碰撞元层排在栈外（下标 = 层数）；无图/越界回退 "?"
	if canvas == null or not map_loaded:
		return "?"
	if i == canvas.collision_index():
		return "碰撞"
	if i < 0 or i >= canvas.layer_count():
		return "?"
	return canvas.layer_name(i)

func _toggle_grid() -> void:
	canvas.show_grid = not canvas.show_grid
	_refresh_view_toggles()


## 框选开关：打开后画布左键拖动进入框选（不用快捷键）
func _toggle_select_mode() -> void:
	if canvas == null:
		return
	canvas.select_mode = not canvas.select_mode
	_set_status("框选已%s —— 左键拖动框选，选中后可整组拖动" % ("打开" if canvas.select_mode else "关闭"))
	_refresh_view_toggles()

## 吸附开关：关掉后摆放/拖动落在任意像素位置（数据存浮点格坐标，亚格摆放）
func _toggle_snap() -> void:
	if canvas == null:
		return
	canvas.snap_to_grid = not canvas.snap_to_grid
	_set_status("吸附已%s —— %s" % [
		"打开" if canvas.snap_to_grid else "关闭",
		"摆放/拖动对齐到格" if canvas.snap_to_grid else "可放在任意像素位置（坐标存浮点）"])
	_refresh_view_toggles()

## 视图开关按钮的按下态与画布状态保持同步
func _cut() -> void:
	if not map_loaded:
		_set_status("无地图：先新建或打开一张地图")
		return
	if canvas.place_kind == "object":
		canvas.cut_selection()
	else:
		canvas.cut_region()

func _copy() -> void:
	if not map_loaded:
		_set_status("无地图：先新建或打开一张地图")
		return
	if canvas.place_kind == "object":
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


# —— 主题：全部样式集中在 src/ui/ui_theme.gd，此处只挂上去 ——
# —— UI 辅助（转发到 UiKit，保证所有弹窗内控件与主界面同风格） ——
const POPUP_BODY_W := 340
# —— 悬停高亮轮询：候选列表开着时，鼠标指到哪项 → 画布实时黄框那个实体 ——
func _process(_delta: float) -> void:
	# 选择页阶段还没构建编辑器界面，_map_file_ctrl 尚不存在（由 editor_layout 赋值），
	# 自动保存与试玩轮询都必须跳过，否则每帧在 nil 上调方法。
	if _map_file_ctrl == null:
		return
	_maybe_autosave()
	_poll_playtest()

# 按实例码找实例节点（层栈化后跨全部层容器查）
func _ent_by_id(id: String) -> EntityNode:
	for e in canvas.ents_all():
		var n := e as EntityNode
		if n != null and n.code == id:
			return n
	return null

# —— 实体属性（面板已删，只剩碰撞生成弹窗与选中状态维护） ——
func _open_collision_gen() -> void:
	_props_panel_ctrl.open_collision_gen()

func _on_entity_selected(n: EntityNode) -> void:
	# 用户看到的是画布下沿那条极简信息条；参数编辑走内容编辑器与资产目录。
	selected_spr = n
	_refresh_sel_bar()
	# 双向同步的另一半：画布选中的实例，切到内容编辑器时左列要定位到它。
	# 载入地图会以 null 清选，先挡掉。
	if n != null and project_shell != null and project_shell.content_editor != null:
		if n.code != "":
			project_shell.content_editor.select_inst(n.code)

func _set_map_loaded(loaded: bool) -> void:
	map_loaded = loaded
	# 顶栏「设置 ▾」是固定文案
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
	_refresh_dirty_badge()
	_refresh_tool_meta()
	_refresh_sel_bar()

# —— 模式切换：关卡 / 内容 / 资产 三个平级面板 + 旧的项目页外壳 ——
var _map_view: VBoxContainer = null
var project_shell = null        # ProjectShell（项目页外壳，含三个视图）
# 视图面板由 project_shell 持有；这里保留别名方便既有调用点
var asset_panel = null

## 模式切换：mode = map（关卡编辑器）/ content（内容编辑器）/ asset（资产目录）。
## 三个面板是平级关系，顶栏三个入口直接切，Esc 回关卡编辑器。
func _set_mode(mode: String, focus_sid := "") -> void:
	# 离开内容页前提交待提交的 SpinBox 值（连续控件失焦才写盘，直接 Esc 切走会丢）；
	# 只冲刷控件值，暂存的新内容留到正式保存/试玩（A2）。
	if mode != "content" and project_shell != null and project_shell.content_editor != null:
		project_shell.content_editor.commit_fields()
	var on_map := mode == "map"
	if _map_view:
		_map_view.visible = on_map
	_sync_panel_buttons(mode)
	if project_shell == null:
		return
	project_shell.visible = not on_map
	if on_map:
		return
	project_shell.show_view(mode, focus_sid)

## 当前是否在项目页（非画布）
func _in_project_view() -> bool:
	return project_shell != null and project_shell.visible

## 顶栏三个面板入口的按下态：单一真相是 _set_mode 的入参，
## 不依赖按钮自己记状态（点 Esc 返回、点地图菜单的路径都要同步）。
func _sync_panel_buttons(mode: String) -> void:
	for nb in _nav_bars:
		if nb != null and is_instance_valid(nb):
			nb.set_mode(mode)

func _save_manifest_file() -> void:
	await _save_manifest_file_async()

## 清单落盘；返回是否成功（await 结果）。地图保存前需要知道成功与否（D06）。
func _save_manifest_file_async() -> bool:
	var out := {}
	for k in manifest.keys():
		if not str(k).begins_with("_"):
			out[k] = manifest[k]
	# assets 与 live manifest 共享同一批字典引用——必须深拷贝后再擦运行时键
	# （atlas_abs 每次加载重算，写盘会污染游戏工程清单，且重载后丢掉）
	out["assets"] = (out.get("assets", []) as Array).duplicate(true)
	for a in (out.get("assets", []) as Array):
		if a is Dictionary:
			(a as Dictionary).erase("atlas_abs")
	# 内置种类由编辑器提供，不写进游戏工程清单
	out = preload("res://src/assets/builtin_kinds.gd").strip_from(out)
	var txt := JSON.stringify(out, "\t")
	if not (JSON.parse_string(txt) is Dictionary):
		_set_status(" 清单写回校验失败，未保存")
		return false
	var p: String = str(manifest.get("_dir", "")).path_join("editor/editor_manifest.json")
	# C-20：清单同样做外部改动预警——手改细配置（palette 等）被编辑器覆盖是真实损失
	var mt0 := int(manifest.get("_manifest_mtime", 0))
	if mt0 > 0 and FileAccess.file_exists(p) and FileAccess.get_modified_time(p) != mt0:
		if not await _confirm_action("外部改动",
			"清单文件在编辑器打开后被外部修改过。\n覆盖保存将丢失外部改动。", "覆盖保存"):
			_set_status(" 已取消保存（保留磁盘上的外部改动）")
			return false
	# 清单写盘走 MapStore 原子写单入口
	if not MapStore.write_text(p, txt):
		_set_status(" 清单写入失败: " + p)
		return false
	# 新补发的执行码已经随清单落盘，标记清掉（D6：避免每次内容视图 Ctrl+S 都重写清单）
	manifest.erase("_codes_issued")
	manifest["_manifest_mtime"] = FileAccess.get_modified_time(p)
	# 人类名 ↔ 执行码对照表随清单一起刷新（游戏侧重建映射、人工 diff 均用）；
	# 只在清单落盘成功后写，码表写失败不影响清单本身，状态栏单独报。
	var cp: String = str(manifest.get("_dir", "")).path_join("editor/CODES.md")
	var doc := FunctionDecls.codes_doc(manifest)
	var cdoc := ConditionDecls.codes_doc(manifest)
	if cdoc != "":
		doc += "\n" + cdoc
	var adoc := AudioDecls.codes_doc(manifest)
	if adoc != "":
		doc += "\n" + adoc
	var sdoc := StepDecls.codes_doc(manifest)
	if sdoc != "":
		doc += "\n" + sdoc
	var tdoc := TriggerDecls.codes_doc(manifest)
	if tdoc != "":
		doc += "\n" + tdoc
	if not MapStore.write_text(cp, doc):
		_set_status(" 清单已保存，但码表写入失败: " + cp)
	return true
## —— 拆到 src/canvas/editor_state.gd 的委托（调用点保持不变） ——
func _apply_state(tool := "", layer := -1) -> void:
	_editor_state_ctrl._apply_state(tool, layer)

func _sync_ui() -> void:
	_editor_state_ctrl._sync_ui()

func _on_layer(i: int) -> void:
	_editor_state_ctrl._on_layer(i)

func _on_tile_pick(i: int, _at: Vector2 = Vector2.ZERO, _mb: int = 0) -> void:
	_editor_state_ctrl._on_tile_pick(i, _at, _mb)

func _on_ent_pick(i: int, _at: Vector2 = Vector2.ZERO, _mb: int = 0) -> void:
	_editor_state_ctrl._on_ent_pick(i, _at, _mb)
## —— 拆到 src/ui/editor_layout.gd 的委托（调用点保持不变） ——
func _build_editor_ui() -> void:
	_ensure_editor_controllers()
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

## 快捷键速查弹窗（? 键 / 状态栏「?」入口）
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
## 项目页外壳（src/ui/project_shell.gd）：资产/内容两视图互斥切换
func _build_project_view() -> void:
	_layout_ctrl._build_project_view()
## —— 拆到 src/map/side_actions.gd 的委托（调用点保持不变） ——

## 地图改名/复制——委托 side_actions 控制器
func _rename_map_by_name(old_name: String, new_name: String) -> void:
	_side_actions_ctrl._rename_map_by_name(old_name, new_name)

func _duplicate_map_by_name(old_name: String, new_name: String) -> void:
	_side_actions_ctrl._duplicate_map_by_name(old_name, new_name)

func _scene_name(sid: String) -> String:
	return _side_actions_ctrl._scene_name(sid)

## 协程透传：内部有未保存确认弹窗（await）。调用方必须也 await，
## 否则弹窗一弹出就返回，新图还没加载完（顶栏切图刷新曾踩过这个坑）。
func _open_map_by_name(map_name: String) -> void:
	await _side_actions_ctrl._open_map_by_name(map_name)
## —— 拆到 src/ui/project_picker.gd（调用点保持不变） ——

func _load_projects() -> void:
	_picker_ctrl._load_projects()

func _show_picker(err := "") -> void:
	_picker_ctrl._show_picker(err)
