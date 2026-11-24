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
	create_timer(30.0).timeout.connect(func():
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
	var controller = app._map_file_ctrl
	await controller.on_play(Vector2i(-1, -1), project_entry)
	if int(controller._play_pid) <= 0:
		return {}
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

func create_ending(app, library, id: String, message: String, map_context := "", goal := "", next := "") -> void:
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
		for opt in collect(pop, "OptionButton"):
			if goal != "" and range(opt.item_count).any(func(i): return opt.get_item_metadata(i) == goal):
				select_metadata(opt, goal)
			if next != "" and range(opt.item_count).any(func(i): return opt.get_item_metadata(i) == next):
				select_metadata(opt, next)
	press(pop, "保存")
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
	check(DirAccess.copy_absolute(ProjectSettings.globalize_path("res://src/canvas/grid_space.gd"),
		project.path_join("grid_space.gd")) == OK, "install the standalone grid contract in the independent game")
	check(write_fixture_audio(project), "write rhythm audio fixture")
	var button_art := Image.create(96, 32, false, Image.FORMAT_RGB8)
	button_art.fill(Color("#264dab"))
	check(button_art.save_png(project.path_join("button.png")) == OK, "write reusable button artwork")
	var tile_art := Image.create(16, 16, false, Image.FORMAT_RGB8)
	tile_art.fill(Color("#4e8764"))
	check(tile_art.save_png(project.path_join("terrain.png")) == OK, "write terrain atlas")
	var manifest := {"_dir": project, "_maps_dir": project.path_join("maps"), "projectName": "Workflow",
		"cellGraphEdgeTypes": {"stairs": {"name": "Stairs", "fields": [
			{"id": "cost", "kind": "input", "type": "int", "min": 1, "default": 9}]}},
		"functions": {"reaction": {"name":"Reaction", "code":"REAC", "repeatable":true,
			"triggers":["touch", "leave"], "fields":[{"id":"message","code":"RMES","kind":"input","type":"string"}]},
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
				{"id":"next", "code":"HOP1", "kind":"choice", "source":"content:ending",
					"contentMapContext":"inherit"}]}},
		"triggers": {"touch":{"name":"Touch","code":"TUCH"},"leave":{"name":"Leave","code":"LEAV"}},
		"conditions": {"hit_window":{"name":"Hit Window","fields":[
			{"id":"milliseconds","code":"WIND","kind":"input","type":"int","min":1}]},
			"on_lane":{"name":"On Lane","fields":[
			{"id":"lane","code":"LANE","kind":"input","type":"int","min":1}]}},
		"audio": {"rhythm": {"name":"Rhythm", "code":"AUD1", "path":"rhythm.wav"}},
		"steps": {"tempo": {"name":"Tempo","code":"TMPO","fields":[
			{"id":"bpm","code":"BPM1","kind":"input","type":"int","min":1}]},
			"advance": {"name": "Advance", "code": "NEXT", "fields": [
			{"id":"routes", "code":"BRCH", "name":"Branches", "kind":"input","type":"array","of":"record","fields":[
				{"id":"match", "code":"MODE", "kind":"choice", "options":["all","any"]},
				{"id":"predicates", "code":"PRED", "kind":"input","type":"array","of":"condition",
					"allowedConditions":["hit_window","on_lane"]},
				{"id":"destination_map", "code":"DMAP", "name":"Branch map", "kind":"choice", "source":"map"},
				{"id":"destination", "code":"DEST", "name":"Branch target", "kind":"choice", "source":"content:ending",
					"contentMapContext":"paired", "mapField":"destination_map"}
			]}]}}, "assets":[
			{"id": "switch", "kind": "entity", "code": "SWCH", "functions":["reaction"], "fields": [{"id":"target","type":"port_ref","of":"door"}]},
			{"id": "button-art", "kind": "scene", "shape": "image", "texture": "button.png"},
			{"id": "terrain", "kind": "scene", "shape": "tile", "atlas": "terrain.png", "cell": 16},
			{"id": "free-ramp", "kind": "entity", "code": "RAMP", "visual": {"type": "poly"}},
			{"id": "door", "kind": "entity", "code": "DOOR", "ports": [{"id":"open","type":"door","x": 5,"y": 4}],
				"fields": [{"id":"label", "type":"string"}]}],
		"playtest": {"executable": OS.get_executable_path(), "report": true, "projectEntry": true,
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
	flow_map.objects = [{"asset": "door", "code": "EXIT", "x": 4, "y": 2, "layer": flow_map.meta.layers[0].id}]
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
	var saved := Store.read(manifest, "campaign", "project-acceptance")
	check(saved.get("scope") == "project" and saved.get("steps", []).size() == 3
		and saved.steps[2].get("at", -1) == 3.0, "standalone beat-aligned step persisted")
	var routes: Array = saved.steps[2].get("fields", {}).get("BRCH", [])
	check(routes.size() == 2 and routes[0].PRED.size() == 2 and routes[0].PRED[0].fields.WIND == 110
		and routes[0].PRED[1].fields.LANE == 2 and routes[1].PRED[0].negate
		and routes[0].get("DMAP") == flow_map.meta.code and routes[1].get("DMAP") == flow_map.meta.code,
		"author assembled two groups with independent typed parameters and a negated predicate")
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
	var arrival := Store.read(manifest, "ending", "project-arrive")
	check(arrival.get("fields", {}).get("GOAL") == "EXIT" and not arrival.has("map")
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
	check(entry_report.get("status") == "ready" and entry_report.get("result", {}).get("step") == 1
		and entry_report.get("result", {}).get("caption") == "Ready"
		and entry_report.get("result", {}).get("ending") == "Reached the ending"
		and entry_report.get("result", {}).get("missEnding") == "Try again"
		and is_equal_approx(float(entry_report.get("result", {}).get("cueSec", -1.0)), 2.237)
		and entry_report.get("result", {}).get("hotspot") == "project-finish",
		"separate game process follows editor-wired campaign to ending: " + str(entry_report))
	check(entry_report.get("result", {}).get("screenTargets") == ["project-finish", "project-finish"],
		"independent runtime hits the authored bottom-anchored button in two viewport sizes")
	check(entry_report.get("result", {}).get("flowGoal") == {"map": flow_map.meta.code, "inst": "EXIT"},
		"the independent game enters the branch map, inherits it on the next hop and resolves the authored instance")
	check(entry_report.get("result", {}).get("screenFocus") == {"start": menu_id, "next": continue_id, "content": "project-finish",
		"localized": "Continuer", "fallback": "Continue"},
		"independent game resolves the author-defined directional route and consumes its target")
	var screen_art: Dictionary = entry_report.get("result", {}).get("screenArtwork", {})
	check(screen_art.get("fit") == "cover" and screen_art.get("size") == [96.0, 32.0]
		and screen_art.get("pixel") == "264dab",
		"independent game resolves and decodes the image chosen by the author: " + str(screen_art))
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
	var markers: Array = app.canvas.port_markers()
	check(markers.size() == 1, "only the declared matching port is available")
	if not markers.is_empty():
		app.canvas.pick_mode_code = app.canvas.pick_candidate_at(markers[0].pos)
		app._end_canvas_pick(true)
	await process_frame
	author_reactions(ce)
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
	canvas._tool_ops_ctrl._stamp(canvas.grid.cell_center_px(Vector2i(4, 2)))
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
	app.canvas._tool_ops_ctrl._stamp(app.canvas.grid.cell_center_px(Vector2i(1, 1)))
	app.canvas.selected_entity.props["label"] = "extra"
	app.canvas._mark()
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
			and row.removedObject and row.seedObject and row.addedObject and row.tilePatched),
		"across seeds the independent game retains seed objects and props while applying placed object edits: " + str(object_report))
	await author_resize(app, manifest)
	await author_projection_copy(app, manifest)
	await author_rule_grids(app, manifest)
	await author_basis_copy(app, manifest)
	await author_multilevel_grid(app, manifest)
	await author_tile_layer_conversion(app, manifest)
	await author_world_region_move(app, manifest)
	print("WORKFLOW-DONE failures=", failures)
	quit(1 if failures else 0)

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
	baseline.objects[0].x = 0
	baseline.objects[0].y = 0
	await cvs.load_data(baseline, "rule_hex", true)
	var initial: Dictionary = cvs.extract()
	var lower_px: Vector2 = cvs.grid.cell_center_px(Vector2i.ZERO)
	var step: Vector2 = cvs.grid.cell_center_px(Vector2i.RIGHT) - lower_px
	var upper_px: Vector2 = cvs.to_layer_world(1, cvs.tile_grid_for_layer(1).cell_center_px(Vector2i.ZERO))
	var n: EntityNode = cvs.ents_all()[0]
	var entity_px: Vector2 = n.get_parent().to_global(n.position - n.sort_anchor())
	var min_corner := lower_px.min(upper_px).min(entity_px) - Vector2(2, 2)
	var max_corner := lower_px.max(upper_px).max(entity_px) + Vector2(2, 2)
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
	input._on_left_press(lower_px, mouse)
	cvs._move_region_preview(lower_px + step)
	var plan: Dictionary = cvs._move_snap.get("plan", {})
	check(plan.get("positions", []).size() == 3, "cross-layer preview plans two tile grids and root collision")
	input._on_left_release(lower_px + step)
	var moved: Dictionary = cvs.extract()
	var dest_upper: Vector2i = cvs.tile_grid_for_layer(1).pick_cell(cvs.to_layer_local(1, upper_px + step))
	var upper_row: Array = moved.tiles[upper][0]
	check(moved.tiles[ground].any(func(row): return row[0] == 1 and row[1] == 0)
		and Vector2i(upper_row[0], upper_row[1]) == dest_upper and dest_upper != Vector2i.ZERO
		and moved.collision[0].x == 1 and moved.collision[0].material == "ice"
		and moved.objects[0].code == initial.objects[0].code
		and (n.get_parent().to_global(n.position - n.sort_anchor()) - entity_px).is_equal_approx(step)
		and moved.meta.cellGraph == initial.meta.cellGraph and moved.spawn == initial.spawn,
		"move both tile grids and collision with their own cells and translate the same instance in pixels")
	var undo_ok: bool = await cvs.undo()
	_check_world_move_restore(undo_ok, cvs.extract(), initial, "undo")
	var redo_ok: bool = await cvs.redo()
	_check_world_move_restore(redo_ok, cvs.extract(), moved, "redo")
	press(app, "跨层搬动")
	var saved: Dictionary = await app._map_file_ctrl.commit_document("保存跨层搬动")
	check(saved.get("status") == "ok", "save the cross-layer move")
	await app._load_map_file(path)
	_check_world_move_restore(true, cvs.extract(), moved, "save and reopen")

func _check_world_move_restore(ok: bool, actual: Dictionary, expected: Dictionary, op: String) -> void:
	var diffs := []
	for key in expected:
		var a := JSON.stringify(actual.get(key))
		var b := JSON.stringify(expected[key])
		if a != b:
			diffs.append("%s: %s vs %s" % [key, a, b])
	check(ok and actual.size() == expected.size() and diffs.is_empty(),
		"one %s restores the entire cross-layer move: %s" % [op, "; ".join(diffs)])