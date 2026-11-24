extends RefCounted
## Authors reference images, hotspots and responsive screen layouts in the project manifest.

const Kit := preload("res://src/ui/ui_kit.gd")
const Store := preload("res://src/content/content_store.gd")
const Functions := preload("res://src/content/function_decl.gd")
const References := preload("res://src/project/reference_index.gd")
const Validation := preload("res://src/project/manifest_validation.gd")
const Layout := preload("res://src/project/screen_layout.gd")
const Id := preload("res://src/content/content_id.gd")
const GamePreview := preload("res://src/project/game_preview.gd")
const FrameDialog := preload("res://src/ui/game_frame_dialog.gd")
const Audit := preload("res://src/project/project_audit.gd")

class Preview extends Control:
	const FOCUS_ACTIONS := {"ui_left": "left", "ui_right": "right", "ui_up": "up", "ui_down": "down",
		"ui_focus_next": "next", "ui_focus_prev": "previous", "ui_accept": "activate"}
	var texture: Texture2D
	var hotspots: Array = []
	var selected := -1
	var start := Vector2(-1, -1)
	var cursor := Vector2.ZERO
	var editing_layout := false
	var elements: Array = []
	var active_element := -1
	var viewport_size := Vector2(1280, 720)
	var focus_preview := false
	var focus_layout: Dictionary = {}
	var focused_id := ""
	var locale := ""
	var asset_textures: Dictionary = {}
	signal picked(index: int)
	signal rectangle_drawn(rect: Rect2)
	signal focus_message(message: String)

	func frame() -> Rect2:
		var dim := size
		var reference := viewport_size if editing_layout else (texture.get_size() if texture != null else Vector2.ZERO)
		if reference.x > 0 and reference.y > 0:
			dim = reference * minf(size.x / reference.x, size.y / reference.y)
		return Rect2((size - dim) * 0.5, dim)

	func _draw() -> void:
		var area := frame()
		draw_rect(area, Color("#263544"))
		if texture != null:
			draw_texture_rect(texture, area, false)
		if editing_layout:
			_draw_layout(area)
		for i in (0 if editing_layout else hotspots.size()):
			var row: Dictionary = hotspots[i]
			var raw: Array = row.rect
			var r := Rect2(area.position + Vector2(raw[0], raw[1]) * area.size,
				Vector2(raw[2], raw[3]) * area.size)
			var c := Color("#ffc15c") if i == selected else Color("#5de2eb")
			draw_rect(r, Color(c, 0.28))
			draw_rect(r, c, false, 2)
		if start.x >= 0:
			var r := Rect2(start, cursor - start).abs()
			draw_rect(Rect2(area.position + r.position * area.size, r.size * area.size),
				Color("#ffffff"), false, 2)

	func _layout_rect(index: int, area: Rect2) -> Rect2:
		var px := Layout.rect(elements[index], viewport_size)
		return Rect2(area.position + px.position / viewport_size * area.size, px.size / viewport_size * area.size)

	func _draw_layout(area: Rect2) -> void:
		for i in elements.size():
			var item: Dictionary = elements[i]
			var bounds := _layout_rect(i, area)
			if not bounds.has_area():
				continue
			var visible_rect := bounds.intersection(area)
			if not visible_rect.has_area():
				continue
			var highlighted: bool = item.id == focused_id if focus_preview else active_element == i
			var color := Color("#ffc15c") if highlighted else Color("#82cee1")
			if item.kind != "text":
				draw_rect(visible_rect, Color(color, 0.23 if item.kind == "panel" else 0.45))
			var image: Texture2D = asset_textures.get(item.get("imageAsset", ""))
			if image != null:
				var placement := Layout.image_placement(bounds, area, image.get_size(), item.get("imageFit", "contain"))
				if not placement.is_empty():
					draw_texture_rect_region(image, placement.dest, placement.source)
			draw_rect(visible_rect, color, false, 1.5)
			var label := Layout.display_text(item, locale)
			if label.is_empty():
				continue
			var font := ThemeDB.fallback_font
			var scale_px := area.size.x / viewport_size.x
			var font_px := int(item.get("fontSize", Layout.DEFAULT_FONT_SIZE))
			var overflow := text_overflows(item)
			var draw_size := maxi(1, roundi(font_px * scale_px))
			var line_height := font.get_height(draw_size)
			var pad := Vector2.ONE * 4 * scale_px
			var pen := bounds.position + pad
			for line in label.split("\n"):
				var available := visible_rect.end.x - pen.x - pad.x
				if pen.y + line_height > visible_rect.end.y or available <= 0.0:
					break
				if pen.y >= visible_rect.position.y and pen.x >= visible_rect.position.x:
					draw_string(font, pen + Vector2(0, font.get_ascent(draw_size)), line,
						HORIZONTAL_ALIGNMENT_LEFT, available, draw_size)
				pen.y += line_height
			if overflow:
				draw_rect(visible_rect, Color("#ff8877"), false, 2)

	func text_overflows(item: Dictionary) -> bool:
		var label := Layout.display_text(item, locale)
		if label.is_empty():
			return false
		var bounds := Layout.rect(item, viewport_size)
		var font := ThemeDB.fallback_font
		var font_px := int(item.get("fontSize", Layout.DEFAULT_FONT_SIZE))
		var lines := label.split("\n")
		if font.get_height(font_px) * lines.size() + 8.0 > bounds.size.y:
			return true
		for line in lines:
			if font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, font_px).x + 8.0 > bounds.size.x:
				return true
		return false

	func _gui_input(event: InputEvent) -> void:
		var area := frame()
		if area.size.x <= 0 or area.size.y <= 0:
			return
		if editing_layout and focus_preview:
			_focus_input(event, area)
			return
		if event is InputEventMouseMotion and start.x >= 0:
			cursor = ((event.position - area.position) / area.size).clamp(Vector2.ZERO, Vector2.ONE)
			queue_redraw()
		if not event is InputEventMouseButton or event.button_index != MOUSE_BUTTON_LEFT:
			return
		var point: Vector2 = ((event.position - area.position) / area.size).clamp(Vector2.ZERO, Vector2.ONE)
		if event.pressed:
			if not area.has_point(event.position):
				return
			start = point
			cursor = point
		elif start.x >= 0:
			var r := Rect2(start, point - start).abs()
			start = Vector2(-1, -1)
			if r.size.x * area.size.x >= 4 and r.size.y * area.size.y >= 4:
				rectangle_drawn.emit(r)
			else:
				var count := elements.size() if editing_layout else hotspots.size()
				for i in range(count - 1, -1, -1):
					var hit := _layout_rect(i, area).has_point(event.position) if editing_layout else Rect2(
						hotspots[i].rect[0], hotspots[i].rect[1], hotspots[i].rect[2], hotspots[i].rect[3]).has_point(point)
					if hit:
						picked.emit(i)
						break
			queue_redraw()
		accept_event()

	func _focus_input(event: InputEvent, area: Rect2) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			grab_focus()
			for i in range(elements.size() - 1, -1, -1):
				if Layout.focusable(elements[i]) and _layout_rect(i, area).intersection(area).has_point(event.position):
					focused_id = str(elements[i].id)
					_focus_result(true)
					break
			accept_event()
			return
		for action in FOCUS_ACTIONS:
			if not event.is_action_pressed(action, true, true):
				continue
			if action != "ui_accept":
				focused_id = Layout.focus_step(focus_layout, elements, focused_id, FOCUS_ACTIONS[action], viewport_size)
			_focus_result(action == "ui_accept")
			accept_event()
			return

	func _focus_result(activate: bool) -> void:
		for row in elements:
			if row.id != focused_id:
				continue
			var title := Layout.display_text(row, locale)
			if title.is_empty():
				title = focused_id
			var message := "焦点：" + title
			if activate:
				var target = row.get("target")
				message = "确认：%s → %s/%s" % [title, target.function, target.content] \
					if References.is_view_content_target(target) else "确认：" + title
			focus_message.emit(message)
			queue_redraw()
			return
		focus_message.emit("当前画幅没有可聚焦按钮。")
		queue_redraw()

