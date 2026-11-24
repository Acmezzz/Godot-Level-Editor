extends RefCounted

const Flow := preload("res://src/map/map_flow.gd")
const Targets := preload("res://src/project/startup_targets.gd")
const Widgets := preload("res://src/ui/field_widgets.gd")
const Kit := preload("res://src/ui/ui_kit.gd")

static func available(app) -> bool:
	if not app.map_loaded:
		return false
	for section in Flow.SECTIONS:
		if not Flow.declarations(app.manifest, section).is_empty() or not Flow.targets(app.canvas.map_data, section).is_empty():
			return true
	return false

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
	for section in Flow.SECTIONS:
		var saved := Flow.targets(source, section)
		original[section] = saved.duplicate(true)
		var values := saved.duplicate(true)
		draft[section] = values
		var declarations := Flow.declarations(manifest, section).duplicate()
		if not declarations.is_empty() or not saved.is_empty():
			_build_section(rows, scroll, manifest, section, declarations, values,
				focus if section == focus_section else "")
	body.add_child(Kit.popup_buttons(func():
		pop.hide()
		if not is_same(canvas.map_data, source) or not is_same(app.manifest, manifest) or draft == original:
			return
		canvas.push_undo()
		for section in draft:
			if draft[section].is_empty():
				source.meta.erase(section)
			else:
				source.meta[section] = draft[section]
		canvas._mark_map()
		app._set_status("地图内容与出口已更新；保存地图后生效。"), pop.hide, "应用", "取消"))
	app._open_popup(pop)

static func _build_section(rows: VBoxContainer, scroll: ScrollContainer, manifest: Dictionary, section: String,
		declarations: Dictionary, values: Dictionary, focus: String) -> void:
	var is_outlet := section == Flow.OUTPUTS
	rows.add_child(Kit.section_header("流程出口" if is_outlet else "关联内容"))
	for id in values:
		if not declarations.has(id):
			declarations[id] = {"name": id + "（声明已移除）"}
	for id in declarations:
		var decl: Dictionary = declarations[id].merged({"kind": "input", "type": "flow_target"}, true)
		var options := func(_decl: Dictionary) -> Array:
			return Targets.destination_options(manifest, decl).map(func(row):
				return {"v": JSON.stringify(row.target), "t": row.name})
		var set_value := func(target: Dictionary) -> bool:
			if target.is_empty():
				values.erase(id)
			else:
				values[id] = target
			return true
		var built := Widgets.build(decl, values.get(id, {}), set_value, options)
		built.ctl.name = ("MapFlow_" if is_outlet else "MapContent_") + id.validate_node_name()
		var row := Kit.field_row(decl.get("name", id), built.ctl)
		rows.add_child(row)
		if id == focus:
			Kit.highlight_field_row(row)
			scroll.ensure_control_visible.call_deferred(row)
