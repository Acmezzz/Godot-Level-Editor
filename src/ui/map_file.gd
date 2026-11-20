extends RefCounted
## 地图文件生命周期控制器：新建/打开/保存/改名（纯改名，引用不迁移）/
## 自动保存/试玩/尺寸/导出。状态经宿主访问；写盘统一走 MapStore
## （.tmp 原子替换，正式保存带 .history 轮转备份）。
const MapExport := preload("res://src/map/map_export.gd")
const UiKitScript := preload("res://src/ui/ui_kit.gd")
const UiThemeScript := preload("res://src/ui/ui_theme.gd")
const K := preload("res://src/core/constants.gd")
const MapStore := preload("res://src/map/map_store.gd")

var app   # 宿主引用

func _init(host) -> void:
	app = host

const AUTOSAVE_INTERVAL_MS := 120000
var _last_autosave_msec := 0
var _opened_mtime := 0   # A4.3：打开地图时记录的磁盘 mtime（保存时对比检测外部改动）
var _last_alive_poll := 0   # PF-04：存活轮询节流
var _play_pid := 0
var _play_started_msec: int = 0
## 最近一次在新建/重命名弹窗里确认的名字（顶栏常驻名字框已移除，这里记住值供预填）
var _name_memo := ""

## 地图文件生命周期——新建/打开/保存/改名（纯改名，引用不迁移）/自动保存/试玩/尺寸/导出
func confirm_discard(action: String) -> bool:
	if not app.map_loaded or not app.canvas.modified_flag:
		return true
	var dlg := ConfirmationDialog.new()
	dlg.title = "未保存的修改"
	dlg.dialog_text = "地图 %s 有未保存修改。\n继续%s将丢失这些修改。" % [app.cur_map_name, action]
	# 自动保存草稿存得进、捞不出——放弃修改时至少把草稿路径说出来，
	# 否则用户以为这份保险不存在。草稿在「打开」里同样可被识别并归位（见 load_map_file）。
	var draft_path := str(app.manifest.get("_maps_dir", "")).path_join(str(app.cur_map_name) + ".autosave.json")
	if FileAccess.file_exists(draft_path):
		dlg.dialog_text += "\n\n最近一次自动保存的草稿在：\n%s\n放弃后仍可从「打开」中载入它找回内容。" % draft_path
	dlg.ok_button_text = "放弃修改并继续"
	dlg.cancel_button_text = "取消"
	# 中文正文需要足够宽度，否则 ConfirmationDialog 的 Label 会被压成一条看不见的窄条
	dlg.min_size = Vector2i(460, 0)
	app.add_child(dlg)
	var answer := [false]
	dlg.confirmed.connect(func(): answer[0] = true)
	dlg.popup_centered()
	# 等对话框真正关闭：确认 → true，取消/关闭 → false
	while dlg.visible:
		await app.get_tree().process_frame
	dlg.queue_free()
	return answer[0]

## 通用确认框：删除/不可撤销动作统一走这里（文本与确定钮文案可定制）
func confirm_action(title: String, text: String, ok_text := "确定", _danger := false) -> bool:
	var dlg := ConfirmationDialog.new()
	dlg.title = title
	dlg.dialog_text = text
	dlg.ok_button_text = ok_text
	dlg.cancel_button_text = "取消"
	dlg.min_size = Vector2i(460, 0)
	app.add_child(dlg)
	var answer := [false]
	dlg.confirmed.connect(func(): answer[0] = true)
	dlg.popup_centered()
	while dlg.visible:
		await app.get_tree().process_frame
	dlg.queue_free()
	return answer[0]

