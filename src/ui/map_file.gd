extends RefCounted
## 管理地图文件与草稿；正式写入前检查外部修改。
const ReferenceIndex := preload("res://src/project/reference_index.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")
const FlowTarget := preload("res://src/content/flow_target.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const MapFlow := preload("res://src/map/map_flow.gd")
const RefFields := preload("res://src/content/ref_fields.gd")
const ClonePlan := preload("res://src/content/clone_plan.gd")
const UiKitScript := preload("res://src/ui/ui_kit.gd")
const BasisFields := preload("res://src/ui/grid_basis_fields.gd")
const UiThemeScript := preload("res://src/ui/ui_theme.gd")
const K := preload("res://src/core/constants.gd")
const MapStore := preload("res://src/map/map_store.gd")
const Recovery := preload("res://src/map/recovery.gd")
const GridSpaceScript := preload("res://src/canvas/grid_space.gd")
const MapConvert := preload("res://src/map/map_convert.gd")
const DocumentCommit := preload("res://src/project/document_commit.gd")
const EventLayers := preload("res://src/project/event_layers.gd")
const SpatialCheck := preload("res://src/project/spatial_reference_check.gd")

var app   # 宿主引用

func _init(host) -> void:
	app = host

const AUTOSAVE_INTERVAL_MS := 120000
var _last_autosave_msec := 0
## 最近一次在新建/重命名弹窗里确认的名字（顶栏常驻名字框已移除，这里记住值供预填）
var _name_memo := ""
var _generation := 0
var _revision := 0
var _opened_digest := ""
var _event_preview_base := ""
var _copy_retry := {}
var event_drawing_retry := {}

func plan_event_drawing(label: String, id: String) -> Dictionary:
	var base := label.strip_edges()
	if not EditorManifest.is_valid_map_name(base):
		base = "共享绘制层_" + id
	var name := _unique_map_name(base)
	if name == app.cur_map_name:
		name = _unique_map_name(base + "_共享")
	var code := MapStore.allocate_code(app.manifest, app.canvas.cur_map_code())
	var meta: Dictionary = app.canvas.map_data.get("meta", {}) if app.map_loaded else {}
	var data := MapStore.new_map(name, int(meta.get("w", K.DEFAULT_MAP_W)),
		int(meta.get("h", K.DEFAULT_MAP_H)), str(meta.get("gridProjection", "")), str(meta.get("gridTopology", "")))
	data.meta.code = code
	if meta.has("gridBasis"):
		data.meta.gridBasis = meta.gridBasis.duplicate()
	return {"name": name, "data": data}

func publish_event_drawing(plan: Dictionary, candidate: Dictionary) -> bool:
	var path := MapStore.path_for(app.manifest, plan.name)
	var expected := preload("res://src/map/map_format.gd").encode(plan.data).sha256_text()
	var seen := Recovery.observe(path)
	if plan.has("log_path") and seen.get("digest", "") == expected:
		return true
	if seen.state != "missing":
		app._set_status("图组绘制层的目标文件已变化：" + plan.name)
		return false
	var manifest_path := str(app.manifest.get("_dir", "")).path_join("editor/editor_manifest.json")
	var payload: Dictionary = EditorManifest.public_data(candidate)
	plan["log_path"] = Recovery.begin_pending(app.manifest, "绑定图组绘制层 " + str(plan.name), [
		{"path": path, "baseline": "", "expect_absent": true, "expect": expected},
		{"path": manifest_path, "baseline": Recovery.digest(manifest_path), "expect": JSON.stringify(payload, "\t").sha256_text()},
	])
	if plan.log_path != "" and MapStore.write(app.manifest, plan.name, plan.data):
		return true
	app._set_status("无法写入图组绘制层：" + plan.name)
	return false

func open_event_drawing(code: String) -> void:
	if await open_map_by_code(code):
		app._set_mode("map")

func choose_event_preview_base() -> void:
	var code: String = app.canvas.cur_map_code()
	var rows := ReferenceIndex.map_target_options(app.manifest).filter(func(map):
		return EventLayers.drawings_for_map(app.manifest, map.code).any(func(group): return group.map == code))
	var shell: Dictionary = app._popup_body("图组叠加参照", "在当前图组上预览一张适用地图及其他覆盖图组，编辑目标仍是当前图组。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var filter := LineEdit.new()
	filter.placeholder_text = "地图名称或码"
	body.add_child(filter)
	var list := ItemList.new()
	list.custom_minimum_size = Vector2(450, 250)
	body.add_child(list)
	var choose := func():
		if list.get_selected_items().is_empty():
			return
		_event_preview_base = list.get_item_metadata(list.get_selected_items()[0])
		app.canvas.show_event_context = true
		refresh_event_drawings()
		app._set_status("图组叠加参照：" + list.get_item_text(list.get_selected_items()[0]))
		pop.hide()
	var fill := func():
		list.clear()
		var q := filter.text.strip_edges().to_lower()
		for map in rows:
			var label := "%s · %s" % [map.name, map.code]
			if q != "" and q not in label.to_lower():
				continue
			var i := list.add_item(label)
			list.set_item_metadata(i, map.code)
			if map.code == _event_preview_base:
				list.select(i)
		if list.item_count > 0 and list.get_selected_items().is_empty():
			list.select(0)
	if rows.is_empty():
		body.add_child(app.UiKitScript.hint_label("此图组没有可预览的普通地图。请先保存图组适用范围。", 420))
	body.add_child(app.UiKitScript.popup_buttons(choose, pop.hide, "预览叠加"))
	filter.text_changed.connect(func(_q): fill.call())
	filter.text_submitted.connect(func(_q): choose.call())
	list.item_activated.connect(func(_i): choose.call())
	fill.call()
	app._open_popup(pop)
	filter.grab_focus()

func refresh_event_drawings() -> void:
	var code: String = app.canvas.cur_map_code()
	var is_shared := code in EventLayers.drawing_codes(app.manifest)
	if not is_shared:
		_event_preview_base = code
	var documents: Array[Dictionary] = []
	if app.canvas.show_event_context and is_shared:
		var stack := EventLayers.drawing_stack(app.manifest.get("eventLayers", {}))
		var group_drawings := ReferenceIndex.event_drawings(app.manifest, _event_preview_base)
		var selected := group_drawings.find_custom(func(drawing): return drawing.map == code)
		if selected >= 0:
			var current := stack.find(group_drawings[selected].layer)
			var by_layer := {}
			for drawing in group_drawings:
				by_layer[drawing.layer] = drawing
			var resolved := ReferenceIndex.resolve_map(app.manifest, _event_preview_base)
			if resolved.status == "ok":
				var data := MapStore.read(app.manifest, resolved.key)
				if not data.is_empty():
					by_layer[""] = {"map": _event_preview_base, "data": data}
			for i in stack.size():
				var layer := stack[i]
				if by_layer.has(layer) and by_layer[layer].map != code:
					documents.append(by_layer[layer].merged({"drawOrder": i - current}, true))
	elif app.canvas.show_event_context:
		documents = ReferenceIndex.event_drawings(app.manifest, code)
	app.canvas.show_drawing_context(documents)

## 进入一次会影响当前文档的操作（新建/切图）：抬会话代数并返回本次代次。
func _begin_doc_op() -> int:
	_generation += 1
	return _generation

## 本次请求是否已过期（期间又切了图/退出了项目）。过期请求不得发布图名/路径。
func _doc_stale(gen: int) -> bool:
	return gen != _generation

## 项目 maps 目录内的未占用名字（D03）：外部地图导入绝不覆盖同名项目图。
func _unique_map_name(base: String) -> String:
	if not FileAccess.file_exists(EditorManifest.map_path(app.manifest, base)):
		return base
	var i := 2
	while i < 1000:
		var cand := "%s_%d" % [base, i]
		if not FileAccess.file_exists(EditorManifest.map_path(app.manifest, cand)):
			return cand
		i += 1
	return base + "_imported"

## 整图复制（C2）：新图名 + C2 计划预览 → 内容先写、地图后写；成功后新图加入地图菜单。
func on_duplicate() -> void:
	if not app.map_loaded:
		app._set_status("无地图：先新建或打开一张地图")
		return
	var old_name: String = app.cur_map_name
	if old_name == "":
		app._set_status("当前地图没有名字，无法复制")
		return
	var shell: Dictionary = app._popup_body("复制整张地图",
		"副本的实例与附属内容全部独立（新实例码、新内容 ID），组内引用自动重映射；目标图重发地图码。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var name_edit := LineEdit.new()
	name_edit.text = str(_copy_retry.get("name", "")) if _copy_retry.get("old") == old_name \
		and is_same(_copy_retry.get("manifest"), app.manifest) else _unique_map_name(old_name + "_copy")
	name_edit.placeholder_text = "新地图名"
	body.add_child(UiKitScript.field_row("新名字", name_edit))
	var plan_lbl := UiKitScript.hint_label("", 460)
	body.add_child(plan_lbl)
	var err_label := UiKitScript.text_label("", UiThemeScript.WARN, UiThemeScript.FS_SMALL)
	err_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	err_label.custom_minimum_size = Vector2(app.POPUP_BODY_W, 0)
	body.add_child(err_label)
	var copy_btn: Button = UiKitScript.button("复制",
		func(): duplicate_current_from_dialog(old_name, name_edit, err_label, pop), "primary")
	var refresh_plan := func():
		var nn: String = name_edit.text.strip_edges()
		if not _copy_retry_plan(old_name, nn).is_empty():
			plan_lbl.text = "继续上一次未完成的复制"
			copy_btn.disabled = false
			return
		var prev := _plan_preview(old_name, nn)
		var p: Dictionary = prev.get("plan", {})
		if str(prev.get("err", "")) != "":
			plan_lbl.text = "预览：" + str(prev.get("err"))
			copy_btn.disabled = true
			return
		var inst: int = (p.get("instance_map", {}) as Dictionary).size()
		var contents: int = (p.get("pending_contents", []) as Array).size()
		var c := _counts((p.get("map_patch", {}) as Dictionary))
		var conflicts: Array = p.get("conflicts", [])
		var head := "计划：实例 %d（新码）· 内容 %d（新 ID）· 瓦片 %d · 碰撞 %d · 摆放物 %d" % [
			inst, contents, int(c.tiles), int(c.collision), int(c.objects)]
		if conflicts.is_empty():
			plan_lbl.text = head
		else:
			plan_lbl.text = head + "\n⚠ 冲突 %d 条（复制会被拒绝）：\n%s" % [
				conflicts.size(), ClonePlan.conflicts_text(conflicts)]
		copy_btn.disabled = not conflicts.is_empty()
	name_edit.text_changed.connect(func(_t: String): refresh_plan.call())
	refresh_plan.call()
	var btn_row := UiKitScript.hbox(8)
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	btn_row.add_child(UiKitScript.button("取消", func(): pop.hide(), "ghost"))
	btn_row.add_child(copy_btn)
	body.add_child(btn_row)
	app._open_popup(pop)

## 副本预览包含当前画布和尚未写盘的内容。
func _plan_preview(old_name: String, nn: String) -> Dictionary:
	if nn == "":
		return {"plan": {}, "err": "先填新图名"}
	if not EditorManifest.is_valid_map_name(nn):
		return {"plan": {}, "err": "地图名不合法：不能含 / \\ : * ? \" < > | 或以 . 开头"}
	if FileAccess.file_exists(EditorManifest.map_path(app.manifest, nn)):
		return {"plan": {}, "err": "同名地图已存在：换个名字"}
	var data: Dictionary = app.canvas.extract()
	if data.is_empty():
		return {"plan": {}, "err": "地图重建中，请稍后再试"}
	# 预览只需要一份可解析的计划：目标码用占位（真正的新码由 duplicate_map 发行）
	return {"plan": ClonePlan.whole_map_document(
		{"data": data, "manifest": app.manifest, "map": old_name}, nn, "PREV",
		_staged_by_key()), "err": ""}

## 当前文档未落盘的暂存内容 {cid: data}（整图复制的输入；没有内容编辑器时为空）。
func _staged_by_key() -> Dictionary:
	if app.project_shell == null or app.project_shell.content_editor == null:
		return {}
	return app.project_shell.content_editor.staged_data_by_key()

## 段计数（计划里的 map_patch 或整份文档都适用）
func _counts(d: Dictionary) -> Dictionary:
	var tiles := 0
	var tseg = d.get("tiles", null)
	if tseg is Dictionary:
		for lid in (tseg as Dictionary):
			var cells = (tseg as Dictionary)[lid]
			if cells is Array:
				tiles += (cells as Array).size()
	var coll = d.get("collision", null)
	var objs = d.get("objects", null)
	return {"tiles": tiles, "collision": (coll as Array).size() if coll is Array else 0,
		"objects": (objs as Array).size() if objs is Array else 0}

## B1-2 另存并转换投影：先预览（目标投影、换算后仍能对上的实例、原样保留待核对的瓦片/碰撞），
## 确认后以画布提交状态为源另存为新图——实例码/内容 ID 走 C2 整图复制，原图不动。
func on_convert_projection() -> void:
	if not app.map_loaded:
		app._set_status("无地图：先新建或打开一张地图")
		return
	var old_name: String = app.cur_map_name
	if old_name == "":
		app._set_status("当前地图没有名字，无法另存")
		return
	var source: Dictionary = app.canvas.copy_content_source()
	if source.is_empty():
		app._set_status("字段未能提交：投影转换已中止")
		return
	var data: Dictionary = app.canvas.extract()
	if data.is_empty():
		app._set_status("地图重建中，请稍后再试")
		return
	var cur_proj := MapConvert.current_projection(data, app.manifest)
	var guard := document_guard()
	var shell: Dictionary = app._popup_body("另存并转换格空间",
		"另存为副本并换算实例与出生点：原图不动。瓦片与碰撞没有唯一对应，保留原格号，转换后需在副本里核对。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var name_edit := LineEdit.new()
	name_edit.placeholder_text = "新地图名"
	body.add_child(UiKitScript.field_row("新名字", name_edit))
	var proj_sel := OptionButton.new()
	proj_sel.name = "TargetGridProjection"
	for p in ["orthogonal", "isometric", "hexagonal"]:
		proj_sel.add_item(_proj_label(p))
		proj_sel.set_item_metadata(proj_sel.item_count - 1, p)
		if p == cur_proj:
			proj_sel.select(proj_sel.item_count - 1)
	body.add_child(UiKitScript.field_row("目标投影", proj_sel, UiKitScript.LABEL_W_LONG))
	var existing_basis := GridSpaceScript.parse_basis(data.meta)
	var basis_editor := BasisFields.add_to(body, "TargetGrid", GridSpaceScript.tile_size_of(app.manifest),
		data.meta.get("gridBasis", []) if existing_basis.ok else [])
	var note := UiKitScript.hint_label("", 460)
	body.add_child(note)
	var err_label := UiKitScript.text_label("", UiThemeScript.WARN, UiThemeScript.FS_SMALL)
	err_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	err_label.custom_minimum_size = Vector2(app.POPUP_BODY_W, 0)
	body.add_child(err_label)
	# lambda 按值捕获局部变量（重新赋值外层看不到）：计划放进容器里用内容变更回传
	var holder := {"plan": {"ok": false, "error": "先填新图名"}, "copy": {}}
	var publish := UiKitScript.button("预览转换", Callable(), "primary")
	var reset_preview := func():
		holder.copy = {}
		publish.text = "预览转换"
		err_label.text = ""
		note.text = "当前格空间：%s" % _grid_description(cur_proj,
			data.meta.get("gridBasis", []) if existing_basis.ok else [])
	var build_preview := func():
		var nn: String = name_edit.text.strip_edges()
		if nn == "":
			holder.plan = {"ok": false, "error": "先填新图名"}
			return
		if not EditorManifest.is_valid_map_name(nn):
			holder.plan = {"ok": false, "error": "名称非法"}
			err_label.text = "地图名不合法：不能含 / \\ : * ? \" < > | 或以 . 开头"
			return
		if FileAccess.file_exists(EditorManifest.map_path(app.manifest, nn)):
			holder.plan = {"ok": false, "error": "同名地图已存在"}
			err_label.text = "同名地图已存在：换个名字"
			return
		var basis := BasisFields.read(basis_editor)
		var p := MapConvert.plan(data, app.manifest, str(proj_sel.get_item_metadata(proj_sel.selected)), basis.value) \
			if basis.ok else {"ok": false, "error": basis.error}
		holder.plan = p
		err_label.text = str(p.get("error", ""))
		if not bool(p.get("ok", false)):
			return
		var lines: Array[String] = ["格空间：%s → %s（另存为新图）" % [
			_grid_description(cur_proj, p.source_grid.get("gridBasis", [])),
			_grid_description(p.projection, basis.value)]]
		var doc: Dictionary = p.get("document", {})
		var n_obj: int = (doc.get("objects", []) as Array).size() if doc.get("objects", null) is Array else 0
		lines.append("实例 %d 个：按像素锚点换算到新格系（坐标保留至 0.001 格）" % n_obj)
		for m in (p.get("manual", []) as Array):
			lines.append("⚠ " + str((m as Dictionary).get("message", "")))
		for w in (p.get("warnings", []) as Array):
			lines.append("· " + str(w))
		note.text = "\n".join(lines)
	name_edit.text_changed.connect(func(_t: String): reset_preview.call())
	proj_sel.item_selected.connect(func(_i: int): reset_preview.call())
	basis_editor.enabled.toggled.connect(func(_enabled: bool): reset_preview.call())
	for field in basis_editor.axes:
		field.text_changed.connect(func(_t: String): reset_preview.call())
	reset_preview.call()
	var btn_row := UiKitScript.hbox(8)
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	btn_row.add_child(UiKitScript.button("取消", func(): pop.hide(), "ghost"))
	publish.pressed.connect(func():
		if holder.copy.is_empty():
			build_preview.call()
		convert_current_to_dialog(old_name, name_edit, err_label, publish, pop, holder, source.staged, guard))
	btn_row.add_child(publish)
	body.add_child(btn_row)
	app._open_popup(pop)

## 两种另存共用冻结目标与依赖发布；从不保存源地图。
func convert_current_to_dialog(old_name: String, name_edit: LineEdit, err_label: Label,
		publish: Button, pop: PopupPanel, holder: Dictionary, staged: Dictionary, guard: Callable) -> void:
	if not guard.call():
		err_label.text = "源文档已改变，请重新打开转换预览"
		return
	var plan: Dictionary = holder.get("plan", {})
	if not bool(plan.get("ok", false)):
		err_label.text = str(plan.get("error", "转换计划未就绪"))
		return
	var nn := name_edit.text.strip_edges()
	if holder.copy.is_empty():
		var prep := MapStore.prepare_duplicate(app.manifest, old_name, nn, plan.document, staged)
		if not prep.has("plan"):
			err_label.text = str(prep.get("error", "")) + "\n" + ClonePlan.conflicts_text(prep.get("conflicts", []))
			return
		var edge_problem := SpatialCheck.converted_edge_problem(app.manifest, prep.plan.data, prep.plan.contents)
		if edge_problem != "":
			err_label.text = "转换未发布；请重选或断开格边引用：" + edge_problem
			return
		holder.copy = prep.plan
		publish.text = "另存并转换"
		# 同一弹窗展示冻结计划，不写源图或内容。
		pop.size = pop.get_contents_minimum_size().ceil().min(Vector2i(app.get_viewport_rect().size) - Vector2i(40, 40))
		return
	if not await _publish_map_copy(holder.copy, guard, err_label):
		return
	if is_instance_valid(pop):
		pop.hide()
	app._set_status("已另存并转换格空间：%s → %s" % [old_name, nn])

func duplicate_current_from_dialog(old_name: String, name_edit: LineEdit, err_label: Label, pop: PopupPanel) -> void:
	if old_name != app.cur_map_name:
		err_label.text = "源文档已改变，请重新打开复制预览"
		return
	var source: Dictionary = app.canvas.copy_content_source()
	if source.is_empty():
		err_label.text = "有字段未能提交，请修正后再复制"
		return
	var data: Dictionary = app.canvas.extract()
	if data.is_empty():
		err_label.text = "地图重建中，请稍后再试"
		return
	var guard := document_guard()
	var nn := name_edit.text.strip_edges()
	if not await _write_map_copy(old_name, nn, data, source.staged, guard, err_label):
		return
	pop.hide()
	app._set_status("已创建地图副本：%s → %s" % [old_name, nn])

func _write_map_copy(old_name: String, new_name: String, data: Dictionary, staged: Dictionary,
		guard: Callable, error_label: Label) -> bool:
	if not guard.call() or app.canvas.doc_busy:
		error_label.text = "文档已变化或正在提交，请重试"
		return false
	var retry := _copy_retry_plan(old_name, new_name)
	var prep := MapStore.prepare_duplicate(app.manifest, old_name, new_name, data, staged) if retry.is_empty() else {"plan": retry}
	if not prep.has("plan"):
		error_label.text = str(prep.get("error", "")) + "\n" + ClonePlan.conflicts_text(prep.get("conflicts", []))
		return false
	var ok := await _publish_map_copy(prep.plan, guard, error_label)
	if ok:
		if not retry.is_empty():
			_copy_retry.clear()
	elif prep.plan.has("log_path"):
		_copy_retry = {"old": old_name, "name": new_name, "manifest": app.manifest, "plan": prep.plan}
	return ok

func _copy_retry_plan(old_name: String, new_name: String) -> Dictionary:
	if _copy_retry.get("old") == old_name and _copy_retry.get("name") == new_name \
			and is_same(_copy_retry.get("manifest"), app.manifest):
		return _copy_retry.plan
	return {}

func _publish_map_copy(plan: Dictionary, guard: Callable, error_label: Label) -> bool:
	if not guard.call() or app.canvas.doc_busy:
		error_label.text = "文档已变化或正在提交，请重试"
		return false
	var checked := DocumentCommit.preflight(plan)
	if checked.has("error"):
		error_label.text = checked.error
		return false
	app.canvas.doc_busy = true
	var ready := true
	if bool(app.manifest.get("_codes_issued", false)):
		ready = await app._save_manifest_file_async(guard)
	var err := "清单未发布或源文档已改变"
	if ready and guard.call():
		err = MapStore.apply_duplicate(plan)
	_release_busy()
	if err != "" and is_instance_valid(error_label):
		error_label.text = "另存失败：" + err
	return err == ""

func confirm_discard(action: String) -> bool:
	if app.canvas != null and app.canvas.doc_busy:
		app._set_status(" 文档操作正在进行，请稍后再试")
		return false
	if not app.map_loaded or not app.canvas.modified_flag:
		return true
	# 确认框开着时冻结撤销/重做（A2）：期间 Ctrl+Z 把画布换掉，用户确认的就不是同一份内容
	if app.canvas != null:
		app.canvas.doc_busy = true
	var guard := document_guard()
	var answer := await _ask_discard(action)
	_release_busy()
	return answer and guard.call()

func _discard_previous_staging(doc: String) -> void:
	if doc != "" and app.project_shell != null and app.project_shell.content_editor != null:
		app.project_shell.content_editor.drop_staged_for_doc(doc)

func _ask_discard(action: String) -> bool:
	var message := "地图 %s 有未保存修改。\n继续%s将丢失这些修改。" % [app.cur_map_name, action]
	# 同时列出将丢弃的暂存内容和待写清单。
	var extra: Array = []
	for p in _pending_targets():
		if p == "content":
			extra.append("内容页暂存的新内容/新绑定")
		elif p == "manifest":
			extra.append("清单里新补发的身份码")
	if not extra.is_empty():
		message += "\n\n此外还有未落盘：%s。" % "、".join(PackedStringArray(extra))
	# 自动保存草稿存得进、捞不出——放弃修改时至少把草稿路径说出来，
	# 否则用户以为这份保险不存在。草稿从「地图 ▾ → 恢复草稿…」也能载入（见 top_bar_nav）。
	var code := str((app.canvas.map_data.get("meta", {}) as Dictionary).get("code", "")) \
		if app.canvas != null and app.canvas.map_data.get("meta", null) is Dictionary else ""
	var draft_path := Recovery.draft_path(app.manifest, code, app.cur_map_name)
	if draft_path != "" and FileAccess.file_exists(draft_path):
		message += "\n\n最近一次自动保存的草稿在：\n%s\n放弃后仍可从「地图 ▾ → 恢复草稿…」载入它找回内容。" % draft_path
	return await confirm_action("未保存的修改", message, "放弃修改并继续")

## 通用确认框：删除/不可撤销动作统一走这里（文本与确定钮文案可定制）
func confirm_action(title: String, text: String, ok_text := "确定") -> bool:
	var dlg := ConfirmationDialog.new()
	dlg.title = title
	dlg.dialog_text = text
	dlg.ok_button_text = ok_text
	dlg.cancel_button_text = "取消"
	dlg.min_size = Vector2i(460, 0)
	app.add_child(dlg)
	var answer := [false]
	dlg.confirmed.connect(func(): answer[0] = true)
	dlg.popup_centered()
	while dlg.visible:
		await app.get_tree().process_frame
	dlg.queue_free()
	return answer[0]

## 新建地图时确定投影、拓扑和可选的像素基向量。
func on_new() -> void:
	var shell: Dictionary = app._popup_body("新建地图", "名字同时作文件名与显示名。格空间设置随地图保存。", true)
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var name_edit := LineEdit.new()
	name_edit.name = "NewMapName"
	# 记住上次填的名字，但已存在的名字不预填（否则一按确定必然撞重名）
	if _name_memo != "" and not FileAccess.file_exists(EditorManifest.map_path(app.manifest, _name_memo)):
		name_edit.text = _name_memo
	name_edit.placeholder_text = "地图名"
	body.add_child(UiKitScript.field_row("地图名", name_edit, UiKitScript.LABEL_W_LONG))
	# 高级设置：格投影。缺省 = 沿用项目解析（清单里瓦片资产的声明）。
	var proj_sel := OptionButton.new()
	proj_sel.name = "NewMapProjection"
	var proj_keys: Array = ["", "orthogonal", "isometric", "hexagonal"]
	var proj_labels: Array = ["沿用项目（%s）" % _proj_label(GridSpaceScript.project_projection(app.manifest)),
		"正交", "等距", "六边形"]
	for i in proj_keys.size():
		proj_sel.add_item(str(proj_labels[i]))
		proj_sel.set_item_metadata(i, str(proj_keys[i]))
	proj_sel.select(0)
	body.add_child(UiKitScript.field_row("格投影", proj_sel, UiKitScript.LABEL_W_LONG))
	var err_label := UiKitScript.text_label("", UiThemeScript.WARN, UiThemeScript.FS_SMALL)
	err_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	err_label.custom_minimum_size = Vector2(app.POPUP_BODY_W, 0)
	var topo_sel := OptionButton.new()
	topo_sel.name = "NewMapTopology"
	topo_sel.add_item("平行四边形（缺省）")
	topo_sel.set_item_metadata(0, "")
	topo_sel.add_item("三角形（每列两半格）")
	topo_sel.set_item_metadata(1, "triangles")
	var width := SpinBox.new()
	var height := SpinBox.new()
	var dimensions := UiKitScript.hbox(6)
	for value in [width, height]:
		value.min_value = 1
		value.max_value = 100000
		value.allow_greater = true
		value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		dimensions.add_child(value)
	width.value = K.DEFAULT_MAP_W
	height.value = K.DEFAULT_MAP_H
	body.add_child(UiKitScript.field_row("宽 × 高（格）", dimensions, UiKitScript.LABEL_W_LONG))
	var advanced := UiKitScript.vbox(6)
	body.add_child(UiKitScript.button("高级格空间设置…", func(): advanced.visible = not advanced.visible, "ghost"))
	body.add_child(advanced)
	advanced.hide()
	advanced.add_child(UiKitScript.field_row("格拓扑", topo_sel, UiKitScript.LABEL_W_LONG))
	var basis_editor := BasisFields.add_to(advanced, "NewMap", GridSpaceScript.tile_size_of(app.manifest))
	var refresh_topology := func():
		var pj := str(proj_sel.get_item_metadata(proj_sel.selected))
		if pj == "":
			pj = GridSpaceScript.project_projection(app.manifest)
		topo_sel.disabled = pj == "hexagonal"
		if topo_sel.disabled:
			topo_sel.select(0)
		topo_sel.tooltip_text = "六边形投影不能搭配三角拓扑" if topo_sel.disabled else ""
		err_label.text = ""
	proj_sel.item_selected.connect(func(_i: int): refresh_topology.call())
	refresh_topology.call()
	body.add_child(err_label)
	var submit := func():
		width.apply()
		height.apply()
		var basis := BasisFields.read(basis_editor)
		if not basis.ok:
			err_label.text = basis.error
			basis.field.grab_focus()
			return
		create_map_from_dialog(name_edit, err_label, pop,
			str(proj_sel.get_item_metadata(proj_sel.selected)),
			str(topo_sel.get_item_metadata(topo_sel.selected)), basis.value, Vector2i(int(width.value), int(height.value)))
	name_edit.text_submitted.connect(func(_t: String): submit.call())
	body.add_child(UiKitScript.popup_buttons(submit, pop.hide, "创建地图"))
	app._open_popup(pop)
	name_edit.grab_focus()

func _grid_description(projection: String, basis: Array) -> String:
	return _proj_label(projection) if basis.is_empty() else "自定义 U=%s，V=%s（%s）" % [
		basis[0], basis[1], _proj_label(projection)]

func _proj_label(p: String) -> String:
	match p:
		"isometric":
			return "等距"
		"hexagonal":
			return "六边形"
	return "正交"

## 新建弹窗确定：校验 → 未保存确认 → 载入空图
func create_map_from_dialog(name_edit: LineEdit, err_label: Label, pop: PopupPanel,
		proj := "", topo := "", basis: Array = [], dimensions := Vector2i(K.DEFAULT_MAP_W, K.DEFAULT_MAP_H)) -> void:
	var n: String = name_edit.text.strip_edges()
	if n == "":
		err_label.text = "先填地图名"
		return
	if not EditorManifest.is_valid_map_name(n):
		err_label.text = "地图名不合法：不能含 / \\ : * ? \" < > | 或以 . 开头"
		return
	if FileAccess.file_exists(EditorManifest.map_path(app.manifest, n)):
		err_label.text = "同名地图已存在：换个名字，或直接打开它"
		return
	var data := MapStore.new_map(n, dimensions.x, dimensions.y, proj, topo)
	data.spawn = [mini(2, dimensions.x - 1), mini(2, dimensions.y - 1)]
	if not basis.is_empty():
		data.meta["gridBasis"] = basis
	var issues: Array = GridSpaceScript.resolve(data.meta, app.manifest).issues
	if not issues.is_empty():
		err_label.text = str(issues[0].message)
		return
	err_label.text = ""
	_name_memo = n
	# 先收新建弹窗再开确认框：确认框是模态窗口，会让新建弹窗失焦自动 hide，
	# 而 hide 连带 queue_free——之后确认框还要 await，留着也会被释放。
	pop.hide()
	if not await confirm_discard("新建"):
		return
	data.meta.code = MapStore.allocate_code(app.manifest, app.canvas.cur_map_code())
	if await _open_unsaved_map(n, data, "新建空地图"):
		app._set_mode("map")

func open_generated_map(n: String, data: Dictionary, guard: Callable) -> bool:
	if not guard.call() or not await confirm_discard("打开生成地图") or not guard.call():
		return false
	var target := MapStore.path_for(app.manifest, n)
	if target == "" or FileAccess.file_exists(target) or map_code_taken(str(data.meta.code)):
		app._set_status("生成地图未打开：目标图名或地图码已被占用，请重新生成。")
		return false
	return await _open_unsaved_map(n, data, "打开生成地图")

func map_code_taken(code: String) -> bool:
	return code == "" or MapStore.code_index(app.manifest).by_code.has(code) \
		or (app.map_loaded and app.canvas.cur_map_code() == code)

func _open_unsaved_map(n: String, data: Dictionary, action: String) -> bool:
	var previous_doc := document_key()
	var gen := _begin_doc_op()
	app.canvas.set_thumbs(app._entity_thumbs())
	await app.canvas.load_data(data, n)
	if _doc_stale(gen):
		return false
	_discard_previous_staging(previous_doc)
	app.cur_map_name = n
	app.cur_map_path = EditorManifest.map_path(app.manifest, n)
	# 新图：身份换到这张，基线清空（磁盘上还没有这份文件）
	_opened_digest = ""
	_revision = 0
	app._playtest_ctrl.sync_map_preferences()
	app._set_map_loaded(true)
	app.canvas._undo_history_ctrl.clear_history()
	app.canvas.modified_flag = true
	app._editor_state_ctrl.sync_ui()
	app._set_status(" %s %s（先保存再试玩）" % [action, n])
	return true

## 重命名当前地图：弹窗输入新名（顶栏名字框已移除，就地改名入口改到这里）
func on_rename() -> void:
	if not app.map_loaded:
		app._set_status("无地图：先新建或打开一张地图")
		return
	var old_name: String = app.cur_map_name
	if old_name == "":
		app._set_status("当前地图没有名字，无法重命名")
		return
	var shell: Dictionary = app._popup_body("重命名地图", "只改文件名与显示名，跨图引用不迁移；还没存过盘的新图会按新名直接保存。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var name_edit := LineEdit.new()
	# 当前名就是上次「新建」时填的名字（打开/改名也会同步 _name_memo）
	name_edit.text = old_name
	name_edit.placeholder_text = "地图名"
	body.add_child(UiKitScript.field_row("新名字", name_edit))
	var err_label := UiKitScript.text_label("", UiThemeScript.WARN, UiThemeScript.FS_SMALL)
	err_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	err_label.custom_minimum_size = Vector2(app.POPUP_BODY_W, 0)
	body.add_child(err_label)
	var submit := func(): rename_current_from_dialog(old_name, name_edit, err_label, pop)
	name_edit.text_submitted.connect(func(_text: String): submit.call())
	body.add_child(UiKitScript.popup_buttons(submit, pop.hide, "重命名"))
	app._open_popup(pop)
	name_edit.grab_focus()
	name_edit.select_all()

## 重命名弹窗确定：校验 → MapStore.rename_map → 同步当前名/路径
func rename_current_from_dialog(old_name: String, name_edit: LineEdit, err_label: Label, pop: PopupPanel) -> void:
	var nn: String = name_edit.text.strip_edges()
	if nn == "" or nn == old_name:
		pop.hide()
		return
	if not EditorManifest.is_valid_map_name(nn):
		err_label.text = "地图名不合法：不能含 / \\ : * ? \" < > | 或以 . 开头"
		return
	# 真正的文件级改名（含「未落盘 → 按新名写盘」）统一走 rename_map_now
	var was_on_disk := FileAccess.file_exists(EditorManifest.map_path(app.manifest, old_name))
	var err := await rename_map_now(old_name, nn, true)
	if err != "":
		err_label.text = "改名失败：" + err
		return
	pop.hide()
	if was_on_disk:
		app._set_status("已改名：%s → %s（引用未迁移）" % [old_name, nn])
	else:
		app._set_status("已改名并保存：%s → %s（原图未落盘，已按新名写入磁盘）" % [old_name, nn])

## 真正的地图重命名：改文件（或按新名落盘）+ 同步当前编辑身份。
## 返回错误信息，"" = 成功。allow_write_unsaved 允许「原图还没落盘」时把画布内容按新名写盘
## （只有当前正在编辑的那张图才有内容可写；清单里的幽灵条目不能凭空造文件）。
func rename_map_now(old_name: String, new_name: String, allow_write_unsaved := false) -> String:
	var nn := new_name.strip_edges()
	if nn == "" or nn == old_name:
		return ""
	if not EditorManifest.is_valid_map_name(nn):
		return "名称非法"
	var old_path := EditorManifest.map_path(app.manifest, old_name)
	var new_path := EditorManifest.map_path(app.manifest, nn)
	if new_path == "":
		return "名称非法"
	var is_current: bool = app.map_loaded and old_name == app.cur_map_name
	var on_disk := old_path != "" and FileAccess.file_exists(old_path)
	if is_current and app.canvas.doc_busy:
		return "另一次文档操作正在进行"
	var data_for_first_save := {}
	if on_disk:
		if is_current and _opened_digest == "":
			return "原图缺少保存基线，请重新打开后再改名"
		var err: String = MapStore.rename_map(app.manifest, old_name, nn, _opened_digest if is_current else "")
		if err != "":
			return err
	elif allow_write_unsaved and is_current:
		if _opened_digest != "":
			return "原图已被删除，请重新检查地图文件"
		# 原图未落盘（新建后还没保存）：改名必须真正落地，否则只改内存名 =
		# 面板显示新名、磁盘上始终没文件，用户看到的「重命名」是假的。
		var ce = null
		if app.project_shell != null:
			ce = app.project_shell.content_editor
		if ce != null:
			# 字段写失败就不该继续写盘：否则新地图文件带着没落盘的字段值
			if not ce.commit_fields():
				return "表单字段写入失败：改名已中止"
		var data: Dictionary = app.canvas.extract()
		if data.is_empty():   # 重建窗口哨兵：此刻写盘会把空图落成新文件
			return " 地图重建中，请稍后再试"
		data.meta.name = nn
		var rows: Array = ce.bound_staged_rows(data) if ce != null else []
		var link_problem := SpatialCheck.staged_problem(app.manifest, data, rows)
		if link_problem != "":
			write_draft_now()
			return "先重接或断开引用：" + link_problem
		var prep := DocumentCommit.prepare(app.manifest, nn, data, rows)
		if prep.has("error"):
			return prep.error
		DocumentCommit.recover_log(prep.plan)
		var checked := DocumentCommit.preflight(prep.plan)
		if checked.has("error"):
			return checked.error
		if bool(app.manifest.get("_codes_issued", false)):
			var guard := document_guard()
			app.canvas.doc_busy = true
			var saved: bool = await app._save_manifest_file_async(guard)
			_release_busy()
			if not saved or not guard.call():
				return "清单未保存或文档已变化"
		var result := DocumentCommit.apply(prep.plan)
		if result.error != "":
			return result.error
		data_for_first_save = data
		if ce != null:
			ce.consume_written_staged(result.get("written_contents", []))
	else:
		return "原图不存在（先保存该地图）"
	if is_current:
		_name_memo = nn
		app.cur_map_name = nn
		app.cur_map_path = new_path
		if app.canvas.map_data.has("meta"):
			app.canvas.map_data["meta"]["name"] = nn
		_opened_digest = Recovery.digest(new_path)
		if not on_disk:
			_finish_map_save(nn, new_path, data_for_first_save)
		else:
			app._playtest_ctrl.sync_map_preferences()
	return ""

## 先选文件再确认丢弃：取消文件选择不能丢失当前编辑。
func on_open() -> void:
	var fd := FileDialog.new()
	fd.title = "打开地图文件"
	fd.ok_button_text = "打开"
	fd.cancel_button_text = "取消"
	fd.display_mode = FileDialog.DISPLAY_LIST
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.current_dir = str(app.manifest.get("_maps_dir", ""))
	fd.add_filter("*.json")
	# 生命周期：选完/取消都释放对话框
	fd.file_selected.connect(func(p: String):
		fd.queue_free()
		_open_chosen(p))
	fd.canceled.connect(func():
		fd.queue_free()
		app._set_status(" 已取消打开（当前地图与暂存内容保持不变）"))
	app.add_child(fd)
	fd.popup_centered(Vector2i(700, 500))

## 选定文件之后的打开流程：先读+校验（失败不动旧文档），再确认丢弃，最后载入。
func _open_chosen(p: String) -> void:
	var probe: Dictionary = MapStore.read_path(p, app.manifest)
	if not probe.get("ok", false):
		app._set_status(" 打开失败: " + _format_issues(probe.get("errors", [])))
		return
	if not await confirm_discard("打开另一张地图"):
		return
	await load_map_file(p)
	if app._in_project_view() and app.project_shell._view == "content":
		app.project_shell.content_editor.refresh_list()

func load_map_file(p: String, expected_digest := "") -> void:
	# 只允许最近一次载入在画布重建完毕后更新当前地图。
	var previous_doc := document_key()
	var gen := _begin_doc_op()
	var result: Dictionary = MapStore.read_path(p, app.manifest)
	if not result.ok:
		app._set_status(" 打开失败: " + _format_issues(result.errors))
		return
	if expected_digest != "" and str(result.get("digest", "")) != expected_digest:
		app._set_status(" 地图写入后已被改动，请重新打开")
		return
	var data: Dictionary = result.data
	if not result.warnings.is_empty():
		app._set_status(" 地图已打开但有兼容警告: " + _format_issues(result.warnings))
	var base := p.get_file().get_basename()
	# 项目外的地图必须导入，避免保存时覆盖项目同名文件。
	var canon := str(p).simplify_path()
	var maps_root := str(app.manifest.get("_maps_dir", "")).simplify_path()
	var outside := maps_root != "" and not MapStore.same_directory(canon.get_base_dir(), maps_root)
	if data.has("_autosave_of"):
		if not outside:
			app._set_status("旧草稿请移出 maps 目录，再作为新地图导入。")
			return
		data.erase("_autosave_of")
	if outside:
		if not await app._confirm_action("导入外部地图",
			"这张图不在当前项目的 maps 目录内：\n%s\n\n导入会把它复制为项目内的 %s.json。" % [canon, base],
			"导入并打开"):
			return
		# D03：导入目标不能是已存在的项目图——同名不同内容时覆盖等于删掉别人的图
		var target := _unique_map_name(base)
		if target != base:
			app._set_status(" 项目内已有同名地图，导入为 " + target + ".json")
		base = target
		if _doc_stale(gen):
			return
		# 导入时重新发码，并重映射本图引用。
		var source_code: String = data.get("meta", {}).get("code", "")
		if data.get("meta", null) is Dictionary:
			(data["meta"] as Dictionary).erase("code")
		MapStore.ensure_code(app.manifest, data)
		ClonePlan.readdress_import(app.manifest, data, source_code, data.meta.code)
		var links := _import_dependencies(data)
		if not links.is_empty():
			if not await app._confirm_action("核对导入地图的外部引用",
				"这些依赖不会随图导入。请核对现有目标，或导入后重接：\n" + "\n".join(links), "继续导入"):
				return
			if _doc_stale(gen):
				return
		if FileAccess.file_exists(MapStore.path_for(app.manifest, base)) or not MapStore.write(app.manifest, base, data):
			app._set_status("导入失败：无法写入 " + EditorManifest.map_path(app.manifest, base))
			return
		p = EditorManifest.map_path(app.manifest, base)
		canon = str(p).simplify_path()
		if target == base:
			app._set_status("已导入外部地图 → " + p)
	if _doc_stale(gen):
		return   # 读取/确认期间又发起了更新的切图请求：本次不再改画布
	var baseline := str(result.get("digest", ""))
	if outside:
		baseline = Recovery.digest(p)
	app.canvas.set_thumbs(app._entity_thumbs())
	await app.canvas.load_data(data, base)
	if _doc_stale(gen):
		return
	_discard_previous_staging(previous_doc)
	app.cur_map_name = base
	app._playtest_ctrl.sync_map_preferences()
	app.cur_map_path = p
	_name_memo = base
	app._set_map_loaded(true)
	app.canvas._undo_history_ctrl.clear_history()
	# 画布重建成功后，使用读入文件的摘要作为保存基线。
	_opened_digest = baseline
	_revision = 0
	var tcount := 0
	for lid in (data.get("tiles", {}) as Dictionary):
		tcount += ((data.get("tiles", {}) as Dictionary)[lid] as Array).size()
	var objs: Array = data.get("objects", [])
	app._set_status(" 已打开 %s（%d 瓦片 / %d 摆放物）" % [base, tcount, objs.size()])

func _format_issues(issues: Array) -> String:
	var lines: Array[String] = []
	for issue in issues:
		lines.append("%s: %s" % [str(issue.get("path", "map")), str(issue.get("message", "invalid data"))])
	return "; ".join(lines)

## 单图导入不会带上这些地图和内容依赖。
func _import_dependencies(data: Dictionary) -> PackedStringArray:
	var notes := PackedStringArray()
	var code: String = data.meta.code
	var refs := MapFlow.references(app.manifest, data)
	var links: Array = Array(refs)
	for obj in data.get("objects", []):
		var decl := AssetDecl.by_id(app.manifest, obj.get("asset", ""))
		links.append_array(ReferenceIndex.property_refs(app.manifest, decl.get("fields", []),
			obj.get("props", {}), {}, str(obj.get("code", ""))))
		for binding in obj.get("functions", []):
			var cid: String = binding.get("content", "")
			if cid != "":
				var fn := FunctionDecls.fn_id_of(app.manifest, binding.get("fn", ""))
				notes.append("%s · 内容 %s/%s" % [obj.get("code", ""), fn if fn != "" else binding.fn, cid])
	for ref in links:
		var value = ref.value
		var key: String = ref.get("paired", "")
		if ref.kind == "map":
			key = str(value)
		elif value is Dictionary:
			key = RefFields.object_map_key(value, key)
		if not RefFields.map_key_local(key, code):
			notes.append("%s · 地图 %s" % [ref.path, key])
		elif ref.kind == "flow_target" and FlowTarget.kind(value) == "content":
			notes.append("%s · 内容 %s/%s" % [ref.path, value.function, value.content])
		elif ref.kind == "content":
			notes.append("%s · 内容 %s" % [ref.path, value])
	return notes

## 先结束编辑手势，再按「清单 → 内容 → 地图」顺序保存。
func commit_document(reason := "") -> Dictionary:
	if app.canvas.doc_busy:
		return {"status": "failed", "error": "另一次文档操作正在进行"}
	app.canvas.cancel_preview_gesture()
	app.canvas.end_gesture()
	app.canvas.doc_busy = true
	var error := await _save_document()
	_release_busy()
	if error != "":
		return {"status": "failed", "error": error}
	if reason != "":
		app._set_status(" 已保存（%s）" % reason)
	return {"status": "ok", "error": ""}


func _save_document() -> String:
	var ce = app.project_shell.content_editor if app.project_shell != null else null
	if ce != null and not ce.commit_fields():
		app._set_status(" 保存中止：表单字段写入失败")
		return "表单字段写入失败"

	var name: String = app.cur_map_name if app.map_loaded else ""
	var path := EditorManifest.map_path(app.manifest, name) if app.map_loaded else ""
	var write_map: bool = app.map_loaded and (app.canvas.modified_flag or not FileAccess.file_exists(path))
	var write_content: bool = ce != null and ce.has_staged_for_current_doc()
	var data: Dictionary = {}
	if write_map or (app.map_loaded and write_content):
		data = app.canvas.extract()
		if data.is_empty():
			app._set_status(" 保存中止：地图正在重建")
			return "地图正在重建"
	var rows: Array = ce.bound_staged_rows(data) if write_content else []
	var saved_map := MapStore.read(app.manifest, name) if write_map or not rows.is_empty() else {}
	if write_map:
		if path == "":
			app._set_status(" 保存中止：地图名不合法")
			return "地图名不合法"
		data.meta.name = name
		MapStore.ensure_code(app.manifest, data)
		var problem := MapStore.identity_error(app.manifest, name, data)
		if problem != "":
			app._set_status(" 保存中止：" + problem)
			return problem
		problem = SpatialCheck.blocked_removals(app.manifest, saved_map, data, rows)
		if problem != "":
			write_draft_now()
			app._set_status(" 先重接或断开引用：" + problem)
			return problem
	if not rows.is_empty():
		var problem := SpatialCheck.staged_problem(app.manifest, data if write_map else saved_map, rows)
		if problem != "":
			write_draft_now()
			app._set_status("先重接或断开引用：" + problem)
			return problem

	var guard := document_guard()
	var observed := {}
	if write_map:
		var problem := MapStore.write_error(app.manifest, data)
		if problem != "":
			app._set_status(" 保存中止：" + problem)
			return problem
		observed = await _confirm_map_write(path, guard)
		if observed.is_empty():
			return "地图保存失败或取消"
	if not write_map and rows.is_empty():
		if bool(app.manifest.get("_codes_issued", false)) and not await app._save_manifest_file_async(guard):
			return "清单保存失败或取消"
		return ""
	var prep := DocumentCommit.prepare(app.manifest, name if write_map else "", data, rows,
		"", "", observed.get("digest", ""))
	if prep.has("error"):
		app._set_status("保存中止：" + prep.error)
		return prep.error
	var plan: Dictionary = prep.plan
	DocumentCommit.recover_log(plan)
	var checked := DocumentCommit.preflight(plan)
	if checked.has("error"):
		app._set_status(checked.error)
		return checked.error
	if bool(app.manifest.get("_codes_issued", false)) and not await app._save_manifest_file_async(guard):
		return "清单保存失败或取消"
	var result := DocumentCommit.apply(plan)
	if result.error != "":
		app._set_status("保存失败：" + result.error)
		return result.error
	if ce != null:
		ce.consume_written_staged(result.get("written_contents", []))
	if write_map:
		_finish_map_save(name, path, data)
	return ""


## 解除文档忙状态（保存失败/取消路径也必须走到，否则撤销永久失效）
func _release_busy() -> void:
	if app.canvas != null:
		app.canvas.doc_busy = false

## 暂存和步骤共用项目根与地图码组成的文档键。
func document_key() -> String:
	if not app.map_loaded:
		return ""
	var code: String = app.canvas.cur_map_code()
	return str(app.manifest.get("_dir", "")).path_join(code) if code != "" else ""

## 检查延迟确认是否仍针对同一文档；只需身份的预览可容许继续编辑。
func document_guard(check_revision := true) -> Callable:
	var generation := _generation
	var revision := _revision
	var source: Dictionary = app.manifest
	return func() -> bool:
		return app._map_file_ctrl == self and is_same(app.manifest, source) \
			and _generation == generation and (not check_revision or _revision == revision)

func note_edit() -> void:
	_revision += 1

## 待写项盘点（A2 staged）：清单补码 / 暂存内容 / 脏地图。
## 供放弃确认和保存失败提示使用。
func _pending_targets() -> Array:
	var out: Array = []
	if bool(app.manifest.get("_codes_issued", false)):
		out.append("manifest")
	if app.project_shell != null and app.project_shell.content_editor != null:
		if app.project_shell.content_editor.has_staged_content():
			out.append("content")
	if app.map_loaded and app.canvas != null and app.canvas.modified_flag:
		out.append("map")
	return out

## Ctrl+S / 地图菜单：按清单、内容、地图的顺序保存。
func save_all() -> bool:
	if not app.map_loaded and _pending_targets().is_empty():
		app._set_status(" 无地图：先新建或打开一张地图")
		return false
	var res: Dictionary = await commit_document("保存")
	return str(res.get("status", "")) == "ok"

## 确认覆盖并记录本次地图写入基线。
func _confirm_map_write(path: String, guard: Callable) -> Dictionary:
	var baseline := _opened_digest
	var observed := Recovery.observe(path)
	if observed.state == "unreadable" or (observed.state == "missing" and baseline != ""):
		app._set_status(" 保存中止：地图写入目标已变化或不可读，请重新检查后再保存")
		return {}
	if observed.state == "present" and observed.digest != baseline:
		var title := "目标文件已存在" if baseline == "" else "外部改动"
		if not await app._confirm_action(title, "磁盘上的地图与打开时不同。继续保存会覆盖它。", "覆盖保存"):
			app._set_status(" 已取消保存（保留磁盘上的地图）")
			return {}
		if Recovery.digest(path) != observed.digest:
			app._set_status(" 保存中止：确认期间文件又被外部改写")
			return {}
	if not guard.call():
		app._set_status(" 保存中止：工作副本已变化，请重新提交")
		return {}
	return observed

func _finish_map_save(n: String, path: String, data: Dictionary) -> void:
	_opened_digest = Recovery.digest(path)
	app.canvas.map_data["meta"] = data.meta
	app.cur_map_name = n
	app.cur_map_path = path
	app._playtest_ctrl.sync_map_preferences()
	app.canvas.modified_flag = false
	app._layout_ctrl._refresh_dirty_badge()
	_last_autosave_msec = Time.get_ticks_msec()
	# 正式保存成功后清掉草稿。
	_drop_draft_for(n)

## 自动保存草稿（A3）：写到 <项目>/editor/drafts/<地图码>.json，记录目标路径、
## 正式图基线摘要、地图快照、待提交文件与预留 ID，供崩溃/退出后整份恢复。
func maybe_autosave() -> void:
	if not app.map_loaded or not app.canvas.modified_flag or app.cur_map_name == "":
		return
	if Time.get_ticks_msec() - _last_autosave_msec < AUTOSAVE_INTERVAL_MS:
		return
	write_draft_now()

## 立即写草稿（退出确认「保留草稿」、定时器共用；失败退避，不刷屏也不放弃）。
func write_draft_now() -> bool:
	var data: Dictionary = app.canvas.extract()
	if data.is_empty():   # 重建窗口哨兵：本轮跳过，下个周期再存
		return false
	var name: String = app.cur_map_name
	if name == "":
		return false
	data.meta.name = name
	var code := str((data.get("meta", {}) as Dictionary).get("code", ""))
	var target := EditorManifest.map_path(app.manifest, name)
	# 使用本会话的打开摘要，避免把外部编辑误记为草稿基线。
	var baseline := _opened_digest
	if baseline == "":
		baseline = Recovery.digest(target)
	# R03：待提交内容载荷 {fn_id, id, data} 进草稿；恢复时校验绑定后重新暂存。
	var pend: Array = []
	if app.project_shell != null and app.project_shell.content_editor != null:
		pend = app.project_shell.content_editor.staged_rows_current_doc()
	var path := Recovery.write_draft(app.manifest, code, name, target, baseline, data, pend,
		bool(app.manifest.get("_codes_issued", false)),
		EditorManifest.issued_codes(app.manifest) if bool(app.manifest.get("_codes_issued", false)) else {})
	if path == "":
		# 失败退避：半间隔后再试，状态栏只说一次当前问题
		_last_autosave_msec = Time.get_ticks_msec() - (AUTOSAVE_INTERVAL_MS >> 1)
		app._set_status(" 草稿写入失败（%s）：稍后自动重试" % "editor 目录不可写")
		return false
	_last_autosave_msec = Time.get_ticks_msec()
	app._set_status(" 已自动保存草稿 → %s" % path.get_file())
	return true

## 恢复先按地图码定位正式图。名称只为尚未落盘的草稿确定新文件路径。
func _resolve_draft_target(draft: Dictionary, draft_key: String) -> Dictionary:
	var code := str(draft.get("mapCode", ""))
	var name_ := str(draft.get("mapName", draft_key))
	MapStore.invalidate_read_cache()
	MapStore.invalidate_code_map()
	var resolved := ReferenceIndex.resolve_map(app.manifest, code)
	if resolved.status == "ambiguous":
		return {"error": "草稿地图码重复，无法确定正式图"}
	if resolved.status == "ok":
		name_ = resolved.key
	var path := EditorManifest.map_path(app.manifest, name_)
	if path.is_empty():
		return {"error": "草稿地图名无效"}
	var seen := Recovery.observe(path)
	if seen.state == "unreadable":
		return {"error": "正式图无法读取"}
	if seen.state == "present" and resolved.status != "ok":
		# A draft from before code issuance can only reopen the exact file it was based on.
		if seen.digest != draft.get("baseline", ""):
			return {"error": "无法确认同名正式图属于这份草稿"}
		var existing := MapStore.read(app.manifest, name_)
		if existing.is_empty() or existing.get("meta", {}).get("code", "") != "":
			return {"error": "无法确认同名正式图属于这份草稿"}
	return {"name": name_, "path": path, "observed": seen}

func restore_draft_key(draft_key: String) -> bool:
	var draft := Recovery.read_draft_key(app.manifest, draft_key)
	if draft.is_empty():
		app._set_status(" 没有可恢复的草稿：" + draft_key)
		return false
	var resolved := _resolve_draft_target(draft, draft_key)
	if resolved.has("error"):
		app._set_status(" 草稿恢复中止：" + str(resolved.error))
		return false
	var map_name := str(resolved.name)
	var target := str(resolved.path)
	var seen: Dictionary = resolved.observed
	var snap = draft.get("snapshot", null)
	if not (snap is Dictionary) or not MapStore.validate_for_write(snap, app.manifest):
		app._set_status(" 草稿结构无效，无法恢复：" + map_name)
		return false
	# 恢复会把画布整份换掉：当前未保存改动同样要确认（与打开/切图一致）
	var guard := document_guard()
	if not await confirm_discard("恢复草稿"):
		return false
	var base := str(draft.get("baseline", ""))
	var accepted := str(seen.get("digest", ""))
	if accepted != base:
		if not await app._confirm_action("草稿与正式图冲突",
			"正式图在草稿保存后被改动过。\n恢复会把草稿载入画布（磁盘文件不动），Ctrl+S 将覆盖正式图。\n草稿已另存副本保留。",
			"仍然恢复"):
			return false
		_keep_conflict_copy(draft_key)
	var current := _resolve_draft_target(draft, draft_key)
	if not guard.call() or current.get("path", "") != target \
			or current.get("observed", {}).get("digest", "") != accepted:
		app._set_status(" 草稿恢复中止：确认期间文档或正式图已变化")
		return false
	var previous_doc := document_key()
	# 载图前恢复预留码，使挂载与引用拿到和草稿一致的身份。
	var draft_codes = draft.get("codesMap", null)
	if draft_codes is Dictionary and not (draft_codes as Dictionary).is_empty():
		if EditorManifest.merge_issued_codes(app.manifest, draft_codes as Dictionary, true) > 0:
			app.manifest["_codes_issued"] = true
	var gen := _begin_doc_op()
	app.canvas.set_thumbs(app._entity_thumbs())
	await app.canvas.load_data((snap as Dictionary).duplicate(true), map_name, false, true)
	if _doc_stale(gen):
		return false
	_discard_previous_staging(previous_doc)
	app.cur_map_name = map_name
	app.cur_map_path = target
	_name_memo = map_name
	_opened_digest = accepted
	_revision = 0
	app._playtest_ctrl.sync_map_preferences()
	app._set_map_loaded(true)
	app.canvas._undo_history_ctrl.clear_history()
	app.canvas.modified_flag = true   # 草稿内容与磁盘不同：必须显式保存
	# R03：待提交内容载荷重新暂存（绑定在恢复后的画布上才收，其余逐条报告）。
	var pend: Array = draft.get("pendingContents", []) if draft.get("pendingContents", null) is Array else []
	var got := 0
	if not pend.is_empty() and app.project_shell != null and app.project_shell.content_editor != null:
		got = app.project_shell.content_editor.restage_rows(pend)
	var detail := "" if pend.is_empty() else "；暂存内容恢复 %d/%d 条" % [got, pend.size()]
	app._set_status(" 已恢复草稿 %s（Ctrl+S 写回正式图）%s" % [map_name, detail])
	return true

## 冲突时保留草稿副本（原草稿保留，另存一份带时间戳的）
## 名字带草稿键：同一目录下可能有多份草稿，副本必须与来源对得上（A3）。
func _keep_conflict_copy(draft_key: String) -> void:
	var src := Recovery.draft_path_of_key(app.manifest, draft_key)
	var text := Recovery.read_text(src)
	if text == "":
		return
	var stamp := Time.get_datetime_string_from_system().replace(":", "").replace("-", "").replace("T", "-")
	Recovery.write_text(src.get_base_dir().path_join(src.get_file().get_basename() + ".conflict-" + stamp + ".json"), text)

## 正式保存成功后删掉对应草稿（草稿已完成使命）
func _drop_draft_for(name: String) -> void:
	var code := str((app.canvas.map_data.get("meta", {}) as Dictionary).get("code", ""))
	Recovery.remove_draft(app.manifest, code, name)

## 查看草稿对应的正式图；未落盘的草稿没有正式图可打开。
func open_draft_target(draft_key: String) -> void:
	var draft := Recovery.read_draft_key(app.manifest, draft_key)
	if draft.is_empty():
		app._set_status(" 没有这份草稿：" + draft_key)
		return
	var resolved := _resolve_draft_target(draft, draft_key)
	if resolved.has("error") or resolved.get("observed", {}).get("state") != "present":
		app._set_status(" 无法打开正式图：" + str(resolved.get("error", "文件不存在")))
		return
	if not await confirm_discard("打开正式图"):
		return
	await load_map_file(str(resolved.path), str(resolved.observed.digest))

func document_generation() -> int:
	return _generation

## Commit current edits before handing the game its exact published map identity.
func prepare_playtest_document(project_entry: bool) -> Dictionary:
	if not project_entry and not app.map_loaded:
		return {"error": " 无地图：先新建或打开一张地图"}
	if not project_entry and app.cur_map_name == "":
		return {"error": " 试玩前先「新建地图」并填名字"}
	# 只把成功提交后的地图交给游戏。
	var gen := _generation
	var res: Dictionary = await commit_document("试玩前提交")
	if str(res.get("status", "")) != "ok":
		return {"error": " 试玩中止：" + str(res.get("error", "提交未完成"))}
	if _doc_stale(gen) or (app.map_loaded and app.canvas.modified_flag):
		return {"error": " 试玩中止：提交期间文档已变化"}
	var maps_root := str(app.manifest.get("_maps_dir", "")).simplify_path()
	var play_path := "" if project_entry else str(app.cur_map_path).simplify_path()
	var digest := "" if project_entry else _opened_digest
	if not project_entry and (digest == "" or Recovery.digest(play_path) != digest):
		return {"error": " 试玩中止：磁盘地图与已提交版本不一致"}
	if not project_entry and (maps_root == "" or play_path.get_base_dir() != maps_root):
		return {"error": " 试玩中止：地图不在当前项目 maps 目录内，拒绝启动"}
	return {"path": play_path, "digest": digest}


## References identify maps by code. Only the file-opening step needs a name.
func open_map_by_code(code: String) -> bool:
	var target := ReferenceIndex.resolve_map(app.manifest, code)
	if target.status != "ok":
		app._set_status("无法打开地图码：" + code)
		return false
	if not app.map_loaded or app.canvas.cur_map_code() != code:
		await open_map_by_name(target.key)
	return app.map_loaded and app.canvas.cur_map_code() == code


func open_map_by_name(map_name: String) -> void:
	if map_name == app.cur_map_name:
		return
	# 先确认目标存在，再问「要不要丢改动」：目标不存在还先丢改动 = 白白损失工作
	var p := EditorManifest.map_path(app.manifest, map_name)
	if p == "" or not FileAccess.file_exists(p):
		app._set_status(" 地图不存在: " + map_name)
		return
	if not await app._confirm_discard("打开地图 " + map_name):
		return
	await app._load_map_file(p)
