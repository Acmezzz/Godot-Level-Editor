extends SceneTree
## Run separately; this workflow needs frames for real workbench popup and map lifecycles.
const RuntimeFixture := "res://tests/runtime_fixture/"
const References := preload("res://src/project/reference_index.gd")
const Audit := preload("res://src/project/project_audit.gd")
const Edge := preload("res://src/map/edge_ref.gd")
const Store = preload("res://src/content/content_store.gd")
const Maps = preload("res://src/map/map_store.gd")
const ViewportLibrary = preload("res://src/ui/viewport_library.gd")
const ReferenceViews = preload("res://src/ui/reference_view_library.gd")
const GraphEditor = preload("res://src/ui/cell_graph_editor.gd")
const WorldLayout = preload("res://src/project/world_layout.gd")
var failures := 0
func _initialize():
	create_timer(180.0).timeout.connect(func():
		printerr("FLOW FAIL: workflow timed out")
		quit(1))
	run.call_deferred()
func check(ok: bool, message: String) -> void:
	if not ok:
		printerr("FLOW FAIL: ", message)
		failures += 1
func collect(n: Node, type: String) -> Array:
	var found: Array = []
	for child in n.get_children():
		if child.is_class(type):
			found.append(child)
		found.append_array(collect(child, type))
	return found
func press(n: Node, label: String) -> void:
	for candidate in collect(n, "Button"):
		if candidate.text == label:
			candidate.pressed.emit()
			return
	check(false, "missing button " + label)
func select_metadata(opt: OptionButton, value: String) -> void:
	for i in opt.item_count:
		if str(opt.get_item_metadata(i)) == value:
			opt.select(i)
			opt.item_selected.emit(i)
			return
	check(false, "missing option " + value)

func launch_and_read(app, project_entry: bool) -> Dictionary:
	await app._map_file_ctrl.on_play(Vector2i(-1, -1), project_entry)
	return await wait_for_playtest(app._map_file_ctrl)

func wait_for_playtest(controller) -> Dictionary:
	var deadline := Time.get_ticks_msec() + 12000
	while Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout
		controller.poll_playtest()
		if int(controller._play_pid) == 0:
			return controller._play_report_result
	return controller._play_report_result

func write_fixture_audio(project: String) -> bool:
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = 8000
	var data := PackedByteArray()
	data.resize(stream.mix_rate * 5 * 2)
	for i in range(data.size() >> 1):
		var sample := int(sin(TAU * 220.0 * float(i) / stream.mix_rate) * 16384.0)
		data.encode_s16(i * 2, sample)
	stream.data = data
	return stream.save_to_wav(project.path_join("rhythm.wav")) == OK

func create_ending(app, library, id: String, message: String, map_context := "", goal := "", next := "", layer := "") -> void:
	library.open()
	var pop = collect(app, "PopupPanel").filter(func(p): return p.visible).back()
	select_metadata(collect(pop, "OptionButton").front(), "ending")
	press(pop, "新建…")
	await process_frame
	pop = collect(app, "PopupPanel").filter(func(p): return p.visible).back()
	var inputs := collect(pop, "LineEdit")
	inputs[0].text = "Ending " + id
	inputs[1].text = id
	inputs[2].text = message
	if map_context != "":
		var selector: OptionButton = pop.find_child("ReferenceContextMap", true, false)
		select_metadata(selector, map_context)
	if goal != "" or next != "":
		if id == "arrive":
			for field in ["goal", "goal_port"]:
				var pick: Button = pop.find_child("FrameFieldReference_" + field, true, false)
				check(pick != null, "library scene picker is available for " + field)
				if pick == null:
					continue
				pick.pressed.emit()
				var frame := await _render_pick_frame(app)
				if frame == null:
					continue
				var confirm := _click_pick_frame(frame, _frame_pick_at_world(frame, Vector2(72, 40)))
				check(not confirm.disabled and not Store.list_ids(app.manifest, "ending").has("project-arrive"),
					"library can select a target without publishing the draft")
				confirm.pressed.emit()
				await process_frame
				await process_frame
			var group: Button = pop.find_child("FrameFieldReference_goal_group", true, false)
			check(group != null, "library exposes the multi-target reference picker")
			if group != null:
				group.pressed.emit()
				var frame := await _render_pick_frame(app)
				if frame != null:
					var first := _frame_pick_at_world(frame, Vector2(72, 40))
					var second := _frame_pick_at_world(frame, Vector2(104, 72))
					var confirm := _click_pick_frame(frame, first)
					_click_pick_frame(frame, second)
					_click_pick_frame(frame, first)
					_click_pick_frame(frame, first)
					check(not confirm.disabled and not Store.list_ids(app.manifest, "ending").has("project-arrive"),
						"multiple targets and toggles stay in one draft until confirmation")
					confirm.pressed.emit()
					await process_frame
					await process_frame
			var route: Button = pop.find_child("FrameFieldReference_goal_route", true, false)
			check(route != null, "library exposes the ordered route picker")
			if route != null:
				route.pressed.emit()
				var frame := await _render_pick_frame(app)
				if frame != null:
					var first := _frame_pick_at_world(frame, Vector2(72, 40))
					var second := _frame_pick_at_world(frame, Vector2(104, 72))
					var confirm := _click_pick_frame(frame, first)
					_click_pick_frame(frame, second)
					_click_pick_frame(frame, second)
					_click_pick_frame(frame, second, MOUSE_BUTTON_RIGHT)
					_click_pick_frame(frame, first)
					check(not confirm.disabled and not Store.list_ids(app.manifest, "ending").has("project-arrive"),
						"ordered route accepts revisits and stays in the draft")
					confirm.pressed.emit()
					await process_frame
					await process_frame
			var path_picker: Button = pop.find_child("FrameFieldReference_camera_path", true, false)
			check(path_picker != null, "a declared free path can be drawn in the game frame")
			if path_picker != null:
				path_picker.pressed.emit()
				var frame := await _render_pick_frame(app)
				if frame != null:
					var first := _frame_pick_at_world(frame, Vector2(34, 31))
					var second := _frame_pick_at_world(frame, Vector2(89, 54))
					var confirm := _click_pick_frame(frame, first)
					_click_pick_frame(frame, second)
					_click_pick_frame(frame, first)
					_click_pick_frame(frame, first, MOUSE_BUTTON_RIGHT)
					check(not confirm.disabled and not Store.list_ids(app.manifest, "ending").has("project-arrive"),
						"unoccupied positions are mapped without publishing the draft")
					confirm.pressed.emit()
					await process_frame
					await process_frame
		for opt in collect(pop, "OptionButton"):
			if id != "arrive" and goal != "" and range(opt.item_count).any(func(i): return opt.get_item_metadata(i) == goal):
				select_metadata(opt, goal)
			if next != "" and range(opt.item_count).any(func(i): return opt.get_item_metadata(i) == next):
				select_metadata(opt, next)
	if layer != "":
		for opt in collect(pop, "OptionButton"):
			if opt.name != "ReferenceContextMap" and range(opt.item_count).any(func(i): return opt.get_item_metadata(i) == map_context):
				select_metadata(opt, map_context)
				break
		await process_frame
		for opt in collect(pop, "OptionButton"):
			if range(opt.item_count).any(func(i): return opt.get_item_metadata(i) == layer):
				select_metadata(opt, layer)
				break
		var layer_picker: Button = pop.find_child("FrameFieldReference_layer_path", true, false)
		check(layer_picker != null, "library exposes the chosen layer's path picker")
		if layer_picker != null:
			layer_picker.pressed.emit()
			var frame := await _render_pick_frame(app)
			if frame != null:
				check(_click_pick_frame(frame, Vector2(0.15, 0.25)).disabled, "the other layer does not add a point")
				check(_click_pick_frame(frame, Vector2(0.74, 0.20)).disabled, "the foreground blocks the chosen layer")
				var confirm := _click_pick_frame(frame, Vector2(0.65, 0.25))
				_click_pick_frame(frame, Vector2(0.75, 0.25))
				check(not confirm.disabled and not Store.list_ids(app.manifest, "ending").has("project-layer-path"),
					"perspective points stay in the draft until applied and saved")
				confirm.pressed.emit()
				await process_frame
				await process_frame
	press(pop, "保存")
	pop.hide()
	await process_frame

func time_edit(pop: PopupPanel, field: String, value: String, submit := true) -> void:
	for button in collect(pop, "Button"):
		if str(button.text).begins_with("▸ 时间与轨道"):
			button.pressed.emit()
			break
	var editor: LineEdit
	for item in collect(pop, "LineEdit"):
		if item.is_visible_in_tree() and (item.placeholder_text == "随前序") == (field == "at"):
			editor = item
			break
	check(editor != null, "time field is visible: " + field)
	if editor == null:
		return
	editor.text = value
	if submit:
		editor.text_submitted.emit(value)
	else:
		editor.focus_exited.emit()

func render_timeline_sample(pop: PopupPanel, value: String, pixel: Vector2i, color: String) -> void:
	var input: LineEdit = pop.find_child("TimelineGamePreviewTime", true, false)
	var frame: TextureRect = pop.find_child("TimelineGamePreviewFrame", true, false)
	var render: Button = pop.find_child("TimelineGamePreviewRender", true, false)
	input.text = value
	input.text_changed.emit(value)
	check(frame.texture == null, "changing the sample clears the old game image")
	input.text_submitted.emit(value)
	var deadline := Time.get_ticks_msec() + 13500
	while is_instance_valid(render) and render.disabled and Time.get_ticks_msec() < deadline:
		await create_timer(0.08).timeout
	if not is_instance_valid(frame) or frame.texture == null:
		check(false, "game returned a frame at " + value)
		return
	var image := frame.texture.get_image()
	check(image.get_size() == Vector2i(720, 1280) and image.get_pixelv(pixel).to_html(false) == color,
		"game rendered the expected timeline state at " + value)

func author_timed_sequence(app, ce, fn_id: String, start: String, duration: String) -> void:
	ce._library.open()
	var pop: PopupPanel = collect(app, "PopupPanel").filter(func(p): return p.visible).back()
	select_metadata(collect(pop, "OptionButton").front(), fn_id)
	press(pop, "新建…")
	await process_frame
	pop = collect(app, "PopupPanel").filter(func(p): return p.visible).back()
	var inputs := collect(pop, "LineEdit")
	inputs[0].text = fn_id
	inputs[1].text = "timing"
	if fn_id == "frame_sequence":
		collect(pop, "SpinBox").front().value = 24
	press(pop, "保存并编辑演出")
	await process_frame
	pop = ce._steps._steps_pop
	ce._steps._steps_add("MARK")
	time_edit(pop, "at", start)
	time_edit(pop, "duration", duration, false)
	time_edit(pop, "at", "not a number")
	time_edit(pop, "duration", "1e999", false)
	if fn_id == "second_sequence":
		time_edit(pop, "at", "0.1235")
	ce._steps._steps_add("MARK")
	time_edit(pop, "at", "0")
	time_edit(pop, "at", "", false)
	ce._steps._steps_add("MARK")
	time_edit(pop, "at", "0")
	var playhead: float = ce._steps._steps_tl.playhead
	press(pop, "游戏演出画面…")
	var preview: PopupPanel = collect(app, "PopupPanel").filter(func(p): return p.visible).back()
	var sample: LineEdit = preview.find_child("TimelineGamePreviewTime", true, false)
	check(is_equal_approx(sample.text.to_float(), playhead), "new sampling window opens at the playhead")
	select_metadata(preview.find_child("TimelineGamePreviewViewport", true, false), "portrait")
	if fn_id == "frame_sequence":
		await render_timeline_sample(preview, "16", Vector2i(67, 640), "d75283")
		await render_timeline_sample(preview, "24", Vector2i(100, 640), "479bb1")
	else:
		await render_timeline_sample(preview, "0.2", Vector2i(20, 640), "d75283")
		await render_timeline_sample(preview, "0.4", Vector2i(40, 640), "479bb1")
	check(ce._steps._steps_tl.playhead == playhead, "resampling leaves the editor playhead unchanged")
	preview.hide()
	pop.hide()
	await process_frame

func message_for_binding(form: Control, value: String) -> void:
	var editor: LineEdit = collect(form, "LineEdit").back()
	editor.text = value
	editor.text_submitted.emit(value)

func author_reactions(ce) -> void:
	var panel: Control = ce._r_body
	# The initial row is furnished by the asset declaration. The extra row comes from the actual add menu.
	var inherited_options: Array = collect(panel, "OptionButton").filter(
		func(item): return item.item_count == 3 and item.get_item_metadata(1) == "TUCH")
	check(inherited_options.size() == 1, "switch starts with one mounted reaction")
	if inherited_options.size() != 1:
		return
	select_metadata(inherited_options[0], "TUCH")
	var rows: Array = collect(panel, "Button").filter(func(item): return item.tooltip_text == "点击展开这一项的内容表单")
	rows[0].pressed.emit()
	message_for_binding(ce._form_block, "entered")
	press(panel, "+ 添加功能 …")
	var menu: PopupMenu = ce._add_menu
	for i in menu.item_count:
		if menu.get_item_metadata(i) == "reaction":
			menu.hide()
			menu.id_pressed.emit(i)
			break
	var live: Array = ce._current_fns()
	check(live.size() == 2 and live[0].get("mounted", false) and not live[1].get("mounted", false),
		"same function gains one independent row without duplicating mount")
	if live.size() != 2:
		return
	var extra_id := str(live[1].get("bindingId", ""))
	var options: Array = collect(panel, "OptionButton").filter(
		func(item): return item.is_inside_tree() and item.item_count == 3 and item.get_item_metadata(1) == "TUCH")
	select_metadata(options.back(), "LEAV")
	message_for_binding(ce._form_block, "exited")
	ce.remember_context()
	press(panel, "↑")
	check(ce._restore_fn_index() == 0 and ce._current_fns()[0].bindingId == extra_id,
		"reorder preserves identity and restores the same binding")
	ce._delete_fn(1)
	check(ce._current_fns().size() == 2, "inherited row cannot be deleted")
	ce._add_fn("reaction")
	check(ce._current_fns().size() == 3, "a third independent row can be added")
	ce._delete_fn(2)
	check(ce._current_fns().size() == 2, "only the added row is removed")

func as_array_controls(n: Node, field: String) -> Array:
	return collect(n, "VBoxContainer").filter(func(item): return item.get_meta("array_field", "") == field)

func author_branches(pop: PopupPanel, map_code: String) -> void:
	var branches: VBoxContainer = as_array_controls(pop, "routes").front()
	var add_branch: Button = branches.get_child(branches.get_child_count() - 1)
	add_branch.pressed.emit()
	add_branch.pressed.emit()
	var groups := as_array_controls(branches, "predicates")
	check(groups.size() == 2, "both branching records have independent condition arrays")
	if groups.size() != 2:
		return
	var count := 0
	for group in groups:
		var add_condition: Button = group.get_child(group.get_child_count() - 1)
		add_condition.pressed.emit()
		var option: OptionButton = collect(group, "OptionButton").front()
		select_metadata(option, "hit_window")
		var window: SpinBox = collect(group, "SpinBox").front()
		window.value = 110
		if count == 0:
			add_condition.pressed.emit()
			option = collect(group, "OptionButton").back()
			select_metadata(option, "on_lane")
			var lane: SpinBox = collect(group, "SpinBox").back()
			lane.value = 2
		else:
			var negate: CheckBox = collect(group, "CheckBox").front()
			negate.button_pressed = true
		count += 1
	var modes: Array = collect(branches, "OptionButton").filter(func(opt):
		return opt.item_count == 2 and opt.get_item_metadata(0) == "all")
	for mode in modes:
		select_metadata(mode, "all")
	for opt in collect(branches, "OptionButton"):
		if range(opt.item_count).any(func(i): return opt.get_item_metadata(i) == map_code):
			select_metadata(opt, map_code)

