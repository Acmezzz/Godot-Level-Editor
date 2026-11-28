extends RefCounted
## Named screen coordinate domains shared by project content.

const Kit := preload("res://src/ui/ui_kit.gd")

static func open(app) -> void:
	var source: Dictionary = app.manifest
	var current = source.get("viewports", [])
	if not current is Array:
		app._set_status("参考画幅定义不是数组，未改动清单。")
		return
	var baseline: Array = current.duplicate(true)
	var rows := baseline.duplicate(true)
	var shell: Dictionary = app._popup_body("项目参考画幅",
		"画幅 ID 用于内容引用。修改宽高会保留内容中已有的归一化坐标。", true)
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var list := OptionButton.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(list)
	var id := LineEdit.new()
	id.placeholder_text = "例如 portrait、wide、player2"
	body.add_child(Kit.field_row("画幅 ID", id, 76))
	var width := _size_input()
	var height := _size_input()
	body.add_child(Kit.field_row("宽（像素）", width, 76))
	body.add_child(Kit.field_row("高（像素）", height, 76))
	var notice := Label.new()
	notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(notice)
	var state := {"index": -1, "saving": false}
	var select_row := func(idx: int):
		state.index = idx
		id.editable = idx < 0
		var row: Dictionary = rows[idx] if idx >= 0 else {}
		id.text = str(row.get("id", ""))
		width.value = float(row.get("w", 1920))
		height.value = float(row.get("h", 1080))
	for row in rows:
		if not row is Dictionary:
			app._set_status("参考画幅定义含无效记录，未改动清单。")
			return
		list.add_item(str(row.get("id", "")))
	list.add_item("添加画幅…")
	list.item_selected.connect(func(i: int): select_row.call(i if i < rows.size() else -1))
	list.select(0)
	select_row.call(0 if not rows.is_empty() else -1)
	var save := func():
		if state.saving:
			return
		var key := id.text.strip_edges()
		var idx := int(state.index)
		if key == "" or (idx < 0 and rows.any(func(r): return str(r.get("id", "")) == key)):
			notice.text = "画幅 ID 必须非空且唯一。"
			return
		var candidate := source.duplicate(true)
		var updated := rows.duplicate(true)
		if idx >= 0:
			updated[idx]["w"] = width.value
			updated[idx]["h"] = height.value
		else:
			updated.append({"id": key, "w": width.value, "h": height.value})
		candidate["viewports"] = updated
		for issue in EditorManifest.validate(candidate):
			if issue.severity == "error" and (str(issue.path).begins_with("viewports") or ".layout" in str(issue.path)):
				notice.text = "此画幅无法保存 · %s：%s" % [issue.path, issue.message]
				return
		var guard := func() -> bool:
			return is_instance_valid(pop) and pop.visible and is_same(app.manifest, source) \
				and source.get("viewports", []) == baseline
		state.saving = true
		var ok: bool = await app._save_manifest_file_async(guard, candidate, "viewports") if guard.call() else false
		state.saving = false
		if not is_instance_valid(pop) or not pop.visible:
			return
		if not ok:
			notice.text = "画幅未保存。请检查清单状态后重新打开。"
			return
		if app.project_shell != null and app.project_shell.content_editor != null:
			app.project_shell.content_editor.reload_content_form()
		app._set_status("已保存参考画幅：" + key)
		pop.hide()
	body.add_child(Kit.popup_buttons(save, func(): pop.hide(), "保存画幅"))
	app._open_popup(pop)

static func _size_input() -> SpinBox:
	var input := SpinBox.new()
	input.min_value = 0.01
	input.max_value = 100000
	input.allow_greater = true
	input.step = 0.01
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return input
