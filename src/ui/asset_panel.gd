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
var host = null  # 宿主 app（确认框复用其链路）

var asset_list: ItemList
var stats_grid: GridContainer
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
	stats_grid.columns = 6
	stats_grid.add_theme_constant_override("h_separation", 8)
	stats_grid.add_theme_constant_override("v_separation", 6)
	det.add_child(stats_grid)

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
	else:
		# 列表空（含「删掉最后一个资产」）：右栏必须走空态，否则名称框/stats/分布/删除按钮
		# 全部滞留上一项，残留闭包还会往已 erase 的字典里写（审查 P1-8）。
		_show_detail("")

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
		# extra 里挂着实例分布与删除按钮，也必须清掉（审查 P1-8 的残留主体）
		for child in extra.get_children():
			extra.remove_child(child)
			child.queue_free()
		_detail_hint.text = "没有匹配的资产"
		_detail_hint.visible = true
		return
	_detail_hint.visible = false
	_loading = true
	name_edit.text = str(_edef.get("name", sid))
	thumb.texture = _asset_texture(_edef)
	_asset_editor_rows(stats_grid, _edef)
	for child in extra.get_children():
		extra.remove_child(child)
		child.queue_free()
	_add_distribution_section(sid)
	var del := Kit.button("删除此资产", func(): _delete_asset_checked(sid), "ghost")
	del.add_theme_color_override("font_color", Th.ERR)
	del.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	extra.add_child(del)
	_loading = false

## 实例分布（模型阶段 1 §5 + v2 §4）：每实例一行——id/坐标 + 各数值就地可改。
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
		total += (dist[map_name] as Array).size()
		# P2-11：行数 = 实例数 × 数值项数，满项目扫下来能上千个 SpinBox。
		# 按地图折叠，默认收起，展开时才建行（懒构建）。
		_dist_rows.add_child(_dist_map_section(str(map_name), dist[map_name], sdefs))
	var foot := "共 %d 个实例 / %d 张地图" % [total, dist.size()]
	if has_stats:
		foot += "　·　改数值 = 只改这个实例，不影响同类型其它实例"
	_dist_rows.add_child(Kit.hint_label(foot, 460))

## 单张地图的折叠段：标题按钮切换，首展时才构建行（P2-11）。
func _dist_map_section(map_name: String, rows: Array, sdefs: Array) -> Control:
	var wrap := Kit.vbox(2)
	var built := {"done": false}
	var body := Kit.vbox(2)
	body.visible = false
	var head := Kit.button(_dist_head_text(map_name, rows.size(), false), Callable(), "ghost")
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	head.pressed.connect(func():
		if not built.done:
			built.done = true
			for r in rows:
				body.add_child(_dist_row(map_name, r, sdefs))
		body.visible = not body.visible
		head.text = _dist_head_text(map_name, rows.size(), body.visible))
	wrap.add_child(head)
	wrap.add_child(body)
	return wrap

func _dist_head_text(map_name: String, n: int, open: bool) -> String:
	return ("▾ " if open else "▸ ") + "%s × %d" % [map_name, n]

