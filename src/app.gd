extends Control
## 独立关卡编辑器应用（Godot EXE）：
## 启动 → 读 user:// 项目列表 → 自动打开上次项目，否则进项目选择页；
## 选定项目后搭界面：顶栏（设置▾ / 地图▾+三模式 / 试玩）、左栏（层下拉+调色板）、画布、状态栏。
## 不绑定具体游戏：多个工程并行管理，顶栏「设置 ▾ → 切换项目…」切换。

const SettingsCfg := "user://settings.cfg"
const ProjectShellScript := preload("res://src/ui/project_shell.gd")
const ProjectPicker := preload("res://src/ui/project_picker.gd")
const ImageProbe := preload("res://src/assets/image_probe.gd")
const UiThemeScript := preload("res://src/ui/ui_theme.gd")
const UiKitScript := preload("res://src/ui/ui_kit.gd")
const MapStore := preload("res://src/map/map_store.gd")
const EdgeRef := preload("res://src/map/edge_ref.gd")   # §7.4：格边身份（选点确认后对准）

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
var _map_file_ctrl   # 地图文件生命周期
var _playtest_ctrl  # 试玩启动与加载状态
var _editor_state_ctrl   # canvas/editor_state.gd 控制器（状态流）
var _layout_ctrl   # ui/editor_layout.gd 控制器（界面搭建）
var _picker_ctrl   # ui/project_picker.gd 控制器（项目选择页）
var _tile_replace_ctrl   # ui/tile_replace_dialog.gd 控制器（E2 批量替换瓦片）
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
	_load_prefs()
	_picker_ctrl._load_projects()
	_ensure_editor_controllers()
	manifest = _load_last_project()
	get_tree().auto_accept_quit = false
	if manifest.is_empty() or manifest.has("_error"):
		_picker_ctrl._show_picker(manifest.get("_error", ""))
	else:
		_enter_project(cur_project_dir, manifest)

## 首次进入或项目切换后重建编辑器控制器；选择页阶段不提前创建，
## 避免布局控制器在宿主没有项目上下文时被误用（A1/E00）。
func _ensure_editor_controllers() -> void:
	if _picker_ctrl == null:
		_picker_ctrl = ProjectPicker.new(self)
	if _tile_replace_ctrl == null:
		_tile_replace_ctrl = preload("res://src/ui/tile_replace_dialog.gd").new(self)
	if _layout_ctrl == null:
		_layout_ctrl = preload("res://src/ui/editor_layout.gd").new(self)
	if _palette_ctrl == null:
		_palette_ctrl = preload("res://src/ui/palette_panel.gd").new(self)
	theme = UiThemeScript.build()

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
	# Ctrl+S / 地图菜单「保存」= 用户以为「全都存了」的入口：按 A2 顺序
	# 清单 → 内容 → 地图一次写完（只写地图会留下指向未落盘内容的引用）。
	return await _map_file_ctrl.save_all()

## E2：按区域选区批量替换瓦片（弹窗在 ui/tile_replace_dialog.gd）
func _open_tile_replace() -> void:
	if _tile_replace_ctrl == null:
		_tile_replace_ctrl = preload("res://src/ui/tile_replace_dialog.gd").new(self)
	_tile_replace_ctrl.open()

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
	var manual := 0
	var skipped := 0
	var corrupt := 0
	for p in pending:
		var pd: Dictionary = p
		var st := str(pd.get("status", ""))
		if st == "corrupt":
			corrupt += 1
			continue
		if st == "manual":
			# §4.4 四态：manual 里再分「目标已不在且无基线」（可跳过）与「内容对不上」（外部改变）
			if not (pd.get("external", []) as Array).is_empty():
				manual += 1
			elif not (pd.get("skipped", []) as Array).is_empty():
				skipped += 1
		elif st != "done":
			partial += 1
	if partial > 0:
		parts.append("%d 次未完成提交（已写文件保留，可同 ID 重试）" % partial)
	if skipped > 0:
		parts.append("%d 次提交的目标已不在（计划失效，可直接清理 editor/pending）" % skipped)
	if manual > 0:
		parts.append("%d 次提交有文件对不上（外部改过或写了一半，需人工复核 editor/pending）" % manual)
	if corrupt > 0:
		parts.append("%d 份提交日志已损坏读不出（editor/pending 下确认后可删除）" % corrupt)
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
	_canvas_dock_slot = null
	project_shell = null
	asset_panel = null
	# 控制器由 editor_layout 建界面时赋值，界面已释放就必须全部置空，
	# 否则切项目回选择页后 _process / 菜单委托仍会打到旧控制器上（见 6b0c5de）。
	_playtest_ctrl = null
	_map_file_ctrl = null
	_editor_state_ctrl = null
	_layout_ctrl = null
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

