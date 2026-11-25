extends RefCounted
## Common single-frame UI. The caller owns snapshot construction and document identity.

const Kit := preload("res://src/ui/ui_kit.gd")
const GamePreview := preload("res://src/project/game_preview.gd")
const FramePicks := preload("res://src/project/frame_picks.gd")
const Layout := preload("res://src/project/screen_layout.gd")

static func keep_on_focus_loss(pop: PopupPanel, cancel := Callable()) -> void:
	pop.popup_window = false
	pop.close_requested.connect(pop.hide)
	pop.window_input.connect(func(event: InputEvent):
		if event.is_action_pressed("ui_cancel"):
			if cancel.is_valid() and cancel.call():
				pop.set_input_as_handled()
			else:
				pop.hide())

static func visible_request(window: WeakRef, current: Callable) -> Callable:
	return func() -> bool:
		var owner: Window = window.get_ref()
		return owner != null and owner.visible and current.call()

static func open(app, capability: String, options: Dictionary, snapshot: Callable, valid: Callable) -> void:
	var manifest: Dictionary = app.manifest
	var shell: Dictionary = app._popup_body(options.title, options.hint)
	var pop: PopupPanel = shell.pop
	keep_on_focus_loss(pop)
	var body: VBoxContainer = shell.body
	(shell.root as VBoxContainer).size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var sizes := Layout.sizes(manifest)
	var picker := OptionButton.new()
	picker.name = options.prefix + "Viewport"
	picker.add_item(options.default_label)
	picker.set_item_metadata(0, "")
	for id in sizes:
		var size: Vector2 = sizes[id]
		picker.add_item("%s · %d × %d" % [id, size.x, size.y])
		picker.set_item_metadata(picker.item_count - 1, id)
	body.add_child(Kit.field_row("出图画幅", picker, 82))
	var sample: LineEdit
	if options.has("sample"):
		sample = LineEdit.new()
		sample.name = options.prefix + "Time"
		sample.text = str(options.sample.value)
		body.add_child(Kit.field_row("取样 · " + str(options.sample.unit), sample, 82))
	var camera_fields: Array[LineEdit] = []
	var camera_reset: Button
	if options.get("camera", false):
		var camera_row := Kit.hbox(8)
		for label in ["X", "Y", "Zoom"]:
			var field := LineEdit.new()
			field.name = options.prefix + "Camera" + label
			field.placeholder_text = "沿用默认"
			field.tooltip_text = "每个世界像素对应的输出像素；留空用默认缩放" if label == "Zoom" \
				else "地图根空间中心的 %s 像素坐标；留空用默认中心" % label
			camera_fields.append(field)
			camera_row.add_child(Kit.field_row("缩放" if label == "Zoom" else label, field, 32))
		for child in camera_row.get_children():
			child.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		camera_reset = Kit.button("默认取景", Callable(), "ghost")
		camera_reset.name = options.prefix + "CameraReset"
		camera_row.add_child(camera_reset)
		body.add_child(Kit.field_row("取景中心", camera_row, 82))
	var frame := TextureRect.new()
	frame.name = options.prefix + "Frame"
	frame.custom_minimum_size.y = 260
	frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	body.add_child(frame)
	var notice := Kit.hint_label(str(options.get("initial", "")), 510)
	body.add_child(notice)
	var render := Kit.button(options.button, Callable(), "primary")
	render.name = options.prefix + "Render"
	var mode := str(options.get("pick_mode", ""))
	var pick_layer := str(options.get("pick_layer", ""))
	var choose: Callable = options.get("pick", Callable())
	var draw_shape: Callable = options.get("draw_shape", Callable())
	var drafting := draw_shape.is_valid()
	var interaction = options.get("interaction")
	var confirm := Kit.button(str(options.get("confirm_label", "创建形状" if drafting else "确认选点")), Callable(), "primary")
	confirm.name = options.prefix + "ConfirmPick"
	confirm.disabled = true
	var picks := {"regions": [], "selected": {}, "draft": [], "apply": Callable(), "current": Callable()}
	var clear_selection := func():
		picks.selected = {}
		picks.draft.clear()
		if interaction != null:
			interaction.clear()
		picks.apply = Callable()
		confirm.disabled = true
		frame.queue_redraw()
	var reset := func():
		picks.regions = []
		picks.current = Callable()
		clear_selection.call()
		frame.texture = null
	var window: WeakRef = weakref(pop)
	var keep := visible_request(window, func(): return is_same(app.manifest, manifest) and valid.call())
	var render_frame := func():
		if render.disabled:
			return
		if not keep.call():
			var owner: Window = window.get_ref()
			if owner != null:
				owner.hide()
			return
		reset.call()
		var preset: String = picker.get_selected_metadata()
		var built: Dictionary = snapshot.call(preset, sample.text) if sample != null else snapshot.call(preset)
		if not built.has("subject"):
			notice.text = str(built.get("error", "无法读取当前工作副本。"))
			return
		if not camera_fields.is_empty():
			var camera := _sample_camera(built.subject.camera, camera_fields)
			if camera.is_empty():
				notice.text = "取景中心须为有限数字，缩放须大于零；也可留空使用默认值。"
				return
			# Snapshot validity still compares the original map context and canvas camera.
			built.subject = built.subject.merged({"camera": camera}, true)
			built.summary = " · 中心 (%s, %s) · 缩放 ×%s" % [camera.center[0], camera.center[1], camera.zoom]
		var viewport := Vector2i((sizes.get(preset, built.default_size) as Vector2).round())
		var current: Callable = built.get("current", Callable())
		render.disabled = true
		picker.disabled = true
		if sample != null:
			sample.editable = false
		for field in camera_fields:
			field.editable = false
		if camera_reset != null:
			camera_reset.disabled = true
		notice.text = "游戏正在渲染当前快照…"
		var result := await GamePreview.render(app.get_tree(), manifest, capability, built.subject, viewport, "", keep)
		if not keep.call():
			var owner: Window = window.get_ref()
			if owner != null:
				owner.hide()
			return
		render.disabled = false
		picker.disabled = false
		if sample != null:
			sample.editable = true
		for field in camera_fields:
			field.editable = true
		if camera_reset != null:
			camera_reset.disabled = false
		if not result.has("image"):
			notice.text = result.error
			return
		if current.is_valid() and not current.call():
			notice.text = "内容在渲染期间已变更，请重新渲染。"
			return
		frame.texture = ImageTexture.create_from_image(result.image)
		notice.text = "游戏渲染快照 · %d × %d%s" % [viewport.x, viewport.y, built.get("summary", "")]
		if mode != "":
			picks.current = current
			picks.regions = result.get("picks", [])
			if options.has("on_picks"):
				options.on_picks.call(picks.regions)
				frame.queue_redraw()
			var pick_error: String = result.get("pick_error", "")
			if pick_error != "":
				notice.text = pick_error
			elif picks.regions.is_empty():
				notice.text += " · 游戏未提供可拾取区域"
			elif mode == "collision" and not picks.regions.any(func(region): return not region.collision.is_empty()):
				notice.text += " · 游戏未提供根空间映射"
			elif pick_layer != "" and not picks.regions.any(func(region): return region.placement.get("layer") == pick_layer):
				notice.text += " · 游戏未提供所选图层的映射"
			elif interaction != null:
				notice.text = interaction.message()
			else:
				notice.text += (" · 左键描点，右键撤末点" if drafting else " · 点击画面后确认")
	render.pressed.connect(render_frame)
	if camera_reset != null:
		var camera_changed := func():
			reset.call()
			notice.text = "取景已更改，请重新渲染。"
		for field in camera_fields:
			field.text_changed.connect(func(_value: String): camera_changed.call())
			field.text_submitted.connect(func(_value: String): render_frame.call())
		camera_reset.pressed.connect(func():
			for field in camera_fields:
				field.clear()
			camera_changed.call()
			render_frame.call())
	if sample != null:
		sample.text_changed.connect(func(_value: String):
			reset.call()
			notice.text = "取样位置已更改，请重新渲染。")
		sample.text_submitted.connect(func(_value: String): render_frame.call())
	picker.item_selected.connect(func(_i: int):
		reset.call()
		notice.text = "画幅已更改，请重新渲染。")
	if mode != "":
		frame.mouse_filter = Control.MOUSE_FILTER_STOP
		var is_current := func() -> bool:
			return keep.call() and (not picks.current.is_valid() or picks.current.call())
		var set_draft_action := func():
			var option: Dictionary = draw_shape.call(picks.draft)
			notice.text = option.text
			picks.apply = option.get("apply", Callable())
			confirm.disabled = not picks.apply.is_valid()
			frame.queue_redraw()
		if interaction != null:
			frame.gui_input.connect(func(event: InputEvent):
				if not event is InputEventMouseButton or frame.texture == null or picks.regions.is_empty():
					return
				if not is_current.call():
					clear_selection.call()
					notice.text = "内容已变更，请重新渲染。"
					return
				var rect := _image_rect(frame)
				var pixel: Vector2 = (event.position - rect.position) / rect.size * frame.texture.get_size()
				if interaction.input(event, pixel, picks.regions):
					notice.text = interaction.message()
					confirm.disabled = not interaction.ready()
					picks.apply = interaction.apply
					frame.queue_redraw())
			frame.draw.connect(func():
				if frame.texture != null:
					interaction.draw(frame, _image_rect(frame)))
		frame.gui_input.connect(func(event: InputEvent):
			if interaction != null:
				return
			if not event is InputEventMouseButton or not event.pressed or frame.texture == null or picks.regions.is_empty():
				return
			if not is_current.call():
				clear_selection.call()
				notice.text = "内容已变更，请重新渲染。"
				return
			if drafting and event.button_index == MOUSE_BUTTON_RIGHT:
				if not picks.draft.is_empty():
					picks.draft.pop_back()
					set_draft_action.call()
				return
			if event.button_index != MOUSE_BUTTON_LEFT:
				return
			if not drafting:
				clear_selection.call()
			var rect := _image_rect(frame)
			if not rect.has_point(event.position):
				notice.text = "请点击画面内的区域。"
				return
			var pixel: Vector2 = (event.position - rect.position) / rect.size * frame.texture.get_size()
			var hit := FramePicks.at(picks.regions, pixel, mode, pick_layer)
			if hit.is_empty():
				notice.text = "这里没有此工具需要的目标。"
				return
			if drafting:
				if not picks.draft.is_empty() and hit.value.layer != picks.draft[0].value.layer:
					notice.text = "同一形状的顶点必须映射到同一图层。"
					return
				if picks.draft.size() >= int(options.max_points):
					notice.text = "顶点已到上限，右键撤末点。"
					return
				hit["pixel"] = pixel
				picks.draft.append(hit)
				set_draft_action.call()
				return
			var option: Dictionary = choose.call(hit.value)
			notice.text = option.get("text", "此目标不适用于当前字段或资产。")
			if option.has("apply"):
				picks.selected = hit
				picks.apply = option.apply
				confirm.disabled = false
			frame.queue_redraw())
		frame.draw.connect(func():
			if picks.selected.is_empty() and picks.draft.is_empty():
				return
			var rect := _image_rect(frame)
			var scale := rect.size / frame.texture.get_size()
			var line := PackedVector2Array()
			if drafting:
				for hit in picks.draft:
					var point: Vector2 = rect.position + hit.pixel * scale
					line.append(point)
					frame.draw_circle(point, 4.0, Color(1.0, 0.83, 0.35))
				if options.get("closed", false) and line.size() > 2:
					line.append(line[0])
				if line.size() >= 2:
					frame.draw_polyline(line, Color(1.0, 0.83, 0.35), 2.0, true)
				return
			for pixel: Vector2 in picks.selected.screen:
				line.append(rect.position + pixel * scale)
			line.append(line[0])
			frame.draw_polyline(line, Color(1.0, 0.83, 0.35), 2.0, true))
		confirm.pressed.connect(func():
			if confirm.disabled or not picks.apply.is_valid():
				return
			if not is_current.call():
				clear_selection.call()
				notice.text = "内容已变更，请重新渲染。"
				return
			confirm.disabled = true
			var applied: bool = await picks.apply.call()
			if not is_instance_valid(pop) or not pop.visible:
				return
			if applied:
				pop.hide()
			else:
				clear_selection.call()
				notice.text = "选点未写入，请核对当前资产、图层或字段。")
	var actions := Kit.hbox(8)
	actions.set_meta("dialog_actions", true)
	actions.add_child(Kit.spacer())
	actions.add_child(Kit.button("关闭", pop.hide, "ghost"))
	actions.add_child(render)
	confirm.visible = mode != ""
	actions.add_child(confirm)
	body.add_child(actions)
	app._open_popup(pop, Vector2i(740, 600), options.get("parent"))

static func _sample_camera(defaults: Dictionary, fields: Array[LineEdit]) -> Dictionary:
	var values := [defaults.center[0], defaults.center[1], defaults.zoom]
	for i in fields.size():
		var field := fields[i]
		field.placeholder_text = str(values[i])
		var text := field.text.strip_edges()
		if text.is_empty():
			continue
		if not text.is_valid_float():
			return {}
		var value := float(text)
		if not is_finite(value) or (i == 2 and value <= 0.0):
			return {}
		values[i] = value
	return {"center": values.slice(0, 2), "zoom": values[2]}

static func _image_rect(frame: TextureRect) -> Rect2:
	var image_size := frame.texture.get_size()
	var scale := minf(frame.size.x / image_size.x, frame.size.y / image_size.y)
	var fitted := image_size * scale
	return Rect2((frame.size - fitted) * 0.5, fitted)
