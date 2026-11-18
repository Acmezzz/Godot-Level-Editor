extends VBoxContainer
## 实体资产界面（快速总表 + 图鉴详情），从 app.gd 拆出以降低耦合。
## 清单对象与写回动作由 app.gd 注入：manifest 字典、save_manifest 回调。
##
## 视觉统一走 UiTheme / UiKit：顶栏用品牌 + 幽灵返回键，总表用表头带底色的
## 七列网格，详情页左侧列表 + 右侧编辑区，所有可编辑控件都是明确的输入样式。

signal closed   # 返回关卡编辑器

const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")
const MapStore := preload("res://src/map_store.gd")
const DefModel := preload("res://src/content/def_model.gd")
const ContentStore := preload("res://src/content/content_store.gd")

var manifest := {}
var save_manifest: Callable
var host = null  # 宿主 app（定位跳转/确认框复用其链路）

var asset_list: ItemList
var stats_grid: GridContainer
var fields_grid: GridContainer
var name_edit: LineEdit
var thumb: TextureRect
var _detail_hint: Label
var extra: VBoxContainer

var _edef: Dictionary = {}
var _loading := false

## 整页底色：直接画在控件自身，不额外插入节点、不占布局，也不会露出默认灰
func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Th.BG_BASE)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()

# —— UI 构建 ——
func build() -> void:
	add_theme_constant_override("separation", 0)
	# 顶栏（标题/项目徽章）已收进项目页外壳 project_shell.gd，这里只做内容区

	# —— 图鉴详情（资产视图的唯一页面：左列图鉴列表 + 右侧详情） ——
	var detail_view := Kit.hbox(0)
	detail_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(detail_view)

	var left_wrap := PanelContainer.new()
	left_wrap.custom_minimum_size = Vector2(272, 0)
	left_wrap.size_flags_horizontal = Control.SIZE_FILL
	left_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var left_sb := Th.box(Th.BG_PANEL, Th.BORDER, 0, 10, 10)
	left_sb.set_border_width_all(0)
	left_sb.border_width_right = 1
	left_wrap.add_theme_stylebox_override("panel", left_sb)
	detail_view.add_child(left_wrap)
	var left := Kit.vbox(8)
	left_wrap.add_child(left)
	left.add_child(Kit.section_label("图鉴"))
	asset_list = ItemList.new()
	asset_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	asset_list.icon_mode = ItemList.ICON_MODE_LEFT
	asset_list.fixed_icon_size = Vector2i(40, 40)
	asset_list.item_clicked.connect(_on_asset_pick)
	left.add_child(asset_list)

	var detail_scroll := ScrollContainer.new()
	detail_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	detail_view.add_child(detail_scroll)
	var det_margin := MarginContainer.new()
	det_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	det_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	det_margin.add_theme_constant_override("margin_left", 18)
	det_margin.add_theme_constant_override("margin_right", 18)
	det_margin.add_theme_constant_override("margin_top", 14)
	det_margin.add_theme_constant_override("margin_bottom", 18)
	detail_scroll.add_child(det_margin)
	var det := Kit.vbox(12)
	det.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	det_margin.add_child(det)

	# 头部：大图 + 名称
	var hdr := Kit.hbox(16)
	det.add_child(hdr)
	_detail_hint = Kit.hint_label("没有匹配的资产", 320)
	_detail_hint.visible = false
	det.add_child(_detail_hint)
	var thumb_wrap := PanelContainer.new()
	thumb_wrap.add_theme_stylebox_override("panel", Th.box(Th.BG_VOID, Th.BORDER, Th.R_CONTAINER, 8, 8))
	hdr.add_child(thumb_wrap)
	thumb = TextureRect.new()
	thumb.custom_minimum_size = Vector2(160, 160)
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumb_wrap.add_child(thumb)

	var name_box := Kit.vbox(8)
	name_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_box.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	hdr.add_child(name_box)
	name_box.add_child(Kit.section_label("图鉴名称"))
	name_edit = LineEdit.new()
	name_edit.add_theme_font_size_override("font_size", Th.FS_LG)
	name_box.add_child(name_edit)
	name_box.add_child(Kit.hint_label("名称与下方数值即时写回清单，下次试玩生效"))

	det.add_child(Kit.divider())
	det.add_child(Kit.section_label("数值模板（stats）"))
	stats_grid = GridContainer.new()
	stats_grid.columns = 7
	stats_grid.add_theme_constant_override("h_separation", 8)
	stats_grid.add_theme_constant_override("v_separation", 6)
	det.add_child(stats_grid)

	det.add_child(Kit.divider())
	det.add_child(Kit.section_label("字段定义（引用及其它）"))
	fields_grid = GridContainer.new()
	fields_grid.columns = 7
	fields_grid.add_theme_constant_override("h_separation", 8)
	fields_grid.add_theme_constant_override("v_separation", 6)
	det.add_child(fields_grid)

	extra = Kit.vbox(8)
	det.add_child(Kit.divider())
	det.add_child(extra)

	# U-01：编辑态只改内存；失焦/回车统一提交（每击键全量写盘+整表重建太重）
	name_edit.text_changed.connect(func(t: String):
		if _edef.is_empty() or _loading:
			return
		_edef["name"] = t)
	name_edit.text_submitted.connect(func(_t: String): _commit_name())
	name_edit.focus_exited.connect(_commit_name)

