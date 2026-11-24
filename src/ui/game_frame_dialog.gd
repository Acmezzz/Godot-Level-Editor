extends RefCounted
## Common single-frame UI. The caller owns snapshot construction and document identity.

const Kit := preload("res://src/ui/ui_kit.gd")
const GamePreview := preload("res://src/project/game_preview.gd")
const Layout := preload("res://src/project/screen_layout.gd")

static func keep_on_focus_loss(pop: PopupPanel) -> void:
	pop.popup_window = false
	pop.close_requested.connect(pop.hide)
	pop.window_input.connect(func(event: InputEvent):
		if event.is_action_pressed("ui_cancel"):
			pop.hide())

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
	var keep := func() -> bool:
		return is_instance_valid(pop) and pop.visible and is_same(app.manifest, manifest) and valid.call()
	render.pressed.connect(func():
		if render.disabled:
			return
		if not keep.call():
			pop.hide()
			return
		var preset: String = picker.get_selected_metadata()
		var built: Dictionary = snapshot.call(preset)
		if not built.has("subject"):
			notice.text = str(built.get("error", "无法读取当前工作副本。"))
			return
		var viewport := Vector2i((sizes.get(preset, built.default_size) as Vector2).round())
		var current: Callable = built.get("current", Callable())
		render.disabled = true
		picker.disabled = true
		frame.texture = null
		notice.text = "游戏正在渲染当前快照…"
		var result := await GamePreview.render(app.get_tree(), manifest, capability, built.subject, viewport, "", keep)
		if not keep.call():
			if is_instance_valid(pop) and pop.visible:
				pop.hide()
			return
		render.disabled = false
		picker.disabled = false
		if not result.has("image"):
			notice.text = result.error
			return
		if current.is_valid() and not current.call():
			notice.text = "内容在渲染期间已变更，请重新渲染。"
			return
		frame.texture = ImageTexture.create_from_image(result.image)
		notice.text = "游戏渲染快照 · %d × %d%s" % [viewport.x, viewport.y, built.get("summary", "")])
	picker.item_selected.connect(func(_i: int):
		frame.texture = null
		notice.text = "画幅已更改，请重新渲染。")
	var actions := Kit.hbox(8)
	actions.add_child(Kit.spacer())
	actions.add_child(Kit.button("关闭", pop.hide, "ghost"))
	actions.add_child(render)
	body.add_child(actions)
	app._open_popup(pop, Vector2i(740, 600))