func _save_prefs() -> bool:
	if MapStore.Recovery.write_json(PREFS_PATH, _prefs):
		return true
	push_warning("偏好写盘失败: " + PREFS_PATH)
	return false

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
# 最近使用瓦片（会话内最多 8 格；笔刷选择时记录，调色板置顶显示）
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
	# E1 选点会话独占 Esc/Enter：画布在 SubViewport 里收不到键盘，只能在这里接。
	# Esc = 取消（不提交、回原视图）；Enter = 确认当前候选（没候选时不响应）。
	if canvas != null and canvas.pick_mode_active:
		if k == KEY_ESCAPE:
			_end_canvas_pick(false)
			get_viewport().set_input_as_handled()
			return
		if k == KEY_ENTER or k == KEY_KP_ENTER:
			if str(canvas.pick_mode_code) != "":
				_end_canvas_pick(true)
				get_viewport().set_input_as_handled()
			return
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
		# 内容视图的 Ctrl+Z 只撤内容字段差量（ContentKey）：地图条目一条都不动。
		# 输入框里让位给控件自己的文本撤销；栈顶不是内容改动就放行（不吞键）。
		if ctrl and k == KEY_Z and not (focus is LineEdit or focus is TextEdit) \
				and project_shell._view == "content" and canvas != null:
			match canvas._undo_history_ctrl.undo_content_only():
				"done":
					_set_status(" 已撤销内容字段改动")
				"refused":
					_set_status(" 该内容文件已被外部修改：未回滚（请重开后再改）")
				_:
					return
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
			if await canvas.redo():
				_set_status(" 已重做")
			elif canvas._undo_history_ctrl.refused_external:
				_set_status(" 该内容文件已被外部修改：未重做（请重开后再改）")
			else:
				_set_status(" 没有可重做的操作")
		else:
			if await canvas.undo():
				_set_status(" 已撤销（剩余 %d 步）" % canvas.undo_step_count())
			elif canvas._undo_history_ctrl.refused_external:
				_set_status(" 该内容文件已被外部修改：未撤销（请重开后再改）")
			else:
				_set_status(" 没有可撤销的操作")
		get_viewport().set_input_as_handled()
		return
	if ctrl and k == KEY_Y:
		if await canvas.redo():
			_set_status(" 已重做")
		elif canvas._undo_history_ctrl.refused_external:
			_set_status(" 该内容文件已被外部修改：未重做（请重开后再改）")
		else:
			_set_status(" 没有可重做的操作")
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
			# 1 秒窗口内连续微调合成一个撤销步：差量条目按同一批实例码合并（merge=true）；
			# 窗口首个按键才取 before，其余沿用起点状态。
			var fresh := now - _nudge_undo_msec > 1000
			_nudge_undo_msec = now
			var pre: Dictionary = canvas._undo_history_ctrl.inst_rows(sel)
			var via_delta := bool(pre.get("ok", false))
			if not via_delta and fresh:
				canvas.push_undo()
			for s in sel:
				var n := s as EntityNode
				if n and is_instance_valid(n):
					n.position += canvas.grid_dir_px(delta.x, delta.y)
			if via_delta:
				canvas._undo_history_ctrl.inst_commit(pre.get("rows", {}), not fresh)
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
			if canvas.duplicate_selected_at_offset(srcs, Vector2i(1, 0)):
				get_viewport().set_input_as_handled()
				return
	# Ctrl+N/O 新建/打开
	if ctrl and k == KEY_N:
		_map_file_ctrl.on_new()
		get_viewport().set_input_as_handled()
		return
	if ctrl and k == KEY_O:
		_map_file_ctrl.on_open()
		get_viewport().set_input_as_handled()
		return
	if k == KEY_ESCAPE and canvas.world_region_mode and not canvas._paste_mode:
		_toggle_world_region_mode()
		get_viewport().set_input_as_handled()
		return
	# Esc 取消区域粘贴预览
	if k == KEY_ESCAPE and canvas._paste_mode:
		canvas.cancel_paste_mode()
		_set_status(" 已取消区域粘贴预览")
		get_viewport().set_input_as_handled()
		return
	if canvas._geometry_draw.active() and k in [KEY_ESCAPE, KEY_ENTER, KEY_KP_ENTER]:
		if k == KEY_ESCAPE:
			canvas._geometry_draw.cancel()
		else:
			canvas._geometry_draw.finish()
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
	_layout_ctrl._refresh_view_toggles()