static func open(app, view_id := "") -> void:
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
	FrameDialog.keep_on_focus_loss(pop)
	var window: WeakRef = weakref(pop)
	var body: VBoxContainer = shell.body
	var list := OptionButton.new()
	var id := LineEdit.new()
	var image_path := LineEdit.new()
	image_path.placeholder_text = "项目内图片路径，例如 art/controls.png"
	var preview := Preview.new()
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
	body.add_child(layout_mode)
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
		"render_revision": 0}
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
		game_render.text = "游戏渲染预览"
	var focus_test := CheckButton.new()
	focus_test.name = "LayoutFocusPreview"
	focus_test.text = "试玩焦点（方向键、Tab、确认）"
	focus_test.hide()
	body.add_child(focus_test)
	focus_test.toggled.connect(func(enabled: bool):
		preview.focus_preview = enabled
		preview.focus_mode = Control.FOCUS_ALL if enabled else Control.FOCUS_NONE
		preview.start = Vector2(-1, -1)
		if enabled:
			preview.focused_id = Layout.focus_start(state.layout, preview.elements, preview.viewport_size)
			preview.call_deferred("grab_focus")
			preview._focus_result(false)
		else:
			preview.release_focus()
			preview.queue_redraw())
	preview.focus_message.connect(func(message: String): notice.text = message)
	var render_layout := func():
		_render_layout(layout_form, preview, state)
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
	var show_row := func(index: int):
		restore_editing.call()
		state.row = index
		var row: Dictionary = rows[index] if index >= 0 else state.draft
		id.text = str(row.get("view_id", ""))
		id.editable = index < 0
		duplicate_view.disabled = index < 0
		delete_view.disabled = index < 0
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
			var token := _element_id(preview.elements)
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
				return "视图仍被引用：" + "、".join(uses.refs.slice(0, 3)) + "。请先在流程图中改接或断开。"
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
		Layout.validate(snapshot.layout, state.viewport_sizes, "layout", errors)
		if not errors.is_empty():
			notice.text = "%s：%s" % [errors[0].path, errors[0].message]
			return
		var viewport := Vector2i(preview.viewport_size.round())
		var locale := preview.locale
		var revision: int = state.render_revision
		var keep := FrameDialog.visible_request(window, func():
			return is_same(app.manifest, source) and state.render_revision == revision)
		game_render.disabled = true
		notice.text = "游戏正在渲染当前布局…"
		var result := await GamePreview.render(app.get_tree(), source, "screenLayout", snapshot, viewport, locale, keep)
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
		if row != snapshot or Vector2i(preview.viewport_size.round()) != viewport or preview.locale != locale:
			notice.text = "渲染期间布局或预览设置已变更，请重新预览。"
			return
		focus_test.button_pressed = false
		focus_test.hide()
		layout_scroll.hide()
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
	var save := func():
		if state.saving:
			return
		if not load_picture.call():
			return
		var key := id.text.strip_edges()
		var candidate := source.duplicate(true)
		stash.call()
		var updated := rows.duplicate(true)
		if state.row < 0:
			if key == "" or updated.any(func(row): return row.view_id == key):
				notice.text = "视图 ID 必须非空且唯一。"
				return
			updated.append(state.draft.duplicate(true))
		candidate["views"] = updated
		var errors: Array[Dictionary] = []
		Validation._validate_views(candidate, errors)
		if not errors.is_empty():
			notice.text = "%s：%s" % [errors[0].path, errors[0].message]
			return
		for ref in References.view_content_refs(candidate):
			if ref.view == key and Store.read_ex(source, ref.fn, ref.cid).status != "ok":
				notice.text = "%s 指向不存在或无法读取的内容。" % ref.path
				return
		var image_assets := Layout.image_assets(candidate)
		for ref in References.view_image_refs(candidate):
			if ref.view == key and not image_assets.has(ref.asset):
				notice.text = "%s 指向不存在的图片资产。" % ref.path
				return
		state.saving = true
		var ok: bool = await app._save_manifest_file_async(current, candidate, "views") if current.call() else false
		state.saving = false
		if not is_instance_valid(pop) or not pop.visible:
			return
		if not ok:
			notice.text = "视图未保存。请检查清单状态后重新打开。"
			return
		app._set_status("已保存参考视图：" + key)
		pop.hide()
	body.add_child(Kit.popup_buttons(save, func(): pop.hide(), "保存参考视图"))
	app._open_popup(pop, Vector2i(660, 620))

