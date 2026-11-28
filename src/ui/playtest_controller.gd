extends RefCounted
## Starts games from committed documents or screen drafts and shows load status.

const UiKitScript := preload("res://src/ui/ui_kit.gd")
const Recovery := preload("res://src/map/recovery.gd")
const EntryStore := preload("res://src/content/content_store.gd")
const EntryFunctions := preload("res://src/content/function_decl.gd")
const References := preload("res://src/project/reference_index.gd")
const StartupTargets := preload("res://src/project/startup_targets.gd")

var app
var files: RefCounted
var _last_alive_poll := 0   # PF-04：存活轮询节流
var _play_pid := 0
var _play_started_msec: int = 0
var _play_program := ""
var _play_report_request := {}
var _play_report_result := {}
var last_run := {}

func _init(host, map_files: RefCounted) -> void:
	app = host
	files = map_files

func on_play(spawn_tiles: Vector2i = Vector2i(-1, -1), project_entry := false) -> void:
	if not _can_start_playtest():
		return
	if project_entry and not bool(app.manifest.get("playtest", {}).get("projectEntry", false)):
		return
	if app.manifest.get("playtest", {}).is_empty():
		app._set_status("此游戏还未声明试玩可执行文件。")
		return
	var input: Dictionary = await files.prepare_playtest_document(project_entry)
	if input.has("error"):
		app._set_status(input.error)
		return
	var play_path: String = input.path
	var digest: String = input.digest
	var args: PackedStringArray = PackedStringArray() if project_entry else _play_args(spawn_tiles)
	var subject := "项目入口" if project_entry else play_path.get_file()
	_start_playtest(play_path, digest, args, subject)

## Published resource entries leave the current editing session untouched.
func play_content_entry(entry: Dictionary, board := "") -> bool:
	if not Playtest.allows_entry(app.manifest, entry.function):
		return false
	if not board.is_empty() and (not Playtest.allows_content_map(app.manifest, entry.function) \
			or not StartupTargets.content_map_available(app.manifest, board)):
		app._set_status("试玩中止：所选地图已不可用。")
		return false
	var data := EntryStore.read(app.manifest, entry.function, entry.content)
	if not StartupTargets.is_project_destination(data, EntryFunctions.fn_code(app.manifest, entry.function)):
		app._set_status("试玩中止：所选项目内容不可用。")
		return false
	if not _published_manifest_current():
		return false
	var subject := "内容入口 %s / %s" % [entry.function, entry.content]
	return _start_playtest("", "", PackedStringArray([Playtest.entry_arg(entry.function, entry.content, board)]), subject)

func play_map_entry(target: Dictionary) -> bool:
	if not Playtest.allows_map_entry(app.manifest):
		return false
	if not StartupTargets.destination_available(app.manifest, Playtest.map_entry_domains(app.manifest), target):
		app._set_status("试玩中止：所选地图或入场端口已不可用。")
		return false
	if not _published_manifest_current():
		return false
	var subject := "地图入口 " + str(target.map)
	if target.has("port"):
		subject += " · %s / %s" % [target.inst, target.port]
	return _start_playtest("", "", PackedStringArray([Playtest.map_entry_arg(target)]), subject)

func play_view(view_id: String, draft := {}) -> bool:
	var is_draft := not draft.is_empty()
	var allowed := Playtest.allows_view_draft(app.manifest) if is_draft else Playtest.allows_view_entry(app.manifest)
	if not allowed:
		app._set_status("游戏未开放从屏幕启动试玩。")
		return false
	if not is_draft and not References.view_ids(app.manifest).has(view_id):
		app._set_status("试玩中止：所选屏幕已经不存在。")
		return false
	if not _published_manifest_current():
		return false
	if is_draft:
		return _start_playtest("", "", PackedStringArray(), "屏幕草稿 " + view_id, draft)
	return _start_playtest("", "", PackedStringArray([Playtest.view_entry_arg(view_id)]), "屏幕 " + view_id)