## 框选开关：打开后画布左键拖动进入框选（不用快捷键）
func _toggle_select_mode() -> void:
	if canvas == null:
		return
	if canvas.world_region_mode:
		_toggle_world_region_mode()
	canvas.select_mode = not canvas.select_mode
	_set_status("框选已%s —— 左键拖动框选，选中后可整组拖动" % ("打开" if canvas.select_mode else "关闭"))
	_layout_ctrl._refresh_view_toggles()

func _toggle_world_region_mode() -> void:
	canvas.cancel_preview_gesture()
	canvas.cancel_paste_mode()
	canvas.world_region_mode = not canvas.world_region_mode
	canvas._world_region_move.selection = Rect2()
	canvas._region_sel = Rect2i()
	canvas._region_layer = ""
	if canvas.world_region_mode:
		canvas.select_mode = false
	_set_status("跨层选区：左键框选，框内拖动，Ctrl+C 复制，右键清除。" if canvas.world_region_mode else "跨层选区已关闭。")
	canvas.queue_redraw()
	_layout_ctrl._refresh_view_toggles()

## 吸附开关：关掉后摆放/拖动落在任意像素位置（数据存浮点格坐标，亚格摆放）
func _toggle_snap() -> void:
	if canvas == null:
		return
	canvas.snap_to_grid = not canvas.snap_to_grid
	_set_status("吸附已%s —— %s" % [
		"打开" if canvas.snap_to_grid else "关闭",
		"摆放/拖动对齐到格" if canvas.snap_to_grid else "可放在任意像素位置（坐标存浮点）"])
	_layout_ctrl._refresh_view_toggles()

## 视图开关按钮的按下态与画布状态保持同步
func _cut() -> void:
	if not map_loaded:
		_set_status("无地图：先新建或打开一张地图")
		return
	if canvas.world_region_mode:
		_set_status("跨层框选仅用于搬动。剪切请先退出该模式。")
		return
	if canvas.place_kind == "object":
		canvas.cut_selection()
	else:
		canvas.cut_region()

func _copy() -> void:
	if not map_loaded:
		_set_status("无地图：先新建或打开一张地图")
		return
	if canvas.world_region_mode:
		canvas._world_region_move.copy()
		return
	if canvas.place_kind == "object":
		canvas.copy_selection()
	else:
		canvas.copy_region()

func _paste() -> void:
	if not map_loaded:
		_set_status("无地图：先新建或打开一张地图")
		return
	if canvas._last_copy_region and canvas._region_clip.get("world", false):
		canvas.cancel_preview_gesture()
		canvas._paste_mode = true
		canvas.queue_redraw()
		_set_status("跨层区域粘贴预览：左键落位，右键或 Esc 取消。")
		return
	if canvas.world_region_mode:
		_set_status("粘贴普通剪贴板前请退出跨层选区。")
		return
	# 区域剪贴板走幽灵预览（左键落位），实体剪贴板直接贴到光标处
	if canvas._last_copy_region and not canvas._region_clip.is_empty():
		if not canvas._region_ops_ctrl.region_clip_matches():
			_set_status("当前瓦片层或格几何与区域剪贴板不兼容")
			return
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
	_map_file_ctrl.maybe_autosave()
	_playtest_ctrl.poll_playtest()

