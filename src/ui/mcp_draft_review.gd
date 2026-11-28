extends RefCounted
## Compare, preview and publish a saved MCP draft revision.

const Kit := preload("res://src/ui/ui_kit.gd")
const Drafts := preload("res://src/mcp/drafts.gd")
const Media := preload("res://src/mcp/media.gd")
const FrameDialog := preload("res://src/ui/game_frame_dialog.gd")

static func open(app, preferred := "") -> void:
	var store := Drafts.new(app)
	var media := Media.new(store)
	var shell: Dictionary = app._popup_body("查看 MCP 草稿", "核对尚未发布的地图、内容和项目配置。预览不会替换当前画布。")
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
	var difference := RichTextLabel.new()
	difference.custom_minimum_size.y = 148
	body.add_child(difference)
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
	var publish := Kit.button("校验并发布此版本", Callable(), "plain")
	buttons.add_child(publish)
	buttons.add_child(Kit.spacer())
	buttons.add_child(Kit.button("关闭", pop.hide, "primary"))
	var selected := {"batch": {}, "revision": 0}
	publish.pressed.connect(func():
		if drafts.selected < 0:
			return
		var id: String = drafts.get_selected_metadata()
		var revision: int = selected.revision
		var workbench: RefCounted = load("res://src/mcp/workbench.gd").new(app)
		var plan: Dictionary = await workbench.invoke("publish", {"draft": id, "revision": revision, "previewOnly": true})
		if plan.has("error"):
			var issues: Array = plan.get("issues", [])
			status.text = plan.error if issues.is_empty() else "%s · %s" % [plan.error, issues[0].message]
			return
		if not await app._confirm_action("发布草稿", "发布所选版本，将写入 %d 个正式目标。" % plan.entries.size(), "发布"):
			return
		var published: Dictionary = await workbench.invoke("publish", {"draft": id, "revision": revision})
		if published.has("error"):
			if is_instance_valid(status):
				status.text = published.error
		else:
			app._set_status("已发布草稿 · %d 个正式目标" % published.files.size()))
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
		difference.clear()
		if drafts.selected < 0:
			status.text = "当前项目没有带改动的 MCP 草稿。"
			maps.disabled = true
			publish.disabled = true
			return
		var item := store.read(str(drafts.get_selected_metadata()))
		var batch := store.state(item)
		publish.disabled = batch.is_empty()
		if batch.is_empty():
			status.text = "草稿版本不可读。"
			return
		var lines := PackedStringArray()
		for change in store.difference(batch, item.manifestDigest):
			lines.append("%s · %s · %s" % [change.get("name", change.id), change.kind, change.operation])
			if change.baselineConflict:
				lines.append("  正式版本已变化，无法与原基线对比。")
			for field in change.fields:
				lines.append("  %s：%s → %s" % [field.path, JSON.stringify(field.before), JSON.stringify(field.after)])
		difference.text = "\n".join(lines)
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
			status.text = "版本 %d · 可在上方核对内容和项目改动。" % selected.revision
			return
		maps.select(index)
		await render.call()
	var refresh := func():
		var previous_draft := str(drafts.get_selected_metadata()) if drafts.selected >= 0 else preferred
		var previous_map := str(maps.get_selected_metadata()) if maps.selected >= 0 else ""
		drafts.clear()
		var index := 0
		for item in store.list_drafts():
			if item.changed.maps.is_empty() and item.changed.contents.is_empty() and item.changed.project.is_empty():
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
