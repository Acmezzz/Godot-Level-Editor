extends RefCounted
## Starts games from committed documents or screen drafts and presents their reports.

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

func _init(host, map_files: RefCounted) -> void:
	app = host
	files = map_files

func on_play(spawn_tiles: Vector2i = Vector2i(-1, -1), project_entry := false) -> void:
	if not _can_start_playtest():
		return
	if project_entry and not bool(app.manifest.get("playtest", {}).get("projectEntry", false)):
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
			app._set_status(_play_report_summary())
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
		app._set_status("试玩 %s 已退出 · %s" % [who, _play_report_summary()])
	else:
		app._set_status("试玩 %s 已退出（运行 %d 秒）" % [who, secs])

func _play_report_summary() -> String:
	match str(_play_report_result.get("status", "")):
		"ready":
			return "游戏已加载本次试玩数据"
		"error", "invalid":
			return "游戏加载未通过：" + str(_play_report_result.get("message", ""))
	return "游戏没有返回本次加载回执"

func open_play_report() -> void:
	# 游戏运行中可以原子替换加载回执，打开时读本次试玩的最新版本。
	if _play_pid > 0 and not _play_report_request.is_empty():
		var latest := Playtest.read_report(_play_report_request)
		if not latest.is_empty():
			_play_report_result = latest
	var shell: Dictionary = app._popup_body("试玩反馈", _play_report_summary())
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var observations := Playtest.observations(_play_report_result)
	if observations.is_empty():
		body.add_child(UiKitScript.hint_label("本次试玩没有返回作者反馈。"))
	else:
		var scroll := ScrollContainer.new()
		scroll.custom_minimum_size = Vector2(540, 240)
		body.add_child(scroll)
		var rows := VBoxContainer.new()
		rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(rows)
		for row in observations:
			rows.add_child(UiKitScript.hint_label(row.message, 480))
			if row.has("step"):
				var button := UiKitScript.button("定位步骤 %d" % (row.step + 1), func():
					if _open_report_step(row):
						pop.hide(), "ghost")
				rows.add_child(button)
	body.add_child(UiKitScript.button("关闭", pop.hide, "ghost"))
	app._open_popup(pop)

func _open_report_step(row: Dictionary) -> bool:
	var editor = app.project_shell.content_editor
	if not editor.commit_fields():
		return false
	var content: Dictionary = editor.read_content_staged_ex(row.function, row.content)
	var steps = content.data.get("steps", [])
	if (content.digest != row.contentDigest or not steps is Array or row.step >= steps.size()
			or not steps[row.step] is Dictionary or steps[row.step].get("step") != row.stepCode):
		app._set_status("无法定位：内容已修改或步骤不存在，请重新试玩。")
		return false
	app._set_mode("content")
	return editor._steps.open_content(row.function, row.content, "", row.step)

## 试玩配置弹窗（v7）：清单 playtest.flags/params 声明驱动，替代写死的 dash/glide/hp。
## flags → 勾选框（启用时启动参数原样追加 flag.arg）；params → SpinBox（追加 arg 以 %d 填数）。
## 值只存编辑器本地 prefs（键 = flag/param id），不写进地图 JSON；清单未声明 = 空态提示。
func open_configuration() -> void:
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
	var prefs_key := _prefs_key()
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


## 试玩配置（v7）：prefs 由 {abilities:[],hp} 旧形态展平为 {flag_id: bool, param_id: int}。
## 旧键 abilities[] 展开成对应 flag id 勾选、hp 落到 hp 键——与旧 CLI 参数一一对应。
## 偏好键（A6）= <项目根>|<地图码>：两个项目有同名地图时配置不串，改名也不丢。
func _prefs_key() -> String:
	var root := str(app.manifest.get("_dir", ""))
	var code := ""
	if app.canvas != null and app.canvas.map_data.get("meta", null) is Dictionary:
		code = str((app.canvas.map_data["meta"] as Dictionary).get("code", ""))
	if code == "":
		code = str(app.cur_map_name)
	return root.path_join("|") + code

func sync_map_preferences() -> void:
	var key := _prefs_key()
	var legacy_key := str(app.cur_map_name)
	var raw = app._prefs.get(key, null)
	var from_legacy := false
	if not raw is Dictionary and legacy_key != "" and app._prefs.get(legacy_key) is Dictionary:
		raw = app._prefs[legacy_key]
		from_legacy = true
	if not raw is Dictionary:
		app.play_cfg = {}
		return
	var cfg: Dictionary = raw.duplicate(true)
	var old_flags = cfg.get("abilities")
	if old_flags is Array:
		cfg.erase("abilities")
		for flag in old_flags:
			if flag is String and flag != "" and not cfg.has(flag):
				cfg[flag] = true
	if cfg.get("hp") is float:
		cfg["hp"] = int(cfg.hp)
	app.play_cfg = cfg
	if from_legacy or cfg != raw:
		var previous: Dictionary = app._prefs.duplicate(true)
		app._prefs[key] = cfg
		if from_legacy:
			app._prefs.erase(legacy_key)
		if not app._save_prefs():
			app._prefs = previous