func _published_manifest_current() -> bool:
	var manifest_path := str(app.manifest._dir).path_join("editor/editor_manifest.json")
	var digest := EntryStore.file_digest(manifest_path)
	if digest != "" and digest == app.manifest.get("_manifest_digest", ""):
		return true
	app._set_status("试玩中止：磁盘清单已变化，请重新打开项目。")
	return false

func _can_start_playtest() -> bool:
	if _play_pid > 0 and Playtest.is_alive(_play_pid):
		app._set_status("已有试玩正在运行，请关闭该游戏后再启动")
		return false
	return true

func _start_playtest(play_path: String, digest: String, args: PackedStringArray, subject: String, draft := {}) -> bool:
	if not _can_start_playtest():
		return false
	Playtest.clear_view_draft(_play_report_request)
	var request := Playtest.request_report(app.manifest, digest)
	if bool(app.manifest.get("playtest", {}).get("report", false)) and request.is_empty():
		app._set_status("试玩中止：无法创建加载回执目录")
		return false
	if not draft.is_empty():
		var text := JSON.stringify(draft.merged({"version": Playtest.PROTOCOL, "token": request.token}))
		var path := Playtest.view_draft_path(request)
		if not Recovery.write_text(path, text):
			app._set_status("试玩中止：无法写入屏幕草稿快照")
			return false
		request["viewDigest"] = text.sha256_text()
		args.append(Playtest.view_entry_arg(draft.view.view_id, path))
	var play_res := Playtest.launch_tracked(app.manifest, play_path, args, request)
	if not play_res.get("ok", false):
		Playtest.clear_view_draft(request)
		app._set_status(" 试玩失败: " + str(play_res.get("error", "")))
		return false
	_play_pid = int(play_res.get("pid", 0))
	_play_started_msec = Time.get_ticks_msec()
	_play_program = str(play_res.get("program", ""))
	_play_report_request = request
	_play_report_result = {}
	last_run = {"entry": subject, "file": play_path, "digest": digest, "state": "进程已启动"}
	var track_note := "" if Playtest.tracking_available() else "（此平台无法跟踪进程退出）"
	app._set_status("试玩启动: %s %s%s" % [_play_program.get_file(), subject, track_note])
	return true

## 试玩进程跟踪：退出后回报一次（OS.is_process_running，无子进程）

func poll_playtest() -> void:
	# §5：查询本身已是系统调用（原 tasklist 子进程已移除），但仍按 1s 节流——
	# 退出回报不需要帧级精度，留着省一次每帧系统调用。
	if Time.get_ticks_msec() - _last_alive_poll < 1000:
		return
	_last_alive_poll = Time.get_ticks_msec()
	if _play_pid <= 0:
		return
	if not _play_report_request.is_empty() and _play_report_result.is_empty():
		_play_report_result = Playtest.read_report(_play_report_request)
		if not _play_report_result.is_empty():
			last_run.state = _play_report_summary()
			app._set_status(last_run.state)
	if not Playtest.tracking_available() or Playtest.is_alive(_play_pid):
		return
	var secs := int((Time.get_ticks_msec() - _play_started_msec) / 1000.0)
	var prog := _play_program
	_play_pid = 0
	if not _play_report_request.is_empty():
		_play_report_result = Playtest.read_report(_play_report_request)
	Playtest.clear_view_draft(_play_report_request)
	var who := prog.get_file()
	if not _play_report_request.is_empty():
		last_run.state = "已退出 · " + _play_report_summary()
	else:
		last_run.state = "已退出（%d 秒）· 未声明加载回执" % secs
	app._set_status("试玩 %s %s" % [who, last_run.state])