## U-01：名称提交（写盘）
func _commit_name() -> void:
	if _edef.is_empty() or _loading:
		return
	save_manifest.call()

# —— 视图切换 ——
func show_detail(sid: String) -> void:
	refresh_list(sid)

# —— 图鉴列表 ——
func refresh_list(focus_sid := "") -> void:
	asset_list.clear()
	var focus_idx := -1
	var idx := 0
	for edef in manifest.get("entities", []):
		# C1/B7：内置种类不进图鉴（trigger_zone 由编辑器提供，不可编辑/删除）
		if bool(edef.get("builtin", false)):
			continue
		var sid := str(edef.get("id", ""))
		asset_list.add_item(str(edef.get("name", sid)), _asset_texture(edef))
		# U-05：tooltip 露出 id——地图数据引用的是它，界面上看不到就没法排查
		asset_list.set_item_tooltip(idx, sid + "  ·  " + str(edef.get("name", sid)))
		asset_list.set_item_metadata(idx, sid)
		if sid == focus_sid:
			focus_idx = idx
		idx += 1
	if focus_idx < 0 and asset_list.item_count > 0:
		focus_idx = 0
	if focus_idx >= 0:
		asset_list.select(focus_idx)
		_show_detail(str(asset_list.get_item_metadata(focus_idx)))

func _on_asset_pick(idx: int, _at: Vector2 = Vector2.ZERO, mb: int = 0) -> void:
	# U-04：只认左键（与实体大纲列表同一约定）
	if mb != MOUSE_BUTTON_LEFT:
		return
	_show_detail(str(asset_list.get_item_metadata(idx)))

func _show_detail(sid: String) -> void:
	_edef = {}
	for edef in manifest.get("entities", []):
		if str(edef.get("id", "")) == sid:
			_edef = edef
			break
	if _edef.is_empty():
		# 空匹配（例如详情里删掉了当前资产）不能留上一项的陈旧数据
		name_edit.text = ""
		thumb.texture = null
		_asset_editor_rows(stats_grid, {})
		_asset_field_rows(fields_grid, {})
		_detail_hint.text = "没有匹配的资产"
		_detail_hint.visible = true
		return
	_detail_hint.visible = false
	_loading = true
	name_edit.text = str(_edef.get("name", sid))
	thumb.texture = _asset_texture(_edef)
	_asset_editor_rows(stats_grid, _edef)
	_asset_field_rows(fields_grid, _edef)
	for child in extra.get_children():
		extra.remove_child(child)
		child.queue_free()
	extra.add_child(Kit.section_label("资产标识"))
	extra.add_child(Kit.hint_label("id: %s   —— 稳定键，被地图数据全项目引用，不可在此重命名" % sid))
	_add_size_row()
	_add_distribution_section(sid)
	var del := Kit.button("删除此资产", func(): _delete_asset_checked(sid), "ghost")
	del.add_theme_color_override("font_color", Th.ERR)
	del.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	extra.add_child(del)
	_loading = false

