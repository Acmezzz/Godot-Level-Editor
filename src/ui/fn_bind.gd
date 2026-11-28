extends RefCounted
## 功能绑定块（附加功能行 + 添加菜单 + 行操作）：从 content_editor.gd 拆出的控制器。宿主 = content_editor 实例（host 引用）。
## repeatable 声明允许从菜单添加同功能的独立绑定；继承行与附加行分开识别。

const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const Catalog := preload("res://src/content/authoring_catalog.gd")
const RIGHT_W := 360

# content_editor 持有该子控制器；反向只保留弱引用，切换项目时可释放。
var _host_ref: WeakRef
var host:
	get: return _host_ref.get_ref()
var app    # 根应用（= host.app）
var _render_generation := 0
var _rows_scroll: ScrollContainer
var _binding_filter := "__all"
var _recent_functions: Array = []

func _init(h) -> void:
	_host_ref = weakref(h)
	app = h.app

## 同名转发属性（读写穿透到宿主，保住搬动文本零改动）
var manifest: Dictionary:
	get: return host.manifest
var _selected_fn: int:
	get: return host._selected_fn
	set(v): host._selected_fn = v

## 同名包装方法（真实实现经 host 转发）
## 这里所有调用点都是「改绑定前先冲刷控件值」，不能走完整 commit——
## 那会把 staged 新内容提前写盘（只有正式保存/试玩才该落盘，A2）。
func commit() -> bool:
	return host.commit_fields()
func _current_fns() -> Array:
	return host._current_fns()
func _current_spr() -> EntityNode:
	return host._current_spr()
func _write_fns(n: EntityNode, fns: Array) -> void:
	host._write_fns(n, fns)
func _refresh_all() -> void:
	host._refresh_all()
func _rebuild_rows() -> void:
	host._rebuild_rows()
func _rebuild_right() -> void:
	host._rebuild_right()
func _mount_codes() -> Dictionary:
	return host._mount_codes()
func _open_lib(i: int) -> void:
	host._open_lib(i)

func _build_fn_block() -> Control:
	_render_generation += 1
	var box := Kit.vbox(6)
	box.add_child(Kit.section_header("功能编排", null))
	var fns := _current_fns()
	var bar := Kit.hbox(6)
	box.add_child(bar)
	var add := Kit.button("+ 添加功能 …", func(): _open_candidates(-1), "plain")
	add.disabled = _function_index().is_empty()
	bar.add_child(add)
	if _selected_fn in range(fns.size()):
		var after := Kit.button("在 #%d 后插入…" % (_selected_fn + 1), func(): _open_candidates(_selected_fn), "ghost")
		after.disabled = add.disabled
		bar.add_child(after)
	if fns.is_empty():
		box.add_child(Kit.hint_label("这个实例还没有功能。", RIGHT_W - 40))
		return box
	box.add_child(Kit.button("把这组绑定追加到其他实例…", _copy_bindings, "ghost"))

	var filter := OptionButton.new()
	filter.fit_to_longest_item = false
	var timings := {"__all": "全部时机", "": "默认时机"}
	for row in fns:
		var code := str(row.get("trigger", ""))
		if code != "":
			timings[code] = FunctionDecls.trigger_options(manifest, _resolve_fn(row).id).get(code, code)
	if not timings.has(_binding_filter):
		_binding_filter = "__all"
	for code in timings:
		filter.add_item(timings[code])
		filter.set_item_metadata(filter.item_count - 1, code)
		if code == _binding_filter:
			filter.select(filter.item_count - 1)
	filter.item_selected.connect(func(i: int):
		if not commit():
			return
		_binding_filter = str(filter.get_item_metadata(i))
		_rebuild_right())
	box.add_child(Kit.field_row("查看", filter, 48))
	var old_scroll := _rows_scroll.scroll_vertical if is_instance_valid(_rows_scroll) else 0
	var scroll := ScrollContainer.new()
	_rows_scroll = scroll
	scroll.follow_focus = true
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size.y = minf(fns.size() * 48.0, 184.0)
	box.add_child(scroll)
	var rows := Kit.vbox(3)
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(rows)
	var selected: Button
	for i in fns.size():
		var row: Dictionary = fns[i]
		if _binding_filter != "__all" and row.get("trigger", "") != _binding_filter:
			continue
		var entry := _build_fn_row(i, row)
		rows.add_child(entry)
		if i == _selected_fn:
			selected = entry
	scroll.set_deferred("scroll_vertical", old_scroll)
	if selected != null:
		_reveal_selected.call_deferred(scroll, selected)
	if _selected_fn in range(fns.size()):
		_add_selected_actions(box, fns[_selected_fn], _fn_token(fns, _selected_fn), fns.size())
	return box

