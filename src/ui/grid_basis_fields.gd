extends RefCounted
## Shared optional basis input for map and tile-layer settings.

const Kit := preload("res://src/ui/ui_kit.gd")

static func add_to(body: VBoxContainer, prefix: String, tile: Vector2i, initial: Array = []) -> Dictionary:
	var enabled := CheckBox.new()
	enabled.name = prefix + "CustomBasis"
	enabled.text = "使用自定义基向量（像素）"
	enabled.button_pressed = not initial.is_empty()
	body.add_child(enabled)
	var fields := VBoxContainer.new()
	body.add_child(fields)
	var axes: Array[LineEdit] = []
	var values: Array = [tile.x, 0, 0, tile.y] if initial.is_empty() else initial[0] + initial[1]
	for axis in ["U", "V"]:
		var row := Kit.hbox(8)
		for component in ["X", "Y"]:
			var field := LineEdit.new()
			field.name = prefix + "Basis" + axis + component
			field.text = str(values[axes.size()])
			row.add_child(Kit.field_row(component.to_lower(), field, 12))
			axes.append(field)
		fields.add_child(Kit.field_row(axis, row, 20))
	enabled.toggled.connect(func(show_fields: bool): fields.visible = show_fields)
	fields.visible = enabled.button_pressed
	return {"enabled": enabled, "axes": axes}

static func read(editor: Dictionary) -> Dictionary:
	if not editor.enabled.button_pressed:
		return {"ok": true, "value": []}
	var parts: Array[float] = []
	for field: LineEdit in editor.axes:
		var raw := field.text.strip_edges()
		if not raw.is_valid_float():
			return {"ok": false, "error": "基向量的四个分量都必须是数值", "field": field}
		parts.append(raw.to_float())
	return {"ok": true, "value": [[parts[0], parts[1]], [parts[2], parts[3]]]}
