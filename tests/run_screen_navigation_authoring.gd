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
	var declaration := {"projectName": "Screen Navigation", "directMapTargets": true,
		"assets": [{"id": "relay", "kind": "entity", "code": "RLY1", "visual": {"mode": "rect", "color": "#62cabb"},
			"ports": [{"id": "door", "x": 0, "y": 0, "type": "arrival"}, {"id": "wire", "x": 4, "y": 0, "type": "signal"}],
			"fields": [{"id": "exit_target", "kind": "input", "type": "flow_target",
				"maps": true, "screens": true, "contentTypes": ["signal"], "arrivalPorts": ["arrival"]},
				{"id": "landing", "kind": "input", "type": "vector2", "pickSpace": "map", "step": 1},
				{"id": "signal_port", "kind": "input", "type": "port_ref", "of": "signal"},
				{"id": "local_signal", "kind": "input", "type": "flow_target",
					"contentTypes": ["signal"], "contentMapContext": "inherit"}]}],
		"startup": {"screens": true}, "viewports": [{"id": "handheld", "w": 480, "h": 720}],
		"mapOutputs": {"completed": {"name": "Course completed",
			"maps": true, "screens": true, "contentTypes": ["signal"], "arrivalPorts": ["arrival"]},
			"retry": {"name": "Retry the course", "arrivalPorts": ["arrival"]}},
		"mapContentSlots": {"round": {"name": "Round rules",
			"contentTypes": ["round_rules"], "contentMapContext": "inherit"},
			"course": {"name": "Generated course rules", "contentTypes": ["course_rules"]}},
		"mapGenerators": {"course": {"contentType": "course_rules",
			"parameterFields": ["projection", "placements"]}},
		"preview": {"version": 1, "executable": OS.get_executable_path(), "capabilities": ["generateMap"],
			"args": ["--headless", "--path", "%projectpath%", "--"]},
		"screenModules": {"course-door": {"outputs": {"accepted": {"name": "Enter", "arrivalPorts": ["arrival"]}},
			"fields": [{"id": "marker", "kind": "input", "type": "port_ref", "of": "signal"}]},
			"signal-latch": {"name": "Latch", "outputs": {"accepted": {"name": "Continue", "screens": true}}, "fields": [
			{"id": "presses", "kind": "input", "type": "int", "min": 1, "default": 1}]}},
		"functions": {"course_rules": {"code": "CRUL", "name": "Course rules", "fields": [
			{"id": "projection", "code": "PROJ", "kind": "choice", "options": ["orthogonal", "isometric"]},
			{"id": "placements", "code": "PLAC", "kind": "input", "type": "array", "of": "record", "fields": [
				{"id": "asset", "code": "ASST", "kind": "input", "type": "asset_ref", "assetKind": "entity"},
				{"id": "column", "code": "COLM", "kind": "input", "type": "int", "min": 1, "max": 10}]},
			{"id": "next", "code": "CNXT", "kind": "input", "type": "flow_target",
				"maps": true, "screens": true, "contentTypes": ["signal"]}]},
			"sequence": {"code": "SEQN", "name": "Sequence", "steps": true},
			"round_rules": {"code": "ROND", "name": "Round rules", "fields": [
				{"id": "inputs", "code": "INPT", "kind": "input", "type": "int", "min": 1, "max": 4},
				{"id": "role", "code": "ROLE", "kind": "input", "type": "flow_target",
					"contentTypes": ["round_host"], "contentMapContext": "inherit"},
				{"id": "retry", "code": "RTRY", "kind": "input", "type": "flow_target", "maps": true}]},
			"round_host": {"code": "RHST", "name": "Round host", "fields": [
				{"id": "host", "code": "HOST", "kind": "choice", "source": "entity_inst:relay"}]},
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
			"mapEntryPorts": ["arrival"],
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
	check(Audit._ref_checks(canvas.extract(), orphan_manifest, "course").any(func(issue):
		return issue.jump.type == "map_flow" and issue.jump.field == "completed"),
		"map audit pinpoints the missing map-level destination")
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
	check(authored_landing == [71.0, 32.0], "author a point in the old map space: %s" % [authored_landing])
	app._set_mode("map")
	check(canvas.set_spawn_cell(Vector2i(4, 4)), "author a competing spawn move")
	Generator.open(app, true)
	var regenerate := popup()
	choose(regenerate.find_child("GeneratorField_projection", true, false), "isometric")
	var rerun: Button = regenerate.find_child("RunMapGenerator", true, false)
	rerun.pressed.emit()
	while rerun.disabled:
		await process_frame
	var space_choice: OptionButton = regenerate.find_child("GenerationConflict0", true, false)
	if not check(space_choice != null, "projection and spatial edits offer a resolvable conflict"):
		quit(1)
		return
	space_choice.select(2)
	space_choice.item_selected.emit(2)
	var flow_label: Array = collect(regenerate, "Label").filter(func(label):
		return label.text == "meta.flowOutputs.completed")
	if not check(flow_label.size() == 1, "regeneration offers the whole completion target as a conflict"):
		quit(1)
		return
	var flow_choice: OptionButton = collect(flow_label[0].get_parent(), "OptionButton")[0]
	flow_choice.select(1)
	flow_choice.item_selected.emit(1)
	var merge_status: Label = regenerate.find_child("GeneratedMapStatus", true, false)
	check("新增引用问题" in merge_status.text and "flowOutputs.retry" in merge_status.text and "R001" in merge_status.text,
		"regeneration names the exact outlet and retired door before applying")
	press(regenerate, "应用重生成")
	await process_frame
	var regenerated := canvas.extract()
	check(regenerated.meta.gridProjection == "isometric" and regenerated.spawn == [1, 2]
		and regenerated.meta.flowOutputs.completed == {"view": "results"}
		and regenerated.meta.contentSlots.round == round_target
		and regenerated.meta.contentSlots.course == rules
		and regenerated.objects[0].props.get("exit_target") == {"view": "results"}
		and Array(regenerated.objects[0].props.get("landing", [])).map(func(n): return int(n)) == [16, 48],
		"adopt generated geometry without erasing the map or instance outlets: %s" % [regenerated.objects[0]])
	var replacement := {"map": map_code, "inst": "R002", "port": "door"}
	check(not Maps.read(manifest, "course").objects.any(func(row): return row.code == "R002"),
		"the replacement door only exists in the working map before rewiring")
	MapFlowDialog.open(app)
	map_flow = popup()
	choose(map_flow.find_child("MapFlow_retry", true, false), JSON.stringify(replacement))
	press(map_flow, "应用")
	app._set_mode("content", pawn_code)
	exit_picker = app.project_shell.content_editor.root.find_child("InstanceValue_exit_target", true, false)
	choose(exit_picker, JSON.stringify(replacement))
	app.project_shell.content_editor.commit_fields()
	published = await app._map_file_ctrl.commit_document("保存重生成的地图和实例出口")
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
	app._set_mode("content")
	await add_screen("instructions", "Enter course", {"module": "course-door"}, copy_arrival)
	await add_screen("welcome", "Start tutorial", {"module": "signal-latch"}, {"view": "instructions"})
	await add_screen("debrief", "Read results", {}, timeline_target)
	app.project_shell.content_editor._library.open()
	press(popup(), "流程关系…")
	await process_frame
	var flow := popup()
	var rules_key := "course_rules\u0001project-course-rules"
	var targets: OptionButton = flow.find_child("FlowTarget", true, false)
	choose(flow.find_child("FlowSource", true, false), "@view\u0001welcome")
	check(range(1, targets.item_count).all(func(i): return targets.get_item_metadata(i).has("view")),
		"a typed screen outlet offers only screens without the global enable flag")
	for id in ["debrief", "instructions"]:
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
	var findings := Audit.audit(manifest)
	check(not findings.any(func(issue): return issue.get("path", "").begins_with("round_host/")),
		"the bound rules validate their local host against the owning map")
	check(not findings.any(func(issue): return issue.get("path", "").begins_with("signal/project-finished.actor")),
		"the timeline outlet propagates the selected map to the ending's local actor reference")
	check(not findings.any(func(issue): return issue.get("path", "").begins_with("signal/%s.actor" % local_signal.content)),
		"the copied instance outlet propagates its board to the local signal")
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
		return edge.from == "@view\u0001welcome" and edge.to == "@view\u0001instructions" and edge.get("output") == "accepted")
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
		and result.get("visited") == ["project-course-rules", "project-epilogue", "project-finished"]
		and result.get("handoffTargets") == route
		and result.get("endingActor") == pawn_code and result.get("endingBoard") == map_code
		and result.get("runtimeCourse", []).map(func(x): return int(x)) == [3, 5] and result.get("board") == copy_code
		and result.get("roundRules") == copy_rules.content and result.get("roundInputs") == 3
		and result.get("roundHost") == copy_host
		and result.get("localActor") == copy_host
		and result.get("arrivalPort") == "door" and result.get("arrivalInstance") == copy_host
		and result.get("screenMarker") == {"map": copy_code, "inst": copy_host, "port": "wire"}
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
		and result.get("screens") == ["results", "debrief"]
		and result.get("text") == "Screen sequence complete"
		and app.manifest.startup.target == {"view": "welcome"},
		"the selected arrival starts the normal map flow without changing project startup: %s" % [report])
	print("SCREEN-NAV-DONE failures=", failures)
	quit(0 if failures == 0 else 1)

func field_control(node: Node, id: String) -> OptionButton:
	for row in collect(node, "HBoxContainer"):
		if row.get_meta("field_id", "") == id:
			return row.get_child(1) as OptionButton
	return null

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
	if module.get("module") == "course-door":
		var marker: Control = pop.find_child("LayoutModuleField_marker", true, false)
		var map: OptionButton = marker.find_child("ReferenceTargetMap", true, false)
		choose(map, target.map)
		var port: OptionButton = marker.find_child("ReferenceTargetValue", true, false)
		check(port.item_count > 1 and range(1, port.item_count).all(func(i):
			return JSON.parse_string(port.get_item_metadata(i)).port == "wire"),
			"unpaired module field offers the selected map's ports of the declared type")
		choose(port, JSON.stringify({"map": target.map, "inst": target.inst, "port": "wire"}))
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
