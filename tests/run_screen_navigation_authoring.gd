extends SceneTree
## Author and play a title → tutorial → map → results → conclusion route.

const Manifest := preload("res://src/project/manifest.gd")
const Maps := preload("res://src/map/map_store.gd")
const Audit := preload("res://src/project/project_audit.gd")
const Views := preload("res://src/ui/reference_view_library.gd")
const Flow := preload("res://src/content/rel_graph.gd")
const ScreenCanvas := preload("res://src/ui/screen_layout_canvas.gd")
const Editor := preload("res://src/editor.tscn")
var app
var failures := 0

func _initialize() -> void:
	create_timer(25.0).timeout.connect(func():
		check(false, "authoring timed out")
		quit(1))
	run.call_deferred()

func run() -> void:
	var project := ProjectSettings.globalize_path("user://screen-navigation-%s" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(project.path_join("editor"))
	for file in ["project.godot", "main.tscn", "game.gd"]:
		check(DirAccess.copy_absolute(ProjectSettings.globalize_path("res://tests/screen_game/" + file),
			project.path_join(file)) == OK, "install the standalone game " + file)
	var declaration := {"projectName": "Screen Navigation", "directViewTargets": true, "directMapTargets": true,
		"assets": [{"id": "relay", "kind": "entity", "code": "RLY1", "visual": {"mode": "rect", "color": "#62cabb"},
			"fields": [{"id": "exit_view", "kind": "choice", "source": "view:"}]}],
		"startup": {"screens": true}, "viewports": [{"id": "handheld", "w": 480, "h": 720}],
		"screenModules": {"signal-latch": {"name": "Latch", "outputs": {"accepted": "Continue"}, "fields": [
			{"id": "presses", "kind": "input", "type": "int", "min": 1, "default": 1}]}},
		"functions": {"signal": {"code": "SIGN", "name": "Signal", "fields": [
			{"id": "text", "code": "TEXT", "kind": "input", "type": "string"}]}},
		"playtest": {"executable": OS.get_executable_path(), "report": true, "projectEntry": true,
			"args": ["--path", "%projectpath%", "--audio-driver", "Dummy", "--", "--verify"]}}
	check(Maps.write_json(project.path_join("editor/editor_manifest.json"), declaration), "install only game declarations")
	var manifest := Manifest.load_from(project)
	if not check(not manifest.has("_error"), str(manifest.get("_error", "load game declarations"))):
		quit(1)
		return
	app = Editor.instantiate()
	root.add_child(app)
	app._clear_project_session()
	app.manifest = manifest
	app._build_editor_ui()
	app._set_mode("content")
	app.project_shell.content_editor._library.open()
	press(popup(), "新建…")
	await process_frame
	var form := popup()
	var inputs := collect(form, "LineEdit")
	inputs[0].text = "Finished"
	inputs[1].text = "finished"
	inputs[2].text = "Screen sequence complete"
	press(form, "保存")
	form.hide()
	await add_screen("results", "See result", {}, {"function": "signal", "content": "project-finished"})
	app._set_mode("map")
	app._on_new()
	var create := popup()
	create.find_child("NewMapName", true, false).text = "course"
	press(create, "确定")
	for i in 12:
		await process_frame
		if app.map_loaded and app.cur_map_name == "course":
			break
	if not check(app.map_loaded and app.cur_map_name == "course", "author a destination map"):
		quit(1)
		return
	var canvas: EditorCanvas = app.canvas
	var pawn: EntityNode = canvas._tool_ops_ctrl.place_object("relay", 0, Vector2(48, 48), true)
	var pawn_code := pawn.code
	var map_code := canvas.cur_map_code()
	app._set_mode("content", pawn_code)
	var exit_picker: OptionButton = app.project_shell.content_editor.root.find_child("InstanceValue_exit_view", true, false)
	choose(exit_picker, "results")
	app.project_shell.content_editor.commit_fields()
	var live_uses := Audit.view_inbound_refs(manifest, "results", [], canvas.extract(), "course")
	check(live_uses.refs.any(func(ref): return pawn_code in ref and "exit_view" in ref),
		"a live map instance prevents deleting its destination")
	app._set_mode("map")
	var published: Dictionary = await app._map_file_ctrl.commit_document("保存教学关卡")
	check(published.get("status") == "ok", "publish the destination map")
	var saved_uses := Audit.view_inbound_refs(manifest, "results", [])
	check(saved_uses.refs.any(func(ref): return pawn_code in ref and "exit_view" in ref),
		"the saved map instance protects the same destination")
	var orphan_manifest := manifest.duplicate(true)
	orphan_manifest.views = []
	check(Audit._ref_checks(canvas.extract(), orphan_manifest, "course").any(func(issue):
		return issue.jump.code == pawn_code and issue.jump.prop == "exit_view"),
		"map audit pinpoints the instance if the destination is externally removed")
	app._set_mode("content")
	await add_screen("instructions", "Enter course", {}, {"map": map_code})
	await add_screen("welcome", "Start tutorial", {"module": "signal-latch"}, {"view": "instructions"})
	var graph := Flow.build_project(manifest)
	var edge_exists: bool = graph.edges.any(func(edge):
		return edge.from == "@view\u0001welcome" and edge.to == "@view\u0001instructions" and edge.get("output") == "accepted")
	check(edge_exists, "the project graph exposes the direct module transition")
	check(graph.edges.any(func(edge): return edge.cid == "instructions" and edge.fn == Flow.MAP_KIND and edge.value == map_code),
		"the project graph links the teaching button to the authored map")
	var inbound := Audit.view_inbound_refs(manifest, "instructions", [])
	check(not inbound.refs.is_empty() and "welcome" in inbound.refs[0], "the destination screen has the expected inbound reference")
	var broken := manifest.duplicate(true)
	var welcome: Dictionary = broken.views.filter(func(row): return row.view_id == "welcome")[0]
	welcome.layout.elements[0].outputs.accepted.view = "missing-screen"
	check(Audit.view_reference_issues(broken, "welcome").any(func(issue): return issue.path.ends_with(".outputs.accepted")),
		"diagnostics identify the particular missing destination")
	press(app.project_shell, "启动入口…")
	var startup := popup()
	choose(startup.find_child("StartupTarget", true, false), {"view": "welcome"})
	press(startup, "保存启动入口")
	app._clear_project_session()
	app.manifest = Manifest.load_from(project)
	app._build_editor_ui()
	app._set_mode("content")
	check(app.manifest.startup.target == {"view": "welcome"}, "the authored screen is published as startup")
	press(app.project_shell, "试玩项目")
	var controller = app._playtest_ctrl
	var end := Time.get_ticks_msec() + 12000
	while controller._play_report_result.is_empty() and Time.get_ticks_msec() < end:
		await create_timer(0.05).timeout
		controller.poll_playtest()
	var report: Dictionary = controller._play_report_result
	var result: Dictionary = report.get("result", {})
	check(report.get("status") == "ready" and result.get("screens") == ["welcome", "instructions", "results"]
		and result.get("visited") == ["project-finished"] and result.get("board") == map_code
		and result.get("placed") == [pawn_code] and result.get("text") == "Screen sequence complete",
		"the game loads the authored map object, follows its screen reference and reaches the conclusion: %s" % [report])
	print("SCREEN-NAV-DONE failures=", failures)
	quit(0 if failures == 0 else 1)

func add_screen(id: String, label: String, module: Dictionary, target: Dictionary) -> void:
	Views.open(app)
	var pop := popup()
	var selector: OptionButton = collect(pop, "OptionButton")[0]
	selector.select(selector.item_count - 1)
	selector.item_selected.emit(selector.selected)
	collect(pop, "LineEdit")[0].text = id
	pop.find_child("ViewLayoutMode", true, false).button_pressed = true
	await process_frame
	var canvas: ScreenCanvas
	for control in collect(pop, "Control"):
		if control is ScreenCanvas:
			canvas = control
			break
	var frame := canvas.frame()
	var button := InputEventMouseButton.new()
	button.button_index = MOUSE_BUTTON_LEFT
	button.pressed = true
	button.position = frame.position + frame.size * Vector2(0.2, 0.4)
	canvas._gui_input(button)
	button.pressed = false
	button.position = frame.position + frame.size * Vector2(0.8, 0.6)
	canvas._gui_input(button)
	var kind: OptionButton = pop.find_child("LayoutElementKind", true, false)
	for i in kind.item_count:
		var value: Dictionary = kind.get_item_metadata(i)
		if (module.is_empty() and value.get("kind") == "button") or (
			not module.is_empty() and value.get("module") == module.module):
			kind.select(i)
			kind.item_selected.emit(i)
			break
	var caption: LineEdit = pop.find_child("LayoutElement_text", true, false)
	caption.text = label
	caption.text_changed.emit(label)
	if not module.is_empty():
		pop.find_child("LayoutModuleField_presses", true, false).value = 2
	var control: OptionButton = pop.find_child("LayoutElementTarget" if module.is_empty() else "LayoutOutput_accepted", true, false)
	choose(control, target)
	press(pop, "保存参考视图")
	check(not pop.visible, "publish screen " + id)
	await process_frame

func choose(control: OptionButton, value: Variant) -> void:
	for i in control.item_count:
		if control.get_item_metadata(i) == value:
			control.select(i)
			control.item_selected.emit(i)
			return
	check(false, "missing choice %s" % [value])

func press(node: Node, label: String) -> void:
	for button in collect(node, "Button"):
		if button.text == label:
			button.pressed.emit()
			return
	check(false, "missing button " + label)

func popup() -> PopupPanel:
	return collect(app, "PopupPanel").filter(func(pop): return pop.visible).back()

func collect(node: Node, type: String) -> Array:
	var found: Array = []
	for child in node.get_children():
		if child.is_class(type):
			found.append(child)
		found.append_array(collect(child, type))
	return found

func check(condition: bool, message: String) -> bool:
	if not condition:
		printerr("SCREEN-NAV-FAIL: ", message)
		failures += 1
	return condition