## 全项目扫描：{地图名: [{id, x, y, def, props}, ...]}——实例分布、K7 删除检查与实例数值显示共用数据源
## 当前打开的地图以画布内存为底（P1-4）：磁盘底册+内存补丁的混合体会让新增未保存的实例
## 不出现、已删除的还留着。所以当前图直接用实体树生成，其余图读磁盘。
func _instance_distribution(sid: String) -> Dictionary:
	var out := {}
	var maps := MapStore.read_all(manifest)
	var live_rows: Array = []
	var canvas_ok: bool = host != null and host.canvas != null and is_instance_valid(host.canvas) and host.canvas.entities != null
	if canvas_ok:
		for e in host.canvas.entities.get_children():
			var spr := e as Sprite2D
			if spr == null or not spr.has_meta("scene") or str(spr.get_meta("scene", "")) != sid:
				continue
			var c: Vector2i = host.canvas._cell_of(spr.position)
			var lprops = spr.get_meta("props", {})
			live_rows.append({
				"id": str(spr.get_meta("ent_id", "")),
				"x": c.x,
				"y": c.y,
				"def": str(spr.get_meta("def_id", "")),
				"props": lprops if lprops is Dictionary else {},
			})
	for map_name in maps:
		var is_cur: bool = host != null and map_name == str(host.cur_map_name)
		if is_cur:
			# 当前图：磁盘内容完全不参与（画布才是真相）
			if not live_rows.is_empty():
				out[map_name] = live_rows
			continue
		var data: Dictionary = maps[map_name]
		var rows: Array = []
		for ent in data.get("entities", []):
			if not (ent is Dictionary) or str(ent.get("scene", "")) != sid:
				continue
			var props = ent.get("props", {})
			rows.append({
				"id": str(ent.get("id", "")),
				"x": int(ent.get("x", 0)),
				"y": int(ent.get("y", 0)),
				"def": str(ent.get("def", "")),
				"props": props if props is Dictionary else {},
			})
		if not rows.is_empty():
			out[map_name] = rows
	# 当前图尚未落盘（新建未保存）：read_all 里没有它，也要把画布实例列出来
	if canvas_ok and not live_rows.is_empty() and not out.has(str(host.cur_map_name)):
		out[str(host.cur_map_name)] = live_rows
	return out

## 分布行：id · 各数值就地可改。数值框直接写该实例的 props.stats 覆盖。
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
			var v_min := float(sf.get("min", 0.0))
			var v_max := float(sf.get("max", 999.0))
			var eff_v := float(eff.get(stat_id, sf.get("default", 0.0)))
			# P3-8：有效值超出声明的 min/max 时（实例覆盖或类型模板给了越界值），SpinBox 会
			# 静默夹到边界显示，用户一微调就把夹过的值写回去。把范围撑到能包住它。
			v_min = minf(v_min, eff_v)
			v_max = maxf(v_max, eff_v)
			box.min_value = v_min
			box.max_value = v_max
			box.step = 0.1 if str(sf.get("type", "float")) == "float" else 1.0
			box.value = eff_v
			box.custom_minimum_size = Vector2(64, 0)
			box.tooltip_text = "只改「%s」这个实例；%s" % [rid,
				"已覆盖类型模板" if ov.has(stat_id) else "当前继承类型模板，改动即覆盖"]
			# 撤销合并：连续调同一个框只压一次撤销（和属性面板同一约定）
			var session := {"started": false}
			box.get_line_edit().focus_exited.connect(func(): session.started = false)
			# P1-7：连续控件不在每 tick 落盘。拖值期间只改内存/画布，失焦或回车上提交；
			# 否则非当前图的每次增量都要全量读改写，还会把 3 层 .history 备份挤满。
			var pending := {"v": box.value}
			box.value_changed.connect(func(v: float):
				pending.v = v
				if not session.started:
					session.started = true
					if host != null and map_name == str(host.cur_map_name) and host.canvas != null and host.canvas.entities != null:
						host.canvas._push_undo()
				if host != null and map_name == str(host.cur_map_name):
					_set_instance_stat(map_name, rid, stat_id, v)
				box.tooltip_text = "只改「%s」这个实例；已覆盖类型模板" % rid)
			var commit := func(_t := ""):
				_set_instance_stat(map_name, rid, stat_id, pending.v)
			box.get_line_edit().text_submitted.connect(commit)
			box.get_line_edit().focus_exited.connect(commit)
			# 点上下箭头不会让 LineEdit 获得焦点，focus_exited 等不到——按鼠标松开兜底提交
			box.gui_input.connect(func(ev: InputEvent):
				if ev is InputEventMouseButton and not (ev as InputEventMouseButton).pressed:
					commit.call())
			cell.add_child(box)
			cells.add_child(cell)
		row.add_child(Kit.spacer())

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
	for h in ["名称", "id", "类型", "默认", "最小", "最大"]:
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