static func _render_layout(form: VBoxContainer, preview: Preview, state: Dictionary) -> void:
	for child in form.get_children():
		form.remove_child(child)
		child.queue_free()
	var refresh := _render_layout.bind(form, preview, state)
	var sizes: Dictionary = state.viewport_sizes
	var base := str(state.layout.get("viewport", ""))
	var fallback: Vector2 = sizes.get(base, Layout.FALLBACK_SIZE)
	preview.viewport_size = sizes.get(state.preview_size, fallback)
	preview.locale = state.locale
	preview.focus_layout = state.layout
	for element in preview.elements:
		_load_layout_image(preview, state, str(element.get("imageAsset", "")))
	if preview.focus_preview:
		var visible := Layout.visible_focus(preview.elements, preview.viewport_size)
		if not visible.any(func(row): return row.id == preview.focused_id):
			preview.focused_id = Layout.focus_start(state.layout, preview.elements, preview.viewport_size)
	preview.queue_redraw()
	if not preview.editing_layout:
		return
	var design := _viewport_option(sizes, base, "默认 1280 × 720")
	design.name = "LayoutDesignViewport"
	design.item_selected.connect(func(i: int):
		state.has_layout = true
		state.layout["viewport"] = design.get_item_metadata(i)
		refresh.call())
	form.add_child(Kit.field_row("设计画幅", design, 70))
	var compare := _viewport_option(sizes, str(state.preview_size), "使用设计画幅")
	compare.name = "LayoutPreviewViewport"
	compare.item_selected.connect(func(i: int):
		state.preview_size = compare.get_item_metadata(i)
		refresh.call())
	form.add_child(Kit.field_row("预览画幅", compare, 70))
	_add_locale_picker(form, state, refresh)
	var focus_start := _focus_options(preview.elements, str(state.layout.get("focusStart", "")), "首个可聚焦按钮")
	focus_start.name = "LayoutFocusStart"
	focus_start.item_selected.connect(func(i: int):
		var id: String = focus_start.get_item_metadata(i)
		if id == "":
			state.layout.erase("focusStart")
		else:
			state.layout["focusStart"] = id)
	form.add_child(Kit.field_row("初始焦点", focus_start, 70))
	if preview.elements.is_empty():
		form.add_child(Kit.hint_label("在画幅上拖动，添加一个布局元素。", 256))
		return
	var list := OptionButton.new()
	list.name = "LayoutElementList"
	for row in preview.elements:
		list.add_item("%s · %s" % [row.kind, row.id])
	list.select(preview.active_element)
	list.item_selected.connect(func(i: int):
		preview.active_element = i
		refresh.call())
	form.add_child(Kit.field_row("元素", list, 70))
	var at := preview.active_element
	if at < 0 or at >= preview.elements.size():
		return
	var item: Dictionary = preview.elements[at]
	var kind := OptionButton.new()
	kind.name = "LayoutElementKind"
	for type in Layout.KINDS:
		kind.add_item({"panel": "面板", "text": "文字", "button": "按钮"}[type])
	kind.select(Layout.KINDS.find(item.kind))
	kind.item_selected.connect(func(i: int):
		item["kind"] = Layout.KINDS[i]
		if item.kind != "button":
			item.erase("focusable")
			Layout.clear_focus_links(state.layout, preview.elements, item.id)
		refresh.call())
	form.add_child(Kit.field_row("类型", kind, 70))
	var overflow := Kit.hint_label("", 200)
	var refresh_text := func():
		overflow.text = "此画幅下文字超出元素范围。" if preview.text_overflows(item) else ""
		preview.queue_redraw()
	var locale: String = state.locale
	var authored_text := str(item.get("text", "")) if locale == "" else str(item.get("textLocales", {}).get(locale, ""))
	var text_input := LineEdit.new()
	text_input.name = "LayoutElement_text"
	text_input.text = authored_text.get_slice("\n", 0)
	if locale != "":
		text_input.placeholder_text = Layout.display_text(item, locale).get_slice("\n", 0)
	text_input.text_changed.connect(func(value: String):
		_set_layout_text(item, locale, value)
		refresh_text.call())
	form.add_child(Kit.field_row("原文" if locale == "" else locale, text_input, 70))
	var multi := TextEdit.new()
	multi.name = "LayoutMultilineText"
	multi.custom_minimum_size.y = 72
	multi.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	multi.text = authored_text
	multi.hide()
	var toggle := CheckButton.new()
	toggle.text = "多行编辑"
	toggle.button_pressed = "\n" in multi.text
	multi.visible = toggle.button_pressed
	text_input.get_parent().visible = not toggle.button_pressed
	toggle.toggled.connect(func(enabled: bool):
		var value := str(item.get("text", "")) if locale == "" else str(item.get("textLocales", {}).get(locale, ""))
		multi.text = value
		text_input.text = value.get_slice("\n", 0)
		text_input.get_parent().visible = not enabled
		multi.visible = enabled)
	multi.text_changed.connect(func():
		if toggle.button_pressed:
			_set_layout_text(item, locale, multi.text)
			refresh_text.call())
	form.add_child(toggle)
	form.add_child(multi)
	var style := LineEdit.new()
	style.name = "LayoutElement_style"
	style.text = str(item.get("style", ""))
	style.text_changed.connect(func(value: String): item["style"] = value)
	form.add_child(Kit.field_row("游戏样式 ID", style, 70))
	_add_image_fields(form, preview, state, item, refresh)
	var font_size := SpinBox.new()
	font_size.min_value = 8
	font_size.max_value = 256
	font_size.step = 1
	font_size.value = int(item.get("fontSize", Layout.DEFAULT_FONT_SIZE))
	font_size.value_changed.connect(func(value: float):
		item["fontSize"] = int(value)
		refresh_text.call())
	form.add_child(Kit.field_row("字号", font_size, 70))
	form.add_child(overflow)
	refresh_text.call()
	for axis in [["anchors", "锚点"], ["offsets", "像素偏移"]]:
		var key: String = axis[0]
		var values: Array = item.get(key, [0, 0, 0, 0]).duplicate()
		var controls := GridContainer.new()
		controls.columns = 2
		for i in 4:
			var sp := SpinBox.new()
			sp.name = "%s_%d" % [key, i]
			sp.prefix = ["左 ", "上 ", "右 ", "下 "][i]
			sp.min_value = 0.0 if key == "anchors" else -100000
			sp.max_value = 1.0 if key == "anchors" else 100000
			sp.allow_lesser = key == "offsets"
			sp.allow_greater = key == "offsets"
			sp.step = 0.0001 if key == "anchors" else 0.01
			sp.value = values[i]
			sp.value_changed.connect(func(value: float):
				values[i] = value
				item[key] = values
				refresh_text.call())
			controls.add_child(sp)
		form.add_child(Kit.field_row(str(axis[1]), controls, 70))
	var fixed_bottom := Kit.button("固定底边", func():
		var r := Layout.rect(item, fallback)
		var a: Array = item.anchors.duplicate()
		var o: Array = item.get("offsets", [0, 0, 0, 0]).duplicate()
		a[1] = 1.0
		a[3] = 1.0
		o[1] = r.position.y - fallback.y
		o[3] = r.end.y - fallback.y
		item["anchors"] = a
		item["offsets"] = o
		refresh.call(), "ghost")
	form.add_child(fixed_bottom)
	var target := OptionButton.new()
	target.name = "LayoutElementTarget"
	target.add_item("（无目标）")
	target.set_item_metadata(0, {})
	var selected := 0
	for option in state.targets:
		target.add_item(option.label)
		target.set_item_metadata(target.item_count - 1, option.value)
		if item.get("target") == option.value:
			selected = target.item_count - 1
	if item.has("target") and selected == 0 and not item.target.is_empty():
		target.add_item("（保留原目标）")
		selected = target.item_count - 1
		target.set_item_disabled(selected, true)
	target.select(selected)
	target.item_selected.connect(func(i: int):
		if i == 0:
			item.erase("target")
		elif target.get_item_metadata(i) is Dictionary:
			item["target"] = target.get_item_metadata(i))
	form.add_child(Kit.field_row("跳转内容", target, 70))
	if item.kind == "button":
		_add_focus_fields(form, preview, state, item, refresh)
	var actions := Kit.hbox(4)
	for delta in [-1, 1]:
		var to: int = at + delta
		var b := Kit.button("下移一层" if delta < 0 else "上移一层", func():
			preview.elements.remove_at(at)
			preview.elements.insert(to, item)
			preview.active_element = to
			refresh.call(), "ghost")
		b.disabled = to < 0 or to >= preview.elements.size()
		actions.add_child(b)
	actions.add_child(Kit.button("复制元素", func():
		var copy := item.duplicate(true)
		copy["id"] = _element_id(preview.elements)
		preview.elements.insert(at + 1, copy)
		preview.active_element = at + 1
		refresh.call(), "ghost"))
	actions.add_child(Kit.button("删除元素", func():
		Layout.clear_focus_links(state.layout, preview.elements, item.id)
		preview.elements.remove_at(at)
		preview.active_element = mini(at, preview.elements.size() - 1)
		refresh.call(), "ghost"))
	form.add_child(actions)