# 按实例码找实例节点（层栈化后跨全部层容器查）
# —— 实体属性（面板已删，只剩碰撞生成弹窗与选中状态维护） ——
func _on_entity_selected(n: EntityNode) -> void:
	# 用户看到的是画布下沿那条极简信息条；参数编辑走内容编辑器与资产目录。
	selected_spr = n
	_layout_ctrl._refresh_sel_bar()
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
		_editor_state_ctrl.sync_ui()
		# 地图载入后：清掉引导态，换成「未选中实体」的提示
		selected_spr = null
	_layout_ctrl._refresh_dirty_badge()
	_layout_ctrl._refresh_tool_meta()
	_layout_ctrl._refresh_sel_bar()

# —— 模式切换：关卡 / 内容 / 资产 三个平级面板 + 旧的项目页外壳 ——
var _map_view: VBoxContainer = null
## E1：演出面板的画布停靠位（editor_layout 建在画布下方；停靠画布时控件搬进来）
var _canvas_dock_slot: PanelContainer = null
var project_shell = null        # ProjectShell（项目页外壳，含三个视图）
# 视图面板由 project_shell 持有；这里保留别名方便既有调用点
var asset_panel = null

## 模式切换：mode = map（关卡编辑器）/ content（内容编辑器）/ asset（资产目录）。
## 三个面板是平级关系，顶栏三个入口直接切，Esc 回关卡编辑器。
## E1：离开画布/内容时记快照，归来按身份校验恢复（目标已删则显示空态）。
func _set_mode(mode: String, focus_sid := "") -> void:
	if canvas != null and mode != "map":
		canvas._geometry_draw.cancel()
	# 选点会话只属于画布：切模式即中止（不提交、不回原视图、不触发取消回调——
	# 用户已经明确要去的那个视图才是落点）
	if mode != "map" and canvas != null and canvas.pick_mode_active:
		_pick_session = {}
		canvas.end_pick_mode()
		_layout_ctrl._refresh_pick_bar()
	# 离开内容页前提交待提交的 SpinBox 值（连续控件失焦才写盘，直接 Esc 切走会丢）；
	# 只冲刷控件值，暂存的新内容留到正式保存/试玩（A2）。
	if mode != "content" and project_shell != null and project_shell.content_editor != null:
		if not project_shell.content_editor.commit_fields():
			return
		# E1：记下定位（实例 + 展开的功能），回内容页时按身份恢复
		if str(project_shell._view) == "content":
			project_shell.remember_content_context()
	var on_map := mode == "map"
	# E1：停靠的演出面板跟着视图搬家。关卡视图不走 show_view（画布层直接上屏），
	# 这里补一次；内容/资产由 project_shell.show_view 统一同步。
	if on_map:
		_sync_steps_dock(mode)
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

## E1：停靠形态的演出面板跟随视图（画布 / 内容各有一套停靠位）。
## 没有打开中的停靠面板时是空操作。
func _sync_steps_dock(view: String) -> void:
	if project_shell == null or project_shell.content_editor == null:
		return
	project_shell.content_editor.sync_steps_dock(view)

# —— E1 临时选点会话：为引用字段在画布挑目标，确认才提交 ——
# 状态：{owner, accept, hint, on_confirm: Callable, on_cancel: Callable, prev_view, prev_focus}
var _pick_session := {}

