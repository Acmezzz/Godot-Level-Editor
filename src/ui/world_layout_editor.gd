extends VBoxContainer
## Draft edits stay in this popup until the manifest write succeeds.

const Kit := preload("res://src/ui/ui_kit.gd")
const Maps := preload("res://src/map/map_store.gd")
const Layout := preload("res://src/project/world_layout.gd")
const Preview := preload("res://src/project/game_preview.gd")
const FrameDialog := preload("res://src/ui/game_frame_dialog.gd")
const MapPreview := preload("res://src/ui/map_game_preview.gd")
const CAPABILITY := "worldFrame"

var _app
var _pop: PopupPanel
var _source: Dictionary
var _baseline: Dictionary
var _draft: Dictionary
var _options: OptionButton
var _surface: WorldCanvas
var _notice: Label
var _fields: Array[SpinBox] = []
var _generated_key: LineEdit
var _replace_legacy: Button
var _names := {}
var _selected := ""
var _saving := false

static func open(app) -> void:
	if not Layout.issues(app.manifest).is_empty():
		app._set_status("世界布局格式无效，未改动清单")
		return
	var shell: Dictionary = app._popup_body("项目世界布局",
		"选择地图添加分块，拖动分块或输入像素坐标。滚轮缩放，中键平移。")
	var ui := new()
	ui._app = app
	ui._pop = shell.pop
	ui._source = app.manifest
	ui._baseline = ui._source.get("worldLayout", {"version": 1, "chunks": {}}).duplicate(true)
	ui._draft = ui._baseline.duplicate(true)
	shell.body.add_child(ui)
	ui._build()
	app._open_popup(ui._pop)

func _build() -> void:
	var row := Kit.hbox(6)
	add_child(row)
	_options = OptionButton.new()
	_options.name = "WorldMapList"
	_options.size_flags_horizontal = SIZE_EXPAND_FILL
	row.add_child(_options)
	_options.item_selected.connect(func(i: int): _select(str(_options.get_item_metadata(i))))
	row.add_child(Kit.button("添加到世界", _add_chunk))
	row.add_child(Kit.button("移出世界", _remove_chunk))
	row.add_child(Kit.button("打开地图", _open_selected))
	row.add_child(Kit.button("适合窗口", func(): _surface.fit()))
	_surface = WorldCanvas.new()
	_surface.name = "WorldFootprints"
	_surface.custom_minimum_size = Vector2(550, 306)
	_surface.size_flags_vertical = SIZE_EXPAND_FILL
	_surface.chunks = _draft.chunks
	_surface.picked.connect(_select)
	_surface.moved.connect(_move)
	_surface.resized.connect(func():
		if not _surface.initialized and _surface.size.x >= 100.0:
			_surface.fit())
	add_child(_surface)
	var dimensions := Kit.hbox(4)
	add_child(dimensions)
	for i in 4:
		var field := SpinBox.new()
		field.name = ["WorldX", "WorldY", "WorldWidth", "WorldHeight"][i]
		field.min_value = -Layout.LIMIT if i < 2 else 1
		field.max_value = Layout.LIMIT
		field.size_flags_horizontal = SIZE_EXPAND_FILL
		field.value_changed.connect(_edit_number.bind(i))
		var labeled := Kit.field_row(["X", "Y", "宽", "高"][i], field, 20)
		labeled.size_flags_horizontal = SIZE_EXPAND_FILL
		dimensions.add_child(labeled)
		_fields.append(field)
	_generated_key = LineEdit.new()
	_generated_key.name = "WorldGeneratedKey"
	_generated_key.placeholder_text = "可选，例如 biome/2/0；留空为普通分块"
	_generated_key.max_length = Layout.GENERATED_KEY_LIMIT
	_generated_key.text_changed.connect(_edit_generated_key)
	add_child(Kit.field_row("生成分块键", _generated_key, 90))
	_replace_legacy = Kit.button("改为整块替换", _replace_legacy_mode)
	add_child(_replace_legacy)
	_notice = Label.new()
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_notice)
	var actions := Kit.popup_buttons(_save, func(): _pop.hide(), "保存世界布局")
	if Preview.supports(_source, CAPABILITY):
		FrameDialog.keep_on_focus_loss(_pop)
		var preview := Kit.button("游戏实景预览…", _open_preview, "ghost")
		actions.add_child(preview)
		actions.move_child(preview, 0)
	add_child(actions)
	_refresh_list()

