extends RefCounted
## 地图文件生命周期控制器（顶栏「设置 ▾ / 地图 ▾」的动作都在这里）：
## 新建、打开、保存（commit_document 统一提交）、改名（纯改名、不迁移引用）、复制整张图、
## 另存并转换投影、尺寸调整、导出、草稿恢复、地图历史载入。
## 写盘统一走 MapStore（.tmp 原子替换）。**卸载/替换/改名/复制四条路径的保证不同**：
##   替换与改名：单文件写，快照进 editor/history/maps/<地图码>/；
##   复制：多文件提交（内容先、地图后），日志留 editor/pending/ 供崩溃后判读；
##   草稿：写 editor/drafts/，不碰正式图。
## 各入口（本控制器 + 内容视图保存 + 清除悬空）一次会提交哪些文件、按什么顺序，
## 由 docs/EDITOR_FEATURES.md §7.3「各入口提交哪些文件」唯一规定，此处不复述。
## 有未保存修改时新建/打开/切图/关窗口都要先确认；取消即中止。
const ClonePlan := preload("res://src/content/clone_plan.gd")
const UiKitScript := preload("res://src/ui/ui_kit.gd")
const BasisFields := preload("res://src/ui/grid_basis_fields.gd")
const UiThemeScript := preload("res://src/ui/ui_theme.gd")
const K := preload("res://src/core/constants.gd")
const MapStore := preload("res://src/map/map_store.gd")
const Recovery := preload("res://src/map/recovery.gd")
const GridSpaceScript := preload("res://src/canvas/grid_space.gd")
const MapConvert := preload("res://src/map/map_convert.gd")
const DocumentSession := preload("res://src/project/document_session.gd")
const DocumentCommit := preload("res://src/project/document_commit.gd")

var app   # 宿主引用

func _init(host) -> void:
	app = host

const AUTOSAVE_INTERVAL_MS := 120000
var _last_autosave_msec := 0
## 最近一次在新建/重命名弹窗里确认的名字（顶栏常驻名字框已移除，这里记住值供预填）
var _name_memo := ""
## B1（§7.1）：提交编排器（prepare/apply），提交与确认 UI 保留在本文件。
var _doc_commit := DocumentCommit.new()
## §4.4-2：常驻文档会话——项目身份 / 文档令牌 / 正式基线 / 暂存内容 / 补码标记都挂在它上面。
## 以前这些是散落在本文件的一组字段 + 每次提交新建一个空会话，基线只能靠人肉同步。
var sess := DocumentSession.new()

## 进入一次会影响当前文档的操作（新建/切图）：抬会话代数并返回本次代次。
func _begin_doc_op() -> int:
	return sess.bump()