## T5：占位尺寸行——0×0 = 未设置（从 prefab 碰撞形状解析）；非零写入 editorSize: [w, h]
func _add_size_row() -> void:
	extra.add_child(Kit.section_label("编辑器占位尺寸 editorSize"))
	var row := Kit.hbox(8)
	var w_spin := SpinBox.new()
	w_spin.min_value = 0
	w_spin.max_value = 999
	w_spin.step = 1
	var h_spin := SpinBox.new()
	h_spin.min_value = 0
	h_spin.max_value = 999
	h_spin.step = 1
	var es = _edef.get("editorSize", null)
	if es is Array and (es as Array).size() >= 2:
		w_spin.value = float(es[0])
		h_spin.value = float(es[1])
	var apply := func(_v: float):
		var w := int(w_spin.value)
		var h := int(h_spin.value)
		if w <= 0 or h <= 0:
			_edef.erase("editorSize")
		else:
			_edef["editorSize"] = [w, h]
		save_manifest.call()
	w_spin.value_changed.connect(apply)
	h_spin.value_changed.connect(apply)
	w_spin.custom_minimum_size = Vector2(96, 0)
	h_spin.custom_minimum_size = Vector2(96, 0)
	w_spin.tooltip_text = "画布占位框宽（像素）。0 = 不设置，回退 prefab 碰撞形状"
	h_spin.tooltip_text = "画布占位框高（像素）。0 = 不设置，回退 prefab 碰撞形状"
	row.add_child(w_spin)
	var times := Kit.text_label("×", Th.TEXT_MUTE, Th.FS_SMALL)
	times.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(times)
	row.add_child(h_spin)
	# 自动换行 Label 不给死宽度会被测成 0 宽、一字一行竖排（实证 P0）
	row.add_child(Kit.hint_label("0 = 从 prefab 碰撞形状解析", 220))
	extra.add_child(row)

## 实例分布（模型阶段 1 §5 + v2 §4）：每实例一行——id/坐标 + 各数值就地可改 + 定位。
## 数值 = 三层合并（实例 > 定义 > 清单），与属性面板/游戏运行时同一算法（DefModel.effective_stats）。
## 改值 = 写该实例的 props.stats 覆盖（不是改类型模板）；当前打开的地图走画布内存，
## 其余地图直接落盘——两处入口改的都是同一份数据，只是路径不同。
var _dist_rows: VBoxContainer

func _add_distribution_section(sid: String) -> void:
	extra.add_child(Kit.section_label("实例分布"))
	_dist_rows = Kit.vbox(4)
	extra.add_child(_dist_rows)
	_fill_distribution(sid)

func _fill_distribution(sid: String) -> void:
	if _dist_rows == null:
		return
	for c in _dist_rows.get_children():
		_dist_rows.remove_child(c)
		c.queue_free()
	var dist := _instance_distribution(sid)
	if dist.is_empty():
		_dist_rows.add_child(Kit.hint_label("没有已放置实例", 220))
		return
	var sdefs: Array = _edef.get("stats", [])
	var has_stats := not (sdefs as Array).is_empty()
	var total := 0
	for map_name in dist:
		var rows: Array = dist[map_name]
		total += rows.size()
		var head := Kit.hbox(6)
		head.add_child(Kit.text_label("%s × %d" % [map_name, rows.size()], Th.TEXT, Th.FS_SMALL))
		_dist_rows.add_child(head)
		for r in rows:
			_dist_rows.add_child(_dist_row(map_name, r, sdefs))
	var foot := "共 %d 个实例 / %d 张地图" % [total, dist.size()]
	if has_stats:
		foot += "　·　改数值 = 只改这个实例，不影响同类型其它实例"
	_dist_rows.add_child(Kit.hint_label(foot, 460))