func _reveal_selected(scroll: ScrollContainer, row: Button) -> void:
	await app.get_tree().process_frame
	if is_instance_valid(scroll) and is_instance_valid(row) and scroll == _rows_scroll and row.is_visible_in_tree():
		scroll.ensure_control_visible(row)

func _build_fn_row(i: int, row: Dictionary) -> Button:
	var id: String = _resolve_fn(row).id
	var trigger: String = row.get("trigger", "")
	var label := FunctionDecls.function_name(manifest, id) if id != "" else str(row.get("fn", "未声明"))
	var title := str(row.get("name", ""))
	var content: String = row.get("content", "")
	if title == "" and id != "" and content != "":
		title = str(host.read_content_staged(id, content).get("name", ""))
	if title == "":
		title = content
	var name_ := title if title != "" else "未绑定内容"
	var controls := "默认时机" if trigger == "" else str(FunctionDecls.trigger_options(manifest, id).get(trigger, trigger))
	if row.get("parallel", false):
		controls += " · 并行"
	if not row.get("enabled", true):
		controls += " · 停用"
	if _mount_state(_current_fns(), str(row.get("fn", ""))) == i:
		controls += " · 类型自带"
	var text := "%s #%d  %s · %s\n%s" % ["▾" if i == _selected_fn else "▸", i + 1, label, controls, name_]
	var token := _fn_token(_current_fns(), i)
	var entry := Kit.button(text, func(): _pick_fn(_fn_index_of(_current_fns(), token)), "plain")
	entry.name = "BindingRow%d" % (i + 1)
	entry.clip_text = true
	entry.alignment = HORIZONTAL_ALIGNMENT_LEFT
	entry.custom_minimum_size.y = 44
	entry.tooltip_text = text
	return entry

func _add_selected_actions(box: VBoxContainer, row: Dictionary, tok: Dictionary, total: int) -> void:
	var i: int = tok.index
	var id: String = _resolve_fn(row).id
	var trg := OptionButton.new()
	trg.fit_to_longest_item = false
	trg.add_item("默认时机")
	trg.set_item_metadata(0, "")
	var current: String = row.get("trigger", "")
	var chosen := 0
	for option in _trigger_options(id):
		trg.add_item(option.t)
		trg.set_item_metadata(trg.item_count - 1, option.v)
		if option.v == current:
			chosen = trg.item_count - 1
	if current != "" and chosen == 0:
		trg.add_item("未声明：" + current)
		chosen = trg.item_count - 1
		trg.set_item_metadata(chosen, current)
	trg.select(chosen)
	trg.item_selected.connect(func(n: int): _set_trigger(tok, str(trg.get_item_metadata(n))))
	box.add_child(Kit.field_row("#%d 时机" % (i + 1), trg, 70))
	var settings := Kit.hbox(6)
	box.add_child(settings)
	var parallel := CheckBox.new()
	parallel.text = "并行"
	parallel.button_pressed = row.get("parallel", false)
	parallel.toggled.connect(func(v: bool): _set_parallel(tok, v))
	settings.add_child(parallel)
	var enabled := CheckBox.new()
	enabled.text = "启用"
	enabled.button_pressed = row.get("enabled", true)
	enabled.toggled.connect(func(v: bool): _set_enabled(tok, v))
	settings.add_child(enabled)
	if i > 0:
		settings.add_child(Kit.button("↑", func(): _move_token(tok, -1), "ghost"))
	if i + 1 < total:
		settings.add_child(Kit.button("↓", func(): _move_token(tok, 1), "ghost"))
	var commands := Kit.hbox(6)
	box.add_child(commands)
	commands.add_child(Kit.button("选择已有内容…", func():
		var at := _fn_index_of(_current_fns(), tok)
		if at >= 0:
			_open_lib(at), "ghost"))
	var mounted := _mount_state(_current_fns(), tok.code)
	if mounted == -2:
		commands.add_child(Kit.button("设为类型自带", func(): _choose_mount(tok), "ghost"))
	elif mounted != i:
		commands.add_child(Kit.del_button(func(): _delete_fn(_fn_index_of(_current_fns(), tok)), "移除此绑定；内容留在库中"))

