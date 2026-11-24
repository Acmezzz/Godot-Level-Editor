extends RefCounted

const Flow := preload("res://src/map/map_flow.gd")
const Targets := preload("res://src/project/startup_targets.gd")
const Widgets := preload("res://src/ui/field_widgets.gd")
const Kit := preload("res://src/ui/ui_kit.gd")

static func available(app) -> bool:
	return app.map_loaded and (not Flow.declarations(app.manifest).is_empty()
		or not Flow.targets(app.canvas.map_data).is_empty())

static func open(app, focus := "") -> void:
	if not available(app):
		return
	var canvas: EditorCanvas = app.canvas
	var source := canvas.map_data
	var original := Flow.targets(source).duplicate(true)
	var values := original.duplicate(true)
	var manifest: Dictionary = app.manifest
	var shell: Dictionary = app._popup_body("地图流程出口",
		"为地图本身接线。游戏决定何时触发出口；应用后随地图保存。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 170
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var rows := Kit.vbox(6)
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(rows)
	body.add_child(scroll)
	var declarations := Flow.declarations(manifest).duplicate()
	for id in original:
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
		built.ctl.name = "MapFlow_" + id.validate_node_name()
		var row := Kit.field_row(decl.get("name", id), built.ctl)
		rows.add_child(row)
		if id == focus:
			Kit.highlight_field_row(row)
			scroll.ensure_control_visible.call_deferred(row)
	body.add_child(Kit.popup_buttons(func():
		pop.hide()
		if not is_same(canvas.map_data, source) or not is_same(app.manifest, manifest) or values == original:
			return
		canvas.push_undo()
		if values.is_empty():
			source.meta.erase(Flow.KEY)
		else:
			source.meta[Flow.KEY] = values
		canvas._mark_map()
		app._set_status("地图流程出口已更新；保存地图后生效。"), pop.hide, "应用", "取消"))
	app._open_popup(pop)
