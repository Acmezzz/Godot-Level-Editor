extends RefCounted
## Builds layout controls and commits declared module fields into the current draft.

const Kit := preload("res://src/ui/ui_kit.gd")
const Layout := preload("res://src/project/screen_layout.gd")
const References := preload("res://src/project/reference_index.gd")
const Widgets := preload("res://src/ui/field_widgets.gd")
const RefFields := preload("res://src/content/ref_fields.gd")
const MapPreview := preload("res://src/ui/map_game_preview.gd")
const Preview := preload("res://src/ui/screen_layout_canvas.gd")
const FlowTarget := preload("res://src/content/flow_target.gd")
const Targets := preload("res://src/project/startup_targets.gd")

static func render(form: VBoxContainer, preview: Preview, state: Dictionary) -> void:
	preview.cancel_placement()
	commit_fields(state)
	state.module_commits.clear()
	for child in form.get_children():
		form.remove_child(child)
		child.queue_free()
	var refresh := render.bind(form, preview, state)
	var sizes: Dictionary = state.viewport_sizes
	var base := str(state.layout.get("viewport", ""))
	var fallback: Vector2 = sizes.get(base, Layout.FALLBACK_SIZE)
	preview.profile = state.preview_size
	preview.viewport_size = sizes.get(state.preview_size, fallback)
	preview.locale = state.locale
	preview.focus_layout = state.layout
	for element in preview.elements:
		_load_layout_image(preview, state, str(element.get("imageAsset", "")))
	if preview.focus_preview:
		var visible := Layout.visible_focus(preview.elements, preview.viewport_size, preview.profile)
		if not visible.any(func(row): return row.id == preview.focused_id):
			preview.focused_id = Layout.focus_start(state.layout, preview.elements, preview.viewport_size, preview.profile)
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
	var compare := _viewport_option(sizes, preview.profile, "基础布局（设计画幅）")
	compare.name = "LayoutPreviewViewport"
	compare.item_selected.connect(func(i: int):
		state.preview_size = compare.get_item_metadata(i)
		refresh.call())
	form.add_child(Kit.field_row("布局画幅", compare, 70))
	if preview.profile != "":
		form.add_child(Kit.hint_label("锚点、偏移和显隐只覆盖此画幅；父级、模块属性、文案和连线共用。", 260))
	_add_locale_picker(form, state, refresh)
	var focus_start := _focus_options(preview.elements, str(state.layout.get("focusStart", "")), "首个可聚焦元素")
	focus_start.name = "LayoutFocusStart"
	focus_start.item_selected.connect(func(i: int):
		var id: String = focus_start.get_item_metadata(i)
		if id == "":
			state.layout.erase("focusStart")
		else:
			state.layout["focusStart"] = id)
	form.add_child(Kit.field_row("初始焦点", focus_start, 70))
	if preview.elements.is_empty():
		form.add_child(Kit.hint_label("关闭「调整元素」，在画幅上拖动可添加布局元素。", 256))
		return
	var list := OptionButton.new()
	list.name = "LayoutElementList"
	for row in preview.elements:
		list.add_item("%s · %s" % [row.get("module", row.kind), row.id])
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
		kind.set_item_metadata(kind.item_count - 1, {"kind": type})
	var selected_kind: int = Layout.KINDS.find(item.kind)
	for module in state.modules:
		var descriptor: Dictionary = state.modules[module]
		kind.add_item("模块 · " + str(descriptor.get("name", module)))
		kind.set_item_metadata(kind.item_count - 1, {"kind": "module", "module": module})
		if item.kind == "module" and item.module == module:
			selected_kind = kind.item_count - 1
	kind.select(selected_kind)
	kind.item_selected.connect(func(i: int):
		var next: Dictionary = kind.get_item_metadata(i)
		if item.kind == next.kind and item.get("module") == next.get("module"):
			return
		commit_fields(state)
		item.erase("module")
		item.erase("props")
		item.erase("outputs")
		item.erase("focusable")
		Layout.clear_focus_links(state.layout, preview.elements, item.id)
		item.merge(next, true)
		refresh.call())
	form.add_child(Kit.field_row("类型", kind, 70))
	if item.kind == "module":
		_add_module_fields(form, state, item, refresh)
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
	var profile := preview.profile
	var parent_picker := OptionButton.new()
	parent_picker.name = "LayoutElementParent"
	parent_picker.add_item("画幅")
	parent_picker.set_item_metadata(0, "")
	var subtree := Layout.subtree_ids(preview.elements, item.id)
	for row in preview.elements:
		if subtree.has(row.id):
			continue
		var caption := Layout.display_text(row, preview.locale).get_slice("\n", 0)
		parent_picker.add_item(row.id if caption == "" else "%s · %s" % [row.id, caption])
		var index := parent_picker.item_count - 1
		parent_picker.set_item_metadata(index, row.id)
		if row.id == item.get("parent", ""):
			parent_picker.select(index)
	parent_picker.item_selected.connect(func(i: int):
		var parent: String = parent_picker.get_item_metadata(i)
		Layout.reparent(preview.elements, [item], parent, fallback, sizes)
		refresh.call())
	form.add_child(Kit.field_row("布局父级", parent_picker, 70))
	var shown := CheckBox.new()
	shown.name = "LayoutElementVisible"
	shown.button_pressed = not Layout.geometry_value(item, profile, "hidden", false)
	shown.toggled.connect(func(value: bool):
		Layout.set_geometry(item, profile, "hidden", not value)
		refresh.call())
	form.add_child(Kit.field_row("显示元素", shown, 70))
	var reset: Button
	if profile != "":
		reset = Kit.button("恢复此画幅的继承", func():
			Layout.clear_variant(item, profile)
			refresh.call(), "ghost")
		reset.disabled = not item.get("variants", {}).has(profile)
		form.add_child(reset)
	for axis in [["anchors", "锚点"], ["offsets", "像素偏移"]]:
		var key: String = axis[0]
		var values: Array = Layout.geometry_value(item, profile, key, Layout.ZERO_OFFSETS).duplicate()
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
				Layout.set_geometry(item, profile, key, values)
				if profile != "":
					reset.disabled = false
				refresh_text.call())
			controls.add_child(sp)
		form.add_child(Kit.field_row(str(axis[1]), controls, 70))
	var fixed_bottom := Kit.button("固定底边", func():
		var viewport := preview.viewport_size
		var resolved := Layout.rectangles(preview.elements, viewport, profile, true)
		var r: Rect2 = resolved[item.id]
		var reference: Rect2 = resolved.get(item.get("parent", ""), Rect2(Vector2.ZERO, viewport))
		var a: Array = Layout.geometry_value(item, profile, "anchors", []).duplicate()
		a[1] = 1.0
		a[3] = 1.0
		Layout.set_geometry(item, profile, "anchors", a)
		Layout.place(item, profile, r, reference)
		refresh.call(), "ghost")
	form.add_child(fixed_bottom)
	var outlets := Layout.output_labels(state.modules, item) if item.kind == "module" else {}
	if outlets.is_empty() or item.has("target"):
		_add_element_target(form, state.targets, item, "", "跳转目标")
	for output in outlets:
		var spec = Layout.output_spec(state.modules, item, output)
		var options: Array = state.named_targets.filter(func(option):
			return FlowTarget.allows(spec, option.value)) if spec is Dictionary else state.targets
		if spec is Dictionary:
			for arrival in Targets.arrival_options(state.manifest, spec):
				options.append({"label": arrival.name, "value": arrival.target})
		_add_element_target(form, options, item, output, outlets[output])
	if item.kind in ["button", "module"]:
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
		commit_fields(state)
		var copy := item.duplicate(true)
		copy["id"] = Layout.new_element_id(preview.elements)
		preview.elements.insert(at + 1, copy)
		preview.active_element = at + 1
		refresh.call(), "ghost"))
	actions.add_child(Kit.button("删除元素", func():
		var parent: String = item.get("parent", "")
		var children := preview.elements.filter(func(row): return row.get("parent") == item.id)
		Layout.reparent(preview.elements, children, parent, fallback, sizes)
		Layout.clear_focus_links(state.layout, preview.elements, item.id)
		preview.elements.remove_at(at)
		preview.active_element = mini(at, preview.elements.size() - 1)
		refresh.call(), "ghost"))
	form.add_child(actions)

