extends RefCounted
## Read-only map review of a saved MCP draft revision.

const Kit := preload("res://src/ui/ui_kit.gd")
const Drafts := preload("res://src/mcp/drafts.gd")
const Media := preload("res://src/mcp/media.gd")
const FrameDialog := preload("res://src/ui/game_frame_dialog.gd")

static func open(app) -> void:
	var store := Drafts.new(app)
	var media := Media.new(store)
	var shell: Dictionary = app._popup_body("查看 MCP 草稿", "核对 AI 尚未发布的地图。预览只读，可随时刷新，不会替换当前画布。")
	var pop: PopupPanel = shell.pop
	pop.name = "MCPDraftReview"
	FrameDialog.keep_on_focus_loss(pop)
	var body: VBoxContainer = shell.body
	var drafts := OptionButton.new()
	drafts.name = "MCPDraftPicker"
	var maps := OptionButton.new()
	maps.name = "MCPDraftMapPicker"
	body.add_child(Kit.field_row("草稿", drafts, 64))
	body.add_child(Kit.field_row("地图", maps, 64))
	var status := Kit.hint_label("", app.POPUP_BODY_W)
	body.add_child(status)
	var preview := TextureRect.new()
	preview.name = "MCPDraftPreview"
	preview.custom_minimum_size = Vector2(0, 300)
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	preview.hide()
	body.add_child(preview)
	var buttons := Kit.hbox(8)
	body.add_child(buttons)
	var reload := Kit.button("刷新草稿", Callable(), "ghost")
	buttons.add_child(reload)
	buttons.add_child(Kit.spacer())
	buttons.add_child(Kit.button("关闭", pop.hide, "primary"))
	var selected := {"batch": {}, "revision": 0}
	var render := func():
		if maps.selected < 0:
			return
		var code: String = maps.get_selected_metadata()
		reload.disabled = true
		drafts.disabled = true
		maps.disabled = true
		status.text = "正在生成预览…"
		var frame := await media.draft_frame({"map": code, "width": 768, "height": 432}, selected.batch)
		if not is_instance_valid(pop) or pop.is_queued_for_deletion():
			return
		reload.disabled = false
		drafts.disabled = false
		maps.disabled = false
		preview.visible = not frame.has("error")
		if preview.visible:
			preview.texture = ImageTexture.create_from_image(frame.image)
			status.text = "版本 %d · 地图码 %s · 未发布预览" % [selected.revision, code]
		else:
			status.text = frame.error
	var show_maps := func(preferred_map: String):
		maps.clear()
		preview.hide()
		if drafts.selected < 0:
			status.text = "当前项目没有包含地图改动的 MCP 草稿。"
			maps.disabled = true
			return
		var item := store.read(str(drafts.get_selected_metadata()))
		var batch := store.state(item)
		selected.batch = batch
		selected.revision = item.get("revision", 0)
		var index := 0
		for code in batch.maps:
			var row: Dictionary = batch.maps[code]
			if row.get("deleted", false):
				continue
			if code == preferred_map:
				index = maps.item_count
			maps.add_item("%s · %s" % [row.name, code])
			maps.set_item_metadata(maps.item_count - 1, code)
		maps.disabled = maps.item_count == 0
		if maps.disabled:
			status.text = "这个草稿没有可预览的地图。"
			return
		maps.select(index)
		await render.call()
	var refresh := func():
		var previous_draft := str(drafts.get_selected_metadata()) if drafts.selected >= 0 else ""
		var previous_map := str(maps.get_selected_metadata()) if maps.selected >= 0 else ""
		drafts.clear()
		var index := 0
		for item in store.list_drafts():
			if item.changed.maps.is_empty():
				continue
			if item.id == previous_draft:
				index = drafts.item_count
			drafts.add_item("%s · %s" % [item.name, str(item.id).left(8)])
			drafts.set_item_metadata(drafts.item_count - 1, item.id)
		drafts.disabled = drafts.item_count == 0
		if not drafts.disabled:
			drafts.select(index)
		await show_maps.call(previous_map)
	drafts.item_selected.connect(func(_index: int): await show_maps.call(""))
	maps.item_selected.connect(func(_index: int): await render.call())
	reload.pressed.connect(refresh)
	app._open_popup(pop)
	await refresh.call()