## 新建地图：名字在弹窗里输入（顶栏已无常驻名字框）
func on_new() -> void:
	var shell: Dictionary = app._popup_body("新建地图", "名字同时作文件名与显示名。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var name_edit := LineEdit.new()
	# 记住上次填的名字，但已存在的名字不预填（否则一按确定必然撞重名）
	if _name_memo != "" and not FileAccess.file_exists(EditorManifest.map_path(app.manifest, _name_memo)):
		name_edit.text = _name_memo
	name_edit.placeholder_text = "地图名"
	body.add_child(UiKitScript.field_row("地图名", name_edit))
	var err_label := UiKitScript.text_label("", UiThemeScript.WARN, UiThemeScript.FS_SMALL)
	err_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	err_label.custom_minimum_size = Vector2(app.POPUP_BODY_W, 0)
	body.add_child(err_label)
	var btn_row := UiKitScript.hbox(8)
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	btn_row.add_child(UiKitScript.button("取消", func(): pop.hide(), "ghost"))
	btn_row.add_child(UiKitScript.button("确定",
		func(): create_map_from_dialog(name_edit, err_label, pop), "primary"))
	name_edit.text_submitted.connect(func(_t: String): create_map_from_dialog(name_edit, err_label, pop))
	body.add_child(btn_row)
	app._open_popup(pop)

## 新建弹窗确定：校验 → 未保存确认 → 载入空图
func create_map_from_dialog(name_edit: LineEdit, err_label: Label, pop: PopupPanel) -> void:
	var n: String = name_edit.text.strip_edges()
	if n == "":
		err_label.text = "先填地图名"
		return
	if not EditorManifest.is_valid_map_name(n):
		err_label.text = "地图名不合法：不能含 / \\ : * ? \" < > | 或以 . 开头"
		return
	if FileAccess.file_exists(EditorManifest.map_path(app.manifest, n)):
		err_label.text = "同名地图已存在：换个名字，或直接打开它"
		return
	err_label.text = ""
	_name_memo = n
	# 先收新建弹窗再开确认框：确认框是模态窗口，会让新建弹窗失焦自动 hide，
	# 而 hide 连带 queue_free——之后确认框还要 await，留着也会被释放。
	pop.hide()
	if not await confirm_discard("新建"):
		return
	app.canvas.set_thumbs(app._entity_thumbs())
	await app.canvas.load_data(MapStore.new_map(n, K.DEFAULT_MAP_W, K.DEFAULT_MAP_H), n)
	app.cur_map_name = n
	app.cur_map_path = EditorManifest.map_path(app.manifest, n)
	_opened_mtime = 0
	app._sync_play_cfg_to_map()
	app._set_map_loaded(true)
	app.canvas.undo_stack.clear()
	app.canvas.redo_stack.clear()
	app._set_status(" 新建空地图 " + n + "（先保存再试玩）")

## 重命名当前地图：弹窗输入新名（顶栏名字框已移除，就地改名入口改到这里）
func on_rename() -> void:
	if not app.map_loaded:
		app._set_status("无地图：先新建或打开一张地图")
		return
	var old_name: String = _effective_map_name()
	if old_name == "":
		app._set_status("当前地图没有名字，无法重命名")
		return
	var shell: Dictionary = app._popup_body("重命名地图", "只改文件名与显示名，跨图引用不迁移；还没存过盘的新图会按新名直接保存。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var name_edit := LineEdit.new()
	# 当前名就是上次「新建」时填的名字（打开/改名也会同步 _name_memo）
	name_edit.text = old_name
	name_edit.placeholder_text = "地图名"
	body.add_child(UiKitScript.field_row("新名字", name_edit))
	var err_label := UiKitScript.text_label("", UiThemeScript.WARN, UiThemeScript.FS_SMALL)
	err_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	err_label.custom_minimum_size = Vector2(app.POPUP_BODY_W, 0)
	body.add_child(err_label)
	var btn_row := UiKitScript.hbox(8)
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	btn_row.add_child(UiKitScript.button("取消", func(): pop.hide(), "ghost"))
	btn_row.add_child(UiKitScript.button("确定",
		func(): rename_current_from_dialog(old_name, name_edit, err_label, pop), "primary"))
	body.add_child(btn_row)
	app._open_popup(pop)

## 重命名弹窗确定：校验 → MapStore.rename_map → 同步当前名/路径
func rename_current_from_dialog(old_name: String, name_edit: LineEdit, err_label: Label, pop: PopupPanel) -> void:
	var nn: String = name_edit.text.strip_edges()
	if nn == "" or nn == old_name:
		pop.hide()
		return
	if not EditorManifest.is_valid_map_name(nn):
		err_label.text = "地图名不合法：不能含 / \\ : * ? \" < > | 或以 . 开头"
		return
	# 真正的文件级改名（含「未落盘 → 按新名写盘」）统一走 rename_map_now
	var was_on_disk := FileAccess.file_exists(EditorManifest.map_path(app.manifest, old_name))
	var err := rename_map_now(old_name, nn, true)
	if err != "":
		err_label.text = "改名失败：" + err
		return
	pop.hide()
	if was_on_disk:
		app._set_status("已改名：%s → %s（引用未迁移）" % [old_name, nn])
	else:
		app._set_status("已改名并保存：%s → %s（原图未落盘，已按新名写入磁盘）" % [old_name, nn])

## 真正的地图重命名：改文件（或按新名落盘）+ 同步当前编辑身份。
## 返回错误信息，"" = 成功。allow_write_unsaved 允许「原图还没落盘」时把画布内容按新名写盘
## （只有当前正在编辑的那张图才有内容可写；清单里的幽灵条目不能凭空造文件）。
func rename_map_now(old_name: String, new_name: String, allow_write_unsaved := false) -> String:
	var nn := new_name.strip_edges()
	if nn == "" or nn == old_name:
		return ""
	if not EditorManifest.is_valid_map_name(nn):
		return "名称非法"
	var old_path := EditorManifest.map_path(app.manifest, old_name)
	var new_path := EditorManifest.map_path(app.manifest, nn)
	if new_path == "":
		return "名称非法"
	if FileAccess.file_exists(new_path):
		return "同名地图已存在"
	var is_current: bool = app.map_loaded and old_name == _effective_map_name()
	var on_disk := old_path != "" and FileAccess.file_exists(old_path)
	if on_disk:
		var err: String = app.MapStore.rename_map(app.manifest, old_name, nn)
		if err != "":
			return err
	elif allow_write_unsaved and is_current:
		# 原图未落盘（新建后还没保存）：改名必须真正落地，否则只改内存名 =
		# 面板显示新名、磁盘上始终没文件，用户看到的「重命名」是假的。
		var data: Dictionary = app.canvas.extract()
		if data.is_empty():   # 重建窗口哨兵：此刻写盘会把空图落成新文件
			return " 地图重建中，请稍后再试"
		data.meta.name = nn
		if not app.MapStore.write(app.manifest, nn, data):
			return "无法写入 " + new_path
	else:
		return "原图不存在（先保存该地图）"
	if is_current:
		_name_memo = nn
		app.cur_map_name = nn
		app.cur_map_path = new_path
		app.canvas.cur_map_name = nn
		if app.canvas.map_data.has("meta"):
			app.canvas.map_data["meta"]["name"] = nn
		_opened_mtime = FileAccess.get_modified_time(new_path)
		# 刚才已把内容写进新文件：脏标记与自动保存计时归零，
		# 否则状态栏还挂着「未保存」、两分钟后又多写一份 .autosave.json。
		if not on_disk:
			app.canvas.modified_flag = false
			_last_autosave_msec = Time.get_ticks_msec()
		app._sync_play_cfg_to_map()
	return ""

func on_open() -> void:
	if not await confirm_discard("打开另一张地图"):
		return
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.current_dir = str(app.manifest.get("_maps_dir", ""))
	fd.add_filter("*.json")
	fd.file_selected.connect(load_map_file)
	app.add_child(fd)
	fd.popup_centered(Vector2i(700, 500))

func load_map_file(p: String) -> void:
	# load_data 是协程（节点重建中间 await 一帧）：必须等它完成，否则切图刚返回时
	# 实体还在重建中——内容页 after_switch 刷新会拿到半重建的画布（列表/点选全乱）。
	var result: Dictionary = app.MapStore.read_path(p, app.manifest)
	if not result.ok:
		app._set_status(" 打开失败: " + _format_issues(result.errors))
		return
	var data: Dictionary = result.data
	if not result.warnings.is_empty():
		app._set_status(" 地图已打开但有兼容警告: " + _format_issues(result.warnings))
	# 草稿归位——打开 .autosave.json 读草稿数据，但名字/路径/名字框归位正式名；
	# 之后 Ctrl+S 写回正式文件，草稿自然变旧失效
	var was_draft := str(p.get_file()).ends_with(".autosave.json")
	var base := p.get_file().get_basename()
	if was_draft:
		base = base.trim_suffix(".autosave")
		p = EditorManifest.map_path(app.manifest, base)
	_opened_mtime = FileAccess.get_modified_time(p)
	app.canvas.set_thumbs(app._entity_thumbs())
	await app.canvas.load_data(data, base)
	app.cur_map_name = base
	app._sync_play_cfg_to_map()
	app.cur_map_path = p
	_name_memo = base
	app._set_map_loaded(true)
	app.canvas.undo_stack.clear()
	app.canvas.redo_stack.clear()
	var tcount := 0
	for lid in (data.get("tiles", {}) as Dictionary):
		tcount += ((data.get("tiles", {}) as Dictionary)[lid] as Array).size()
	var objs: Array = data.get("objects", [])
	app._set_status(" 已打开 %s%s（%d 瓦片 / %d 摆放物）" % [
		base, "（草稿归位，保存写回正式文件）" if was_draft else "", tcount, objs.size()])

func _format_issues(issues: Array) -> String:
	var lines: Array[String] = []
	for issue in issues:
		lines.append("%s: %s" % [str(issue.get("path", "map")), str(issue.get("message", "invalid data"))])
	return "; ".join(lines)

## 当前地图名的兜底对齐：app.cur_map_name 与 canvas.cur_map_name 两处记录，以 canvas 为准
func _effective_map_name() -> String:
	var n: String = str(app.cur_map_name).strip_edges()
	var cname: String = str(app.canvas.cur_map_name)
	if cname != "" and cname != n:
		var cpath := EditorManifest.map_path(app.manifest, cname)
		if FileAccess.file_exists(cpath):
			app.cur_map_name = cname
			app.cur_map_path = cpath
			_opened_mtime = FileAccess.get_modified_time(cpath)
			return cname
	return n

## 保存当前地图；返回是否成功（试玩前依赖它决定是否继续）
func on_save() -> bool:
	if not app.map_loaded:
		app._set_status(" 无地图：先新建或打开一张地图")
		return false
	var n: String = _effective_map_name()
	if n == "":
		app._set_status(" 当前地图没有名字：先「新建地图」并填名字")
		return false
	if not EditorManifest.is_valid_map_name(n):
		app._set_status(" 地图名不合法：不能含 / \\ : * ? \" < > | 或以 . 开头")
		return false
	var data: Dictionary = app.canvas.extract()
	if data.is_empty():   # 重建窗口哨兵：绝不能把空快照写盘
		app._set_status(" 地图重建中，保存已跳过：请稍后再试")
		return false
	data.meta.name = n
	var path := EditorManifest.map_path(app.manifest, n)
	if path == "":
		app._set_status(" 地图名不合法: " + n)
		return false
	# 外部变更检测——打开后磁盘 mtime 变了 = 别处改过这份文件（本次保存会覆盖外部改动）
	var ext_changed := _opened_mtime > 0 and FileAccess.file_exists(path) \
		and FileAccess.get_modified_time(path) != _opened_mtime
	# 写盘收敛到 MapStore 单入口（.tmp 原子替换，中途崩溃不留半截 JSON）
	if not app.MapStore.write(app.manifest, n, data):
		app._set_status(" 保存失败: " + path)
		return false
	_opened_mtime = FileAccess.get_modified_time(path)
	# 画布与 app 的地图名必须同步：跨图配对/撤销等都以 app.canvas.cur_map_name 为来源
	app.canvas.cur_map_name = n
	app.canvas.map_data["meta"] = data.meta
	app.cur_map_name = n
	app.cur_map_path = path
	app._sync_play_cfg_to_map()
	app.canvas.modified_flag = false
	_last_autosave_msec = Time.get_ticks_msec()
	var tcount2 := 0
	for lid2 in (data.get("tiles", {}) as Dictionary):
		tcount2 += ((data.get("tiles", {}) as Dictionary)[lid2] as Array).size()
	var msg := " 已保存 %s（%d 瓦片 / %d 摆放物）" % [n, tcount2, (data.get("objects", []) as Array).size()]
	if ext_changed:
		msg += "；注意：磁盘文件在打开后被外部修改过，本次保存覆盖了外部改动"
	app._set_status(msg)
	return true

## 自动保存：有未保存修改且距上次保存超过间隔时写入 .autosave.json

func maybe_autosave() -> void:
	if not app.map_loaded or not app.canvas.modified_flag or app.cur_map_name == "":
		return
	if Time.get_ticks_msec() - _last_autosave_msec < AUTOSAVE_INTERVAL_MS:
		return
	var data: Dictionary = app.canvas.extract()
	if data.is_empty():   # 重建窗口哨兵：本轮跳过，下个周期再存
		return
	data.meta.name = app.cur_map_name
	data["_autosave_of"] = app.cur_map_name
	var path := str(app.manifest.get("_maps_dir", "")).path_join(app.cur_map_name + ".autosave.json")
	# 自动保存同样走原子写
	if not app.MapStore.write_json(path, data):
		return
	_last_autosave_msec = Time.get_ticks_msec()
	app._set_status(" 已自动保存草稿 → %s.autosave.json" % app.cur_map_name)

func on_play(spawn_tiles: Vector2i = Vector2i(-1, -1)) -> void:
	if not app.map_loaded:
		app._set_status(" 无地图：先新建或打开一张地图")
		return
	if _effective_map_name() == "":
		app._set_status(" 试玩前先「新建地图」并填名字")
		return
	if not on_save():
		app._set_status(" 试玩中止：地图未保存成功")
		return
	var res := Playtest.launch_tracked(app.manifest, app.cur_map_path, app._play_args(spawn_tiles))
	if not res.get("ok", false):
		app._set_status(" 试玩失败: " + str(res.get("error", "")))
		return
	_play_pid = int(res.get("pid", 0))
	_play_started_msec = Time.get_ticks_msec()
	app._set_status(" 试玩启动: " + app.cur_map_path.get_file() + "（游戏退出后此处会提示）")

## 试玩进程跟踪：退出后回报一次（Windows tasklist 轮询）

func poll_playtest() -> void:
	# is_alive 是阻塞的 tasklist 调用，每帧轮询会卡主线程——1s 节流
	if Time.get_ticks_msec() - _last_alive_poll < 1000:
		return
	_last_alive_poll = Time.get_ticks_msec()
	if _play_pid <= 0:
		return
	# 刚启动的头几秒 tasklist 可能还查不到，先跳过
	if Time.get_ticks_msec() - _play_started_msec < 4000:
		return
	if Playtest.is_alive(_play_pid):
		return
	var secs := int((Time.get_ticks_msec() - _play_started_msec) / 1000.0)
	_play_pid = 0
	# 试玩日志尾随——游戏侧写 editor/playtest.log，退出后取最后几行（无文件 = 原消息）
	var tail := Playtest.log_tail(str(app.manifest.get("_dir", "")), 4)
	if tail != "":
		app._set_status(" 试玩退出（%d 秒）· 日志: %s" % [secs, tail.replace("\n", " | ")])
	else:
		app._set_status(" 试玩进程已退出（运行 %d 秒）" % secs)

## 试玩配置弹窗（v7）：清单 playtest.flags/params 声明驱动，替代写死的 dash/glide/hp。
## flags → 勾选框（启用时启动参数原样追加 flag.arg）；params → SpinBox（追加 arg 以 %d 填数）。
## 值只存编辑器本地 prefs（键 = flag/param id），不写进地图 JSON；清单未声明 = 空态提示。
func _open_play_cfg() -> void:
	if not app.map_loaded:
		app._set_status("无地图：先新建或打开一张地图")
		return
	var pt: Dictionary = app.manifest.get("playtest", {}) if app.manifest is Dictionary else {}
	var flags: Array = pt.get("flags", []) if pt.get("flags", null) is Array else []
	var params: Array = pt.get("params", []) if pt.get("params", null) is Array else []
	var shell = app._popup_body("试玩配置 —— %s" % app.cur_map_name,
		"只存编辑器本地，不写进地图 JSON。声明在清单 playtest.flags / playtest.params。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	if flags.is_empty() and params.is_empty():
		body.add_child(app.UiKitScript.hint_label(
			"清单未声明 playtest 项——在 editor_manifest.json 加 \"playtest\" 后重开清单（示例见 GAME_SIDE_STANDARD §试玩）。",
			app.POPUP_BODY_W))
	var states := {}   # {id: Callable} 应用时逐项收集（勾选=布尔，数字=整数）
	for f in flags:
		var fd: Dictionary = f
		var fid := str(fd.get("id", ""))
		var cb := CheckBox.new()
		cb.text = str(fd.get("name", fid))
		cb.button_pressed = bool(app.play_cfg.get(fid, false))
		body.add_child(cb)
		states[fid] = func() -> Variant: return cb.button_pressed
	for p2 in params:
		var pd: Dictionary = p2
		var pid := str(pd.get("id", ""))
		var sp := SpinBox.new()
		sp.min_value = float(pd.get("min", 0))
		sp.max_value = float(pd.get("max", 999999))
		sp.step = 1
		sp.value = float(int(app.play_cfg.get(pid, int(pd.get("def", 0)))))
		body.add_child(app.UiKitScript.field_row(str(pd.get("name", pid)), sp, UiKitScript.LABEL_W))
		states[pid] = func() -> Variant: return int(sp.value)
	var btn_row = app.UiKitScript.hbox(8)
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	btn_row.add_child(app.UiKitScript.button("取消", func(): pop.hide(), "ghost"))
	var apply_cfg := func():
		var cfg := {}
		for sid in states:
			cfg[sid] = (states[sid] as Callable).call()
		app.play_cfg = cfg
		app._prefs[app.cur_map_name] = app.play_cfg
		app._save_prefs()
		pop.hide()
		app._set_status("试玩配置已应用（仅影响试玩启动参数）")
	btn_row.add_child(app.UiKitScript.button("应用", apply_cfg, "primary"))
	body.add_child(btn_row)
	app._open_popup(pop)

func _play_args(spawn_tiles := Vector2i(-1, -1)) -> PackedStringArray:
	var out: PackedStringArray = []
	var pt: Dictionary = app.manifest.playtest if (app.manifest is Dictionary and app.manifest.playtest is Dictionary) else {}
	var flags: Array = pt.get("flags", []) if pt.get("flags", null) is Array else []
	var params: Array = pt.get("params", []) if pt.get("params", null) is Array else []
	for f in flags:
		var fd: Dictionary = f
		var fid := str(fd.get("id", ""))
		if bool(app.play_cfg.get(fid, false)) and str(fd.get("arg", "")) != "":
			out.append(str(fd.get("arg")))
	for p2 in params:
		var pd: Dictionary = p2
		var pid := str(pd.get("id", ""))
		if app.play_cfg.has(pid):
			var v := int(app.play_cfg.get(pid, 0))
			if v != int(pd.get("def", 0)):
				var arg := str(pd.get("arg", "%d"))
				out.append(arg % v if arg.contains("%d") else arg)
	if spawn_tiles.x >= 0 and spawn_tiles.y >= 0:
		out.append("--spawnx=%d" % spawn_tiles.x)
		out.append("--spawny=%d" % spawn_tiles.y)
	return out


## 试玩配置（v7）：prefs 由 {abilities:[],hp} 旧形态展平为 {flag_id: bool, param_id: int}。
## 旧键 abilities[] 展开成对应 flag id 勾选、hp 落到 hp 键——与旧 CLI 参数一一对应。
func _sync_play_cfg_to_map() -> void:
	var raw = app._prefs.get(app.cur_map_name, null)
	if not (raw is Dictionary):
		app.play_cfg = {}
		return
	var cfg := {}
	var old_ab = (raw as Dictionary).get("abilities", null)
	if old_ab is Array:
		for x in (old_ab as Array):
			cfg[str(x)] = true
	var old_hp = (raw as Dictionary).get("hp", null)
	if old_hp != null:
		cfg["hp"] = int(old_hp)
	for k in (raw as Dictionary):
		if not cfg.has(k):
			cfg[k] = (raw as Dictionary)[k]
	app.play_cfg = cfg
	app._prefs[app.cur_map_name] = cfg
	app._save_prefs()