## 本次请求是否已过期（期间又切了图/退出了项目）。过期请求不得发布图名/路径。
func _doc_stale(gen: int) -> bool:
	return sess.stale(gen)

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
	var old_name: String = _effective_map_name()
	if old_name == "":
		app._set_status("当前地图没有名字，无法复制")
		return
	var shell: Dictionary = app._popup_body("复制整张地图",
		"副本的实例与附属内容全部独立（新实例码、新内容 ID），组内引用自动重映射；目标图重发地图码。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var name_edit := LineEdit.new()
	name_edit.text = _unique_map_name(old_name + "_copy")
	name_edit.placeholder_text = "新地图名"
	body.add_child(UiKitScript.field_row("新名字", name_edit))
	# E3：先预览 C2 计划（会复制多少实例/内容/瓦片、有哪些冲突），确认再落盘
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

## C2 计划预览（不写盘）：源 = 画布当前提交状态，目标 = 新图名。
## 返回 {plan: <ClonePlan.build 结果>, err: ""}；名字非法时 err 给原因、plan 为空。
## 预览与执行同一口径：源文档保留自己的地图码（组外引用要钉的是**源图码**，不是图名），
## 未落盘的暂存内容一并参与，否则预览的「内容 N」与冲突和真正执行时不一致（V4 P1）。
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
	var old_name: String = _effective_map_name()
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
	var guard := _commit_is_current.bind(sess.generation, sess.revision, app.manifest)
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
	if old_name != _effective_map_name():
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
	var guard := _commit_is_current.bind(sess.generation, sess.revision, app.manifest)
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
	var prep := MapStore.prepare_duplicate(app.manifest, old_name, new_name, data, staged)
	if not prep.has("plan"):
		error_label.text = str(prep.get("error", "")) + "\n" + ClonePlan.conflicts_text(prep.get("conflicts", []))
		return false
	return await _publish_map_copy(prep.plan, guard, error_label)

func _publish_map_copy(plan: Dictionary, guard: Callable, error_label: Label) -> bool:
	if not guard.call() or app.canvas.doc_busy:
		error_label.text = "文档已变化或正在提交，请重试"
		return false
	app.canvas.doc_busy = true
	var ready := true
	if bool(app.manifest.get("_codes_issued", false)):
		ready = await app._save_manifest_file_async(guard, app.manifest.duplicate(true))
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
	var guard := _commit_is_current.bind(sess.generation, sess.revision, app.manifest)
	var answer := await _ask_discard(action)
	_release_busy()
	return answer and guard.call()

func _discard_previous_staging(doc: String) -> void:
	if doc != "" and app.project_shell != null and app.project_shell.content_editor != null:
		app.project_shell.content_editor.drop_staged_for_doc(doc)

func _ask_discard(action: String) -> bool:
	var message := "地图 %s 有未保存修改。\n继续%s将丢失这些修改。" % [app.cur_map_name, action]
	# A2 staged：盘点随地图一起消失的待写项（含暂存内容与待写清单），
	# 让「放弃」的代价可见——用户至少知道丢的是哪几类，而不是只看到地图脏。
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
	var shell: Dictionary = app._popup_body("新建地图", "名字同时作文件名与显示名。格空间设置随地图保存。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var name_edit := LineEdit.new()
	name_edit.name = "NewMapName"
	# 记住上次填的名字，但已存在的名字不预填（否则一按确定必然撞重名）
	if _name_memo != "" and not FileAccess.file_exists(EditorManifest.map_path(app.manifest, _name_memo)):
		name_edit.text = _name_memo
	name_edit.placeholder_text = "地图名"
	body.add_child(UiKitScript.field_row("地图名", name_edit))
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
	body.add_child(UiKitScript.field_row("格拓扑", topo_sel, UiKitScript.LABEL_W_LONG))
	var basis_editor := BasisFields.add_to(body, "NewMap", GridSpaceScript.tile_size_of(app.manifest))
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
		var basis := BasisFields.read(basis_editor)
		if not basis.ok:
			err_label.text = basis.error
			basis.field.grab_focus()
			return
		create_map_from_dialog(name_edit, err_label, pop,
			str(proj_sel.get_item_metadata(proj_sel.selected)),
			str(topo_sel.get_item_metadata(topo_sel.selected)), basis.value)
	var btn_row := UiKitScript.hbox(8)
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	btn_row.add_child(UiKitScript.button("取消", func(): pop.hide(), "ghost"))
	btn_row.add_child(UiKitScript.button("确定", submit, "primary"))
	name_edit.text_submitted.connect(func(_t: String): submit.call())
	body.add_child(btn_row)
	app._open_popup(pop)

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
		proj := "", topo := "", basis: Array = []) -> void:
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
	var data := MapStore.new_map(n, K.DEFAULT_MAP_W, K.DEFAULT_MAP_H, proj, topo)
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
	await _open_unsaved_map(n, data, "新建空地图")

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
	var previous_doc := _doc_key()
	var gen := _begin_doc_op()
	app.canvas.set_thumbs(app._entity_thumbs())
	await app.canvas.load_data(data, n)
	if _doc_stale(gen):
		return false
	_discard_previous_staging(previous_doc)
	app.cur_map_name = n
	app.cur_map_path = EditorManifest.map_path(app.manifest, n)
	# 新图：身份换到这张，基线清空（磁盘上还没有这份文件）
	sess.set_identity(str(app.manifest.get("_dir", "")), app.canvas.cur_map_code(),
		n, str(app.cur_map_path), "", 0)
	sess.contents = {}
	sess.revision = 0
	app._playtest_ctrl.sync_map_preferences()
	app._set_map_loaded(true)
	app.canvas._undo_history_ctrl.clear_history()
	app.canvas.modified_flag = true
	app._sync_ui()
	app._set_status(" %s %s（先保存再试玩）" % [action, n])
	return true

## 重命名当前地图：弹窗输入新名（顶栏名字框已移除，就地改名入口改到这里）
func on_rename() -> void:
	if not app.map_loaded:
		app._set_status("无地图：先新建或打开一张地图")
		return
	var old_name: String = _effective_map_name()
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
	var btn_row := UiKitScript.hbox(8)
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	btn_row.add_child(UiKitScript.button("取消", func(): pop.hide(), "ghost"))
	btn_row.add_child(UiKitScript.button("确定",
		func(): rename_current_from_dialog(old_name, name_edit, err_label, pop), "primary"))
	body.add_child(btn_row)
	app._open_popup(pop)

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
	if FileAccess.file_exists(new_path):
		return "同名地图已存在"
	var is_current: bool = app.map_loaded and old_name == _effective_map_name()
	var on_disk := old_path != "" and FileAccess.file_exists(old_path)
	if is_current and app.canvas.doc_busy:
		return "另一次文档操作正在进行"
	if on_disk:
		if is_current and sess.opened_digest == "":
			return "原图缺少保存基线，请重新打开后再改名"
		var err: String = MapStore.rename_map(app.manifest, old_name, nn, sess.opened_digest if is_current else "")
		if err != "":
			return err
	elif allow_write_unsaved and is_current:
		if sess.opened_digest != "":
			return "原图已被删除，请重新检查地图文件"
		if bool(app.manifest.get("_codes_issued", false)):
			var guard := _commit_is_current.bind(sess.generation, sess.revision, app.manifest)
			app.canvas.doc_busy = true
			var saved: bool = await app._save_manifest_file_async(guard)
			_release_busy()
			if not saved or not guard.call():
				return "清单未保存或文档已变化"
		# 原图未落盘（新建后还没保存）：改名必须真正落地，否则只改内存名 =
		# 面板显示新名、磁盘上始终没文件，用户看到的「重命名」是假的。
		# R06/§4.4-4：这是一次正式提交（内容 → 地图），走 DocumentCommit 的冻结计划：
		# 暂存内容与地图在同一条日志里，逐目标复验与收据由执行器给。
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
		var map_error := MapStore.write_error(app.manifest, data)
		if map_error != "":
			return "地图校验失败：" + map_error
		var frozen: Array = []
		if ce != null:
			sess.contents = ce.staged_table()
			var prep_contents: Dictionary = _doc_commit.prepare({"manifest": app.manifest,
				"map_snapshot": data}, {"contents": sess.snapshot().get("contents", [])})
			if prep_contents.status == "failed":
				return str(prep_contents.error)
			if prep_contents.status == "ok":
				for target in prep_contents.plan.targets:
					if target.required:
						frozen.append({"kind": "content", "fn_id": str(target.payload.fn_id),
							"id": str(target.id), "data": target.payload.data,
							"expect_absent": target.expect_absent, "baseline": target.baseline})
		# 地图目标带「写前校验 + 历史快照」的语义：用 payload 声明它是地图文档，
		# 执行器按 MapStore.write 的同一入口落盘（不是裸写字节）。
		frozen.append({"kind": "map", "id": nn, "path": new_path, "expect_absent": true,
			"map_data": data})
		var prep: Dictionary = _doc_commit.prepare_frozen("未落盘地图改名落盘 → %s" % nn,
			app.manifest, frozen)
		if str(prep.get("status", "")) != "ok":
			return str(prep.get("error", "提交计划为空：改名已中止"))
		var res: Dictionary = _doc_commit.apply_frozen(prep.get("plan", {}) as Dictionary)
		if ce != null:
			ce.consume_written_staged(res.get("targets", []))
		if str(res.get("status", "")) != "ok":
			var why := str(res.get("error", ""))
			if why == "":
				var cs: Array = res.get("conflicts", [])
				why = str((cs[0] as Dictionary).get("message", "")) if not cs.is_empty() else "改名写盘失败"
			return why
	else:
		return "原图不存在（先保存该地图）"
	if is_current:
		_name_memo = nn
		app.cur_map_name = nn
		app.cur_map_path = new_path
		app.canvas.cur_map_name = nn
		if app.canvas.map_data.has("meta"):
			app.canvas.map_data["meta"]["name"] = nn
		# 历史随地图码走（A3）：码不变则目录不变；无码兜底到图名的旧记录搬到新名下
		var mcode := str((app.canvas.map_data.get("meta", {}) as Dictionary).get("code", ""))
		Recovery.migrate_history(app.manifest, mcode, old_name, mcode, nn)
		sess.rename_doc(nn, str(new_path), Recovery.digest(new_path),
			FileAccess.get_modified_time(new_path))
		# 刚才已把内容写进新文件：脏标记与自动保存计时归零，
		# 否则状态栏还挂着「未保存」、两分钟后又多写一份 .autosave.json。
		if not on_disk:
			app.canvas.modified_flag = false
			_last_autosave_msec = Time.get_ticks_msec()
		app._playtest_ctrl.sync_map_preferences()
	return ""

## 打开另一张地图：先选文件，再确认丢弃，最后载入。
## 顺序是硬约束（V4 P1）：以前先 confirm_discard 再开文件选择器——
## 用户在选图对话框按取消，改动与暂存已经被丢掉，画布却还停在原图（静默数据损失）。
func on_open() -> void:
	var fd := FileDialog.new()
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
	# 读不出来就别问「要不要丢改动」——那等于逼用户丢掉能保住的工作
	var probe: Dictionary = MapStore.read_path(p, app.manifest)
	if not probe.get("ok", false):
		app._set_status(" 打开失败: " + _format_issues(probe.get("errors", [])))
		return
	if not await confirm_discard("打开另一张地图"):
		return
	await load_map_file(p)

func load_map_file(p: String, expected_digest := "") -> void:
	# load_data 是协程（节点重建中间 await 一帧）：必须等它完成，否则切图刚返回时
	# 实体还在重建中——内容页 after_switch 刷新会拿到半重建的画布（列表/点选全乱）。
	# 文档代次（A2）：双击/连续切图时只有最后一次请求可以发布图名与路径。
	# 未保存确认在上层入口（打开/侧栏）做；这里只做真实载入。
	var previous_doc := _doc_key()
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
	# 只认项目 maps 目录内的正式文件（D03）：项目外/别处的同名图必须显式导入，
	# 否则保存会按当前项目拼路径，悄悄覆盖另一个文件。
	var canon := str(p).simplify_path()
	var maps_root := str(app.manifest.get("_maps_dir", "")).simplify_path()
	var outside := maps_root != "" and not canon.begins_with(maps_root.path_join(""))
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
		# 侧效前查代次（V4 P1）：确认期间又发起了别的切图请求，这次导入就不该再写盘
		if _doc_stale(gen):
			return
		# R06：外部图的身份重新登记——源图码不进本项目（可能与现有图撞码），重发项目内新码。
		if data.get("meta", null) is Dictionary:
			(data["meta"] as Dictionary).erase("code")
		MapStore.ensure_code(app.manifest, data)
		if not MapStore.write(app.manifest, base, data):
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
	# 画布重建成功后才发布文档身份（A2）：外部导入/切项目期间路径已变，旧根不得残留。
	# 基线取此刻磁盘上的这份文件。
	sess.set_identity(str(app.manifest.get("_dir", "")), app.canvas.cur_map_code(),
		base, str(p), baseline, FileAccess.get_modified_time(p))
	sess.contents = {}
	sess.revision = 0
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

## A3/E3：地图历史入口（editor/history/maps/<地图码>/，每次正式保存前的快照）。
## 列出版本 → 载入某个版本到画布（磁盘正式文件不动，Ctrl+S 才写回）。
func on_history() -> void:
	if not app.map_loaded:
		app._set_status("无地图：先新建或打开一张地图")
		return
	var name := _effective_map_name()
	var code := str((app.canvas.map_data.get("meta", {}) as Dictionary).get("code", ""))
	var snaps: Array = Recovery.list_history(app.manifest, code, name)
	var shell: Dictionary = app._popup_body("地图历史 —— %s" % name,
		"每次正式保存前自动留一份快照（最多 20 份，最新的在前）。恢复只改画布，Ctrl+S 才写回正式图。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	if snaps.is_empty():
		body.add_child(UiKitScript.hint_label(
			"还没有历史快照：正式保存过一次之后才会出现。草稿在「地图 ▾ → 恢复草稿…」。", 460))
		body.add_child(UiKitScript.button("关闭", func(): pop.hide(), "ghost"))
		app._open_popup(pop)
		return
	var list := ItemList.new()
	list.custom_minimum_size = Vector2(0, 220)
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.max_columns = 1
	var hs_dir := str(app.manifest.get("_dir", "")).path_join("editor/history/maps").path_join(
		Recovery.draft_key(code, name))
	for f in snaps:
		list.add_item(str(f))
	body.add_child(list)
	var hint := UiKitScript.hint_label("", 460)
	body.add_child(hint)
	var restore_btn := UiKitScript.button("恢复选中版本", Callable(), "primary")
	restore_btn.disabled = true
	list.item_selected.connect(func(idx: int):
		restore_btn.disabled = false
		hint.text = "将载入 %s（磁盘文件不动）" % str(list.get_item_text(idx)))
	restore_btn.pressed.connect(func():
		var sel := list.get_selected_items()
		if sel.is_empty():
			return
		var fname := str(list.get_item_text(sel[0]))
		pop.hide()
		_restore_history_snapshot(name, hs_dir.path_join(fname)))
	body.add_child(restore_btn)
	body.add_child(UiKitScript.button("关闭", func(): pop.hide(), "ghost"))
	app._open_popup(pop)

## 历史快照载入画布：按草稿恢复同一条路径（keep_dirty=true，正式文件不动）。
func _restore_history_snapshot(map_name: String, snapshot_path: String) -> void:
	var decoded := MapStore.read_path(snapshot_path, app.manifest)
	if not decoded.ok:
		app._set_status(" 历史快照读取失败：" + snapshot_path.get_file())
		return
	var snap: Dictionary = decoded.data
	var guard := _commit_is_current.bind(sess.generation, sess.revision, app.manifest)
	var path := EditorManifest.map_path(app.manifest, map_name)
	var baseline := Recovery.digest(path)
	if not await app._confirm_action("恢复历史版本",
		"把 %s 载入画布。\n\n正式文件不会被改动；Ctrl+S 才会写回（当前未保存的改动会先被替换）。" % snapshot_path.get_file(),
		"载入") or not guard.call():
		return
	var previous_doc := _doc_key()
	var gen := _begin_doc_op()
	app.canvas.set_thumbs(app._entity_thumbs())
	# 快照里记的是当时的 meta.name（改名前的旧名）：以当前图名为准，保存才不会写回旧名
	if snap.get("meta", null) is Dictionary:
		(snap["meta"] as Dictionary)["name"] = map_name
	await app.canvas.load_data(snap, map_name, false, true)
	if _doc_stale(gen):
		return
	_discard_previous_staging(previous_doc)
	app.cur_map_name = map_name
	app.cur_map_path = path
	sess.set_identity(str(app.manifest.get("_dir", "")), app.canvas.cur_map_code(),
		map_name, path, baseline, FileAccess.get_modified_time(path))
	sess.contents = {}
	sess.revision = 0
	app._playtest_ctrl.sync_map_preferences()
	app._set_map_loaded(true)
	app.canvas.modified_flag = true   # 历史内容与磁盘不同：必须显式保存
	app._set_status(" 已载入历史版本 %s（Ctrl+S 写回 %s）" % [snapshot_path.get_file(), map_name])

## 当前地图名的兜底对齐：app.cur_map_name 与 canvas.cur_map_name 两处记录，以 canvas 为准
func _effective_map_name() -> String:
	var n: String = str(app.cur_map_name).strip_edges()
	var cname: String = str(app.canvas.cur_map_name)
	if cname != "" and cname != n:
		var cpath := EditorManifest.map_path(app.manifest, cname)
		if FileAccess.file_exists(cpath):
			app.cur_map_name = cname
			app.cur_map_path = cpath
			sess.map_name = cname
			sess.map_path = str(cpath)
			sess.opened_digest = Recovery.digest(cpath)
			sess.opened_mtime = FileAccess.get_modified_time(cpath)
			return cname
	return n

## 统一提交入口（A2）：先结束编辑手势，再按「清单 → 内容 → 地图」顺序落盘。
func commit_document(reason := "") -> Dictionary:
	if app.canvas != null and app.canvas.doc_busy:
		return {"status": "failed", "error": "另一次文档操作正在进行"}
	# 正式提交（R28）：先归位未松手的预览型手势，再清手势类型，随后冻结撤销/重做。
	if app.canvas != null:
		if app.canvas.has_method("cancel_preview_gesture"):
			app.canvas.cancel_preview_gesture()
		if app.canvas.has_method("end_gesture"):
			app.canvas.end_gesture()
		app.canvas.doc_busy = true   # 确认/写入期间冻结撤销与重做
	# R01/R04：先收集控件值——可能新增暂存条目或写已有内容文件，目标集合以收集后的为准。
	# 集合失败即中止（V4 P1）：继续提交会让地图带着没落盘的字段值写出去。
	var ce = app.project_shell.content_editor if app.project_shell != null else null
	if ce != null and not ce.commit_fields():
		_release_busy()
		app._set_status(" 提交中止：表单字段写入失败（" + reason + "），地图未写入")
		return {"status": "failed", "written": [], "error": "字段写入失败", "pending": _pending_targets()}
	# B1（§7.1）：提交编排迁到 DocumentCommit——冻结会话快照与 Plan，按依赖序执行；
	# 清单/地图写盘的外部改动确认对话框保留在 UI 侧钩子（_hook_*）里。
	# §4.4-2：会话是常驻的，这里只把「此刻的工作副本」同步进去，再取冻结快照。
	if ce != null:
		sess.contents = ce.staged_table()   # 与 UI 共享同一份工作副本（字典按引用）
	sess.codes_pending = bool(app.manifest.get("_codes_issued", false))
	sess.map_code = str((app.canvas.map_data.get("meta", {}) as Dictionary).get("code", "")) if app.map_loaded else ""
	sess.map_name = str(app.cur_map_name)
	sess.map_path = str(app.cur_map_path)
	sess.project_root = str(app.manifest.get("_dir", ""))
	sess.doc_key = _doc_key()
	var op := {
		"manifest": app.manifest,
		"map_name": app.cur_map_name, "map_path": app.cur_map_path,
		# 从未落过盘的新图（含恢复草稿后正式文件不存在）：即使画布还没标脏也必须建文件，
		# 否则首次保存报「无待写改动」而地图目录里什么都没有。
		"map_dirty": bool(app.map_loaded and app.canvas != null and app.canvas.modified_flag)
			or (app.map_loaded and str(app.cur_map_path) != "" and not FileAccess.file_exists(str(app.cur_map_path))),
	}
	var snap := sess.snapshot()
	if app.map_loaded and (op.map_dirty or not (snap["contents"] as Array).is_empty()):
		var map_snapshot: Dictionary = app.canvas.extract()
		if map_snapshot.is_empty():
			_release_busy()
			return {"status": "failed", "error": "地图正在重建，无法复核暂存依赖"}
		if op.map_dirty:
			map_snapshot.meta.name = str(op.map_name)
			MapStore.ensure_code(app.manifest, map_snapshot)
		op["map_snapshot"] = map_snapshot
	var prep: Dictionary = _doc_commit.prepare(op, snap)
	if str(prep.get("status", "")) == "empty":
		_release_busy()
		if reason != "":
			app._set_status(" 已提交（%s）：无待写改动" % reason)
		return {"status": "ok", "written": [], "error": "", "pending": [], "targets": []}
	if str(prep.get("status", "")) != "ok":
		_release_busy()
		var error := str(prep.get("error", "无法准备提交计划"))
		app._set_status(" 提交中止：" + error)
		return {"status": "failed", "written": [], "error": error, "pending": _pending_targets()}
	# 按依赖顺序写入；写入失败时保留已成功写入的文件。
	var source: Dictionary = app.manifest
	var manifest_snapshot := source.duplicate(true)
	var guard := _commit_is_current.bind(sess.generation, sess.revision, source)
	var frozen_map: Dictionary = op.get("map_snapshot", {})
	var res: Dictionary = await _doc_commit.apply(prep.get("plan", {}) as Dictionary,
		_commit_hooks(guard, frozen_map, manifest_snapshot))
	_release_busy()
	var st := str(res.get("status", ""))
	if st == "ok" and reason != "":
		var wk: Array = res.get("written", [])
		app._set_status(" 已提交（%s）%s" % [reason,
			("：" + ", ".join(PackedStringArray(wk))) if not wk.is_empty() else "：无待写改动"])
	elif st == "conflict":
		app._set_status(" 提交中止：内容文件在提交期间被外部改动（先重扫再试）")
	# §4.4-3：逐目标收据带给调用方（哪些写了/跳过了/没轮到），不再只有一句状态。
	return {"status": st, "written": res.get("written", []), "error": str(res.get("error", "")),
		"receipt": res.get("receipt", {}), "targets": res.get("targets", []),
		"pending": [] if st == "ok" else _pending_targets()}

## 解除文档忙状态（保存失败/取消路径也必须走到，否则撤销永久失效）
func _release_busy() -> void:
	if app.canvas != null:
		app.canvas.doc_busy = false

## 当前文档键（R02/B1）：项目根|地图码（无码退回图名）——与 content_form._doc_key 同一口径。
func _doc_key() -> String:
	if sess.doc_key != "":
		return sess.doc_key
	var root := str(app.manifest.get("_dir", ""))
	var code := ""
	if app.map_loaded and app.canvas != null \
			and (app.canvas.map_data.get("meta", {}) as Dictionary).get("code", null) != null:
		code = str((app.canvas.map_data.get("meta", {}) as Dictionary).get("code", ""))
	if code == "":
		code = str(app.cur_map_name)
	return root.path_join(code)

## B1：apply 的 UI 侧钩子。清单/地图写盘含外部改动确认对话框（协程）；
## 内容逐条冲刷走 content_editor.flush_one_content（绑定复核在表单层）。
func _commit_is_current(gen: int, revision: int, source: Dictionary) -> bool:
	return not sess.stale(gen) and sess.revision == revision and is_same(source, app.manifest)

func _commit_hooks(guard: Callable, frozen_map: Dictionary, manifest_snapshot: Dictionary) -> Dictionary:
	return {
		"save_manifest": app._save_manifest_file_async.bind(guard, manifest_snapshot),
		"save_map": _save_now.bind(frozen_map, guard),
		"flush_one": _hook_flush_one,
		"is_current": guard,
	}

func _hook_flush_one(cid: String, payload := {}) -> Dictionary:
	var ce = app.project_shell.content_editor if app.project_shell != null else null
	if ce == null:
		return {"status": "dropped"}
	return ce.flush_one_content(cid, payload)

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

## 写入提交时冻结的地图。前置内容和清单由提交计划处理。
func _save_now(data: Dictionary, guard: Callable) -> bool:
	if not app.map_loaded:
		app._set_status(" 无地图：先新建或打开一张地图")
		return false
	var gen := sess.generation   # 保存属于发起时的那个文档（A2）：等待后必须仍指向同一份
	var n: String = _effective_map_name()
	if n == "":
		app._set_status(" 当前地图没有名字：先「新建地图」并填名字")
		return false
	if not EditorManifest.is_valid_map_name(n):
		app._set_status(" 地图名不合法：不能含 / \\ : * ? \" < > | 或以 . 开头")
		return false
	if data.is_empty():
		app._set_status(" 地图重建中，保存已跳过：请稍后再试")
		return false
	# 依赖身份先落盘（D06）：本次画布可能用到刚补发的资产码/功能码；地图引用它们前
	# 清单必须先写成功，否则取消/前置失败会留下指向不存在身份的地图。
	if bool(app.manifest.get("_codes_issued", false)):
		if not await app._save_manifest_file_async():
			app._set_status(" 保存中止：清单补码写入失败，地图未写盘")
			return false
	data.meta.name = n
	MapStore.ensure_code(app.manifest, data)   # 地图码（v7）：保存时补发，跨图引用写码的前提
	var path := EditorManifest.map_path(app.manifest, n)
	if path == "":
		app._set_status(" 地图名不合法: " + n)
		return false
	# 保存期间项目/文档被换掉（确认框还开着时切了项目）：此时代次不同，写盘会落到别的项目
	if _doc_stale(gen) or (sess.project_root != "" and sess.project_root != str(app.manifest.get("_dir", ""))):
		app._set_status(" 保存中止：文档已切换，本次改动未写入")
		return false
	# 外部变更检测——打开后磁盘内容变了 = 别处改过这份文件（本次保存会覆盖外部改动）。
	# 摘要优先（A2）：mtime 是秒级粒度，同秒同长度的外部编辑 mtime/长度都撞得上，只有内容摘要能识别。
	# R05：确认绑定到「此刻这份内容」——确认前抓的摘要，确认后仍须一致才写。
	var baseline := sess.opened_digest
	if FileAccess.file_exists(path):
		if sess.opened_digest == "" and sess.opened_mtime == 0:
			# V4 P0-1：本会话里这张图从未落过盘，磁盘上却出现了同名文件
			# （期间别的编辑器/脚本建了图）：按「新文件」覆盖等于删掉别人的图，
			# 必须确认，且确认后复验摘要没再变。
			var appeared := Recovery.digest(path)
			if not await app._confirm_action("目标文件已存在",
				"这张图还没有保存过，但磁盘上已出现同名文件：\n%s\n\n继续保存会覆盖它。" % path,
				"覆盖保存"):
				app._set_status(" 已取消保存（磁盘上的同名地图保持不变）")
				return false
			if Recovery.digest(path) != appeared:
				app._set_status(" 保存中止：确认期间文件又被外部改写，请重新检查后再保存")
				return false
			baseline = appeared
		var cur_digest := Recovery.digest(path)
		var ext_changed := false
		if sess.opened_digest != "" and cur_digest != "":
			ext_changed = cur_digest != sess.opened_digest
		elif sess.opened_mtime > 0:
			ext_changed = FileAccess.get_modified_time(path) != sess.opened_mtime
		if ext_changed:
			# C-20：保存前确认而不是覆盖后提示——外部改动是别人的工作，覆盖是破坏性动作
			if not await app._confirm_action("外部改动",
				"地图文件在编辑器打开后被外部修改过。\n覆盖保存将丢失外部改动（上一轮快照已存进 editor/history/maps/<地图码>/）。",
				"覆盖保存"):
				app._set_status(" 已取消保存（保留磁盘上的外部改动）")
				return false
			# 确认后复验：确认期间又被外部改写就不覆盖（R05）
			if Recovery.digest(path) != cur_digest:
				app._set_status(" 保存中止：确认期间文件又被外部改写，请重新检查后再保存")
				return false
			baseline = cur_digest
	# 确认等待期间内容又被外部改过：避免「确认的是 A、覆盖的是 B」
	if not guard.call():
		app._set_status(" 保存中止：工作副本已变化，请重新提交")
		return false
	var observed := Recovery.observe(path)
	if (baseline == "" and observed.state != "missing") or (baseline != "" and \
			(observed.state != "present" or observed.digest != baseline)):
		app._set_status(" 保存中止：地图写入目标已变化或不可读，请重新检查后再保存")
		return false
	# 写盘收敛到 MapStore 单入口（.tmp 原子替换，中途崩溃不留半截 JSON）；
	# 写前校验不过时把首个错误带回状态栏，避免只看到「保存失败」无从下手。
	if not MapStore.write(app.manifest, n, data):
		var why: String = MapStore.write_error(app.manifest, data)
		if why == "":
			why = MapStore.identity_error(app.manifest, n, data)
		app._set_status(" 保存失败: %s%s" % [path, ("（%s）" % why) if why != "" else ""])
		return false
	# 基线前移（§4.4-2）：此后外部改动 = 相对这次写入的内容
	sess.note_saved(str(path), Recovery.digest(path), FileAccess.get_modified_time(path))
	app.canvas.cur_map_name = n
	app.canvas.map_data["meta"] = data.meta
	app.cur_map_name = n
	app.cur_map_path = path
	app._playtest_ctrl.sync_map_preferences()
	app.canvas.modified_flag = false
	_last_autosave_msec = Time.get_ticks_msec()
	var tcount2 := 0
	for lid2 in (data.get("tiles", {}) as Dictionary):
		tcount2 += ((data.get("tiles", {}) as Dictionary)[lid2] as Array).size()
	var msg := " 已保存 %s（%d 瓦片 / %d 摆放物）" % [n, tcount2, (data.get("objects", []) as Array).size()]
	app._set_status(msg)
	# 正式保存成功：草稿完成使命，删掉（A3）；历史快照此时才纳入（见 MapStore.write）
	_drop_draft_for(n)
	return true

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
	var name := _effective_map_name()
	if name == "":
		return false
	data.meta.name = name
	var code := str((data.get("meta", {}) as Dictionary).get("code", ""))
	var target := EditorManifest.map_path(app.manifest, name)
	# R08：草稿基线 = 本会话打开/上次提交时的摘要（没有才退回当前磁盘摘要）——
	# 外部改写发生在打开之后、写草稿之前时，磁盘摘要会把外部版本误记为本会话基线。
	var baseline := sess.opened_digest
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
		_last_autosave_msec = Time.get_ticks_msec() - AUTOSAVE_INTERVAL_MS / 2
		app._set_status(" 草稿写入失败（%s）：稍后自动重试" % "editor 目录不可写")
		return false
	_last_autosave_msec = Time.get_ticks_msec()
	app._set_status(" 已自动保存草稿 → %s" % path.get_file())
	return true

## 恢复草稿：把快照载入画布并标记脏（正式文件未动，Ctrl+S 才写回）。
## 参数是**草稿键**（文件名，A3）：带地图码的地图键是码、不带码才是图名，
## 拿「空码 + 图名」重算路径会算出另一个键，读不到自己刚写的草稿。
func _resolve_draft_target(draft: Dictionary, fallback: String) -> Dictionary:
	var name_ := str(draft.get("mapName", ""))
	if name_ == "":
		name_ = fallback
	var code := str(draft.get("mapCode", ""))
	MapStore.invalidate_read_cache()
	MapStore.invalidate_code_map()
	var index := MapStore.code_index(app.manifest)
	var matches: Array = index.get("by_code", {}).get(code, [])
	if matches.size() > 1:
		return {"error": "草稿地图码重复，无法确定正式图"}
	if matches.size() == 1:
		name_ = str(matches[0])
	var path := EditorManifest.map_path(app.manifest, name_)
	if path == "":
		return {"error": "草稿地图名无效"}
	var seen := Recovery.observe(path)
	if seen.state == "unreadable":
		return {"error": "正式图无法读取"}
	if seen.state == "present" and code != "" and matches.is_empty():
		return {"error": "同名正式图的地图码与草稿不一致"}
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
	var guard := _commit_is_current.bind(sess.generation, sess.revision, app.manifest)
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
	var previous_doc := _doc_key()
	# V4 P0-2：草稿记录的预留码必须在装载画布**之前**合回清单。
	# 装载会做 C09 挂载补齐、实例码生成与引用解析——这些都以当前清单码为准；
	# 先装载再合并，画布上的绑定/字段键已经按启动时临时补发的新码算好了。
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
	sess.set_identity(str(app.manifest.get("_dir", "")), app.canvas.cur_map_code(),
		map_name, target, accepted, FileAccess.get_modified_time(target) if accepted != "" else 0)
	sess.revision = 0
	app._playtest_ctrl.sync_map_preferences()
	app._set_map_loaded(true)
	app.canvas._undo_history_ctrl.clear_history()
	app.canvas.modified_flag = true   # 草稿内容与磁盘不同：必须显式保存
	# R03：待提交内容载荷重新暂存（绑定在恢复后的画布上才收，其余逐条报告）。
	var pend: Array = draft.get("pendingContents", []) if draft.get("pendingContents", null) is Array else []
	if not pend.is_empty() and app.project_shell != null and app.project_shell.content_editor != null:
		var got: int = app.project_shell.content_editor.restage_rows(pend)
		if got < pend.size():
			app._set_status(" 草稿里 %d 条待提交内容未恢复（绑定已不在恢复后的画布上）" % (pend.size() - got))
		elif got > 0:
			app._set_status(" 已随草稿恢复 %d 条暂存内容（Ctrl+S 时落盘）" % got)
	app._set_status(" 已恢复草稿 %s（Ctrl+S 写回正式图）" % map_name)
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

## 「查看正式图」：草稿只记身份，不记磁盘外的东西——按草稿里的 targetPath 打开正式图。
## targetPath 缺失/已删时退回按图名在项目里找（图被改名时可能找不到，状态栏说清楚）。
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
	return sess.generation

## Commit current edits before handing the game its exact published map identity.
func prepare_playtest_document(project_entry: bool) -> Dictionary:
	if not project_entry and not app.map_loaded:
		return {"error": " 无地图：先新建或打开一张地图"}
	if not project_entry and _effective_map_name() == "":
		return {"error": " 试玩前先「新建地图」并填名字"}
	# 试玩只拿「成功提交后的项目内路径」（A2）：先走统一提交（清单码 → 内容 → 地图），
	# 失败就停，避免游戏侧读到半套内容。
	var gen := sess.generation
	var res: Dictionary = await commit_document("试玩前提交")
	if str(res.get("status", "")) != "ok":
		return {"error": " 试玩中止：" + str(res.get("error", "提交未完成"))}
	if sess.stale(gen) or (app.map_loaded and app.canvas.modified_flag):
		return {"error": " 试玩中止：提交期间文档已变化"}
	var receipt: Dictionary = res.get("receipt", {})
	var maps_root := str(app.manifest.get("_maps_dir", "")).simplify_path()
	var play_path := "" if project_entry else str(receipt.get("absolute_path", sess.map_path)).simplify_path()
	var digest := "" if project_entry else str(receipt.get("map_digest", sess.opened_digest))
	if not project_entry and (digest == "" or Recovery.digest(play_path) != digest):
		return {"error": " 试玩中止：磁盘地图与已提交版本不一致"}
	if not project_entry and (maps_root == "" or play_path.get_base_dir() != maps_root):
		return {"error": " 试玩中止：地图不在当前项目 maps 目录内，拒绝启动"}
	return {"path": play_path, "digest": digest}


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
