extends VBoxContainer

const Kit := preload("res://src/ui/ui_kit.gd")
const Fields := preload("res://src/ui/field_widgets.gd")
const Generators := preload("res://src/project/map_generators.gd")
const Runner := preload("res://src/project/game_preview.gd")
const FrameDialog := preload("res://src/ui/game_frame_dialog.gd")
const Maps := preload("res://src/map/map_store.gd")

var _app
var _source: Dictionary
var _pop: PopupPanel
var _picker: OptionButton
var _preset: OptionButton
var _preset_row: Control
var _name_input: LineEdit
var _params: VBoxContainer
var _generate: Button
var _accept: Button
var _status: Label
var _values := {}
var _commits: Array[Callable] = []
var _result := {}
var _running := false
var _opening := false
var _origin := {}

static func available(app) -> bool:
	var manifest: Dictionary = app.manifest
	return Runner.supports(manifest, Runner.GENERATE_MAP) and Generators.issues(manifest).is_empty() \
		and not manifest.get("mapGenerators", {}).is_empty()

static func can_regenerate(app) -> bool:
	if not app.map_loaded or not available(app):
		return false
	var row := Generators.origin(app.canvas.map_data)
	return row.get("generator") is String and row.get("parameters") is Dictionary \
		and app.manifest.mapGenerators.has(row.generator)

static func open(app, regenerate := false) -> void:
	if not available(app):
		app._set_status("游戏清单未声明可用的地图生成器。")
		return
	if regenerate and not can_regenerate(app):
		app._set_status("当前地图没有可用的上次生成参数。")
		return
	var shell: Dictionary = app._popup_body("重新生成到新地图" if regenerate else "从游戏生成地图",
		"沿用上次参数。结果会打开为独立的新地图。" if regenerate
		else "设置参数并查看生成摘要，再打开为普通可编辑地图。生成不会写入项目。")
	var ui := new()
	ui._app = app
	ui._source = app.manifest
	ui._pop = shell.pop
	if regenerate:
		var source := Generators.origin(app.canvas.map_data)
		ui._origin = {"generator": source.generator, "parameters": source.parameters}
	FrameDialog.keep_on_focus_loss(ui._pop)
	shell.body.add_child(ui)
	ui._build()
	app._open_popup(ui._pop)

func _build() -> void:
	_picker = OptionButton.new()
	_picker.name = "MapGeneratorList"
	for id in _source.mapGenerators:
		if not _origin.is_empty() and id != _origin.generator:
			continue
		_picker.add_item(str(_source.mapGenerators[id].get("name", id)))
		_picker.set_item_metadata(_picker.item_count - 1, id)
	add_child(Kit.field_row("生成器", _picker))
	_preset = OptionButton.new()
	_preset.name = "MapGeneratorPreset"
	_preset_row = Kit.field_row("已保存配置", _preset)
	add_child(_preset_row)
	_name_input = LineEdit.new()
	_name_input.name = "GeneratedMapName"
	if not _origin.is_empty():
		_name_input.text = _app.cur_map_name + "_new"
	add_child(Kit.field_row("地图名", _name_input))
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 170
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_params = Kit.vbox(4)
	_params.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.add_child(_params)
	add_child(scroll)
	_status = Kit.hint_label("", 510)
	_status.name = "GeneratedMapStatus"
	add_child(_status)
	var actions := Kit.hbox(6)
	actions.add_child(Kit.button("关闭", _pop.hide, "ghost"))
	actions.add_child(Kit.spacer())
	_generate = Kit.button("生成地图", _run)
	_generate.name = "RunMapGenerator"
	actions.add_child(_generate)
	_accept = Kit.button("打开为可编辑地图", _open_result, "primary")
	actions.add_child(_accept)
	add_child(actions)
	_picker.item_selected.connect(func(_i): _select_generator())
	_preset.item_selected.connect(func(_i): _build_params(_preset.get_selected_metadata()))
	_name_input.text_changed.connect(func(_value): _invalidate())
	_picker.select(0)
	_select_generator()

func _select_generator() -> void:
	var id: String = _picker.get_selected_metadata()
	_preset.clear()
	_preset.add_item("临时参数" if _origin.is_empty() else "上次生成的参数")
	_preset.set_item_metadata(0, _origin.get("parameters", {}))
	for row in Generators.presets(_source, id):
		_preset.add_item("%s [%s]" % [row.name, row.id])
		_preset.set_item_metadata(_preset.item_count - 1, row.parameters)
	_preset_row.visible = _source.mapGenerators[id].has("contentType")
	_preset.select(0)
	_build_params(_preset.get_selected_metadata())