## 全项目扫描：{地图名: [{id, x, y, def, props}, ...]}——实例分布、K7 删除检查与实例数值显示共用数据源
## 当前打开的地图优先用画布内存值：磁盘上还没保存的改动也要能在这里看到并继续改。
func _instance_distribution(sid: String) -> Dictionary:
	var out := {}
	var maps := MapStore.read_all(manifest)
	var by_id := {}
	if host != null and host.canvas != null and is_instance_valid(host.canvas) and host.canvas.entities != null:
		by_id = host.canvas._ent_by_id_index()
	for map_name in maps:
		var data: Dictionary = maps[map_name]
		var is_cur: bool = host != null and map_name == str(host.cur_map_name)
		var rows: Array = []
		for ent in data.get("entities", []):
			if not (ent is Dictionary) or str(ent.get("scene", "")) != sid:
				continue
			var ent_id := str(ent.get("id", ""))
			var props = ent.get("props", {})
			var row := {
				"id": ent_id,
				"x": int(ent.get("x", 0)),
				"y": int(ent.get("y", 0)),
				"def": str(ent.get("def", "")),
				"props": props if props is Dictionary else {},
			}
			var spr = by_id.get(ent_id, null)
			if is_cur and spr != null and is_instance_valid(spr):
				var live = spr.get_meta("props", {})
				row["props"] = live if live is Dictionary else {}
				row["def"] = str(spr.get_meta("def_id", ""))
			rows.append(row)
		if not rows.is_empty():
			out[map_name] = rows
	return out

## 分布行：id · 各数值就地可改 · 定位。数值框直接写该实例的 props.stats 覆盖。
func _dist_row(map_name: String, r: Dictionary, sdefs: Array) -> Control:
	var row := Kit.hbox(10)
	var rid := str(r.get("id", ""))
	var ids := Kit.text_label(rid, Th.TEXT_MUTE, Th.FS_META)
	ids.custom_minimum_size = Vector2(84, 0)
	ids.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	ids.tooltip_text = "%s  (%d,%d)" % [map_name, int(r.get("x", 0)), int(r.get("y", 0))]
	row.add_child(ids)
	if (sdefs as Array).is_empty():
		var lbl := Kit.text_label("这个类型没有数值项", Th.TEXT_MUTE, Th.FS_SMALL)
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(lbl)
	else:
		var props: Dictionary = r.get("props", {}) if r.get("props") is Dictionary else {}
		var ov: Dictionary = props.get("stats", {}) if props.get("stats", {}) is Dictionary else {}
		var def_res := {}
		var did := str(r.get("def", ""))
		if did != "":
			def_res = ContentStore.read(manifest, "defs", did)
		var eff: Dictionary = DefModel.effective_stats(def_res, _edef, props)
		var cells := Kit.hbox(8)
		cells.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(cells)
		for sf in sdefs:
			var stat_id := str(sf.get("id", ""))
			if stat_id == "":
				continue
			var cell := Kit.hbox(3)
			var nl := Kit.text_label(str(sf.get("name", stat_id)), Th.TEXT_MUTE, Th.FS_META)
			nl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			cell.add_child(nl)
			var box := SpinBox.new()
			box.min_value = float(sf.get("min", 0.0))
			box.max_value = float(sf.get("max", 999.0))
			box.step = 0.1 if str(sf.get("type", "float")) == "float" else 1.0
			box.value = float(eff.get(stat_id, sf.get("default", 0.0)))
			box.custom_minimum_size = Vector2(64, 0)
			box.tooltip_text = "只改「%s」这个实例；%s" % [rid,
				"已覆盖类型模板" if ov.has(stat_id) else "当前继承类型模板，改动即覆盖"]
			# 撤销合并：连续调同一个框只压一次撤销（和属性面板同一约定）
			var session := {"started": false}
			box.get_line_edit().focus_exited.connect(func(): session.started = false)
			box.value_changed.connect(func(v: float):
				if not session.started:
					session.started = true
					if host != null and map_name == str(host.cur_map_name) and host.canvas != null and host.canvas.entities != null:
						host.canvas._push_undo()
				_set_instance_stat(map_name, rid, stat_id, v)
				box.tooltip_text = "只改「%s」这个实例；已覆盖类型模板" % rid)
			cell.add_child(box)
			cells.add_child(cell)
		row.add_child(Kit.spacer())
	row.add_child(Kit.button("定位", func(): host._focus_ent_in_map(map_name, rid), "ghost"))
	return row

