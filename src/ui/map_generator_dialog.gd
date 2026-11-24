extends VBoxContainer

const Kit := preload("res://src/ui/ui_kit.gd")
const Fields := preload("res://src/ui/field_widgets.gd")
const Generators := preload("res://src/project/map_generators.gd")
const Runner := preload("res://src/project/game_preview.gd")
const FrameDialog := preload("res://src/ui/game_frame_dialog.gd")
const Maps := preload("res://src/map/map_store.gd")
const Merge := preload("res://src/map/generated_map_merge.gd")
const CONFLICT_PAGE := 20

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
var _conflict_scroll: ScrollContainer
var _conflict_rows: VBoxContainer
var _conflict_nav: HBoxContainer
var _page_label: Label
var _prev_page: Button
var _next_page: Button
var _page := 0
var _merge_input := {}
var _choices := {}
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
	var row := Merge.origin(app.canvas.map_data)
	return not row.is_empty() and app.manifest.mapGenerators.has(row.generator)

static func open(app, regenerate := false) -> void:
	if not available(app):
		app._set_status("游戏清单未声明可用的地图生成器。")
		return
	if regenerate and not can_regenerate(app):
		app._set_status("当前地图没有可用的生成基线。")
		return
	var shell: Dictionary = app._popup_body("重新生成当前地图" if regenerate else "从游戏生成地图",
		"基于上次结果保留手工修改，冲突时停止应用。" if regenerate
		else "设置参数并查看生成摘要，再打开为普通可编辑地图。生成不会写入项目。")
	var ui := new()
	ui._app = app
	ui._source = app.manifest
	ui._pop = shell.pop
	if regenerate:
		ui._origin = Merge.origin(app.canvas.map_data).duplicate(true)
	FrameDialog.keep_on_focus_loss(ui._pop)
	shell.body.add_child(ui)
	ui._build()
	var bounds: Vector2 = app.get_viewport_rect().size
	app._open_popup(ui._pop, Vector2i(minf(620, bounds.x - 40), minf(645, bounds.y - 40)) if regenerate else Vector2i.ZERO)

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
		_name_input.text = _app.cur_map_name
		_name_input.editable = false
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
	if not _origin.is_empty():
		_conflict_scroll = ScrollContainer.new()
		_conflict_scroll.custom_minimum_size.y = 180
		_conflict_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		_conflict_scroll.hide()
		_conflict_rows = Kit.vbox(8)
		_conflict_rows.size_flags_horizontal = SIZE_EXPAND_FILL
		_conflict_scroll.add_child(_conflict_rows)
		add_child(_conflict_scroll)
		_conflict_nav = Kit.hbox(6)
		_prev_page = Kit.button("上一页", func(): _draw_conflict_page(_page - 1))
		_next_page = Kit.button("下一页", func(): _draw_conflict_page(_page + 1))
		_page_label = Label.new()
		_conflict_nav.add_child(_prev_page)
		_conflict_nav.add_child(_page_label)
		_conflict_nav.add_child(_next_page)
		_conflict_nav.hide()
		add_child(_conflict_nav)
	var actions := Kit.hbox(6)
	actions.add_child(Kit.button("关闭", _pop.hide, "ghost"))
	actions.add_child(Kit.spacer())
	_generate = Kit.button("生成地图", _run)
	_generate.name = "RunMapGenerator"
	actions.add_child(_generate)
	_accept = Kit.button("打开为可编辑地图" if _origin.is_empty() else "应用重生成", _open_result, "primary")
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
	_merge_input = {}
	_choices.clear()
	if _conflict_scroll != null:
		_conflict_scroll.hide()
		_conflict_nav.hide()
		_clear_conflict_rows()
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
	var regenerate := not _origin.is_empty()
	if target == "" or (not regenerate and FileAccess.file_exists(target)):
		_status.text = "请输入合法且未被占用的地图名。"
		return
	var id: String = _picker.get_selected_metadata()
	var params := _values.duplicate(true)
	for field in Generators.fields_for(_source, id):
		if not Generators.valid_value(field, params[field.id]):
			_status.text = "参数值无效：" + str(field.get("name", field.id))
			return
	var public: Dictionary = _app._manifest_write_payload(_source)
	var controller = _app._map_file_ctrl
	var session = controller.sess
	var generation: int = session.generation
	var revision: int = session.revision
	var live: Dictionary = _app.canvas.extract() if regenerate else {}
	if regenerate and (name_ != _app.cur_map_name or Merge.origin(live) != _origin
			or Maps.write_error(_source, _origin.base) != ""):
		_status.text = "地图或生成基线不可用，请重新打开窗口。"
		return
	var code := str(_origin.get("owner", ""))
	if not regenerate:
		code = Maps.allocate_code(_source, _app.canvas.cur_map_code() if _app.map_loaded else "")
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
			or public != _app._manifest_write_payload(_source) \
			or (regenerate and (session.stale(generation) or session.revision != revision)):
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
	map.meta.erase(Merge.KEY)
	var candidate := {"name": name_, "manifest": public, "generation": generation, "revision": revision,
		"generated": map, "generator": id, "parameters": params, "warnings": decoded.warnings}
	if regenerate:
		var plan := Merge.plan(_origin.base, live, map)
		var conflicts: Array = plan.conflicts
		if not conflicts.is_empty():
			_merge_input = {"candidate": candidate, "live": live, "count": conflicts.size()}
			_show_conflicts(conflicts)
			return
		map = plan.map
	_prepare_candidate(candidate, map)