func run():
	var tmp := "user://workflow-" + str(Time.get_ticks_usec()) + "-" + str(randi())
	var project := ProjectSettings.globalize_path(tmp)
	DirAccess.make_dir_recursive_absolute(project.path_join("maps"))
	for filename in ["project.godot", "main.tscn", "game.gd"]:
		check(DirAccess.copy_absolute(ProjectSettings.globalize_path(RuntimeFixture + filename),
			project.path_join(filename)) == OK, "copy independent runtime " + filename)
	check(DirAccess.copy_absolute(ProjectSettings.globalize_path("res://src/map/generated_chunk_delta.gd"),
		project.path_join("generated_chunk_delta.gd")) == OK, "install the same delta implementation in the independent game")
	DirAccess.make_dir_recursive_absolute(project.path_join("src/canvas"))
	check(DirAccess.copy_absolute(ProjectSettings.globalize_path("res://src/canvas/grid_space.gd"),
		project.path_join("src/canvas/grid_space.gd")) == OK, "install the standalone grid contract in the independent game")
	for filename in ["map_view_data.gd", "object_geometry.gd"]:
		check(DirAccess.copy_absolute(ProjectSettings.globalize_path("res://src/map/" + filename),
			project.path_join(filename)) == OK, "install standalone geometry " + filename)
	check(write_fixture_audio(project), "write rhythm audio fixture")
	var button_art := Image.create(96, 32, false, Image.FORMAT_RGB8)
	button_art.fill(Color("#264dab"))
	check(button_art.save_png(project.path_join("button.png")) == OK, "write reusable button artwork")
	var tile_art := Image.create(16, 16, false, Image.FORMAT_RGB8)
	tile_art.fill(Color("#4e8764"))
	check(tile_art.save_png(project.path_join("terrain.png")) == OK, "write terrain atlas")
	tile_art.fill(Color("#a98861"))
	check(tile_art.save_png(project.path_join("terrain-alt.png")) == OK, "write replacement atlas")
	var manifest := {"_dir": project, "_maps_dir": project.path_join("maps"), "projectName": "Workflow",
		"cellGraphEdgeTypes": {"stairs": {"name": "Stairs", "fields": [
			{"id": "cost", "kind": "input", "type": "int", "min": 1, "default": 9}]}},
		"functions": {"reaction": {"name":"Reaction", "code":"REAC", "repeatable":true, "steps":true,
			"triggers":["touch", "leave"], "fields":[{"id":"message","code":"RMES","kind":"input","type":"string"}]},
			"frame_sequence": {"name":"Frame Sequence", "code":"FSEQ", "steps":true, "timebase":"frames",
				"timePreview":{"fpsField":"fps"}, "fields":[{"id":"fps","code":"FPS1","kind":"input","type":"int","min":1}]},
			"second_sequence": {"name":"Second Sequence", "code":"SSEQ", "steps":true},
			"campaign": {"name": "Campaign", "code": "FLOW", "steps": true, "timebase":"beats",
			"timePreview":{"audioField":"music","offsetField":"offset","tempoStep":"tempo","bpmField":"bpm"},
			"fields": [
			{"id":"caption", "code":"CAPT", "kind":"input", "type":"string"},
			{"id":"position", "code":"VPOS", "kind":"input", "type":"viewport_ref"},
			{"id":"music", "code":"MUSC", "kind":"choice", "source":"audio:"},
			{"id":"offset", "code":"OFST", "kind":"input", "type":"float", "step":0.001}]},
			"ending": {"name": "Ending", "code": "ENDS", "fields": [
				{"id":"message", "code":"MESG", "kind":"input", "type":"string"},
				{"id":"goal", "code":"GOAL", "kind":"choice", "source":"entity_inst:door"},
				{"id":"goal_port", "code":"GPRT", "kind":"input", "type":"port_ref", "of":"door"},
				{"id":"arrival_edge", "code":"ARED", "kind":"input", "type":"edge_ref"},
				{"id":"goal_group", "code":"GGRP", "kind":"choice", "source":"entity_inst:door", "multiple":true},
				{"id":"goal_route", "code":"GROT", "kind":"input", "type":"array", "of":"choice", "source":"entity_inst:door"},
				{"id":"camera_path", "code":"CPTH", "kind":"input", "type":"array", "of":"vector2", "pickSpace":"map"},
				{"id":"path_map", "code":"PMAP", "kind":"choice", "source":"map"},
				{"id":"path_layer", "code":"PLID", "kind":"choice", "source":"layer:", "mapField":"path_map"},
				{"id":"layer_path", "code":"LPTH", "kind":"input", "type":"array", "of":"vector2",
					"pickSpace":"layer", "layerField":"path_layer", "mapField":"path_map"},
				{"id":"next", "code":"HOP1", "kind":"choice", "source":"content:ending",
					"contentMapContext":"inherit"},
				{"id":"retry_chart", "code":"AGAN", "name":"Retry chart", "kind":"choice",
					"source":"content:campaign", "contentMapContext":"inherit"}]}},
		"triggers": {"touch":{"name":"Touch","code":"TUCH"},"leave":{"name":"Leave","code":"LEAV"}},
		"conditions": {"hit_window":{"name":"Hit Window","fields":[
			{"id":"milliseconds","code":"WIND","kind":"input","type":"int","min":1}]},
			"on_lane":{"name":"On Lane","fields":[
			{"id":"lane","code":"LANE","kind":"input","type":"int","min":1}]}},
		"audio": {"rhythm": {"name":"Rhythm", "code":"AUD1", "path":"rhythm.wav"}},
		"steps": {"marker": {"name":"Mark","code":"MARK"},
			"tempo": {"name":"Tempo","code":"TMPO","fields":[
			{"id":"bpm","code":"BPM1","kind":"input","type":"int","min":1}]},
			"advance": {"name": "Advance", "code": "NEXT", "fields": [
			{"id":"routes", "code":"BRCH", "name":"Branches", "kind":"input","type":"array","of":"record","fields":[
				{"id":"match", "code":"MODE", "kind":"choice", "options":["all","any"]},
				{"id":"predicates", "code":"PRED", "kind":"input","type":"array","of":"condition",
					"allowedConditions":["hit_window","on_lane"]},
				{"id":"destination_map", "code":"DMAP", "name":"Branch map", "kind":"choice", "source":"map"},
				{"id":"arrival_door", "code":"ADRP", "name":"Arrival door", "kind":"choice",
					"source":"entity_inst:door", "mapField":"destination_map"},
				{"id":"destination", "code":"DEST", "name":"Branch target", "kind":"choice", "source":"content:ending",
					"contentMapContext":"paired", "mapField":"destination_map"}
			]}]}}, "assets":[
			{"id": "switch", "kind": "entity", "code": "SWCH", "functions":["reaction"],
				"ports":[{"id":"output","type":"signal","x":-5,"y":3}], "fields": [
				{"id":"target","type":"port_ref","of":"door","sourcePort":"output"}, {"id":"backup_map","type":"map_ref"},
				{"id":"backup","type":"port_ref","of":"door","mapField":"backup_map"},
				{"id":"activation_count","kind":"input","type":"int","default":1,"min":0,"max":4},
				{"id":"caption","kind":"input","type":"string","default":"Switch"},
				{"id":"motion_layer","kind":"choice","source":"layer:"},
				{"id":"motion_path","kind":"input","type":"array","of":"vector2",
					"pickSpace":"layer","layerField":"motion_layer"}]},
			{"id": "button-art", "kind": "scene", "shape": "image", "texture": "button.png"},
			{"id": "terrain", "kind": "scene", "shape": "tile", "atlas": "terrain.png", "cell": 16},
			{"id": "terrain-alt", "kind": "scene", "shape": "tile", "atlas": "terrain-alt.png", "cell": 16},
			{"id": "free-ramp", "kind": "entity", "code": "RAMP", "visual": {"type": "poly"}},
			{"id": "door", "kind": "entity", "code": "DOOR", "ports": [{"id":"open","type":"door","x": 5,"y": 4}],
				"fields": [{"id":"label", "type":"string"}, {"id":"route_cell", "kind":"choice", "source":"cell:"},
					{"id":"route_edge", "type":"edge_ref"}, {"id":"boundary_edge", "type":"edge_ref"},
					{"id":"edge_routes", "kind":"input", "type":"array", "of":"record", "fields":[
						{"id":"map", "kind":"choice", "source":"map"}, {"id":"edge", "type":"edge_ref", "mapField":"map"}]}]}],
		"playtest": {"executable": OS.get_executable_path(), "report": true, "projectEntry": true,
			"entryFunctions": ["second_sequence", "frame_sequence"],
			"args": ["--headless", "--path", "%projectpath%", "--", "--map=%mapfile%", "--verify"]},
		"mapGenerators": {"slope_room": {"name": "Slope Room", "fields": [
			{"id": "start", "name": "Starting column", "kind": "input", "type": "int", "min": 2, "max": 5, "default": 2},
			{"id": "variant", "name": "Variant", "kind": "input", "type": "int", "min": 0, "max": 2, "default": 0}]}},
		"preview": {"version": 1, "executable": OS.get_executable_path(), "capabilities": ["screenLayout", "mapFrame", "timelineFrame", "worldFrame", "generateMap"],
			"args": ["--path", "%projectpath%", "--rendering-method", "gl_compatibility",
				"--audio-driver", "Dummy", "--resolution", "240x160", "--"]}}
	var path := project.path_join("editor/editor_manifest.json")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var flow_map := Maps.new_map("flow_stage", 8, 8, "orthogonal")
	flow_map.objects = [{"asset": "door", "code": "EXIT", "x": 4, "y": 2, "layer": flow_map.meta.layers[0].id},
		{"asset": "door", "code": "ALT", "x": 6, "y": 4, "layer": flow_map.meta.layers[0].id}]
	check(Maps.write(manifest, "flow_stage", flow_map), "save a map whose door can be chosen from the project library")
	check(Maps.write_json(path, manifest), "write project manifest fixture")
	var import_log := PackedStringArray()
	var import_exit := OS.execute(OS.get_executable_path(),
		["--headless", "--path", project, "--editor", "--import"], import_log, true)
	if import_exit != 0:
		check(false, "initialize independent Godot project: " + "\n".join(import_log))
		quit(1)
		return
	manifest["_manifest_digest"] = Store.file_digest(path)
	var app = load("res://src/editor.tscn").instantiate()
	root.add_child(app)
	app.manifest = manifest
	app._build_editor_ui()
	app._set_mode("content")
	var ce = app.project_shell.content_editor
	ViewportLibrary.open(app)
	var viewport_pop = collect(app, "PopupPanel").filter(func(p): return p.visible).back()
	var vp_id = collect(viewport_pop, "LineEdit").front()
	vp_id.text = "portrait"
	var vp_dims := collect(viewport_pop, "SpinBox")
	vp_dims[0].value = 720
	vp_dims[1].value = 1280
	press(viewport_pop, "保存画幅")
	await process_frame
	check(manifest.get("viewports", []).size() == 1, "viewport published into live manifest")
	var disk: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	check(disk.get("viewports", []).size() == 1 and disk.viewports[0].h == 1280, "viewport saved to project manifest")
	ce._library.open()
	var pop = collect(app, "PopupPanel").filter(func(p): return p.visible).back()
	press(pop, "新建…")
	await process_frame
	pop = collect(app, "PopupPanel").filter(func(p): return p.visible).back()
	var inputs := collect(pop, "LineEdit")
	check(inputs.size() >= 3 and collect(pop, "SpinBox").size() == 3, "standalone record fields rendered with no map")
	if inputs.size() >= 3:
		inputs[0].text = "Campaign"
		inputs[1].text = "acceptance"
		inputs[2].text = "Ready"
	var viewport_opt = collect(pop, "OptionButton").filter(func(opt): return opt.name != "ReferenceContextMap").front()
	for i in viewport_opt.item_count:
		if str(viewport_opt.get_item_metadata(i)) == "portrait":
			viewport_opt.select(i)
			viewport_opt.item_selected.emit(i)
	select_metadata(collect(pop, "OptionButton").back(), "AUD1")
	collect(pop, "SpinBox").back().value = 0.237
	press(pop, "保存并编辑演出")
	await process_frame
	check(Store.read(manifest, "campaign", "project-acceptance").get("fields", {}).get("CAPT", "") == "Ready", "project record persisted")
	check(Store.read(manifest, "campaign", "project-acceptance").get("fields", {}).get("VPOS", {}) ==
		{"viewport":"portrait","point":[0.0,0.0]}, "choosing a viewport stores a complete point")
	ce._steps._steps_add("TMPO")
	pop = ce._steps._steps_pop
	collect(pop, "SpinBox").back().value = 120
	check(ce.commit_fields(), "tempo committed")
	ce._steps._steps_add("TMPO")
	for button in collect(pop, "Button"):
		if str(button.text).begins_with("▸ 时间与轨道"):
			button.pressed.emit()
			break
	for item in collect(pop, "LineEdit"):
		if item.placeholder_text == "随前序":
			item.text = "2"
			item.text_submitted.emit("2")
			break
	await process_frame
	# Only change the second segment's BPM, after its start beat has been saved.
	for item in collect(pop, "SpinBox"):
		if item.min_value == 1:
			item.value = 60
			break
	check(ce.commit_fields(), "second tempo committed")
	ce._steps._steps_add("NEXT")
	press(pop, "时间轴")
	await process_frame
	var timeline: TimelineView = ce._steps._steps_tl
	check(ce._steps._audio_preview.is_available() and not ce._steps._audio_preview.waveform.is_empty(),
		"audio code resolves to a WAV preview with waveform")
	check(is_equal_approx(float(timeline.clock.seconds_at(3.0)), 2.237),
		"timeline uses both tempo segments and the authored offset")
	timeline._press(Vector2(TimelineView.MARGIN_L + timeline._pps * 3.0, 4.0))
	timeline._release()
	press(pop, "试听")
	check(ce._steps._audio_preview.active, "transport starts from clicked beat")
	await create_timer(0.18).timeout
	check(timeline.playhead > 3.0, "audio transport advances the beat playhead")
	press(pop, "暂停试听")
	check(not ce._steps._audio_preview.active, "pause holds playback")
	timeline._press(Vector2(TimelineView.MARGIN_L + timeline._pps * 3.0, 4.0))
	timeline._release()
	press(pop, "步骤移到播放头")
	author_branches(pop, str(flow_map.meta.code))
	check(ce.commit_fields(), "nested branch forms commit")
	var branch_pick: Button = pop.find_child("FrameFieldReference_arrival_door", true, false)
	check(branch_pick != null, "a nested step field has a game frame picker")
	if branch_pick != null:
		branch_pick.pressed.emit()
		var branch_frame := await _render_pick_frame(app)
		if branch_frame != null:
			var branch_confirm := _click_pick_frame(branch_frame, _frame_pick_at_world(branch_frame, Vector2(72, 40)))
			check(not branch_confirm.disabled, "a branch uses its newly selected map to pick the matching door")
			check(not Store.read(manifest, "campaign", "project-acceptance").steps[2].fields.BRCH[0].has("ADRP"),
				"pending scene selection does not write the branch row")
			branch_confirm.pressed.emit()
			await process_frame
			check(not is_instance_valid(branch_frame) or not branch_frame.visible, "nested frame confirmation applies the selected reference")
	var saved := Store.read(manifest, "campaign", "project-acceptance")
	check(saved.get("scope") == "project" and saved.get("steps", []).size() == 3
		and saved.steps[2].get("at", -1) == 3.0, "standalone beat-aligned step persisted")
	var routes: Array = saved.steps[2].get("fields", {}).get("BRCH", [])
	check(routes.size() == 2 and routes[0].PRED.size() == 2 and routes[0].PRED[0].fields.WIND == 110
		and routes[0].PRED[1].fields.LANE == 2 and routes[1].PRED[0].negate
		and routes[0].get("DMAP") == flow_map.meta.code and routes[1].get("DMAP") == flow_map.meta.code,
		"author assembled two groups with independent typed parameters and a negated predicate")
	check(routes[0].get("ADRP") == "EXIT" and not routes[1].has("ADRP"), "scene selection stores the door on only the selected branch")
	var staged_frame := saved.duplicate(true)
	staged_frame.fields["CAPT"] = "Staged frame"
	ce.stage_clone("campaign", "project-acceptance", staged_frame, "")
	press(pop, "游戏演出画面…")
	var sample_pop: PopupPanel = collect(app, "PopupPanel").filter(func(p): return p.visible).back()
	select_metadata(sample_pop.find_child("TimelineGamePreviewViewport", true, false), "portrait")
	var sample_render: Button = sample_pop.find_child("TimelineGamePreviewRender", true, false)
	sample_render.pressed.emit()
	var sample_until := Time.get_ticks_msec() + 13500
	while is_instance_valid(sample_render) and sample_render.disabled and Time.get_ticks_msec() < sample_until:
		await create_timer(0.08).timeout
	if not is_instance_valid(sample_pop) or not is_instance_valid(pop):
		check(false, "timeline and frame windows survive the independent game taking focus")
		quit(1)
		return
	var sampled: TextureRect = sample_pop.find_child("TimelineGamePreviewFrame", true, false)
	check(sampled.texture != null, "independent game returned a timeline frame")
	if sampled.texture != null:
		var pixels := sampled.texture.get_image()
		check(pixels.get_size() == Vector2i(720, 1280) and pixels.get_pixel(224, 640).to_html(false) == "d75283"
			and pixels.get_pixel(100, 640).to_html(false) != "d75283",
			"the game reads staged content and samples the cue at beat three using both tempo segments")
	check(Store.read(manifest, "campaign", "project-acceptance") == saved,
		"preview reads the staged timeline without publishing it")
	sample_pop.hide()
	ce.drop_staged_for_doc(ce._form._doc_key())
	pop.hide()
	await process_frame
	await create_ending(app, ce._library, "arrive", "Reached the ending", str(flow_map.meta.code), "EXIT")
	await create_ending(app, ce._library, "finish", "Reached the ending", "", "", "project-arrive")
	await create_ending(app, ce._library, "retry", "Try again")
	await author_timed_sequence(app, ce, "frame_sequence", "11.6", "5.8")
	await author_timed_sequence(app, ce, "second_sequence", "0.123456", "0.234567")
	var frame_steps: Array = Store.read(manifest, "frame_sequence", "project-timing").get("steps", [])
	var second_steps: Array = Store.read(manifest, "second_sequence", "project-timing").get("steps", [])
	check(frame_steps.size() == 3 and frame_steps[0].get("at") == 12 and frame_steps[0].get("duration") == 6
		and not frame_steps[1].has("at") and frame_steps[2].get("at") == 0,
		"frame inputs snap, invalid edits do not write, and blank start differs from explicit zero")
	check(second_steps.size() == 3 and second_steps[0].get("at") == 0.123456
		and second_steps[0].get("duration") == 0.234567, "manual seconds retain time precision")
	var arrival := Store.read(manifest, "ending", "project-arrive")
	var camera_path: Array = arrival.get("fields", {}).get("CPTH", [])
	check(camera_path.size() == 2 and Vector2(camera_path[0][0], camera_path[0][1]).distance_to(Vector2(34, 31)) < 0.01
		and Vector2(camera_path[1][0], camera_path[1][1]).distance_to(Vector2(89, 54)) < 0.01,
		"free path stores root-space coordinates without requiring placed targets")
	check(arrival.get("fields", {}).get("GOAL") == "EXIT"
		and arrival.fields.get("GGRP") == ["ALT", "EXIT"]
		and arrival.fields.get("GROT") == ["EXIT", "ALT", "EXIT"]
		and arrival.fields.get("GPRT") == {"map": "", "inst": "EXIT", "port": "open"} and not arrival.has("map")
		and not arrival.fields.has("DMAP"), "temporary map exposes the local instance without pinning the saved reference")
	ce._library.open()
	pop = collect(app, "PopupPanel").filter(func(p): return p.visible).back()
	press(pop, "流程关系…")
	await process_frame
	pop = collect(app, "PopupPanel").filter(func(p): return p.visible).back()
	var graph_options := collect(pop, "OptionButton")
	select_metadata(graph_options[0], "campaign\u0001project-acceptance")
	check(graph_options[1].item_count == 2, "both branch targets are available for wiring")
	select_metadata(graph_options[2], "project-finish")
	press(pop, "应用关系")
	graph_options[1].select(1)
	graph_options[1].item_selected.emit(1)
	select_metadata(graph_options[2], "project-retry")
	press(pop, "应用关系")
	select_metadata(graph_options[0], "ending\u0001project-retry")
	var retry_slot: OptionButton = graph_options[1]
	for i in retry_slot.item_count:
		if retry_slot.get_item_text(i).ends_with(" → campaign"):
			retry_slot.select(i)
			retry_slot.item_selected.emit(i)
			break
	select_metadata(graph_options[2], "project-acceptance")
	press(pop, "应用关系")
	check(Store.read(manifest, "ending", "project-retry").get("fields", {}).get("AGAN") == "project-acceptance",
		"author closes the cross-function retry cycle through the project relationship graph")
	pop.hide()
	await process_frame
	var art := Image.create(160, 90, false, Image.FORMAT_RGB8)
	art.fill(Color.NAVY_BLUE)
	check(art.save_png(project.path_join("reference.png")) == OK, "create fixture reference image")
	ReferenceViews.open(app)
	pop = collect(app, "PopupPanel").filter(func(p): return p.visible).back()
	inputs = collect(pop, "LineEdit")
	inputs[0].text = "title"
	inputs[1].text = "reference.png"
	press(pop, "加载图片")
	await process_frame
	var preview: ReferenceViews.Preview
	for candidate in collect(pop, "Control"):
		if candidate is ReferenceViews.Preview:
			preview = candidate
			break
	check(preview != null and preview.texture != null, "image preview loaded")
	var continue_id := ""
	var menu_id := ""
	if preview != null:
		var frame := preview.frame()
		var drag := InputEventMouseButton.new()
		drag.button_index = MOUSE_BUTTON_LEFT
		drag.pressed = true
		drag.position = frame.position + frame.size * Vector2(0.25, 0.25)
		preview._gui_input(drag)
		drag.pressed = false
		drag.position = frame.position + frame.size * Vector2(0.75, 0.75)
		preview._gui_input(drag)
		check(preview.hotspots.size() == 1, "drag produced a normalized hotspot")
		var next_content: OptionButton = pop.find_child("ViewHotspotTarget", true, false)
		for idx in next_content.item_count:
			if next_content.get_item_metadata(idx) == {"function":"ending", "content":"project-finish"}:
				next_content.select(idx)
				next_content.item_selected.emit(idx)
				break
		pop.find_child("ViewLayoutMode", true, false).button_pressed = true
		var design: OptionButton = pop.find_child("LayoutDesignViewport", true, false)
		design.select(1)
		design.item_selected.emit(1)
		await process_frame
		frame = preview.frame()
		drag.pressed = true
		drag.position = frame.position + frame.size * Vector2(0.25, 0.68)
		preview._gui_input(drag)
		drag.pressed = false
		drag.position = frame.position + frame.size * Vector2(0.75, 0.85)
		preview._gui_input(drag)
		var label: LineEdit = pop.find_child("LayoutElement_text", true, false)
		label.text = "Continue"
		label.text_changed.emit(label.text)
		press(pop, "固定底边")
		select_metadata(pop.find_child("LayoutImageAsset", true, false), "button-art")
		select_metadata(pop.find_child("LayoutImageFit", true, false), "cover")
		check(preview.asset_textures.get("button-art") != null
			and preview.asset_textures["button-art"].get_size() == Vector2(96, 32),
			"layout previews the source image from the reusable asset declaration")
		var button_target: OptionButton = pop.find_child("LayoutElementTarget", true, false)
		for idx in button_target.item_count:
			if button_target.get_item_metadata(idx) == {"function":"ending", "content":"project-finish"}:
				button_target.select(idx)
				button_target.item_selected.emit(idx)
				break
		continue_id = str(preview.elements[0].id)
		drag.pressed = true
		drag.position = frame.position + frame.size * Vector2(0.25, 0.20)
		preview._gui_input(drag)
		drag.pressed = false
		drag.position = frame.position + frame.size * Vector2(0.75, 0.32)
		preview._gui_input(drag)
		menu_id = str(preview.elements[1].id)
		label = pop.find_child("LayoutElement_text", true, false)
		label.text = "Menu"
		label.text_changed.emit(label.text)
		var initial: OptionButton = pop.find_child("LayoutFocusStart", true, false)
		initial.select(2)
		initial.item_selected.emit(2)
		var right: OptionButton = pop.find_child("LayoutFocus_right", true, false)
		right.select(1)
		right.item_selected.emit(1)
		pop.find_child("LayoutNewLocale", true, false).text = "fr"
		press(pop, "添加语言")
		var buttons: OptionButton = pop.find_child("LayoutElementList", true, false)
		buttons.select(0)
		buttons.item_selected.emit(0)
		label = pop.find_child("LayoutElement_text", true, false)
		label.text = "Continuer dans le prochain chapitre avec toutes les options sélectionnées et sauvegardées"
		label.text_changed.emit(label.text)
		check(preview.text_overflows(preview.elements[0]), "a long translation is reported as overflowing")
		label.text = "Continuer"
		label.text_changed.emit(label.text)
		check(not preview.text_overflows(preview.elements[0]), "shortening the translation clears overflow")
		var result := [""]
		preview.focus_message.connect(func(message: String): result[0] = message)
		pop.find_child("LayoutFocusPreview", true, false).button_pressed = true
		check(preview.focused_id == menu_id, "navigation preview uses the authored initial button")
		var direction := InputEventAction.new()
		direction.action = &"ui_right"
		direction.pressed = true
		preview._gui_input(direction)
		check(preview.focused_id == continue_id, "right follows the authored route instead of spatial placement")
		direction.action = &"ui_accept"
		preview._gui_input(direction)
		check(str(result[0]).contains("Continuer") and str(result[0]).contains("ending/project-finish"),
			"confirm preview reports the localized title and the focused content target")
		var game_style: LineEdit = pop.find_child("LayoutElement_style", true, false)
		game_style.text = "fixture/primary"
		game_style.text_changed.emit(game_style.text)
		var render: Button = pop.find_child("GameRenderPreview", true, false)
		var frame_image: TextureRect = pop.find_child("GameRenderedFrame", true, false)
		check(not render.disabled, "project advertises a game renderer for screen layouts")
		var before_render := FileAccess.get_sha256(path)
		render.pressed.emit()
		var render_until := Time.get_ticks_msec() + 13500
		while is_instance_valid(render) and render.disabled and Time.get_ticks_msec() < render_until:
			await create_timer(0.08).timeout
		if not is_instance_valid(pop):
			check(false, "the layout workbench must survive the game renderer taking window focus")
			quit(1)
			return
		check(frame_image.visible and frame_image.texture != null, "real game frame is displayed in the layout editor")
		if frame_image.texture != null:
			var pixels := frame_image.texture.get_image()
			check(pixels.get_size() == Vector2i(720, 1280)
				and pixels.get_pixel(500, 1050).to_html(false) == "c53874"
				and pixels.get_pixel(0, 0).to_html(false) == "18203a",
				"picture contains the game-styled button at its authored location")
			render.pressed.emit()
			check(preview.visible and not frame_image.visible, "returning restores the unsaved layout editor")
		check(FileAccess.get_sha256(path) == before_render, "rendering an unsaved layout does not write the manifest")
	press(pop, "保存参考视图")
	await process_frame
	check(References.inbound_content(manifest, "ending", "project-finish").edges.views.size() == 2,
		"both hotspot and layout button are included in the deletion reference index")
	var saved_layout: Dictionary = manifest.views[0].layout
	check(saved_layout.viewport == "portrait" and saved_layout.elements[0].text == "Continue"
		and saved_layout.elements[0].anchors[1] == 1.0 and saved_layout.elements[0].anchors[3] == 1.0,
		"responsive button retains the author's text and bottom anchors")
	check(saved_layout.focusStart == menu_id and saved_layout.elements[1].focus.right == continue_id,
		"initial focus and explicit route persisted by element id")
	check(saved_layout.locales == ["fr"] and saved_layout.elements[0].textLocales.fr == "Continuer",
		"localized text persists without overwriting the source text")
	check(saved_layout.elements[0].get("imageAsset") == "button-art" and saved_layout.elements[0].get("imageFit") == "cover",
		"the layout saves a stable image asset ID and its fit without embedding a file path")
	check(Audit.asset_deletion_usage(manifest, "button-art", {}, []).views.size() == 1,
		"asset deletion sees the saved layout reference")
	var stale_view := manifest.duplicate(true)
	stale_view.views[0].hotspots[0].target.content = "project-missing"
	stale_view.views[0].layout.elements[0].imageAsset = "missing-image"
	check(Audit.audit(stale_view).any(func(issue): return str(issue.get("path", "")).begins_with("views[0].hotspots")),
		"audit locates a stale reference-view hotspot")
	check(Audit.audit(stale_view).any(func(issue): return issue.path == "views[0].layout.elements[0].imageAsset"),
		"audit locates a stale layout image by its exact field")
	var entry_report := await launch_and_read(app, true)
	app._map_file_ctrl.open_play_report()
	var observation: Dictionary = entry_report.get("observations", [{}])[0]
	var report_popup: PopupPanel = collect(app, "PopupPanel").filter(func(p): return p.visible).back()
	press(report_popup, "定位步骤 %d" % (int(observation.get("step", -1)) + 1))
	check(ce._steps._steps_cid == "project-acceptance" and ce._steps._steps_sel == int(observation.get("step", -1))
		and not report_popup.visible, "runtime feedback opens the authored cue step from the report")
	if is_instance_valid(ce._steps._steps_pop):
		ce._steps._steps_pop.hide()
	var stale_observation := observation.duplicate()
	stale_observation.contentDigest = "0".repeat(64)
	check(not app._map_file_ctrl._open_report_step(stale_observation), "a mismatched content digest cannot jump to a stale step")
	check(entry_report.get("status") == "ready" and entry_report.get("result", {}).get("step") == 2
		and entry_report.get("result", {}).get("caption") == "Ready"
		and entry_report.get("result", {}).get("ending") == "Reached the ending"
		and entry_report.get("result", {}).get("missEnding") == "Try again"
		and is_equal_approx(float(entry_report.get("result", {}).get("cueSec", -1.0)), 2.237)
		and entry_report.get("result", {}).get("hotspot") == "project-finish",
		"separate game process follows editor-wired campaign to ending: " + str(entry_report))
	var attempts: Array = entry_report.get("result", {}).get("attempts", [])
	check(attempts.size() == 2 and attempts[0].get("retry") == "project-acceptance"
		and float(attempts[0].get("inputSec", 0.0)) > 2.347 and attempts[1].get("retry") == ""
		and absf(float(attempts[1].get("inputSec", -1.0)) - 2.237) <= 0.11,
		"live key events miss, follow the authored retry link, restart the clock and then hit")
	check(entry_report.get("result", {}).get("screenTargets") == ["project-finish", "project-finish"],
		"independent runtime hits the authored bottom-anchored button in two viewport sizes")
	check(entry_report.get("result", {}).get("flowGoal") == {"map": flow_map.meta.code, "inst": "EXIT"},
		"the independent game enters the branch map, inherits it on the next hop and resolves the authored instance")
	var schedules: Dictionary = entry_report.get("result", {}).get("schedules", {})
	check(schedules.get("frame_sequence") == [[0.5, 0.75], [0.75, 0.75], [0.0, 0.0]],
		"independent game schedules frame steps at the declared content frame rate")
	var seconds: Array = schedules.get("second_sequence", [])
	check(seconds.size() == 3 and is_equal_approx(seconds[0][0], 0.123456)
		and is_equal_approx(seconds[0][1], 0.358023) and seconds[1][0] == seconds[0][1]
		and seconds[2] == [0.0, 0.0], "independent game schedules seconds and resolves implicit and explicit starts")
	check(entry_report.get("result", {}).get("screenFocus") == {"start": menu_id, "next": continue_id, "content": "project-finish",
		"localized": "Continuer", "fallback": "Continue"},
		"independent game resolves the author-defined directional route and consumes its target")
	var screen_art: Dictionary = entry_report.get("result", {}).get("screenArtwork", {})
	check(screen_art.get("fit") == "cover" and screen_art.get("size") == [96.0, 32.0]
		and screen_art.get("pixel") == "264dab",
		"independent game resolves and decodes the image chosen by the author: " + str(screen_art))
	ce._library.open()
	pop = collect(app, "PopupPanel").filter(func(p): return p.visible).back()
	select_metadata(collect(pop, "OptionButton").front(), "second_sequence")
	var entry_list: ItemList = collect(pop, "ItemList").front()
	for i in entry_list.item_count:
		if entry_list.get_item_metadata(i) == "project-timing":
			entry_list.select(i)
			entry_list.item_selected.emit(i)
			break
	var entry_launch: Button = collect(pop, "Button").filter(func(b): return b.text == "试玩所选内容").front()
	check(entry_launch.is_visible_in_tree() and not entry_launch.disabled, "declared project content appears as a playable entry")
	var prior_request: String = app._map_file_ctrl._play_report_request.token
	entry_launch.pressed.emit()
	var entry_until := Time.get_ticks_msec() + 5000
	while app._map_file_ctrl._play_report_request.get("token") == prior_request and Time.get_ticks_msec() < entry_until:
		await process_frame
	var chosen_report := await wait_for_playtest(app._map_file_ctrl)
	var chosen_entry: Dictionary = chosen_report.get("result", {}).get("entry", {})
	check(chosen_report.get("status") == "ready" and chosen_report.get("mapDigest") == ""
		and chosen_entry.get("version") == 1 and chosen_entry.get("function") == "second_sequence"
		and chosen_entry.get("content") == "project-timing"
		and chosen_report.get("result", {}).get("schedule") == seconds,
		"the same independent game starts from the library-selected session: " + str(chosen_report))
	await create_ending(app, ce._library, "finish-alt", "Reached the replacement", str(flow_map.meta.code), "EXIT")
	ce._library.open()
	pop = collect(app, "PopupPanel").filter(func(p): return p.visible).back()
	press(pop, "流程关系…")
	await process_frame
	pop = collect(app, "PopupPanel").filter(func(p): return p.visible).back()
	var missing_links: OptionButton = pop.find_child("FlowMissingLinks", true, false)
	check(missing_links.disabled, "saved flow opens without broken branches")
	# Simulate the game project temporarily removing the target file outside the editor.
	var old_ending := Store.path_for(manifest, "ending", "project-finish")
	var held_ending := project.path_join("held-ending.json")
	check(DirAccess.rename_absolute(old_ending, held_ending) == OK, "temporarily remove the target from the content directory")
	press(pop, "重新扫描")
	check(not missing_links.disabled and missing_links.item_count == 4
		and missing_links.get_item_text(1).contains("ending/project-finish"), "rescan exposes the missing nested branch, screen button and hotspot targets")
	missing_links.select(1)
	missing_links.item_selected.emit(1)
	graph_options = collect(pop, "OptionButton")
	check(graph_options[0].get_selected_metadata() == "campaign\u0001project-acceptance"
		and graph_options[2].get_selected_metadata() == "project-finish", "broken reference selects its exact source and field")
	select_metadata(graph_options[2], "")
	press(pop, "应用关系")
	var repaired_routes: Array = Store.read(manifest, "campaign", "project-acceptance").steps[2].fields.BRCH
	check(missing_links.item_count == 3 and not repaired_routes[0].has("DEST") and repaired_routes[1].DEST == "project-retry",
		"disconnect clears the missing reference without changing the sibling branch")
	select_metadata(graph_options[2], "project-finish-alt")
	press(pop, "应用关系")
	check(DirAccess.rename_absolute(held_ending, old_ending) == OK, "restore the old file for the separate screen references")
	pop.hide()
	await process_frame
	var repaired_report := await launch_and_read(app, true)
	check(repaired_report.get("result", {}).get("ending") == "Reached the replacement"
		and repaired_report.get("result", {}).get("missEnding") == "Try again"
		and repaired_report.get("result", {}).get("flowGoal") == {"map": flow_map.meta.code, "inst": "EXIT"},
		"the independent game uses the repaired route while preserving the retry branch: " + str(repaired_report))
	var data := Maps.new_map("board", 10, 10)
	var remote := Maps.new_map("remote", 10, 10)
	remote.meta["code"] = "RMT2"
	remote.meta["cellGraph"] = {"cells": [
		{"id": "b", "polygon": [[0, 0], [16, 0], [16, 16], [0, 16]]},
		{"id": "other", "polygon": [[16, 0], [32, 0], [32, 16], [16, 16]]},
	]}
	check(Maps.write(manifest, "remote", remote), "write remote graph with a same-named cell and a different default cell")
	var layer: String = data.meta.layers[0].id
	data.meta.layers.append({"id": "upper_art", "name": "Upper Art", "offset": [24, 12], "scale": 1.5})
	data.objects = [
		{"asset":"switch","code":"SW01","x":2,"y":2,"layer":layer},
		{"asset":"door","code":"DR01","x":4,"y":3,"layer":layer}]
	check(Maps.write(manifest, "board", data), "write source board")
	await app._load_map_file(Maps.path_for(manifest, "board"))
	app._set_mode("content", "SW01")
	press(ce.root, "画布选…")
	check(app.canvas.pick_mode_accept == "port" and app.canvas.pick_mode_active, "opened port picking from instance form")
	var markers: Array = app.canvas.port_markers(["door"])
	check(markers.size() == 1, "only the declared matching port is available")
	if not markers.is_empty():
		app.canvas.pick_mode_code = app.canvas.pick_candidate_at(markers[0].pos)
		app._end_canvas_pick(true)
	await process_frame
	author_reactions(ce)
	# The independent row has moved before the inherited row. Both contents are still staged.
	var reaction_rows: Array = ce._current_fns()
	var reaction_id: String = reaction_rows[0].content
	var board_path := Maps.path_for(manifest, "board")
	var board_digest := FileAccess.get_sha256(board_path)
	ce._open_steps_editor(0)
	var reaction_pop: PopupPanel = ce._steps._steps_pop
	ce._steps._steps_add("MARK")
	time_edit(reaction_pop, "duration", "0.5")
	var previous_camera: Vector2 = app.canvas.cam_pos
	var previous_zoom: float = app.canvas.zoom
	app.canvas.cam_pos = Vector2(32, 32)
	app.canvas.zoom = 2.0
	press(reaction_pop, "游戏演出画面…")
	var reaction_preview: PopupPanel = collect(app, "PopupPanel").filter(func(p): return p.visible).back()
	select_metadata(reaction_preview.find_child("TimelineGamePreviewViewport", true, false), "portrait")
	await render_timeline_sample(reaction_preview, "0.25", Vector2i(376, 656), "d75283")
	var reaction_image: TextureRect = reaction_preview.find_child("TimelineGamePreviewFrame", true, false)
	check(reaction_image.texture != null and reaction_image.texture.get_image().get_pixel(4, 4).to_html(false) == "46c4ae",
		"instance scene also resolves the other binding's staged row")
	var reaction_render: Button = reaction_preview.find_child("TimelineGamePreviewRender", true, false)
	reaction_render.pressed.emit()
	app.canvas.cam_pos = Vector2(40, 32)
	var reaction_deadline := Time.get_ticks_msec() + 13500
	while reaction_render.disabled and Time.get_ticks_msec() < reaction_deadline:
		await create_timer(0.08).timeout
	check(not reaction_render.disabled and reaction_image.texture == null,
		"a frame rendered against the previous camera is discarded")
	app.canvas.cam_pos = Vector2(32, 32)
	await render_timeline_sample(reaction_preview, "0.75", Vector2i(376, 656), "479bb1")
	check(FileAccess.get_sha256(board_path) == board_digest
		and not FileAccess.file_exists(Store.path_for(manifest, "reaction", reaction_id)),
		"instance timeline preview does not publish the binding, its content, or the map")
	reaction_preview.hide()
	reaction_pop.hide()
	app.canvas.cam_pos = previous_camera
	app.canvas.zoom = previous_zoom
	await process_frame
	GraphEditor.open(app)
	pop = collect(app, "PopupPanel").filter(func(p): return p.visible).back()
	var name_input = collect(pop, "LineEdit").front()
	name_input.text = "a"
	press(pop, "添加格")
	name_input.text = "b"
	press(pop, "添加格")
	check(collect(pop, "SpinBox").size() >= 8, "polygon vertices are editable")
	pop.find_child("NewGraphSpaceId", true, false).text = "upper"
	press(pop, "添加空间")
	var assignment: OptionButton = pop.find_child("CellLocalSpace", true, false)
	assignment.select(1)
	assignment.item_selected.emit(1)
	var space_layer: OptionButton = pop.find_child("GraphSpaceLayer", true, false)
	for i in space_layer.item_count:
		if space_layer.get_item_metadata(i) == "upper_art":
			space_layer.select(i)
			space_layer.item_selected.emit(i)
			break
	collect(pop.find_child("GraphSpace_origin", true, false), "SpinBox")[0].value = 64
	collect(pop.find_child("GraphSpace_axisX", true, false), "SpinBox")[0].value = 0
	collect(pop.find_child("GraphSpace_axisX", true, false), "SpinBox")[1].value = 1
	collect(pop.find_child("GraphSpace_axisY", true, false), "SpinBox")[0].value = -1
	collect(pop.find_child("GraphSpace_axisY", true, false), "SpinBox")[1].value = 0
	var space_filter: OptionButton = pop.find_child("GraphSpaceFilter", true, false)
	space_filter.select(0)
	space_filter.item_selected.emit(0)
	await process_frame
	var graph_preview = pop.find_child("GraphPreview", true, false)
	var tile := Vector2(app.canvas.grid.tile)
	var corner := tile * Vector2(2, 1)
	var moved := corner + Vector2(5, 3)
	var upper_frame := Transform2D(Vector2.DOWN, Vector2.LEFT, Vector2(64, 0))
	var upper_to_map := Transform2D(0.0, Vector2.ONE * 1.5, 0.0, Vector2(24, 12)) * upper_frame
	var vertex_click := InputEventMouseButton.new()
	vertex_click.button_index = MOUSE_BUTTON_LEFT
	vertex_click.pressed = true
	vertex_click.position = graph_preview.projection() * (upper_to_map * corner)
	graph_preview._gui_input(vertex_click)
	vertex_click.pressed = false
	vertex_click.position = graph_preview.projection() * (upper_to_map * moved)
	graph_preview._gui_input(vertex_click)
	pop.find_child("GraphLinkMode", true, false).button_pressed = true
	vertex_click.pressed = true
	vertex_click.position = graph_preview.projection() * (tile * 0.5)
	graph_preview._gui_input(vertex_click)
	var edge_type: OptionButton = pop.find_child("NewEdgeType", true, false)
	edge_type.select(1)
	press(pop, "新建连接")
	graph_preview._gui_input(vertex_click)
	var first_id: String = graph_preview.selected_edge
	edge_type = pop.find_child("NewEdgeType", true, false)
	edge_type.select(1)
	press(pop, "新建连接")
	var passable_id: String = graph_preview.selected_edge
	graph_preview._gui_input(vertex_click)
	var cost: SpinBox = pop.find_child("EdgeProperty_cost", true, false)
	cost.value = 3
	pop.find_child("GraphLinkMode", true, false).button_pressed = false
	graph_preview._gui_input(vertex_click)
	edge_type = pop.find_child("NewEdgeType", true, false)
	edge_type.select(1)
	press(pop, "新建连接")
	var exit_id: String = graph_preview.selected_edge
	var dest_map: OptionButton = pop.find_child("ExplicitEdgeMap", true, false)
	select_metadata(dest_map, "RMT2")
	press(pop, "应用到地图")
	check(pop.visible, "map selection alone cannot publish an incomplete destination")
	var dest_cell: OptionButton = pop.find_child("ExplicitEdgeTarget", true, false)
	dest_cell.select(0)
	dest_cell.item_selected.emit(0)
	cost = pop.find_child("EdgeProperty_cost", true, false)
	cost.value = 2
	press(pop, "应用到地图")
	check(app.canvas.cell_graph().get("cells", []).size() == 2, "graph applied to live map")
	check(app.canvas.pick_cell_id_at(upper_to_map * (tile * Vector2(1.5, 0.5)), "upper") == "b"
		and app.canvas.pick_cell_id_at(tile * 0.5, "upper") == "", "main canvas honors projected coordinates and space filter")
	var upper_layer: int = app.canvas._layer_index_of("upper_art")
	await app.canvas.layer_set_param(upper_layer, "offset", Vector2(44, 22))
	await app.canvas.layer_set_param(upper_layer, "scale", 2.0)
	upper_to_map = Transform2D(0.0, Vector2.ONE * 2.0, 0.0, Vector2(44, 22)) * upper_frame
	check(app.canvas.pick_cell_id_at(upper_to_map * (tile * Vector2(1.5, 0.5)), "upper") == "b"
		and app.canvas.cell_polygon_world("b")[0].is_equal_approx(upper_to_map * (tile * Vector2.RIGHT)),
		"changing the art layer updates both grid hit targets and overlay points")
	check(Maps.rename_map(manifest, "remote", "remote_renamed") == "", "rename destination while preserving its map code")
	var board_report := await launch_and_read(app, false)
	var from_point: Array = board_report.get("result", {}).get("fromPoint", [0.0, 0.0])
	check(board_report.get("status") == "ready" and board_report.get("result", {}).get("cell") == "a"
		and board_report.get("result", {}).get("opened") == "DR01"
		and board_report.get("result", {}).get("edge") == passable_id
		and board_report.get("result", {}).get("exitEdge") == exit_id
		and board_report.get("result", {}).get("destinationMap") == "RMT2"
		and board_report.get("result", {}).get("destinationCell") == "b"
		and board_report.get("result", {}).get("fromSpace") == "upper"
		and board_report.get("result", {}).get("toSpace") == ""
		and Vector2(from_point[0], from_point[1]).is_equal_approx(upper_to_map * (tile * Vector2.RIGHT))
		and board_report.get("result", {}).get("reactions") == {"TUCH":["entered"],"LEAV":["exited"]},
		"separate game process follows editor-authored directed edge: " + str(board_report))
	var reopened := Maps.read(manifest, "board")
	check(Audit._ref_checks(reopened, manifest, "board").is_empty(), "saved port is accepted by project audit")
	var stale := reopened.duplicate(true)
	stale.objects[0].props.target.port = "removed"
	check(not Audit._ref_checks(stale, manifest, "board").is_empty(), "audit flags missing port on an existing instance")
	var cells: Array = reopened.get("meta", {}).get("cellGraph", {}).get("cells", [])
	check(cells.size() == 2 and cells[1].neighbors == ["a"], "graph and directed link reopened from disk")
	var saved_edges: Array = reopened.meta.cellGraph.get("edges", [])
	check(saved_edges.size() == 3 and first_id != passable_id and saved_edges[0].id == first_id
		and saved_edges[0].props.cost == 9 and saved_edges[1].id == passable_id
		and saved_edges[1].props.cost == 3 and saved_edges[1].to == "a",
		"parallel connections retain independent identities and author-configured cost")
	check(saved_edges.size() == 3 and saved_edges[2].id == exit_id and saved_edges[2].from == "a"
		and saved_edges[2].toMap == "RMT2" and saved_edges[2].to == "b",
		"remote endpoint pair and ID survive save and target rename")
	check(not Audit.audit(manifest).any(func(issue): return str(issue.path).contains("cellGraph.edges[2]")),
		"project audit accepts a renamed target identified by code")
	var bad_source := reopened.duplicate(true)
	bad_source.meta.cellGraph.edges[2].to = "missing"
	var broken := Audit._graph_target_checks(bad_source, manifest, "board", [], {})
	check(broken.size() == 1 and str(broken[0].path).ends_with("edges[2].to"),
		"remote cell loss is reported on the source edge")
	check(cells.size() == 2 and Vector2(cells[1].polygon[2][0], cells[1].polygon[2][1]).is_equal_approx(moved),
		"visually dragged vertex is written in local coordinates and survives reopen")
	var frame: Dictionary = reopened.meta.cellGraph.spaces.upper
	check(Vector2(frame.origin[0], frame.origin[1]).is_equal_approx(upper_frame.origin)
		and Vector2(frame.axisX[0], frame.axisX[1]).is_equal_approx(upper_frame.x)
		and Vector2(frame.axisY[0], frame.axisY[1]).is_equal_approx(upper_frame.y)
		and frame.get("layer") == "upper_art" and cells[1].space == "upper",
		"authored affine space and assignment survive reopen")
	var reactions: Array = reopened.objects[0].functions
	check(reactions.size() == 2 and reactions[0].bindingId != reactions[1].bindingId
		and reactions[0].content != reactions[1].content and reactions[0].order == 1
		and reactions[1].get("mounted", false), "distinct binding identities and content survive reopening")
	check(Audit._binding_checks(reopened, manifest, "board").is_empty(), "audit accepts repeated rows and unique mount")
	if is_instance_valid(pop):
		pop.hide()
	await process_frame

	app._map_file_ctrl.on_duplicate()
	pop = collect(app, "PopupPanel").filter(func(p): return p.visible).back()
	var board_copy_name: LineEdit = collect(pop, "LineEdit").front()
	board_copy_name.text = "board_reuse"
	board_copy_name.text_changed.emit(board_copy_name.text)
	press(pop, "复制")
	await process_frame
	var copy := Maps.read(manifest, "board_reuse")
	check(copy.meta.cellGraph.edges == saved_edges, "map-local edge identities survive whole-map duplication")
	var copied_bindings: Array = copy.objects[0].functions
	check(copied_bindings.size() == 2 and copied_bindings[0].bindingId == reactions[0].bindingId
		and copied_bindings[0].content != reactions[0].content
		and copied_bindings[1].content != reactions[1].content, "copied instance keeps local row IDs and remaps both content files")
	await app._load_map_file(Maps.path_for(manifest, "board_reuse"))
	var copied_report := await launch_and_read(app, false)
	check(copied_report.get("status") == "ready" and copied_report.get("result", {}).get("opened", "") != "DR01"
		and copied_report.get("result", {}).get("reactions") == {"TUCH":["entered"],"LEAV":["exited"]},
		"copied instance runs both new content files: " + str(copied_report))
	var before_detach: PackedVector2Array = app.canvas.cell_polygon_world("b")
	await app.canvas.layer_del(app.canvas._layer_index_of("upper_art"))
	check(not app.canvas.cell_graph().spaces.upper.has("layer")
		and app.canvas.cell_polygon_world("b") == before_detach and app.canvas.cell_graph().edges == saved_edges,
		"deleting a layer retains the bound space placement, cells and traversal")
	check(await app.canvas.undo() and app.canvas.cell_graph().spaces.upper.get("layer") == "upper_art",
		"one undo restores both layer and space binding")
	# Author the collision and gate on the live canvas, then reuse the room through the copy dialog.
	var room := Maps.new_map("platform", 12, 8)
	check(Maps.write(manifest, "platform", room), "seed blank platform map")
	await app._load_map_file(Maps.path_for(manifest, "platform"))
	app._set_mode("map")
	var canvas = app.canvas
	canvas.active_layer = canvas.collision_index()
	canvas.collision_shape = ""
	canvas._paint(Vector2i(2, 4))
	canvas.collision_shape = "r45"
	canvas._paint(Vector2i(3, 4))
	canvas.collision_shape = ""
	canvas._paint(Vector2i(4, 3))
	canvas._undo_history_ctrl.stroke_end()
	canvas._paint_pushed = false
	canvas.active_layer = 0
	canvas.stamp_asset = "door"
	canvas._tool_ops_ctrl.place_object(canvas.stamp_asset, canvas.active_layer, canvas.grid.cell_center_px(Vector2i(4, 2)))
	canvas.stamp_asset = "free-ramp"
	canvas.place_kind = "object"
	canvas.snap_to_grid = false
	press(app, "绘制轮廓 / 路径")
	var outline = canvas._geometry_draw
	var initial_count: int = canvas.extract().objects.size()
	for point in [Vector2(32.5, 68.0), Vector2(72.5, 40.0), Vector2(72.5, 72.0), Vector2(32.5, 72.0)]:
		outline.add(canvas.to_layer_world(canvas.active_layer, point))
	check(canvas.extract().objects.size() == initial_count, "unfinished contour is not part of the document")
	outline.finish()
	check(canvas.extract().objects.size() == initial_count + 1, "one finish inserts a free geometry entity")
	check(await canvas.undo() and canvas.extract().objects.size() == initial_count, "contour creation is one undo step")
	check(await canvas.redo() and canvas.extract().objects.size() == initial_count + 1, "redo restores the contour")
	var shell_point: Vector2 = canvas.to_layer_world(canvas.active_layer, Vector2(70, 62))
	var ring_target: EntityNode = canvas._entity_at(shell_point)
	check(ring_target != null and ring_target.asset == "free-ramp", "pick the drawn solid to edit its holes")
	canvas.commit_selection(ring_target)
	press(app, "绘制孔洞")
	for point in [Vector2(58,60), Vector2(65,60), Vector2(65,68), Vector2(58,68)]:
		outline.add(canvas.to_layer_world(canvas.active_layer, point))
	outline.finish()
	var hole_point: Vector2 = canvas.to_layer_world(canvas.active_layer, Vector2(61, 64))
	check(not outline.active() and ring_target.holes_local().size() == 1
		and not ring_target.contains_point(canvas.to_layer_local(canvas.active_layer, hole_point)),
		"drawn hole is stored and excluded from hit testing")
	canvas.zoom = 4.0
	var edit_corner: Vector2 = canvas.to_layer_world(canvas.active_layer, Vector2(58, 60))
	var vertex: Vector2i = canvas._vertex_handle_hit(edit_corner)
	check(vertex == Vector2i(1, 0), "the hole vertex has a distinct handle")
	var invalid_before := ring_target.props.duplicate(true)
	var undo_before: int = canvas.undo_step_count()
	canvas._begin_vertex_drag(ring_target, vertex)
	canvas._move_vertex_preview(canvas.to_layer_world(canvas.active_layer, Vector2(50, 40)))
	canvas._finish_vertex_drag()
	canvas.end_gesture()
	check(ring_target.props == invalid_before and canvas.undo_step_count() == undo_before,
		"dragging a hole outside the outline restores the prior data without creating history")
	canvas._begin_vertex_drag(ring_target, vertex)
	var new_corner: Vector2 = canvas.to_layer_world(canvas.active_layer, Vector2(57, 60))
	canvas._move_vertex_preview(new_corner)
	canvas._finish_vertex_drag()
	canvas.end_gesture()
	check(ring_target.geometry_point_to_world(ring_target.holes_local()[0][0]).distance_to(new_corner) <= 0.01,
		"a valid drag moves the hole vertex")
	var midpoint: Vector2 = canvas.to_layer_world(canvas.active_layer, Vector2(61, 60))
	check(canvas._add_vertex_at(midpoint) and ring_target.holes_local()[0].size() == 5,
		"add a vertex to the inner edge")
	check(canvas._delete_vertex_at(midpoint) and ring_target.holes_local()[0].size() == 4,
		"delete the additional vertex from the inner ring")
	canvas._canvas_input_ctrl._on_right_press(shell_point, true)
	check(is_instance_valid(ring_target) and ring_target.holes_local().size() == 1
		and canvas._entity_at(shell_point) == ring_target, "hole removal misses do not erase the entity")
	canvas._canvas_input_ctrl._on_right_press(hole_point, true)
	check(ring_target.holes_local().is_empty(), "author can remove an inner ring")
	check(await canvas.undo() and canvas.extract().objects.back().props.holes.size() == 1,
		"one undo restores the removed hole")
	ring_target = canvas._entity_at(shell_point)
	canvas.commit_selection(ring_target)
	press(app, "绘制附加轮廓")
	for point in [Vector2(99,48), Vector2(125,48), Vector2(125,70), Vector2(99,70)]:
		outline.add(canvas.to_layer_world(canvas.active_layer, point))
	outline.finish()
	var extra_point: Vector2 = canvas.to_layer_world(canvas.active_layer, Vector2(102, 51))
	check(canvas._entity_at(extra_point) == ring_target and ring_target.geometry_parts().size() == 2,
		"the disconnected contour belongs to the same selectable entity")
	press(app, "绘制孔洞")
	for point in [Vector2(108,53), Vector2(116,53), Vector2(116,64), Vector2(108,64)]:
		outline.add(canvas.to_layer_world(canvas.active_layer, point))
	outline.finish()
	check(ring_target.geometry_parts()[1].holes.size() == 1
		and canvas._entity_at(canvas.to_layer_world(canvas.active_layer, Vector2(112, 58))) == null,
		"a hole is attached to the component containing it and excluded from hit testing")
	canvas._canvas_input_ctrl._on_right_press(extra_point, true, true)
	check(ring_target.geometry_parts().size() == 1, "remove the additional component without deleting the entity")
	check(await canvas.undo() and canvas.extract().objects.back().props.parts.size() == 1,
		"one undo restores the entire component with its hole")
	canvas.cam_pos = Vector2(64, 40)
	canvas.zoom = 2.0
	var workbench = app.project_shell.content_editor
	workbench.stage_clone("ending", "preview-only", {"function": "ENDS", "fields": {"MESG": "Preview overlay"}}, "")
	var platform_path := Maps.path_for(manifest, "platform")
	var room_before := FileAccess.get_sha256(platform_path)
	var manifest_before := FileAccess.get_sha256(path)
	app._layout_ctrl._on_map_menu_id(14)
	pop = collect(app, "PopupPanel").filter(func(p): return p.visible).back()
	select_metadata(pop.find_child("MapGamePreviewViewport", true, false), "portrait")
	var map_render: Button = pop.find_child("MapGamePreviewRender", true, false)
	map_render.pressed.emit()
	var map_render_until := Time.get_ticks_msec() + 13500
	while is_instance_valid(map_render) and map_render.disabled and Time.get_ticks_msec() < map_render_until:
		await create_timer(0.08).timeout
	if not is_instance_valid(pop):
		check(false, "map preview window survives game rendering")
		quit(1)
		return
	var map_frame: TextureRect = pop.find_child("MapGamePreviewFrame", true, false)
	check(map_frame.texture != null, "the independent game returned its own map frame")
	if map_frame.texture != null:
		var pixels := map_frame.texture.get_image()
		check(pixels.get_size() == Vector2i(720, 1280)
			and pixels.get_pixel(376, 640).to_html(false) == "f29b41"
			and pixels.get_pixel(360, 640).to_html(false) != "f29b41",
			"the live unsaved gate is drawn with the actual requested camera pan and zoom")
		check(pixels.get_pixel(3, 3).to_html(false) == "46c4ae", "game frame consumes the unsaved staged content")
	check(FileAccess.get_sha256(platform_path) == room_before and FileAccess.get_sha256(path) == manifest_before
		and not FileAccess.file_exists(Store.path_for(manifest, "ending", "preview-only")),
		"map preview leaves the formal map, manifest and pending content unwritten")
	workbench.drop_staged_for_doc(app._map_file_ctrl.sess.doc_key)
	pop.hide()
	await process_frame
	app._map_file_ctrl.on_duplicate()
	pop = collect(app, "PopupPanel").filter(func(p): return p.visible).back()
	var copy_name: LineEdit = collect(pop, "LineEdit").front()
	copy_name.text = "platform_reuse"
	copy_name.text_changed.emit(copy_name.text)
	press(pop, "复制")
	await process_frame
	var copied_room := Maps.read(manifest, "platform_reuse")
	check(copied_room.get("meta", {}).get("code", "") != room.meta.code
		and copied_room.get("collision", []).size() == 3
		and copied_room.get("objects", []).size() == 2, "room copy keeps collision, gate and contour and assigns new identity")
	var source_platform_report := await launch_and_read(app, false)
	check(source_platform_report.get("status") == "ready", "source room is saved and playable")
	app._nav_bars[0]._refresh_map_menu()
	app._nav_bars[0]._switch_menu.id_pressed.emit(100002)
	await process_frame
	pop = collect(app, "PopupPanel").filter(func(p): return p.visible).back()
	var world_list: OptionButton = pop.find_child("WorldMapList", true, false)
	select_metadata(world_list, room.meta.code)
	press(pop, "添加到世界")
	pop.find_child("WorldX", true, false).value = -128
	pop.find_child("WorldY", true, false).value = 0
	select_metadata(world_list, copied_room.meta.code)
	press(pop, "添加到世界")
	pop.find_child("WorldX", true, false).value = 0
	pop.find_child("WorldY", true, false).value = 0
	pop.find_child("WorldWidth", true, false).value = 96
	press(pop, "适合窗口")
	var world_surface = pop.find_child("WorldFootprints", true, false)
	var start: Vector2 = world_surface._offset + Vector2(32, 32) * world_surface._zoom
	var pointer := InputEventMouseButton.new()
	pointer.button_index = MOUSE_BUTTON_LEFT
	pointer.pressed = true
	pointer.position = start
	world_surface._gui_input(pointer)
	var drag := InputEventMouseMotion.new()
	drag.button_mask = MOUSE_BUTTON_MASK_LEFT
	drag.position = start + Vector2(8, 0) * world_surface._zoom
	world_surface._gui_input(drag)
	pointer.pressed = false
	world_surface._gui_input(pointer)
	check(is_equal_approx(pop.find_child("WorldX", true, false).value, 8.0), "drag updates the selected chunk's numeric origin")
	check(not manifest.has("worldLayout"), "world layout remains a draft before save")
	var source_hash := FileAccess.get_sha256(Maps.path_for(manifest, "platform"))
	var copy_hash := FileAccess.get_sha256(Maps.path_for(manifest, "platform_reuse"))
	var world_manifest_hash := FileAccess.get_sha256(path)
	workbench.stage_clone("ending", "preview-only", {"function": "ENDS", "fields": {"MESG": "Preview overlay"}}, "")
	press(pop, "适合窗口")
	var world_camera: Dictionary = world_surface.camera()
	press(pop, "游戏实景预览…")
	await process_frame
	var world_preview: PopupPanel
	for panel in collect(app, "PopupPanel"):
		if panel.visible and panel.find_child("WorldGamePreviewRender", true, false) != null:
			world_preview = panel
	if not is_instance_valid(world_preview):
		check(false, "world preview opens without discarding the layout draft")
		quit(1)
		return
	var world_render: Button = world_preview.find_child("WorldGamePreviewRender", true, false)
	world_render.pressed.emit()
	var world_render_until := Time.get_ticks_msec() + 13500
	while is_instance_valid(world_render) and world_render.disabled and Time.get_ticks_msec() < world_render_until:
		await create_timer(0.08).timeout
	if not is_instance_valid(world_preview) or not is_instance_valid(pop):
		check(false, "world editor and preview survive the renderer taking focus")
		quit(1)
		return
	var world_frame: TextureRect = world_preview.find_child("WorldGamePreviewFrame", true, false)
	check(world_frame.texture != null, "world renderer returned a frame for the draft")
	if world_frame.texture != null:
		var image := world_frame.texture.get_image()
		var center := Vector2(world_camera.center[0], world_camera.center[1])
		var color_at := func(point: Vector2) -> String:
			var pixel := Vector2i(((point - center) * float(world_camera.zoom) + Vector2(image.get_size()) * 0.5).round())
			return image.get_pixelv(pixel).to_html(false)
		check(color_at.call(Vector2(-56, 40)) == "f29b41" and color_at.call(Vector2(80, 40)) == "f29b41"
			and color_at.call(Vector2(4, 40)) == "18203a" and color_at.call(Vector2(-122, 6)) == "46c4ae"
			and color_at.call(Vector2(14, 6)) == "34476c",
			"world preview renders both gates, the draft gap and the current room's staged content")
	check(not manifest.has("worldLayout") and world_manifest_hash == FileAccess.get_sha256(path)
		and source_hash == FileAccess.get_sha256(Maps.path_for(manifest, "platform"))
		and copy_hash == FileAccess.get_sha256(Maps.path_for(manifest, "platform_reuse"))
		and not FileAccess.file_exists(Store.path_for(manifest, "ending", "preview-only")),
		"world rendering does not publish draft layout, maps or content")
	workbench.drop_staged_for_doc(app._map_file_ctrl.sess.doc_key)
	world_preview.hide()
	await process_frame
	press(pop, "保存世界布局")
	await process_frame
	var world: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path)).get("worldLayout", {})
	var chunks: Dictionary = world.get("chunks", {})
	check(WorldLayout.issues({"worldLayout": world}).is_empty() and chunks.size() == 2
		and chunks.has(room.meta.code) and WorldLayout.rect(chunks[room.meta.code]) == Rect2(-128, 0, 128, 128)
		and chunks.has(copied_room.meta.code) and WorldLayout.rect(chunks[copied_room.meta.code]) == Rect2(8, 0, 96, 128)
		and source_hash == FileAccess.get_sha256(Maps.path_for(manifest, "platform"))
		and copy_hash == FileAccess.get_sha256(Maps.path_for(manifest, "platform_reuse")),
		"world positions, sizes and stable map codes are persisted without rewriting the maps: " + str(world))
	pop.hide()
	check(Maps.rename_map(manifest, "platform_reuse", "platform_chunk") == "", "rename a placed map without changing the world layout")
	app._nav_bars[0]._switch_menu.id_pressed.emit(100002)
	await process_frame
	pop = collect(app, "PopupPanel").filter(func(p): return p.visible).back()
	select_metadata(pop.find_child("WorldMapList", true, false), copied_room.meta.code)
	check(is_equal_approx(pop.find_child("WorldX", true, false).value, 8.0), "reopened world layout retains the dragged position")
	press(pop, "打开地图")
	await process_frame
	check(app.cur_map_name == "platform_chunk", "world layout opens the renamed map by code")
	var platform_report := await launch_and_read(app, false)
	check(platform_report.get("status") == "ready"
		and platform_report.get("result", {}).get("rise") == 1
		and platform_report.get("result", {}).get("freeRamp") == true
		and platform_report.get("result", {}).get("gate", "") != ""
		and platform_report.get("result", {}).get("gate") != source_platform_report.get("result", {}).get("gate"),
		"independent game traverses the copied room floor/slope to a gate: " + str(platform_report))
	var motion: Dictionary = platform_report.get("result", {}).get("freeRampMotion", {})
	check(motion.get("primaryStops") == true and motion.get("extraStops") == true
		and motion.get("primaryHoleClears") == true and motion.get("extraHoleClears") == true
		and motion.get("gapClears") == true,
		"independent game stops on both saved contour solids and moves through each hole and the gap: " + str(motion))
	var samples: Array = platform_report.get("result", {}).get("worldSamples", [])
	check(samples == [
		{"map": room.meta.code, "gate": source_platform_report.get("result", {}).get("gate", "")},
		{"map": copied_room.meta.code, "gate": platform_report.get("result", {}).get("gate", "")},
		{"map": "", "gate": ""},
	], "independent game loads both authored chunks by world position, including after rename: " + str(samples))

	var generated_path := Maps.path_for(manifest, "generated_slope")
	var before_generation := FileAccess.get_sha256(path)
	app._layout_ctrl._on_map_menu_id(15)
	await process_frame
	pop = collect(app, "PopupPanel").filter(func(p): return p.visible).back()
	pop.find_child("GeneratedMapName", true, false).text = "generated_slope"
	pop.find_child("GeneratorField_start", true, false).value = 3
	var generate_button: Button = pop.find_child("RunMapGenerator", true, false)
	generate_button.pressed.emit()
	var generate_until := Time.get_ticks_msec() + 13500
	while is_instance_valid(generate_button) and generate_button.disabled and Time.get_ticks_msec() < generate_until:
		await create_timer(0.08).timeout
	if not is_instance_valid(pop):
		check(false, "generation window survives game process")
		quit(1)
		return
	var summary: String = pop.find_child("GeneratedMapStatus", true, false).text
	check(summary.begins_with("生成完成") and not FileAccess.file_exists(generated_path)
		and before_generation == FileAccess.get_sha256(path) and app.cur_map_name == "platform_chunk",
		"generated result can be reviewed without writing or switching maps: " + summary)
	press(pop, "打开为可编辑地图")
	await process_frame
	if app.cur_map_name != "generated_slope":
		check(false, "open generated result as the current document")
		quit(1)
		return
	var generated: Dictionary = app.canvas.extract()
	check(app.canvas.modified_flag and not FileAccess.file_exists(generated_path)
		and Vector2i(int(generated.spawn[0]), int(generated.spawn[1])) == Vector2i(3, 2)
		and generated.collision.size() == 2 and generated.objects.size() == 1
		and generated.meta.code != room.meta.code and generated.meta.code != copied_room.meta.code,
		"chosen parameter changes the generated room and the editor gives it a fresh identity")
	app.canvas.active_layer = app.canvas.collision_index()
	app.canvas.collision_shape = ""
	app.canvas._paint(Vector2i(5, 3))
	app.canvas._paint(Vector2i.ZERO)
	app.canvas._undo_history_ctrl.stroke_end()
	app.canvas._paint_pushed = false
	var generated_save: Dictionary = await app._map_file_ctrl.commit_document("保存生成地图")
	check(generated_save.get("status") == "ok", "save the generated room with an authored landing: " + str(generated_save))
	var edited_room := Maps.read(manifest, "generated_slope")
	check(edited_room.get("collision", []).size() == 4, "the author's collision edits survive save")
	var generated_report := await launch_and_read(app, false)
	check(generated_report.get("status") == "ready" and generated_report.get("result", {}).get("rise") == 1
		and generated_report.get("result", {}).get("gate") == "GATE",
		"independent game reaches the generated gate via the author's new landing: " + str(generated_report))
	await app._load_map_file(generated_path)
	var generated_hash := FileAccess.get_sha256(generated_path)
	app._layout_ctrl._on_map_menu_id(16)
	await process_frame
	pop = collect(app, "PopupPanel").filter(func(p): return p.visible).back()
	check(pop.find_child("GeneratorField_start", true, false).value == 3, "saved generator parameters are restored")
	var variant: SpinBox = pop.find_child("GeneratorField_variant", true, false)
	variant.value = 2
	var regenerate: Button = pop.find_child("RunMapGenerator", true, false)
	regenerate.pressed.emit()
	while is_instance_valid(regenerate) and regenerate.disabled:
		await create_timer(0.08).timeout
	summary = pop.find_child("GeneratedMapStatus", true, false).text
	check(summary.contains("发现 2 处冲突")
		and FileAccess.get_sha256(generated_path) == generated_hash and not app.canvas.modified_flag,
		"conflicting generation leaves the document untouched and identifies the edited cell: " + summary)
	var first_choice: OptionButton = pop.find_child("GenerationConflict0", true, false)
	var second_choice: OptionButton = pop.find_child("GenerationConflict1", true, false)
	if first_choice == null or second_choice == null:
		check(false, "independent conflict choices are present")
		quit(1)
		return
	for choice in [first_choice, second_choice]:
		var cell: String = choice.get_parent().get_child(0).text
		var selected := 1 if cell == "collision[5,3]" else 2
		choice.select(selected)
		choice.item_selected.emit(selected)
	summary = pop.find_child("GeneratedMapStatus", true, false).text
	check(summary.begins_with("生成完成"), "conflict decisions can be applied together: " + summary)
	press(pop, "应用重生成")
	await process_frame
	var merged: Dictionary = app.canvas.extract()
	var merged_collision: Array = merged.get("collision", [])
	check(merged_collision.size() == 5 and merged.meta.code == edited_room.meta.code
		and merged_collision.any(func(row): return row.x == 0 and row.y == 0 and row.get("shape") == "r45")
		and merged_collision.any(func(row): return row.x == 5 and row.y == 3 and not row.has("shape"))
		and FileAccess.get_sha256(generated_path) == generated_hash,
		"regeneration keeps the authored landing, adopts the other generated shape, adds the ceiling, and is still unsaved")
	check(await app.canvas.undo() and app.canvas.extract().get("collision", []).size() == 4,
		"one undo restores the prior map and generation baseline")
	check(await app.canvas.redo() and app.canvas.extract().get("collision", []).size() == 5,
		"redo restores the merged map")
	var merged_report := await launch_and_read(app, false)
	check(merged_report.get("status") == "ready" and merged_report.get("result", {}).get("gate") == "GATE"
		and Maps.read(manifest, "generated_slope").meta.generatorSource.parameters.variant == 2,
		"the independent game consumes the saved merge and its new generation baseline")
	var override_hash := FileAccess.get_sha256(generated_path)
	app._nav_bars[0]._switch_menu.id_pressed.emit(100002)
	await process_frame
	pop = collect(app, "PopupPanel").filter(func(p): return p.visible).back()
	world_list = pop.find_child("WorldMapList", true, false)
	select_metadata(world_list, edited_room.meta.code)
	press(pop, "添加到世界")
	pop.find_child("WorldX", true, false).value = 384
	pop.find_child("WorldY", true, false).value = 0
	pop.find_child("WorldWidth", true, false).value = 192
	var key_input: LineEdit = pop.find_child("WorldGeneratedKey", true, false)
	key_input.text = "slope/2/0"
	key_input.text_changed.emit(key_input.text)
	select_metadata(world_list, room.meta.code)
	key_input.text = "slope/2/0"
	key_input.text_changed.emit(key_input.text)
	var before_override := FileAccess.get_sha256(path)
	press(pop, "保存世界布局")
	check(FileAccess.get_sha256(path) == before_override
		and not manifest.worldLayout.chunks.has(edited_room.meta.code),
		"duplicate generated keys cannot publish an ambiguous layout")
	key_input.text = ""
	key_input.text_changed.emit(key_input.text)
	press(pop, "保存世界布局")
	await process_frame
	var saved_world: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path)).worldLayout
	check(saved_world.chunks[edited_room.meta.code].get("generatedKey") == "slope/2/0"
		and FileAccess.get_sha256(generated_path) == override_hash, "saving the slot assignment publishes only the layout")
	pop.hide()
	var hybrid_report := await launch_and_read(app, false)
	var hybrid: Array = hybrid_report.get("result", {}).get("generatedChunks", [])
	check(hybrid.size() == 4
		and hybrid[0].key == "slope/1/0" and not hybrid[0].authored and hybrid[0].collisions == 3 and hybrid[0].gate == "SEED"
		and hybrid[1].key == "slope/2/0" and hybrid[1].authored and hybrid[1].map == edited_room.meta.code
		and hybrid[1].collisions == 5 and hybrid[1].gate == "GATE"
		and hybrid[2].key == "slope/3/0" and not hybrid[2].authored and hybrid[2].collisions == 3 and hybrid[2].gate == "SEED",
		"the independent game uses the author's edited chunk only at its generation key and generates both neighbors: " + str(hybrid_report))
	var lifecycle: Array = hybrid_report.get("result", {}).get("streaming", [])
	check(lifecycle.size() == 4 and lifecycle[0].resident.has("slope/2/0")
		and lifecycle[0].overrideShape == true and lifecycle[0].reused == false
		and lifecycle[1].reused == true and lifecycle[1].unloaded == 1 and not lifecycle[1].resident.has("slope/0/0")
		and lifecycle[2].reused == true and lifecycle[2].overrideShape == true
		and lifecycle[3].reused == true and lifecycle[3].unloaded == 1
		and not lifecycle[3].resident.has("slope/2/0") and lifecycle[3].overrideShape == false
		and lifecycle.all(func(entry): return entry.resident.size() == 3),
		"continuous movement reuses preloaded chunk nodes and removes expired collision bodies: " + str(lifecycle))
	app.canvas.active_layer = app.canvas.collision_index()
	check(app.canvas._tool_ops_ctrl.erase_cells([Vector2i(3, 0)]), "author erases a generated collision cell")
	app.canvas._undo_history_ctrl.stroke_end()
	app.canvas._paint_pushed = false
	app.canvas.active_layer = 0
	app.canvas.paint_asset = "terrain"
	app.canvas.paint_cell = Vector2i.ZERO
	app.canvas._paint(Vector2i.ONE)
	app.canvas._undo_history_ctrl.stroke_end()
	app.canvas._paint_pushed = false
	var grid_save: Dictionary = await app._map_file_ctrl.commit_document("保存格位差量来源")
	check(grid_save.get("status") == "ok", "save the authored add and erase actions")
	app._nav_bars[0]._switch_menu.id_pressed.emit(100002)
	await process_frame
	pop = collect(app, "PopupPanel").filter(func(p): return p.visible).back()
	world_list = pop.find_child("WorldMapList", true, false)
	select_metadata(world_list, edited_room.meta.code)
	select_metadata(pop.find_child("WorldGeneratedMode", true, false), WorldLayout.DELTA_MODE)
	press(pop, "保存世界布局")
	await process_frame
	check(manifest.worldLayout.chunks[edited_room.meta.code].get("generatedMode") == "gridDelta", "publish the selected delta mode")
	pop.hide()
	var delta_report := await launch_and_read(app, false)
	var patches: Array = delta_report.get("result", {}).get("seedPatches", [])
	check(patches.size() == 2 and patches[0].seed == 7 and patches[1].seed == 8
		and patches.all(func(row): return (row.applied and row.seedCell and row.deleted and row.solidLanding
			and row.tilePatched and row.gate == "SEED")),
		"each seed keeps its own generated cells and entities, adds the author's tile and solid landing, and erases the authored cell: " + str(delta_report))
	app.canvas.commit_selection(app.canvas._ent_by_code_index().get("TRIM"))
	check(app.canvas.selected_entity != null, "pick the generated object to remove")
	app.canvas.delete_selection()
	app.canvas.commit_selection(app.canvas._ent_by_code_index().get("GATE"))
	app.canvas.selected_entity.props["label"] = "author"
	app.canvas._mark()
	app.canvas.active_layer = 0
	app.canvas.stamp_asset = "door"
	app.canvas._tool_ops_ctrl.place_object(app.canvas.stamp_asset, app.canvas.active_layer, app.canvas.grid.cell_center_px(Vector2i(1, 1)))
	app.canvas.selected_entity.props["label"] = "extra"
	app.canvas._mark()
	await app.canvas.layer_add("Author overlay")
	var overlay_id: String = app.canvas.layer_id(1)
	app.canvas.active_layer = 1
	app.canvas.paint_asset = "terrain"
	app.canvas.paint_cell = Vector2i.ZERO
	app.canvas._paint(Vector2i(2, 2))
	app.canvas._undo_history_ctrl.stroke_end()
	app.canvas._paint_pushed = false
	app.canvas._tool_ops_ctrl.place_object("button-art", 1, app.canvas.grid.cell_center_px(Vector2i(2, 1)))
	check(app.canvas.set_spawn_cell(Vector2i(3, 1)), "set the authored chunk entrance")
	await app.canvas.layer_set_blend(0, "add")
	await app.canvas.layer_set_param(0, "offset", Vector2(12, 4))
	await app.canvas.layer_set_param(0, "scale", 1.5)
	app.canvas.apply_cell_graph({"spaces": {"deck": {"layer": overlay_id, "origin": [8, 4], "axisX": [1, 0.25]}},
		"cells": [
			{"id": "author-entry", "space": "deck", "polygon": [[0, 0], [16, 0], [8, 12]]},
			{"id": "author-exit", "space": "deck", "polygon": [[16, 0], [32, 0], [24, 12]]}],
		"edges": [{"id": "author-stairs", "from": "author-entry", "to": "author-exit",
			"type": "stairs", "props": {"cost": 3}}]})
	var object_save: Dictionary = await app._map_file_ctrl.commit_document("保存分块摆放物差量")
	check(object_save.get("status") == "ok", "save generated object edit, deletion and addition")
	app._nav_bars[0]._switch_menu.id_pressed.emit(100002)
	await process_frame
	pop = collect(app, "PopupPanel").filter(func(p): return p.visible).back()
	world_list = pop.find_child("WorldMapList", true, false)
	select_metadata(world_list, edited_room.meta.code)
	select_metadata(pop.find_child("WorldGeneratedMode", true, false), WorldLayout.CONTENT_DELTA_MODE)
	press(pop, "保存世界布局")
	await process_frame
	check(manifest.worldLayout.chunks[edited_room.meta.code].get("generatedMode") == WorldLayout.CONTENT_DELTA_MODE,
		"publish both grid and stable instance edits")
	pop.hide()
	var object_report := await launch_and_read(app, false)
	var objects: Array = object_report.get("result", {}).get("seedPatches", [])
	check(objects.size() == 2 and objects.all(func(row):
		return row.applied and row.gate == "GATE" and row.gateLabel == "author" and row.gateSeed == row.seed \
			and row.removedObject and row.seedObject and row.addedObject and row.tilePatched \
			and row.spawn[0] == 3 and row.spawn[1] == 1 and row.blend == "add" and row.decor == 2 \
			and row.authorRoute == "author-exit" and row.authorEdge == "author-stairs" \
			and row.seedRoute == "seed-exit-%d" % int(row.seed) and row.overlay == overlay_id \
			and row.seedWorldX == 12 + float(row.seed) * 1.5 and row.seedWorldY == 5.5),
		"both seeds keep their own playable route and accept the authored route, decor and entrance: " + str(object_report))
	await author_resize(app, manifest)
	await author_projection_copy(app, manifest)
	await author_rule_grids(app, manifest)
	await author_basis_copy(app, manifest)
	await author_multilevel_grid(app, manifest)
	await author_tile_layer_conversion(app, manifest)
	await author_world_region_move(app, manifest)
	await author_frame_picks(app, manifest)
	await author_transformed_terrain(app, manifest)
	await author_collision_batch(app, manifest)
	await author_long_timeline(app, manifest)
	await author_signal_room(app, project + "-signal")
	print("WORKFLOW-DONE failures=", failures)
	quit(1 if failures else 0)