## 写单实例数值：当前地图走画布（撤销栈/脏标记与属性面板同路），其余地图直接落盘。
## 两个入口改的是同一份地图数据，区别只在「已经打开」与否。
func _set_instance_stat(map_name: String, ent_id: String, stat_id: String, v: float) -> void:
	if ent_id == "" or stat_id == "":
		return
	if host != null and map_name == str(host.cur_map_name) and host.canvas != null and host.canvas.entities != null:
		var spr = host.canvas._ent_by_id_index().get(ent_id, null)
		if spr == null or not is_instance_valid(spr):
			return
		var props: Dictionary = spr.get_meta("props", {})
		if not (props is Dictionary):
			props = {}
		var ov: Dictionary = props.get("stats", {}) if props.get("stats", {}) is Dictionary else {}
		ov[stat_id] = v
		props["stats"] = ov
		spr.set_meta("props", props)
		host.canvas._mark()
		host._set_status("  %s · %s 已改为 %s（仅此实例）" % [ent_id, stat_id, _fmt_num(v)])
		return
	# 非当前地图：读 → 改 → 写。写盘走 MapStore 的原子替换 + 历史轮转。
	var data: Dictionary = MapStore.read(manifest, map_name)
	if data.is_empty():
		return
	var ent := MapStore.find_entity(data, ent_id)
	if ent.is_empty():
		return
	var p2 = ent.get("props", {})
	var props2: Dictionary = p2 if p2 is Dictionary else {}
	var ov2: Dictionary = props2.get("stats", {}) if props2.get("stats", {}) is Dictionary else {}
	ov2[stat_id] = v
	props2["stats"] = ov2
	ent["props"] = props2
	if MapStore.write(manifest, map_name, data):
		host._set_status("  %s · %s 已改为 %s（仅此实例，已写盘）" % [ent_id, stat_id, _fmt_num(v)])
	else:
		host._set_status("  写盘失败：%s" % map_name)

func _fmt_num(v: float) -> String:
	return "%d" % int(v) if v == floorf(v) else "%.1f" % v

## K7：删除资产前引用检查——列出仍在使用该类型的地图与实例数；有引用需确认
func _delete_asset_checked(sid: String) -> void:
	# C1/B7：内置种类拒绝删除
	if bool(_edef.get("builtin", false)):
		host._set_status(" 内置种类由编辑器提供，不能删除")
		return
	# 有引用先列出来；没有引用也要问一次——删资产不可撤销
	var dist := _instance_distribution(sid)
	var text := "将删除资产「%s」(%s)，不可撤销。" % [str(_edef.get("name", sid)), sid]
	if not dist.is_empty():
		var lines := []
		var total := 0
		for map_name in dist:
			var n: int = (dist[map_name] as Array).size()
			total += n
			lines.append("%s × %d" % [map_name, n])
		text += "\n\n还有 %d 张地图在用（共 %d 个实例）：%s。\n删除后这些实体失去调色板/占位框/导出依据。" % [dist.size(), total, ", ".join(lines)]
	else:
		text += "\n\n当前没有地图实例在用它。"
	if not await host._confirm_action("删除资产", text, "删除"):
		return
	manifest.get("entities", []).erase(_edef)
	save_manifest.call()
	_edef = {}
	# 删除后留在图鉴：刷新列表并落到第一项（没有则给空态提示）
	refresh_list()

