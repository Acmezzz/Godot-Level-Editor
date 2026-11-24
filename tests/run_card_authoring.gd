extends SceneTree
## Runs only the mapless card encounter, from editor controls through an independent game process.

const Manifest := preload("res://src/project/manifest.gd")
const Maps := preload("res://src/map/map_store.gd")
const Store := preload("res://src/content/content_store.gd")
const Flow := preload("res://src/content/rel_graph.gd")
const Editor := preload("res://src/editor.tscn")
var app
var failures := 0

func _initialize() -> void:
	create_timer(25.0).timeout.connect(func():
		check(false, "authoring timed out")
		quit(1))
	run.call_deferred()

func run() -> void:
	var project := ProjectSettings.globalize_path("user://card-authoring-%s" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(project.path_join("editor"))
	for file in ["project.godot", "game.gd"]:
		var from := ProjectSettings.globalize_path("res://tests/card_game/" + file)
		check(DirAccess.copy_absolute(from, project.path_join(file)) == OK, "install game-side " + file)
	var declarations := {
		"projectName": "Market Hand",
		"startup": {"contentTypes": ["encounter"]},
		"projectContentSlots": {"scoring": {"name": "Scoring", "contentTypes": ["score_rules"]}},
		"functions": {
			"score_rules": {"name": "Score rules", "code": "SCRL", "fields": [
				{"id": "multiplier", "code": "MULT", "kind": "input", "type": "int", "min": 1}]},
			"card": {"name": "Card", "code": "CARD", "fields": [
				{"id": "caption", "code": "CAPT", "kind": "input", "type": "string"},
				{"id": "power", "code": "POWR", "kind": "input", "type": "int", "min": 0}]},
			"settlement": {"name": "Settlement", "code": "STLM", "fields": [
				{"id": "text", "code": "TEXT", "kind": "input", "type": "string"}]},
			"encounter": {"name": "Encounter", "code": "ENCT", "fields": [
				{"id": "target", "code": "TARG", "kind": "input", "type": "int", "min": 1},
				{"id": "deck", "code": "DECK", "kind": "input", "type": "array", "of": "record", "fields": [
					{"id": "card", "code": "CRDF", "kind": "choice", "source": "content:card"},
					{"id": "copies", "code": "COPY", "kind": "input", "type": "int", "min": 1}]},
				{"id": "deal_order", "code": "ORDR", "kind": "input", "type": "array", "of": "choice", "source": "content:card"},
				{"id": "pass", "code": "PASS", "kind": "choice", "source": "content:settlement"},
				{"id": "fail", "code": "FAIL", "kind": "choice", "source": "content:settlement"}]}},
		"playtest": {"executable": OS.get_executable_path(), "report": true, "projectEntry": true,
			"entryFunctions": ["encounter"], "args": ["--headless", "--path", "%projectpath%", "--script", "res://game.gd", "--", "--verify"]}}
	check(Maps.write_json(project.path_join("editor/editor_manifest.json"), declarations), "install declarations only")
	var manifest := Manifest.load_from(project)
	if not check(not manifest.has("_error"), str(manifest.get("_error", "load game declarations"))):
		finish()
		return
	app = Editor.instantiate()
	root.add_child(app)
	app._clear_project_session()
	app.manifest = manifest
	app._build_editor_ui()
	app._set_mode("content")
	for card in [["courier", "Courier", 4], ["sentry", "Sentry", 2]]:
		var pop := await new_content("card", card[0])
		field(pop, "caption").text = card[1]
		field(pop, "power").value = card[2]
		save(pop)
	for result in [["market-open", "Market open"], ["stand-down", "Stand down"]]:
		var pop := await new_content("settlement", result[0])
		field(pop, "text").text = result[1]
		save(pop)
	var scoring := await new_content("score_rules", "double")
	field(scoring, "multiplier").value = 2
	save(scoring)
	var rule_target := {"function": "score_rules", "content": "project-double"}
	var global_rules := await open_project_flow_slots()
	var project_slots: OptionButton = global_rules.find_child("FlowSlot", true, false)
	project_slots.select(1)
	project_slots.item_selected.emit(1)
	var scorer: OptionButton = global_rules.find_child("FlowTarget", true, false)
	check(scorer.item_count == 2, "the scoring slot offers only compatible published contents")
	choose(scorer, rule_target)
	press(global_rules, "应用关系")
	check(app.manifest.projectContentSlots.scoring.get("target") == rule_target, "project rule was published from the graph")
	global_rules.hide()
	var encounter := await new_content("encounter", "harbor")
	field(encounter, "target").value = 14
	var deck: Control = field(encounter, "deck")
	press(deck, "+ 添加")
	press(deck, "+ 添加")
	var options := collect(deck, "OptionButton")
	choose(options[0], "project-courier")
	choose(options[1], "project-sentry")
	var counts := collect(deck, "SpinBox")
	counts[0].value = 2
	counts[1].value = 3
	var order := field(encounter, "deal_order")
	press(order, "+ 添加")
	press(order, "+ 添加")
	var dealt := collect(order, "OptionButton")
	choose(dealt[0], "project-sentry")
	choose(dealt[1], "project-courier")
	press(dealt[1].get_parent(), "↑")
	choose(field(encounter, "pass"), "project-market-open")
	choose(field(encounter, "fail"), "project-stand-down")
	save(encounter)
	var saved := Store.read(manifest, "encounter", "project-harbor")
	if not check(saved.get("fields", {}).get("DECK", []) == [
			{"CRDF": "project-courier", "COPY": 2.0}, {"CRDF": "project-sentry", "COPY": 3.0}], "deck records preserve authored order"):
		finish()
		return
	check(saved.fields.ORDR == ["project-courier", "project-sentry"], "form reorders the deal list")
	var graph := Flow.build_project(manifest)
	var slots: Array = graph.slots["encounter\u0001project-harbor"].filter(func(slot): return slot.field == "ORDR")
	check(slots.map(func(slot): return slot.index) == [0, 1, -1], "flow graph exposes ordered reference slots")
	var tail: Dictionary = slots.back()
	var result := Flow.set_edge(func(kind, id): return Store.read(manifest, kind, id),
		func(kind, id, data): return Store.write_ex(manifest, kind, id, data, "").ok,
		tail.fn_id, tail.cid, tail.step, tail.field, "project-courier", tail.multi, tail.value, tail)
	check(result.status == "ok", "flow graph may append a repeated card")
	var startup := await open_project_flow_slots()
	var option: OptionButton = startup.find_child("FlowTarget", true, false)
	check(option.item_count == 2, "only declared startup content types are offered")
	var entrance := {"function": "encounter", "content": "project-harbor"}
	choose(option, entrance)
	press(startup, "应用关系")
	check(app.manifest.startup.get("target") == entrance, "author published the startup choice from the graph")
	startup.hide()
	app._clear_project_session()
	app.manifest = Manifest.load_from(project)
	app._build_editor_ui()
	app._set_mode("content")
	check(app.manifest.startup.target == {"function": "encounter", "content": "project-harbor"},
		"the published startup choice survives reloading")
	var form = app.project_shell.content_editor._form
	check(form._delete_blocked_reason("encounter", "project-harbor").contains("正式启动入口"),
		"deletion identifies the active startup target")
	check(app.manifest.projectContentSlots.scoring.target == rule_target
		and form._delete_blocked_reason("score_rules", "project-double").contains("项目规则"),
		"the published project rule survives reloading and protects its referenced content")
	press(app.project_shell, "试玩项目")
	var controller = app._playtest_ctrl
	var end := Time.get_ticks_msec() + 12000
	while controller._play_report_result.is_empty() and Time.get_ticks_msec() < end:
		await create_timer(0.05).timeout
		controller.poll_playtest()
	var report: Dictionary = controller._play_report_result
	check(report.get("status") == "ready", "independent game returned a matching receipt: %s" % [report])
	check(report.get("result", {}).get("entrySource") == "manifest",
		"ordinary startup loaded the authored target without a command-line content override")
	check(report.get("result", {}).get("scoring") == rule_target, "the game reads the authored project scoring reference")
	check(report.get("result", {}).get("dealt") == ["project-courier", "project-sentry", "project-courier"],
		"the game deals in the same order and retains the repeated card")
	check(report.get("result", {}).get("settlements", []) == [
		{"card": "project-courier", "score": 16.0, "outlet": "PASS", "target": "project-market-open", "text": "Market open"},
		{"card": "project-sentry", "score": 12.0, "outlet": "FAIL", "target": "project-stand-down", "text": "Stand down"}],
		"both playable cards reach their authored settlement")
	finish()

func new_content(kind: String, slug: String) -> PopupPanel:
	press(open_library(kind), "新建…")
	await process_frame
	var pop := visible_popup()
	var ids := collect(pop, "LineEdit")
	ids[0].text = slug.capitalize()
	ids[1].text = slug
	return pop

func save(pop: PopupPanel) -> void:
	press(pop, "保存")
	check(collect(pop, "LineEdit")[1].text.begins_with("project-"), "item was saved by the editor")
	pop.hide()

func open_library(kind: String) -> PopupPanel:
	app.project_shell.content_editor._library.open()
	var pop := visible_popup()
	choose(collect(pop, "OptionButton")[0], kind)
	return pop

func open_project_flow_slots() -> PopupPanel:
	press(open_library("encounter"), "流程关系…")
	await process_frame
	var pop := visible_popup()
	choose(pop.find_child("FlowSource", true, false), "@project\u0001root")
	return pop

func choose(control: OptionButton, id: Variant) -> void:
	for index in control.item_count:
		var value = control.get_item_metadata(index)
		if typeof(value) == typeof(id) and value == id:
			control.select(index)
			control.item_selected.emit(index)
			return
	check(false, "missing choice " + str(id))

func press(node: Node, text: String) -> void:
	for button in collect(node, "Button"):
		if button.text == text:
			button.pressed.emit()
			return
	check(false, "missing button " + text)

func field(node: Node, id: String) -> Control:
	for row in collect(node, "HBoxContainer"):
		if row.get_meta("field_id", "") == id:
			return row.get_child(1)
	check(false, "missing field " + id)
	return null

func visible_popup() -> PopupPanel:
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
		printerr("CARD-FAIL: ", message)
		failures += 1
	return condition

func finish() -> void:
	print("CARD-DONE failures=", failures)
	quit(0 if failures == 0 else 1)
