extends SceneTree
## One authoring workflow: configure production and multiple deliveries, publish and launch the game.

const Manifest := preload("res://src/project/manifest.gd")
const Maps := preload("res://src/map/map_store.gd")
const Clone := preload("res://src/content/clone_plan.gd")
const Audit := preload("res://src/project/project_audit.gd")
const Editor := preload("res://src/editor.tscn")
var app
var failures := 0

func _initialize() -> void:
	create_timer(25.0).timeout.connect(func():
		check(false, "authoring timed out")
		finish())
	run.call_deferred()

func run() -> void:
	var project := ProjectSettings.globalize_path("user://network-authoring-%s" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(project.path_join("editor"))
	for file in ["project.godot", "game.gd"]:
		check(DirAccess.copy_absolute(ProjectSettings.globalize_path("res://tests/network_game/" + file),
			project.path_join(file)) == OK, "install " + file)
	var resource := {"id": "resource", "kind": "choice", "options": ["copper", "iron"]}
	var declarations := {"projectName": "Freight Yard", "startup": {"maps": true},
		"assets": [
			{"id": "works", "kind": "entity", "code": "WORK", "name": "Factory", "visual": {"mode": "rect", "color": "#c88042"}, "fields": [
				resource, {"id": "batch", "kind": "input", "type": "int", "min": 1},
				{"id": "routes", "kind": "input", "type": "array", "of": "port_ref", "portTypes": "cargo"}]},
			{"id": "depot", "kind": "entity", "code": "DEPT", "name": "Depot", "visual": {"mode": "rect", "color": "#4b9388"}, "fields": [
				resource, {"id": "demand", "kind": "input", "type": "int", "min": 1}], "ports": [
				{"id": "freight", "type": "cargo", "x": 0, "y": 0},
				{"id": "alarm", "type": "signal", "x": 10, "y": 0}]}],
		"playtest": {"executable": OS.get_executable_path(), "report": true, "projectEntry": true,
			"args": ["--headless", "--path", "%projectpath%", "--script", "res://game.gd", "--"]}}
	check(Maps.write_json(project.path_join("editor/editor_manifest.json"), declarations), "install only game declarations")
	var manifest := Manifest.load_from(project)
	if not check(not manifest.has("_error"), str(manifest.get("_error", "load game manifest"))):
		finish()
		return
	app = Editor.instantiate()
	root.add_child(app)
	app._clear_project_session()
	app.manifest = manifest
	app._build_editor_ui()
	app._set_mode("map")
	app._on_new()
	var create := visible_popup()
	create.find_child("NewMapName", true, false).text = "foundry"
	press(create, "确定")
	for i in 12:
		await process_frame
		if app.cur_map_name == "foundry" and app.map_loaded:
			break
	if not check(app.map_loaded and app.cur_map_name == "foundry", "create a new map from the editor"):
		finish()
		return
	var canvas: EditorCanvas = app.canvas
	var factory: EntityNode = canvas._tool_ops_ctrl.place_object("works", 0, Vector2(16, 32), true)
	var first: EntityNode = canvas._tool_ops_ctrl.place_object("depot", 0, Vector2(80, 16), true)
	var second: EntityNode = canvas._tool_ops_ctrl.place_object("depot", 0, Vector2(80, 64), true)
	var code := canvas.cur_map_code()
	var source := factory.code
	var sink_a := first.code
	var sink_b := second.code
	for job in [[sink_a, 3], [sink_b, 5]]:
		app._set_mode("content", job[0])
		choose(instance_value("resource"), "copper")
		instance_value("demand").value = job[1]
		app.project_shell.content_editor.commit_fields()
	app._set_mode("content", source)
	choose(instance_value("resource"), "copper")
	instance_value("batch").value = 8
	app.project_shell.content_editor.commit_fields()
	var routes := instance_value("routes")
	press(routes, "+ 添加")
	press(routes, "+ 添加")
	var selectors := collect(routes, "OptionButton")
	if not check(selectors.size() == 2, "add two editable delivery slots"):
		finish()
		return
	var addresses := [{"map": code, "inst": sink_a, "port": "freight"}, {"map": code, "inst": sink_b, "port": "freight"}]
	for i in selectors.size():
		var selector: OptionButton = selectors[i]
		check(selector.item_count == 3, "filter to the two freight ports plus the empty choice")
		choose(selector, JSON.stringify(addresses[i]))
	app._set_mode("map")
	var receipt: Dictionary = await app._map_file_ctrl.commit_document("保存经营网络")
	if not check(receipt.get("status") == "ok", "publish the network: %s" % [receipt]):
		finish()
		return
	await app._load_map_file(Maps.path_for(manifest, "foundry"))
	var reopened: EntityNode = canvas._ent_by_code_index()[source]
	check(reopened.props.routes == addresses, "reopen the same ordered fanout")
	var map := Maps.read(manifest, "foundry")
	var copy := Clone.whole_map_document({"data": map, "manifest": manifest, "map": "foundry"}, "foundry_copy", "COPY")
	var copied: Dictionary = copy.document.objects.filter(func(row): return row.asset == "works")[0]
	var cloned_routes: Array = copied.props.routes
	check(cloned_routes.size() == 2 and cloned_routes[0].map == "COPY" and cloned_routes[1].map == "COPY"
		and cloned_routes[0].inst != sink_a and cloned_routes[1].inst != sink_b,
		"map duplication remaps each link to the copied depots")
	var bad_map := map.duplicate(true)
	var bad_factory: Dictionary = bad_map.objects.filter(func(row): return row.asset == "works")[0]
	bad_factory.props.routes[1].port = "alarm"
	check(Audit._ref_checks(bad_map, manifest, "foundry").any(func(issue): return "routes#1" in issue.path),
		"map audit identifies the specific incompatible link")
	app._set_mode("content")
	press(app.project_shell, "启动入口…")
	var startup := visible_popup()
	var picker: OptionButton = startup.find_child("StartupTarget", true, false)
	for i in picker.item_count:
		if picker.get_item_metadata(i) == {"map": code}:
			picker.select(i)
			break
	press(startup, "保存启动入口")
	press(app.project_shell, "试玩项目")
	var controller = app._playtest_ctrl
	var end := Time.get_ticks_msec() + 12000
	while controller._play_report_result.is_empty() and Time.get_ticks_msec() < end:
		await create_timer(0.05).timeout
		controller.poll_playtest()
	var report: Dictionary = controller._play_report_result
	var result: Dictionary = report.get("result", {})
	check(report.get("status") == "ready" and result.get("map") == code and result.get("won") == true,
		"the independent game loads the authored startup map and fulfills both orders: %s" % [report])
	check(result.get("arrivals", []) == [
		{"depot": sink_a, "resource": "copper", "delivered": 3.0, "complete": true},
		{"depot": sink_b, "resource": "copper", "delivered": 5.0, "complete": true}],
		"game dispatches in authored order to both nodes and settles their authored demands")
	finish()

func instance_value(id: String) -> Control:
	return app.project_shell.content_editor.root.find_child("InstanceValue_" + id, true, false)

func visible_popup() -> PopupPanel:
	return collect(app, "PopupPanel").filter(func(pop): return pop.visible).back()

func choose(control: OptionButton, id: String) -> void:
	for index in control.item_count:
		if control.get_item_metadata(index) == id:
			control.select(index)
			control.item_selected.emit(index)
			return
	check(false, "missing choice " + id)

func press(node: Node, text: String) -> void:
	for button in collect(node, "Button"):
		if button.text == text:
			button.pressed.emit()
			return
	check(false, "missing button " + text)

func collect(node: Node, type: String) -> Array:
	var found: Array = []
	for child in node.get_children():
		if child.is_class(type):
			found.append(child)
		found.append_array(collect(child, type))
	return found

func check(condition: bool, message: String) -> bool:
	if not condition:
		printerr("NETWORK-FAIL: ", message)
		failures += 1
	return condition

func finish() -> void:
	print("NETWORK-DONE failures=", failures)
	quit(0 if failures == 0 else 1)