func _build_params(parameters: Dictionary) -> void:
	for child in _params.get_children():
		_params.remove_child(child)
		child.queue_free()
	_commits.clear()
	_values = {}
	var id: String = _picker.get_selected_metadata()
	var resolve: Callable = _app.project_shell.content_editor._form.project_reference_options.bind("")
	for field in Generators.fields_for(_source, id):
		var key: String = field.id
		var saved = parameters.get(key, Generators.default_value(field))
		_values[key] = saved if Generators.valid_value(field, saved) else Generators.default_value(field)
		var built := Fields.build(field, _values[key], _set_param.bind(key), resolve)
		built.ctl.name = "GeneratorField_" + key.validate_node_name()
		_params.add_child(Kit.field_row(str(field.get("name", key)), built.ctl))
		if built.get("commit", Callable()).is_valid():
			_commits.append(built.commit)
	_invalidate()

func _set_param(value: Variant, key: String) -> bool:
	_values[key] = value
	_invalidate()
	return true

func _invalidate() -> void:
	_result = {}
	_accept.disabled = true
	_status.text = "生成后可查看地图摘要。"

func _project_is_current() -> bool:
	return is_instance_valid(_app) and is_same(_app.manifest, _source)

func _keep() -> bool:
	return is_instance_valid(_pop) and _pop.visible and _project_is_current()

func _run() -> void:
	if _running or _opening or not _keep():
		return
	for commit in _commits:
		if not commit.call():
			return
	_invalidate()
	var name_ := _name_input.text.strip_edges()
	var target := Maps.path_for(_source, name_)
	if target == "" or FileAccess.file_exists(target):
		_status.text = "请输入合法且未被占用的地图名。"
		return
	var id: String = _picker.get_selected_metadata()
	var params := _values.duplicate(true)
	for field in Generators.fields_for(_source, id):
		if not Generators.valid_value(field, params[field.id]):
			_status.text = "参数值无效：" + str(field.get("name", field.id))
			return
	var public: Dictionary = _app._manifest_write_payload(_source)
	var code := Maps.allocate_code(_source, _app.canvas.cur_map_code() if _app.map_loaded else "")
	_running = true
	_generate.disabled = true
	_status.text = "游戏正在生成地图…"
	var reply := await Runner.render(get_tree(), _source, Runner.GENERATE_MAP,
		{"generator": id, "parameters": params, "manifest": public,
			"target": {"name": name_, "code": code, "version": Maps.FORMAT_VERSION}},
		Vector2i.ZERO, "", _keep)
	if not _keep():
		return
	_running = false
	_generate.disabled = false
	for commit in _commits:
		commit.call()
	if id != _picker.get_selected_metadata() or params != _values or name_ != _name_input.text.strip_edges() \
			or public != _app._manifest_write_payload(_source):
		_status.text = "生成期间输入或清单有变动，请重新生成。"
		return
	if not reply.has("map_text"):
		_status.text = reply.error
		return
	var decoded := Maps.decode_text(reply.map_text, "map.json", _source)
	if not decoded.ok:
		var issue: Dictionary = decoded.errors[0]
		_status.text = "生成结果无法打开：%s · %s" % [issue.path, issue.message]
		return
	var map: Dictionary = decoded.data
	if map.meta.get("code", code) != code:
		_status.text = "生成结果使用了不同的地图码。"
		return
	map.meta.name = name_
	map.meta.code = code
	Generators.remember(map, id, params)
	_result = {"map": map, "name": name_, "manifest": public}
	_accept.disabled = false
	var tiles := 0
	for cells in map.get("tiles", {}).values():
		tiles += cells.size()
	_status.text = "生成完成：%d × %d 格 · %d 瓦片 · %d 碰撞格 · %d 摆放物" % [
		map.meta.get("w", 120), map.meta.get("h", 56), tiles, map.get("collision", []).size(), map.get("objects", []).size()]
	if not decoded.warnings.is_empty():
		var issue: Dictionary = decoded.warnings[0]
		_status.text += "\n%d 条警告，首条：%s · %s" % [decoded.warnings.size(), issue.path, issue.message]

func _open_result() -> void:
	if _running or _opening or not _keep():
		return
	for commit in _commits:
		commit.call()
	if _result.is_empty():
		return
	var public: Dictionary = _result.manifest
	var app = _app
	var candidate := _result
	var source := _source
	var popup := _pop
	var guard := func() -> bool:
		return is_instance_valid(popup) and popup.visible and is_instance_valid(app) \
			and is_same(app.manifest, source) and app._manifest_write_payload(source) == public
	if not guard.call():
		_invalidate()
		_status.text = "清单已变动，请重新生成。"
		return
	_opening = true
	var opened: bool = await app._map_file_ctrl.open_generated_map(candidate.name, candidate.map, guard)
	if not _keep():
		return
	_opening = false
	if opened:
		_pop.hide()
		app._set_mode("map")
	else:
		_invalidate()
		_status.text = "结果未应用，请重新生成。"