static func _add_element_target(form: VBoxContainer, options: Array, item: Dictionary,
		output: String, label: String) -> void:
	var target := OptionButton.new()
	target.name = "LayoutElementTarget" if output.is_empty() else "LayoutOutput_" + output.validate_node_name()
	target.add_item("（无目标）")
	target.set_item_metadata(0, {})
	var current = Layout.target_at(item, output)
	var selected := 0
	for option in options:
		target.add_item(option.label)
		target.set_item_metadata(target.item_count - 1, option.value)
		if current == option.value:
			selected = target.item_count - 1
	if selected == 0 and current is Dictionary and not current.is_empty():
		target.add_item("（保留原目标）")
		selected = target.item_count - 1
		target.set_item_disabled(selected, true)
	target.select(selected)
	target.item_selected.connect(func(i: int):
		var value = target.get_item_metadata(i)
		if value is Dictionary:
			Layout.set_target(item, output, value))
	form.add_child(Kit.field_row(label, target, 70))

static func _add_module_fields(form: VBoxContainer, state: Dictionary, item: Dictionary, refresh: Callable) -> void:
	var fields: Array = state.modules[item.module].get("fields", [])
	var session := {"queued": false}
	var props: Dictionary = item.get("props", {})
	var frame_pick := func(row: Control, decl: Dictionary, pair: Callable, commit: Callable, read: Callable):
		var apply := func(next) -> bool:
			commit_fields(state)
			var result = commit.call(next)
			return not result is bool or result
		MapPreview.add_reference_button(state.app, row, decl, pair, apply, state.resolve_options,
			true, refresh, "", read, true)
	for field: Dictionary in fields:
		var id: String = field.id
		var value = props.get(id, field.get("default"))
		var scoped := RefFields.with_map_scope(field, fields, props, "id", true)
		var set_value := func(next):
			var previous = props.get(id, field.get("default"))
			item["props"] = props
			props[id] = next
			if not session.queued and _module_map_values(state.manifest, field, id, previous) \
					!= _module_map_values(state.manifest, field, id, next):
				session.queued = true
				refresh.call_deferred()
		var built := Widgets.build(scoped, value, set_value, state.resolve_options, "id", frame_pick)
		var ctl: Control = built.ctl
		ctl.name = "LayoutModuleField_" + id
		var row := Kit.field_row(str(field.get("name", id)), ctl, 70)
		row.set_meta("module_field", id)
		form.add_child(row)
		if Widgets.wants_frame_pick(field) and Widgets.frame_value_available(field, built):
			var pair := func() -> Array[String]: return RefFields.frame_scope(field, fields, props, "id", true)
			frame_pick.call(row, field, pair, set_value, built.get("pick_values", Callable()))
		state.module_commits.append(built.get("commit", Callable()))

static func _module_map_values(manifest: Dictionary, decl: Dictionary, id: String, value: Variant) -> Array:
	if decl.get("type") != "array" and RefFields.describe(decl).kind != "map":
		return []
	return References.property_refs(manifest, [decl], {id: value}) \
		.filter(func(ref): return ref.kind == "map").map(func(ref): return [ref.path, ref.value])

static func commit_fields(state: Dictionary) -> void:
	for commit: Callable in state.module_commits:
		if commit.is_valid():
			commit.call()

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
		if enabled and item.kind == "button":
			item.erase("focusable")
		else:
			item["focusable"] = enabled
		if not enabled:
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