func author_long_timeline(app, manifest: Dictionary) -> void:
	var steps: Array = [{"step": "NEXT", "at": 0, "duration": 10000}]
	for i in range(1, 5000):
		steps.append({"step": "NEXT", "at": i * 2, "track": i % 8})
	check(Store.write(manifest, "second_sequence", "project-long-performance", {
		"id": "project-long-performance", "function": "SSEQ", "name": "Long performance",
		"scope": "project", "fields": {}, "steps": steps,
	}), "create a 5000-step performance fixture")
	app._set_mode("content")
	var panel = app.project_shell.content_editor._steps
	check(panel.open_content("second_sequence", "project-long-performance"), "open the long performance")
	var pop: PopupPanel = panel._steps_pop
	press(pop, "时间轴")
	await process_frame
	var timeline: TimelineView = panel._steps_tl
	var pulse := timeline._block_rect(4967)
	check(timeline._hit(pulse.get_center()) == 4967, "locate a distant instantaneous step on its track")
	check(timeline._hit(Vector2(pulse.position.x, TimelineView.RULER_H + 10)) == 0,
		"a long interval that starts offscreen stays hittable")
	var window := Rect2(pulse.position.x - 200, TimelineView.RULER_H, 500, TimelineView.TRACK_H * 8)
	var expected: Array[int] = []
	var stamp := Time.get_ticks_usec()
	for sample in range(30):
		expected.clear()
		for i in steps.size():
			if timeline._block_rect(i).intersects(window, true):
				expected.append(i)
	var scan_us := Time.get_ticks_usec() - stamp
	stamp = Time.get_ticks_usec()
	var visible: Array[int] = []
	for sample in range(30):
		visible = timeline._visible_blocks(window, 0, 7)
	var query_us := Time.get_ticks_usec() - stamp
	check(visible == expected and visible.has(0) and visible.has(4967),
		"the visible window includes long and instantaneous steps in source order")
	print("TIMELINE-WINDOW steps=5000 samples=30 visible=%d scan_us=%d indexed_us=%d" % [
		visible.size(), scan_us, query_us])
	press(pop, "列表")
	var list: VBoxContainer = panel._steps_list
	collect(list, "SpinBox")[0].get_line_edit().text = "4961"
	press(list, "定位步骤")
	check(panel._steps_sel == 4960 and list.get_child_count() == 42, "jump to a late global row with one page mounted")
	var previous_playhead := timeline.playhead
	press(pop, "时间轴")
	await process_frame
	check(timeline._visible_rect().intersects(timeline._block_rect(4960)) and timeline.playhead == previous_playhead,
		"switching to the timeline reveals the selected step without moving the playhead")
	press(pop, "列表")
	press(list.get_child(2), "↑")
	check(panel._steps_sel == 4959, "moving across a page boundary follows the selected step")
	var saved: Array = Store.read(manifest, "second_sequence", "project-long-performance").get("steps", [])
	check(saved.size() == 5000 and saved[4959].at == 9920 and saved[4960].at == 9918,
		"the reordered steps persist at the intended global positions")
	panel._teardown_steps_host()

