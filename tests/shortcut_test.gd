extends SceneTree
## 快捷键输入管线回归（T-13）：画布在 SubViewport 里收不到键盘（审查报告 K9c/BUG-02），
## 键盘统一走 app._shortcut_input。本测试把真实按键事件推入主视口管线，
## 防止输入路由再次回归。每次实体操作前先切到实体层（与运行路径一致）。
## 控制器拆分后（审查第二批），UI 由 _ready 经 _layout_ctrl 构建——测试改走
## call_deferred(_run)：树已在跑时 add_child 才同步触发 _ready，
## 否则 _layout_ctrl 还是 Nil，包装器会在 Nil 上调方法。

var errs := 0

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var app = load("res://src/app.gd").new()
	root.add_child(app)
	var project := OS.get_environment("BIRD_PROJECT")
	if project == "":
		project = "D:/Game/BIRD/bird"
	app.manifest = EditorManifest.load_from(project)
	app._build_theme()
	app._build_editor_ui()
	await process_frame
	await process_frame
	app._open_map_by_name("level1")
	await process_frame
	await process_frame
	var cvs = app.canvas

	# —— 打开地图后画布侧地图名同步（此前被搬移脚本链尾污染静默破坏过一次） ——
	if cvs.cur_map_name == "level1":
		print("PASS map name sync")
	else:
		errs += 1
		print("FAIL map name sync: '", cvs.cur_map_name, "'")

	# —— Ctrl+X：剪切选中实体（BUG-02 修复的直证） ——
	var n0: int = cvs.entities.get_children().size()
	_pick_first(cvs)
	_press(KEY_X, true)
	await process_frame
	await process_frame
	if cvs.entities.get_children().size() == n0 - 1 and cvs._clipboard.size() == 1:
		print("PASS ctrl+x cut")
	else:
		errs += 1
		print("FAIL ctrl+x cut ", n0, " -> ", cvs.entities.get_children().size())
	if cvs.undo():
		await process_frame
		await process_frame
		if cvs.entities.get_children().size() == n0:
			print("PASS ctrl+z restores")
		else:
			errs += 1
			print("FAIL ctrl+z restores")
	else:
		errs += 1
		print("FAIL undo returned false")

	# —— Ctrl+C / Ctrl+V ——
	_pick_first(cvs)
	_press(KEY_C, true)
	_press(KEY_V, true)
	await process_frame
	await process_frame
	if cvs._clipboard.size() >= 1 and cvs.entities.get_children().size() >= n0 + 1:
		print("PASS ctrl+c/v copy paste")
	else:
		errs += 1
		print("FAIL ctrl+c/v ", cvs._clipboard.size(), " ents=", cvs.entities.get_children().size())
	cvs.undo()
	await process_frame

	# —— Del：删除选中实体 ——
	_pick_first(cvs)
	var nd: int = cvs.entities.get_children().size()
	_press(KEY_DELETE, false)
	await process_frame
	await process_frame
	if cvs.entities.get_children().size() == nd - 1:
		print("PASS delete key")
	else:
		errs += 1
		print("FAIL delete key ", nd, " -> ", cvs.entities.get_children().size())
	cvs.undo()
	await process_frame

	# —— Esc：取消区域粘贴预览 ——
	cvs._paste_mode = true
	cvs._region_clip = {"terrain": [], "decor": [], "collision": [], "size": Vector2i(1, 1)}
	_press(KEY_ESCAPE, false)
	await process_frame
	if not cvs._paste_mode:
		print("PASS esc cancels paste preview")
	else:
		errs += 1
		print("FAIL esc cancels paste preview")

	# —— v2 §2.5：数字键 1-6 已作废（没有工具概念）。按下后不得改变画笔语义 ——
	var tool_before: String = cvs.tool
	_press(KEY_2, false)
	await process_frame
	if cvs.tool == tool_before:
		print("PASS tool keys are gone")
	else:
		errs += 1
		print("FAIL tool keys still change state: ", tool_before, " -> ", cvs.tool)

	# —— 层决定画笔语义：实体层 = 放置，瓦片层 = 涂刷 ——
	cvs.active_layer = cvs._ent_layer_index()
	cvs.tool = ""
	app._apply_state("", cvs._ent_layer_index())
	var ent_ok: bool = cvs.tool == "stamp"
	app._apply_state("", 0)
	var tile_ok: bool = cvs.tool == "paint"
	if ent_ok and tile_ok:
		print("PASS layer decides brush semantics")
	else:
		errs += 1
		print("FAIL layer decides brush: ent=", cvs.tool, " ent_ok=", ent_ok, " tile_ok=", tile_ok)

	if errs == 0:
		print("SHORTCUT_TEST_OK")
	else:
		print("SHORTCUT_TEST_FAIL")
	quit(errs)

## 切到实体层并选中第一个实体（模拟真实操作路径；v2：不再需要挑工具）
func _pick_first(cvs) -> void:
	cvs.active_layer = cvs._ent_layer_index()
	cvs.tool = "stamp"
	cvs.selected_multi = [cvs.entities.get_children()[0]]
	cvs.selected_entity = null

## 构造真实按键事件推入主视口管线（与真实键盘事件同一条路径）
func _press(key: Key, ctrl: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = key
	ev.ctrl_pressed = ctrl
	ev.pressed = true
	root.push_input(ev)