func _open_candidates(after: int) -> void:
	if not commit():
		return
	var fns := _current_fns()
	var token := _fn_token(fns, after) if after >= 0 else {}
	var spr := _current_spr()
	var trigger := str(fns[after].get("trigger", "")) if after >= 0 else ""
	var snapshot: Dictionary = app.canvas.map_data
	var candidates := Catalog.functions(manifest, fns, snapshot, trigger, _recent_functions)
	var shell: Dictionary = app._popup_body("添加功能",
		"插入位置：%s。按当前时机和本图使用情况排序，可切换查看其他时机。" % ("末尾" if after < 0 else "#%d 之后" % (after + 1)), true)
	var body: VBoxContainer = shell.body
	var popup: PopupPanel = shell.pop
	var filter := LineEdit.new()
	filter.placeholder_text = "功能名称、用途或 ID"
	body.add_child(filter)
	var scope := CheckBox.new()
	scope.text = "只看支持当前时机的功能"
	scope.disabled = trigger == ""
	scope.set_pressed_no_signal(trigger != "" and candidates.any(func(row): return row.compatible))
	body.add_child(scope)
	var list := ItemList.new()
	list.custom_minimum_size = Vector2(500, 320)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(list)
	var choose := func():
		var selected := list.get_selected_items()
		if selected.is_empty() or spr != _current_spr():
			return
		var at := _fn_index_of(_current_fns(), token) if not token.is_empty() else -1
		if not token.is_empty() and at < 0:
			return
		var item: Dictionary = list.get_item_metadata(selected[0])
		popup.hide()
		_add_fn(item.id, at, trigger if item.compatible else "")
	var populate := func():
		list.clear()
		var q := filter.text.strip_edges().to_lower()
		for item in candidates:
			if scope.button_pressed and not item.compatible:
				continue
			var summary := "%s · %s" % [item.name, item.reason]
			if q != "" and q not in ("%s %s %s" % [summary, item.id, item.description]).to_lower():
				continue
			var n := list.add_item(summary)
			list.set_item_tooltip(n, "%s\n%s" % [item.id, item.description])
			list.set_item_metadata(n, item)
		if list.item_count > 0:
			list.select(0)
	scope.toggled.connect(func(_on: bool): populate.call())
	filter.text_changed.connect(func(_text: String): populate.call())
	filter.text_submitted.connect(func(_text: String): choose.call())
	list.item_activated.connect(func(_i: int): choose.call())
	body.add_child(Kit.popup_buttons(choose, popup.hide, "插入功能"))
	populate.call()
	app._open_popup(popup)
	filter.grab_focus()

func _copy_bindings() -> void:
	if not commit():
		return
	var from := _current_spr()
	var source := _current_fns().duplicate(true)
	var generation: int = app._map_file_ctrl.sess.generation
	var shell: Dictionary = app._popup_body("追加这组绑定",
		"同图、同资产的实例可复用这组绑定。已有的单次功能会跳过；内容 ID 继续共享。", true)
	var body: VBoxContainer = shell.body
	var pop: PopupPanel = shell.pop
	var list := ItemList.new()
	list.select_mode = ItemList.SELECT_MULTI
	list.custom_minimum_size = Vector2(460, 250)
	body.add_child(list)
	for item in host._entities():
		if item.node != from and item.asset == from.asset and not app.canvas.is_layer_code_locked(item.node.layer_id):
			var i := list.add_item("%s · %s" % [item.code, str(Vector2i(item.position))])
			list.set_item_metadata(i, item.code)
	var notice := Kit.hint_label("已选 0 个目标。", 440)
	body.add_child(notice)
	list.multi_selected.connect(func(_i: int, _on: bool): notice.text = "已选 %d 个目标。" % list.get_selected_items().size())
	var apply := func():
		if app._map_file_ctrl.sess.stale(generation):
			return
		var selected := list.get_selected_items()
		if selected.is_empty():
			return
		var nodes := []
		for i in selected:
			var node := host._find_ent(str(list.get_item_metadata(i))) as EntityNode
			if node == null or app.canvas.is_layer_code_locked(node.layer_id):
				notice.text = "有已选实例不能编辑，未改动任何绑定。请重新打开并检查图层锁定。"
				return
			nodes.append(node)
		var history: Dictionary = app.canvas._undo_history_ctrl.inst_rows(nodes)
		if not history.get("ok", false):
			app.canvas.push_undo()
		var count := 0
		for node in nodes:
			var rows: Array = node.functions.duplicate(true)
			for original in source:
				var fn_id := FunctionDecls.fn_id_of(manifest, original.fn)
				if fn_id == "" or (not FunctionDecls.is_repeatable(manifest, fn_id) and rows.any(func(r): return r.fn == original.fn)):
					continue
				var row: Dictionary = original.duplicate(true)
				row.erase("mounted")
				row["bindingId"] = FunctionDecls.new_binding_id(rows)
				row["order"] = rows.size() + 1
				rows.append(row)
				count += 1
			node.functions = rows
		if count > 0:
			if history.get("ok", false):
				app.canvas._undo_history_ctrl.inst_commit(history.rows)
			app.canvas._mark_ents()
			_refresh_all()
		pop.hide()
		app._set_status("追加了 %d 条绑定 · 与原条目共用内容" % count)
	body.add_child(Kit.popup_buttons(apply, pop.hide, "追加到所选实例"))
	app._open_popup(pop)

