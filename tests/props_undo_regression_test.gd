extends SceneTree

const CanvasScript := preload("res://src/canvas/editor_canvas.gd")
const PropsPanelScript := preload("res://src/ui/props_panel.gd")

class TestHost extends Control:
	var manifest := {
		"tileSize": 16,
		"layers": [],
		"tiles": [],
		"entities": [{
			"id": "test_entity",
			"name": "Test Entity",
			"fields": [{"id": "label", "name": "Label", "type": "string"}],
			"stats": [{"id": "hp", "name": "HP", "default": 1, "min": 1, "max": 9, "type": "int"}],
		}]
	}
	var canvas
	var props_panel := VBoxContainer.new()
	var props_scroll: ScrollContainer
	var selected_spr: Sprite2D
	var _props_panel_ctrl
	const POPUP_BODY_W := 340
	func _set_status(_message: String) -> void: pass
	func _set_badge(_panel: PanelContainer, _text: String, _color: Color) -> void: pass
	func _open_asset_editor(_sid: String) -> void: pass
	func _rebuild_props_panel() -> void: _props_panel_ctrl.rebuild()

var failures: Array[String] = []
var host: TestHost

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	host = TestHost.new()
	root.add_child(host)
	host.canvas = CanvasScript.new()
	host.add_child(host.canvas)
	host.canvas.manifest = host.manifest
	host.canvas.set_thumbs({})
	host.add_child(host.props_panel)
	host._props_panel_ctrl = PropsPanelScript.new(host)
	host.canvas.entity_selected.connect(func(spr: Sprite2D): host.selected_spr = spr)
	var data := {
		"meta": {"name": "undo", "w": 8, "h": 6}, "spawn": [1, 1],
		"terrain": [], "decor": [], "collision": [],
		"entities": [{"scene": "test_entity", "id": "e_1", "x": 2, "y": 2,
			"props": {"label": "start"}}],
	}
	await host.canvas.load_data(data, "undo")
	host.selected_spr = host.canvas.entities.get_child(0) as Sprite2D

	host._props_panel_ctrl.rebuild()
	await process_frame

	var label := _find_line_edit(host.props_panel)
	_check(label != null, "production property panel creates the string field")
	if label != null:
		label.grab_focus()
		for value in ["s", "sta", "staged"]:
			label.text = value
			label.emit_signal("text_changed", value)
		_check(str(_current_entity().get_meta("props", {}).get("label", "")) == "staged",
			"typing updates the selected entity property")
		_check(host.canvas.undo(), "one undo is available after a string edit session")
		await process_frame
		_check(str(_current_entity().get_meta("props", {}).get("label", "")) == "start",
			"one undo restores the value from before typing began")
		_check(host.canvas.undo_stack.is_empty(), "multiple typed characters form one undo step")

	host.selected_spr = _current_entity()
	host._props_panel_ctrl.rebuild()
	await process_frame
	var hp_spin := _find_spin_box(host.props_panel)
	_check(hp_spin != null, "production property panel creates the stat override field")
	if hp_spin != null:
		hp_spin.value = 4
		_check(float(_current_entity().get_meta("props", {}).get("stats", {}).get("hp", 0.0)) == 4.0,
			"changing a stat creates an instance override")
		_check(host.canvas.undo(), "one undo is available after changing a stat")
		await process_frame
		_check(not (_current_entity().get_meta("props", {}).get("stats", {}) as Dictionary).has("hp"),
			"undo removes the stat override and restores inheritance")

	if is_instance_valid(host):
		host.queue_free()
	await process_frame
	if failures.is_empty():
		print("PROPS_UNDO_REGRESSION_OK")
		quit(0)
	else:
		for failure in failures:
			printerr("PROPS_UNDO_REGRESSION_FAIL: ", failure)
		quit(1)

func _current_entity() -> Sprite2D:
	for node in host.canvas.entities.get_children():
		if str(node.get_meta("ent_id", "")) == "e_1":
			return node as Sprite2D
	return null

func _find_line_edit(node: Node) -> LineEdit:
	if node is LineEdit:
		return node as LineEdit
	for child in node.get_children():
		var found := _find_line_edit(child)
		if found != null:
			return found
	return null

func _find_spin_box(node: Node) -> SpinBox:
	if node is SpinBox:
		return node as SpinBox
	for child in node.get_children():
		var found := _find_spin_box(child)
		if found != null:
			return found
	return null

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		printerr("PROPS_UNDO_REGRESSION_FAIL: ", message)