func _refresh_list() -> void:
	var catalog := Maps.code_index(_source)
	_names.clear()
	for code in catalog.by_code:
		var names: Array = catalog.by_code[code]
		if names.size() == 1:
			_names[code] = names[0]
	var keys: Array = _names.keys()
	for code in _draft.chunks:
		if not _names.has(code):
			keys.append(code)
	keys.sort_custom(func(a, b): return str(_names.get(a, a)).naturalnocasecmp_to(str(_names.get(b, b))) < 0)
	_options.clear()
	for code in keys:
		var title := "%s · %s" % [_names.get(code, "地图缺失或重码"), code]
		_options.add_item(("● " if _draft.chunks.has(code) else "") + title)
		_options.set_item_metadata(_options.item_count - 1, code)
	_surface.names = _names
	var preferred := str(catalog.by_name.get(_app.cur_map_name, ""))
	_select(_selected if keys.has(_selected) else (preferred if keys.has(preferred) else str(keys.front()) if not keys.is_empty() else ""))

func _select(code: String) -> void:
	_selected = code
	_surface.selected = code
	for i in _options.item_count:
		if _options.get_item_metadata(i) == code:
			_options.select(i)
			break
	var chunk: Dictionary = _draft.chunks.get(code, {})
	for i in _fields.size():
		_fields[i].editable = not chunk.is_empty()
		_fields[i].set_value_no_signal(float(chunk.get("origin" if i < 2 else "size", [0, 0] if i < 2 else [128, 128])[i % 2]))
	_generated_key.editable = not chunk.is_empty()
	_generated_key.text = str(chunk.get("generatedKey", ""))
	_replace_legacy.visible = chunk.has("generatedMode")
	_surface.queue_redraw()

func _add_chunk() -> void:
	if _saving or not _names.has(_selected) or _draft.chunks.has(_selected):
		return
	var point := _surface.world_at(_surface.size * 0.5)
	_draft.chunks[_selected] = {"origin": [_coordinate(point.x), _coordinate(point.y)], "size": [128, 128]}
	_refresh_list()
	_surface.fit()

func _remove_chunk() -> void:
	if _saving or not _draft.chunks.erase(_selected):
		return
	_refresh_list()

func _coordinate(n: float) -> int:
	return clampi(roundi(n), -Layout.LIMIT, Layout.LIMIT)

func _move(code: String, at: Vector2) -> void:
	if _saving or not _draft.chunks.has(code):
		return
	_draft.chunks[code].origin = [_coordinate(at.x), _coordinate(at.y)]
	_select(code)

func _edit_number(value: float, i: int) -> void:
	if _saving or not _draft.chunks.has(_selected):
		return
	_draft.chunks[_selected]["origin" if i < 2 else "size"][i % 2] = int(value)
	_surface.queue_redraw()

func _edit_generated_key(value: String) -> void:
	if _saving or not _draft.chunks.has(_selected):
		return
	var row: Dictionary = _draft.chunks[_selected]
	var key := value.strip_edges()
	if key.is_empty():
		row.erase("generatedKey")
		row.erase("generatedMode")
	else:
		row["generatedKey"] = key
	_replace_legacy.visible = row.has("generatedMode")
	_surface.queue_redraw()

func _replace_legacy_mode() -> void:
	if _saving or not _draft.chunks.has(_selected):
		return
	_draft.chunks[_selected].erase("generatedMode")
	_replace_legacy.hide()
	_notice.text = "保存后游戏将使用整张作者地图覆盖此分块。原地图和生成基线不变。"

func _open_selected() -> void:
	if _saving:
		return
	if _draft != _baseline:
		_notice.text = "请先保存世界布局，再打开地图。"
		return
	var matches: Array = Maps.code_index(_source).by_code.get(_selected, [])
	if matches.size() != 1:
		_notice.text = "地图不存在或地图码重复。"
		return
	var host = _app
	var target := str(matches[0])
	_pop.hide()
	await host._open_map_by_name(target)
	if host.cur_map_name == target:
		host._set_mode("map")

func _save() -> void:
	if _saving or _draft == _baseline:
		return
	var candidate := _source.duplicate(true)
	candidate["worldLayout"] = _draft.duplicate(true)
	var issues := Layout.issues(candidate)
	if not issues.is_empty():
		var issue: Dictionary = issues[0]
		_notice.text = "布局未保存：%s · %s" % [issue.path, issue.message]
		return
	_saving = true
	var ok: bool = await _app._save_manifest_file_async(_can_save, candidate, "worldLayout") if _can_save() else false
	_saving = false
	if not is_instance_valid(_pop) or not _pop.visible:
		return
	if ok:
		_baseline = _draft.duplicate(true)
		_notice.text = "已保存世界布局。可继续编辑或打开选中的地图。"
	else:
		_notice.text = "世界布局未保存。草稿仍可编辑；如果已有其他布局写入，请重新打开。"

func _can_save() -> bool:
	return _is_open() \
		and _source.get("worldLayout", {"version": 1, "chunks": {}}) == _baseline

