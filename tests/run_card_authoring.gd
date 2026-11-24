extends SceneTree
## Runs only the mapless card encounter, from editor controls through an independent game process.

const Manifest := preload("res://src/project/manifest.gd")
const Maps := preload("res://src/map/map_store.gd")
const Store := preload("res://src/content/content_store.gd")
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
		"functions": {
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
	var encounter := await new_content("encounter", "harbor")
	field(encounter, "target").value = 7
	var deck: Control = field(encounter, "deck")
	press(deck, "+ 添加")
	press(deck, "+ 添加")
	var options := collect(deck, "OptionButton")
	choose(options[0], "project-courier")
	choose(options[1], "project-sentry")
	var counts := collect(deck, "SpinBox")
	counts[0].value = 2
	counts[1].value = 3
	choose(field(encounter, "pass"), "project-market-open")
	choose(field(encounter, "fail"), "project-stand-down")
	save(encounter)
	var saved := Store.read(manifest, "encounter", "project-harbor")
	if not check(saved.get("fields", {}).get("DECK", []) == [
			{"CRDF": "project-courier", "COPY": 2.0}, {"CRDF": "project-sentry", "COPY": 3.0}], "deck records preserve authored order"):
		finish()
		return
	app._clear_project_session()
	app.manifest = Manifest.load_from(project)
	app._build_editor_ui()
	app._set_mode("content")
	var library := open_library("encounter")
	var list: ItemList = collect(library, "ItemList")[0]
	list.select(0)
	list.item_selected.emit(0)
	press(library, "试玩所选内容")
	var controller = app._playtest_ctrl
	var end := Time.get_ticks_msec() + 12000
	while controller._play_report_result.is_empty() and Time.get_ticks_msec() < end:
		await create_timer(0.05).timeout
		controller.poll_playtest()
	var report: Dictionary = controller._play_report_result
	check(report.get("status") == "ready", "independent game returned a matching receipt: %s" % [report])
	check(report.get("result", {}).get("settlements", []) == [
		{"card": "project-courier", "score": 8.0, "outlet": "PASS", "target": "project-market-open", "text": "Market open"},
		{"card": "project-sentry", "score": 6.0, "outlet": "FAIL", "target": "project-stand-down", "text": "Stand down"}],
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