# —— stats 模板行 ——
func _asset_editor_rows(grid: GridContainer, edef: Dictionary) -> void:
	for c in grid.get_children():
		grid.remove_child(c)
		c.queue_free()
	if _dedupe_stat_ids(edef):
		save_manifest.call()
	for h in ["名称", "id", "类型", "默认", "最小", "最大", ""]:
		grid.add_child(Kit.text_label(h, Th.TEXT_MUTE, Th.FS_META))
	for sf in edef.get("stats", []):
		var nm := LineEdit.new()
		nm.text = str(sf.get("name", ""))
		nm.custom_minimum_size = Vector2(78, 0)
		# P0-6：编辑只改内存，失焦/回车才写盘（每击键全量写 JSON 会持续打盘）
		nm.text_changed.connect(func(t: String): sf["name"] = t)
		nm.text_submitted.connect(func(_t: String): save_manifest.call())
		nm.focus_exited.connect(func(): save_manifest.call())
		grid.add_child(nm)
		var idl := LineEdit.new()
		idl.text = str(sf.get("id", ""))
		idl.editable = false
		idl.custom_minimum_size = Vector2(96, 0)
		grid.add_child(idl)
		var tsel := OptionButton.new()
		tsel.add_item("int")
		tsel.add_item("float")
		tsel.select(1 if str(sf.get("type", "float")) == "float" else 0)
		tsel.item_selected.connect(func(idx: int):
			sf["type"] = ["int", "float"][idx]
			save_manifest.call())
		grid.add_child(tsel)
		var step := 1.0 if str(sf.get("type", "float")) == "int" else 0.1
		var defs := SpinBox.new()
		defs.min_value = -999999
		defs.max_value = 999999
		defs.step = step
		defs.value = float(sf.get("default", 0))
		defs.custom_minimum_size = Vector2(56, 0)
		defs.value_changed.connect(func(v: float):
			sf["default"] = v
		)
		defs.focus_exited.connect(func():
			save_manifest.call())
		grid.add_child(defs)
		# U-03：三个数值统一 SpinBox；min/max 互相钳制保证 min<=max（先声明再连接，lambda 才能引用彼此）
		var mins := SpinBox.new()
		mins.min_value = -999999
		mins.max_value = 999999
		mins.step = step
		mins.value = float(sf.get("min", 0))
		mins.custom_minimum_size = Vector2(56, 0)
		var maxs := SpinBox.new()
		maxs.min_value = -999999
		maxs.max_value = 999999
		maxs.step = step
		maxs.value = float(sf.get("max", 0))
		maxs.custom_minimum_size = Vector2(56, 0)
		mins.value_changed.connect(func(v: float):
			sf["min"] = v
			if float(sf.get("max", 0)) < v:
				sf["max"] = v
				maxs.set_value_no_signal(v)
		)
		mins.focus_exited.connect(func():
			save_manifest.call())
		maxs.value_changed.connect(func(v: float):
			sf["max"] = v
			if float(sf.get("min", 0)) > v:
				sf["min"] = v
				mins.set_value_no_signal(v)
		)
		maxs.focus_exited.connect(func():
			save_manifest.call())
		grid.add_child(mins)
		grid.add_child(maxs)
		var sdel := Kit.button("✕", func():
			(edef.get("stats", []) as Array).erase(sf)
			save_manifest.call()
			_asset_editor_rows(grid, edef), "icon")
		sdel.tooltip_text = "删除这个数值项（实例上的覆盖值会变成孤立数据）"
		grid.add_child(sdel)