## 开始选点：切回画布、进入选点模式；回调只在确认/取消时各调一次。
## prev_view/prev_focus 用于「取消后回到原视图与原表单焦点」。
## want_types（E2）：声明的 of 白名单，画布只认这些资产类型（空 = 不限）。
func _begin_canvas_pick(owner: String, accept: String, hint: String,
		on_confirm: Callable, on_cancel: Callable, want_types: Array = []) -> bool:
	if canvas == null or not map_loaded:
		_set_status("选点需要先打开一张地图")
		return false
	if canvas.pick_mode_active:
		_set_status("已经在选点：先确认或取消当前选择")
		return false
	var prev_view := str(project_shell._view) if project_shell != null else ""
	# 画布停靠形态直接在关卡视图里发起选点：归来落点应是画布，不是把面板拽回内容页
	if _map_view != null and _map_view.visible:
		prev_view = "map"
	# 焦点：取消后要回到「发起选点前正在输入的那个控件」（返回时恢复原表单与焦点）
	var prev_focus: Control = get_viewport().gui_get_focus_owner()
	_pick_session = {"owner": owner, "on_confirm": on_confirm, "on_cancel": on_cancel,
		"prev_view": prev_view, "prev_focus": prev_focus}
	_set_mode("map")
	canvas.begin_pick_mode(owner, accept, hint, want_types)
	_layout_ctrl._refresh_pick_bar()
	var what := "一条格边" if accept == "edge" else ("一格" if accept == "cell" else ("端口" if accept == "port" else "实例"))
	_set_status(hint + "：左键点%s，确认提交；Esc 取消" % what)
	return true

## 确认/取消选点：清理模式，回调各调一次；取消时回到原视图（表单已由宿主保留）。
func _end_canvas_pick(confirm: bool) -> void:
	if canvas == null or not canvas.pick_mode_active:
		return
	var code: String = str(canvas.pick_mode_code)
	var sess := _pick_session.duplicate()
	_pick_session = {}
	canvas.end_pick_mode()
	_layout_ctrl._refresh_pick_bar()
	var cb = sess.get("on_confirm" if confirm else "on_cancel", null)
	var back_view := str(sess.get("prev_view", ""))
	# 确认时把相机对到目标：切回项目页看表单前，用户能先看到自己刚指的那一格
	if confirm and code != "":
		if str(canvas.pick_mode_accept) == "cell":
			canvas.focus_cell_id(code)
		elif str(canvas.pick_mode_accept) == "edge":
			canvas.focus_edge(str(EdgeRef.edge_of(JSON.parse_string(code))))
		elif str(canvas.pick_mode_accept) == "port":
			var port = JSON.parse_string(code)
			if port is Dictionary:
				canvas.focus_entity_code(str(port.inst))
		else:
			canvas.focus_entity_code(code)
	# 回原视图但不重建表单（静默恢复）：控件与焦点都还在，只有内容视图的
	# 引用值真的变了才由宿主自己重建对应区块。
	if back_view != "" and back_view != "map" and project_shell != null:
		project_shell.show_view_quiet(back_view)
	if cb is Callable and (cb as Callable).is_valid():
		(cb as Callable).call(code if confirm else "")
	# 焦点回到发起时的控件（取消路径尤其重要：用户回来接着输入，不该重新点一遍）
	var pf = sess.get("prev_focus", null)
	if pf is Control and is_instance_valid(pf) and (pf as Control).is_inside_tree():
		(pf as Control).grab_focus()
	_set_status(("已选目标 " + _pick_label(code)) if confirm else "已取消选点")

## 选点结果显示：格边给「(x,y)-(x,y)」，其余原样（至少别把整串 JSON 糊在状态栏）。
func _pick_label(code: String) -> String:
	if str(canvas.pick_mode_accept) == "port" and code != "":
		var port = JSON.parse_string(code)
		return "%s · %s" % [port.inst, port.port] if port is Dictionary else code
	if str(canvas.pick_mode_accept) != "edge":
		return code
	var e := str(EdgeRef.edge_of(JSON.parse_string(code)))
	if e == "":
		return code
	return e.replace("|", "-")

## 画布点选候选时刷新确认条（只改候选，不提交）。
func _on_pick_candidate(code: String) -> void:
	_layout_ctrl._refresh_pick_bar()
	if code != "" and canvas != null:
		# 点中即把这条高亮告诉用户（状态栏），但值仍等「确认」才写
		_set_status("%s：已点 %s，按确认提交" % [str(canvas.pick_mode_hint), _pick_label(code)])

## 画布右键 = 取消选点
func _on_pick_cancelled() -> void:
	_end_canvas_pick(false)