func open_release_check() -> void:
	var startup: Dictionary = app.manifest.get("startup", {})
	var target: Dictionary = startup.get("target", {})
	var shell: Dictionary = app._popup_body("检查与试玩",
		"先保存内容并检查结构，再从正式入口试玩。发布包由游戏侧打包与独立验证。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	body.add_child(_check_label("正式入口：" + (str(target.get("view", target.get("map", target.get("content", JSON.stringify(target))))) if not target.is_empty() else "由游戏决定")))
	if not last_run.is_empty():
		body.add_child(_check_label("最近试玩：%s · %s%s" % [last_run.entry, last_run.state,
			" · 数据 " + str(last_run.digest).left(8) if last_run.digest != "" else ""]))
	var actions := UiKitScript.hbox(6)
	body.add_child(actions)
	var run := UiKitScript.button("试玩正式入口", func():
		pop.hide()
		on_play(Vector2i(-1, -1), true))
	run.disabled = app.manifest.get("playtest", {}).get("projectEntry") != true
	actions.add_child(run)
	if app.manifest.has("startup"):
		actions.add_child(app.UiKitScript.button("设置正式入口…", func():
			pop.hide()
			preload("res://src/ui/startup_dialog.gd").open.call_deferred(app), "ghost"))
	if app.map_loaded:
		actions.add_child(app.UiKitScript.button("当前地图试玩参数…", func():
			pop.hide()
			open_configuration.call_deferred(), "ghost"))
	body.add_child(_check_label("检查读取正式文件；游戏侧动态行为请在试玩和发布包中确认。"))
	var list := ItemList.new()
	list.custom_minimum_size = Vector2(620, 290)
	body.add_child(list)
	var info := _check_label("")
	body.add_child(info)
	var refresh := func():
		list.clear()
		preload("res://src/map/map_store.gd").refresh_external_maps()
		var checked := preload("res://src/project/project_data_check.gd").check(app.manifest)
		var issues: Array = checked.get("issues", [])
		for issue in issues:
			var caption := "%s · %s：%s" % ["需修复" if issue.severity == "error" else "查看", issue.path, issue.message]
			var i := list.add_item(caption)
			list.set_item_tooltip(i, caption)
			list.set_item_metadata(i, issue)
		info.text = "正式数据通过结构检查（%d 条提示）" % issues.size() if checked.get("valid", false) else "结构检查未通过。"
	var locate := func(i: int):
		var issue: Dictionary = list.get_item_metadata(i)
		info.text = list.get_item_text(i)
		var path: String = issue.path
		if issue.has("function") and issue.has("content"):
			pop.hide()
			app._set_mode("content")
			var editor = app.project_shell.content_editor
			var ref_path: String = issue.get("reference", {}).get("path", "")
			if ref_path.begins_with("steps["):
				var tail := ref_path.substr(6)
				editor._steps.open_content(issue.function, issue.content, issue.get("map", ""), int(tail.get_slice("]", 0)),
					tail.get_slice("].", 1))
			else:
				editor.open_project_content(issue.function, issue.content, issue.get("map", ""))
			return
		if path.begins_with("views["):
			var idx := int(path.substr(6).get_slice("]", 0))
			var views: Array = app.manifest.get("views", [])
			if idx in range(views.size()):
				pop.hide()
				var view: Dictionary = views[idx]
				var elements: Array = view.get("layout", {}).get("elements", [])
				var at := path.find(".elements[")
				var item := int(path.substr(at + 10).get_slice("]", 0)) if at >= 0 else -1
				var jump := {"element": elements[item].get("id", "")} if item in range(elements.size()) else {}
				preload("res://src/ui/reference_view_library.gd").open.call_deferred(app, view.view_id, jump)
				return
		var parts: PackedStringArray = str(issue.path).split(".")
		if parts[0] in ["startup", "viewports", "eventLayers"]:
			pop.hide()
			match parts[0]:
				"startup": preload("res://src/ui/startup_dialog.gd").open.call_deferred(app)
				"viewports": preload("res://src/ui/viewport_library.gd").open.call_deferred(app)
				"eventLayers": preload("res://src/ui/event_layers_dialog.gd").open.call_deferred(app, parts[1] if parts.size() > 1 else "")
			return
		var code: String = issue.get("map", parts[1] if parts.size() > 1 and parts[0] == "maps" else "")
		if code == "":
			return
		pop.hide()
		if not await app._map_file_ctrl.open_map_by_code(code):
			return
		var ref: Dictionary = issue.get("reference", {})
		if ref.has("map_section"):
			preload("res://src/ui/map_flow_dialog.gd").open(app, ref.map_section, ref.field)
		elif ref.get("code", "") != "":
			app._set_mode("content")
			app.project_shell.content_editor.select_inst(ref.code)
	list.item_activated.connect(locate)
	body.add_child(app.UiKitScript.popup_buttons(refresh, pop.hide, "检查已保存数据"))
	app._open_popup(pop, Vector2i(720, 560))
	refresh.call()

func _check_label(text: String) -> Label:
	return UiKitScript.hint_label(text, 570)

func _play_report_summary() -> String:
	match str(_play_report_result.get("status", "")):
		"ready":
			return "游戏已加载本次试玩数据"
		"error", "invalid":
			return "游戏加载未通过：" + str(_play_report_result.get("message", ""))
	return "游戏没有返回本次加载回执"

## 试玩配置弹窗（v7）：清单 playtest.flags/params 声明驱动，替代写死的 dash/glide/hp。
## flags → 勾选框（启用时启动参数原样追加 flag.arg）；params → SpinBox（追加 arg 以 %d 填数）。
## 值只存编辑器本地 prefs（键 = flag/param id），不写进地图 JSON；清单未声明 = 空态提示。
func open_configuration() -> void:
	if not app.map_loaded:
		app._set_status("无地图：先新建或打开一张地图")
		return
	var prefs_key := _prefs_key()
	if prefs_key.is_empty():
		app._set_status("无法配置试玩：当前地图没有地图码")
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
			"试玩已接入；游戏未提供可在此调整的参数。" if not pt.is_empty() else
			"游戏尚未接入试玩。请在清单声明 playtest 后重新打开工程。",
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
	var generation: int = files.document_generation()
	var apply_cfg := func():
		if app._playtest_ctrl != self or generation != files.document_generation() or prefs_key != _prefs_key():
			return
		var cfg: Dictionary = app.play_cfg.duplicate(true)
		for sid in states:
			cfg[sid] = (states[sid] as Callable).call()
		var previous: Dictionary = app._prefs.duplicate(true)
		app._prefs[prefs_key] = cfg
		if not app._save_prefs():
			app._prefs = previous
			app._set_status("试玩配置写入失败，请重试")
			return
		app.play_cfg = cfg
		pop.hide()
		app._set_status("试玩配置已应用（仅影响试玩启动参数）")
	btn_row.add_child(app.UiKitScript.button("应用", apply_cfg, "primary"))
	body.add_child(btn_row)
	app._open_popup(pop)

func _play_args(spawn_tiles := Vector2i(-1, -1)) -> PackedStringArray:
	var out: PackedStringArray = []
	# R24：可选键用一致的默认解析——模板项目可能没有 playtest 键，直接点取会报「无效索引」。
	var pt: Dictionary = app.manifest.get("playtest", {}) if (app.manifest is Dictionary and app.manifest.get("playtest", null) is Dictionary) else {}
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


## 本地试玩配置按项目目录和地图码保存；地图名只用于窗口标题。
func _prefs_key() -> String:
	var code: String = app.canvas.cur_map_code() if app.canvas != null else ""
	return str(app.manifest.get("_dir", "")).path_join("|") + code if not code.is_empty() else ""

func sync_map_preferences() -> void:
	var key := _prefs_key()
	var saved = app._prefs.get(key, {})
	app.play_cfg = saved.duplicate(true) if not key.is_empty() and saved is Dictionary else {}