# —— 字段定义行 ——
func _asset_field_rows(grid: GridContainer, edef: Dictionary) -> void:
	for c in grid.get_children():
		grid.remove_child(c)
		c.queue_free()
	for h in ["名称", "id", "类型", "of 目标类型", "enum 选项（逗号分隔）", "默认值", ""]:
		grid.add_child(Kit.text_label(h, Th.TEXT_MUTE, Th.FS_META))
	for f in edef.get("fields", []):
		var nm := LineEdit.new()
		nm.text = str(f.get("name", ""))
		nm.custom_minimum_size = Vector2(90, 0)
		# P0-6：失焦提交（同 stats 行）
		nm.text_changed.connect(func(t: String): f["name"] = t)
		nm.text_submitted.connect(func(_t: String): save_manifest.call())
		nm.focus_exited.connect(func(): save_manifest.call())
		grid.add_child(nm)
		var idl := LineEdit.new()
		idl.text = str(f.get("id", ""))
		idl.editable = false
		idl.custom_minimum_size = Vector2(96, 0)
		grid.add_child(idl)
		var tsel := OptionButton.new()
		tsel.add_item("string")
		tsel.add_item("entity_ref")
		tsel.add_item("map_ref")
		tsel.add_item("enum")
		tsel.add_item("bool")
		var types := ["string", "entity_ref", "map_ref", "enum", "bool"]
		tsel.select(maxi(types.find(str(f.get("type", "string"))), 0))
		tsel.item_selected.connect(func(idx: int):
			f["type"] = types[idx]
			save_manifest.call()
			_asset_field_rows(grid, edef))
		grid.add_child(tsel)
		var ofe := LineEdit.new()
		ofe.text = str(f.get("of", ""))
		ofe.placeholder_text = "实体类型,逗号分隔"
		ofe.custom_minimum_size = Vector2(110, 0)
		ofe.editable = str(f.get("type", "")) == "entity_ref"
		ofe.text_changed.connect(func(t: String): f["of"] = t)
		ofe.text_submitted.connect(func(_t: String): save_manifest.call())
		ofe.focus_exited.connect(func(): save_manifest.call())
		grid.add_child(ofe)
		# enum 选项：逗号分隔，失焦提交（只有 type=enum 时可编辑，其余置灰避免噪音）
		var ope := LineEdit.new()
		var opts_arr: Array = f.get("options", [])
		var opt_texts := PackedStringArray()
		for o in opts_arr:
			opt_texts.append(str(o))
		ope.text = ",".join(opt_texts)
		ope.placeholder_text = "A,B,C"
		ope.custom_minimum_size = Vector2(140, 0)
		ope.editable = str(f.get("type", "")) == "enum"
		ope.tooltip_text = "下拉可选项，逗号分隔；改完在属性面板里就是下拉框"
		ope.text_changed.connect(func(t: String):
			var arr: Array = []
			for part in t.split(",", false):
				var pt := part.strip_edges()
				if pt != "":
					arr.append(pt)
			f["options"] = arr)
		ope.text_submitted.connect(func(_t: String): save_manifest.call())
		ope.focus_exited.connect(func(): save_manifest.call())
		grid.add_child(ope)
		var defe := LineEdit.new()
		defe.text = str(f.get("default", ""))
		defe.custom_minimum_size = Vector2(76, 0)
		defe.text_changed.connect(func(t: String): f["default"] = t)
		defe.text_submitted.connect(func(_t: String): save_manifest.call())
		defe.focus_exited.connect(func(): save_manifest.call())
		grid.add_child(defe)
		var fdel := Kit.button("✕", func():
			(edef.get("fields", []) as Array).erase(f)
			save_manifest.call()
			_asset_field_rows(grid, edef), "icon")
		fdel.tooltip_text = "删除这个字段（地图里已填的值会变成孤立数据）"
		grid.add_child(fdel)

func _stats_by_id(edef: Dictionary) -> Dictionary:
	var out := {}
	for s in edef.get("stats", []):
		out[str(s.get("id", ""))] = s
	return out

## 去重历史遗留的重复 stat id；返回是否有改动
func _dedupe_stat_ids(edef: Dictionary) -> bool:
	var seen := {}
	var changed := false
	var kept := []
	for s in edef.get("stats", []):
		var sid := str(s.get("id", ""))
		if sid == "" or seen.has(sid):
			changed = true
			continue
		seen[sid] = true
		kept.append(s)
	if changed:
		edef["stats"] = kept
	return changed

## 资产缩略图：裁掉透明留白后再用。
## 预览图统一 96×96 画布 + 中间十几像素的图形，不裁的话列表里只剩一个点。
var _tex_cache := {}   # U-06：path→ImageTexture 缓存，同一图只读一次盘
func _asset_texture(edef: Dictionary) -> Texture2D:
	var rel := str(edef.get("thumb", ""))
	if rel == "":
		return null
	var p: String = str(manifest.get("_dir", "")).path_join(rel)
	if not FileAccess.file_exists(p):
		return null
	if _tex_cache.has(p):
		return _tex_cache[p]
	var img := Image.load_from_file(p)
	if img == null:
		return null
	var tex := ImageTexture.create_from_image(EditorManifest.trim_alpha(img))
	_tex_cache[p] = tex
	return tex