func _show_conflicts(conflicts: Array) -> void:
	_merge_input["conflicts"] = conflicts
	_draw_conflict_page(0)
	_status.text = "未应用：发现 %d 处冲突。请逐项选择。" % conflicts.size()

func _clear_conflict_rows() -> void:
	for row in _conflict_rows.get_children():
		_conflict_rows.remove_child(row)
		row.queue_free()

func _draw_conflict_page(page: int) -> void:
	var conflicts: Array = _merge_input.get("conflicts", [])
	var pages := ceili(float(conflicts.size()) / CONFLICT_PAGE)
	if page < 0 or page >= pages:
		return
	_page = page
	_clear_conflict_rows()
	var offset := page * CONFLICT_PAGE
	for i in range(offset, mini(offset + CONFLICT_PAGE, conflicts.size())):
		var conflict: Dictionary = conflicts[i]
		var path: String = conflict.path
		var choice := OptionButton.new()
		choice.name = "GenerationConflict" + str(i)
		choice.add_item("请选择")
		choice.add_item("保留编辑值")
		choice.add_item("采用生成值")
		choice.select(["", "authored", "generated"].find(_choices.get(path, "")))
		choice.item_selected.connect(_choose.bind(path))
		var row := Kit.vbox(4)
		row.add_child(Kit.hint_label(path, 480))
		row.add_child(Kit.hint_label("编辑值：%s\n生成值：%s" % [
			_describe(conflict.authored), _describe(conflict.generated)], 480))
		row.add_child(choice)
		_conflict_rows.add_child(row)
	_conflict_scroll.show()
	_conflict_scroll.scroll_vertical = 0
	_conflict_nav.visible = pages > 1
	_page_label.text = "%d / %d" % [page + 1, pages]
	_prev_page.disabled = page == 0
	_next_page.disabled = page + 1 >= pages

func _describe(side: Dictionary) -> String:
	if not side.keep:
		return "（删除）"
	var preview := JSON.stringify(side.value)
	return preview if preview.length() <= 160 else preview.left(157) + "…"

func _choose(index: int, path: String) -> void:
	if _merge_input.is_empty():
		return
	if index == 0:
		_choices.erase(path)
	else:
		_choices[path] = "authored" if index == 1 else "generated"
	_result = {}
	_accept.disabled = true
	var count: int = _merge_input.count
	if count != _choices.size():
		_status.text = "还有 %d 处冲突未选择。" % (count - _choices.size())
		return
	var candidate: Dictionary = _merge_input.candidate
	var session = _app._map_file_ctrl.sess
	if session.stale(candidate.generation) or session.revision != candidate.revision:
		_status.text = "地图已变动，请重新生成。"
		return
	var plan := Merge.plan(_origin.base, _merge_input.live, candidate.generated, _choices)
	if plan.conflicts.is_empty():
		_prepare_candidate(candidate, plan.map)
	else:
		var next: Array = plan.conflicts
		_merge_input.count = _choices.size() + next.size()
		_show_conflicts(next)

func _prepare_candidate(candidate: Dictionary, map: Dictionary) -> void:
	var error := Maps.write_error(_source, map)
	if error != "":
		_status.text = "合并后的地图无效： " + error
		return
	Merge.attach(map, candidate.generated, candidate.generator, candidate.parameters)
	_result = {"map": map, "name": candidate.name, "manifest": candidate.manifest,
		"generation": candidate.generation, "revision": candidate.revision}
	_accept.disabled = false
	var tiles := 0
	for cells in map.get("tiles", {}).values():
		tiles += cells.size()
	_status.text = "生成完成：%d × %d 格 · %d 瓦片 · %d 碰撞格 · %d 摆放物" % [
		map.meta.get("w", 120), map.meta.get("h", 56), tiles, map.get("collision", []).size(), map.get("objects", []).size()]
	if not candidate.warnings.is_empty():
		var issue: Dictionary = candidate.warnings[0]
		_status.text += "\n%d 条警告，首条：%s · %s" % [candidate.warnings.size(), issue.path, issue.message]

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
	var opened: bool
	if _origin.is_empty():
		opened = await app._map_file_ctrl.open_generated_map(candidate.name, candidate.map, guard)
	else:
		opened = await app._map_file_ctrl.apply_regenerated_map(candidate.map, candidate.generation, candidate.revision)
	if not _keep():
		return
	_opening = false
	if opened:
		_pop.hide()
		app._set_mode("map")
	else:
		_invalidate()
		_status.text = "结果未应用，请重新生成。"