func author_collision_batch(app, manifest: Dictionary) -> void:
	var map := Maps.new_map("collision_batch", 224, 224)
	var lid: String = map.meta.layers[0].id
	map.meta.layers.append({"id": "backdrop", "name": "Backdrop"})
	map.tiles[lid] = [[2, 2, "terrain", 0, 0, 5], [3, 2, "terrain", 0, 0, 0]]
	var backdrop := []
	for y in 200:
		for x in 200:
			backdrop.append([x, y, "terrain", 0, 0, 0])
	map.tiles["backdrop"] = backdrop
	map.collision = [{"x": 2, "y": 2, "shape": "r45", "gameRule": {"power": 8}},
		{"x": 6, "y": 4, "type": "hazard"}]
	var path := Maps.path_for(manifest, "collision_batch")
	check(Maps.write(manifest, "collision_batch", map), "save the large-map collision fixture")
	await app._load_map_file(path)
	var cvs: EditorCanvas = app.canvas
	var history = cvs._undo_history_ctrl
	var started := Time.get_ticks_usec()
	var baseline: String = history._snapshot()
	var snapshot_us := Time.get_ticks_usec() - started
	var root_before := cvs.map_root
	started = Time.get_ticks_usec()
	var generated := cvs.generate_collision("top", true, true, 0)
	var generate_us := Time.get_ticks_usec() - started
	var patch: Dictionary = history.undo_stack.back() if history.undo_stack.back() is Dictionary else {}
	check(generated == 2 and patch.get("kind") == "delta" and patch.get("cells", []).size() == 3
		and cvs._collision_meta[Vector2i(2, 2)].type == "one_way"
		and not cvs._collision_meta[Vector2i(2, 2)].has("raw"), "replace records only three changed collision cells")
	cvs.generate_collision("top", true, true, 0)
	check(history.undo_stack.size() == 1, "identical regeneration adds no undo step")
	check(await cvs.undo() and is_same(root_before, cvs.map_root)
		and cvs._collision_meta[Vector2i(2, 2)].shape == "r45"
		and cvs._collision_meta[Vector2i(2, 2)].raw.gameRule.power == 8
		and cvs._collision_meta[Vector2i(6, 4)].type == "hazard",
		"undo restores old geometry and game metadata without rebuilding unrelated layers")
	check(await cvs.redo() and is_same(root_before, cvs.map_root)
		and cvs.collision.get_cell_source_id(Vector2i(6, 4)) == -1
		and cvs.layer_tiles[cvs._layer_index_of("backdrop")].get_used_cells().size() == 40000,
		"redo restores generated cells and leaves the backdrop intact")
	print("COLLISION-BATCH snapshot_us=", snapshot_us, " snapshot_text_bytes=", baseline.to_utf8_buffer().size(),
		" apply_us=", generate_us, " delta_text_bytes=", JSON.stringify(patch).to_utf8_buffer().size())
	var backdrop_index := cvs._layer_index_of("backdrop")
	cvs.set_layer_locked(backdrop_index, true)
	cvs._region_sel = Rect2i(2, 2, 2, 1)
	cvs._region_layer = lid
	var revision := cvs.tile_rev
	app._tile_replace_ctrl.open()
	var pop: PopupPanel = collect(app, "PopupPanel").filter(func(item): return item.visible).back()
	select_metadata(collect(pop, "OptionButton")[1], "terrain-alt")
	press(pop, "替换")
	var tile_patch: Dictionary = history.undo_stack.back() if history.undo_stack.back() is Dictionary else {}
	var layer: TileMapLayer = cvs.layer_tiles[0]
	var cell := Vector2i(2, 2)
	check(tile_patch.get("cells", []).size() == 2 and cvs.tile_rev == revision + 1
		and cvs.asset_of_source(layer.get_cell_source_id(cell)) == "terrain-alt"
		and cvs.extract().tiles[lid].any(func(row): return row == [2, 2, "terrain-alt", 0, 0, 5]),
		"replace only touches the selected layer and preserves the tile transform bits")
	check(await cvs.undo() and is_same(root_before, cvs.map_root)
		and cvs.asset_of_source(layer.get_cell_source_id(cell)) == "terrain",
		"tile batch undo restores original source without rebuilding the canvas")
	check(await cvs.redo() and is_same(root_before, cvs.map_root)
		and cvs.asset_of_source(layer.get_cell_source_id(cell)) == "terrain-alt"
		and cvs.layer_tiles[backdrop_index].get_used_cells().size() == 40000,
		"tile batch redo reapplies the replacement and leaves the locked backdrop intact")

func author_transformed_terrain(app, manifest: Dictionary) -> void:
	await app._load_map_file(Maps.path_for(manifest, "platform"))
	var canvas: EditorCanvas = app.canvas
	await canvas.layer_set_param(0, "offset", Vector2(48, 24))
	await canvas.layer_set_param(0, "scale", 1.5)
	var row: Dictionary = canvas.extract().objects.filter(func(item): return item.asset == "free-ramp").front()
	var terrain: EntityNode = canvas._ent_by_code_index()[row.code]
	canvas.commit_selection(terrain)
	terrain.toggle_flip_h()
	terrain.rotate_90()
	terrain.scale_step(0.25)
	var anchor := terrain.geometry_point_to_world(Vector2.ZERO)
	terrain.set_sort_anchor(Vector2(7, 11))
	canvas._mark_ents()
	var vertex := terrain.geometry_point_to_world(Vector2(40, -28))
	# The previously saved map rounds data coordinates to three decimal places.
	check(anchor.distance_to(Vector2(96.75, 126.0)) < 0.01 and terrain.geometry_point_to_world(Vector2.ZERO).is_equal_approx(anchor)
		and vertex.distance_to(Vector2(149.25, 51.0)) < 0.01
		and terrain.geometry_point_from_world(vertex).is_equal_approx(Vector2(40, -28)),
		"layer offset and scale, rotation, reflection and instance scale preserve the authored anchor and vertex inverse")
	check(canvas._entity_at(terrain.geometry_point_to_world(Vector2(37.5, -6))) == terrain
		and canvas._entity_at(terrain.geometry_point_to_world(Vector2(28.5, -4))) != terrain,
		"editor hit testing separates the transformed solid from its hole")
	var report := await launch_and_read(app, false)
	var result: Dictionary = report.get("result", {})
	var motion: Dictionary = result.get("freeRampMotion", {})
	var actual: Array = result.get("freeRampVertex", [])
	check(report.get("status") == "ready" and actual.size() == 2 and Vector2(actual[0], actual[1]).is_equal_approx(vertex)
		and motion.size() == 5 and not motion.values().has(false),
		"independent physics uses the same transformed contour vertex and keeps both holes and the gap open: " + str(report))

func author_resize(app, manifest: Dictionary) -> void:
	manifest.assets.append({"id": "resize-refs", "kind": "entity", "fields": [
		{"id": "map", "type": "map_ref"},
		{"id": "entity", "type": "entity_ref", "mapField": "map"},
		{"id": "edge", "type": "edge_ref"}]})
	var target := Maps.new_map("resize_target", 12, 10, "orthogonal")
	var source := Maps.new_map("resize_source", 12, 10, "orthogonal")
	var local_refs := {"entity": "DR09", "edge": Edge.value_of("", Vector2i(7, 3), Vector2i(8, 3))}
	target.spawn = [10, 9]
	target.collision = [{"x": 10, "y": 9}]
	target.objects = [
		{"asset": "door", "code": "DR09", "x": 9, "y": 2, "layer": target.meta.layers[0].id},
		{"asset": "resize-refs", "code": "REF0", "x": 2, "y": 2, "layer": target.meta.layers[0].id, "props": local_refs}]
	source.objects = [
		{"asset": "switch", "code": "SW09", "x": 3, "y": 2, "layer": source.meta.layers[0].id,
			"props": {"target": {"map": target.meta.code, "inst": "DR09", "port": "open"}}},
		{"asset": "resize-refs", "code": "REF1", "x": 2, "y": 2, "layer": source.meta.layers[0].id,
			"props": {"map": target.meta.code, "entity": "DR09"}}]
	check(Maps.write(manifest, "resize_target", target) and Maps.write(manifest, "resize_source", source),
		"save resize fixtures with valid local and incoming references")
	var target_path := Maps.path_for(manifest, "resize_target")
	var source_path := Maps.path_for(manifest, "resize_source")
	var source_hash := FileAccess.get_sha256(source_path)
	var target_hash := FileAccess.get_sha256(target_path)
	await app._load_map_file(target_path)
	app._set_mode("map")
	for accept in [false, true]:
		app._open_size_dialog()
		var popups := collect(app, "PopupPanel").filter(func(p): return p.visible)
		var popup: PopupPanel = popups.back()
		for spin in collect(popup, "SpinBox"):
			spin.value = 8
		press(popup, "应用")
		var dialogs := collect(app, "ConfirmationDialog").filter(func(d): return d.visible)
		check(dialogs.size() == 1, "resize displays a confirmation before changing live data")
		if dialogs.size() != 1:
			return
		var confirm: ConfirmationDialog = dialogs[0]
		var message := confirm.dialog_text
		check(message.contains("新增引用问题 4 处") and message.contains("REF0).edge")
			and message.contains("REF0).entity") and message.contains("SW09).target")
			and message.contains("REF1).entity") and message.contains("(10, 9) → (7, 7)"),
			"confirmation names newly broken local edge/entity and incoming port/entity references: " + message)
		if accept:
			confirm.get_ok_button().pressed.emit()
		else:
			confirm.get_cancel_button().pressed.emit()
		for i in 20:
			await process_frame
		if not accept:
			check(app.canvas.extract().spawn == [10, 9], "cancelling resize preserves the live spawn")
	var resized: Dictionary = app.canvas.extract()
	var props: Dictionary = resized.objects[0].get("props", {}) if resized.objects.size() == 1 else {}
	check(resized.meta.w == 8 and resized.meta.h == 8 and resized.spawn == [7, 7]
		and resized.collision.is_empty() and resized.objects.size() == 1
		and props.get("entity") == "DR09" and Edge.edge_of(props.get("edge")) == local_refs.edge.edge
		and str(props.edge.get("map")) == "" and Vector2i(int(props.edge.cell[0]), int(props.edge.cell[1])) == Vector2i(7, 3),
		"accepting resize crops data and preserves reference values: " + str(resized))
	var undone: bool = await app.canvas.undo()
	var restored: Dictionary = app.canvas.extract()
	check(undone and restored.spawn == [10, 9] and restored.meta.w == 12 and restored.meta.h == 10
		and restored.objects.size() == 2 and restored.collision.size() == 1,
		"one resize undo restores dimensions and cropped data")
	check(FileAccess.get_sha256(source_path) == source_hash and FileAccess.get_sha256(target_path) == target_hash,
		"resize does not rewrite either saved map before commit")

func author_projection_copy(app, manifest: Dictionary) -> void:
	var source := Maps.new_map("projection_source", 12, 10, "hexagonal")
	var lid: String = source.meta.layers[0].id
	source.objects = [{"asset": "resize-refs", "code": "REF0", "x": 3, "y": 3, "layer": lid,
		"props": {"edge": Edge.value_of(source.meta.code, Vector2i(3, 3), Vector2i(4, 4))}}]
	check(Maps.write(manifest, "projection_source", source), "write hex projection source")
	var source_path := Maps.path_for(manifest, "projection_source")
	var source_hash := FileAccess.get_sha256(source_path)
	var copy_path := Maps.path_for(manifest, "projection_copy")
	await app._load_map_file(source_path)
	app._on_convert_projection()
	var popups := collect(app, "PopupPanel").filter(func(p): return p.visible)
	if popups.is_empty():
		check(false, "opened projection copy dialog")
		return
	var pop: PopupPanel = popups.back()
	var input: LineEdit = collect(pop, "LineEdit")[0]
	input.text = "projection_copy"
	input.text_changed.emit(input.text)
	select_metadata(collect(pop, "OptionButton")[0], "orthogonal")
	press(pop, "检查副本")
	var labels := collect(pop, "Label")
	check(labels.any(func(label): return label.text.contains("副本新增引用问题 1 处"))
		and not FileAccess.file_exists(copy_path), "projection check displays a dangling edge and does not publish")
	press(pop, "另存并转换")
	for i in 12:
		await process_frame
	var copy := Maps.read(manifest, "projection_copy")
	check(not copy.is_empty() and copy.meta.gridProjection == "orthogonal"
		and copy.objects[0].props.edge.map == copy.meta.code
		and FileAccess.get_sha256(source_path) == source_hash, "publish the reviewed copy while preserving its source")