static func _element_id(elements: Array) -> String:
	var id := Id.new_inst_code()
	while elements.any(func(item): return item.id == id):
		id = Id.new_inst_code()
	return id

static func _load_layout_image(preview: Preview, state: Dictionary, id: String) -> void:
	if id == "" or preview.asset_textures.has(id) or not state.image_assets.has(id) or state.project_dir == "":
		return
	var rel := Layout.image_path(state.image_assets[id].get("texture"))
	var file: String = state.project_dir.path_join(rel)
	var image: Texture2D
	if FileAccess.file_exists(file):
		var raw := Image.load_from_file(file)
		if raw != null and not raw.is_empty():
			image = ImageTexture.create_from_image(raw)
	preview.asset_textures[id] = image

static func _add_image_fields(form: VBoxContainer, preview: Preview, state: Dictionary,
		item: Dictionary, refresh: Callable) -> void:
	var picker := OptionButton.new()
	picker.name = "LayoutImageAsset"
	picker.add_item("（无图片）")
	picker.set_item_metadata(0, "")
	var current := str(item.get("imageAsset", ""))
	var selected := 0
	for id in state.image_assets:
		var asset: Dictionary = state.image_assets[id]
		var disabled: bool = asset.get("disabled", false) == true
		if disabled and id != current:
			continue
		picker.add_item("%s · %s%s" % [asset.get("name", id), id, "（已停用）" if disabled else ""])
		var index := picker.item_count - 1
		picker.set_item_metadata(index, id)
		picker.set_item_disabled(index, disabled)
		if id == current:
			selected = index
	if current != "" and selected == 0:
		picker.add_item("（找不到图片：%s）" % current)
		selected = picker.item_count - 1
		picker.set_item_disabled(selected, true)
	picker.select(selected)
	picker.item_selected.connect(func(i: int):
		if i == 0:
			item.erase("imageAsset")
			item.erase("imageFit")
		else:
			item["imageAsset"] = picker.get_item_metadata(i)
		refresh.call())
	form.add_child(Kit.field_row("图片资产", picker, 70))
	if current == "":
		return
	var fit := OptionButton.new()
	fit.name = "LayoutImageFit"
	for i in Layout.IMAGE_FITS.size():
		fit.add_item(["完整显示", "裁切填满", "拉伸填满"][i])
		fit.set_item_metadata(i, Layout.IMAGE_FITS[i])
	fit.select(Layout.IMAGE_FITS.find(item.get("imageFit", "contain")))
	fit.item_selected.connect(func(i: int):
		item["imageFit"] = Layout.IMAGE_FITS[i]
		preview.queue_redraw())
	form.add_child(Kit.field_row("图片适配", fit, 70))
	if preview.asset_textures.get(current) == null:
		form.add_child(Kit.hint_label("无法预览所选图片，请检查资产源文件。", 230))

