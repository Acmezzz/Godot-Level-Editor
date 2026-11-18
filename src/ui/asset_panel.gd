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

## 快速总表的内容宽度：6 列（图鉴 / 实体 / 生命 / 伤害 / 速度 / 范围）
## 「详情」列已删——实体名按钮本身就是进图鉴的入口，独立「打开」列是重复入口
const QUICK_W := 660.0

var manifest := {}
var save_manifest: Callable
var host = null  # 宿主 app（定位跳转/确认框复用其链路）

var quick_view: VBoxContainer
var detail_view: HBoxContainer
var quick_grid: GridContainer
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
	# 顶栏（标题/项目徽章/返回）已收进项目页外壳 project_shell.gd，这里只做内容区

	# —— 快速总表 ——
	# 内容整体居中：表格在宽屏上贴着左边会显得散，居中后视线落点更稳。
	quick_view = Kit.vbox(0)
	quick_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(quick_view)

	var q_margin := MarginContainer.new()
	q_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	q_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	q_margin.add_theme_constant_override("margin_left", 18)
	q_margin.add_theme_constant_override("margin_right", 18)
	q_margin.add_theme_constant_override("margin_top", 14)
	q_margin.add_theme_constant_override("margin_bottom", 14)
	quick_view.add_child(q_margin)

	var q_col := Kit.vbox(10)
	# 表格宽度：够放 7 列，但不随窗口无限拉宽
	q_col.custom_minimum_size = Vector2(QUICK_W, 0)
	q_col.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	q_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	q_margin.add_child(q_col)

	var q_head := Kit.hbox(8)
	q_head.add_child(Kit.text_label("快速调整", Th.TEXT, Th.FS_MD))
	q_head.add_child(Kit.text_label("常用数值可直接在本表修改，点击实体名进入图鉴", Th.TEXT_MUTE, Th.FS_SMALL))
	q_col.add_child(q_head)

	var quick_scroll := ScrollContainer.new()
	# 宽度由 q_col 的 custom_minimum_size 定；竖直方向吃掉剩余空间
	quick_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	quick_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	quick_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	q_col.add_child(quick_scroll)
	quick_grid = GridContainer.new()
	quick_grid.columns = 6
	quick_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	quick_grid.add_theme_constant_override("h_separation", 10)
	quick_grid.add_theme_constant_override("v_separation", 6)
	quick_scroll.add_child(quick_grid)

	# —— 图鉴详情 ——
	detail_view = Kit.hbox(0)
	detail_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_view.visible = false
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
	left.add_child(Kit.button("←  返回总表", func(): show_quick(), "ghost"))
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
	refresh_quick()

## U-01：名称提交（写盘 + 快速总表那一格刷新）
func _commit_name() -> void:
	if _edef.is_empty() or _loading:
		return
	save_manifest.call()
	refresh_quick()

# —— 视图切换 ——
func show_quick() -> void:
	detail_view.visible = false
	quick_view.visible = true
	refresh_quick()

func show_detail(sid: String) -> void:
	quick_view.visible = false
	detail_view.visible = true
	refresh_list(sid)