func _is_open() -> bool:
	return is_instance_valid(_pop) and _pop.visible and is_same(_app.manifest, _source)

func _open_preview() -> void:
	if _saving:
		return
	if _draft.chunks.is_empty():
		_notice.text = "请先添加至少一张地图。"
		return
	FrameDialog.open(_app, CAPABILITY, {"title": "世界游戏实景预览", "button": "渲染世界",
		"hint": "按当前的世界布局取景，由游戏选择并绘制分块。无需先保存布局或当前关卡。",
		"prefix": "WorldGamePreview", "default_label": "布局画布大小",
		"initial": "缩放和中心来自世界布局画布，切换画幅改变可见范围。"}, _capture_preview, _is_open)

func _capture_preview(preset: String) -> Dictionary:
	var public: Dictionary = _app._manifest_write_payload(_source)
	public["worldLayout"] = _draft.duplicate(true)
	var camera := _surface.camera()
	var session = _app._map_file_ctrl.sess
	var generation: int = session.generation
	var revision: int = session.revision
	var overrides := {}
	var code: String = _app.canvas.cur_map_code() if _app.map_loaded else ""
	if _draft.chunks.has(code):
		var context := MapPreview.map_context(_app)
		if context.is_empty():
			return {"error": "当前分块正在重建，请稍后重试。"}
		overrides[code] = {"map": context.map, "stagedContent": context.stagedContent}
	var subject := {"manifest": public, "camera": camera, "viewportId": preset, "overrides": overrides}
	return {"subject": subject, "default_size": _surface.size,
		"current": func(): return not session.stale(generation) and session.revision == revision \
			and _draft == public.worldLayout and _surface.camera() == camera}

class WorldCanvas extends Control:
	signal picked(code: String)
	signal moved(code: String, at: Vector2)
	var chunks := {}
	var names := {}
	var selected := ""
	var initialized := false
	var _offset := Vector2.ZERO
	var _zoom := 1.0
	var _drag := ""
	var _delta := Vector2.ZERO

	func world_at(point: Vector2) -> Vector2:
		return (point - _offset) / _zoom

	func camera() -> Dictionary:
		var center := world_at(size * 0.5)
		return {"center": [center.x, center.y], "zoom": _zoom}

	func fit() -> void:
		var bounds := Rect2()
		var first := true
		for row in chunks.values():
			var rect := Layout.rect(row)
			bounds = rect if first else bounds.merge(rect)
			first = false
		_zoom = 1.0 if first else clampf(minf((size.x - 40) / bounds.size.x, (size.y - 40) / bounds.size.y), 0.000001, 8.0)
		_offset = size * 0.5 - bounds.get_center() * _zoom
		initialized = true
		queue_redraw()

	func _ready() -> void:
		clip_contents = true

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color("#151e2b"))
		var origin := _offset
		draw_line(Vector2(0, origin.y), Vector2(size.x, origin.y), Color("#405571"))
		draw_line(Vector2(origin.x, 0), Vector2(origin.x, size.y), Color("#405571"))
		var font := get_theme_default_font()
		for code in _ordered():
			var rect := Layout.rect(chunks[code])
			rect = Rect2(rect.position * _zoom + origin, rect.size * _zoom)
			if not rect.intersects(Rect2(Vector2.ZERO, size)):
				continue
			var tint := Color("#7bdaec") if code == selected else Color("#809cbf")
			if not names.has(code):
				tint = Color("#ffac7e")
			draw_rect(rect, Color(tint, 0.30))
			draw_rect(rect, tint, false, 2.0)
			if rect.size.x >= 32 and rect.size.y >= 23:
				var label := str(names.get(code, code))
				if chunks[code].has("generatedKey"):
					label += " · " + str(chunks[code].generatedKey)
				draw_string(font, rect.position + Vector2(5, 17), label, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 10, 14, tint)

	func _ordered() -> Array:
		var order := chunks.keys()
		if chunks.has(selected):
			order.erase(selected)
			order.append(selected)
		return order

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			var point := world_at(event.position)
			if event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
				_zoom = clampf(_zoom * (1.25 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 0.8), 0.000001, 16.0)
				_offset = event.position - point * _zoom
				queue_redraw()
			elif event.button_index == MOUSE_BUTTON_LEFT:
				_drag = ""
				if event.pressed:
					var order := _ordered()
					order.reverse()
					for code in order:
						var rect := Layout.rect(chunks[code])
						if rect.has_point(point):
							_drag = code
							_delta = point - rect.position
							picked.emit(code)
							break
			else:
				return
			accept_event()
		elif event is InputEventMouseMotion:
			if event.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
				_offset += event.relative
				queue_redraw()
			elif _drag != "" and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
				moved.emit(_drag, world_at(event.position) - _delta)