func author_rule_grids(app, manifest: Dictionary) -> void:
	var skew := [[22.0, 5.0], [7.0, 17.0]]
	var cases := [
		["iso", "isometric", "", [], [[2, 2], [3, 2], [4, 2]], [2, 3], Vector2(0, 40), 4, 4],
		["hex", "hexagonal", "", [], [[2, 2], [1, 3], [1, 4]], [2, 3], Vector2(40, 32), 6, 6],
		["tri", "orthogonal", "triangles", skew, [[4, 2], [5, 2], [6, 2]], [5, 1], Vector2(203, 154) / 3.0, 3, 3],
		["skew", "orthogonal", "", skew, [[2, 2], [3, 2], [4, 2]], [2, 3], Vector2(72.5, 55), 4, 4],
	]
	for sample in cases:
		var name: String = "rule_" + sample[0]
		var route: Array = sample[4]
		app._on_new()
		var popups := collect(app, "PopupPanel").filter(func(p): return p.visible)
		if popups.is_empty():
			check(false, "open new-map dialog for " + name)
			return
		var pop: PopupPanel = popups.back()
		pop.find_child("NewMapName", true, false).text = name
		select_metadata(pop.find_child("NewMapProjection", true, false), sample[1])
		select_metadata(pop.find_child("NewMapTopology", true, false), sample[2])
		if not sample[3].is_empty():
			pop.find_child("NewMapCustomBasis", true, false).button_pressed = true
			var ux: LineEdit = pop.find_child("NewMapBasisUX", true, false)
			var uy: LineEdit = pop.find_child("NewMapBasisUY", true, false)
			var vx: LineEdit = pop.find_child("NewMapBasisVX", true, false)
			var vy: LineEdit = pop.find_child("NewMapBasisVY", true, false)
			ux.text = str(sample[3][0][0])
			uy.text = str(sample[3][0][1])
			if sample[0] == "tri":
				vx.text = ux.text
				vy.text = uy.text
				press(pop, "确定")
				check(pop.visible and collect(pop, "Label").any(func(label): return label.text.contains("不可逆")),
					"singular basis is rejected before leaving the map dialog")
			vx.text = str(sample[3][1][0])
			vy.text = str(sample[3][1][1])
		press(pop, "确定")
		for i in 12:
			await process_frame
			if app.cur_map_name == name and app.map_loaded:
				break
		if app.cur_map_name != name or not app.map_loaded:
			check(false, "new map loaded for " + name)
			return
		var canvas = app.canvas
		canvas.active_layer = 0
		canvas.place_kind = "tile"
		canvas.paint_asset = "terrain"
		canvas.paint_cell = Vector2i.ZERO
		canvas.brush_size = 1
		var painted := route + [sample[5]]
		for cell in painted:
			var point: Vector2 = canvas.grid.cell_center_px(Vector2i(cell[0], cell[1]))
			canvas._apply_tool(canvas.to_layer_world(canvas.active_layer, point))
		canvas._undo_history_ctrl.stroke_end()
		canvas._paint_pushed = false
		canvas.active_layer = canvas.collision_index()
		canvas.collision_shape = ""
		canvas.collision_type = "solid"
		var blocked: Array = sample[5]
		canvas._apply_tool(canvas.grid.cell_center_px(Vector2i(blocked[0], blocked[1])))
		canvas._undo_history_ctrl.stroke_end()
		canvas._paint_pushed = false
		canvas._drag_spawn_to(sample[6])
		canvas.active_layer = 0
		canvas.place_kind = "object"
		canvas.stamp_asset = "door"
		canvas.snap_to_grid = false
		var goal: Array = route.back()
		var goal_point: Vector2 = canvas.grid.cell_center_px(Vector2i(goal[0], goal[1]))
		canvas._apply_tool(canvas.to_layer_world(canvas.active_layer, goal_point))
		if canvas.selected_entity == null:
			check(false, "place a door on " + name)
			return
		var gate: String = canvas.selected_entity.code
		var saved: Dictionary = await app._map_file_ctrl.commit_document("保存格网路线")
		if saved.get("status") != "ok":
			check(false, "save authored map " + name + ": " + str(saved))
			return
		await app._load_map_file(Maps.path_for(manifest, name))
		var reopened: Dictionary = canvas.extract()
		check(reopened.get("meta", {}).get("gridProjection") == sample[1]
			and reopened.get("meta", {}).get("gridBasis", []) == sample[3]
			and reopened.get("meta", {}).get("gridTopology", "") == sample[2]
			and reopened.get("spawn") == route[0] and canvas.spawn.position.is_equal_approx(sample[6]),
			"reopen the same topology and spawn on %s: %s, spawn=%s at %s" % [
				name, reopened.get("meta", {}), reopened.get("spawn"), canvas.spawn.position])
		var report := await launch_and_read(app, false)
		var result: Dictionary = report.get("result", {})
		var center: Array = result.get("center", [INF, INF])
		var actual_path: Array = result.get("path", []).map(func(cell): return [int(cell[0]), int(cell[1])])
		check(actual_path == route and result.get("gate") == gate
			and result.get("reached") == true and result.get("rejectedNeighbor") == true
			and Vector2(center[0], center[1]).is_equal_approx(sample[6])
			and result.get("vertices") == sample[7] and result.get("neighbors") == sample[8],
			"independent game traverses the authored route on " + name + ": " + str(report))

func author_basis_copy(app, manifest: Dictionary) -> void:
	var source_path := Maps.path_for(manifest, "rule_skew")
	var target_path := Maps.path_for(manifest, "rule_skew_rebased")
	if not FileAccess.file_exists(source_path):
		check(false, "custom basis source exists")
		return
	var source_hash := FileAccess.get_sha256(source_path)
	await app._load_map_file(source_path)
	var source: Dictionary = app.canvas.extract()
	var door_code: String = source.objects[0].code
	var source_anchor: Vector2 = app.canvas._ent_by_code_index()[door_code].position
	app._on_convert_projection()
	var popups := collect(app, "PopupPanel").filter(func(p): return p.visible)
	if popups.is_empty():
		check(false, "open custom grid conversion")
		return
	var pop: PopupPanel = popups.back()
	var map_name: LineEdit = collect(pop, "LineEdit")[0]
	map_name.text = "rule_skew_rebased"
	map_name.text_changed.emit(map_name.text)
	var enabled: CheckBox = pop.find_child("TargetGridCustomBasis", true, false)
	var ux: LineEdit = pop.find_child("TargetGridBasisUX", true, false)
	check(enabled.button_pressed and is_equal_approx(ux.text.to_float(), 22.0), "load existing basis into conversion inputs")
	ux.text = "24"
	ux.text_changed.emit(ux.text)
	press(pop, "检查副本")
	check(collect(pop, "Button").any(func(btn): return btn.text == "另存并转换")
		and not FileAccess.file_exists(target_path), "freeze custom basis conversion for review")
	ux.text = "25"
	ux.text_changed.emit(ux.text)
	check(collect(pop, "Button").any(func(btn): return btn.text == "检查副本")
		and not FileAccess.file_exists(target_path), "editing the basis invalidates the frozen review")
	press(pop, "检查副本")
	press(pop, "另存并转换")
	for i in 12:
		await process_frame
	var copy := Maps.read(manifest, "rule_skew_rebased")
	if copy.is_empty():
		check(false, "save the reviewed custom grid copy")
		return
	await app._load_map_file(target_path)
	var copy_anchor: Vector2 = app.canvas._ent_by_code_index()[copy.objects[0].code].position
	check(copy.meta.gridBasis[0][0] == 25.0 and copy.meta.gridProjection == "orthogonal"
		and copy.meta.code != source.meta.code and copy.objects[0].code != door_code
		and source_anchor.distance_to(copy_anchor) < 0.025
		and copy.tiles.keys().size() == source.tiles.keys().size()
		and copy.collision.size() == source.collision.size()
		and FileAccess.get_sha256(source_path) == source_hash,
		"reopened basis copy preserves the reviewed basis, local anchor and source file")

func author_multilevel_grid(app, manifest: Dictionary) -> void:
	var path := Maps.path_for(manifest, "rule_hex")
	await app._load_map_file(path)
	var cvs = app.canvas
	var ground: String = cvs.layer_id(0)
	var upper: String = cvs.layer_id(1)
	await cvs.layer_set_param(1, "offset", Vector2(112, 22))
	await cvs.layer_set_param(1, "scale", 1.5)
	app._layout_ctrl._layer_ctrl._open_layer_manager()
	var managers := collect(app, "PopupPanel").filter(func(p): return p.visible)
	if managers.is_empty():
		check(false, "open the layer manager")
		return
	var manager: PopupPanel = managers.back()
	var grid_option: OptionButton = manager.find_child("LayerTileGrid_" + upper, true, false)
	if grid_option == null:
		check(false, "find the upper layer's grid control")
		return
	grid_option.select(5)
	grid_option.item_selected.emit(5)
	var custom_popups := collect(app, "PopupPanel").filter(func(p): return p.visible)
	if custom_popups.is_empty():
		check(false, "open the custom tile grid dialog")
		return
	var custom: PopupPanel = custom_popups.back()
	custom.find_child("LayerCustomTopology", true, false).select(1)
	custom.find_child("LayerCustomBasisVX", true, false).text = "4"
	press(custom, "应用图层格系")
	for i in 12:
		await process_frame
		if cvs.is_map_ready() and cvs.tile_grid_for_layer(1).is_tri():
			break
	if not cvs.tile_grid_for_layer(1).is_tri() or not cvs.tile_grid_for_layer(1).has_basis or not cvs.grid.is_hex_geom():
		check(false, "configure a custom triangle tile layer on a hex map")
		return
	cvs.active_layer = 1
	cvs.place_kind = "tile"
	cvs.paint_asset = "terrain"
	cvs.paint_cell = Vector2i.ZERO
	for cell in [Vector2i(1, 4), Vector2i(2, 4)]:
		cvs._apply_tool(cvs.to_layer_world(1, cvs.tile_grid_for_layer(1).cell_center_px(cell)))
	cvs._undo_history_ctrl.stroke_end()
	cvs._paint_pushed = false
	author_layer_region_edits(cvs)
	cvs._region_sel = Rect2i()
	cvs._region_layer = ""
	GraphEditor.open(app)
	var popups := collect(app, "PopupPanel").filter(func(p): return p.visible)
	if popups.is_empty():
		check(false, "open the rule grid graph editor")
		return
	var pop: PopupPanel = popups.back()
	var tile_layer: OptionButton = pop.find_child("GraphTileLayer", true, false)
	var space_id: LineEdit = pop.find_child("NewGraphSpaceId", true, false)
	select_metadata(tile_layer, ground)
	space_id.text = "ground"
	press(pop, "从瓦片生成格")
	space_id.text = "ground"
	press(pop, "从瓦片生成格")
	check(collect(pop, "Label").any(func(label): return label.text.contains("没有新格")),
		"reimport does not overwrite existing cells or their edges")
	select_metadata(tile_layer, upper)
	space_id.text = "upper"
	press(pop, "从瓦片生成格")
	var graph_preview = pop.find_child("GraphPreview", true, false)
	if graph_preview.rows.size() != 6:
		check(false, "import both independent layers into the graph: " + str(graph_preview.rows.size()))
		return
	select_metadata(pop.find_child("GraphSpaceFilter", true, false), "")
	# Picker selection follows the space filter, so select the source first, then show all spaces.
	select_metadata(pop.find_child("GraphCellPicker", true, false), "ground:1,4")
	var filter: OptionButton = pop.find_child("GraphSpaceFilter", true, false)
	filter.select(0)
	filter.item_selected.emit(0)
	var edge_type: OptionButton = pop.find_child("NewEdgeType", true, false)
	edge_type.select(1)
	press(pop, "新建连接")
	var stairs: String = graph_preview.selected_edge
	pop.find_child("GraphLinkMode", true, false).button_pressed = true
	await process_frame
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = graph_preview.projection() * (Vector2(112, 22) + cvs.tile_grid_for_layer(1).cell_center_px(Vector2i(1, 4)) * 1.5)
	graph_preview._gui_input(click)
	pop.find_child("EdgeProperty_cost", true, false).value = 3
	press(pop, "应用到地图")
	var applied: Dictionary = cvs.cell_graph()
	check(applied.get("edges", []).size() == 1 and applied.edges[0].from == "ground:1,4"
		and applied.edges[0].to == "upper:1,4" and applied.edges[0].props.cost == 3,
		"link two floor spaces through a directed typed edge")
	var saved: Dictionary = await app._map_file_ctrl.commit_document("保存跨楼层通行")
	check(saved.get("status") == "ok", "save imported layered grid")
	await app._load_map_file(path)
	if not await extend_upper_floor(app, path, upper):
		return
	var expected := Vector2(160, 118)
	check(cvs.tile_grid_for_layer(1).is_tri() and cvs.grid.is_hex_geom()
		and cvs.cell_polygon_world("upper:2,4").size() == 3
		and cvs.cell_polygon_world("upper:2,4")[0].is_equal_approx(expected)
		and cvs.pick_cell_id_at(Vector2(170, 126), "upper") == "upper:2,4",
		"reopened mixed grid preserves the visual layer transform and honors space filtering")
	var report := await launch_and_read(app, false)
	var result: Dictionary = report.get("result", {})
	check(report.get("status") == "ready" and result.get("goal") == "upper:3,4"
		and result.get("stairs") == stairs and result.get("vertices") == 3
		and result.get("tileTopology") == "triangles"
		and result.get("upperPoint") == [190.0, 142.0], "independent game traverses the authored floor link and extension: " + str(report))

func author_layer_region_edits(cvs) -> void:
	var ground: Dictionary = cvs.extract().tiles.duplicate(true)
	var lower_id: String = cvs.layer_id(0)
	var upper_id: String = cvs.layer_id(1)
	var grid: GridSpace = cvs.tile_grid_for_layer(1)
	var controller = cvs._region_ops_ctrl
	var source: Vector2 = cvs.to_layer_world(1, grid.cell_center_px(Vector2i(2, 4)))
	controller.select_region(source, source)
	cvs.copy_region()
	check(cvs._region_layer == upper_id and cvs._region_clip.get("tile_rows", []).size() == 1,
		"copy a single triangle from its transformed layer")
	cvs.active_layer = 0
	check(not controller.region_clip_matches(), "triangle clipboard cannot paste into a hex layer")
	cvs.active_layer = 1
	cvs._paste_region(Vector2i(8, 4))
	var layer: TileMapLayer = cvs._layer_node(1)
	check(layer.get_cell_source_id(Vector2i(8, 4)) != -1, "paste the selected tile in the active layer")
	var at: Vector2 = cvs.to_layer_world(1, grid.cell_center_px(Vector2i(8, 4)))
	var dest: Vector2 = cvs.to_layer_world(1, grid.cell_center_px(Vector2i(10, 4)))
	controller.select_region(at, at)
	controller._begin_region_move(at)
	controller._move_region_preview(dest)
	controller._finish_region_move()
	cvs.end_gesture()
	check(layer.get_cell_source_id(Vector2i(8, 4)) == -1 and layer.get_cell_source_id(Vector2i(10, 4)) != -1,
		"drag moves the tile by half-column coordinates within the active layer")
	controller.select_region(dest, dest)
	cvs.cut_region()
	check(layer.get_cell_source_id(Vector2i(10, 4)) == -1 and cvs.extract().tiles[lower_id] == ground[lower_id],
		"cut removes only the currently selected layer's tile")

func extend_upper_floor(app, path: String, layer_id: String) -> bool:
	var cvs = app.canvas
	var before: Dictionary = cvs.cell_graph().duplicate(true)
	var new_cell := Vector2i(3, 4)
	cvs.active_layer = 1
	cvs.place_kind = "tile"
	cvs.paint_asset = "terrain"
	cvs.paint_cell = Vector2i.ZERO
	cvs._apply_tool(cvs.to_layer_world(1, cvs.tile_grid_for_layer(1).cell_center_px(new_cell)))
	cvs._undo_history_ctrl.stroke_end()
	cvs._paint_pushed = false
	var point: Vector2 = cvs.to_layer_world(1, cvs.tile_grid_for_layer(1).cell_center_px(new_cell))
	cvs._region_ops_ctrl.select_region(point, point)
	GraphEditor.open(app)
	var popups := collect(app, "PopupPanel").filter(func(p): return p.visible)
	if popups.is_empty():
		check(false, "open graph extension dialog")
		return false
	var pop: PopupPanel = popups.back()
	select_metadata(pop.find_child("GraphTileLayer", true, false), layer_id)
	pop.find_child("NewGraphSpaceId", true, false).text = "upper"
	pop.find_child("GraphJoinGeneratedTiles", true, false).button_pressed = true
	press(pop, "从瓦片生成格")
	press(pop, "应用到地图")
	var saved: Dictionary = await app._map_file_ctrl.commit_document("保存楼层延伸")
	if saved.get("status") != "ok":
		check(false, "save graph extension")
		return false
	await app._load_map_file(path)
	var after: Dictionary = cvs.cell_graph()
	var added: Array = after.cells.filter(func(row): return row.id == "upper:3,4")
	var expected: Array = before.cells.duplicate(true)
	for row in expected:
		if row.id == "upper:2,4":
			row.neighbors.append("upper:3,4")
	check(added.size() == 1 and added[0].neighbors == ["upper:2,4"]
		and after.cells.filter(func(row): return row.id != "upper:3,4") == expected
		and after.edges == before.edges, "region import joins a neighboring cell outside the region and preserves authored rows")
	return true

func author_tile_layer_conversion(app, manifest: Dictionary) -> void:
	var path := Maps.path_for(manifest, "rule_hex")
	await app._load_map_file(path)
	var cvs = app.canvas
	var source: Dictionary = cvs.extract()
	var floor: String = cvs.layer_id(1)
	app._layout_ctrl._layer_ctrl._open_layer_manager()
	var popups := collect(app, "PopupPanel").filter(func(p): return p.visible)
	if popups.is_empty():
		check(false, "open layer manager for migration")
		return
	var manager: PopupPanel = popups.back()
	manager.find_child("ConvertTileGrid_" + floor, true, false).pressed.emit()
	popups = collect(app, "PopupPanel").filter(func(p): return p.visible)
	if popups.is_empty():
		check(false, "open layer migration dialog")
		return
	var pop: PopupPanel = popups.back()
	press(pop, "检查瓦片迁移")
	check(collect(pop, "Label").any(func(label): return label.text.contains("重叠 1"))
		and cvs.layer_count() == source.meta.layers.size(), "overlapping target cells block center migration")
	pop.find_child("LayerConversionByCenter", true, false).button_pressed = false
	press(pop, "检查瓦片迁移")
	check(collect(pop, "Button").any(func(btn): return btn.text == "创建迁移图层")
		and cvs.layer_count() == source.meta.layers.size(), "index migration freezes a plan without writing")
	var title: LineEdit = pop.find_child("ConvertedLayerName", true, false)
	title.text = "Converted floor"
	title.text_changed.emit(title.text)
	check(collect(pop, "Button").any(func(btn): return btn.text == "检查瓦片迁移"),
		"renaming the proposed layer invalidates the review")
	press(pop, "检查瓦片迁移")
	press(pop, "创建迁移图层")
	for i in 12:
		await process_frame
		if cvs.is_map_ready() and cvs.layer_name(cvs.active_layer) == "Converted floor":
			break
	if cvs.layer_name(cvs.active_layer) != "Converted floor":
		check(false, "publish a new layer with the reviewed name")
		return
	var copy: String = cvs.layer_id(cvs.active_layer)
	var cloned: Dictionary = cvs.extract()
	check(cloned.tiles[copy] == source.tiles[floor] and cloned.tiles[floor] == source.tiles[floor]
		and cloned.meta.cellGraph == source.meta.cellGraph and cloned.objects == source.objects
		and cloned.collision == source.collision and cloned.meta.layers[2].offset == source.meta.layers[1].offset
		and cvs.tile_grid_for_layer(cvs.active_layer).projection == "orthogonal"
		and not cvs.tile_grid_for_layer(cvs.active_layer).is_tri(), "migrate tiles only and preserve the original layer and gameplay")
	check(await cvs.undo() and cvs._layer_index_of(copy) == -1, "undo removes the new layer in one operation")
	check(await cvs.redo() and cvs._layer_index_of(copy) == 2, "redo restores the same layer identity")
	var saved: Dictionary = await app._map_file_ctrl.commit_document("保存迁移图层")
	check(saved.get("status") == "ok", "save layer migration")
	await app._load_map_file(path)
	check(cvs.extract().tiles.get(copy, []) == source.tiles[floor], "converted tiles reopen with preserved indices")

