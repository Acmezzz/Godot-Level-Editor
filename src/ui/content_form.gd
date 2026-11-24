extends RefCounted
## 内容表单 + 内容库：字段控件渲染、结构化行、内容库（复制/共享改绑/改名/删除）、
## 内容字段和绑定共用同一份工作副本。
##
## 三件必须分清的东西：
##   **控件待收集值** —— LineEdit/SpinBox 里还没提交的文本；commit()/失焦/回车才转成值，
##                          切面板时 _set_mode 先 commit() 冲刷，别让用户输入凭空消失。
##   **已有文件的工作副本** —— 已落盘内容的字段改动直接写回该内容文件（_content_write，
##                          带磁盘摘要基线，外部改过就 conflict）。
##   **新绑定的暂存** —— 以 (功能 ID, 内容 ID) 寻址，记录数据、实例和文档归属。
##                          正式地图提交按冻结计划逐条调用 flush_one 写入仍有绑定的内容。
##
## 落盘责任划分：本模块只管「把值写进内容数据 / 暂存」；真正的地图写盘、历史轮转和提交日志
## 由 map_file.commit_document 与 MapStore/Recovery 负责——这里不直接写地图。
## 跨边界引用经 host 转发（同名 const 重声明 + 同名转发属性 + 同名包装方法）。

