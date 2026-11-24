extends RefCounted
## Authors reference images, hotspots and responsive screen layouts in the project manifest.

const Kit := preload("res://src/ui/ui_kit.gd")
const Store := preload("res://src/content/content_store.gd")
const Functions := preload("res://src/content/function_decl.gd")
const Validation := preload("res://src/project/manifest_validation.gd")
const Layout := preload("res://src/project/screen_layout.gd")
const Preview := preload("res://src/ui/screen_layout_canvas.gd")
const LayoutForm := preload("res://src/ui/screen_layout_form.gd")
const GamePreview := preload("res://src/project/game_preview.gd")
const FrameDialog := preload("res://src/ui/game_frame_dialog.gd")
const Audit := preload("res://src/project/project_audit.gd")

static func open(app, view_id := "", jump := {}) -> void:
	var source: Dictionary = app.manifest
	var baseline = source.get("views", [])
	var issues: Array[Dictionary] = []
	Validation._validate_views(source, issues)
	if not baseline is Array or not issues.is_empty():
		app._set_status("参考视图声明有误，请先修正诊断中的问题。")
		return
	baseline = baseline.duplicate(true)
	var rows: Array = baseline.duplicate(true)
	var shell: Dictionary = app._popup_body("项目参考视图",
		"拖动绘制热点，点击选中。热点可指向内容；游戏决定如何显示参考图和响应点击。")
	var pop: PopupPanel = shell.pop
	var window: WeakRef = weakref(pop)
	var body: VBoxContainer = shell.body
	var list := OptionButton.new()
	var id := LineEdit.new()
	var image_path := LineEdit.new()
	image_path.placeholder_text = "项目内图片路径，例如 art/controls.png"
	var preview := Preview.new()
	FrameDialog.keep_on_focus_loss(pop, preview.cancel_placement)
	preview.custom_minimum_size = Vector2(500, 295)
	preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var hotspot := OptionButton.new()
	hotspot.name = "ViewHotspot"
	var target := OptionButton.new()
	target.name = "ViewHotspotTarget"
	var notice := Kit.hint_label("", 520)
	body.add_child(list)
	body.add_child(Kit.field_row("视图 ID", id, 82))
	body.add_child(Kit.field_row("参考图片", image_path, 82))
	var layout_mode := CheckButton.new()
	layout_mode.name = "ViewLayoutMode"
	layout_mode.text = "布局编辑"
	var layout_tools := Kit.hbox(8)
	layout_tools.add_child(layout_mode)
	var adjust := CheckButton.new()
	adjust.name = "LayoutAdjust"
	adjust.text = "调整元素"
	adjust.tooltip_text = "拖动已有元素移动，拖动选中元素的四角缩放。Esc 或右键取消本次拖动。"
	adjust.hide()
	layout_tools.add_child(adjust)
	body.add_child(layout_tools)
	var work := Kit.hbox(8)
	work.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(work)
	preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview.clip_contents = true
	work.add_child(preview)
	var game_frame := TextureRect.new()
	game_frame.name = "GameRenderedFrame"
	game_frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	game_frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	game_frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	game_frame.hide()
	work.add_child(game_frame)
	var layout_scroll := ScrollContainer.new()
	layout_scroll.custom_minimum_size.x = 320
	layout_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	layout_scroll.hide()
	work.add_child(layout_scroll)
	var layout_form := Kit.vbox(5)
	layout_form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layout_scroll.add_child(layout_form)
	var hotspot_row := Kit.field_row("热点", hotspot, 82)
	var hotspot_target_row := Kit.field_row("跳转内容", target, 82)
	body.add_child(hotspot_row)
	body.add_child(hotspot_target_row)
	body.add_child(notice)
	var state := {"row": -1, "saving": false, "targets": [], "draft": {}, "layout": {},
		"preview_size": "", "locale": "", "has_layout": false, "viewport_sizes": Layout.sizes(source),
		"image_assets": Layout.image_assets(source), "project_dir": str(source.get("_dir", "")),
		"render_revision": 0, "modules": Layout.modules(source), "module_commits": [], "manifest": source, "app": app,
		"resolve_options": app.project_shell.content_editor._form._resolve_options.bind(true, true)}
	var game_render := Kit.button("游戏渲染预览", Callable(), "ghost")
	game_render.name = "GameRenderPreview"
	game_render.disabled = not GamePreview.supports(source, "screenLayout")
	game_render.tooltip_text = "游戏工程须声明 screenLayout 预览能力。" if game_render.disabled else \
		"用游戏的渲染器预览当前布局、画幅和语言；不会保存改动。"
	game_render.hide()
	var restore_editing := func():
		state.render_revision += 1
		game_frame.hide()
		game_frame.texture = null
		preview.show()
		layout_scroll.visible = layout_mode.button_pressed
		adjust.visible = layout_mode.button_pressed
		game_render.text = "游戏渲染预览"
	var focus_test := CheckButton.new()
	focus_test.name = "LayoutFocusPreview"
	focus_test.text = "试玩焦点（方向键、Tab、确认）"
	focus_test.hide()
	body.add_child(focus_test)
	adjust.toggled.connect(func(enabled: bool):
		preview.adjusting_layout = enabled
		preview.focus_mode = Control.FOCUS_CLICK if enabled else Control.FOCUS_NONE
		preview.start = Vector2(-1, -1)
		preview.cancel_placement()
		preview.queue_redraw())
	focus_test.toggled.connect(func(enabled: bool):
		preview.focus_preview = enabled
		adjust.disabled = enabled
		preview.focus_mode = Control.FOCUS_ALL if enabled else (Control.FOCUS_CLICK if adjust.button_pressed else Control.FOCUS_NONE)
		preview.start = Vector2(-1, -1)
		preview.cancel_placement()
		if enabled:
			preview.focused_id = Layout.focus_start(state.layout, preview.elements, preview.viewport_size, preview.profile)
			preview.call_deferred("grab_focus")
			preview._focus_result(false)
		else:
			preview.release_focus()
			preview.queue_redraw())
	preview.focus_message.connect(func(message: String): notice.text = message)
	var render_layout := func():
		LayoutForm.render(layout_form, preview, state)
	preview.geometry_changed.connect(render_layout)
	var refill_targets := func():
		target.clear()
		target.add_item("（无目标）")
		target.set_item_metadata(0, {})
		if preview.selected < 0:
			target.disabled = true
			return
		target.disabled = false
		var raw_target = preview.hotspots[preview.selected].get("target")
		var current: Dictionary = raw_target if raw_target is Dictionary else {}
		var selected := 0
		for option in state.targets:
			target.add_item(option.label)
			target.set_item_metadata(target.item_count - 1, option.value)
			if current == option.value:
				selected = target.item_count - 1
		if selected == 0 and not current.is_empty():
			target.add_item("（保留原有游戏目标）")
			selected = target.item_count - 1
			target.set_item_disabled(selected, true)
		target.select(selected)
	var refill_hotspots := func(index: int):
		preview.selected = index
		hotspot.clear()
		for i in preview.hotspots.size():
			hotspot.add_item("热点 %d" % (i + 1))
		if index >= 0:
			hotspot.select(index)
		hotspot.disabled = hotspot.item_count == 0
		refill_targets.call()
		preview.queue_redraw()
	var load_picture := func() -> bool:
		var rel := image_path.text.strip_edges().replace("\\", "/")
		if rel.begins_with("res://"):
			rel = rel.substr(6)
		preview.texture = null
		notice.text = ""
		if rel != "":
			var file := str(source.get("_dir", "")).path_join(rel)
			if rel.is_absolute_path() or ".." in rel.split("/") or not FileAccess.file_exists(file):
				notice.text = "图片不存在，或路径超出项目目录。"
			else:
				var img := Image.new()
				if img.load(file) == OK and not img.is_empty():
					preview.texture = ImageTexture.create_from_image(img)
				else:
					notice.text = "无法读取该参考图片。"
		preview.queue_redraw()
		return notice.text == ""
	var stash := func():
		LayoutForm.commit_fields(state)
		var row: Dictionary
		if state.row >= 0:
			row = rows[state.row]
		else:
			row = state.draft
			row["view_id"] = id.text.strip_edges()
		var path := image_path.text.strip_edges()
		if path.is_empty():
			row.erase("image")
		else:
			row["image"] = path
		if preview.hotspots.is_empty():
			row.erase("hotspots")
		else:
			row["hotspots"] = preview.hotspots.duplicate(true)
		if state.has_layout:
			state.layout["elements"] = preview.elements
			row["layout"] = state.layout.duplicate(true)
	var duplicate_view := Kit.button("复制视图…", Callable(), "ghost")
	var delete_view := Kit.button("删除视图…", Callable(), "ghost")
	var play_view := Kit.button("试玩已保存视图", Callable(), "ghost")
	play_view.visible = Playtest.allows_view_entry(source)
	play_view.tooltip_text = "从此屏幕启动独立游戏。只读取已保存版本，当前修改仍留在窗口。"
	var play_draft := Kit.button("试玩当前草稿", Callable(), "ghost")
	play_draft.visible = Playtest.allows_view_draft(source)
	play_draft.tooltip_text = "游戏使用当前视图快照。其他视图、地图和内容仍使用已保存版本。"
	var show_row := func(index: int):
		restore_editing.call()
		state.row = index
		var row: Dictionary = rows[index] if index >= 0 else state.draft
		id.text = str(row.get("view_id", ""))
		id.editable = index < 0
		duplicate_view.disabled = index < 0
		delete_view.disabled = index < 0
		play_view.disabled = index < 0
		image_path.text = str(row.get("image", ""))
		var current_hotspots = row.get("hotspots")
		preview.hotspots = current_hotspots.duplicate(true) if current_hotspots is Array else []
		state.has_layout = row.get("layout") is Dictionary
		state.layout = row.get("layout", {}).duplicate(true)
		state.preview_size = ""
		state.locale = ""
		preview.elements = state.layout.get("elements", [])
		preview.active_element = 0 if not preview.elements.is_empty() else -1
		render_layout.call()
		refill_hotspots.call(0 if not preview.hotspots.is_empty() else -1)
		load_picture.call()
	for kind in Functions.functions(source):
		for cid in Store.list_ids(source, kind):
			var rd := Store.read_ex(source, kind, cid)
			if rd.status == "ok":
				state.targets.append({"label": "%s · %s · %s" % [kind, rd.data.get("name", ""), cid],
					"value": {"function": kind, "content": cid}})
	for row in rows:
		list.add_item(str(row.view_id))
	list.add_item("添加视图…")
	list.item_selected.connect(func(i: int):
		stash.call()
		show_row.call(i if i < rows.size() else -1))
	var initial := rows.find_custom(func(row): return row.view_id == view_id)
	if initial < 0:
		initial = 0 if not rows.is_empty() else -1
	list.select(initial if initial >= 0 else rows.size())
	show_row.call(initial)
	image_path.text_submitted.connect(func(_s: String): load_picture.call())
	hotspot.item_selected.connect(refill_hotspots)
	layout_mode.toggled.connect(func(enabled: bool):
		restore_editing.call()
		preview.editing_layout = enabled
		preview.start = Vector2(-1, -1)
		layout_scroll.visible = enabled
		hotspot_row.visible = not enabled
		hotspot_target_row.visible = not enabled
		focus_test.visible = enabled
		game_render.visible = enabled
		if not enabled:
			focus_test.button_pressed = false
			adjust.button_pressed = false
		render_layout.call()
		pop.size = Vector2i(960, 650) if enabled else Vector2i(660, 620))
	preview.picked.connect(func(i: int):
		if preview.editing_layout:
			preview.active_element = i
			render_layout.call()
		else:
			refill_hotspots.call(i))
	preview.rectangle_drawn.connect(func(r: Rect2):
		if preview.editing_layout:
			var token := Layout.new_element_id(preview.elements)
			preview.elements.append({"id": token, "kind": "button", "text": "",
				"anchors": [r.position.x, r.position.y, r.end.x, r.end.y]})
			preview.active_element = preview.elements.size() - 1
			state.has_layout = true
			render_layout.call()
			return
		preview.hotspots.append({"rect": [r.position.x, r.position.y, r.size.x, r.size.y]})
		refill_hotspots.call(preview.hotspots.size() - 1))
	target.item_selected.connect(func(i: int):
		if preview.selected < 0:
			return
		if i == 0:
			preview.hotspots[preview.selected].erase("target")
		elif target.get_item_metadata(i) is Dictionary:
			preview.hotspots[preview.selected]["target"] = target.get_item_metadata(i))
	var current := func() -> bool:
		return is_instance_valid(pop) and pop.visible and is_same(app.manifest, source) and source.get("views", []) == baseline
	var buttons := Kit.hbox(6)
	buttons.add_child(duplicate_view)
	buttons.add_child(delete_view)
	buttons.add_child(play_view)
	buttons.add_child(play_draft)
	play_view.pressed.connect(func():
		if state.saving or state.row < 0 or not current.call():
			return
		if app._playtest_ctrl.play_view(baseline[state.row].view_id):
			notice.text = "已启动此视图的已保存版本。当前编辑仍留在此窗口。")
	duplicate_view.pressed.connect(func():
		if state.saving:
			return
		if not state.draft.is_empty() and state.draft != {"view_id": ""}:
			notice.text = "已有未保存的新视图；请先保存或取消后再复制。"
			return
		stash.call()
		var copy: Dictionary = rows[state.row].duplicate(true)
		copy["view_id"] = ""
		state.draft = copy
		list.select(rows.size())
		show_row.call(-1)
		notice.text = "为副本填写新的视图 ID，再保存。"
		id.grab_focus())
	delete_view.pressed.connect(func():
		if state.saving or not current.call():
			return
		var at: int = state.row
		var key: String = rows[at].view_id
		var block_reason := func() -> String:
			var staged: Array = app.project_shell.content_editor.staged_rows_current_doc()
			var uses := Audit.view_inbound_refs(source, key, staged)
			if not uses.refs.is_empty():
				return "视图仍被引用：" + "、".join(uses.refs.slice(0, 3)) + "。请先修改引用字段。"
			if not uses.bad.is_empty():
				return "无法检查引用：" + str(uses.bad[0].name)
			return ""
		var reason: String = block_reason.call()
		if reason != "":
			notice.text = reason
			return
		state.saving = true
		var agreed: bool = await app._confirm_action("删除参考视图", "删除屏幕「%s」及其布局和热点？" % key, "删除视图")
		if not agreed or not current.call():
			state.saving = false
			return
		reason = block_reason.call()
		if reason != "":
			state.saving = false
			notice.text = reason
			return
		var updated: Array = baseline.duplicate(true)
		updated.remove_at(at)
		var candidate := source.duplicate(true)
		candidate["views"] = updated
		var ok: bool = await app._save_manifest_file_async(current, candidate, "views")
		state.saving = false
		if not is_instance_valid(pop) or not pop.visible:
			return
		if not ok:
			notice.text = "视图未删除；请重新打开后再试。"
			return
		app._set_status("已删除参考视图：" + key)
		pop.hide())
	buttons.add_child(Kit.button("加载图片", func(): load_picture.call()))
	buttons.add_child(game_render)
	game_render.pressed.connect(func():
		if game_frame.visible:
			restore_editing.call()
			focus_test.show()
			notice.text = ""
			return
		if game_render.disabled or not state.has_layout:
			notice.text = "请先添加布局元素。"
			return
		if not load_picture.call():
			return
		stash.call()
		var row: Dictionary = rows[state.row] if state.row >= 0 else state.draft
		var snapshot := row.duplicate(true)
		var errors: Array[Dictionary] = []
		Layout.validate(snapshot.layout, state.viewport_sizes, "layout", errors, state.modules)
		if not errors.is_empty():
			notice.text = "%s：%s" % [errors[0].path, errors[0].message]
			return
		var viewport := Vector2i(preview.viewport_size.round())
		var profile := preview.profile
		var locale := preview.locale
		var revision: int = state.render_revision
		var keep := FrameDialog.visible_request(window, func():
			return is_same(app.manifest, source) and state.render_revision == revision)
		game_render.disabled = true
		notice.text = "游戏正在渲染当前布局…"
		var result := await GamePreview.render(app.get_tree(), source, "screenLayout", snapshot, viewport, locale, keep, profile)
		var owner: Window = window.get_ref()
		if owner == null or not owner.visible:
			return
		game_render.disabled = false
		if not keep.call():
			return
		if not result.has("image"):
			notice.text = result.error
			return
		stash.call()
		if row != snapshot or Vector2i(preview.viewport_size.round()) != viewport or preview.locale != locale or preview.profile != profile:
			notice.text = "渲染期间布局或预览设置已变更，请重新预览。"
			return
		focus_test.button_pressed = false
		focus_test.hide()
		adjust.hide()
		layout_scroll.hide()
		preview.cancel_placement()
		preview.hide()
		game_frame.texture = ImageTexture.create_from_image(result.image)
		game_frame.show()
		game_render.text = "返回布局编辑"
		notice.text = "游戏渲染快照 · %d × %d · %s" % [viewport.x, viewport.y, locale if locale != "" else "原文"])
	var remove_hotspot := Kit.button("删除选中热点", func():
		if preview.selected >= 0:
			preview.hotspots.remove_at(preview.selected)
			refill_hotspots.call(mini(preview.selected, preview.hotspots.size() - 1)))
	buttons.add_child(remove_hotspot)
	layout_mode.toggled.connect(func(enabled: bool): remove_hotspot.visible = not enabled)
	body.add_child(buttons)
	var prepare := func(draft_only: bool) -> Dictionary:
		if not load_picture.call():
			return {}
		var key := id.text.strip_edges()
		stash.call()
		var view: Dictionary = (rows[state.row] if state.row >= 0 else state.draft).duplicate(true)
		var updated: Array = (baseline if draft_only else rows).duplicate(true)
		if state.row < 0:
			if key == "" or updated.any(func(row): return row.view_id == key):
				notice.text = "视图 ID 必须非空且唯一。"
				return {}
			updated.append(view)
		else:
			updated[state.row] = view
		var candidate := source.merged({"views": updated}, true)
		var errors: Array[Dictionary] = []
		Validation._validate_views(candidate, errors)
		if not errors.is_empty():
			notice.text = "%s：%s" % [errors[0].path, errors[0].message]
			return {}
		var problems := Audit.view_reference_issues(candidate, key)
		if not problems.is_empty():
			notice.text = "%s：%s" % [problems[0].path, problems[0].message]
			return {}
		return {"manifest": candidate, "view": view}
	play_draft.pressed.connect(func():
		if state.saving or not current.call():
			return
		var prepared: Dictionary = prepare.call(true)
		if prepared.is_empty():
			return
		var view: Dictionary = prepared.view
		var size := Vector2i(preview.viewport_size.round())
		var snapshot := {"view": view, "viewport": [size.x, size.y], "viewportId": preview.profile, "locale": preview.locale}
		if app._playtest_ctrl.play_view(view.view_id, snapshot):
			notice.text = "已启动当前草稿的试玩快照。当前编辑仍留在此窗口。")
	var save := func():
		if state.saving:
			return
		var prepared: Dictionary = prepare.call(false)
		if prepared.is_empty():
			return
		state.saving = true
		var ok: bool = await app._save_manifest_file_async(current, prepared.manifest, "views") if current.call() else false
		state.saving = false
		if not is_instance_valid(pop) or not pop.visible:
			return
		if not ok:
			notice.text = "视图未保存。请检查清单状态后重新打开。"
			return
		app._set_status("已保存参考视图：" + str(prepared.view.view_id))
		pop.hide()
	body.add_child(Kit.popup_buttons(save, func(): pop.hide(), "保存参考视图"))
	var element: String = jump.get("element", "")
	var selected := preview.elements.find_custom(func(row): return row.id == element)
	if selected >= 0:
		preview.active_element = selected
		layout_mode.button_pressed = true
	elif jump.get("hotspot", -1) in range(preview.hotspots.size()):
		refill_hotspots.call(jump.hotspot)
	app._open_popup(pop, Vector2i(960, 650) if selected >= 0 else Vector2i(660, 620))
	var field: String = jump.get("field", "")
	if selected >= 0 and field != "":
		for row in layout_form.get_children():
			if row.get_meta("module_field", "") == field:
				layout_scroll.ensure_control_visible.call_deferred(row)
				break