func author_world_region_move(app, manifest: Dictionary) -> void:
	var path := Maps.path_for(manifest, "rule_hex")
	await app._load_map_file(path)
	var cvs = app.canvas
	var baseline: Dictionary = cvs.extract()
	var ground: String = cvs.layer_id(0)
	var upper: String = cvs.layer_id(1)
	var copy: String = cvs.layer_id(2)
	for lid in [ground, upper, copy]:
		baseline.tiles.erase(lid)
	baseline.meta.layers[1].offset = [12.0, 3.0]
	baseline.meta.layers[1].scale = 1.5
	baseline.tiles[ground] = [[0, 0, "terrain", 0, 0], [2, 0, "terrain", 0, 0]]
	baseline.tiles[upper] = [[0, 0, "terrain", 0, 0]]
	baseline.collision = [{"x": 0, "y": 0, "type": "solid", "material": "ice"}]
	baseline.spawn = [0, 0]
	baseline.objects[0].x = 0
	baseline.objects[0].y = 0
	baseline.objects[0].props = {"route_cell": "copy-a",
		"route_edge": {"map": baseline.meta.code, "cell": [0, 0], "edge": "0,0|0,1"},
		"boundary_edge": {"map": baseline.meta.code, "cell": [0, 0], "edge": "0,0|1,0"}}
	await cvs.load_data(baseline, "rule_hex", true)
	var initial: Dictionary = cvs.extract()
	var lower_px: Vector2 = cvs.grid.cell_center_px(Vector2i.ZERO)
	var step: Vector2 = cvs.grid.cell_center_px(Vector2i.RIGHT) - lower_px
	var upper_px: Vector2 = cvs.to_layer_world(1, cvs.tile_grid_for_layer(1).cell_center_px(Vector2i.ZERO))
	var root_local: Vector2 = cvs.to_layer_local(cvs.collision_index(), lower_px)
	var upper_local: Vector2 = cvs.to_layer_local(1, upper_px)
	cvs.map_data.meta.cellGraph = {
		"spaces": {"copy-upper": {"layer": upper}},
		"cells": [
			{"id": "copy-a", "polygon": _copy_test_polygon(root_local), "neighbors": ["copy-b", "outside"]},
			{"id": "copy-b", "space": "copy-upper", "polygon": _copy_test_polygon(upper_local), "neighbors": ["copy-a"],
				"generatedFromTile": "fixture"},
			{"id": "outside", "polygon": _copy_test_polygon(root_local + step * 3), "neighbors": ["copy-a"]}],
		"edges": [
			{"id": "stairs", "from": "copy-a", "to": "copy-b", "props": {"cost": 7.0}},
			{"id": "outside-route", "from": "copy-a", "to": "outside"}]}
	initial = cvs.extract()
	var n: EntityNode = cvs.ents_all()[0]
	var entity_px: Vector2 = n.get_parent().to_global(n.position - n.sort_anchor())
	var min_corner := lower_px.min(upper_px).min(entity_px) - Vector2(2, 2)
	var edge_end: Vector2 = cvs.grid.cell_center_px(Vector2i.DOWN)
	var max_corner := lower_px.max(upper_px).max(entity_px).max(edge_end) + Vector2(2, 2)
	var mouse := InputEventMouseButton.new()
	mouse.button_index = MOUSE_BUTTON_LEFT
	mouse.pressed = true
	cvs.snap_to_grid = true
	press(app, "跨层搬动")
	var input = cvs._canvas_input_ctrl
	input._on_left_press(min_corner, mouse)
	input._on_left_release(max_corner)
	cvs.set_layer_locked(1, true)
	input._on_left_press(lower_px, mouse)
	check(not cvs._move_active, "a selected locked layer refuses a cross-layer move")
	cvs.set_layer_locked(1, false)
	input._on_left_press(lower_px, mouse)
	input._on_left_release(lower_px + step * 2)
	check(cvs.extract() == initial, "a blocked cross-layer move writes none of its members")
	app._copy()
	check(cvs._region_clip.get("world", false), "copy captures the entire world selection")
	check(not cvs._region_clip.has("graph") and not cvs._region_clip.has("spawn"), "ordinary copy leaves graph and spawn opt-in")
	app._paste()
	check(cvs._paste_mode, "cross-layer paste starts a preview")
	input._on_right_press(lower_px)
	check(not cvs._paste_mode and cvs._world_region_move.selection.has_point(lower_px), "cancel paste preserves the source selection")
	app._layout_ctrl._on_map_menu_id(18)
	for flag: CheckBox in collect(app, "CheckBox"):
		if flag.text in ["包括框内的出生点", "副本引用跟随框内规则格边"]:
			flag.button_pressed = true
	press(app, "复制选区")
	check(cvs._region_clip.has("graph") and cvs._region_clip.has("spawn") and cvs._region_clip.has("edge_origin"),
		"the dialog includes the chosen payloads and edge remapping")
	var snap_offset: Vector2 = cvs._region_clip.snap_offset
	var copy_origin := min_corner + snap_offset
	app._paste()
	input._on_left_press(copy_origin + step * 2, mouse)
	check(cvs._paste_mode and cvs.extract() == initial, "an occupied destination rejects the whole paste")
	cvs.set_layer_locked(1, true)
	input._on_left_press(copy_origin + step, mouse)
	check(cvs._paste_mode and cvs.extract() == initial, "a locked destination rejects the whole paste")
	cvs.set_layer_locked(1, false)
	input._on_left_press(copy_origin + step, mouse)
	var copied: Dictionary = cvs.extract()
	var dest_upper: Vector2i = cvs.tile_grid_for_layer(1).pick_cell(cvs.to_layer_local(1, upper_px + step))
	check(not cvs._paste_mode and copied.tiles[ground].size() == 3 and copied.tiles[upper].size() == 2
		and copied.tiles[upper].any(func(row): return Vector2i(row[0], row[1]) == dest_upper)
		and copied.collision.size() == 2 and copied.collision[1].material == "ice"
		and copied.objects.size() == initial.objects.size() + 1 and copied.objects[1].code != initial.objects[0].code
		and copied.spawn == [1, 0] and copied.objects[1].props.route_cell == "copy-a-copy",
		"paste adds both tile grids, collision metadata and a fresh instance without replacing the source")
	var graph: Dictionary = copied.meta.cellGraph
	check(copied.objects[1].props.route_edge.edge == "1,0|1,1"
		and copied.objects[1].props.boundary_edge == initial.objects[0].props.boundary_edge
		and copied.objects[0].props.route_edge == initial.objects[0].props.route_edge,
		"only the copied object's wholly selected edge is moved to its translated root cells")
	check(graph.cells.size() == 5 and graph.edges.size() == 3
		and graph.cells[0].neighbors == ["copy-b", "outside"]
		and graph.cells[3].neighbors == ["copy-b-copy"] and graph.cells[4].space == "copy-upper"
		and graph.edges[2].from == "copy-a-copy" and graph.edges[2].to == "copy-b-copy" and graph.edges[2].props.cost == 7
		and cvs.cell_centroid_world("copy-b-copy").is_equal_approx(upper_px + step),
		"paste translates the induced subgraph, preserves the bound space, and remaps only its internal connections")
	var pasted: EntityNode = cvs._ent_by_code_index().get(str(copied.objects[1].code))
	check(pasted != null and (pasted.get_parent().to_global(pasted.position - pasted.sort_anchor()) - entity_px).is_equal_approx(step),
		"the copied instance retains the common pixel displacement")
	_check_world_move_restore(await cvs.undo(), cvs.extract(), initial, "undo copy")
	_check_world_move_restore(await cvs.redo(), cvs.extract(), copied, "redo copy")
	var copy_save: Dictionary = await app._map_file_ctrl.commit_document("保存跨层复制")
	check(copy_save.get("status") == "ok", "save the cross-layer copy")
	await app._load_map_file(path)
	_check_world_move_restore(true, cvs.extract(), copied, "save and reopen copy")
	var outside: Dictionary = initial.objects[0].duplicate(true)
	outside.code = "EOUT"
	outside.layer = copy
	outside.x = 6
	var implicit_edge := Edge.value_of("", Vector2i.ZERO, Vector2i.DOWN)
	outside.props = {"edge_routes": [{"edge": implicit_edge}, {"map": "rule_iso", "edge": implicit_edge}],
		"unrecognized": implicit_edge}
	initial.objects.append(outside)
	await cvs.load_data(initial.duplicate(true), "rule_hex", true)
	initial = cvs.extract()
	n = cvs.ents_all()[0]
	app._layout_ctrl._on_map_menu_id(19)
	for flag: CheckBox in collect(app, "CheckBox"):
		if flag.text in ["搬动框内格图", "搬动框内出生点", "本图实例引用跟随框内规则格边"]:
			flag.button_pressed = true
	press(app, "应用搬动选项")
	input._on_left_press(min_corner, mouse)
	input._on_left_release(max_corner)
	cvs.set_layer_locked(2, true)
	input._on_left_press(lower_px, mouse)
	input._on_left_release(lower_px + step)
	check(cvs.extract() == initial, "a locked incoming reference rejects the whole opted-in move")
	cvs.set_layer_locked(2, false)
	var external_edge: Dictionary = initial.objects[0].props.route_edge
	var external_content := {"function": "ENDS", "scope": "project", "fields": {"ARED": external_edge}}
	check(Store.write(manifest, "ending", "project-region-edge", external_content), "publish a separate edge reference")
	var external_path := Store.path_for(manifest, "ending", "project-region-edge")
	var external_digest := Store.file_digest(external_path)
	input._on_left_press(lower_px, mouse)
	input._on_left_release(lower_px + step)
	var retained_dialogs := collect(app, "ConfirmationDialog").filter(func(dialog): return dialog.visible)
	check(retained_dialogs.size() == 1 and retained_dialogs[0].dialog_text.contains("ending/project-region-edge.arrival_edge")
		and retained_dialogs[0].dialog_text.contains("0,0|0,1 → 1,0|1,1"), "the move lists the external field and both edge IDs")
	if retained_dialogs.is_empty():
		return
	retained_dialogs[0].get_cancel_button().pressed.emit()
	await process_frame
	check(cvs.extract() == initial, "cancel leaves the region and its references unchanged")
	input._on_left_press(lower_px, mouse)
	cvs._move_region_preview(lower_px + step)
	var plan: Dictionary = cvs._move_snap.get("plan", {})
	check(plan.get("positions", []).size() == 3, "cross-layer preview plans two tile grids and root collision")
	check(plan.get("spawn") == Vector2i.RIGHT and cvs._move_snap.graph_cells.size() == 2,
		"preview includes opted in spawn and both graph spaces")
	var root: Node2D = cvs.map_root
	var steps: int = cvs.undo_step_count()
	input._on_left_release(lower_px + step)
	retained_dialogs = collect(app, "ConfirmationDialog").filter(func(dialog): return dialog.visible)
	retained_dialogs[0].get_ok_button().pressed.emit()
	await process_frame
	check(Store.file_digest(external_path) == external_digest,
		"confirm keeps the external content file pointing at the old position")
	var move_entry: Variant = cvs._undo_history_ctrl.undo_stack.back()
	check(cvs.undo_step_count() == steps + 1 and move_entry is Dictionary
		and move_entry.get("kind") == "region_move" and move_entry.graph_rows.size() == 2
		and move_entry.get("props", {}).size() == 2,
		"mixed region move records one patch with only changed graph rows and reference owners")
	var moved: Dictionary = cvs.extract()
	var upper_row: Array = moved.tiles[upper][0]
	check(moved.tiles[ground].any(func(row): return row[0] == 1 and row[1] == 0)
		and Vector2i(upper_row[0], upper_row[1]) == dest_upper and dest_upper != Vector2i.ZERO
		and moved.collision[0].x == 1 and moved.collision[0].material == "ice"
		and moved.objects[0].code == initial.objects[0].code
		and (n.get_parent().to_global(n.position - n.sort_anchor()) - entity_px).is_equal_approx(step)
		and moved.spawn == [1, 0] and moved.objects[0].props.route_cell == "copy-a",
		"move both tile grids and collision with their own cells and translate the same instance in pixels")
	var outside_moved: Dictionary = moved.objects.filter(func(row): return row.code == "EOUT")[0]
	check(moved.objects[0].props.route_edge.edge == "1,0|1,1"
		and moved.objects[0].props.boundary_edge == initial.objects[0].props.boundary_edge
		and outside_moved.x == outside.x and outside_moved.props.edge_routes[0].edge == Edge.value_of("", Vector2i(1, 0), Vector2i(1, 1))
		and outside_moved.props.edge_routes[1].edge == implicit_edge and outside_moved.props.unrecognized == implicit_edge,
		"local declared edges follow the region even outside the rectangle; boundary, remote and undeclared values stay")
	var moved_graph: Dictionary = moved.meta.cellGraph
	check(moved_graph.edges == initial.meta.cellGraph.edges and moved_graph.cells[2] == initial.meta.cellGraph.cells[2]
		and moved_graph.cells[0].neighbors == ["copy-b", "outside"] and moved_graph.cells[1].id == "copy-b"
		and not moved_graph.cells[1].has("generatedFromTile")
		and cvs.cell_centroid_world("copy-a").is_equal_approx(lower_px + step)
		and cvs.cell_centroid_world("copy-b").is_equal_approx(upper_px + step),
		"moving cells keeps their IDs and all edges while translating each polygon in its own space")
	var undo_ok: bool = await cvs.undo()
	_check_world_move_restore(undo_ok, cvs.extract(), initial, "undo")
	check(is_instance_valid(n) and cvs.map_root == root and cvs._ent_by_code_index().get(n.code) == n,
		"move undo preserves the map root and coded instance")
	var redo_ok: bool = await cvs.redo()
	_check_world_move_restore(redo_ok, cvs.extract(), moved, "redo")
	check(is_instance_valid(n) and cvs.map_root == root and cvs._ent_by_code_index().get(n.code) == n,
		"move redo preserves the map root and coded instance")
	press(app, "跨层搬动")
	var saved: Dictionary = await app._map_file_ctrl.commit_document("保存跨层搬动")
	check(saved.get("status") == "ok", "save the cross-layer move")
	await app._load_map_file(path)
	_check_world_move_restore(true, cvs.extract(), moved, "save and reopen")
	var layer: TileMapLayer = cvs.layer_tiles[0]
	var unresolved := [2, 0, "missing-region-tile", 0, 0, 3]
	cvs.write_tile_row(ground, layer, unresolved)
	var before_overlap: Dictionary = cvs.extract()
	cvs._world_region_move.finish({"groups": [{"lid": ground, "layer": layer,
		"rows": before_overlap.tiles[ground]}], "objects": [], "delta": step,
		"plan": {"positions": [[Vector2i(2, 0), Vector2i(3, 0)]]}})
	var after_overlap: Dictionary = cvs.extract()
	check(after_overlap.tiles[ground].size() == 2 and layer.get_cell_source_id(Vector2i(1, 0)) == -1
		and layer.get_cell_source_id(Vector2i(2, 0)) >= 0
		and cvs.unresolved_tile(ground, Vector2i(3, 0)) == [3, 0, "missing-region-tile", 0, 0, 3],
		"overlapping move replaces a selected destination and preserves the unresolved tile row")
	_check_world_move_restore(await cvs.undo(), cvs.extract(), before_overlap, "undo overlapping move")
	_check_world_move_restore(await cvs.redo(), cvs.extract(), after_overlap, "redo overlapping move")

func _copy_test_polygon(center: Vector2) -> Array:
	var result := []
	for corner in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		var point: Vector2 = center + corner
		result.append([point.x, point.y])
	return result

func _check_world_move_restore(ok: bool, actual: Dictionary, expected: Dictionary, op: String) -> void:
	var diffs := []
	for key in expected:
		# Undo snapshots and disk round trips parse JSON numbers as floats.
		var a := JSON.stringify(JSON.parse_string(JSON.stringify(actual.get(key))))
		var b := JSON.stringify(JSON.parse_string(JSON.stringify(expected[key])))
		if a != b:
			diffs.append("%s: %s vs %s" % [key, a, b])
	check(ok and actual.size() == expected.size() and diffs.is_empty(),
		"one %s restores the entire cross-layer move: %s" % [op, "; ".join(diffs)])
func _render_pick_frame(app, label := "", preset := "portrait") -> PopupPanel:
	var popups := collect(app, "PopupPanel").filter(func(p): return p.visible and p.find_child("MapGamePreviewRender", true, false) != null)
	if popups.is_empty():
		check(false, "open the game frame picker " + label)
		return null
	var pop: PopupPanel = popups.back()
	select_metadata(pop.find_child("MapGamePreviewViewport", true, false), preset)
	var render: Button = pop.find_child("MapGamePreviewRender", true, false)
	render.pressed.emit()
	return await _wait_for_pick_frame(pop)

func _wait_for_pick_frame(pop: PopupPanel) -> PopupPanel:
	var render: Button = pop.find_child("MapGamePreviewRender", true, false)
	var until := Time.get_ticks_msec() + 13500
	while is_instance_valid(render) and render.disabled and Time.get_ticks_msec() < until:
		await create_timer(0.08).timeout
	if not is_instance_valid(pop) or not pop.visible or pop.find_child("MapGamePreviewFrame", true, false).texture == null:
		check(false, "load the game frame picker")
		return null
	return pop

func _click_pick_frame(pop: PopupPanel, at: Vector2, button := MOUSE_BUTTON_LEFT, modifier := KEY_NONE) -> Button:
	var frame: TextureRect = pop.find_child("MapGamePreviewFrame", true, false)
	var extent := frame.texture.get_size()
	var fitted := extent * minf(frame.size.x / extent.x, frame.size.y / extent.y)
	var mouse := InputEventMouseButton.new()
	mouse.button_index = button
	mouse.ctrl_pressed = modifier == KEY_CTRL
	mouse.shift_pressed = modifier == KEY_SHIFT
	mouse.pressed = true
	mouse.position = (frame.size - fitted) * 0.5 + fitted * at
	frame.gui_input.emit(mouse)
	return pop.find_child("MapGamePreviewConfirmPick", true, false)

func _frame_pick_at_world(pop: PopupPanel, point: Vector2) -> Vector2:
	var values := []
	for key in ["X", "Y", "Zoom"]:
		var field: LineEdit = pop.find_child("MapGamePreviewCamera" + key, true, false)
		values.append(float(field.placeholder_text if field.text.is_empty() else field.text))
	return Vector2(0.5, 0.5) + (point - Vector2(values[0], values[1])) * values[2] / Vector2(720, 1280)

