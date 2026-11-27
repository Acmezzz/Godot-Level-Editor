extends RefCounted

const Flow := preload("res://src/map/map_flow.gd")
const SlotField := preload("res://src/ui/destination_slot_field.gd")
const Kit := preload("res://src/ui/ui_kit.gd")
const FlowTarget := preload("res://src/content/flow_target.gd")

static func available(app) -> bool:
	if not app.map_loaded:
		return false
	for section in Flow.SECTIONS:
		if not Flow.declarations(app.manifest, section).is_empty() or not Flow.targets(app.canvas.map_data, section).is_empty():
			return true
	return false

static func apply_targets(canvas: EditorCanvas, sections: Dictionary) -> void:
	canvas.push_undo()
	for section in sections:
		if sections[section].is_empty():
			canvas.map_data.meta.erase(section)
		else:
			canvas.map_data.meta[section] = sections[section]
	canvas._mark_map()

static func open(app, focus_section := "", focus := "") -> void:
	if not available(app):
		return
	var canvas: EditorCanvas = app.canvas
	var source := canvas.map_data
	var manifest: Dictionary = app.manifest
	var shell: Dictionary = app._popup_body("地图内容与出口",
		"为地图绑定共用规则并设置流程出口。游戏执行规则和跳转；应用后随地图保存。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 170
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var rows := Kit.vbox(6)
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(rows)
	body.add_child(scroll)
	var original := {}
	var draft := {}
	var working_map := canvas.arrival_snapshot()
	var apply := func():
		pop.hide()
		if not is_same(canvas.map_data, source) or not is_same(app.manifest, manifest):
			return false
		if draft != original:
			apply_targets(canvas, draft)
			app._set_status("地图内容与出口已更新；保存地图后生效。")
		return true
	var open_content := func(target: Dictionary, context: String):
		if apply.call():
			app.project_shell.content_editor.open_project_content.call_deferred(target.function, target.content, context)
	for section in Flow.SECTIONS:
		var saved := Flow.targets(source, section)
		original[section] = saved.duplicate(true)
		var values := saved.duplicate(true)
		draft[section] = values
		var declarations := Flow.declarations(manifest, section).duplicate()
		if not declarations.is_empty() or not saved.is_empty():
			_build_section(rows, scroll, manifest, section, declarations, values,
				focus if section == focus_section else "", open_content.bind(canvas.cur_map_code()), working_map)
	body.add_child(Kit.popup_buttons(apply, pop.hide, "应用", "取消"))
	app._open_popup(pop)

static func _build_section(rows: VBoxContainer, scroll: ScrollContainer, manifest: Dictionary, section: String,
		declarations: Dictionary, values: Dictionary, focus: String, open_content: Callable, working_map: Dictionary) -> void:
	var is_outlet := section == Flow.OUTPUTS
	rows.add_child(Kit.section_header("流程出口" if is_outlet else "关联内容"))
	for id in values:
		if not declarations.has(id):
			declarations[id] = {"name": id + "（声明已移除）"}
	for id in declarations:
		var decl: Dictionary = declarations[id]
		var can_edit := func() -> bool:
			return FlowTarget.kind(values.get(id)) == "content" and FlowTarget.allows(decl, values[id])
		var edit := Kit.button("应用并编辑内容…", func(): open_content.call(values[id]), "ghost") \
			if decl.get("contentMapContext") == "inherit" else null
		if edit != null:
			edit.disabled = not can_edit.call()
		var set_value := func(target: Dictionary) -> bool:
			if target.is_empty():
				values.erase(id)
			else:
				values[id] = target
			if edit != null:
				edit.disabled = not can_edit.call()
			return true
		var control := SlotField.build(manifest, decl, values.get(id, {}), set_value, working_map)
		control.name = ("MapFlow_" if is_outlet else "MapContent_") + id.validate_node_name()
		var row := Kit.field_row(decl.get("name", id), control)
		if edit != null:
			row.add_child(edit)
		rows.add_child(row)
		if id == focus:
			Kit.highlight_field_row(row)
			scroll.ensure_control_visible.call_deferred(row)