const FrameReference := preload("res://src/ui/map_game_preview.gd")
const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const ContentId := preload("res://src/content/content_id.gd")
const ConditionDecls := preload("res://src/content/condition_decl.gd")
const AudioDecls := preload("res://src/content/audio_decl.gd")
const StepDecls := preload("res://src/content/step_decl.gd")
const MapStore := preload("res://src/map/map_store.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")
const FieldWidgets := preload("res://src/ui/field_widgets.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const RefFields := preload("res://src/content/ref_fields.gd")
const ReferenceUsage := preload("res://src/project/reference_usage.gd")
const StartupTargets := preload("res://src/project/startup_targets.gd")
const CellGraph := preload("res://src/map/cell_graph.gd")
const ReferenceIndex := preload("res://src/project/reference_index.gd")   # B2：删除入边全景统一入口
const RIGHT_W := 360

var host   # content_editor 宿主
var app    # 根应用（= host.app）

func _init(h) -> void:
	host = h
	app = h.app

## 同名转发属性（读写穿透到宿主，保住搬动文本零改动）
var manifest: Dictionary:
	get: return host.manifest
var _pending_commits: Array:
	get: return host._pending_commits
var _selected_fn: int:
	get: return host._selected_fn
	set(v): host._selected_fn = v
var _form_id_edit: LineEdit:
	get: return host._form_id_edit
	set(v): host._form_id_edit = v
var _selected_ent: String:
	get: return host._selected_ent
	set(v): host._selected_ent = v
var _preview: Control:
	get: return host._preview
var _r_badge: PanelContainer:
	get: return host._r_badge

## 同名包装方法（真实实现经 host 转发）
## 表单内部调用点都是「换选择前先冲刷控件值」，不落 staged（A2）。
func commit() -> bool:
	return host.commit_fields()
func _current_fns() -> Array:
	return host._current_fns()
func _current_spr() -> EntityNode:
	return host._current_spr()
func _entities() -> Array:
	return host._entities()
func _content_id_for(n: EntityNode, fn_id: String) -> String:
	return host._content_id_for(n, fn_id)
func _map_ready() -> bool:
	return host._map_ready()
func _write_fns(n: EntityNode, fns: Array) -> void:
	host._write_fns(n, fns)
func _refresh_all() -> void:
	host._refresh_all()
func _rebuild_right() -> void:
	host._rebuild_right()
func _rebuild_rows() -> void:
	host._rebuild_rows()
func _open_steps_editor(i: int) -> void:
	host._open_steps_editor(i)
func _resolve_fn(f: Dictionary) -> Dictionary:
	return host._resolve_fn(f)

## 内容表单：字段按功能声明渲染（声明 = 游戏侧契约，编辑器只建控件不解释语义）。
## 内容文件结构 {id, function: 功能码, name, fields:{字段码:值}}。
## 磁盘上的 function/fields 键一律是执行码（ensure_codes 保证），严格按码、无回退。
func _build_form_block() -> Control:
	var box := Kit.vbox(6)
	var fns := _current_fns()
	var i := _selected_fn
	var f: Dictionary = fns[i] if i >= 0 and i < fns.size() and fns[i] is Dictionary else {}
	var ref := _resolve_fn(f)
	var fn_id := str(ref.get("id", ""))
	var content_id := str(f.get("content", ""))
	var fn_label := str(FunctionDecls.function_name(manifest, fn_id)) if bool(ref.get("known", false)) \
		else "(未声明的功能) " + str(f.get("fn", ""))
	var st0 = _staged_get(fn_id, content_id)
	var cres: Dictionary = {"status": "ok", "data": (st0.data as Dictionary).duplicate(true), "error": ""} \
		if st0 is Dictionary and content_id != "" \
		else (ContentStore.read_ex(manifest, fn_id, content_id) if content_id != "" and fn_id != "" \
		else {"status": "missing", "data": {}, "error": ""})
	var data: Dictionary = cres.data if str(cres.status) == "ok" else {}
	var project_scope := str(data.get("scope", "")) == "project"
	var cname := str(data.get("name", "")) if not data.is_empty() else str(f.get("name", ""))

	var head := Kit.hbox(6)
	var title := Kit.text_label("%s 内容" % fn_label, Th.TEXT, Th.FS_SMALL)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var reload_btn := Kit.button("重读内容", host.reload_content_form, "ghost")
	reload_btn.tooltip_text = "放弃此表单尚未写入的值，重读当前内容"
	head.add_child(reload_btn)
	box.add_child(head)
	# 码漂移：内容文件的 "function" 键与当前功能执行码不一致（清单改码后旧文件仍带旧码）。
	# 只提示不阻断——写盘时会以当前码重写，用户改一次值即自愈。
	var drift := _function_code_drift(data, fn_id)
	if drift != "":
		box.add_child(Kit.text_label("⚠ 内容记录的功能码 %s 与清单当前码 %s 不一致（改动任一字段即按当前码重写）"
			% [drift, FunctionDecls.fn_code(manifest, fn_id)], Th.WARN, Th.FS_META))
	# 损坏内容：拒绝静默覆盖，给显式修复入口（C04）。修复前表单只读。
	if str(cres.status) == "invalid":
		box.add_child(Kit.text_label("⚠ 内容文件损坏，已拒绝写入：%s" % str(cres.error), Th.ERR, Th.FS_META))
		var fix := Kit.button("重建为空白内容（会覆盖坏文件）", func():
			var blank := _blank_content(fn_id, content_id)
			if ContentStore.write(manifest, fn_id, content_id, blank, true):
				app._set_status(" 内容已重建：" + content_id)
				_rebuild_right())
		box.add_child(fix)

	# 只读层级 ID：创建后显示完整 id，未创建时明确写「未创建」而不是伪造一个随机码
	var id_text := content_id
	if id_text == "":
		id_text = "未创建"
	_form_id_edit = LineEdit.new()
	_form_id_edit.text = id_text
	_form_id_edit.editable = false
	_form_id_edit.tooltip_text = "内容 ID：<地图>-<实体类型>-<实例>-<功能>-<随机码>"
	_form_id_edit.add_theme_font_size_override("font_size", Th.FS_META)
	box.add_child(Kit.field_row("ID", _form_id_edit, 40))

	var target := {"entity": _current_spr(), "binding": f, "doc": _doc_key(), "scope": _content_scope_guard(),
		"project_scope": project_scope}
	var name_edit := LineEdit.new()
	name_edit.text = cname if cname != "" else fn_id
	name_edit.placeholder_text = "显示名（空则用功能 id）"
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var saved_name := {"text": name_edit.text, "value": str(data.get("name", "")), "bound": content_id != ""}
	var push_name := func() -> bool:
		var text := name_edit.text.strip_edges()
		if text == saved_name.text:
			return true
		if not _form_binding_matches(i, target) or not _commit_name(i, text, saved_name):
			return false
		target.binding = _current_fns()[i]
		saved_name.text = text
		return true
	_pending_commits.append(push_name)
	name_edit.text_submitted.connect(func(_t: String): push_name.call())
	name_edit.focus_exited.connect(func(): push_name.call())
	box.add_child(Kit.field_row("显示名", name_edit, 56))

	# 演出功能（声明 "steps": true）：只读摘要 + 子面板入口。步骤数组是这类功能
	# 内容的主体；普通字段/条件区照常渲染在下方（演出功能也可以有字段）。
	if FunctionDecls.fn_has_steps(manifest, fn_id):
		var sdata: Array = data.get("steps", []) if data.get("steps", []) is Array else []
		var parts: Array[String] = []
		for st in sdata:
			var sc := str((st as Dictionary).get("step", "")) if st is Dictionary else ""
			parts.append("%d.%s" % [parts.size() + 1, StepDecls.step_name(manifest, sc)])
		var sum := " → ".join(parts) if not parts.is_empty() else "（空演出：还没有步骤）"
		var srow := Kit.hbox(6)
		var slabel := Kit.hint_label("演出步骤：%s" % sum, RIGHT_W - 200)
		slabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		srow.add_child(slabel)
		srow.add_child(Kit.button("编辑演出", func():
			if _form_binding_matches(i, target):
				_open_steps_editor(i), "primary"))
		box.add_child(srow)
		box.add_child(Kit.divider())

	var fields := FunctionDecls.function_fields(manifest, fn_id)
	if fields.is_empty():
		box.add_child(Kit.hint_label("这个功能没有声明可填字段；填个名字即可。", RIGHT_W - 40))
	var cur: Dictionary = data.get("fields", {}) if data.get("fields", {}) is Dictionary else {}
	for fd in fields:
		if not (fd is Dictionary):
			continue
		box.add_child(_build_field_row(i, fn_id, fd, cur, fields, target))
	# 条件区：功能声明引用的条件库条目。条件参数是实例上填的——同一条件被不同
	# 实例引用时参数各填各的；值与功能字段共存于同一份内容 fields（键=字段码）。
	var cond_fds: Array = []
	for cid in FunctionDecls.function_decl(manifest, fn_id).get("conditions", []):
		var cond_id := str(cid)
		var cdecl := ConditionDecls.condition_decl(manifest, cond_id)
		if cdecl.is_empty():
			continue
		box.add_child(Kit.divider())
		box.add_child(Kit.section_header("条件：%s" % str(cdecl.get("name", cond_id))))
		var cfields: Array = cdecl.get("fields", [])
		if cfields.is_empty():
			box.add_child(Kit.hint_label("这个条件没有可调参数。", RIGHT_W - 40))
		for fd2 in cfields:
			if not (fd2 is Dictionary):
				continue
			cond_fds.append(fd2)
			box.add_child(_build_field_row(i, fn_id, fd2, cur, fields + cfields, target))
	if content_id == "":
		box.add_child(Kit.hint_label("首次修改任意字段即创建内容条目。", RIGHT_W - 40))
	var undeclared := _undeclared_block(fields, cond_fds, cur)
	if undeclared != null:
		box.add_child(undeclared)
	return box

## 内容里有清单没声明的键——保留原值、只读呈现，不删不改。
## 键一律是字段码；对不上声明码 = 声明被删/换码（数据漂移）。
## fields 与 cond_fields 都算「已知」：条件字段与功能字段共存于同一份 fields。
func _undeclared_block(fields: Array, cond_fields: Array, cur: Dictionary) -> Control:
	var known := {}
	for fd in fields:
		if fd is Dictionary:
			known[str((fd as Dictionary).get("code", ""))] = true
	for fd2 in cond_fields:
		if fd2 is Dictionary:
			known[str((fd2 as Dictionary).get("code", ""))] = true
	var extra := []
	for k in cur:
		if str(k) == "" or known.has(str(k)):
			continue
		extra.append(k)
	if extra.is_empty():
		return null
	extra.sort()
	var box := Kit.vbox(4)
	box.add_child(Kit.hint_label(
		"⚠ %d 个字段未在清单中声明（只读保留，不参与编辑）：" % extra.size(), RIGHT_W - 40))
	for k in extra:
		var v = cur[k]
		var txt := str(v) if (v is String or v is StringName) else JSON.stringify(v)
		var row := LineEdit.new()
		row.text = "%s = %s" % [str(k), txt]
		row.editable = false
		row.add_theme_font_size_override("font_size", Th.FS_META)
		row.tooltip_text = "字段码不在清单声明里（声明被删/换码）。补回声明（code 须一致）即可恢复编辑。"
		box.add_child(row)
	return box

## 单个声明字段：交给 field_widgets 按 kind（input / choice）建控件。
## 内容文件里的键一律是字段码（ensure_codes 保证声明都有码，无回退）。
## E1：同图实例引用额外给「画布选…」——临时切回画布点目标，确认才写值
## （取消时原值/焦点都不动，控件也不重建）。
func _build_field_row(i: int, fn_id: String, fd: Dictionary, cur: Dictionary, siblings: Array, target: Dictionary) -> Control:
	var fid := str(fd.get("id", ""))
	var key := str(fd.get("code", ""))
	var val = cur.get(key, fd.get("default", FieldWidgets.default_for(fd)))
	var label := str(fd.get("name", fid))
	# R13：配对地图字段的现值注入 _mapKey——功能/条件字段的实例引用与摆放物引用同一语义
	# （缺省 = 本图；配对字段填了别的图就枚举那张图的实例）。
	var d := fd
	var paired := str(fd.get("mapField", "")) != "" and not siblings.is_empty()
	var tk := RefFields.paired_map_value(fd, siblings, cur) if paired else ""
	if paired:
		if tk != "":
			d = fd.duplicate(true)
			d["_mapKey"] = tk
	var resolve_scope := func() -> Array[String]: return RefFields.frame_scope(fd, siblings, cur)
	var expected := {"present": cur.has(key), "value": cur.get(key)}.duplicate(true)
	var set_value := func(v, check_scope: Callable) -> bool:
		if not _form_binding_matches(i, target):
			return false
		var cid := str(target.binding.get("content", ""))
		var had_content := cid != ""
		if not _set_field(i, fn_id, key, v, expected, check_scope):
			return false
		if expected.present:
			cur[key] = expected.value
		if not had_content and i < _current_fns().size():
			target.binding = _current_fns()[i]
		return true
	var apply := func(v) -> bool:
		return set_value.call(v, func(values: Dictionary):
			return not paired or RefFields.paired_map_value(fd, siblings, values) == tk)
	var options := func(decl: Dictionary) -> Array:
		return _resolve_options(decl, bool(target.project_scope))
	var frame_pick := func(row: Control, nested: Dictionary, pair: Callable, save: Callable, read: Callable):
		FrameReference.add_reference_button(app, row, nested, pair, save, options, bool(target.project_scope), _rebuild_right, "", read)
	var built := FieldWidgets.build(d, val, apply, options, "code", frame_pick)
	if built.get("commit") is Callable and (built.commit as Callable).is_valid():
		_pending_commits.append(built.commit)
	var row := Kit.field_row(label, built.ctl, 96)
	# E1：按声明显示能给出的说明（类型/范围/缺省/码）；契约没有独立说明/单位键，不发明
	var tip := FieldWidgets.decl_tooltip(fd)
	if tip != "":
		row.tooltip_text = tip
	var pickable := FieldWidgets.wants_canvas_pick(fd) and (not bool(target.project_scope) or tk != "")
	if pickable and not FieldWidgets.ordered_frame_pick(fd) and not bool(fd.get("multiple", false)) and can_pick_on_canvas(tk):
		var pick := Kit.button("画布选…", func():
			_pick_entity_for(fd, apply), "ghost")
		pick.tooltip_text = "临时切到画布点一个实例；确认才写入，取消不改当前值" \
			if not FieldWidgets.wants_cell_pick(fd) else \
			"临时切到画布点格图里的一格（按多边形命中）；确认才写入，取消不改当前值"
		pick.add_theme_font_size_override("font_size", Th.FS_META)
		row.add_child(pick)
	if FieldWidgets.wants_frame_pick(fd) and FieldWidgets.frame_value_available(fd, built):
		var save := func(value) -> bool:
			var scope: Array = resolve_scope.call()
			return set_value.call(value, func(fields: Dictionary): return RefFields.frame_scope(fd, siblings, fields) == scope)
		FrameReference.add_reference_button(app, row, fd, resolve_scope, save, options, bool(target.project_scope),
			_rebuild_right, "", built.get("pick_values", Callable()))
	return row

func _form_binding_matches(i: int, target: Dictionary) -> bool:
	if not target.scope.call() or target.doc != _doc_key() or target.entity != _current_spr():
		return false
	var rows := _current_fns()
	return i >= 0 and i < rows.size() and is_same(rows[i], target.binding)

## E1：为一个实例引用字段开画布选点（宿主 = app，会话管理与确认条都在那边）。
## 确认回调只写字段值；字段写盘走与手选下拉同一条 _set_field。
## C4：cell_id 字段走同一会话，accept="cell"（候选来自格图多边形，不走实例命中）。
func _pick_entity_for(fd: Dictionary, commit: Callable) -> void:
	var fname := str(fd.get("name", str(fd.get("id", ""))))
	var mode := FieldWidgets.pick_mode(fd)
	var is_cell := mode == "cell"
	var is_edge := mode == "edge"
	var hint := "为「%s」选一格（格图）" % fname if is_cell \
		else ("为「%s」选一条格边（靠近格边点）" % fname if is_edge else "为「%s」选目标实例" % fname)
	var of := FieldWidgets.canvas_pick_types(fd)
	if mode == "port":
		hint = "为「%s」选目标端口" % fname
	if not is_cell and not is_edge and not of.is_empty():
		hint += "（限定类型：%s）" % ",".join(PackedStringArray(of))
	# 单独建回调再传：多行 lambda 直接塞进实参列表容易读错缩进边界
	# 边字段的值是对象 {map, cell, edge}，画布给的是它的 JSON 串——与端口引用同一编码，
	# 这里解码回对象再写，保证落盘形状一致（choice 控件也按同一编码显示）。
	var on_ok := func(code: String):
		if code == "":
			return
		var value = FieldWidgets.decode_pick(mode, code)
		if value == null or not commit.call(value):
			return
		# 下拉控件还停在旧值：提交后重建右栏让新值上屏（用户主动确认的写盘）
		_rebuild_right()
	app._begin_canvas_pick("content", mode, hint, on_ok, Callable(), of)

## choice.source 的选项来源解析（由游戏侧声明，编辑器只查不解释）。
## 支持：content:<功能id>（内容库）、entity:<id,id>（清单实体类型）、
## entity_inst:<id,id>（当前图实例，值=实例码）、map（值=地图码，显示图名）、audio:（音频池）、
## layer:（当前图用户层栈，值=层码，显示「序号.层名」）、
## asset:<kind>:<id,id>（资产引用，kind 空 = 全部；asset_ref 类型的 input 字段也走这里）。
func can_pick_on_canvas(map_key: String) -> bool:
	return _map_ready() and RefFields.map_key_local(map_key, app.canvas.cur_map_code())

## 临时地图只影响候选；不写入内容文件，也不覆盖字段自身的配对地图。
func reference_context_selector(current: String, on_change: Callable) -> OptionButton:
	var select := OptionButton.new()
	select.name = "ReferenceContextMap"
	select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	select.tooltip_text = "只用来选择本图引用。已声明的配对地图优先，不会保存此选择。"
	select.add_item("不指定")
	select.set_item_metadata(0, "")
	for option in _resolve_options({"source": "map"}):
		var key := str(option.v)
		var i := select.item_count
		select.add_item(str(option.t))
		select.set_item_metadata(i, key)
		if key == current:
			select.select(i)
	var selected := [select.selected]
	select.item_selected.connect(func(i: int):
		if not bool(on_change.call(str(select.get_item_metadata(i)))):
			select.select(int(selected[0]))
		else:
			selected[0] = i)
	return select

func project_reference_options(decl: Dictionary, context: String) -> Array:
	if context == "" or str(decl.get("_mapKey", "")) != "":
		return _resolve_options(decl, true)
	var source := str(decl.get("source", ""))
	if source == "editor:reference-maps":
		var resolved := ReferenceIndex.resolve_map(manifest, context)
		var options := ReferenceIndex.map_target_options(manifest).filter(func(map):
			return map.name != resolved.key).map(func(map):
			return {"v": map.code, "t": map.name})
		if not options.is_empty():
			options.push_front({"v": "", "t": "内容所属地图 · " + str(resolved.key if resolved.status == "ok" else context)})
		return options
	if not (source.begins_with("entity_inst:") or source.begins_with("cell:") \
			or source.begins_with("port:") or source.begins_with("edge:") or source == "layer:"):
		return _resolve_options(decl, true)
	var scoped := decl.duplicate()
	scoped["_mapKey"] = context
	var options := _resolve_options(scoped, true)
	if source == "edge:coordinates" and not options.is_empty():
		options[0]["code"] = ""
		return options
	if source.begins_with("port:") or source.begins_with("edge:"):
		var local: Array = []
		for option in options:
			var value = JSON.parse_string(str(option.v))
			if value is Dictionary:
				value["map"] = ""
				local.append({"t": option.t, "v": JSON.stringify(value)})
		return local
	return options

func _resolve_options(decl: Dictionary, project_scope := false, saved_only := false) -> Array:
	if str(decl.get("source", "")) == "editor:condition-schema":
		return ConditionDecls.allowed_rows(manifest, decl)

	var src := str(decl.get("source", ""))
	if src == "editor:reference-maps":
		var local := not project_scope and not saved_only and _map_ready()
		var options := ReferenceIndex.map_target_options(manifest).filter(func(map):
			return not local or map.name != app.canvas.cur_map_name).map(func(map):
			return {"v": map.code, "t": map.name})
		if local and not options.is_empty():
			options.push_front({"v": "", "t": "当前地图（工作副本）"})
		return options
	if src == "editor:flow-target":
		var working_map := {}
		if not project_scope and not saved_only and app.map_loaded:
			if not decl.domains.get("arrivalPorts", []).is_empty():
				working_map = app.canvas.arrival_snapshot()
			elif decl.domains.get("maps") == true:
				working_map = {"meta": app.canvas.map_data.meta}
		return StartupTargets.destination_options(manifest, decl.domains, working_map).map(func(option):
			return {"v": JSON.stringify(option.target), "t": option.name})
	if src == "view:":
		return ReferenceIndex.view_ids(manifest).map(func(id: String): return {"v": id, "t": id})
	if src.begins_with("content:"):
		var kind := src.substr(8)
		var out: Array = []
		for cid in ContentStore.list_ids(manifest, kind):
			var d := ContentStore.read(manifest, kind, str(cid))
			var nm := str(d.get("name", ""))
			out.append({"v": str(cid), "t": ("%s  %s" % [str(cid), nm]) if nm != "" else str(cid)})
		return out
	if src.begins_with("entity:"):
		var want := src.substr(7).split(",", false)
		var out2: Array = []
		for e in AssetDecl.of_kind_placed(manifest, "entity"):
			var sid := str((e as Dictionary).get("id", ""))
			if not want.is_empty() and not want.has(sid):
				continue
			out2.append({"v": sid, "t": str((e as Dictionary).get("name", sid))})
		return out2
	if src.begins_with("entity_inst:"):
	# 实例级来源：列实例（值=实例码）。目标域 = 声明的 _mapKey（配对地图字段，C1）：
	# 有目标图就枚举目标图实例（跨图引用按 (地图码, 实例码) 语义），否则列当前图。
		var want := src.substr(12).split(",", false)
		var map_key := str(decl.get("_mapKey", ""))
		if project_scope and map_key == "":
			return []
		if map_key != "" and (saved_only or not can_pick_on_canvas(map_key)):
			return RefFields.map_instances(manifest, map_key, Array(want))
		var out4: Array = []
		if _map_ready():
			for e0 in app.canvas.ents_all():
				var spr := e0 as EntityNode
				if spr == null or not spr.is_entity():
					continue
				var sid0 := spr.asset
				if not want.is_empty() and not want.has(sid0):
					continue
				var c0 := spr.code
				if c0 == "":
					continue
				var cell: Vector2i = spr.cell()
				# 标签带实例码：同类型同格的多个实例（多楼层/叠放）靠码区分，否则下拉项完全同名
				out4.append({"v": c0, "t": "%s %s · (%d,%d)" % [
					str(app._scene_name(sid0)), c0, cell.x, cell.y]})
		return out4
	if src.begins_with("port:"):
		# C3：端口候选 = 配对图（_mapKey）优先，缺省本图；of 白名单 = 端口类型过滤。
		var pk := src.substr(5).split(",", false)
		var pmap := str(decl.get("_mapKey", ""))
		if project_scope and pmap == "":
			return []
		if not saved_only and can_pick_on_canvas(pmap):
			var rows: Array = []
			for ent in app.canvas.ents_all():
				if ent is EntityNode and ent.is_entity():
					rows.append({"asset": ent.asset, "code": ent.code})
			var map_code: String = app.canvas.cur_map_code()
			return RefFields.port_options(manifest, map_code,
				rows, Array(pk))
		return RefFields.port_candidates(manifest, pmap, Array(pk))
	if src.begins_with("cell:"):
		# 有限格图使用配对地图，并可限定候选的局部空间。
		var map_key := str(decl.get("_mapKey", ""))
		var snap := {}
		if project_scope and map_key == "":
			return []
		if not saved_only and can_pick_on_canvas(map_key):
			snap = app.canvas.map_data
		elif map_key != "":
			var rm := ReferenceIndex.resolve_map(manifest, map_key)
			if rm.status == "ok":
				snap = MapStore.read(manifest, str(rm.key))
		var cg := CellGraph.graph_of(snap.get("meta", {}) as Dictionary)
		return CellGraph.cell_options(cg, CellGraph.cell_source_space(decl))
	if src.begins_with("edge:"):
		# §7.4：格边候选 = 两侧都有瓦片的相邻格对（按规范代表边去重）。
		# 配对图（_mapKey）指向别的图时读那张图的文档；否则直接用画布活体瓦片层（未保存也能选）。
		var emap := str(decl.get("_mapKey", ""))
		if project_scope and emap == "":
			return []
		if src == "edge:coordinates":
			if not saved_only and can_pick_on_canvas(emap):
				return [RefFields.edge_context(app.canvas.map_data.meta, manifest)]
			var map := RefFields.edge_map(manifest, emap) if emap != "" else {}
			return [] if map.is_empty() else [RefFields.edge_context(map.meta, manifest)]
		if not saved_only and can_pick_on_canvas(emap):
			return app.canvas._edge_candidates()
		return RefFields.edge_candidates(manifest, emap) if emap != "" else []
	if src.begins_with("viewport:"):
		# C5：具名参考画幅候选（清单 viewports：[{id, w, h}]）。缺声明 = 无候选（控件保留原值）。
		var outv: Array = []
		for vp in (manifest.get("viewports", []) as Array):
			if vp is Dictionary and str((vp as Dictionary).get("id", "")) != "":
				outv.append({"v": str((vp as Dictionary).get("id", "")), "t": "%s（%dx%d）" % [str((vp as Dictionary).get("id", "")), int((vp as Dictionary).get("w", 0)), int((vp as Dictionary).get("h", 0))]})
		return outv
	if src == "layer:":
		var key := str(decl.get("_mapKey", ""))
		var layers: Array = []
		if not saved_only and (key != "" or not project_scope) and can_pick_on_canvas(key):
			layers = app.canvas.layers_decl()
		elif key != "":
			var resolved := ReferenceIndex.resolve_map(manifest, key)
			if resolved.status == "ok":
				layers = MapStore.read(manifest, str(resolved.key)).get("meta", {}).get("layers", [])
		var outl: Array = []
		var li := 0
		for L in layers:
			outl.append({"v": str(L.get("id", "")), "t": "%d.%s" % [li + 1, str(L.get("name", ""))]})
			li += 1
		return outl
	if src == "audio:":
		# 音频池来源：列音频声明（值=音频码，显示名），路径解释权在游戏侧。
		var out5: Array = []
		for aid in AudioDecls.audio(manifest):
			var ad: Dictionary = (AudioDecls.audio(manifest) as Dictionary)[aid]
			out5.append({"v": str(ad.get("code", "")), "t": str(ad.get("name", aid))})
		return out5
	if src.begins_with("asset:"):
		# asset:<kind>[:<id,id>] —— 资产引用（asset_ref）的选项来源；值 = 资产 id。
		# R13：保留空段（asset::AB23 = kind 空 + ID 白名单）——与 RefFields.describe 同一语义。
		var rest := src.substr(6)
		var cut := rest.find(":")
		var want_kind := rest if cut < 0 else rest.substr(0, cut)
		var ids_s := "" if cut < 0 else rest.substr(cut + 1)
		var want_ids: Array = Array(ids_s.split(",", false))
		var assets := AssetDecl.all(manifest)
		var out6: Array = []
		for a in assets:
			var ad: Dictionary = assets[a]
			var aid := str(ad.get("id", ""))
			if want_kind != "" and str(ad.get("kind", "")) != want_kind:
				continue
			if not want_ids.is_empty() and not want_ids.has(aid):
				continue
			out6.append({"v": aid, "t": str(ad.get("name", aid))})
		return out6
	if src == "map":
		return ReferenceIndex.map_target_options(manifest).map(func(row):
			return {"v": row.code, "t": row.name})
	return []


## 读内容：暂存中的条目优先（还没落盘），否则读盘。
func _content_read(fn_id: String, cid: String) -> Dictionary:
	var st = _staged_get(fn_id, cid)
	if st is Dictionary:
		return (st.data as Dictionary).duplicate(true)
	return ContentStore.read(manifest, fn_id, cid)

## 读内容并带出磁盘文本摘要（F1/P04 写前基线）：{data, digest}。
## 暂存条目没有磁盘基线（digest 为空 = 不比对，写盘时只落在 flushed 之后）。
func _content_read_ex(fn_id: String, cid: String) -> Dictionary:
	var st = _staged_get(fn_id, cid)
	if st is Dictionary:
		return {"data": (st.data as Dictionary).duplicate(true), "digest": ""}
	var res := ContentStore.read_ex(manifest, fn_id, cid)
	return {"data": res.data if str(res.status) == "ok" else {},
		"digest": str(res.get("digest", "")) if str(res.status) == "ok" else ""}

## 写内容：暂存中的条目只更新内存（staged），已落盘的条目照旧即时写盘（field_edit 允许）。
## base_digest = 读到内容时的磁盘摘要；非空时写前比对，磁盘被外部改过就不覆盖（P04）。
## 返回 "ok" / "conflict" / "fail"。
func _content_write(fn_id: String, cid: String, data: Dictionary, base_digest := "") -> String:
	var st = _staged_get(fn_id, cid)
	if st is Dictionary:
		(st as Dictionary)["data"] = data.duplicate(true)
		return "ok"
	var res := ContentStore.write_ex(manifest, fn_id, cid, data, base_digest)
	if bool(res.get("conflict", false)):
		return "conflict"
	return "ok" if bool(res.get("ok", false)) else "fail"

## 写前发现磁盘内容被外部改过（F1/P04）：不覆盖、不改画布，只提示去重开。
## 内容文件每次保存都有 .history 备份，但外部改动是别人的工作，静默吞掉比报错更糟。
func _content_conflict(cid: String) -> void:
	app._set_status(" 内容 %s 已被外部修改，本次未写入：点击「重读内容」后再改" % cid)

## 字段改动：写内容文件。content 为空时生成 ID 并暂存（A2 staged）。
## 约定：字段值落在 content/<kind>/<id>.json，属「内容资产」而非地图快照——
## 不走画布整图撤销（撤销一张 10 万格地图不该只为了回滚一个字段）；已落盘内容
## 改走 ContentKey 差量（§7.5 阶段二）：记录改前/改后整份内容 + 两侧摘要，
## undo 只写回那一个文件，盘上被外部改过则拒绝覆盖。
## 连续控件只在失焦/回车提交。
func _set_field(i: int, fn_id: String, key: String, value, expected: Dictionary, check_pair: Callable) -> bool:
	if value is String:
		value = (value as String).strip_edges()
	if key == "" or fn_id == "":
		return false
	var cid := _ensure_content(i)
	if cid == "":
		_ensure_failed()
		return false
	var rd := _content_read_ex(fn_id, cid)
	var data: Dictionary = rd.data
	if data.is_empty():
		_content_conflict(cid)
		return false
	var before: Dictionary = data.duplicate(true)
	var fields: Dictionary = data.get("fields", {}) if data.get("fields", {}) is Dictionary else {}
	if not check_pair.call(fields) or fields.has(key) != expected.present or fields.get(key) != expected.value:
		_content_conflict(cid)
		return false
	if fields.get(key) == value:
		return true
	fields[key] = value
	data["fields"] = fields
	var wr := _content_write(fn_id, cid, data, str(rd.digest))
	if wr == "conflict":
		_content_conflict(cid)
		return false
	if wr != "ok":
		_ensure_failed()
		return false
	var stored: Dictionary = _content_read_ex(fn_id, cid).data.get("fields", fields)
	expected.merge({"present": stored.has(key), "value": stored.get(key)}.duplicate(true), true)
	_record_content_delta(fn_id, cid, before, data, str(rd.digest))
	_refresh_value_only()
	return true

## 内容差量记账（ContentKey = 功能 id + 内容 id）：只记已落盘的那份内容。
## digest_before 为空（新建/staged）不记——这类内容撤销等于放弃暂存，由暂存复核处理。
func _record_content_delta(fn_id: String, cid: String, before: Dictionary, after: Dictionary,
		digest_before: String) -> void:
	if digest_before == "" or app == null or app.canvas == null:
		return
	var path := ContentStore.path_for(manifest, fn_id, cid)
	var digest_after := ContentStore.file_digest(path) if path != "" else ""
	app.canvas._undo_history_ctrl.record_content(fn_id, cid, before, after, digest_before, digest_after)

## 显示名：内容条目的 name；改动写内容文件并同步实例绑定的 name（列表读的是绑定）。
func _commit_name(i: int, text: String, expected: Dictionary) -> bool:
	var fns := _current_fns()
	if i < 0 or i >= fns.size():
		return false
	var f: Dictionary = fns[i] if fns[i] is Dictionary else {}
	var fn_id := str(_resolve_fn(f).get("id", ""))
	var nm := text.strip_edges()
	if nm == "":
		nm = fn_id
	var cid := str(f.get("content", ""))
	if cid == "":
		# 只改名字不创建内容：绑定里的 name 先记下，保持列表可读
		if str(f.get("name", "")) == nm:
			return true
		var spr0 := _current_spr()
		fns = fns.duplicate(true)
		(fns[i] as Dictionary)["name"] = nm
		_write_fns(spr0, fns)
		_refresh_status_only()
		return true
	var rd := _content_read_ex(fn_id, cid)
	var data: Dictionary = rd.data
	if data.is_empty() or (expected.bound and str(data.get("name", "")) != expected.value):
		_content_conflict(cid)
		return false
	if str(data.get("name", "")) == nm:
		expected.merge({"bound": true, "value": nm}, true)
		return true
	var before: Dictionary = data.duplicate(true)
	data["name"] = nm
	var wr := _content_write(fn_id, cid, data, str(rd.digest))
	if wr == "conflict":
		_content_conflict(cid)
		return false
	if wr != "ok":
		_ensure_failed()
		return false
	expected.merge({"bound": true, "value": nm}, true)
	_record_content_delta(fn_id, cid, before, data, str(rd.digest))
	var spr := _current_spr()
	fns = fns.duplicate(true)
	(fns[i] as Dictionary)["name"] = nm
	_write_fns(spr, fns)
	_refresh_status_only()
	return true

## 新内容条目骨架：function 写功能码（执行引用），目录名仍是人类名（可读）。
func _blank_content(fn_id: String, cid: String) -> Dictionary:
	return {"id": cid, "function": FunctionDecls.fn_code(manifest, fn_id),
		"name": fn_id, "fields": {}}

## 内容文件的 "function" 键与清单当前执行码不一致时返回文件里的旧码（一致或未记录返回空串）。
## 只用于提示：清单改码后旧内容不会自动重写，等用户下次改动该内容时才以当前码落盘。
func _function_code_drift(data: Dictionary, fn_id: String) -> String:
	if data.is_empty() or fn_id == "":
		return ""
	var stored := str(data.get("function", ""))
	var current := FunctionDecls.fn_code(manifest, fn_id)
	if stored == "" or current == "" or stored == current:
		return ""
	return stored

## 保证该附加功能有 content id：已有绑定直接返回；没有就生成新 ID 但**不写盘**（A2 staged）——
## 新内容要等正式保存/试玩走 commit_document 才落地，避免「打开表单看一眼」就凭空生成文件。
## 用功能 ID 与新内容 ID 登记暂存，正式地图提交再写入。
## 返回空串 = 生成失败（调用方给出可见反馈，不静默吞掉）。
func _ensure_content(i: int) -> String:
	var fns := _current_fns()
	if i < 0 or i >= fns.size():
		return ""
	var f: Dictionary = fns[i] if fns[i] is Dictionary else {}
	var cid := str(f.get("content", ""))
	if cid != "":
		return cid
	var fn_id := str(_resolve_fn(f).get("id", ""))
	var spr := _current_spr()
	if spr == null or fn_id == "":
		return ""
	var cand := _content_id_for(spr, fn_id)
	var new_id := ContentId.unique(manifest, fn_id, cand)
	if new_id == "":
		return ""
	var nm := str(f.get("name", "")) if str(f.get("name", "")) != "" else fn_id
	var data := _blank_content(fn_id, new_id)
	data["name"] = nm
	# 暂存：只在内存登记，等正式提交再写（staged）
	_staged_put(fn_id, new_id, {"fn_id": fn_id, "data": data, "ent": spr.code, "doc": _doc_key()})
	app._set_status(" 新内容 %s 已暂存：Ctrl+S 或试玩时落盘" % new_id)
	fns = fns.duplicate(true)
	(fns[i] as Dictionary)["content"] = new_id
	(fns[i] as Dictionary)["name"] = nm
	# 新绑定也先写进画布（内存），它同样属于 staged 范围；正式提交时随地图一起落盘
	host._write_fns(spr, fns)
	if _form_id_edit != null:
		_form_id_edit.text = new_id
	return new_id

## 暂存内容：{"fn_id\u0001content_id": {fn_id, cid, data, ent, doc}}。
## 键必须含功能 ID——多个功能目录下可以存在同名 cid，
## 只按裸 cid 索引会读到/覆盖另一份内容（V4 P0-6）。
## doc（R02 工作副本归属）= 项目根|地图码：冲刷只写当前文档（地图）的条目，
## 切图后旧图的暂存不跟新图落盘；绑定身份复核失败（撤销/删绑定）就地丢弃。
var _staged := {}

## 暂存键：功能 ID 与内容 ID 联合唯一。
func _staged_key(fn_id: String, cid: String) -> String:
	return str(fn_id) + "\u0001" + str(cid)

func _staged_get(fn_id: String, cid: String) -> Variant:
	return _staged.get(_staged_key(fn_id, cid))

## 写暂存条目（自动补 cid 键，避免调用点各自拼键）。
func _staged_put(fn_id: String, cid: String, st: Dictionary) -> void:
	var s := st.duplicate(true)
	s["fn_id"] = fn_id
	s["cid"] = cid
	s["expect_absent"] = bool(s.get("expect_absent", true))
	_staged[_staged_key(fn_id, cid)] = s

func _staged_erase(fn_id: String, cid: String) -> void:
	_staged.erase(_staged_key(fn_id, cid))

## 当前文档键（R02）：项目根 + 地图码（无码退回图名）。
func _doc_key() -> String:
	var root := str(app.manifest.get("_dir", ""))
	var code := ""
	if app.map_loaded and app.canvas != null and app.canvas.map_data.get("meta", null) is Dictionary:
		code = str((app.canvas.map_data["meta"] as Dictionary).get("code", ""))
	if code == "":
		code = str(app.cur_map_name)
	return root.path_join(code)

## 暂存条目按功能执行码与内容 ID 匹配地图绑定；单个实例的解绑不影响共享内容。
func bound_staged_rows(map_data: Dictionary) -> Array:
	var bindings := {}
	for obj in map_data.get("objects", []):
		if str(obj.get("code", "")) == "":
			continue
		for binding in obj.get("functions", []):
			if binding is Dictionary:
				bindings[[str(binding.get("fn", "")), str(binding.get("content", ""))]] = true
	var doc := _doc_key()
	var rows: Array = []
	for key in _staged.keys():
		var row: Dictionary = _staged[key]
		if row.doc != doc:
			continue
		if map_data.is_empty() or bindings.has([FunctionDecls.fn_code(manifest, row.fn_id), row.cid]):
			rows.append(row)
		else:
			_staged.erase(key)
	return rows


## 已解绑的草稿丢弃。写入失败时保留失败条目和其后未写的条目。
func save_staged_content(map_data: Dictionary) -> String:
	for row in bound_staged_rows(map_data):
		var baseline := str(row.get("baseline", ""))
		if not row.expect_absent and baseline == "":
			return "暂存内容缺少替换基线：%s" % row.cid
		var result := ContentStore.write_ex(manifest, row.fn_id, row.cid, row.data,
			baseline, false, row.expect_absent)
		if result.get("conflict", false):
			return "内容文件已被外部创建或改动：%s" % row.cid
		if not result.get("ok", false):
			return "无法写入内容：%s" % row.cid
		_staged_erase(row.fn_id, row.cid)
	return ""


## 消费冻结计划中已落盘的内容，失败目标继续留在工作副本里。
func consume_written_staged(receipts: Array) -> void:
	var doc := _doc_key()
	for row in receipts:
		if row.get("kind") != "content" or row.get("status") != "written":
			continue
		var fn_id := str(row.get("fn_id", ""))
		var cid := str(row.get("id", ""))
		var staged = _staged_get(fn_id, cid)
		if staged is Dictionary and staged.get("doc") == doc:
			_staged_erase(fn_id, cid)

func has_staged() -> bool:
	return not _staged.is_empty()

## 当前文档的暂存行 [{fn_id, cid, data}]（提交日志/草稿冻结目标用，R04）。
func staged_rows_for_current_doc() -> Array:
	var doc := _doc_key()
	var out: Array = []
	for key in _staged:
		var st: Dictionary = _staged[key]
		if str(st.get("doc", "")) != doc:
			continue
		var cid := str(st.get("cid", ""))
		if cid == "":
			cid = str(key) if not str(key).contains("\u0001") else str(key).split("\u0001")[1]
		out.append({"fn_id": str(st.get("fn_id", "")), "cid": cid,
			"data": (st.get("data", {}) as Dictionary).duplicate(true)})
	return out

## 当前文档的暂存内容 {内容ID: data}：整图复制要把未落盘的绑定内容一起带进副本
## （只读磁盘副本会把这些内容判成缺失/丢内容，V4 P1）。键只用内容 ID——ClonePlan 按
## 绑定行里的 content 值查表，与功能 id 无关。
func staged_data_by_key() -> Dictionary:
	var out := {}
	for row in staged_rows_for_current_doc():
		var cid := str(row.get("cid", ""))
		var dat = row.get("data", null)
		if cid != "" and dat is Dictionary:
			out[_staged_key(str(row.fn_id), cid)] = (dat as Dictionary).duplicate(true)
	return out

## 当前文档是否有暂存内容。
func has_staged_for_current_doc() -> bool:
	if _staged.is_empty():
		return false
	var doc := _doc_key()
	for key in _staged:
		if str((_staged[key] as Dictionary).get("doc", "")) == doc:
			return true
	return false

## 地图成功切换后，只清理被替换文档的暂存。
func drop_staged_for_doc(doc: String) -> int:
	var dropped := 0
	for key in _staged.keys():
		if str((_staged[key] as Dictionary).get("doc", "")) == doc:
			_staged.erase(key)
			dropped += 1
	return dropped

## 草稿恢复：把待提交内容载荷重新暂存（R03）。绑定还在的才收，返回收下的条数。
func restage_rows(rows: Array) -> int:
	var doc := _doc_key()
	var n := 0
	for row in rows:
		if not (row is Dictionary):
			continue
		var r: Dictionary = row
		var cid := str(r.get("cid", "")) if r.has("cid") else str(r.get("id", ""))
		var fn_id := str(r.get("fn_id", ""))
		var dat = r.get("data", null)
		if cid == "" or fn_id == "" or not (dat is Dictionary):
			continue
		if _staged_get(fn_id, cid) != null:
			continue
		# 找回绑定身份：恢复后的画布上找 content==cid 的绑定行（复核用）
		var ent := ""
		if _map_ready():
			for e0 in host._entities():
				var r0: Dictionary = e0
				for f0 in (r0.get("fns", []) as Array):
					if f0 is Dictionary and str((f0 as Dictionary).get("content", "")) == cid:
						ent = str(r0.get("code", ""))
						break
				if ent != "":
					break
		if ent == "" and _map_ready():
			continue   # 绑定不在恢复后的画布上：这条不收（写盘只会造孤儿文件）
		_staged_put(fn_id, cid, {"fn_id": fn_id, "data": dat,
			"ent": ent, "doc": doc})
		n += 1
	return n

## 复制粘贴产生的暂存（R12）：粘贴路径不再当场写盘——新内容随正式提交
## （Ctrl+S / 试玩）才落盘；撤销恢复地图后绑定消失，R02 的绑定复核就地丢弃，
## 不再留下孤儿内容文件。ent = 拥有该内容的副本实例码（复核身份）。
func stage_clone(fn_id: String, cid: String, data: Dictionary, ent: String) -> void:
	if fn_id == "" or cid == "" or _staged_get(fn_id, cid) != null:
		return
	_staged_put(fn_id, cid, {"fn_id": fn_id, "data": data,
		"ent": ent, "doc": _doc_key()})

## 写盘失败：状态栏 + 徽章双重提示（红色徽章在右栏顶部，不依赖状态栏可见性）
## 不再一律甩「目录权限」——真实失败原因多半是身份码没生成或 kind 不合法。
func _ensure_failed() -> void:
	var cur := _current_spr()
	if cur == null:
		app._set_status(" 内容写入失败：当前没有选中实例")
	elif cur.code == "":
		app._set_status("  内容写入失败：这个实例还没有身份码（重新放置一次再试）")
	else:
		app._set_status("  内容写入失败：检查 content 目录是否存在且可写")
	if _r_badge != null:
		_r_badge.visible = true
		Kit.set_badge(_r_badge, "写盘失败", Th.ERR)

## 只刷左列/预览，不重建右栏——表单重建会丢输入焦点，改一个字段就跳走无法连续输入。
## 名字进左列标签，改名后必须重建行；只改字段值时行内容没变，走 _refresh_value_only。
func _refresh_status_only() -> void:
	_rebuild_rows()
	if _preview != null:
		_preview.refresh()

## F1/P04：改字段值只影响内容文件，左列行显示的是「类型名 + 实例码」，一个都不变。
## 原实现每次改值都重建整列控件（满图时几百行 × 每行五个控件），输入大字段时明显卡。
func _refresh_value_only() -> void:
	if _preview != null:
		_preview.refresh()

# ──────────── 库复用弹窗 ────────────

## 列同功能的全部内容条目；选中一条 → 复制成新 ID 追加到当前实例末尾。
## 跨功能不列：字段声明不同，复用没有意义。
## E3：名称筛选 + 改显示名（保 ID）+ 删除（先跑 C3 引用检查，仍被引用时停住）。
func _open_lib(i: int) -> void:
	if not commit():
		return
	var fns := _current_fns()
	if i < 0 or i >= fns.size():
		return
	var f: Dictionary = fns[i] if fns[i] is Dictionary else {}
	var fn_id := str(_resolve_fn(f).get("id", ""))
	if fn_id == "":
		return
	var target := {"entity": _current_spr(), "binding": f, "doc": _doc_key(), "scope": _content_scope_guard()}
	var fn_label := str(FunctionDecls.function_name(manifest, fn_id))
	var shell: Dictionary = app._popup_body("选择已有%s内容" % fn_label,
		"选中即复制进当前实例，生成新 ID。改显示名不改 ID；删除前先查引用。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var ids := ContentStore.list_ids(manifest, fn_id)
	# 暂存中的新内容也列进来（还没落盘，但用户可以复用）
	for key in _staged:
		var st_l: Dictionary = _staged[key] if _staged[key] is Dictionary else {}
		var sid := str(st_l.get("cid", key))
		if str(st_l.get("fn_id", "")) == fn_id and not ids.has(sid):
			ids.append(sid)
	if ids.is_empty():
		body.add_child(Kit.empty_state("◌", "这个功能还没有已有内容",
			"先在别的实例里填一条，或直接在新实例里新建"))
		body.add_child(Kit.popup_buttons(func(): pop.hide(), func(): pop.hide(), "关闭", "取消"))
		app._open_popup(pop)
		return

	# —— 名称筛选（E3）+ 引用状态筛选（C2）——
	var filter := LineEdit.new()
	filter.placeholder_text = "筛选：名称或 id"
	filter.clear_button_enabled = true
	var state_opt := OptionButton.new()
	state_opt.add_item("全部")
	state_opt.add_item("被引用")
	state_opt.add_item("未被引用")
	state_opt.tooltip_text = "按入边数筛选：被引用 = 至少一条绑定或内容入边（◆n 后缀）"
	var state_row := Kit.hbox(6)
	state_row.add_child(filter)
	state_row.add_child(state_opt)
	body.add_child(state_row)

	# C2：批量引用扫描（一次读盘）——筛选与行详情共用；活体绑定从画布收集
	var live_binds: Array = []
	if _map_ready():
		var fcode := FunctionDecls.fn_code(manifest, fn_id)
		for ent_row in host._entities():
			for fb in ((ent_row as Dictionary).get("fns", []) as Array):
				if not (fb is Dictionary):
					continue
				if str((fb as Dictionary).get("content", "")) == "":
					continue
				if fcode != "" and str((fb as Dictionary).get("fn", "")) != fcode:
					continue
				live_binds.append({"cid": str((fb as Dictionary).get("content", "")), "code": str((ent_row as Dictionary).get("code", ""))})
	var bulk := ReferenceUsage.content_edges_bulk(manifest, fn_id, ids, app.canvas.cur_map_name, live_binds)

	var list := ItemList.new()
	list.custom_minimum_size = Vector2(0, 200)
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.max_columns = 1
	var picked := [""]
	# 每行的 {cid, name}：筛选重填时名字从这份快照取（不逐项重读盘）
	var rows: Array = []
	for cid in ids:
		var d := ContentStore.read(manifest, fn_id, str(cid))
		var bulk_refs: Dictionary = bulk.get("refs", {})
		var bref: Dictionary = (bulk_refs.get(str(cid), {}) if bulk_refs.has(str(cid)) else {"n": 0})
		rows.append({"cid": str(cid), "name": str(d.get("name", "")), "n": int(bref.get("n", 0))})
	body.add_child(list)

	var refill := func():
		var q := str(filter.text).strip_edges().to_lower()
		list.clear()
		for r in rows:
			var cid := str((r as Dictionary).get("cid", ""))
			var nm := str((r as Dictionary).get("name", ""))
			if q != "" and not cid.to_lower().contains(q) and not nm.to_lower().contains(q):
				continue
			# C2：引用状态筛选 + 入边数后缀（◆n = 绑定实例+内容入边总数）
			var n: int = int((r as Dictionary).get("n", 0))
			if state_opt.selected == 1 and n == 0:
				continue
			if state_opt.selected == 2 and n > 0:
				continue
			var it := list.add_item(((nm + "  ·  " + cid) if nm != "" else cid) + ("  ◆%d" % n if n > 0 else ""))
			list.set_item_metadata(it, cid)
			if nm == "":
				list.set_item_custom_fg_color(it, Th.TEXT_MUTE)

	# —— 改显示名（E3）：只改内容文件的 name，ID 与所有引用不动 ——
	var rename_row := Kit.hbox(6)
	var rename_edit := LineEdit.new()
	rename_edit.placeholder_text = "新显示名（选中条目后可改）"
	rename_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rename_row.add_child(rename_edit)
	var on_rename := func():
		if picked[0] == "":
			app._set_status(" 先选一条内容")
			return
		var nm := rename_edit.text.strip_edges()
		if _rename_library_item(fn_id, picked[0], nm):
			for r in rows:
				if str((r as Dictionary).get("cid", "")) == picked[0]:
					(r as Dictionary)["name"] = nm
			refill.call()
	var rename_btn := Kit.button("改显示名", on_rename, "ghost")
	rename_btn.tooltip_text = "只改显示名；内容 ID 不变，已有引用照常解析"
	rename_row.add_child(rename_btn)
	# —— 删除（E3）：先跑 C3 引用检查；仍被引用或有未扫描文件时停在报告 ——
	var on_del := func():
		if picked[0] == "":
			app._set_status(" 先选一条内容")
			return
		var gone: String = picked[0]
		if not await _delete_library_item(fn_id, gone):
			return
		var keep: Array = []
		for r in rows:
			if str((r as Dictionary).get("cid", "")) != gone:
				keep.append(r)
		rows.clear()
		rows.append_array(keep)
		picked[0] = ""
		refill.call()
	var del_btn := Kit.button("删除…", on_del, "ghost")
	del_btn.add_theme_color_override("font_color", Th.ERR)
	del_btn.tooltip_text = "删除这条内容前先查实例与内容间引用；被引用时不会删"
	rename_row.add_child(del_btn)
	# C2：共享改绑——本实例改绑到选中的已有内容（沿用同一 ID），前显示受影响实例
	var share_btn := Kit.button("共享改绑…", func(): _share_rebind(i, fn_id, picked[0]), "ghost")
	share_btn.tooltip_text = "本实例改绑到选中内容（不再复制新 ID）；确认框列出正被谁引用"
	rename_row.add_child(share_btn)
	body.add_child(rename_row)

	filter.text_changed.connect(func(_t: String): refill.call())
	state_opt.item_selected.connect(func(_i: int): refill.call())
	refill.call()

	var name_edit := LineEdit.new()
	name_edit.placeholder_text = "新内容显示名"
	body.add_child(Kit.field_row("新名字", name_edit, 56))
	# C2：行详情——选中条目的绑定实例与内容入边（bulk 一次读盘的结果）
	var edges_lbl := Kit.hint_label("选中条目后这里显示绑定与入边。", RIGHT_W - 40)
	body.add_child(edges_lbl)
	list.item_selected.connect(func(idx: int):
		var cid := str(list.get_item_metadata(idx))
		picked[0] = cid
		var nm := ""
		for r in rows:
			if str((r as Dictionary).get("cid", "")) == cid:
				nm = str((r as Dictionary).get("name", ""))
				break
		if nm == "":
			nm = str(ContentStore.read(manifest, fn_id, cid).get("name", ""))
		name_edit.text = (nm if nm != "" else cid) + " 副本"
		rename_edit.text = nm
		edges_lbl.text = _lib_edges_text(cid, bulk))

	var on_ok := func():
		if not _form_binding_matches(i, target) or not commit() or not _form_binding_matches(i, target):
			return
		if picked[0] == "":
			app._set_status(" 先选一条内容")
			return
		pop.hide()
		_duplicate_from_lib(fn_id, picked[0], name_edit.text, i)
	body.add_child(Kit.popup_buttons(on_ok, func(): pop.hide(), "复用", "取消"))
	app._open_popup(pop)

func _content_scope_guard() -> Callable:
	var ctrl = app._map_file_ctrl
	if ctrl == null:
		return func() -> bool: return false
	var generation := int(ctrl.sess.generation)
	var source: Dictionary = manifest
	return func() -> bool:
		return app._map_file_ctrl == ctrl and not ctrl.sess.stale(generation) and is_same(app.manifest, source)

## 返回是否真的改了（调用方据此刷新列表快照）。
func _rename_library_item(fn_id: String, cid: String, new_name: String) -> bool:
	var nm := new_name.strip_edges()
	if nm == "":
		app._set_status(" 先填新显示名")
		return false
	var rd := _content_read_ex(fn_id, cid)
	var data: Dictionary = rd.data
	if data.is_empty():
		app._set_status(" 读不到内容 %s（文件缺失或损坏）" % cid)
		return false
	if str(data.get("name", "")) == nm:
		return false
	data["name"] = nm
	var wr := _content_write(fn_id, cid, data, str(rd.digest))
	if wr == "conflict":
		app._set_status(" 内容 %s 已被外部修改，改显示名未写入" % cid)
		return false
	if wr != "ok":
		app._set_status(" 改显示名失败：内容文件不可写")
		return false
	# 绑定里冗余的 name 只影响列表显示：引用字段是 content ID，改名不动它
	app._set_status(" 已改显示名：%s → %s（ID 与引用不变）" % [cid, nm])
	_refresh_status_only()
	return true

## E3：库内删除——先跑 C3 引用检查。三条拦截线：
##   ① 有地图/实例仍引用该内容（含当前画布的未保存绑定）→ 列出后停住；
##   ② 其它内容的引用字段指向它（内容间入边）→ 删除会让那些引用悬空；
##   ③ 有未扫描/读不出的文件（地图或内容）→ 范围不完整，只提示不动手。
## 全部通过才走确认框并删文件（内容文件有 .history 备份可找回）。
## 返回是否真的删了（调用方据此从列表快照里去掉该行）。
## C2：行详情文本：绑定实例与 content 入边（bulk 一次读盘的结果）。
func _lib_edges_text(cid: String, bulk: Dictionary) -> String:
	var bulk_refs: Dictionary = bulk.get("refs", {})
	var refd: Dictionary = bulk_refs.get(cid, {}) if bulk_refs.has(cid) else {"instances": {}, "contents": [], "n": 0}
	var inst: Dictionary = refd.get("instances", {})
	var parts: Array[String] = []
	for mn in inst:
		parts.append("%s × %d" % [str(mn), (inst[mn] as Array).size()])
	var out := "绑定：%s" % ("、".join(parts) if not parts.is_empty() else "无")
	var cs: Array = refd.get("contents", [])
	var clines: Array[String] = []
	for c in cs:
		clines.append("%s/%s.%s" % [str((c as Dictionary).get("kind", "")), str((c as Dictionary).get("id", "")), str((c as Dictionary).get("field", ""))])
	for ref in refd.get("views", []):
		clines.append("参考视图 %s · %s" % [ref.view, ref.path])
	if not clines.is_empty():
		out += "
入边：" + "、".join(clines)
	if int(refd.get("n", 0)) == 0:
		out += "
（未被任何实例、内容或参考视图引用）"
	return out

## C2：共享改绑：本实例改绑到已有内容 ID（沿用同一 ID），先弹确认框列受影响实例。
func _share_rebind(i: int, fn_id: String, cid: String) -> void:
	if cid == "":
		app._set_status(" 先选一条内容")
		return
	if str(((_current_fns()[i] if i >= 0 and i < _current_fns().size() else {}) as Dictionary).get("content", "")) == cid:
		return
	var rows := _current_fns()
	if i < 0 or i >= rows.size() or not rows[i] is Dictionary:
		return
	var target := {"entity": _current_spr(), "binding": rows[i], "doc": _doc_key(), "scope": _content_scope_guard()}
	var bulk := ReferenceUsage.content_edges_bulk(manifest, fn_id, [cid], app.canvas.cur_map_name, [])
	var inst: Dictionary = ((bulk.get("refs", {}) as Dictionary).get(cid, {}) as Dictionary).get("instances", {})
	var parts: Array[String] = []
	var total := 0
	for mn in inst:
		var codes: Array = inst[mn]
		total += codes.size()
		parts.append("%s × %d" % [str(mn), codes.size()])
	var shell: Dictionary = app._popup_body("共享已有内容", "这条内容正被 %d 个实例绑定（%s）。改绑后它们与本实例共用同一内容 ID，字段改动一起生效。" % [total, "、".join(parts) if not parts.is_empty() else "无"])
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	body.add_child(Kit.hint_label("目标内容：" + cid + "（沿用此 ID，不再复制）", RIGHT_W - 40))
	# 确认 → 改绑：只改 bindings 的 content 键（地图改动，走 _write_fns 进撤销栈）
	var go := func():
		if not _form_binding_matches(i, target) or not commit() or not _form_binding_matches(i, target):
			return
		if _content_read(fn_id, cid).is_empty():
			app._set_status("目标内容已变更，请重新选择")
			return
		var fns := _current_fns()
		if i < 0 or i >= fns.size():
			return
		var fns2 := fns.duplicate(true)
		(fns2[i] as Dictionary)["content"] = cid
		_write_fns(_current_spr(), fns2)
		_rebuild_right()
		app._set_status(" 已改绑到共享内容 " + cid)
	body.add_child(Kit.popup_buttons(go, func(): pop.hide(), "改绑", "取消"))
	app._open_popup(pop)

## R14：删除前的全部入边检查（活体绑定 / 暂存 / 草稿 / 内容间引用 / 范围完整性）。
## 返回 "" = 可以删；非空 = 中止原因（可直接给状态栏）。确认弹窗前后各跑一次（复验）。
func _delete_blocked_reason(fn_id: String, cid: String) -> String:
	if manifest.get("startup", {}).get("target", {}) == {"function": fn_id, "content": cid}:
		return " 删除中止：此内容是正式启动入口。请先更换或清除入口。"
	# 当前画布的**全部**活体绑定都算引用（磁盘是旧的）——不只当前选中实例。
	var live_codes: Array = []
	var fcode := FunctionDecls.fn_code(manifest, fn_id)
	if _map_ready():
		for row in host._entities():
			for f in (row.get("fns", []) as Array):
				if f is Dictionary and str((f as Dictionary).get("content", "")) == cid \
						and (fcode == "" or str((f as Dictionary).get("fn", "")) == fcode):
					live_codes.append(str(row.get("code", "")))
					break
	# R14：暂存内容的引用字段也指得到它（未落盘的入边）。
	var staged_refs: Array = []
	for row2 in staged_rows_for_current_doc():
		if row2.fn_id == fn_id and row2.cid == cid:
			continue
		if not ReferenceUsage.content_link_paths(manifest, str(row2.fn_id), row2.data, fn_id, cid).is_empty():
			staged_refs.append("%s/%s" % [row2.fn_id, row2.cid])
	var cur_map := str(app.cur_map_name) if app.map_loaded else ""
	# B2（§7.2）：删除入边全景统一走 ReferenceIndex.inbound_content——
	# 磁盘地图/内容/草稿三路入边 + 读不全源，审计与删除共用同一套解析结果。
	var live_map: Dictionary = app.canvas.extract() if _map_ready() else {}
	var ref: Dictionary = ReferenceUsage.inbound_content(manifest, fn_id, cid, cur_map, live_codes, live_map)
	if not bool(ref.get("complete", false)):
		return " 删除中止：检查范围不完整——%s。先修好这些文件再试" % \
			"；".join(PackedStringArray((ref.get("unreadable_sources", []) as Array).map(
				func(x) -> String: return str(x))))
	var edges: Dictionary = ref.get("edges", {})
	var project_slots: Array = edges.get("project_slots", [])
	if not project_slots.is_empty():
		var rule: Dictionary = project_slots[0]
		var source := "图组事件层" if rule.has("layer") else "项目规则"
		return " 删除中止：%s「%s」仍引用它。请先更换或清除该规则。" % [source, rule.name]
	var by_map: Dictionary = edges.get("instances", {})
	if not by_map.is_empty():
		var lines: Array[String] = []
		var total := 0
		for mn in by_map:
			var codes: Array = by_map[mn]
			total += codes.size()
			lines.append("%s × %d（%s）" % [str(mn), codes.size(),
				", ".join(PackedStringArray(codes.slice(0, 4)))])
		return " 删除中止：%s 仍被 %d 个实例引用——%s。请先改接或清除引用。" % [
			cid, total, "；".join(lines)]
	# ② 其它内容文件的引用型字段指向它（内容 → 内容的入边）：删了那些引用就悬空
	var inbound: Array = edges.get("contents", [])
	if not inbound.is_empty():
		var refs: Array[String] = []
		for r in inbound:
			refs.append("%s/%s.%s" % [str((r as Dictionary).get("kind", "")),
				str((r as Dictionary).get("id", "")), str((r as Dictionary).get("field", ""))])
		return " 删除中止：另有 %d 份内容的引用字段指向它（%s）。先清掉那些字段" % [
			inbound.size(), ", ".join(PackedStringArray(refs.slice(0, 5)))]
	var view_targets: Array = edges.get("views", [])
	if not view_targets.is_empty():
		var ref_view: Dictionary = view_targets[0]
		return " 删除中止：参考视图「%s」仍引用它（%s）。请先改接或清除目标。" % [
			ref_view.view, ref_view.path]
	# R14：暂存内容（未落盘）的引用字段指向它也算入边——删了那些引用就悬空。
	if not staged_refs.is_empty():
		return " 删除中止：另有 %d 条暂存内容引用它（%s）。先清掉那些字段或落盘后再试" % [
			staged_refs.size(), ", ".join(PackedStringArray(staged_refs.slice(0, 5)))]
	# R14：草稿（未落盘工作副本）的入边——快照绑定/待提交载荷引用它，恢复草稿会带回悬空引用。
	var draft_refs: Array = edges.get("drafts", [])
	if not draft_refs.is_empty():
		return " 删除中止：草稿（%s）里引用了它。先恢复或清掉那些草稿再试" % \
			", ".join(PackedStringArray(draft_refs.slice(0, 5)))
	return ""

func _delete_library_item(fn_id: String, cid: String) -> bool:
	var reason := _delete_blocked_reason(fn_id, cid)
	if reason != "":
		app._set_status(reason)
		return false
	var nm := str(_content_read(fn_id, cid).get("name", ""))
	var text := "将删除内容「%s」(%s)。\n\n编辑器未发现实例或内容引用。游戏侧按 ID 直接加载的入口请先确认仍可运行。文件会从 content/%s/ 移除（.history 有备份）。" % [
		nm if nm != "" else cid, cid, fn_id]
	if not await app._confirm_action("删除内容", text, "删除"):
		return false
	# R14：确认后复验——对话框期间引用情况可能变化；变了就中止（重试会再报告原因）
	var reason2 := _delete_blocked_reason(fn_id, cid)
	if reason2 != "":
		app._set_status(" 删除中止：确认后引用情况发生变化——%s" % reason2)
		return false
	# §7.2：删除前由存储层先轮转历史快照；拿不到快照就拒绝删（不静默丢可回滚性）
	var rm: Dictionary = ContentStore.remove_ex(manifest, fn_id, cid)
	if not bool(rm.get("ok", false)):
		app._set_status(" 删除失败：%s（%s/%s）" % [str(rm.get("error", "未知原因")), fn_id, cid])
		return false
	app._set_status(" 已删除内容：%s/%s%s" % [fn_id, cid,
		"（快照在 content/%s/.history/%s.json.1）" % [fn_id, cid]
		if bool(rm.get("backed_up", false)) else ""])
	return true

## 将库中内容复制成新文件并改绑到当前行。时机、行 ID 与挂载标记原样保留。
func _duplicate_from_lib(fn_id: String, old_id: String, new_name: String, bind_index: int) -> void:
	var src := _content_read(fn_id, old_id)
	if src.is_empty():
		app._set_status(" 读不到内容 %s（文件缺失或损坏）" % old_id)
		return
	var spr := _current_spr()
	if spr == null:
		return
	var cand := _content_id_for(spr, fn_id)
	var new_id := ContentId.unique(manifest, fn_id, cand)
	if new_id == "":
		app._set_status(" 新内容 ID 生成失败（缺分层身份码或撞码重试耗尽）")
		return
	var nm := new_name.strip_edges()
	if nm == "":
		nm = str(src.get("name", "")) if str(src.get("name", "")) != "" else fn_id
	# 以整份源内容为底（顶层未知键原样带走），只覆盖身份三键
	var data: Dictionary = src.duplicate(true)
	data["id"] = new_id
	if data.get("scope") == "project":
		data.erase("scope")
	data["function"] = FunctionDecls.fn_code(manifest, fn_id)
	data["name"] = nm
	if not (data.get("fields", null) is Dictionary):
		data["fields"] = {}
	if not (data.get("steps", null) is Array):
		data["steps"] = []
	# 复制后的内容先暂存，等正式保存或试玩再落盘。
	if not commit():
		return
	var fns := _current_fns().duplicate(true)
	if bind_index < 0 or bind_index >= fns.size() or not fns[bind_index] is Dictionary:
		return
	if str(fns[bind_index].get("fn", "")) != FunctionDecls.fn_code(manifest, fn_id):
		return
	_staged_put(fn_id, new_id, {"fn_id": fn_id, "data": data, "ent": spr.code, "doc": _doc_key()})
	fns[bind_index]["content"] = new_id
	fns[bind_index]["name"] = nm
	_selected_fn = bind_index
	_write_fns(spr, fns)
	_refresh_all()
	app._set_status(" 已复制「%s」为新内容 %s" % [nm, new_id])
