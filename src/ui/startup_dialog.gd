extends RefCounted

const Kit := preload("res://src/ui/ui_kit.gd")
const Targets := preload("res://src/project/startup_targets.gd")
const Refs := preload("res://src/project/reference_index.gd")

static func fill_content_maps(picker: OptionButton, manifest: Dictionary, saved: String) -> void:
	picker.clear()
	picker.add_item("选择已保存的地图…")
	picker.set_item_metadata(0, "")
	var current := 0
	for map in Refs.map_target_options(manifest):
		var index := picker.item_count
		picker.add_item("%s [%s]" % [map.name, map.code])
		picker.set_item_metadata(index, map.code)
		if map.code == saved:
			current = index
	picker.select(current)

static func open(app) -> void:
	var source: Dictionary = app.manifest
	var startup: Dictionary = source.startup
	var shell: Dictionary = app._popup_body("正式启动入口",
		"游戏正常启动时读取已保存的入口。选择一项已发布的内容、屏幕或地图；未设置时使用游戏自己的默认流程。")
	var pop: PopupPanel = shell.pop
	var options := OptionButton.new()
	options.name = "StartupTarget"
	options.add_item("（由游戏决定）")
	options.set_item_metadata(0, {})
	var selected: Dictionary = startup.get("target", {})
	var current := -1 if not selected.is_empty() else 0
	for row in Targets.options(source):
		var index := options.item_count
		options.add_item(row.name)
		options.set_item_metadata(index, row.target)
		if row.target == selected:
			current = index
	if current < 0:
		current = options.item_count
		options.add_item("（当前入口不可用，请重新选择）")
		options.set_item_metadata(current, selected)
		options.set_item_disabled(current, true)
	options.select(current)
	shell.body.add_child(Kit.field_row("正式开局", options, 80))
	var board := OptionButton.new()
	board.name = "StartupContentMap"
	var board_row := Kit.field_row("内容配对地图", board, 80)
	shell.body.add_child(board_row)
	var saved_board: String = startup.get("contentMap", "")
	var show_board := func():
		board_row.visible = Targets.needs_content_map(startup, options.get_selected_metadata())
	show_board.call()
	if startup.get("contentMapContext") == "paired":
		fill_content_maps(board, source, saved_board)
		options.item_selected.connect(func(_index: int): show_board.call())
	var notice := Kit.hint_label("", 430)
	shell.body.add_child(notice)
	var guard := func() -> bool:
		return is_instance_valid(pop) and pop.visible and is_same(app.manifest, source)
	var save := func():
		var value: Dictionary = options.get_selected_metadata()
		if not Targets.available(source, value):
			notice.text = "该入口已不可用，请重新选择。"
			return
		var code := ""
		if Targets.needs_content_map(startup, value):
			code = board.get_selected_metadata()
			if not Targets.content_map_available(source, code):
				notice.text = "请为内容开局选择可读取的地图。"
				return
		if value == selected and code == saved_board:
			pop.hide()
			return
		var candidate := source.duplicate(true)
		if value.is_empty():
			candidate.startup.erase("target")
		else:
			candidate.startup["target"] = value
		if code.is_empty():
			candidate.startup.erase("contentMap")
		else:
			candidate.startup["contentMap"] = code
		if await app._save_manifest_file_async(guard, candidate, "startup"):
			app._set_status("已保存正式启动入口")
			pop.hide()
	shell.body.add_child(Kit.popup_buttons(save, func(): pop.hide(), "保存启动入口"))
	app._open_popup(pop, Vector2i(580, 250))