func _function_index() -> Dictionary:
	return FunctionDecls.functions(manifest)

## 解析一条绑定里的功能引用：磁盘上的 fn 一律是执行码，按码查 id；查不到 = 数据漂移。
## 返回 {id, code, known}——UI 全部按 id（人类名）组织，写盘只写 code。
func _resolve_fn(f: Dictionary) -> Dictionary:
	var code := str(f.get("fn", ""))
	var id := FunctionDecls.fn_id_of(manifest, code)
	return {"id": id, "code": code, "known": id != ""}

## 控件令牌仅在当前实例和右栏渲染中有效；有 ID 的行额外核对持久身份。
func _fn_token(fns: Array, i: int) -> Dictionary:
	var row: Dictionary = fns[i] if fns[i] is Dictionary else {}
	return {"code": str(row.get("fn", "")), "id": str(row.get("bindingId", "")),
		"index": i, "entity": _current_spr(), "generation": _render_generation}

func _fn_index_of(fns: Array, tok: Dictionary) -> int:
	if tok.get("generation") != _render_generation or tok.get("entity") != _current_spr():
		return -1
	var i := int(tok.get("index", -1))
	if i < 0 or i >= fns.size() or not fns[i] is Dictionary:
		return -1
	var row: Dictionary = fns[i]
	if str(row.get("fn", "")) != tok.code or str(row.get("bindingId", "")) != tok.id:
		return -1
	return i

func _mount_state(fns: Array, code: String) -> int:
	return FunctionDecls.mounted_index(fns, code) if _mount_codes().has(code) else -1

func _choose_mount(tok: Dictionary) -> void:
	if not commit():
		return
	var fns := _current_fns().duplicate(true)
	var i := _fn_index_of(fns, tok)
	if i < 0 or _mount_state(fns, tok.code) != -2:
		return
	var repeatable := FunctionDecls.is_repeatable(manifest, FunctionDecls.fn_id_of(manifest, tok.code))
	for j in fns.size():
		if not fns[j] is Dictionary or str(fns[j].get("fn", "")) != tok.code:
			continue
		fns[j].erase("mounted")
		if repeatable and str(fns[j].get("bindingId", "")) == "":
			fns[j]["bindingId"] = FunctionDecls.new_binding_id(fns)
	fns[i]["mounted"] = true
	_write_fns(_current_spr(), fns)
	_refresh_all()

func _pick_fn(i: int) -> void:
	if i < 0 or not commit():
		return
	_selected_fn = -1 if _selected_fn == i else i
	_rebuild_right()

## 功能声明的 trigger id 白名单 → [{v: 时机码, t: 显示名}]。
## 声明按 id 引用时机池；绑定存码，UI 显示名。
func _trigger_options(fn_id: String) -> Array:
	var out: Array = []
	var choices := FunctionDecls.trigger_options(manifest, fn_id)
	for code in choices:
		out.append({"v": code, "t": choices[code]})
	return out

## 切换行设置前保存当前输入，重建时按绑定身份重新读取字段。
func _patch_setting(tok: Dictionary, key: String, value: Variant) -> void:
	if _fn_index_of(_current_fns(), tok) < 0 or not commit():
		return
	var fns := _current_fns().duplicate(true)
	var i := _fn_index_of(fns, tok)
	if i < 0:
		return
	if value == null:
		fns[i].erase(key)
	else:
		fns[i][key] = value
	_write_fns(_current_spr(), fns)
	_rebuild_right()