## 顶栏三个面板入口的按下态：单一真相是 _set_mode 的入参，
## 不依赖按钮自己记状态（点 Esc 返回、点地图菜单的路径都要同步）。
func _sync_panel_buttons(mode: String) -> void:
	for nb in _nav_bars:
		if nb != null and is_instance_valid(nb):
			nb.set_mode(mode)

## 清单落盘；返回是否成功（await 结果）。地图保存前需要知道成功与否（D06）。
func _manifest_write_payload(source: Dictionary) -> Dictionary:
	var out := source.duplicate(true)
	for key in out.keys():
		if str(key).begins_with("_"):
			out.erase(key)
	for asset in (out.get("assets", []) as Array):
		if asset is Dictionary:
			asset.erase("atlas_abs")
	return preload("res://src/assets/builtin_kinds.gd").strip_from(out)

func _save_manifest_file_async(guard := Callable(), snapshot := {}, publish_key := "") -> bool:
	var source := manifest
	var baseline := JSON.stringify(_manifest_write_payload(source), "\t") if publish_key != "" else ""
	var out := _manifest_write_payload(source if snapshot.is_empty() else snapshot)
	var txt := JSON.stringify(out, "\t")
	var p := str(source.get("_dir", "")).path_join("editor/editor_manifest.json")
	var recovery := preload("res://src/map/recovery.gd")
	var observed := recovery.observe(p)
	if observed.state != "present":
		_set_status(" 清单保存中止：正式清单已消失或不可读")
		return false
	var seen := str(observed.digest)
	if seen != str(source.get("_manifest_digest", "")):
		if not await _confirm_action("外部改动",
			"清单文件在编辑器打开后被外部修改过。\n覆盖保存将丢失外部改动。", "覆盖保存"):
			_set_status(" 已取消保存（保留磁盘上的外部改动）")
			return false
	var expected_live := baseline if publish_key != "" else txt
	if (guard.is_valid() and not guard.call()) or not is_same(manifest, source) \
			or JSON.stringify(_manifest_write_payload(manifest), "\t") != expected_live:
		_set_status(" 清单保存中止：确认期间工作副本已变化")
		return false
	if recovery.digest(p) != seen:
		_set_status(" 清单保存中止：确认期间文件又被外部改写，请重新检查后再保存")
		return false
	# 清单写盘走 MapStore 原子写单入口
	if not MapStore.write_text(p, txt):
		_set_status(" 清单写入失败: " + p)
		return false
	if publish_key != "":
		manifest[publish_key] = snapshot[publish_key].duplicate(true)
	# 新补发的执行码已经随清单落盘，标记清掉（D6：避免每次内容视图 Ctrl+S 都重写清单）
	manifest.erase("_codes_issued")
	manifest.erase("_codes_issued_now")
	manifest["_manifest_digest"] = txt.sha256_text()
	return true


## —— 拆到 src/ui/editor_layout.gd 的委托（调用点保持不变） ——
func _build_editor_ui() -> void:
	_ensure_editor_controllers()
	_layout_ctrl._build_editor_ui()

## 状态栏唯一写入口：按当前视图分派——项目页（内容/资产）有自己的状态栏，
## 只写关卡那条会让内容页里「实例已不存在」这类提示看不见（标签此时是隐藏的）。
## 界面尚未建好/已释放（切项目的过渡窗口）时静默丢弃。
func _set_status(msg: String) -> void:
	if _in_project_view():
		project_shell._set_status(msg)
		return
	if _layout_ctrl != null:
		_layout_ctrl._set_status(msg)

func _open_popup(pop: PopupPanel, popup_size := Vector2i.ZERO, parent: Window = null) -> void:
	_layout_ctrl._open_popup(pop, popup_size, parent)

func _popup_body(title: String, subtitle := "") -> Dictionary:
	return _layout_ctrl._popup_body(title, subtitle)

## 快捷键速查弹窗（? 键 / 状态栏「?」入口）
func _open_shortcut_help() -> void:
	_layout_ctrl._open_shortcut_help()
func _scene_name(sid: String) -> String:
	return preload("res://src/assets/asset_decl.gd").name_of(manifest, sid)
