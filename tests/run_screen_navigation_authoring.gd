extends SceneTree
## Author and play a title → settings → tutorial → map → results → conclusion route.

const Manifest := preload("res://src/project/manifest.gd")
const Maps := preload("res://src/map/map_store.gd")
const Usage := preload("res://src/project/reference_usage.gd")
const ScreenReferences := preload("res://src/project/screen_reference_validation.gd")
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
		var source_file: String = file + ".template" if file == "project.godot" else file
		check(DirAccess.copy_absolute(ProjectSettings.globalize_path("res://tests/screen_game/" + source_file),
			project.path_join(file)) == OK, "install the standalone game " + file)
	var declaration := {"projectName": "Screen Navigation", "directMapTargets": true,
		"assets": [{"id": "relay", "kind": "entity", "code": "RLY1", "visual": {"mode": "rect", "color": "#62cabb"},
			"ports": [{"id": "door", "x": 0, "y": 0, "type": "arrival"}, {"id": "wire", "x": 4, "y": 0, "type": "signal"}],
			"fields": [{"id": "exit_target", "kind": "input", "type": "flow_target",
				"maps": true, "screens": true, "contentTypes": ["signal"], "arrivalPorts": ["arrival"]},
				{"id": "landing", "kind": "input", "type": "vector2", "pickSpace": "map", "step": 1},
				{"id": "signal_port", "kind": "input", "type": "port_ref", "of": "signal"},
				{"id": "local_signal", "kind": "input", "type": "flow_target",
					"contentTypes": ["signal"], "contentMapContext": "inherit"}]}],
		"startup": {"screens": true, "arrivalPorts": ["arrival"], "contentTypes": ["sequence"],
			"contentMapContext": "paired"}, "viewports": [{"id": "handheld", "w": 480, "h": 720}],
		"mapOutputs": {"completed": {"name": "Course completed",
			"maps": true, "screens": true, "viewMapContext": "inherit", "contentTypes": ["signal"], "arrivalPorts": ["arrival"]},
			"retry": {"name": "Retry the course", "arrivalPorts": ["arrival"]}},
		"mapContentSlots": {"round": {"name": "Round rules",
			"contentTypes": ["round_rules"], "contentMapContext": "inherit"},
			"course": {"name": "Generated course rules", "contentTypes": ["course_rules"]}},
		"mapGenerators": {"course": {"contentType": "course_rules",
			"parameterFields": ["projection", "placements", "route", "elevation"]}},
		"triggers": {"course_entered": {"name": "Course notice", "code": "NTCE",
			"eventTargets": {"contentTypes": ["signal"]}}},
		"preview": {"version": 1, "executable": OS.get_executable_path(), "capabilities": ["generateMap", "mapFrame"],
			"args": ["--rendering-method", "gl_compatibility", "--audio-driver", "Dummy", "--path", "%projectpath%", "--"]},
		"screenModules": {"course-door": {"outputs": {"accepted": {"name": "Enter", "arrivalPorts": ["arrival"]}},
			"fields": [{"id": "marker", "kind": "input", "type": "port_ref", "of": "signal"},
				{"id": "crossing", "kind": "input", "type": "edge_ref"},
				{"id": "checkpoint", "kind": "input", "type": "edge_ref"}]},
			"map-debrief": {"outputs": {"accepted": {"name": "Debrief", "contentTypes": ["sequence"],
				"contentMapContext": "inherit"}}},
			"map-results": {"outputs": {"accepted": {"name": "Continue", "contentTypes": ["course_rules"],
				"contentMapContext": "inherit"}}},
			"player-options": {"name": "Player settings", "outputs": {"accepted": {"name": "Apply", "screens": true}},
				"fields": [{"id": "volume", "kind": "input", "type": "int", "min": 0, "max": 100, "step": 5, "default": 100},
					{"id": "captions", "kind": "input", "type": "bool", "default": false}]},
			"signal-latch": {"name": "Latch", "outputs": {"accepted": {"name": "Continue", "screens": true}}, "fields": [
			{"id": "presses", "kind": "input", "type": "int", "min": 1, "default": 1}]}},
		"functions": {"course_rules": {"code": "CRUL", "name": "Course rules", "fields": [
			{"id": "projection", "code": "PROJ", "kind": "choice", "options": ["orthogonal", "isometric"]},
			{"id": "placements", "code": "PLAC", "kind": "input", "type": "array", "of": "record", "fields": [
				{"id": "asset", "code": "ASST", "kind": "input", "type": "asset_ref", "assetKind": "entity"},
				{"id": "column", "code": "COLM", "kind": "input", "type": "int", "min": 1, "max": 10}]},
			{"id": "route", "code": "WPNT", "kind": "input", "type": "array", "of": "vector2",
				"min": 0, "max": 7, "step": 1},
			{"id": "elevation", "code": "ELEV", "kind": "input", "type": "curve",
				"default": [{"time": 0, "value": 0}]},
			{"id": "next", "code": "CNXT", "kind": "input", "type": "flow_target",
				"maps": true, "screens": true, "viewMapContext": "inherit", "contentTypes": ["signal"]}]},
			"sequence": {"code": "SEQN", "name": "Sequence", "steps": true, "fields": [
				{"id": "host", "code": "DHST", "kind": "choice", "source": "entity_inst:relay"}]},
			"round_rules": {"code": "ROND", "name": "Round rules", "fields": [
				{"id": "inputs", "code": "INPT", "kind": "input", "type": "int", "min": 1, "max": 4},
				{"id": "role", "code": "ROLE", "kind": "input", "type": "flow_target",
					"contentTypes": ["round_host"], "contentMapContext": "inherit"},
				{"id": "retry", "code": "RTRY", "kind": "input", "type": "flow_target", "maps": true}]},
			"round_host": {"code": "RHST", "name": "Round host", "fields": [
				{"id": "host", "code": "HOST", "kind": "choice", "source": "entity_inst:relay"},
				{"id": "relay_port", "code": "RPOR", "kind": "input", "type": "port_ref", "of": "signal"}]},
			"signal": {"code": "SIGN", "name": "Signal", "fields": [
			{"id": "text", "code": "TEXT", "kind": "input", "type": "string"},
			{"id": "actor", "code": "ACTR", "kind": "choice", "source": "entity_inst:relay"},
			{"id": "next", "code": "NEXT", "kind": "input", "type": "flow_target",
				"maps": true, "screens": true, "contentTypes": ["signal"]}]}},
		"steps": {"handoff": {"code": "HDOF", "name": "Handoff", "fields": [
			{"id": "board", "code": "BRD1", "kind": "choice", "source": "map"},
			{"id": "route", "code": "ROUT", "kind": "input", "type": "array", "of": "flow_target",
				"maps": true, "screens": true, "contentTypes": ["signal"], "contentMapContext": "paired", "mapField": "board"}]}},
		"playtest": {"executable": OS.get_executable_path(), "report": true, "projectEntry": true, "mapEntry": true,
			"mapEntryPorts": ["arrival"], "entryFunctions": ["sequence"], "contentEntryMap": true,
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
	var route_field: Control = collect(form, "HBoxContainer").filter(func(row):
		return row.get_meta("field_id", "") == "route")[0]
	press(route_field, "+ 添加")
	press(route_field, "+ 添加")
	var route_axes := collect(route_field, "SpinBox")
	route_axes[1].value = 2
	route_axes[3].value = 3
	var curve: Control = form.find_child("KeyframeGraph", true, false).get_parent()
	collect(curve, "SpinBox")[1].value = 1
	press(form, "保存")
	form.hide()
	var rules := {"function": "course_rules", "content": "project-course-rules"}
	app.project_shell.content_editor._library.open()
	choose(collect(popup(), "OptionButton")[0], "round_rules")
	press(popup(), "新建…")
	await process_frame
	form = popup()
	inputs = collect(form, "LineEdit")
	inputs[0].text = "Three inputs"
	inputs[1].text = "three-inputs"
	collect(form, "SpinBox")[0].value = 3
	press(form, "保存")
	form.hide()
	var round_target := {"function": "round_rules", "content": "project-three-inputs"}
	app.project_shell.content_editor._library.open()
	choose(collect(popup(), "OptionButton")[0], "round_host")
	press(popup(), "新建…")
	await process_frame
	form = popup()
	inputs = collect(form, "LineEdit")
	inputs[0].text = "Host role"
	inputs[1].text = "relay-host"
	press(form, "保存")
	form.hide()
	var host_target := {"function": "round_host", "content": "project-relay-host"}
	await add_screen("results", "Play a procedural course", {"module": "map-results"}, rules)
	app._set_mode("map")
	Generator.open(app)
	var create := popup()
	create.find_child("GeneratedMapName", true, false).text = "course"
	var presets: OptionButton = create.find_child("MapGeneratorPreset", true, false)
	check(presets.item_count == 2 and "project-course-rules" in presets.get_item_text(1),
		"generation offers the saved project content")
	presets.select(1)
	presets.item_selected.emit(1)
	choose(create.find_child("GeneratorField_projection", true, false), "isometric")
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
	check(canvas.extract().objects.map(func(row): return int(row.y)) == [3, 4],
		"the game generator uses both the authored route and elevation curve")
	var snapshot: Dictionary = canvas.extract().meta.generatorSource.parameters
	check(snapshot.size() == 4 and snapshot.has_all(["projection", "placements", "route", "elevation"]),
		"generation snapshots only selected fields")
	var pawn: EntityNode = canvas._ent_by_code_index()["R000"]
	var pawn_code := pawn.code
	var map_code := canvas.cur_map_code()
	check(Maps.read(manifest, "course").is_empty(), "the new map is still unpublished")
	MapFlowDialog.open(app)
	var first_outlets := popup()
	var self_target := JSON.stringify({"map": map_code})
	var first_exit: OptionButton = first_outlets.find_child("MapFlow_completed", true, false)
	check(range(first_exit.item_count).any(func(i):
		return first_exit.get_item_metadata(i) == self_target and first_exit.get_item_text(i).begins_with("当前地图")),
		"the unpublished map is an actual destination option")
	choose(first_exit, "")
	choose(first_exit, self_target)
	press(first_outlets, "应用")
	app._set_mode("content", pawn_code)
	var exit_picker: OptionButton = app.project_shell.content_editor.root.find_child("InstanceValue_exit_target", true, false)
	choose(exit_picker, JSON.stringify({"map": map_code}))
	check(pawn.props.get("exit_target") == {"map": map_code}, "the same instance outlet accepts a stable map target")
	app.project_shell.content_editor.commit_fields()
	var base: Dictionary = await app._map_file_ctrl.commit_document("发布地图与本图接线")
	var first_map := Maps.read(manifest, "course")
	check(base.get("status") == "ok" and first_map.meta.flowOutputs.completed == {"map": map_code}
		and first_map.objects[0].props.exit_target == {"map": map_code}, "publish the new map and both self-links together")
	choose(exit_picker, JSON.stringify({"function": "signal", "content": "project-finished"}))
	var delete_reason: String = app.project_shell.content_editor._form._delete_blocked_reason("signal", "project-finished")
	check(pawn_code in delete_reason, "an unsaved content destination protects the referenced item")
	choose(exit_picker, JSON.stringify({"view": "results"}))
	app.project_shell.content_editor.commit_fields()
	var live_uses := Usage.view_inbound_refs(manifest, "results", [], canvas.extract(), "course")
	check(live_uses.refs.any(func(ref): return pawn_code in ref and "exit_target" in ref),
		"a live map instance prevents deleting its destination")
	app._set_mode("map")
	var published: Dictionary = await app._map_file_ctrl.commit_document("保存教学关卡")
	check(published.get("status") == "ok", "publish the destination map")
	var saved_uses := Usage.view_inbound_refs(manifest, "results", [])
	check(saved_uses.refs.any(func(ref): return pawn_code in ref and "exit_target" in ref),
		"the saved map instance protects the same destination")
	app._set_mode("content", pawn_code)
	exit_picker = app.project_shell.content_editor.root.find_child("InstanceValue_exit_target", true, false)
	choose(exit_picker, "")
	app.project_shell.content_editor.commit_fields()
	app._set_mode("map")
	MapFlowDialog.open(app)
	var map_flow := popup()
	var completed: OptionButton = map_flow.find_child("MapFlow_completed", true, false)
	choose(completed, JSON.stringify({"function": "signal", "content": "project-finished"}))
	var round_slot: OptionButton = map_flow.find_child("MapContent_round", true, false)
	choose(round_slot, JSON.stringify(round_target))
	press(map_flow, "应用并编辑内容…")
	await process_frame
	form = popup()
	check(form.find_child("ReferenceContextMap", true, false).get_selected_metadata() == map_code,
		"editing the bound rules opens with the owning map selected")
	choose(field_control(form, "role"), JSON.stringify(host_target))
	choose(field_control(form, "retry"), JSON.stringify({"map": map_code}))
	press(form, "保存")
	form.hide()
	app.project_shell.content_editor._library._open_item(host_target.function, host_target.content, map_code)
	form = popup()
	choose(field_control(form, "host"), pawn_code)
	press(form, "保存")
	form.hide()
	delete_reason = app.project_shell.content_editor._form._delete_blocked_reason("signal", "project-finished")
	check("地图出口" in delete_reason, "an unsaved map outlet protects its destination content")
	delete_reason = app.project_shell.content_editor._form._delete_blocked_reason(round_target.function, round_target.content)
	check("地图内容" in delete_reason, "an unsaved round slot protects the reusable rules")
	MapFlowDialog.open(app)
	map_flow = popup()
	completed = map_flow.find_child("MapFlow_completed", true, false)
	choose(completed, JSON.stringify({"view": "results"}))
	var retiring := {"map": map_code, "inst": "R001", "port": "door"}
	choose(map_flow.find_child("MapFlow_retry", true, false), JSON.stringify(retiring))
	press(map_flow, "应用")
	published = await app._map_file_ctrl.commit_document("保存地图级出口")
	check(published.get("status") == "ok", "publish the map-level completion outlet")
	app._set_mode("content", pawn_code)
	exit_picker = app.project_shell.content_editor.root.find_child("InstanceValue_exit_target", true, false)
	choose(exit_picker, JSON.stringify({"view": "results"}))
	var landing: Node = app.project_shell.content_editor.root.find_child("InstanceValue_landing", true, false)
	var coordinates := collect(landing, "SpinBox")
	coordinates[0].value = 71
	coordinates[1].value = 32
	app.project_shell.content_editor.commit_fields()
	var authored_landing: Array = canvas._ent_by_code_index()[pawn_code].props.get("landing", [])
	check(authored_landing == [71.0, 32.0], "author a point in map space: %s" % [authored_landing])
	app._set_mode("map")
	var previous: EntityNode = canvas._ent_by_code_index()["R001"]
	var previous_position := previous.position
	canvas.commit_selection(previous)
	canvas.delete_selection()
	var next: EntityNode = canvas._tool_ops_ctrl.place_object(pawn.asset, 0, previous_position, true)
	var replacement := {"map": map_code, "inst": next.code, "port": "door"}
	check(not Maps.read(manifest, "course").objects.any(func(row): return row.code == next.code),
		"the replacement door only exists in the working map before rewiring")
	MapFlowDialog.open(app)
	map_flow = popup()
	choose(map_flow.find_child("MapFlow_retry", true, false), JSON.stringify(replacement))
	press(map_flow, "应用")
	app._set_mode("content", pawn_code)
	exit_picker = app.project_shell.content_editor.root.find_child("InstanceValue_exit_target", true, false)
	choose(exit_picker, JSON.stringify(replacement))
	app.project_shell.content_editor.commit_fields()
	published = await app._map_file_ctrl.commit_document("保存地图和实例出口")
	var rewired := Maps.read(manifest, "course")
	check(published.get("status") == "ok" and rewired.meta.flowOutputs.retry == replacement
		and rewired.objects[0].props.exit_target == replacement,
		"publish both outlets together with the replacement door")
	app._set_mode("content")
	var editor = app.project_shell.content_editor
	editor._library._open_item("signal", "project-finished")
	form = popup()
	choose(form.find_child("ReferenceContextMap", true, false), map_code)
	choose(field_control(form, "actor"), pawn_code)
	press(form, "保存")
	form.hide()
	editor._library.open()
	choose(collect(popup(), "OptionButton")[0], "sequence")
	press(popup(), "新建…")
	await process_frame
	form = popup()
	inputs = collect(form, "LineEdit")
	inputs[0].text = "Epilogue sequence"
	inputs[1].text = "epilogue"
	press(form, "保存并编辑演出")
	await process_frame
	editor._steps._steps_add("HDOF")
	var sequence: PopupPanel = editor._steps._steps_pop
	choose(field_control(sequence, "board"), map_code)
	sequence.hide()
	var timeline_target := {"function": "sequence", "content": "project-epilogue"}
	app._set_mode("content", pawn_code)
	exit_picker = app.project_shell.content_editor.root.find_child("InstanceValue_exit_target", true, false)
	choose(exit_picker, JSON.stringify({"map": map_code}))
	var local_picker: OptionButton = app.project_shell.content_editor.root.find_child("InstanceValue_local_signal", true, false)
	var original_signal := {"function": "signal", "content": "project-finished"}
	choose(local_picker, JSON.stringify(original_signal))
	app.project_shell.content_editor.commit_fields()
	app._set_mode("map")
	published = await app._map_file_ctrl.commit_document("保存实例重试出口")
	check(published.get("status") == "ok", "publish the self-directed instance outlet")
	app._map_file_ctrl.on_duplicate()
	var copy_popup := popup()
	collect(copy_popup, "LineEdit")[0].text = "course_variant"
	press(copy_popup, "复制")
	var copy := Maps.read(manifest, "course_variant")
	if not check(not copy.is_empty(), "copy the authored map and scoped content from the editor"):
		quit(1)
		return
	check(copy.meta.gridProjection == "isometric" and copy.tiles.values().all(func(layer): return layer.is_empty()),
		"the target is a saved isometric map with no painted tiles")
	var copy_code: String = copy.meta.code
	var copy_host: String = copy.objects[0].code
	var copy_rules: Dictionary = copy.meta.contentSlots.round
	var copy_fields: Dictionary = Store.read(manifest, copy_rules.function, copy_rules.content).fields
	var copy_role: Dictionary = copy_fields.ROLE
	var source := Maps.read(manifest, "course")
	var local_signal: Dictionary = copy.objects[0].props.local_signal
	check(local_signal.content != original_signal.content and source.objects[0].props.local_signal == original_signal
		and Store.read(manifest, local_signal.function, local_signal.content).fields.ACTR == copy_host,
		"the instance outlet alone brings its map-scoped signal into the copy")
	var copy_arrival := {"map": copy_code, "inst": copy_host, "port": "door"}
	var copy_retry := {"map": copy_code, "inst": copy.objects[1].code, "port": "door"}
	check(copy.meta.flowOutputs == {"completed": {"view": "results"}, "retry": copy_retry}
		and copy.objects[0].props.exit_target == {"map": copy_code} and copy_fields.RTRY == {"map": copy_code}
		and source.meta.flowOutputs.retry == replacement
		and source.objects[0].props.exit_target == {"map": map_code}
		and Store.read(manifest, round_target.function, round_target.content).fields.RTRY == {"map": map_code},
		"self-directed outlets follow the copy, and the screen outlet and source remain intact")
	check(copy_rules.content != round_target.content and copy_host != pawn_code
		and copy_role.content != host_target.content
		and Store.read(manifest, copy_role.function, copy_role.content).fields.HOST == copy_host
		and Store.read(manifest, host_target.function, host_target.content).fields.HOST == pawn_code
		and Store.read(manifest, round_target.function, round_target.content).fields.ROLE == host_target,
		"the copy owns both documents on the remapped path; the source documents are unchanged")
	app.project_shell.content_editor._library._open_item(copy_role.function, copy_role.content, copy_code)
	form = popup()
	var bound_port: Control
	for row in collect(form, "HBoxContainer"):
		if row.get_meta("field_id", "") == "relay_port":
			bound_port = row.get_child(1)
			break
	if not check(bound_port != null, "open the copied role's port field"):
		quit(1)
		return
	var bound_map: OptionButton = bound_port.find_child("ReferenceTargetMap", true, false)
	check(bound_map.get_selected_metadata() == "", "bound content starts with its inherited map")
	choose(bound_port.find_child("ReferenceTargetValue", true, false), JSON.stringify({"map": "", "inst": copy_host, "port": "wire"}))
	choose(bound_map, map_code)
	var upstream_port := {"map": map_code, "inst": pawn_code, "port": "wire"}
	choose(bound_port.find_child("ReferenceTargetValue", true, false), JSON.stringify(upstream_port))
	press(form, "保存")
	form.hide()
	check(Store.read(manifest, copy_role.function, copy_role.content).fields.RPOR == upstream_port,
		"the bound role can persist an explicit port on another map")
	app._set_mode("content")
	await add_screen("instructions", "Enter course", {"module": "course-door"}, copy_arrival)
	await add_screen("settings", "Apply options", {"module": "player-options"}, {"view": "instructions"})
	await add_screen("welcome", "Start tutorial", {"module": "signal-latch"}, {"view": "instructions"})
	app.project_shell.content_editor._library._open_item("sequence", "project-epilogue", copy_code)
	form = popup()
	choose(field_control(form, "host"), copy_host)
	press(form, "保存")
	form.hide()
	await add_screen("debrief", "Read results", {"module": "map-debrief"}, timeline_target)
	app.project_shell.content_editor._library.open()
	press(popup(), "流程关系…")
	await process_frame
	var flow := popup()
	var rules_key := "course_rules\u0001project-course-rules"
	var targets: OptionButton = flow.find_child("FlowTarget", true, false)
	choose(flow.find_child("FlowSource", true, false), "@view\u0001welcome")
	check(range(1, targets.item_count).all(func(i): return targets.get_item_metadata(i).has("view")),
		"a typed screen outlet offers only screens without the global enable flag")
	for id in ["debrief", "settings"]:
		choose(targets, {"view": id})
		press(flow, "应用关系")
		var welcome_view: Dictionary = manifest.views.filter(func(row): return row.view_id == "welcome")[0]
		check(welcome_view.layout.elements[0].outputs.accepted == {"view": id},
			"the typed outlet can be rewired from the graph")
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
	var sequence_key := "sequence\u0001project-epilogue"
	choose(flow.find_child("FlowSource", true, false), sequence_key)
	var slots: OptionButton = flow.find_child("FlowSlot", true, false)
	var route := [{"map": map_code}, {"function": "signal", "content": "project-finished"}]
	for destination in route:
		slots.select(slots.item_count - 1)
		slots.item_selected.emit(slots.selected)
		choose(targets, destination)
		press(flow, "应用关系")
	flow.hide()
	check(Store.read(manifest, "sequence", "project-epilogue").steps[0].fields == {
		"BRD1": map_code, "ROUT": route},
		"the timeline keeps the paired map and the graph-authored destinations in order")
	var graph := Flow.build_project(manifest)
	check(graph.edges.any(func(edge):
		return edge.from == "@map\u0001" + map_code and edge.to == "@view\u0001results" and edge.field == "completed"),
		"the project graph reads the saved outlet from the map itself")
	check(graph.edges.any(func(edge):
		return edge.from == "@map\u0001" + map_code and edge.to == "round_rules\u0001project-three-inputs" \
			and edge.get("map_section") == "contentSlots"),
		"the project graph distinguishes a saved rules binding from an outlet")
	check(graph.edges.any(func(edge): return edge.from == rules_key and edge.to == "@view\u0001debrief"),
		"the project flow graph reloads the procedural course outlet")
	check(graph.edges.any(func(edge): return edge.from == router_key and edge.to == "signal\u0001project-finished"),
		"graph reloads the mixed destination as an edge to the published target")
	var edge_exists: bool = graph.edges.any(func(edge):
		return edge.from == "@view\u0001welcome" and edge.to == "@view\u0001settings" and edge.get("output") == "accepted")
	check(edge_exists, "the project graph exposes the direct module transition")
	check(graph.edges.any(func(edge): return edge.cid == "instructions" and edge.fn == Flow.MAP_KIND and edge.value == copy_code),
		"the project graph links the teaching button to the authored map")
	editor._library.open()
	press(popup(), "流程关系…")
	await process_frame
	flow = popup()
	choose(flow.find_child("FlowSource", true, false), "@map\u0001" + copy_code)
	var direct: ItemList = flow.find_child("FlowDirectLinks", true, false)
	var outlet_index := -1
	for i in direct.item_count:
		var outlet: Dictionary = direct.get_item_metadata(i).edge
		if outlet.get("map_instance") == copy_host and outlet.field == "exit_target":
			outlet_index = i
			break
	if not check(outlet_index >= 0, "the project graph exposes the copied instance outlet"):
		quit(1)
		return
	direct.select(outlet_index)
	press(flow, "定位引用字段")
	for i in 15:
		await process_frame
		if app.cur_map_name == "course_variant" and app.project_shell._view == "content":
			break
	exit_picker = editor.root.find_child("InstanceValue_exit_target", true, false)
	if not check(app.cur_map_name == "course_variant" and exit_picker != null
			and exit_picker.get_selected_metadata() == JSON.stringify({"map": copy_code}),
			"the graph opens the correct map, instance and field"):
		quit(1)
		return
	choose(exit_picker, JSON.stringify({"view": "results"}))
	editor.commit_fields()
	published = await app._map_file_ctrl.commit_document("保存从流程图定位的实例出口")
	check(published.get("status") == "ok" and Maps.read(manifest, "course_variant").objects[0].props.exit_target == {"view": "results"},
		"the outlet can be redirected and published from the opened instance form")
	choose(exit_picker, JSON.stringify(copy_arrival))
	editor.commit_fields()
	published = await app._map_file_ctrl.commit_document("保存实例入口")
	editor._library.open()
	press(popup(), "流程关系…")
	await process_frame
	flow = popup()
	choose(flow.find_child("FlowSource", true, false), "@map\u0001" + copy_code)
	var map_slots: OptionButton = flow.find_child("FlowSlot", true, false)
	check(map_slots.get_item_text(0).begins_with("Course completed"), "the graph exposes the map's completion slot")
	var map_targets: OptionButton = flow.find_child("FlowTarget", true, false)
	choose(map_targets, {"view": "debrief"})
	press(flow, "应用关系")
	check(canvas.extract().meta.flowOutputs.completed == {"view": "debrief"}
		and Maps.read(manifest, "course_variant").meta.flowOutputs.completed == {"view": "results"},
		"graph rewires the working map without publishing it")
	check(await canvas.undo() and canvas.extract().meta.flowOutputs.completed == {"view": "results"},
		"the graph edit can be undone before saving")
	app._set_mode("map")
	var current_host: EntityNode = canvas._ent_by_code_index()[copy_host]
	app._set_mode("content", copy_host)
	var signal_port: Control = app.project_shell.content_editor.root.find_child("InstanceReference_signal_port", true, false)
	var target_map: OptionButton = signal_port.find_child("ReferenceTargetMap", true, false)
	check(target_map.get_selected_metadata() == "", "instance offers the working map by default")
	choose(target_map, map_code)
	check(not current_host.props.has("signal_port"), "switching candidate map does not write a reference")
	var remote_port := {"map": map_code, "inst": pawn_code, "port": "wire"}
	choose(signal_port.find_child("ReferenceTargetValue", true, false), JSON.stringify(remote_port))
	check(current_host.props.get("signal_port") == remote_port, "instance chooses an explicit port on another map")
	app._set_mode("map")
	check(canvas.duplicate_selected_at_offset([current_host], Vector2i(2, 2)), "duplicate a portal with its own arrival")
	var new_host: EntityNode = canvas.selected_multi[0]
	var new_host_code := new_host.code
	check(new_host.code != copy_host and new_host.props.exit_target == {
		"map": copy_code, "inst": new_host.code, "port": "door"} and current_host.props.exit_target == copy_arrival,
		"only the duplicated portal points to the duplicated arrival instance")
	published = await app._map_file_ctrl.commit_document("保存复制的局部入口")
	copy = Maps.read(manifest, "course_variant")
	check(published.get("status") == "ok" and copy.objects[-1].props.exit_target.inst == new_host.code,
		"the copied portal keeps its independent arrival after publication")
	check(copy.objects[0].props.get("signal_port") == remote_port
		and copy.objects[-1].props.get("signal_port") == remote_port,
		"the original and copy keep the same explicit port on the other map")
	var shared := await author_scoped_drawing(canvas, map_code, copy_code, current_host.asset,
		{"function": "signal", "content": "project-finished"})
	if shared.is_empty():
		quit(1)
		return
	var inbound := Usage.view_inbound_refs(manifest, "settings", [])
	check(not inbound.refs.is_empty() and "welcome" in inbound.refs[0], "the destination screen has the expected inbound reference")
	var broken := manifest.duplicate(true)
	var welcome: Dictionary = broken.views.filter(func(row): return row.view_id == "welcome")[0]
	welcome.layout.elements[0].outputs.accepted.view = "missing-screen"
	check(ScreenReferences.view_reference_issues(broken, "welcome").any(func(issue): return issue.path.ends_with(".outputs.accepted")),
		"diagnostics identify the particular missing destination")
	press(app, "启动入口…")
	var startup := popup()
	choose(startup.find_child("StartupTarget", true, false), {"view": "welcome"})
	press(startup, "保存启动入口")
	app._clear_project_session()
	app.manifest = Manifest.load_from(project)
	app._build_editor_ui()
	app._set_mode("content")
	check(app.manifest.startup.target == {"view": "welcome"}, "the authored screen is published as startup")
	var settings: Dictionary = app.manifest.views.filter(func(row): return row.view_id == "settings")[0]
	check(has_options(settings.layout.elements[0].props, 65, true)
		and settings.layout.elements[0].outputs.accepted == {"view": "instructions"},
		"reopen the authored settings module with its defaults and Apply destination")
	press(app, "试玩项目")
	var controller = app._playtest_ctrl
	var end := Time.get_ticks_msec() + 12000
	while controller._play_report_result.is_empty() and Time.get_ticks_msec() < end:
		await create_timer(0.05).timeout
		controller.poll_playtest()
	var report: Dictionary = controller._play_report_result
	var result: Dictionary = report.get("result", {})
	check(report.get("status") == "ready" and result.get("screens") == ["welcome", "settings", "instructions", "results", "debrief"]
		and has_options(result.get("settingsBefore", {}), 65, true)
		and has_options(result.get("settingsApplied", {}), 35, false)
		and is_equal_approx(float(result.get("masterVolume", -1)), 0.35)
		and result.get("captionVisible") == false
		and result.get("courseNotice") == "Screen sequence complete" and result.get("sharedDrawings") == [shared]
		and result.get("visited") == ["project-course-rules", "project-epilogue", "project-finished"]
		and result.get("handoffTargets") == route
		and result.get("endingActor") == pawn_code and result.get("endingBoard") == map_code
		and result.get("runtimeCourse", []).map(func(x): return int(x)) == [3, 5] and result.get("board") == copy_code
		and result.get("runtimeRows", []).map(func(y): return int(y)) == [3, 4]
		and result.get("debriefBoard") == copy_code and result.get("debriefHost") == copy_host
		and result.get("roundRules") == copy_rules.content and result.get("roundInputs") == 3
		and result.get("roundHost") == copy_host
		and result.get("roundRelayPort") == upstream_port
		and result.get("localActor") == copy_host
		and result.get("arrivalPort") == "door" and result.get("arrivalInstance") == copy_host
		and result.get("screenMarker") == {"map": copy_code, "inst": copy_host, "port": "wire"}
		and result.get("screenCrossing") == {"map": copy_code, "cell": [1.0, 1.0], "edge": "1,1|2,1"}
		and result.get("screenCheckpoint") == {"map": copy_code, "cell": [2.0, 2.0], "edge": "2,2|3,2"}
		and result.get("remotePort") == remote_port
		and result.get("placed") == copy.objects.map(func(row): return row.code) and result.get("text") == "Screen sequence complete",
		"the game reads the map-level completion outlet and reaches the conclusion: %s" % [report])
	end = Time.get_ticks_msec() + 2000
	while Playtest.is_alive(controller._play_pid) and Time.get_ticks_msec() < end:
		await create_timer(0.05).timeout
	app.project_shell.content_editor._library.open()
	press(popup(), "流程关系…")
	await process_frame
	flow = popup()
	choose(flow.find_child("FlowSource", true, false), "@map\u0001" + copy_code)
	var entries: OptionButton = flow.find_child("FlowPlayMapEntry", true, false)
	check(entries.item_count == copy.objects.size() + 1, "entry choices exclude other maps and ports of other types")
	choose(entries, {"map": copy_code, "inst": new_host_code, "port": "door"})
	press(flow, "试玩所选地图")
	end = Time.get_ticks_msec() + 8000
	while controller._play_report_result.is_empty() and Time.get_ticks_msec() < end:
		await create_timer(0.05).timeout
		controller.poll_playtest()
	report = controller._play_report_result
	result = report.get("result", {})
	check(report.get("status") == "ready" and result.get("board") == copy_code
		and result.get("arrivalPort") == "door" and result.get("arrivalInstance") == new_host_code
		and has_options(result.get("settingsOnBoot", {}), 35, false)
		and result.get("screens") == ["results", "debrief"]
		and result.get("text") == "Screen sequence complete"
		and app.manifest.startup.target == {"view": "welcome"},
		"the selected arrival starts the normal map flow without changing project startup: %s" % [report])
	end = Time.get_ticks_msec() + 2000
	while Playtest.is_alive(controller._play_pid) and Time.get_ticks_msec() < end:
		await create_timer(0.05).timeout
	app.project_shell.content_editor._library.open()
	press(popup(), "流程关系…")
	await process_frame
	flow = popup()
	choose(flow.find_child("FlowSource", true, false), "@map\u0001" + map_code)
	choose(flow.find_child("FlowPlayMapEntry", true, false), {"map": map_code})
	press(flow, "试玩所选地图")
	end = Time.get_ticks_msec() + 8000
	while controller._play_report_result.is_empty() and Time.get_ticks_msec() < end:
		await create_timer(0.05).timeout
		controller.poll_playtest()
	report = controller._play_report_result
	result = report.get("result", {})
	check(report.get("status") == "ready" and result.get("board") == map_code
		and result.get("sharedDrawings") == [] and not result.has("courseNotice"),
		"the game omits both the shared drawing and event on the excluded map: %s" % [report])
	end = Time.get_ticks_msec() + 2000
	while Playtest.is_alive(controller._play_pid) and Time.get_ticks_msec() < end:
		await create_timer(0.05).timeout
	var arrival := {"map": copy_code, "inst": new_host_code, "port": "door"}
	press(app, "启动入口…")
	startup = popup()
	choose(startup.find_child("StartupTarget", true, false), arrival)
	press(startup, "保存启动入口")
	app._clear_project_session()
	app.manifest = Manifest.load_from(project)
	app._build_editor_ui()
	check(app.manifest.startup.target == arrival, "the new formal entrance persists through reload")
	press(app, "试玩项目")
	controller = app._playtest_ctrl
	end = Time.get_ticks_msec() + 8000
	while controller._play_report_result.is_empty() and Time.get_ticks_msec() < end:
		await create_timer(0.05).timeout
		controller.poll_playtest()
	report = controller._play_report_result
	result = report.get("result", {})
	check(report.get("status") == "ready" and result.get("board") == copy_code
		and result.get("arrivalPort") == "door" and result.get("arrivalInstance") == new_host_code
		and result.get("screens") == ["results", "debrief"] and result.get("text") == "Screen sequence complete",
		"the normal project launch enters the saved door without a screen or playtest entry override: %s" % [report])
	end = Time.get_ticks_msec() + 2000
	while Playtest.is_alive(controller._play_pid) and Time.get_ticks_msec() < end:
		await create_timer(0.05).timeout
	app.project_shell.content_editor._library.open()
	press(popup(), "流程关系…")
	await process_frame
	flow = popup()
	choose(flow.find_child("FlowSource", true, false), "@project\u0001root")
	choose(flow.find_child("FlowTarget", true, false), timeline_target)
	var startup_board: OptionButton = flow.find_child("FlowStartupContentMap", true, false)
	check(startup_board.is_visible_in_tree(), "the project slot offers a paired map for content startup")
	choose(startup_board, copy_code)
	press(flow, "应用关系")
	check(app.manifest.startup.target == timeline_target and app.manifest.startup.contentMap == copy_code,
		"the graph publishes the content and its board together")
	flow.hide()
	app._clear_project_session()
	app.manifest = Manifest.load_from(project)
	app._build_editor_ui()
	press(app, "试玩项目")
	controller = app._playtest_ctrl
	end = Time.get_ticks_msec() + 8000
	while controller._play_report_result.is_empty() and Time.get_ticks_msec() < end:
		await create_timer(0.05).timeout
	report = controller._play_report_result
	result = report.get("result", {})
	check(report.get("status") == "ready" and result.get("screens", []).is_empty()
		and result.get("debriefBoard") == copy_code and result.get("debriefHost") == copy_host
		and result.get("visited") == ["project-epilogue", "project-finished"],
		"ordinary launch starts map-bound content directly and reaches its authored ending: %s" % [report])
	end = Time.get_ticks_msec() + 2000
	while Playtest.is_alive(controller._play_pid) and Time.get_ticks_msec() < end:
		await create_timer(0.05).timeout
	var saved_startup: Dictionary = app.manifest.startup.duplicate(true)
	app.project_shell.content_editor._library.open()
	var library := popup()
	choose(collect(library, "OptionButton")[0], "sequence")
	var rows: ItemList = collect(library, "ItemList")[0]
	for i in rows.item_count:
		if rows.get_item_metadata(i) == timeline_target.content:
			rows.select(i)
			rows.item_selected.emit(i)
			break
	choose(library.find_child("ContentPlaytestMap", true, false), map_code)
	press(library, "试玩所选内容")
	end = Time.get_ticks_msec() + 8000
	while controller._play_report_result.is_empty() and Time.get_ticks_msec() < end:
		await create_timer(0.05).timeout
		controller.poll_playtest()
	report = controller._play_report_result
	result = report.get("result", {})
	check(report.get("status") == "ready" and result.get("debriefBoard") == map_code \
		and result.get("visited") == ["project-epilogue", "project-finished"] \
		and Manifest.load_from(project).startup == saved_startup,
		"the library launches the same content on another board without changing published startup: %s" % [report])
	print("SCREEN-NAV-DONE failures=", failures)
	quit(0 if failures == 0 else 1)

func field_control(node: Node, id: String) -> OptionButton:
	for row in collect(node, "HBoxContainer"):
		if row.get_meta("field_id", "") == id:
			return row.get_child(1) as OptionButton
	return null

func has_options(values: Dictionary, volume: int, captions: bool) -> bool:
	return values.get("volume") == volume and values.get("captions") == captions

func author_scoped_drawing(canvas: EditorCanvas, excluded: String, included: String,
		asset: String, target: Dictionary) -> Dictionary:
	app.project_shell.content_editor._library.open()
	press(popup(), "图组事件…")
	await process_frame
	var pop := popup()
	press(pop, "新建层")
	collect(pop, "LineEdit")[0].text = "Course overlay"
	for box in collect(pop, "CheckBox"):
		if box.text == "适用于全部地图":
			box.button_pressed = false
		elif box.text.ends_with("[%s]" % included):
			box.button_pressed = true
	var selectors := collect(pop, "OptionButton")
	var layer_id: String = selectors[0].get_selected_metadata()
	choose(selectors.back(), JSON.stringify(target))
	var previous_path: String = app.cur_map_path
	press(pop, "保存并编辑绘制层")
	for i in 30:
		await process_frame
		if app.cur_map_path != previous_path:
			break
	var row: Dictionary = app.manifest.get("eventLayers", {}).get(layer_id, {})
	var drawing: String = row.get("drawingMap", "")
	if not check(not drawing.is_empty() and canvas.cur_map_code() == drawing
			and row.get("maps") == [included] and row.get("events", {}).get("NTCE") == target,
			"save and open a shared drawing and typed event for the selected map only"):
		return {}
	var placed: EntityNode = canvas._tool_ops_ctrl.place_object(asset, 0, Vector2(24, 44), true)
	if not check(placed != null, "place %s on the independent drawing (ready=%s layers=%s locked=%s placeable=%s)" % [
			asset, canvas.is_map_ready(), canvas.layer_count(), canvas.is_layer_locked(0), canvas.is_placeable(asset)]):
		return {}
	var instance := placed.code
	var saved: Dictionary = await app._map_file_ctrl.commit_document("保存教学共享绘制层")
	if not check(saved.get("status") == "ok", "publish the shared drawing object"):
		return {}
	canvas.show_event_context = true
	await app._map_file_ctrl.open_map_by_code(excluded)
	check(canvas.cur_map_code() == excluded and canvas._context_drawings.is_empty(),
		"an excluded map has no shared drawing context")
	await app._map_file_ctrl.open_map_by_code(included)
	check(canvas.cur_map_code() == included and canvas._context_drawings.size() == 1
		and canvas._context_drawings[0].cur_map_code() == drawing,
		"the included map mounts the saved shared drawing as a separate document")
	return {"code": drawing, "instances": [instance]}

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
	if module.get("module") == "signal-latch":
		pop.find_child("LayoutModuleField_presses", true, false).value = 2
	if module.get("module") == "player-options":
		var volume: SpinBox = pop.find_child("LayoutModuleField_volume", true, false)
		var captions: CheckBox = pop.find_child("LayoutModuleField_captions", true, false)
		check(volume.value == 100 and not captions.button_pressed, "the editor renders the module's declared defaults")
		volume.value = 65
		captions.button_pressed = true
	if module.get("module") == "course-door":
		var marker: Control = pop.find_child("LayoutModuleField_marker", true, false)
		var map: OptionButton = marker.find_child("ReferenceTargetMap", true, false)
		choose(map, target.map)
		var port: OptionButton = marker.find_child("ReferenceTargetValue", true, false)
		check(port.item_count > 1 and range(1, port.item_count).all(func(i):
			return JSON.parse_string(port.get_item_metadata(i)).port == "wire"),
			"unpaired module field offers the selected map's ports of the declared type")
		var crossing: Control = pop.find_child("LayoutModuleField_crossing", true, false)
		choose(crossing.find_child("ReferenceTargetMap", true, false), target.map)
		var edges: OptionButton = crossing.find_child("ReferenceTargetValue", true, false)
		check(edges.item_count == 1, "the occupied-edge dropdown has no choices")
		if not await pick_relay_reference(pop, "crossing", target.map):
			return
		if not await pick_relay_reference(pop, "marker", target.map):
			return
		var checkpoint: Control = pop.find_child("LayoutModuleField_checkpoint", true, false)
		choose(checkpoint.find_child("ReferenceTargetMap", true, false), target.map)
		var coordinates: LineEdit = checkpoint.find_child("EdgeCoordinates", true, false)
		coordinates.text = "0,0|2,2"
		coordinates.text_submitted.emit(coordinates.text)
		check(checkpoint.find_child("EdgeCoordinatesStatus", true, false).visible,
			"coordinate entry rejects two cells that do not share an edge")
		coordinates.text = "3,2|2,2"
		coordinates.text_submitted.emit(coordinates.text)
		check(coordinates.text == "2,2|3,2", "coordinate entry accepts and orders an empty-map edge")
	var control: OptionButton = pop.find_child("LayoutElementTarget" if module.is_empty() else "LayoutOutput_accepted", true, false)
	choose(control, target)
	press(pop, "保存参考视图")
	check(not pop.visible, "publish screen " + id)
	await process_frame

func pick_relay_reference(pop: PopupPanel, field: String, map_code: String) -> bool:
	var widget: Control = pop.find_child("LayoutModuleField_" + field, true, false)
	choose(widget.find_child("ReferenceTargetMap", true, false), map_code)
	var picker: Button = pop.find_child("FrameFieldReference_" + field, true, false)
	if not check(picker != null, "unpaired module field offers the game frame picker: " + field):
		return false
	picker.pressed.emit()
	var preview := popup()
	var render: Button = preview.find_child("MapGamePreviewRender", true, false)
	if not check(render != null and render.text == "渲染目标地图", "the picker targets the selected saved map: " + field):
		return false
	choose(preview.find_child("MapGamePreviewViewport", true, false), "handheld")
	render.pressed.emit()
	var until := Time.get_ticks_msec() + 8000
	while render.disabled and Time.get_ticks_msec() < until:
		await process_frame
	var shot: TextureRect = preview.find_child("MapGamePreviewFrame", true, false)
	if not check(shot.texture != null, "load the game-rendered map"):
		preview.hide()
		return false
	await process_frame
	var image := shot.texture.get_image()
	var pixel := Vector2(-1, -1)
	for y in image.get_height():
		for x in image.get_width():
			if image.get_pixel(x, y).is_equal_approx(Color("#ffbe54")):
				pixel = Vector2(x, y + 2)
				break
		if pixel.x >= 0:
			break
	var extent := Vector2(image.get_size())
	var fit := minf(shot.size.x / extent.x, shot.size.y / extent.y)
	var mouse := InputEventMouseButton.new()
	mouse.button_index = MOUSE_BUTTON_LEFT
	mouse.pressed = true
	mouse.position = (shot.size - extent * fit) * 0.5 + pixel * fit
	shot.gui_input.emit(mouse)
	var confirm: Button = preview.find_child("MapGamePreviewConfirmPick", true, false)
	if not check(not confirm.disabled, "the game image identifies a compatible target: " + field):
		preview.hide()
		return false
	confirm.pressed.emit()
	await process_frame
	await process_frame
	return true

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