func _set_parallel(tok: Dictionary, v: bool) -> void:
	_patch_setting(tok, "parallel", v)

func _set_trigger(tok: Dictionary, code: String) -> void:
	var trigger: Variant = code
	if code.is_empty():
		trigger = null
	_patch_setting(tok, "trigger", trigger)

func _set_enabled(tok: Dictionary, v: bool) -> void:
	var setting: Variant = null
	if not v:
		setting = false
	_patch_setting(tok, "enabled", setting)

func _delete_fn(i: int) -> void:
	var spr := _current_spr()
	var fns := _current_fns()
	if spr == null or i < 0 or i >= fns.size():
		return
	var tok := _fn_token(fns, i)
	if not commit():
		return
	fns = _current_fns().duplicate(true)
	i = _fn_index_of(fns, tok)
	if i < 0 or _mount_state(fns, tok.code) in [i, -2]:
		return
	fns.remove_at(i)
	# order 之后重排：序号是执行顺序的唯一真相，删除后不能留空洞
	for k in fns.size():
		if fns[k] is Dictionary:
			(fns[k] as Dictionary)["order"] = k + 1
	_selected_fn = -1
	_write_fns(spr, fns)
	_refresh_all()

func _move_token(tok: Dictionary, direction: int) -> void:
	_move_fn(_fn_index_of(_current_fns(), tok), direction)

## 绑定行 ↑/↓：交换相邻两条并重排 order（执行顺序 = 数组序）。
func _move_fn(i: int, dir: int) -> void:
	var spr := _current_spr()
	var fns := _current_fns()
	var j := i + dir
	if spr == null or i < 0 or i >= fns.size() or j < 0 or j >= fns.size():
		return
	var tok := _fn_token(fns, i)
	if not commit():
		return
	fns = _current_fns().duplicate(true)
	i = _fn_index_of(fns, tok)
	if i < 0:
		return
	j = i + dir
	if j < 0 or j >= fns.size():
		return
	var t = fns[i]
	fns[i] = fns[j]
	fns[j] = t
	for k in fns.size():
		if fns[k] is Dictionary:
			(fns[k] as Dictionary)["order"] = k + 1
	if _selected_fn == i:
		_selected_fn = j
	elif _selected_fn == j:
		_selected_fn = i
	_write_fns(spr, fns)
	_refresh_all()

## 追加功能：内容留空，等用户在表单里第一次改动时再生成 ID。
## 绑定里写执行码；码由 ensure_codes 在加载清单时补发，这里不可能缺。
func _add_fn(fn_id: String, after := -1, trigger := "") -> void:
	var spr := _current_spr()
	var code := FunctionDecls.fn_code(manifest, fn_id)
	if spr == null or code == "" or not commit() or spr != _current_spr():
		return
	var fns := _current_fns().duplicate(true)
	var repeatable := FunctionDecls.is_repeatable(manifest, fn_id)
	var matching := []
	for i in fns.size():
		if fns[i] is Dictionary and str(fns[i].get("fn", "")) == code:
			matching.append(i)
	if not repeatable and not matching.is_empty():
		return
	var mounted := _mount_state(fns, code)
	if mounted == -2:
		app._set_status("请先标记这项功能的类型自带行。")
		return
	var next := {"fn": code, "content": "", "name": "", "order": fns.size() + 1, "parallel": false}
	if repeatable:
		if mounted >= 0:
			fns[mounted]["mounted"] = true
		for i in matching:
			if str(fns[i].get("bindingId", "")) == "":
				fns[i]["bindingId"] = FunctionDecls.new_binding_id(fns)
		next["bindingId"] = FunctionDecls.new_binding_id(fns)
	if trigger != "":
		next["trigger"] = trigger
	_selected_fn = fns.size() if after < 0 else after + 1
	fns.insert(_selected_fn, next)
	for i in fns.size():
		fns[i]["order"] = i + 1
	_binding_filter = "__all"
	_recent_functions.erase(fn_id)
	_recent_functions.push_front(fn_id)
	_recent_functions.resize(mini(12, _recent_functions.size()))
	_write_fns(spr, fns)
	_refresh_all()