func author_frame_picks(app, manifest: Dictionary) -> void:
	var map := Maps.new_map("frame_pick", 10, 10, "orthogonal")
	var destination := Maps.new_map("frame_pick_destination", 10, 10, "orthogonal")
	var destination_code: String = destination.meta.code
	var primary: String = map.meta.layers[0].id
	var upper: String = map.meta.layers[1].id
	map.meta.layers[1].offset = [48, 16]
	map.meta.layers[1].scale = 1.5
	map.meta.cellGraph = {"spaces": {"upper-side": {"layer": upper, "origin": [40, 30], "axisX": [2, 0]}},
		"cells": [{"id": "entry", "polygon": [[20, 20], [30, 22], [22, 31]], "neighbors": []}]}
	map.objects = [{"asset": "switch", "code": "PICK", "layer": primary, "x": 0, "y": 0,
		"props": {"backup_map": destination_code}}]
	map.collision = [{"x": 1, "y": 1, "type": "solid", "material": "ice"}]
	check(Maps.write(manifest, "frame_pick", map), "make a map with two game view lanes")
	var path := Maps.path_for(manifest, "frame_pick")
	var original_hash := FileAccess.get_sha256(path)
	await app._load_map_file(path)
	var cvs = app.canvas
	app._on_layer(0)
	cvs.stamp_asset = "door"
	cvs.place_kind = "object"
	cvs.snap_to_grid = true
	for i in 2:
		app._layout_ctrl._on_map_menu_id(14)
		var pop := await _render_pick_frame(app)
		if pop == null:
			return
		check(_click_pick_frame(pop, Vector2(-0.12, 0.25)).disabled, "empty margin does not pick through the letterbox")
		var approve := _click_pick_frame(pop, Vector2(0.15 + i * 0.5, 0.25))
		check(not approve.disabled and cvs.ents_all().size() == i + 1, "mapped placement awaits explicit confirmation")
		approve.pressed.emit()
		await process_frame
	var objects: Array = cvs.extract().objects
	var doors: Array = objects.filter(func(row): return row.asset == "door")
	if doors.size() != 2:
		check(false, "both views can place a door")
		return
	check(doors[0].layer == primary and doors[1].layer == upper and doors[0].x == 1 and doors[0].y == 1
		and is_equal_approx(float(doors[1].x), 2.786) and is_equal_approx(float(doors[1].y), 2.071)
		and FileAccess.get_sha256(path) == original_hash,
		"both frame regions map to stable layer-local anchors without writing the file")
	cvs.stamp_asset = "free-ramp"
	app._layout_ctrl._on_map_menu_id(14)
	var shape_pop := await _render_pick_frame(app)
	if shape_pop == null:
		return
	var frame: TextureRect = shape_pop.find_child("MapGamePreviewFrame", true, false)
	var pixels := frame.texture.get_image()
	var occluder := Vector2(0.74, 0.20)
	var color := pixels.get_pixel(533, 256)
	check(color.r > color.g * 1.5 and _click_pick_frame(shape_pop, occluder).disabled,
		"visible foreground mesh blocks selecting the surface behind it")
	_click_pick_frame(shape_pop, Vector2(0.65, 0.25))
	_click_pick_frame(shape_pop, Vector2(0.75, 0.25))
	check(_click_pick_frame(shape_pop, Vector2(0.15, 0.25)).disabled,
		"a draft cannot combine two independently mapped layers")
	var create := _click_pick_frame(shape_pop, Vector2(0.65, 0.35))
	check(not create.disabled and cvs.ents_all().size() == 3, "three mapped points form an uncommitted polygon")
	check(_click_pick_frame(shape_pop, Vector2.ZERO, MOUSE_BUTTON_RIGHT).disabled, "right click removes a draft vertex")
	create = _click_pick_frame(shape_pop, Vector2(0.65, 0.35))
	create.pressed.emit()
	await process_frame
	var outlines: Array = cvs.extract().objects.filter(func(row): return row.asset == "free-ramp")
	if outlines.size() != 1:
		check(false, "confirm creates a single polygon")
		return
	var outline: Dictionary = outlines[0]
	check(outline.layer == upper and outline.props.points.size() == 3
		and absf(float(outline.props.points[1][0]) - 6.10) < 0.03
		and absf(float(outline.props.points[2][1]) - 9.14) < 0.03, "polygon stores perspective-correct local coordinates")
	check(await cvs.undo() and cvs.ents_all().size() == 3, "one undo removes the entire polygon")
	check(await cvs.redo() and cvs.ents_all().size() == 4, "one redo restores the polygon")
	app._set_mode("content", "PICK")
	var editor = app.project_shell.content_editor
	var port_picker: Button = editor.root.find_child("FrameReference_target", true, false)
	check(port_picker != null, "the instance port exposes its own frame picker")
	if port_picker == null:
		return
	port_picker.pressed.emit()
	var ref_pop := await _render_pick_frame(app)
	if ref_pop == null:
		return
	var connect_port := _click_pick_frame(ref_pop, Vector2(0.65, 0.25))
	check(not connect_port.disabled, "the secondary view exposes a matching declared port")
	connect_port.pressed.emit()
	await process_frame
	check(not is_instance_valid(ref_pop) or not ref_pop.visible, "the reference picker closes after writing its field")
	var linked: Array = cvs.extract().objects.filter(func(row): return row.code == "PICK")
	check(linked[0].get("props", {}).get("target", {}).get("inst") == doors[1].code, "confirm writes the instance port field")
	app._set_mode("map")
	cvs.place_kind = "tile"
	cvs.paint_asset = "terrain"
	cvs.paint_cell = Vector2i.ZERO
	cvs.brush_size = 1
	app._layout_ctrl._on_map_menu_id(14)
	var paint_pop := await _render_pick_frame(app)
	if paint_pop == null:
		return
	var before_tiles: Dictionary = cvs.extract().tiles
	var apply := _drag_pick_frame(paint_pop, Vector2(0.11, 0.25), Vector2(0.86, 0.25))
	check(not apply.disabled and cvs.extract().tiles == before_tiles, "mapped stroke is a draft until confirmed")
	apply.pressed.emit()
	await process_frame
	var painted: Dictionary = cvs.extract().tiles
	check(not painted.get(primary, []).is_empty() and not painted.get(upper, []).is_empty()
		and painted[primary].all(func(row): return row[0] in [1, 2])
		and painted[upper].all(func(row): return row[0] in [3, 4]),
		"one screen drag paints both projected layers and does not bridge the unmapped gap")
	check(await cvs.undo() and cvs.extract().tiles == before_tiles, "one undo reverses the complete multilayer stroke")
	check(await cvs.redo() and cvs.extract().tiles == painted, "redo restores the full stroke")
	app._layout_ctrl._on_map_menu_id(14)
	var erase_pop := await _render_pick_frame(app)
	if erase_pop == null:
		return
	apply = _click_pick_frame(erase_pop, Vector2(0.12, 0.25), MOUSE_BUTTON_RIGHT)
	apply.pressed.emit()
	await process_frame
	var final_tiles: Dictionary = cvs.extract().tiles
	check(final_tiles.get(primary, []).size() < painted.get(primary, []).size()
		and final_tiles.get(upper, []) == painted.get(upper, []), "right button erases the picked tile without touching another layer")
	var original_layer: int = cvs.active_layer
	app._on_layer(cvs.collision_index())
	cvs.collision_type = "one_way"
	cvs.collision_shape = "r45"
	app._layout_ctrl._on_map_menu_id(14)
	var collision_pop := await _render_pick_frame(app)
	if collision_pop == null:
		return
	check(_click_pick_frame(collision_pop, occluder).disabled, "foreground occludes the root collision mapping too")
	var before_collision: Array = cvs.extract().collision
	var collision_steps: int = cvs.undo_step_count()
	apply = _drag_pick_frame(collision_pop, Vector2(0.11, 0.25), Vector2(0.86, 0.25))
	check(not apply.disabled and cvs.extract().collision == before_collision, "projected root collision remains a draft")
	apply.pressed.emit()
	await process_frame
	var authored_collision: Array = cvs.extract().collision
	check(cvs.undo_step_count() == collision_steps + 1 and authored_collision.any(func(row): return row.x == 5 and row.y == 3)
		and authored_collision.all(func(row): return row.x != 3 and row.x != 4 and row.type == "one_way" and row.shape == "r45")
		and authored_collision.any(func(row): return row.x == 1 and row.y == 1 and row.get("material") == "ice")
		and cvs.extract().tiles == final_tiles, "one collision stroke uses both root projections, preserves raw metadata and leaves tiles alone")
	check(await cvs.undo() and cvs.extract().collision == before_collision, "undo restores the original root collision")
	check(await cvs.redo() and cvs.extract().collision == authored_collision, "redo restores the authored slopes")
	app._layout_ctrl._on_map_menu_id(14)
	var collision_erase := await _render_pick_frame(app)
	if collision_erase == null:
		return
	apply = _click_pick_frame(collision_erase, Vector2(0.12, 0.25), MOUSE_BUTTON_RIGHT)
	check(not apply.disabled, "right click drafts root collision erase")
	apply.pressed.emit()
	await process_frame
	check(cvs.collision.get_cell_source_id(Vector2i(1, 1)) == -1 and cvs.extract().tiles == final_tiles,
		"collision erase removes the picked root cell and no tiles")
	app._on_layer(original_layer)
	app._layout_ctrl._on_map_menu_id(17)
	var move_pop := await _render_pick_frame(app)
	if move_pop == null:
		return
	check(_click_pick_frame(move_pop, Vector2(0.15, 0.25)).disabled, "instance selection alone cannot apply a move")
	check(_click_pick_frame(move_pop, Vector2(0.65, 0.25)).disabled, "a destination in another layer cannot move the instance")
	apply = _click_pick_frame(move_pop, Vector2(0.25, 0.25))
	check(not apply.disabled and cvs._ent_by_code_index()[doors[0].code].position.is_equal_approx(Vector2(24, 24)),
		"the mapped move stays in the draft until confirmed")
	apply.pressed.emit()
	var move_frame: TextureRect = move_pop.find_child("MapGamePreviewFrame", true, false)
	check(move_pop.visible and apply.disabled and move_frame.texture == null, "applying drops the old draft and frame immediately")
	apply.pressed.emit()
	if await _wait_for_pick_frame(move_pop) == null:
		return
	check(apply.disabled and move_frame.texture.get_size() == Vector2(720, 1280), "the same picker refreshes at the selected size without a draft")
	check(cvs._ent_by_code_index()[doors[0].code].position.is_equal_approx(Vector2(32, 24)), "apply moves the selected instance")
	_click_pick_frame(move_pop, Vector2(0.75, 0.25))
	check(_click_pick_frame(move_pop, Vector2(0.65, 0.25)).disabled, "a collapsed edge cannot be confirmed")
	apply = _click_pick_frame(move_pop, Vector2(0.73, 0.26))
	check(not apply.disabled, "a new valid outline vertex location is enabled")
	apply.pressed.emit()
	if await _wait_for_pick_frame(move_pop) == null:
		return
	var edited: Array = cvs.extract().objects.filter(func(row): return row.code == outline.code)
	var moved: Array = edited[0].props.points
	check(moved != outline.props.points and moved[0] == outline.props.points[0] and moved[2] == outline.props.points[2],
		"adjust only the specified vertex while preserving identity and other vertices")
	check(_click_pick_frame(move_pop, Vector2(0.73, 0.26), MOUSE_BUTTON_LEFT, KEY_CTRL).disabled,
		"a three-point contour cannot lose a vertex")
	check(_click_pick_frame(move_pop, Vector2(0.65, 0.25), MOUSE_BUTTON_LEFT, KEY_SHIFT).disabled,
		"inserting a vertex first selects its predecessor")
	check(_click_pick_frame(move_pop, Vector2(0.15, 0.25)).disabled, "inserting on another layer is rejected")
	apply = _click_pick_frame(move_pop, Vector2(0.70, 0.25))
	check(not apply.disabled and _frame_contour_points(cvs, outline.code) == moved, "insert is a draft until applied")
	apply.pressed.emit()
	if await _wait_for_pick_frame(move_pop) == null:
		return
	var inserted := _frame_contour_points(cvs, outline.code)
	check(inserted.size() == 4 and inserted[0] == moved[0] and inserted[2] == moved[1] and inserted[3] == moved[2],
		"the new vertex follows the chosen predecessor in the projected ring")
	apply = _click_pick_frame(move_pop, Vector2(0.73, 0.26), MOUSE_BUTTON_LEFT, KEY_CTRL)
	check(not apply.disabled and _frame_contour_points(cvs, outline.code) == inserted, "deletion awaits confirmation")
	apply.pressed.emit()
	if await _wait_for_pick_frame(move_pop) == null:
		return
	move_pop.hide()
	var points := _frame_contour_points(cvs, outline.code)
	check(points == [inserted[0], inserted[1], inserted[3]], "the fresh frame identifies the reindexed vertex for deletion")
	check(await cvs.undo() and _frame_contour_points(cvs, outline.code) == inserted, "one undo restores the deleted vertex")
	check(await cvs.undo() and _frame_contour_points(cvs, outline.code) == moved, "the next undo removes the inserted vertex")
	check(await cvs.undo() and cvs.extract().objects.any(func(row): return row.get("code") == outline.code and row.props.points == outline.props.points),
		"one undo restores the original outline")
	check(cvs._ent_by_code_index()[doors[0].code].position.is_equal_approx(Vector2(32, 24)), "undoing the vertex leaves the instance move")
	check(await cvs.undo() and cvs._ent_by_code_index()[doors[0].code].position.is_equal_approx(Vector2(24, 24)),
		"the next undo restores the original anchor")
	check(await cvs.redo() and cvs._ent_by_code_index()[doors[0].code].position.is_equal_approx(Vector2(32, 24)),
		"redo moves the same stable instance")
	check(await cvs.redo() and _frame_contour_points(cvs, outline.code) == moved,
		"the next redo reapplies the edited vertex")
	check(await cvs.redo() and _frame_contour_points(cvs, outline.code) == inserted, "redo restores the inserted vertex")
	check(await cvs.redo() and _frame_contour_points(cvs, outline.code) == points, "redo deletes the original vertex again")
	app._layout_ctrl._on_map_menu_id(17)
	var rings_pop := await _render_pick_frame(app)
	if rings_pop == null:
		return
	var tools: OptionButton = rings_pop.find_child("MapGamePreviewTool", true, false)
	tools.item_selected.emit(2)
	_click_pick_frame(rings_pop, Vector2(0.65, 0.25))
	_click_pick_frame(rings_pop, Vector2(0.659, 0.27))
	_click_pick_frame(rings_pop, Vector2(0.674, 0.265))
	check(_click_pick_frame(rings_pop, Vector2(0.15, 0.25)).disabled, "a hole cannot collect points from a different layer")
	apply = _click_pick_frame(rings_pop, Vector2(0.659, 0.292))
	check(not apply.disabled and not _frame_contour_props(cvs, outline.code).has("holes"), "the new hole awaits confirmation")
	check(_click_pick_frame(rings_pop, Vector2.ZERO, MOUSE_BUTTON_RIGHT).disabled, "undo the last draft point without editing the map")
	_click_pick_frame(rings_pop, Vector2(0.659, 0.292)).pressed.emit()
	if await _wait_for_pick_frame(rings_pop) == null:
		return
	tools.item_selected.emit(1)
	_click_pick_frame(rings_pop, Vector2(0.65, 0.25))
	_click_pick_frame(rings_pop, Vector2(0.78, 0.25))
	_click_pick_frame(rings_pop, Vector2(0.83, 0.25))
	apply = _click_pick_frame(rings_pop, Vector2(0.78, 0.29))
	check(not apply.disabled, "a separate closed ring can be added in the perspective view")
	apply.pressed.emit()
	if await _wait_for_pick_frame(rings_pop) == null:
		return
	var compound := _frame_contour_props(cvs, outline.code)
	check(compound.get("holes", []).size() == 1 and compound.get("parts", []).size() == 1, "the same instance holds both new rings")
	tools.item_selected.emit(3)
	check(_click_pick_frame(rings_pop, Vector2(0.65, 0.25)).disabled, "the primary outer ring cannot be deleted")
	apply = _click_pick_frame(rings_pop, Vector2(0.659, 0.292))
	check(not apply.disabled, "the refreshed frame identifies the new hole for removal")
	apply.pressed.emit()
	if await _wait_for_pick_frame(rings_pop) == null:
		return
	check(not _frame_contour_props(cvs, outline.code).has("holes"), "confirmation removes the selected hole")
	apply = _click_pick_frame(rings_pop, Vector2(0.78, 0.29))
	check(not apply.disabled, "the extra outer ring remains selectable after ring indexes change")
	apply.pressed.emit()
	if await _wait_for_pick_frame(rings_pop) == null:
		return
	rings_pop.hide()
	check(not _frame_contour_props(cvs, outline.code).has("parts"), "confirmation removes the selected extra outer ring")
	check(await cvs.undo() and _frame_contour_props(cvs, outline.code).has("parts"), "one undo restores the extra outer ring")
	check(await cvs.undo() and _frame_contour_props(cvs, outline.code) == compound, "the next undo restores the hole")
	app._layout_ctrl._on_map_menu_id(17)
	var arrange := await _render_pick_frame(app)
	if arrange == null:
		return
	var arrange_tools: OptionButton = arrange.find_child("MapGamePreviewTool", true, false)
	var door_code: String = doors[0].code
	var door: EntityNode = cvs._ent_by_code_index()[door_code]
	for tool in [4, 5]:
		arrange_tools.select(tool)
		arrange_tools.item_selected.emit(tool)
		var before_transform := door.data_transform.duplicate(true)
		apply = _click_pick_frame(arrange, Vector2(0.15, 0.25))
		check(not apply.disabled and door.data_transform == before_transform, "instance transform stays in the draft")
		apply.pressed.emit()
		if await _wait_for_pick_frame(arrange) == null:
			return
	check(is_equal_approx(float(door.data_transform.get("rotation", 0.0)), PI / 2) and door.flipped_h(),
		"rotate and flip the same instance in the refreshed preview")
	arrange_tools.select(6)
	arrange_tools.item_selected.emit(6)
	var removal_root: Node2D = cvs.map_root
	var steps_before_removal: int = cvs.undo_step_count()
	apply = _click_pick_frame(arrange, Vector2(0.15, 0.25))
	check(not apply.disabled and cvs._ent_by_code_index().has(door_code), "projected deletion needs confirmation")
	apply.pressed.emit()
	if await _wait_for_pick_frame(arrange) == null:
		return
	check(cvs.undo_step_count() == steps_before_removal + 1 and not cvs._ent_by_code_index().has(door_code)
		and _click_pick_frame(arrange, Vector2(0.15, 0.25)).disabled, "removal refreshes picks and records one step")
	arrange.hide()
	check(await cvs.undo() and cvs.map_root == removal_root and cvs._ent_by_code_index()[door_code].flipped_h(),
		"deletion undo restores the transformed instance without rebuilding the map")
	check(await cvs.redo() and not cvs._ent_by_code_index().has(door_code), "redo removes only the selected instance")
	check(await cvs.undo(), "restore the door before publishing the preview edits")
	var before_spawn: Array = cvs.extract().spawn
	var root: Node2D = cvs.map_root
	var steps: int = cvs.undo_step_count()
	var mouse := InputEventMouseButton.new()
	mouse.button_index = MOUSE_BUTTON_LEFT
	var origin: Vector2 = cvs.spawn.get_global_position()
	var target: Vector2 = cvs.to_layer_world(cvs.collision_index(), cvs.grid.cell_center_px(Vector2i(6, 4)))
	cvs.place_kind = "object"
	cvs._canvas_input_ctrl._on_left_press(origin, mouse)
	cvs._drag_spawn_to(target)
	check(cvs.cancel_preview_gesture() and cvs.extract().spawn == before_spawn and cvs.undo_step_count() == steps,
		"cancelled canvas spawn drag restores its original position and history")
	app._layout_ctrl._on_map_menu_id(22)
	var spawn_pop := await _render_pick_frame(app)
	if spawn_pop == null:
		return
	check(_click_pick_frame(spawn_pop, occluder).disabled, "the foreground prevents selecting a spawn behind it")
	cvs.set_layer_locked(cvs.collision_index(), true)
	check(_click_pick_frame(spawn_pop, Vector2(0.65, 0.25)).disabled, "root collision lock prevents moving spawn")
	cvs.set_layer_locked(cvs.collision_index(), false)
	apply = _click_pick_frame(spawn_pop, Vector2(0.65, 0.25))
	check(not apply.disabled and cvs.extract().spawn == before_spawn and FileAccess.get_sha256(path) == original_hash,
		"the projected spawn stays a draft until confirmed")
	apply.pressed.emit()
	await process_frame
	check(cvs.extract().spawn == [5, 3] and cvs.undo_step_count() == steps + 1, "spawn uses root coordinates from the perspective view")
	check(await cvs.undo() and cvs.extract().spawn == before_spawn and cvs.map_root == root, "undo restores the root spawn in place")
	check(await cvs.redo() and cvs.extract().spawn == [5, 3] and cvs.map_root == root, "redo reapplies the root spawn in place")
	var source_switch: EntityNode = cvs._ent_by_code_index()["PICK"]
	cvs.commit_selection(source_switch)
	cvs.place_kind = "object"
	app._on_layer(0)
	var handle: Dictionary = cvs._link_handles()[0]
	var source_port := {"x": -5, "y": 3}
	check(handle.from == cvs.port_position(source_switch, source_port) and cvs._link_handles().size() == 1,
		"the local link starts on its declared source port and the paired remote link is not shown")
	var input = cvs._canvas_input_ctrl
	var upper_door: EntityNode = cvs._ent_by_code_index()[doors[1].code]
	var lower_door: EntityNode = cvs._ent_by_code_index()[doors[0].code]
	var lower_port: Vector2 = cvs.port_position(lower_door, {"x": 5, "y": 4})
	var upper_port: Vector2 = cvs.port_position(upper_door, {"x": 5, "y": 4})
	var previous: Dictionary = source_switch.props.target.duplicate()
	input._on_object_layer_press(handle.handle, mouse)
	cvs._move_link_preview(lower_port)
	check(cvs.gesture == cvs.Gesture.LINK_DRAG and source_switch.props.target == previous, "wire stays a draft during drag")
	input._on_right_press(handle.from)
	check(cvs.gesture == cvs.Gesture.NONE and source_switch.props.target == previous and cvs.ents_all().has(source_switch),
		"right click cancels a wire drag without erasing its source")
	input._on_object_layer_press(handle.handle, mouse)
	input._on_left_release(handle.from)
	check(source_switch.props.target == previous, "an incompatible port does not clear the original wire")
	input._on_object_layer_press(handle.handle, mouse)
	input._on_left_release(lower_port)
	check(source_switch.props.target.inst == doors[0].code, "drag replaces the target with a compatible port")
	check(await cvs.undo() and source_switch.props.target == previous and cvs.map_root == root, "one undo restores the wire in place")
	check(await cvs.redo() and source_switch.props.target.inst == doors[0].code, "redo restores the changed wire")
	cvs.commit_selection(source_switch)
	input._on_object_layer_press(handle.handle, mouse)
	input._on_left_release(Vector2(650, 650))
	check(not source_switch.props.has("target"), "dragging the bound wire to empty space disconnects it")
	input._on_object_layer_press(handle.handle, mouse)
	input._on_left_release(upper_port)
	check(source_switch.props.target == previous, "the wire reconnects to the transformed port on the upper layer")
	var source_id := "%s-SWCH-PICK-reaction-preview" % cvs.cur_map_code()
	source_switch.functions = [{"fn": "REAC", "tr": "TUCH", "content": source_id}]
	editor.stage_clone("reaction", source_id, {"id": source_id, "function": "REAC",
		"fields": {"RMES": "Draft copied from the game frame"}}, "PICK")
	cvs._mark_ents()
	app._layout_ctrl._on_map_menu_id(17)
	var copy_pop := await _render_pick_frame(app)
	if copy_pop == null:
		return
	var copy_tools: OptionButton = copy_pop.find_child("MapGamePreviewTool", true, false)
	copy_tools.select(7)
	copy_tools.item_selected.emit(7)
	var object_count: int = cvs.ents_all().size()
	check(_click_pick_frame(copy_pop, Vector2(0.11, 0.34)).disabled, "copy needs a destination after selecting the switch")
	check(_click_pick_frame(copy_pop, occluder).disabled, "copy cannot use an occluded destination")
	apply = _click_pick_frame(copy_pop, Vector2(0.65, 0.25))
	check(not apply.disabled and cvs.ents_all().size() == object_count, "cross-layer copy stays a draft until confirmed")
	apply.pressed.emit()
	if await _wait_for_pick_frame(copy_pop) == null:
		return
	copy_pop.hide()
	var copied_switches: Array = cvs.ents_all().filter(func(n): return n.asset == "switch" and n.code != "PICK")
	if copied_switches.size() != 1:
		check(false, "one switch was copied")
		return
	var copy: EntityNode = copied_switches[0]
	var copy_code := copy.code
	var copy_id: String = copy.functions[0].content
	check(copy.layer_id == upper and copy.props.target == source_switch.props.target and copy_id != source_id
		and copy.position.is_equal_approx(Vector2(48.0 + 32.0 / 7, 32.0 + 64.0 / 7))
		and not FileAccess.file_exists(Store.path_for(manifest, "reaction", copy_id)),
		"copy has a fresh identity and staged content, preserves its outside port reference and lands in the perspective layer")
	check(await cvs.undo() and not cvs._ent_by_code_index().has(copy_code) and cvs.map_root == root,
		"undo removes just the copy in place")
	check(await cvs.redo() and cvs._ent_by_code_index().has(copy_code), "redo restores the same copy ID")
	app._layout_ctrl._on_map_menu_id(23)
	var graph_pop := await _render_pick_frame(app)
	if graph_pop == null:
		return
	var graph_id: LineEdit = graph_pop.find_child("FrameGraphCellId", true, false)
	var graph_space: OptionButton = graph_pop.find_child("FrameGraphSpace", true, false)
	select_metadata(graph_space, "upper-side")
	graph_id.text = "exit-floor"
	check(_click_pick_frame(graph_pop, Vector2(0.15, 0.25)).disabled, "cannot draw a layer-bound cell from a different view")
	_click_pick_frame(graph_pop, Vector2(0.65, 0.25))
	_click_pick_frame(graph_pop, Vector2(0.75, 0.25))
	apply = _click_pick_frame(graph_pop, Vector2(0.65, 0.35))
	check(not apply.disabled and cvs.cell_graph().cells.size() == 1, "mapped polygon stays a draft")
	apply.pressed.emit()
	if await _wait_for_pick_frame(graph_pop) == null:
		return
	var drawn: Dictionary = cvs.cell_graph().cells.back()
	check(drawn.id == "exit-floor" and drawn.space == "upper-side"
		and Vector2(drawn.polygon[0][0], drawn.polygon[0][1]).distance_to(Vector2(44.0 / 7, 78.0 / 7)) < 0.02,
		"perspective picks are converted to the selected space's local polygon")
	var graph_tools: OptionButton = graph_pop.find_child("MapGamePreviewTool", true, false)
	graph_tools.select(1)
	graph_tools.item_selected.emit(1)
	_click_pick_frame(graph_pop, Vector2(0.15, 0.24))
	apply = _click_pick_frame(graph_pop, Vector2(0.68, 0.28))
	check(not apply.disabled and cvs.cell_graph().cells[0].neighbors.is_empty(), "link stays a draft across the two views")
	apply.pressed.emit()
	if await _wait_for_pick_frame(graph_pop) == null:
		return
	graph_pop.hide()
	check(cvs.cell_graph().cells[0].neighbors == ["exit-floor"] and cvs.cell_graph().cells[1].neighbors.is_empty(),
		"only the selected outgoing direction is added")
	check(await cvs.undo() and cvs.cell_graph().cells[0].neighbors.is_empty(), "undo removes the authored link")
	check(await cvs.redo() and cvs.cell_graph().cells[0].neighbors == ["exit-floor"], "redo restores the same link")
	app._layout_ctrl._on_map_menu_id(23)
	var edge_pop := await _render_pick_frame(app)
	if edge_pop == null:
		return
	var edge_tools: OptionButton = edge_pop.find_child("MapGamePreviewTool", true, false)
	edge_tools.select(2)
	edge_tools.item_selected.emit(2)
	select_metadata(edge_pop.find_child("FrameGraphEdgeType", true, false), "stairs")
	var edge_cost: SpinBox = edge_pop.find_child("FrameEdgeProperty_cost", true, false)
	check(edge_cost.value == 9, "declared edge defaults appear in the game frame editor")
	edge_cost.value = 3
	_click_pick_frame(edge_pop, Vector2(0.15, 0.24))
	apply = _click_pick_frame(edge_pop, Vector2(0.68, 0.28))
	check(not apply.disabled and cvs.cell_graph().get("edges", []).is_empty(), "typed edge remains a draft until confirmation")
	apply.pressed.emit()
	if await _wait_for_pick_frame(edge_pop) == null:
		return
	edge_pop.hide()
	var authored_edge: Dictionary = cvs.cell_graph().get("edges", [{}]).front()
	check(authored_edge.get("from") == "entry" and authored_edge.get("to") == "exit-floor"
		and authored_edge.get("type") == "stairs" and authored_edge.get("props", {}).get("cost") == 3
		and cvs.cell_graph().cells[0].neighbors == ["exit-floor"], "typed edge preserves its own cost and the parallel simple link")
	check(await cvs.undo() and cvs.cell_graph().get("edges", []).is_empty(), "one undo removes only the typed edge")
	var edge_redo: bool = await cvs.redo()
	var restored_edges: Array = cvs.cell_graph().get("edges", [])
	check(edge_redo and restored_edges.size() == 1 and restored_edges[0].id == authored_edge.get("id")
		and restored_edges[0].from == "entry" and restored_edges[0].to == "exit-floor"
		and restored_edges[0].type == "stairs" and int(restored_edges[0].props.cost) == 3,
		"redo restores the same typed edge identity and cost")
	var edge_id: String = authored_edge.get("id", "")
	var graph_root: Node2D = cvs.map_root
	app._layout_ctrl._on_map_menu_id(23)
	edge_pop = await _render_pick_frame(app)
	if edge_pop == null:
		return
	edge_tools = edge_pop.find_child("MapGamePreviewTool", true, false)
	edge_tools.select(3)
	edge_tools.item_selected.emit(3)
	apply = _click_pick_frame(edge_pop, Vector2(0.15, 0.24))
	check(apply.disabled, "editing waits for a specific outgoing edge")
	var existing: OptionButton = edge_pop.find_child("FrameExistingEdge", true, false)
	select_metadata(existing, edge_id)
	var delete_edge: CheckBox = edge_pop.find_child("FrameDeleteEdge", true, false)
	delete_edge.button_pressed = true
	apply.pressed.emit()
	if await _wait_for_pick_frame(edge_pop) == null:
		return
	check(cvs.cell_graph().edges.is_empty() and cvs.cell_graph().cells[0].neighbors == ["exit-floor"],
		"confirmed deletion removes only the selected explicit edge")
	check(await cvs.undo() and cvs.map_root == graph_root and cvs.cell_graph().edges[0].id == edge_id,
		"undo restores the same edge without rebuilding unrelated map data")
	edge_pop.find_child("MapGamePreviewRender", true, false).pressed.emit()
	if await _wait_for_pick_frame(edge_pop) == null:
		return
	_click_pick_frame(edge_pop, Vector2(0.15, 0.24))
	select_metadata(existing, edge_id)
	edge_cost = edge_pop.find_child("FrameEdgeProperty_cost", true, false)
	edge_cost.value = 2
	apply = _click_pick_frame(edge_pop, Vector2(0.15, 0.24))
	check(not apply.disabled and cvs.cell_graph().edges[0].to == "exit-floor", "retargeting only changes the draft before confirmation")
	apply.pressed.emit()
	if await _wait_for_pick_frame(edge_pop) == null:
		return
	check(cvs.cell_graph().edges[0].to == "entry" and cvs.cell_graph().edges[0].props.cost == 2
		and cvs.cell_graph().edges[0].id == edge_id, "editing retargets and changes cost without replacing the edge identity")
	_click_pick_frame(edge_pop, Vector2(0.15, 0.24))
	select_metadata(existing, edge_id)
	apply = _click_pick_frame(edge_pop, Vector2(0.68, 0.28))
	apply.pressed.emit()
	if await _wait_for_pick_frame(edge_pop) == null:
		return
	edge_pop.hide()
	app._layout_ctrl._on_map_menu_id(23)
	var vertex_pop := await _render_pick_frame(app)
	if vertex_pop == null:
		return
	var vertex_tools: OptionButton = vertex_pop.find_child("MapGamePreviewTool", true, false)
	vertex_tools.select(4)
	vertex_tools.item_selected.emit(4)
	var old_polygon: Array = cvs.cell_graph().cells[1].polygon.duplicate(true)
	var vertex_pos := Vector2(0.65, 0.25)
	check(_click_pick_frame(vertex_pop, vertex_pos, MOUSE_BUTTON_LEFT, KEY_CTRL).disabled,
		"a triangular graph cell cannot lose a vertex")
	_click_pick_frame(vertex_pop, vertex_pos, MOUSE_BUTTON_RIGHT)
	_click_pick_frame(vertex_pop, vertex_pos)
	check(_click_pick_frame(vertex_pop, Vector2(0.15, 0.24)).disabled, "a vertex cannot be moved into another coordinate space")
	apply = _click_pick_frame(vertex_pop, Vector2(0.66, 0.255))
	check(not apply.disabled and cvs.cell_graph().cells[1].polygon == old_polygon, "vertex motion stays in the draft")
	apply.pressed.emit()
	if await _wait_for_pick_frame(vertex_pop) == null:
		return
	vertex_pop.hide()
	var edited_polygon: Array = cvs.cell_graph().cells[1].polygon.duplicate(true)
	check(Vector2(edited_polygon[0][0], edited_polygon[0][1]).distance_to(Vector2(6.5507, 11.7391)) < 0.02
		and edited_polygon.slice(1) == old_polygon.slice(1) and cvs.cell_graph().edges[0].id == edge_id,
		"moving a projected vertex preserves the other vertices and existing edge identity")
	check(await cvs.undo() and cvs.cell_graph().cells[1].polygon == old_polygon, "undo restores the previous contour")
	check(await cvs.redo() and cvs.cell_graph().cells[1].polygon == edited_polygon, "redo restores the moved vertex")
	app._layout_ctrl._on_map_menu_id(23)
	var delete_pop := await _render_pick_frame(app)
	if delete_pop == null:
		return
	var delete_tools: OptionButton = delete_pop.find_child("MapGamePreviewTool", true, false)
	delete_tools.select(5)
	delete_tools.item_selected.emit(5)
	var graph_before_delete: Dictionary = cvs.cell_graph().duplicate(true)
	var root_before_delete: Node2D = cvs.map_root
	cvs.set_layer_locked(1, true)
	check(_click_pick_frame(delete_pop, Vector2(0.68, 0.28)).disabled, "locked graph cells cannot be selected for deletion")
	cvs.set_layer_locked(1, false)
	apply = _click_pick_frame(delete_pop, Vector2(0.68, 0.28))
	check(not apply.disabled and cvs.cell_graph() == graph_before_delete, "the selected cell remains in the map until confirmation")
	apply.pressed.emit()
	if await _wait_for_pick_frame(delete_pop) == null:
		return
	check(cvs.cell_graph().cells.size() == 1 and cvs.cell_graph().cells[0].neighbors.is_empty()
		and cvs.cell_graph().edges.is_empty() and _click_pick_frame(delete_pop, Vector2(0.68, 0.28)).disabled,
		"removing a cell clears its explicit and simple inbound connections and refreshes game picks")
	delete_pop.hide()
	check(await cvs.undo() and cvs.map_root == root_before_delete and cvs.cell_graph() == graph_before_delete,
		"one undo restores the cell and its connections without rebuilding the map")
	destination.meta.cellGraph = {"cells": [{"id": "remote", "polygon": [[20, 20], [30, 22], [22, 31]], "neighbors": []}]}
	destination.objects = [{"asset": "door", "code": "DIST", "layer": destination.meta.layers[0].id, "x": 1, "y": 1}]
	check(Maps.write(manifest, "frame_pick_destination", destination), "save a second map with a projected graph cell")
	app._layout_ctrl._on_map_menu_id(23)
	edge_pop = await _render_pick_frame(app)
	if edge_pop == null:
		return
	edge_tools = edge_pop.find_child("MapGamePreviewTool", true, false)
	edge_tools.select(2)
	edge_tools.item_selected.emit(2)
	_click_pick_frame(edge_pop, Vector2(0.15, 0.24))
	var map_picker: OptionButton = edge_pop.find_child("FrameGraphDestinationMap", true, false)
	var pick_destination: Button = edge_pop.find_child("FrameGraphPickDestination", true, false)
	select_metadata(map_picker, destination_code)
	pick_destination.pressed.emit()
	var target_pop := await _render_pick_frame(app)
	if target_pop == null or target_pop == edge_pop:
		check(false, "open a separate target frame while preserving the source")
		return
	var target_point := Vector2(24, 24)
	var default_pick := _frame_pick_at_world(target_pop, target_point)
	var confirm_target := _click_pick_frame(target_pop, default_pick)
	check(not confirm_target.disabled and cvs.cell_graph() == graph_before_delete,
		"picking in the second map does not modify the open map")
	var before_camera: Array = [cvs.cam_pos, cvs.zoom]
	for entry in [["X", "60"], ["Y", "70"], ["Zoom", "6"]]:
		var field: LineEdit = target_pop.find_child("MapGamePreviewCamera" + entry[0], true, false)
		field.text = entry[1]
		field.text_changed.emit(field.text)
	var target_frame: TextureRect = target_pop.find_child("MapGamePreviewFrame", true, false)
	check(confirm_target.disabled and target_frame.texture == null, "changing the target camera clears old pixels and the pending pick")
	target_pop.find_child("MapGamePreviewRender", true, false).pressed.emit()
	if await _wait_for_pick_frame(target_pop) == null:
		return
	check(_click_pick_frame(target_pop, default_pick).disabled, "the previous screen position no longer picks the cell")
	var zoomed_pick := Vector2(0.5, 0.5) + (target_point - Vector2(60, 70)) * 6.0 / Vector2(720, 1280)
	var pixel := Vector2i(zoomed_pick * target_frame.texture.get_size())
	check(target_frame.texture.get_image().get_pixelv(pixel).g > 0.6
		and not _click_pick_frame(target_pop, zoomed_pick).disabled
		and [cvs.cam_pos, cvs.zoom] == before_camera,
		"the game draws and maps the cell at the requested center and scale without moving the editor canvas")
	confirm_target.pressed.emit()
	await process_frame
	apply = edge_pop.find_child("MapGamePreviewConfirmPick", true, false)
	check(not apply.disabled and cvs.cell_graph() == graph_before_delete, "confirming the remote cell only updates the new edge draft")
	apply.pressed.emit()
	if await _wait_for_pick_frame(edge_pop) == null:
		return
	var new_edge: Dictionary = cvs.cell_graph().edges.back()
	check(new_edge.toMap == destination_code and new_edge.to == "remote" and new_edge.from == "entry" and new_edge.id != edge_id,
		"new edge stores the target map and cell together")
	check(await cvs.undo() and cvs.cell_graph() == graph_before_delete, "one undo removes the cross-map edge")
	edge_pop.find_child("MapGamePreviewRender", true, false).pressed.emit()
	if await _wait_for_pick_frame(edge_pop) == null:
		return
	edge_tools.select(3)
	edge_tools.item_selected.emit(3)
	_click_pick_frame(edge_pop, Vector2(0.15, 0.24))
	select_metadata(edge_pop.find_child("FrameExistingEdge", true, false), edge_id)
	pick_destination.pressed.emit()
	target_pop = await _render_pick_frame(app)
	if target_pop == null or target_pop == edge_pop:
		check(false, "reopen the destination picker for an existing edge")
		return
	_click_pick_frame(target_pop, _frame_pick_at_world(target_pop, target_point)).pressed.emit()
	await process_frame
	check(cvs.cell_graph() == graph_before_delete, "remote retargeting preserves the original until source confirmation")
	apply.pressed.emit()
	if await _wait_for_pick_frame(edge_pop) == null:
		return
	edge_pop.hide()
	check(cvs.cell_graph().edges[0].toMap == destination_code and cvs.cell_graph().edges[0].to == "remote",
		"the existing edge now targets the second map")
	app._set_mode("content", "PICK")
	var backup: Button = editor.root.find_child("FrameReference_backup", true, false)
	check(backup != null, "a paired cross-map port exposes a game frame picker")
	if backup == null:
		return
	backup.pressed.emit()
	target_pop = await _render_pick_frame(app)
	if target_pop == null:
		return
	var confirm_remote := _click_pick_frame(target_pop, _frame_pick_at_world(target_pop, target_point))
	var switch: EntityNode = cvs._ent_by_code_index()["PICK"]
	check(not confirm_remote.disabled and not switch.props.has("backup"),
		"the remote port is selectable and remains unwritten until confirmation")
	confirm_remote.pressed.emit()
	await process_frame
	check(switch.props.get("backup") == {"map": destination_code, "inst": "DIST", "port": "open"}
		and switch.props.backup_map == destination_code and cvs.cur_map_code() == map.meta.code,
		"the port is written on the source instance without switching the active map")
	var count: SpinBox = editor.root.find_child("InstanceValue_activation_count", true, false)
	var caption: LineEdit = editor.root.find_child("InstanceValue_caption", true, false)
	check(count != null and caption != null, "the instance form exposes declared input widgets")
	if count == null or caption == null:
		return
	check(count.value == 1 and caption.text == "Switch" and not switch.props.has("activation_count"),
		"declared defaults appear without writing an override")
	count.value = 0
	count.get_line_edit().text_submitted.emit("0")
	check(switch.props.get("activation_count") == 0 and await cvs.undo() and not switch.props.has("activation_count"),
		"undo removes a committed instance override")
	check(await cvs.redo() and switch.props.get("activation_count") == 0, "redo restores the explicit zero")
	var motion_layer: OptionButton = editor.root.find_child("InstanceValue_motion_layer", true, false)
	select_metadata(motion_layer, upper)
	check(switch.props.get("motion_layer") == upper, "the instance layer field stores the selected layer ID")
	await process_frame
	var motion_picker: Button = editor.root.find_child("FrameFieldReference_motion_path", true, false)
	check(motion_picker != null, "the instance can pick a motion path in its chosen layer")
	if motion_picker == null:
		return
	motion_picker.pressed.emit()
	var motion_frame := await _render_pick_frame(app, "instance motion path: " + app.status.text)
	if motion_frame == null:
		return
	check(_click_pick_frame(motion_frame, Vector2(0.15, 0.25)).disabled, "instance path ignores a different layer")
	var confirm_motion := _click_pick_frame(motion_frame, Vector2(0.65, 0.25))
	_click_pick_frame(motion_frame, Vector2(0.75, 0.25))
	check(not confirm_motion.disabled and not switch.props.has("motion_path"),
		"both motion points remain a draft before applying")
	confirm_motion.pressed.emit()
	await process_frame
	await process_frame
	var motion: Array = switch.props.get("motion_path", [])
	check(motion.size() == 2 and await cvs.undo() and not switch.props.has("motion_path")
		and switch.props.motion_layer == upper, "one undo removes the whole chosen path and leaves its layer")
	check(await cvs.redo() and switch.props.get("motion_path") == motion, "redo restores the ordered path")
	motion_layer = editor.root.find_child("InstanceValue_motion_layer", true, false)
	select_metadata(motion_layer, primary)
	var scope_dialogs := collect(app, "ConfirmationDialog").filter(func(d): return d.visible)
	check(scope_dialogs.size() == 1 and switch.props.motion_layer == upper and switch.props.motion_path == motion,
		"changing the layer waits for confirmation while keeping the authored path")
	if scope_dialogs.size() != 1:
		return
	scope_dialogs[0].get_cancel_button().pressed.emit()
	for i in 4:
		await process_frame
	motion_layer = editor.root.find_child("InstanceValue_motion_layer", true, false)
	check(switch.props.motion_layer == upper and str(motion_layer.get_item_metadata(motion_layer.selected)) == upper,
		"cancelling restores the original layer selection")
	select_metadata(motion_layer, primary)
	scope_dialogs = collect(app, "ConfirmationDialog").filter(func(d): return d.visible)
	if scope_dialogs.size() != 1:
		check(false, "changing the layer again opens the confirmation")
		return
	scope_dialogs[0].get_ok_button().pressed.emit()
	for i in 4:
		await process_frame
	check(switch.props.motion_layer == primary and not switch.props.has("motion_path"),
		"confirmed change clears coordinates from the old layer")
	check(await cvs.undo() and switch.props.motion_layer == upper and switch.props.motion_path == motion,
		"one undo restores both the layer and the path")
	caption = editor.root.find_child("InstanceValue_caption", true, false)
	caption.text = ""
	# The mode transition flushes the pending text together with the map.
	app._set_mode("map")
	var saved: Dictionary = await app._map_file_ctrl.commit_document("保存实景落点及连接")
	check(saved.get("status") == "ok", "publish positions and port selected from the game frame")
	await app._load_map_file(path)
	var reopened: EntityNode = cvs._ent_by_code_index()["PICK"]
	check(reopened.props.get("activation_count") == 0 and reopened.props.get("caption") == "",
		"zero and empty string remain explicit overrides after reopening")
	var reopened_motion: Array = reopened.props.get("motion_path", [])
	check(reopened.props.get("motion_layer") == upper and reopened_motion.size() == 2 and motion.size() == 2
		and Vector2(reopened_motion[0][0], reopened_motion[0][1]).is_equal_approx(Vector2(motion[0][0], motion[0][1]))
		and Vector2(reopened_motion[1][0], reopened_motion[1][1]).is_equal_approx(Vector2(motion[1][0], motion[1][1])),
		"instance motion path and layer survive reopening")
	check(cvs.extract().tiles == final_tiles and cvs.extract().spawn == [5, 3], "mapped tile edits and spawn survive save and reopen")
	check(cvs.cell_graph().edges[0].id == edge_id and cvs.cell_graph().edges[0].props.cost == 2
		and cvs.cell_graph().edges[0].toMap == destination_code and cvs.cell_graph().edges[0].to == "remote",
		"the edited edge retains its original ID, new cost, and cross-map destination after reopening")
	await create_ending(app, editor._library, "layer-path", "Layer path", str(map.meta.code), "", "", upper)
	var layer_fields: Dictionary = Store.read(manifest, "ending", "project-layer-path").get("fields", {})
	var layer_path: Array = layer_fields.get("LPTH", [])
	check(layer_fields.get("PMAP") == map.meta.code and layer_fields.get("PLID") == upper and layer_path.size() == 2
		and Vector2(layer_path[0][0], layer_path[0][1]).distance_to(Vector2(48.0 + 32.0 / 7.0, 32.0 + 64.0 / 7.0)) < 0.02
		and Vector2(layer_path[1][0], layer_path[1][1]).distance_to(Vector2(48.0 + 32.0 / 3.0, 32.0 + 32.0 / 3.0)) < 0.02,
		"the saved path contains both perspective-correct local positions in click order")
	var report := await launch_and_read(app, false)
	var result: Dictionary = report.get("result", {})
	var played_path: Array = result.get("layerPath", [])
	var instance_motion: Array = result.get("instanceMotion", [])
	check(instance_motion.size() == 2 and played_path.size() == 2
		and Vector2(instance_motion[0][0], instance_motion[0][1]).distance_to(Vector2(played_path[0][0], played_path[0][1])) < 0.02
		and Vector2(instance_motion[1][0], instance_motion[1][1]).distance_to(Vector2(played_path[1][0], played_path[1][1])) < 0.02,
		"the independent game moves the instance through the same two authored world points")
	check(played_path.size() == 2
		and Vector2(played_path[0][0], played_path[0][1]).distance_to(Vector2(48, 16) + Vector2(48.0 + 32.0 / 7.0, 32.0 + 64.0 / 7.0) * 1.5) < 0.02
		and Vector2(played_path[1][0], played_path[1][1]).distance_to(Vector2(136, 80)) < 0.02,
		"the independent game transforms the saved local path using the chosen layer")
	var picks: Array = result.get("picks", [])
	check(report.get("status") == "ready" and picks.size() == 2 and picks[0].point == [32.0, 24.0]
		and absf(float(picks[1].point[0]) - (48.0 + (48.0 + 32.0 / 7.0) * 1.5)) < 0.02
		and absf(float(picks[1].point[1]) - (16.0 + (32.0 + 64.0 / 7.0) * 1.5)) < 0.02
		and result.get("opened") == ""
		and result.get("openedByCopy") == doors[1].code
		and result.get("openedBackup") == "DIST"
		and absf(float(picks[0].transform.rotation) - PI / 2.0) < 0.001 and picks[0].transform.flip_h == true
		and result.get("playerStart") == [88.0, 56.0]
		and result.get("switchCopies", []).size() == 1 and result.switchCopies[0].code == copy_code
		and result.switchCopies[0].layer == upper and result.switchCopies[0].target.inst == doors[1].code
		and result.switchCopies[0].message == "Draft copied from the game frame"
		and result.get("authoredRoute") == "remote" and result.get("arrivalMap") == destination_code
		and result.get("authoredEdge") == authored_edge.get("id")
		and result.get("arrivalVertex") == [20.0, 20.0]
		and result.get("contours", []).size() == 1 and result.contours[0].props == compound,
		"game reloads both view positions and the projected polygon, and opens the selected door: " + str(report))
	var before_delete: Dictionary = cvs.extract()
	var upper_index: int = cvs._layer_index_of(upper)
	var after_delete: Dictionary = cvs._layer_ops_ctrl.without_layer(before_delete, upper_index)
	var impact := Audit.map_change_reference_impacts(manifest, "frame_pick", before_delete, after_delete)
	check(impact.added.any(func(message): return message.contains("PICK).motion_layer"))
		and impact.added.any(func(message): return message.contains("project-layer-path.path_layer")),
		"deleting a layer previews affected instance and shared content paths: " + str(impact.added))
	await cvs.layer_del(upper_index)
	var problems := Audit._ref_checks(cvs.extract(), manifest, "frame_pick")
	check(problems.any(func(issue): return issue.jump.get("code") == "PICK" and issue.jump.get("prop") == "motion_layer")
		and cvs._ent_by_code_index()["PICK"].props.motion_layer == upper,
		"a missing layer is locatable and preserves the original reference")
	check(await cvs.undo() and not Audit._ref_checks(cvs.extract(), manifest, "frame_pick").any(
		func(issue): return issue.jump.get("prop") == "motion_layer"), "undo restores the referenced layer")
	var campaign := Store.read(manifest, "campaign", "project-acceptance")
	campaign.steps[2].fields.BRCH[0].DEST = "missing-content"
	var findings := Audit._content_ref_checks(manifest, "campaign", "project-acceptance", campaign)
	var nested := findings.filter(func(issue): return issue.path.ends_with("steps[2].routes#0.destination"))
	check(nested.size() == 1, "nested branch issue retains its exact path")
	if nested.size() == 1:
		await app._layout_ctrl._issues_ctrl._jump_to(nested[0])
		var issue_steps = editor._steps
		check(issue_steps._steps_sel == 2 and issue_steps._steps_form.get_children().any(
			func(row): return row.get_meta("field_id", "") == "routes" and row.get_meta("issue_highlight", false)),
			"the issue drawer opens the owning step and marks the outer branch field")
		issue_steps._teardown_steps_host()
	var campaign_source := Store.read(manifest, "campaign", "project-acceptance")
	var campaign_copy := await _copy_library_draft(app, editor._library, "campaign", "project-acceptance")
	collect(campaign_copy, "LineEdit")[1].text = "campaign-copy"
	press(campaign_copy, "保存")
	await process_frame
	var copied_campaign := Store.read(manifest, "campaign", "project-campaign-copy")
	check(copied_campaign.get("id") == "project-campaign-copy" and copied_campaign.get("steps") == campaign_source.steps
		and copied_campaign.get("fields") == campaign_source.fields
		and Store.read(manifest, "campaign", "project-acceptance") == campaign_source,
		"duplicating an independent campaign preserves its nested branches and steps without changing the source")
	campaign_copy.hide()
	var segment_panel = editor._steps
	check(segment_panel.open_content("campaign", "project-acceptance"), "open the source performance")
	press(segment_panel._steps_pop, "列表")
	press(segment_panel._steps_pop, "复制段落…")
	var range_dialog: ConfirmationDialog = collect(segment_panel._steps_pop, "ConfirmationDialog").back()
	var bounds := collect(range_dialog, "SpinBox")
	bounds[0].get_line_edit().text = "2"
	bounds[1].get_line_edit().text = "3"
	range_dialog.confirmed.emit()
	segment_panel._teardown_steps_host()
	check(segment_panel.open_content("campaign", "project-campaign-copy"), "open another performance using the same declaration")
	press(segment_panel._steps_pop, "列表")
	press(segment_panel._steps_pop, "粘贴段落…")
	var paste_dialog: ConfirmationDialog = collect(segment_panel._steps_pop, "ConfirmationDialog").back()
	collect(paste_dialog, "LineEdit")[0].text = "12"
	paste_dialog.confirmed.emit()
	segment_panel._teardown_steps_host()
	await process_frame
	var extended := Store.read(manifest, "campaign", "project-campaign-copy")
	var segment: Array = extended.get("steps", []).slice(3)
	check(segment.size() == 2 and segment[0].get("at") == 12.0 and segment[1].get("at") == 13.0
		and segment[1].get("fields") == campaign_source.steps[2].fields
		and extended.steps.slice(0, 3) == campaign_source.steps
		and Store.read(manifest, "campaign", "project-acceptance") == campaign_source,
		"the saved segment preserves beat offsets and nested branches without altering either original")

