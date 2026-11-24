extends RefCounted

const Layers := preload("res://src/project/event_layers.gd")
const Ids := preload("res://src/content/content_id.gd")
const Maps := preload("res://src/project/reference_index.gd")
const SlotField := preload("res://src/ui/destination_slot_field.gd")
const Kit := preload("res://src/ui/ui_kit.gd")

static func open(app) -> void:
	var source: Dictionary = app.manifest
	var before: Dictionary = source.get(Layers.KEY, {})
	var draft := before.duplicate(true)
	var events := Layers.types(source)
	var map_options := Maps.map_target_options(source)
	var shell: Dictionary = app._popup_body("图组事件层", "同一层的事件只配置一次，可用于全部地图或任意地图组合。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var toolbar := Kit.hbox(6)
	body.add_child(toolbar)
	var select := OptionButton.new()
	select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(select)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 260
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var fields := Kit.vbox(6)
	fields.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(fields)
	body.add_child(scroll)

	var selected := func() -> String:
		return str(select.get_selected_metadata()) if select.selected >= 0 else ""
	var show_layer := func():
		for child in fields.get_children():
			fields.remove_child(child)
			child.queue_free()
		var id: String = selected.call()
		if id.is_empty():
			fields.add_child(Kit.hint_label("点击「新建层」添加共享事件。", 450))
			return
		var row: Dictionary = draft[id]
		var name := LineEdit.new()
		name.text = str(row.get("name", id))
		name.text_changed.connect(func(value: String):
			row["name"] = value
			select.set_item_text(select.selected, value if not value.is_empty() else id))
		fields.add_child(Kit.field_row("层名称", name))
		var all_maps := CheckBox.new()
		all_maps.text = "适用于全部地图"
		all_maps.button_pressed = not row.has("maps")
		fields.add_child(all_maps)
		var maps := Kit.vbox(2)
		fields.add_child(maps)
		maps.visible = row.has("maps")
		var chosen: Array = row.get("maps", []).duplicate()
		all_maps.toggled.connect(func(enabled: bool):
			maps.visible = not enabled
			if enabled:
				row.erase("maps")
			else:
				row["maps"] = chosen)
		var options := {}
		for map in map_options:
			options[map.code] = map.name
		for code in chosen:
			if not options.has(code):
				options[code] = "地图已缺失或重码"
		for code in options:
			var box := CheckBox.new()
			box.text = "%s [%s]" % [options[code], code]
			box.button_pressed = chosen.has(code)
			box.toggled.connect(func(enabled: bool):
				if enabled:
					chosen.append(code)
				else:
					chosen.erase(code)
				row["maps"] = chosen)
			maps.add_child(box)
		fields.add_child(Kit.section_header("事件"))
		var values: Dictionary = row.get_or_add("events", {})
		var codes := events.keys()
		for code in values:
			if not codes.has(code):
				codes.append(code)
		for code in codes:
			var event: Dictionary = events.get(code, {})
			var field := SlotField.build(source, event.get("eventTargets", {}), values.get(code, {}),
				func(target: Dictionary) -> bool:
					if target.is_empty():
						values.erase(code)
					else:
						values[code] = target
					return true)
			fields.add_child(Kit.field_row(event.get("name", code), field, 120))
	var refresh := func(preferred: String):
		select.clear()
		var index := 0
		for id in draft:
			if id == preferred:
				index = select.item_count
			select.add_item(str(draft[id].get("name", id)))
			select.set_item_metadata(select.item_count - 1, id)
		select.select(index if not draft.is_empty() else -1)
		show_layer.call()
	select.item_selected.connect(func(_index: int): show_layer.call())
	toolbar.add_child(Kit.button("新建层", func():
		var id := Ids.new_inst_code() + Ids.new_inst_code()
		while draft.has(id):
			id = Ids.new_inst_code() + Ids.new_inst_code()
		draft[id] = {"name": "新事件层", "events": {}}
		refresh.call(id)))
	toolbar.add_child(Kit.button("删除层", func():
		draft.erase(selected.call())
		refresh.call("")))
	refresh.call("")

	var current := func() -> bool:
		return pop.visible and is_same(app.manifest, source) and source.get(Layers.KEY, {}) == before
	body.add_child(Kit.popup_buttons(func():
		if draft == before:
			pop.hide()
			return
		var candidate := source.duplicate()
		candidate[Layers.KEY] = draft
		if current.call() and await app._save_manifest_file_async(current, candidate, Layers.KEY):
			pop.hide(), pop.hide, "保存事件层"))
	app._open_popup(pop, Vector2i(650, 460))