# —— 快速总表 ——
func refresh_quick() -> void:
	if quick_grid == null:
		return
	for child in quick_grid.get_children():
		quick_grid.remove_child(child)
		child.queue_free()
	# 表头：带底色 + 小字号，和数据行区分开
	for header in ["图鉴", "实体", "生命", "伤害", "速度", "范围"]:
		var h := Kit.text_label(header, Th.TEXT_MUTE, Th.FS_META)
		h.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		quick_grid.add_child(h)
	# 行高统一：有数值和无数值的行混排时，靠固定高度保持网格节奏
	var row_h := 38.0
	for edef in manifest.get("entities", []):
		var sid := str(edef.get("id", ""))
		# 首格：缩略图 + 名称按钮（合在一起，视线不用横向跳）
		# 宽度交给列头最小宽度统一控制，行内不再自己撑宽，否则会把「详情」列挤出画面
		var entry := Kit.hbox(6)
		entry.custom_minimum_size = Vector2(0, row_h)
		var icon_tex := _asset_texture(edef)
		if icon_tex != null:
			var icon := TextureRect.new()
			icon.texture = icon_tex
			icon.custom_minimum_size = Vector2(30, 30)
			icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			entry.add_child(icon)
		var open := Kit.button(str(edef.get("name", sid)), func(): show_detail(sid), "ghost")
		open.alignment = HORIZONTAL_ALIGNMENT_LEFT
		open.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		entry.add_child(open)
		quick_grid.add_child(entry)
		var idl := Kit.text_label(sid, Th.TEXT_MUTE, Th.FS_META)
		idl.custom_minimum_size = Vector2(0, row_h)
		idl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		quick_grid.add_child(idl)
		# 四个常用数值
		var stats := _stats_by_id(edef)
		for stat_id in ["hp", "damage", "speed", "range"]:
			var stat: Dictionary = stats.get(stat_id, {})
			if stat.is_empty():
				var dash := Kit.text_label("—", Th.TEXT_MUTE, Th.FS_SMALL)
				dash.custom_minimum_size = Vector2(84, row_h)
				dash.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
				quick_grid.add_child(dash)
				continue
			var spin := SpinBox.new()
			spin.custom_minimum_size = Vector2(84, row_h)
			spin.min_value = float(stat.get("min", 0.0))
			spin.max_value = maxf(float(stat.get("max", 999.0)), spin.min_value)
			spin.step = 1.0 if str(stat.get("type", "float")) == "int" else 0.1
			spin.value = clampf(float(stat.get("default", 0.0)), spin.min_value, spin.max_value)
			# U-02：初始显示被钳制就同步回写，数据不再停在越界值上
			stat["default"] = roundi(spin.value) if str(stat.get("type", "float")) == "int" else spin.value
			spin.value_changed.connect(func(value: float):
				stat["default"] = roundi(value) if str(stat.get("type", "float")) == "int" else value
			)
			spin.focus_exited.connect(func():
				save_manifest.call())
			quick_grid.add_child(spin)

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

## 实例分布（模型阶段 1 §5）：每实例一行——id/坐标 + 当前生效数值 + 单实例定位。
## 数值 = 三层合并（实例 > 定义 > 清单），与属性面板/游戏运行时同一算法（DefModel.effective_stats）。
## 数据每次全量读盘（自用规模可接受；批次 10 的 D2 mtime 缓存落地后自动受益）。
func _add_distribution_section(sid: String) -> void:
	extra.add_child(Kit.section_label("实例分布"))
	var dist := _instance_distribution(sid)
	if dist.is_empty():
		extra.add_child(Kit.hint_label("没有已放置实例", 220))
		return
	var total := 0
	for map_name in dist:
		var rows: Array = dist[map_name]
		total += rows.size()
		extra.add_child(Kit.text_label("%s × %d" % [map_name, rows.size()], Th.TEXT, Th.FS_SMALL))
		for r in rows:
			var rid := str(r.get("id", ""))
			var row := Kit.hbox(8)
			var lbl := Kit.text_label("  %s(%d,%d)%s" % [
				rid, int(r.get("x", 0)), int(r.get("y", 0)), _instance_stat_text(r)],
				Th.TEXT_DIM, Th.FS_SMALL)
			lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(lbl)
			row.add_child(Kit.button("定位", func(): host._focus_issue(map_name, rid), "ghost"))
			extra.add_child(row)
	extra.add_child(Kit.hint_label("共 %d 个实例 / %d 张地图" % [total, dist.size()], 220))

## 全项目扫描：{地图名: [{id, x, y, def, props}, ...]}——实例分布、K7 删除检查与实例数值显示共用数据源
func _instance_distribution(sid: String) -> Dictionary:
	var out := {}
	var maps := MapStore.read_all(manifest)
	for map_name in maps:
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
	return out

## 单实例生效数值文本：三层合并（实例 > 定义 > 清单）与属性面板同源；无 stats 模板返回空串
func _instance_stat_text(r: Dictionary) -> String:
	var sdefs: Array = _edef.get("stats", [])
	if (sdefs as Array).is_empty():
		return ""
	var props: Dictionary = r.get("props", {}) if r.get("props", {}) is Dictionary else {}
	var def_res := {}
	var did := str(r.get("def", ""))
	if did != "":
		def_res = ContentStore.read(manifest, "defs", did)
	var eff: Dictionary = DefModel.effective_stats(def_res, _edef, props)
	var parts := []
	for sf in sdefs:
		var sid2 := str(sf.get("id", ""))
		var sname := str(sf.get("name", sid2))
		var v := float(eff.get(sid2, sf.get("default", 0.0)))
		parts.append("%s %s" % [sname, "%d" % int(v) if v == floorf(v) else "%.1f" % v])
	return " · " + " · ".join(parts)

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
	detail_view.visible = false
	quick_view.visible = true
	refresh_quick()

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
