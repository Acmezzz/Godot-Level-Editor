extends RefCounted

const Slots := preload("res://src/project/project_content_slots.gd")
const SlotField := preload("res://src/ui/destination_slot_field.gd")
const Targets := preload("res://src/project/startup_targets.gd")
const Kit := preload("res://src/ui/ui_kit.gd")

static func open(app, focus := "") -> void:
	var source: Dictionary = app.manifest
	var before := Slots.declarations(source).duplicate(true)
	if before.is_empty():
		return
	var draft := before.duplicate(true)
	var shell: Dictionary = app._popup_body("项目规则",
		"从内容库选择项目共用的规则。保存后游戏可从任意启动入口读取。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 170
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var rows := Kit.vbox(6)
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(rows)
	body.add_child(scroll)
	for id in draft:
		var slot: Dictionary = draft[id]
		var set_value := func(target: Dictionary) -> bool:
			if target.is_empty():
				slot.erase("target")
			else:
				slot["target"] = target
			return true
		var control := SlotField.build(source, {"contentTypes": slot.contentTypes}, slot.get("target", {}), set_value)
		control.name = "ProjectContent_" + id.validate_node_name()
		var row := Kit.field_row(slot.get("name", id), control)
		rows.add_child(row)
		if id == focus:
			Kit.highlight_field_row(row)
			scroll.ensure_control_visible.call_deferred(row)
	var notice := Kit.hint_label("", 460)
	body.add_child(notice)
	var current := func() -> bool:
		return pop.visible and is_same(app.manifest, source) and Slots.declarations(source) == before
	body.add_child(Kit.popup_buttons(func():
		if not current.call():
			notice.text = "项目规则已变更，请重新打开。"
			return
		if draft == before:
			pop.hide()
			return
		for id in draft:
			var slot: Dictionary = draft[id]
			var next: Dictionary = slot.get("target", {})
			if not next.is_empty() and next != before[id].get("target", {}) \
					and not Targets.destination_available(source, {"contentTypes": slot.contentTypes}, next):
				notice.text = "内容已不可用：" + str(slot.get("name", id))
				return
		var candidate := source.duplicate(true)
		candidate[Slots.KEY] = draft
		if await app._save_manifest_file_async(current, candidate, Slots.KEY):
			app._set_status("项目规则已保存")
			pop.hide(), pop.hide, "保存项目规则"))
	app._open_popup(pop, Vector2i(580, 330))
