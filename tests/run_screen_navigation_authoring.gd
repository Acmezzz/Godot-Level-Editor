extends SceneTree
## Author and play a title → tutorial → map → results → conclusion route.

const Manifest := preload("res://src/project/manifest.gd")
const Maps := preload("res://src/map/map_store.gd")
const Audit := preload("res://src/project/project_audit.gd")
const Views := preload("res://src/ui/reference_view_library.gd")
const Flow := preload("res://src/content/rel_graph.gd")
const Store := preload("res://src/content/content_store.gd")
const ScreenCanvas := preload("res://src/ui/screen_layout_canvas.gd")
const Generator := preload("res://src/ui/map_generator_dialog.gd")
const MapFlowDialog := preload("res://src/ui/map_flow_dialog.gd")
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
			"fields": [{"id": "exit_target", "kind": "input", "type": "flow_target",
				"maps": true, "screens": true, "contentTypes": ["signal"]}]}],
		"startup": {"screens": true}, "viewports": [{"id": "handheld", "w": 480, "h": 720}],
		"mapOutputs": {"completed": {"name": "Course completed",
			"maps": true, "screens": true, "contentTypes": ["signal"]}},
		"mapGenerators": {"course": {"contentType": "course_rules",
			"parameterFields": ["projection", "placements"]}},
		"preview": {"version": 1, "executable": OS.get_executable_path(), "capabilities": ["generateMap"],
			"args": ["--headless", "--path", "%projectpath%", "--"]},
		"screenModules": {"signal-latch": {"name": "Latch", "outputs": {"accepted": "Continue"}, "fields": [
			{"id": "presses", "kind": "input", "type": "int", "min": 1, "default": 1}]}},
		"functions": {"course_rules": {"code": "CRUL", "name": "Course rules", "fields": [
			{"id": "projection", "code": "PROJ", "kind": "choice", "options": ["orthogonal", "isometric"]},
			{"id": "placements", "code": "PLAC", "kind": "input", "type": "array", "of": "record", "fields": [
				{"id": "asset", "code": "ASST", "kind": "input", "type": "asset_ref", "assetKind": "entity"},
				{"id": "column", "code": "COLM", "kind": "input", "type": "int", "min": 1, "max": 10}]},
			{"id": "next", "code": "CNXT", "kind": "input", "type": "flow_target",
				"maps": true, "screens": true, "contentTypes": ["signal"]}]},
			"signal": {"code": "SIGN", "name": "Signal", "fields": [
			{"id": "text", "code": "TEXT", "kind": "input", "type": "string"},
			{"id": "next", "code": "NEXT", "kind": "input", "type": "flow_target",
				"maps": true, "screens": true, "contentTypes": ["signal"]}]}},
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
	choose(collect(popup(), "OptionButton")[0], "signal")
	press(popup(), "新建…")
	await process_frame
	var form := popup()
	var inputs := collect(form, "LineEdit")
	inputs[0].text = "Finished"
	inputs[1].text = "finished"
	inputs[2].text = "Screen sequence complete"
	press(form, "保存")
	form.hide()
	app.project_shell.content_editor._library.open()
	press(popup(), "新建…")
	await process_frame
	form = popup()
	inputs = collect(form, "LineEdit")
	inputs[0].text = "Results Router"
	inputs[1].text = "results-router"
	press(form, "保存")
	form.hide()
	app.project_shell.content_editor._library.open()
	choose(collect(popup(), "OptionButton")[0], "course_rules")
	press(popup(), "新建…")
	await process_frame
	form = popup()
	inputs = collect(form, "LineEdit")
	inputs[0].text = "Course Rules"
	inputs[1].text = "course-rules"
	var choices := collect(form, "OptionButton")
	choose(choices[0], "orthogonal")
	press(form, "+ 添加")
	press(form, "+ 添加")
	var assets := collect(form, "OptionButton")
	var columns := collect(form, "SpinBox")
	for i in 2:
		choose(assets[i + 1], "relay")
		columns[i].value = 3 + 2 * i
	press(form, "保存")
	form.hide()
	var rules := {"function": "course_rules", "content": "project-course-rules"}
	await add_screen("results", "Play a procedural course", {}, rules)
	app._set_mode("map")
	Generator.open(app)
	var create := popup()
	create.find_child("GeneratedMapName", true, false).text = "course"
	var presets: OptionButton = create.find_child("MapGeneratorPreset", true, false)
	check(presets.item_count == 2 and "project-course-rules" in presets.get_item_text(1),
		"generation offers the saved project content")
	presets.select(1)
	presets.item_selected.emit(1)
	check(create.find_child("GeneratorField_next", true, false) == null,
		"the runtime outlet is not part of the generator form")
	var generate: Button = create.find_child("RunMapGenerator", true, false)
	generate.pressed.emit()
	while generate.disabled:
		await process_frame
	var status: String = create.find_child("GeneratedMapStatus", true, false).text
	if not check(status.begins_with("生成完成"), "game produces a map from the authored parameters: " + status):
		quit(1)
		return
	press(create, "打开为可编辑地图")
	for i in 12:
		await process_frame
		if app.map_loaded and app.cur_map_name == "course":
			break
	if not check(app.map_loaded and app.cur_map_name == "course", "author a destination map"):
		quit(1)
		return
	var canvas: EditorCanvas = app.canvas
	check(canvas.extract().objects.map(func(row): return int(row.x)) == [3, 5],
		"the generated placements match the two authored record rows")
	var snapshot: Dictionary = canvas.extract().meta.generatorSource.parameters
	check(snapshot.size() == 2 and snapshot.has_all(["projection", "placements"]),
		"generation snapshots only selected fields")
	var base: Dictionary = await app._map_file_ctrl.commit_document("发布地图供流程选用")
	check(base.get("status") == "ok", "publish the map before it becomes a destination")
	var pawn: EntityNode = canvas._ent_by_code_index()["R000"]
	var pawn_code := pawn.code
	var map_code := canvas.cur_map_code()
	app._set_mode("content", pawn_code)
	var exit_picker: OptionButton = app.project_shell.content_editor.root.find_child("InstanceValue_exit_target", true, false)
	choose(exit_picker, JSON.stringify({"map": map_code}))
	check(pawn.props.get("exit_target") == {"map": map_code}, "the same instance outlet accepts a stable map target")
	choose(exit_picker, JSON.stringify({"function": "signal", "content": "project-finished"}))
	var delete_reason: String = app.project_shell.content_editor._form._delete_blocked_reason("signal", "project-finished")
	check(pawn_code in delete_reason, "an unsaved content destination protects the referenced item")
	choose(exit_picker, JSON.stringify({"view": "results"}))
	app.project_shell.content_editor.commit_fields()
	var live_uses := Audit.view_inbound_refs(manifest, "results", [], canvas.extract(), "course")
	check(live_uses.refs.any(func(ref): return pawn_code in ref and "exit_target" in ref),
		"a live map instance prevents deleting its destination")
	app._set_mode("map")
	var published: Dictionary = await app._map_file_ctrl.commit_document("保存教学关卡")
	check(published.get("status") == "ok", "publish the destination map")
	var saved_uses := Audit.view_inbound_refs(manifest, "results", [])
	check(saved_uses.refs.any(func(ref): return pawn_code in ref and "exit_target" in ref),
		"the saved map instance protects the same destination")
	var orphan_manifest := manifest.duplicate(true)
	orphan_manifest.views = []
	check(Audit._ref_checks(canvas.extract(), orphan_manifest, "course").any(func(issue):
		return issue.jump.code == pawn_code and issue.jump.prop == "exit_target"),
		"map audit pinpoints the instance if the destination is externally removed")
	app._set_mode("content", pawn_code)
	exit_picker = app.project_shell.content_editor.root.find_child("InstanceValue_exit_target", true, false)
	choose(exit_picker, "")
	app.project_shell.content_editor.commit_fields()
	app._set_mode("map")
	MapFlowDialog.open(app)
	var map_flow := popup()
	var completed: OptionButton = map_flow.find_child("MapFlow_completed", true, false)
	choose(completed, JSON.stringify({"function": "signal", "content": "project-finished"}))
	press(map_flow, "应用")
	delete_reason = app.project_shell.content_editor._form._delete_blocked_reason("signal", "project-finished")
	check("地图出口" in delete_reason, "an unsaved map outlet protects its destination content")
	MapFlowDialog.open(app)
	map_flow = popup()
	completed = map_flow.find_child("MapFlow_completed", true, false)
	choose(completed, JSON.stringify({"view": "results"}))
	press(map_flow, "应用")
	check(Audit._ref_checks(canvas.extract(), orphan_manifest, "course").any(func(issue):
		return issue.jump.type == "map_flow" and issue.jump.field == "completed"),
		"map audit pinpoints the missing map-level destination")
	published = await app._map_file_ctrl.commit_document("保存地图级出口")
	check(published.get("status") == "ok", "publish the map-level completion outlet")
	app._set_mode("content")
	await add_screen("instructions", "Enter course", {}, {"map": map_code})
	await add_screen("welcome", "Start tutorial", {"module": "signal-latch"}, {"view": "instructions"})
	await add_screen("debrief", "Read results", {}, {"function": "signal", "content": "project-results-router"})
	app.project_shell.content_editor._library.open()
	press(popup(), "流程关系…")
	await process_frame
	var flow := popup()
	var rules_key := "course_rules\u0001project-course-rules"
	var targets: OptionButton = flow.find_child("FlowTarget", true, false)
	choose(flow.find_child("FlowSource", true, false), rules_key)
	for destination in [{"map": map_code}, {"function": "signal", "content": "project-finished"}, {"view": "debrief"}]:
		choose(targets, destination)
		press(flow, "应用关系")
		var config := Store.read(manifest, rules.function, rules.content)
		check(config.get("fields", {}).get("CNXT") == destination,
			"the procedural course outlet accepts the typed destination %s" % destination)
	var router_key := "signal\u0001project-results-router"
	choose(flow.find_child("FlowSource", true, false), router_key)
	for destination in [{"map": map_code}, {"view": "instructions"}, {"function": "signal", "content": "project-finished"}]:
		choose(targets, destination)
		press(flow, "应用关系")
		var router := Store.read(manifest, "signal", "project-results-router")
		check(router.get("fields", {}).get("NEXT") == destination, "graph writes the typed destination %s" % destination)
	flow.hide()
	var graph := Flow.build_project(manifest)
	check(graph.edges.any(func(edge):
		return edge.from == "@map\u0001" + map_code and edge.to == "@view\u0001results" and edge.field == "completed"),
		"the project graph reads the saved outlet from the map itself")
	check(graph.edges.any(func(edge): return edge.from == rules_key and edge.to == "@view\u0001debrief"),
		"the project flow graph reloads the procedural course outlet")
	check(graph.edges.any(func(edge): return edge.from == router_key and edge.to == "signal\u0001project-finished"),
		"graph reloads the mixed destination as an edge to the published target")
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
	check(report.get("status") == "ready" and result.get("screens") == ["welcome", "instructions", "results", "debrief"]
		and result.get("visited") == ["project-course-rules", "project-results-router", "project-finished"]
		and result.get("runtimeCourse", []).map(func(x): return int(x)) == [3, 5] and result.get("board") == map_code
		and result.get("placed") == [pawn_code, "R001"] and result.get("text") == "Screen sequence complete",
		"the game reads the map-level completion outlet and reaches the conclusion: %s" % [report])
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
		var candidate = control.get_item_metadata(i)
		if typeof(candidate) == typeof(value) and candidate == value:
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
