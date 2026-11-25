extends RefCounted

const Recovery := preload("res://src/map/recovery.gd")
const Layers := preload("res://src/project/event_layers.gd")
const Ids := preload("res://src/content/content_id.gd")
const Maps := preload("res://src/project/reference_index.gd")
const SlotField := preload("res://src/ui/destination_slot_field.gd")
const Kit := preload("res://src/ui/ui_kit.gd")

static func open(app, layer_id := "", drawing_only := false) -> void:
	var source: Dictionary = app.manifest
	var before: Dictionary = source.get(Layers.KEY, {})
	var draft := before.duplicate(true)
	var retry: Dictionary = app._map_file_ctrl.event_drawing_retry
	if not is_same(retry.get("manifest"), source) or retry.get("before") != before:
		retry.clear()
	if not retry.is_empty():
		draft = retry.draft.duplicate(true)
		layer_id = retry.id
	var events := Layers.types(source)
	var map_options := Maps.map_target_options(source)
	var drawing_codes := Layers.drawing_codes(source)
	var shell: Dictionary = app._popup_body("图组事件层", "多张地图可共用独立绘制、碰撞与事件。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var columns := Kit.hbox(12)
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(columns)
	var stack := Kit.vbox(6)
	stack.custom_minimum_size.x = 200
	columns.add_child(stack)
	stack.add_child(Kit.section_header("绘制顺序"))
	stack.add_child(Kit.hint_label("上方遮挡下方，图组整组移动。", 200))
	var list := ItemList.new()
	list.name = "DrawingOrder"
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.custom_minimum_size.y = 184
	stack.add_child(list)
	var movement := Kit.hbox(6)
	stack.add_child(movement)
	var up := Kit.button("上移")
	var down := Kit.button("下移")
	movement.add_child(up)
	movement.add_child(down)
	var manage := Kit.hbox(6)
	stack.add_child(manage)
	var add := Kit.button("新建层")
	var remove := Kit.button("删除层")
	manage.add_child(add)
	manage.add_child(remove)
	var edit := Kit.button("保存并编辑绘制层")

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 260
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var fields := Kit.vbox(6)
	fields.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(fields)
	columns.add_child(scroll)

	var order := Layers.drawing_stack(draft)
	order.reverse()
	var selected_index := func() -> int: return list.get_selected_items()[0]
	var selected := func() -> String:
		return order[selected_index.call()]
	var update_actions := func():
		var index: int = selected_index.call()
		up.disabled = index == 0
		down.disabled = index == order.size() - 1
		remove.disabled = order[index] == ""
		edit.disabled = remove.disabled
	var show_layer := func():
		for child in fields.get_children():
			fields.remove_child(child)
			child.queue_free()
		var id: String = selected.call()
		if id.is_empty():
			fields.add_child(Kit.hint_label("「普通地图」是绘制的分界。放在它上方的图组会盖住地图，放在它下方的图组会先画。", 370))
			return
		var row: Dictionary = draft[id]
		var name := LineEdit.new()
		name.text = str(row.get("name", id))
		name.text_changed.connect(func(value: String):
			row["name"] = value
			list.set_item_text(order.find(id), value if not value.is_empty() else id))
		fields.add_child(Kit.field_row("层名称", name))
		var drawing_code: String = row.get("drawingMap", "")
		var resolved := Maps.resolve_map(source, drawing_code)
		fields.add_child(Kit.field_row("绘制层地图码", Kit.hint_label(
			"用「保存并编辑绘制层」创建" if drawing_code == "" else (
			drawing_code if resolved.status == "ok" else
			"%s：%s，保存并编辑可重建" % [drawing_code, "地图码重复" if resolved.status == "ambiguous" else "地图缺失"]), 400)))
		if drawing_code != "" and resolved.status != "ok":
			var replacement := OptionButton.new()
			replacement.add_item("选择现有地图作为绘制层…")
			for option in map_options:
				if option.code not in drawing_codes:
					replacement.add_item("%s [%s]" % [option.name, option.code])
					replacement.set_item_metadata(replacement.item_count - 1, option.code)
			replacement.item_selected.connect(func(index: int):
				if index > 0:
					row["drawingMap"] = replacement.get_item_metadata(index))
			fields.add_child(Kit.field_row("重新绑定", replacement))
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
			if map.code not in drawing_codes:
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
		if drawing_only:
			return
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
		list.clear()
		for id in order:
			var index := list.add_item("普通地图（分界）" if id == "" else str(draft[id].get("name", id)))
			list.set_item_metadata(index, id)
		list.select(order.find(preferred))
		list.ensure_current_is_visible()
		update_actions.call()
	var write_order := func():
		var base := order.find("")
		for i in order.size():
			if i != base:
				draft[order[i]]["drawOrder"] = base - i
	var move := func(direction: int):
		var index: int = selected_index.call()
		var id := order[index]
		var next := index + direction
		order[index] = order[next]
		order[next] = id
		write_order.call()
		refresh.call(id)
	up.pressed.connect(move.bind(-1))
	down.pressed.connect(move.bind(1))
	list.item_selected.connect(func(_index: int):
		update_actions.call()
		show_layer.call())
	add.pressed.connect(func():
		var id := Ids.new_inst_code() + Ids.new_inst_code()
		while draft.has(id):
			id = Ids.new_inst_code() + Ids.new_inst_code()
		draft[id] = {"name": "新图组", "events": {}}
		order.push_front(id)
		write_order.call()
		refresh.call(id)
		show_layer.call())
	remove.pressed.connect(func():
		var index: int = selected_index.call()
		draft.erase(order.pop_at(index))
		refresh.call(order[mini(index, order.size() - 1)])
		show_layer.call())
	refresh.call(layer_id if draft.has(layer_id) else order[0])
	show_layer.call()

	var current := func() -> bool:
		return pop.visible and is_same(app.manifest, source) and source.get(Layers.KEY, {}) == before
	var publish := func(edit_drawing: bool):
		if not current.call():
			return
		var id: String = selected.call()
		if edit_drawing and id == "":
			return
		var layer: Dictionary = draft.get(id, {})
		var code: String = layer.get("drawingMap", "")
		var plan: Dictionary = retry.get("plan", {})
		var output := draft.duplicate(true)
		if not plan.is_empty():
			var pending_id: String = retry.id
			if output.has(pending_id) and output[pending_id].get("drawingMap", "") == retry.get("previous_code", ""):
				output[pending_id]["drawingMap"] = plan.data.meta.code
				if id == pending_id:
					code = plan.data.meta.code
			else:
				app._set_status("请先保存上一次未完成的绘制层绑定")
				return
		elif edit_drawing and Maps.resolve_map(source, code).status != "ok":
			plan = app._map_file_ctrl.plan_event_drawing(str(layer.get("name", id)), id)
			output[id]["drawingMap"] = plan.data.meta.code
			code = plan.data.meta.code
			retry.merge({"plan": plan, "id": id, "previous_code": layer.get("drawingMap", ""),
				"manifest": source, "before": before, "draft": draft}, true)
		if output != before:
			var candidate := source.duplicate()
			candidate[Layers.KEY] = output
			var write_drawing: Callable = Callable() if plan.is_empty() else app._map_file_ctrl.publish_event_drawing.bind(plan, candidate)
			if not await app._save_manifest_file_async(current, candidate, Layers.KEY, write_drawing):
				if str(plan.get("log_path", "")) == "":
					retry.clear()
				return
			Recovery.clear_pending(plan.get("log_path", ""))
			retry.clear()
			if app.map_loaded:
				app._map_file_ctrl.refresh_event_drawings()
		pop.hide()
		if edit_drawing and Maps.resolve_map(source, code).status == "ok":
			app._map_file_ctrl.open_event_drawing.call_deferred(code)
	edit.pressed.connect(func(): publish.call(true))
	body.add_child(edit)
	body.add_child(Kit.popup_buttons(func(): publish.call(false), pop.hide, "保存事件层"))
	app._open_popup(pop, Vector2i(730, 480))