static func _set_layout_text(item: Dictionary, locale: String, value: String) -> void:
	if locale == "":
		item["text"] = value
		return
	var variants: Dictionary = item.get("textLocales", {})
	if value.is_empty():
		variants.erase(locale)
	else:
		variants[locale] = value
	if variants.is_empty():
		item.erase("textLocales")
	else:
		item["textLocales"] = variants

static func _add_locale_picker(form: VBoxContainer, state: Dictionary, refresh: Callable) -> void:
	var options := OptionButton.new()
	options.name = "LayoutLocale"
	options.add_item("原文")
	options.set_item_metadata(0, "")
	var selected := 0
	var locales: Array = state.layout.get("locales", [])
	for tag in locales:
		options.add_item(tag)
		options.set_item_metadata(options.item_count - 1, tag)
		if state.locale == tag:
			selected = options.item_count - 1
	options.select(selected)
	options.item_selected.connect(func(i: int):
		state.locale = options.get_item_metadata(i)
		refresh.call())
	form.add_child(Kit.field_row("文案语言", options, 70))
	var row := Kit.hbox(4)
	var input := LineEdit.new()
	input.name = "LayoutNewLocale"
	input.placeholder_text = "例如 zh-hans、en-us"
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(input)
	row.add_child(Kit.button("添加语言", func():
		var tag := Layout.locale_key(input.text)
		if not Layout.valid_locale(tag):
			input.tooltip_text = "请输入有效的语言标记，例如 zh-hans 或 en-us。"
			input.grab_focus()
			input.select_all()
			return
		if not locales.has(tag):
			locales.append(tag)
			state.layout["locales"] = locales
			state.has_layout = true
		state.locale = tag
		refresh.call(), "ghost"))
	form.add_child(row)