func _frame_contour_points(cvs: EditorCanvas, code: String) -> Array:
	return _frame_contour_props(cvs, code).get("points", [])

func _frame_contour_props(cvs: EditorCanvas, code: String) -> Dictionary:
	for row in cvs.extract().objects:
		if row.get("code") == code:
			return row.props
	return {}

func _drag_pick_frame(pop: PopupPanel, a: Vector2, b: Vector2) -> Button:
	var frame: TextureRect = pop.find_child("MapGamePreviewFrame", true, false)
	var extent := Vector2(frame.texture.get_size())
	var fitted := extent * minf(frame.size.x / extent.x, frame.size.y / extent.y)
	var origin := (frame.size - fitted) * 0.5
	var confirm := _click_pick_frame(pop, a)
	var drag := InputEventMouseMotion.new()
	drag.button_mask = MOUSE_BUTTON_MASK_LEFT
	drag.position = origin + fitted * b
	frame.gui_input.emit(drag)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.position = drag.position
	frame.gui_input.emit(release)
	return confirm

func author_signal_room(app, project: String) -> void:
	DirAccess.make_dir_recursive_absolute(project.path_join("editor"))
	for filename in ["project.godot", "main.tscn", "game.gd"]:
		check(DirAccess.copy_absolute(ProjectSettings.globalize_path("res://tests/screen_game/" + filename),
			project.path_join(filename)) == OK, "install the separate screen game " + filename)
	var launch := ["--path", "%projectpath%", "--audio-driver", "Dummy", "--"]
	var manifest := {"_dir": project, "_maps_dir": project.path_join("maps"), "projectName": "Signal Room",
		"viewports": [{"id": "handheld", "w": 480, "h": 720}],
		"screenModules": {"signal-latch": {"name": "Signal latch", "fields": [
			{"id": "presses", "name": "Confirmations", "kind": "input", "type": "int", "min": 1, "max": 4, "default": 3}]}},
		"assets": [
			{"id": "relay", "kind": "entity", "code": "RLY1", "fields": [
				{"id": "route_layer", "kind": "choice", "source": "layer:"},
				{"id": "route", "kind": "input", "type": "array", "of": "vector2",
					"pickSpace": "layer", "layerField": "route_layer"}]},
			{"id": "relay-exit", "kind": "entity", "code": "RXIT"}],
		"functions": {"signal": {"code": "SIGN", "name": "Signal", "fields": [
			{"id": "screen", "code": "PANE", "kind": "choice", "source": "view:"},
			{"id": "text", "code": "TEXT", "kind": "input", "type": "string"}]}},
		"preview": {"version": 1, "executable": OS.get_executable_path(), "args": launch,
			"capabilities": ["screenLayout", "mapFrame"]},
		"playtest": {"executable": OS.get_executable_path(), "args": launch + ["--verify", "--map=%mapfile%"],
			"report": true, "projectEntry": true, "entryFunctions": ["signal"]}}
	var path := project.path_join("editor/editor_manifest.json")
	check(Maps.write_json(path, manifest), "write only the second game's module and viewport declarations")
	var import_log := PackedStringArray()
	if OS.execute(OS.get_executable_path(), ["--headless", "--path", project, "--editor", "--import"], import_log, true) != 0:
		check(false, "import the screen game: " + "\n".join(import_log))
		return
	manifest["_manifest_digest"] = Store.file_digest(path)
	app._clear_project_session()
	app.manifest = manifest
	app._build_editor_ui()
	app._set_mode("content")
	var library = app.project_shell.content_editor._library
	await _author_signal_content(app, library, "clear", "Signal verified")
	await _author_signal_screen(app, "relay-tuning", "Confirm the signal", "project-clear")
	await _author_signal_content(app, library, "tune", "", "relay-tuning")
	await _author_signal_screen(app, "watch-deck", "Tune the relay", "project-clear", path)
	await _author_signal_content(app, library, "watch", "")
	var write_ok := true
	for i in range(260):
		var id := "project-extra-%03d" % i
		write_ok = Store.write(manifest, "signal", id, {
			"scope": "project", "function": manifest.functions.signal.code, "name": "Extra %03d" % i, "fields": {},
		}) and write_ok
	check(write_ok, "write 260 unrelated content nodes for the flow workshop")
	library.open()
	press(_visible_popup(app), "流程关系…")
	await process_frame
	var flow := _visible_popup(app)
	var source: OptionButton = flow.find_child("FlowSource", true, false)
	var target: OptionButton = flow.find_child("FlowTarget", true, false)
	var local: CheckButton = flow.find_child("FlowDirectOnly", true, false)
	var canvas = flow.find_child("FlowCanvas", true, false)
	check(local.button_pressed and canvas.data.nodes.size() <= 3,
		"large projects open on direct relations instead of drawing every node")
	var source_search: LineEdit = flow.find_child("FlowSourceSearch", true, false)
	source_search.text = "signal project-watch"
	source_search.text_changed.emit(source_search.text)
	source_search.text_submitted.emit(source_search.text)
	check(source.get_selected_metadata() == "signal\u0001project-watch" and source.item_count <= 2,
		"search by type and ID selects the intended content despite unrelated nodes")
	select_metadata(target, "watch-deck")
	press(flow, "应用关系")
	var links: ItemList = flow.find_child("FlowDirectLinks", true, false)
	check(links.item_count == 1 and canvas.data.nodes.size() == 2, "linking refreshes the focused view")
	links.item_activated.emit(0)
	check(source.get_selected_metadata() == "@view\u0001watch-deck" and links.item_count == 2,
		"follow an edge to the screen even when its name does not match the source filter")
	links.select(1)
	press(flow, "定位引用字段")
	check(source.get_selected_metadata() == "signal\u0001project-watch" and target.get_selected_metadata() == "watch-deck",
		"the inbound relation selects its original editable field")
	links.item_activated.emit(0)
	var target_search: LineEdit = flow.find_child("FlowTargetSearch", true, false)
	target_search.text = "project-tune"
	target_search.text_changed.emit(target_search.text)
	check(target.item_count == 3, "target search keeps the current link and the matching candidate")
	for i in target.item_count:
		var candidate = target.get_item_metadata(i)
		if candidate is Dictionary and candidate == {"function": "signal", "content": "project-tune"}:
			target.select(i)
			break
	press(flow, "应用关系")
	check(manifest.views[1].layout.elements[0].target.content == "project-tune",
		"the graph rebinds the screen button in the project manifest")
	press(flow, "编辑选中项")
	await process_frame
	var opened := _visible_popup(app)
	check(collect(opened, "LineEdit").front().text == "watch-deck", "the graph opens the selected screen")
	var before := Store.file_digest(path)
	press(opened, "删除视图…")
	check(collect(app, "ConfirmationDialog").filter(func(d): return d.visible).is_empty()
		and collect(opened, "Label").any(func(label): return label.text.contains("signal/project-watch.screen"))
		and Store.file_digest(path) == before, "incoming content prevents deleting the screen")
	press(opened, "复制视图…")
	collect(opened, "LineEdit").front().text = "watch-deck-copy"
	opened.find_child("ViewLayoutMode", true, false).button_pressed = true
	await process_frame
	press(opened, "复制元素")
	await process_frame
	var caption: LineEdit = opened.find_child("LayoutElement_text", true, false)
	caption.text = "A different button"
	caption.text_changed.emit(caption.text)
	press(opened, "保存参考视图")
	await process_frame
	check(manifest.views.size() == 3 and manifest.views[2].view_id == "watch-deck-copy",
		"the duplicate is independently saved under its new view ID")
	if manifest.views.size() == 3:
		var original: Array = manifest.views[1].layout.elements
		var copied: Array = manifest.views[2].layout.elements
		check(original.size() == 1 and copied.size() == 2 and original[0] == copied[0]
			and copied[1].id != copied[0].id and copied[1].text == "A different button"
			and copied[1].target == original[0].target,
			"the copied element has a fresh ID and retains the authored target")
	ReferenceViews.open(app, "watch-deck-copy")
	opened = _visible_popup(app)
	press(opened, "删除视图…")
	var confirmations := collect(app, "ConfirmationDialog").filter(func(d): return d.visible)
	check(confirmations.size() == 1, "confirm removal of the unused copy")
	if not confirmations.is_empty():
		confirmations[0].confirmed.emit()
		confirmations[0].hide()
		await process_frame
		await process_frame
	check(manifest.views.size() == 2 and manifest.views[1].view_id == "watch-deck",
		"only the unreferenced view is removed")
	check(not app.map_loaded and Store.read(manifest, "signal", "project-watch").get("fields", {}).get("PANE") == "watch-deck",
		"the start content stores a chosen screen without creating a map")
	var changed := manifest.duplicate(true)
	changed.views = manifest.get("views", []).filter(func(view): return view.view_id != "watch-deck")
	var broken_screen := Audit.audit(changed).filter(
		func(issue): return issue.path == "signal/project-watch.screen" and issue.message.contains("watch-deck"))
	check(broken_screen.size() == 1,
		"a missing referenced screen is reported against its content field")
	if broken_screen.size() == 1:
		await app._layout_ctrl._issues_ctrl._jump_to(broken_screen[0])
		var issue_form := _visible_popup(app)
		check(collect(issue_form, "LineEdit")[1].text == "project-watch" and collect(issue_form, "HBoxContainer").any(
			func(row): return row.get_meta("field_id", "") == "screen" and row.get_meta("issue_highlight", false)),
			"the issue drawer opens the shared content and marks the screen field without an active map")
		issue_form.hide()
	var watch_source := Store.read(manifest, "signal", "project-watch")
	var abandoned := await _copy_library_draft(app, library, "signal", "project-watch")
	collect(abandoned, "LineEdit")[1].text = "discarded-watch"
	abandoned.hide()
	await process_frame
	check(not Store.list_ids(manifest, "signal").has("project-discarded-watch"),
		"closing a duplicate draft does not write a content file")
	var watch_copy := await _copy_library_draft(app, library, "signal", "project-watch")
	var copy_inputs := collect(watch_copy, "LineEdit")
	copy_inputs[0].text = "Alternate entrance"
	copy_inputs[1].text = "alternate-watch"
	check(not Store.list_ids(manifest, "signal").has("project-alternate-watch"), "copy remains unpublished before saving")
	press(watch_copy, "保存")
	await process_frame
	var alternate := Store.read(manifest, "signal", "project-alternate-watch")
	check(alternate.get("name") == "Alternate entrance" and alternate.get("fields") == watch_source.fields
		and Store.read(manifest, "signal", "project-watch") == watch_source,
		"saving the duplicate creates an independent entry with the same screen link")
	watch_copy.hide()
	library.open()
	var pop: PopupPanel = _visible_popup(app)
	var entries: ItemList = collect(pop, "ItemList").front()
	for i in entries.item_count:
		if entries.get_item_metadata(i) == "project-alternate-watch":
			entries.select(i)
			entries.item_selected.emit(i)
			break
	press(pop, "试玩所选内容")
	var deadline := Time.get_ticks_msec() + 5000
	while app._map_file_ctrl._play_report_request.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	var report := await wait_for_playtest(app._map_file_ctrl)
	var result: Dictionary = report.get("result", {})
	check(report.get("status") == "ready" and report.get("mapDigest") == ""
		and result.get("visited") == ["project-alternate-watch", "project-tune", "project-clear"]
		and result.get("screens") == ["watch-deck", "relay-tuning"]
		and result.get("buttons") == ["Tune the relay", "Confirm the signal"]
		and result.get("latchInputs") == [2.0]
		and result.get("text") == "Signal verified",
		"the second game follows both authored buttons from the selected start content: " + str(report))
	await _author_relay_map(app, manifest)

func _author_relay_map(app, manifest: Dictionary) -> void:
	app._set_mode("map")
	app._on_new()
	var popup := _visible_popup(app)
	popup.find_child("NewMapName", true, false).text = "relay_deck"
	select_metadata(popup.find_child("NewMapProjection", true, false), "isometric")
	press(popup, "确定")
	for i in 12:
		await process_frame
		if app.cur_map_name == "relay_deck" and app.map_loaded:
			break
	if app.cur_map_name != "relay_deck" or not app.map_loaded:
		check(false, "create an isometric map in the second game")
		return
	var canvas: EditorCanvas = app.canvas
	await canvas.layer_set_param(0, "offset", Vector2(12, 4))
	await canvas.layer_set_param(0, "scale", 1.5)
	var layer := canvas.layer_id(0)
	var gate: EntityNode = canvas._tool_ops_ctrl.place_object("relay-exit", 0, Vector2(32, 48), true)
	var relay: EntityNode = canvas._tool_ops_ctrl.place_object("relay", 0, Vector2(0, 16), true)
	var gate_code := gate.code
	var relay_code := relay.code
	app._set_mode("content", relay_code)
	var editor = app.project_shell.content_editor
	select_metadata(editor.root.find_child("InstanceValue_route_layer", true, false), layer)
	await process_frame
	var picker: Button = editor.root.find_child("FrameFieldReference_route", true, false)
	if picker == null:
		check(false, "the second game exposes its authored layer-local relay route")
		return
	picker.pressed.emit()
	var frame := await _render_pick_frame(app, "isometric relay", "handheld")
	if frame == null:
		return
	var shot: TextureRect = frame.find_child("MapGamePreviewFrame", true, false)
	var image := shot.texture.get_image()
	check(image.get_pixel(420, 308).is_equal_approx(Color("#67e8bb")),
		"the second renderer's exit appears at the expected projected pixel")
	var confirm := _click_pick_frame(frame, Vector2(276, 164) / Vector2(480, 720))
	_click_pick_frame(frame, Vector2(348, 236) / Vector2(480, 720))
	_click_pick_frame(frame, Vector2(420, 308) / Vector2(480, 720))
	check(not confirm.disabled and not relay.props.has("route"), "relay points stay in the frame draft")
	confirm.pressed.emit()
	await process_frame
	await process_frame
	app._set_mode("map")
	var saved: Dictionary = await app._map_file_ctrl.commit_document("保存等距接力路线")
	if saved.get("status") != "ok":
		check(false, "save the second game's route: " + str(saved))
		return
	await app._load_map_file(Maps.path_for(manifest, "relay_deck"))
	var reopened: EntityNode = canvas._ent_by_code_index()[relay_code]
	check(canvas.extract().meta.gridProjection == "isometric" and reopened.props.get("route_layer") == layer
		and _route_matches(reopened.props.get("route", []), [Vector2(0, 16), Vector2(16, 32), Vector2(32, 48)]),
		"the saved second project retains its isometric projection, layer and three local waypoints")
	var report := await launch_and_read(app, false)
	var result: Dictionary = report.get("result", {})
	check(report.get("status") == "ready" and result.get("exit") == gate_code
		and _route_matches(result.get("route", []), [Vector2(12, 28), Vector2(36, 52), Vector2(60, 76)]),
		"the second game moves through all authored world waypoints and reaches the placed exit: " + str(report))

func _route_matches(rows: Array, expected: Array) -> bool:
	if rows.size() != expected.size():
		return false
	for i in rows.size():
		if Vector2(rows[i][0], rows[i][1]).distance_to(expected[i]) > 0.01:
			return false
	return true

func _visible_popup(app) -> PopupPanel:
	return collect(app, "PopupPanel").filter(func(p): return p.visible).back()

func _copy_library_draft(app, library, kind: String, cid: String) -> PopupPanel:
	library.open()
	var pop := _visible_popup(app)
	select_metadata(collect(pop, "OptionButton").front(), kind)
	var list: ItemList = collect(pop, "ItemList").front()
	for i in list.item_count:
		if list.get_item_metadata(i) == cid:
			list.select(i)
			list.item_selected.emit(i)
			break
	press(pop, "复制为草稿…")
	await process_frame
	return _visible_popup(app)

func _author_signal_content(app, library, id: String, message: String, view := "") -> void:
	library.open()
	press(_visible_popup(app), "新建…")
	await process_frame
	var pop := _visible_popup(app)
	var inputs := collect(pop, "LineEdit")
	inputs[0].text = id.capitalize()
	inputs[1].text = id
	inputs[2].text = message
	if view != "":
		select_metadata(collect(pop, "OptionButton").front(), view)
	press(pop, "保存")
	pop.hide()
	await process_frame

func _author_signal_screen(app, id: String, caption: String, content: String, manifest_path := "") -> void:
	ReferenceViews.open(app)
	var pop := _visible_popup(app)
	var list: OptionButton = collect(pop, "OptionButton").front()
	list.select(list.item_count - 1)
	list.item_selected.emit(list.selected)
	collect(pop, "LineEdit").front().text = id
	pop.find_child("ViewLayoutMode", true, false).button_pressed = true
	var design: OptionButton = pop.find_child("LayoutDesignViewport", true, false)
	design.select(1)
	design.item_selected.emit(1)
	await process_frame
	var preview: ReferenceViews.Preview
	for node in collect(pop, "Control"):
		if node is ReferenceViews.Preview:
			preview = node
			break
	var frame := preview.frame()
	var pointer := InputEventMouseButton.new()
	pointer.button_index = MOUSE_BUTTON_LEFT
	pointer.pressed = true
	pointer.position = frame.position + frame.size * Vector2(0.25, 0.65)
	preview._gui_input(pointer)
	pointer.pressed = false
	pointer.position = frame.position + frame.size * Vector2(0.75, 0.8)
	preview._gui_input(pointer)
	var field: LineEdit = pop.find_child("LayoutElement_text", true, false)
	if id == "watch-deck":
		var type: OptionButton = pop.find_child("LayoutElementKind", true, false)
		for i in type.item_count:
			if type.get_item_metadata(i).get("module") == "signal-latch":
				type.select(i)
				type.item_selected.emit(i)
				break
		var presses: SpinBox = pop.find_child("LayoutModuleField_presses", true, false)
		check(presses != null and presses.value == 3, "game module provides the field and its default")
		presses.value = 2
		var focusable: CheckBox = pop.find_child("LayoutElementFocusable", true, false)
		focusable.button_pressed = true
		field = pop.find_child("LayoutElement_text", true, false)
	field.text = caption
	field.text_changed.emit(caption)
	field = pop.find_child("LayoutElement_style", true, false)
	field.text = "signal/relay"
	field.text_changed.emit(field.text)
	var target: OptionButton = pop.find_child("LayoutElementTarget", true, false)
	for i in target.item_count:
		if target.get_item_metadata(i) == {"function": "signal", "content": content}:
			target.select(i)
			target.item_selected.emit(i)
			break
	if manifest_path != "":
		var before := Store.file_digest(manifest_path)
		var render: Button = pop.find_child("GameRenderPreview", true, false)
		render.pressed.emit()
		var deadline := Time.get_ticks_msec() + 13500
		while render.disabled and Time.get_ticks_msec() < deadline:
			await create_timer(0.08).timeout
		var picture: TextureRect = pop.find_child("GameRenderedFrame", true, false)
		check(picture.texture != null and picture.texture.get_size() == Vector2(480, 720)
			and picture.texture.get_image().get_pixel(130, 480).to_html(false) == "cc711e"
			and Store.file_digest(manifest_path) == before,
			"the second game renders its styling and the unsaved screen at the declared portrait size")
	press(pop, "保存参考视图")
	var deadline := Time.get_ticks_msec() + 5000
	while is_instance_valid(pop) and pop.visible and Time.get_ticks_msec() < deadline:
		await process_frame
	check(not is_instance_valid(pop) or not pop.visible, "save the authored signal screen " + id)
	if id == "watch-deck":
		var row: Dictionary = app.manifest.views.filter(func(view): return view.view_id == id)[0]
		check(row.layout.elements[0].get("module") == "signal-latch"
			and row.layout.elements[0].get("focusable") == true
			and row.layout.elements[0].get("props", {}).get("presses") == 2,
			"the layout stores the module identity and the authored override")
