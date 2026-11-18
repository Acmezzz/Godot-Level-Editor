extends SceneTree

const CanvasScript := preload("res://src/canvas/editor_canvas.gd")

var failures: Array[String] = []
var canvas

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	canvas = CanvasScript.new()
	root.add_child(canvas)
	canvas.manifest = {
		"tileSize": 16,
		"layers": [],
		"tiles": [],
		"entities": [
			{"id": "portal", "fields": [
				{"id": "target_point", "type": "entity_ref"},
				{"id": "external_link", "type": "entity_ref"},
			]},
			{"id": "spawn_point", "fields": []},
		],
	}
	canvas.set_thumbs({})
	var data := {
		"meta": {"name": "copy", "w": 12, "h": 8}, "spawn": [1, 1],
		"terrain": [], "decor": [], "collision": [],
		"entities": [
			{"scene": "portal", "id": "e_1", "x": 2, "y": 2, "flip_h": true,
				"props": {"target_point": "e_2", "external_link": "e_3"}},
			{"scene": "portal", "id": "e_2", "x": 4, "y": 2, "flip_h": false,
				"props": {"target_point": "e_1"}},
			{"scene": "spawn_point", "id": "e_3", "x": 8, "y": 2, "props": {}},
		],
	}
	await canvas.load_data(data, "copy")
	var first: Sprite2D = _entity("e_1")
	var second: Sprite2D = _entity("e_2")
	canvas.selected_multi = [first, second]
	canvas.copy_selection()
	canvas.paste_at(Vector2(160, 160))

	var pasted := _entities_except(["e_1", "e_2", "e_3"])
	_check(pasted.size() == 2, "pasting a two-entity selection creates two new entities")
	if pasted.size() == 2:
		var copied_by_source := {}
		for spr in pasted:
			var props: Dictionary = spr.get_meta("props", {})
			if str(props.get("external_link", "")) == "e_3":
				copied_by_source["e_1"] = spr
			else:
				copied_by_source["e_2"] = spr
		var copied_first: Sprite2D = copied_by_source.get("e_1")
		var copied_second: Sprite2D = copied_by_source.get("e_2")
		_check(copied_first != null and copied_first.flip_h,
			"copied entity preserves horizontal flip state")
		_check(copied_second != null and not copied_second.flip_h,
			"unflipped copied entity remains unflipped")
		if copied_first != null and copied_second != null:
			var first_props: Dictionary = copied_first.get_meta("props", {})
			var second_props: Dictionary = copied_second.get_meta("props", {})
			_check(str(first_props.get("target_point", "")) == str(copied_second.get_meta("ent_id", "")),
				"internal entity reference points to copied partner")
			_check(str(second_props.get("target_point", "")) == str(copied_first.get_meta("ent_id", "")),
				"reciprocal internal reference points back to copied entity")
			_check(str(first_props.get("external_link", "")) == "e_3",
				"reference outside copied selection remains unchanged")
	_check(str(first.get_meta("props", {}).get("target_point", "")) == "e_2",
		"copying leaves original entity references untouched")

	if is_instance_valid(canvas):
		canvas.queue_free()
	await process_frame
	if failures.is_empty():
		print("ENTITY_COPY_REGRESSION_OK")
		quit(0)
	else:
		for failure in failures:
			printerr("ENTITY_COPY_REGRESSION_FAIL: ", failure)
		quit(1)

func _entity(ent_id: String) -> Sprite2D:
	for node in canvas.entities.get_children():
		if str(node.get_meta("ent_id", "")) == ent_id:
			return node as Sprite2D
	return null

func _entities_except(ids: Array[String]) -> Array[Sprite2D]:
	var out: Array[Sprite2D] = []
	for node in canvas.entities.get_children():
		if not ids.has(str(node.get_meta("ent_id", ""))):
			out.append(node as Sprite2D)
	return out

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		printerr("ENTITY_COPY_REGRESSION_FAIL: ", message)