static func _add_focus_fields(form: VBoxContainer, preview: Preview, state: Dictionary,
		item: Dictionary, refresh: Callable) -> void:
	var button := CheckBox.new()
	button.text = "可用键盘或手柄聚焦"
	button.name = "LayoutElementFocusable"
	button.button_pressed = Layout.focusable(item)
	button.toggled.connect(func(enabled: bool):
		if enabled:
			item.erase("focusable")
		else:
			item["focusable"] = false
			Layout.clear_focus_links(state.layout, preview.elements, item.id)
		refresh.call())
	form.add_child(button)
	if not button.button_pressed:
		return
	for direction in ["up", "down", "left", "right"]:
		var current := str(item.get("focus", {}).get(direction, ""))
		var picker := _focus_options(preview.elements, current, "自动寻找")
		picker.name = "LayoutFocus_" + direction
		picker.item_selected.connect(func(i: int):
			var links: Dictionary = item.get("focus", {})
			var id: String = picker.get_item_metadata(i)
			if id == "":
				links.erase(direction)
			else:
				links[direction] = id
			if links.is_empty():
				item.erase("focus")
			else:
				item["focus"] = links
			preview.queue_redraw())
		form.add_child(Kit.field_row({"up": "方向 ↑", "down": "方向 ↓", "left": "方向 ←", "right": "方向 →"}[direction], picker, 70))

static func _focus_options(elements: Array, current: String, empty_label: String) -> OptionButton:
	var control := OptionButton.new()
	control.add_item(empty_label)
	control.set_item_metadata(0, "")
	var selected := 0
	for row in elements:
		if not Layout.focusable(row):
			continue
		var label := str(row.get("text", "")).strip_edges()
		control.add_item(str(row.id) if label == "" else "%s · %s" % [label, row.id])
		control.set_item_metadata(control.item_count - 1, row.id)
		if row.id == current:
			selected = control.item_count - 1
	control.select(selected)
	return control

static func _viewport_option(sizes: Dictionary, current: String, empty_label: String) -> OptionButton:
	var control := OptionButton.new()
	control.add_item(empty_label)
	control.set_item_metadata(0, "")
	var selected := 0
	for key in sizes:
		var dim: Vector2 = sizes[key]
		control.add_item("%s · %s × %s" % [key, dim.x, dim.y])
		control.set_item_metadata(control.item_count - 1, key)
		if key == current:
			selected = control.item_count - 1
	control.select(selected)
	return control
