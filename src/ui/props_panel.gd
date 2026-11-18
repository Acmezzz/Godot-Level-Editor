extends RefCounted
## 实体属性面板控制器：字段编辑、entity_ref 门/出口配对、批量编辑、
## 对齐分布、碰撞生成。状态全部经宿主（app.gd）访问，本类不持有副本。
const UiKitScript := preload("res://src/ui/ui_kit.gd")
const UiThemeScript := preload("res://src/ui/ui_theme.gd")
const ManifestScript := preload("res://src/manifest.gd")

var app   # 宿主引用

func _init(host) -> void:
	app = host

# —— 实体属性面板 + 批量编辑 + 对齐分布 + 碰撞生成（审查 8.2 块 7：从 app.gd 拆出） ——
# —— 批量编辑：把一组数值/字段统一写到「选中里同类型的实体」 ——
func open_bulk_edit(sid: String, edef: Dictionary) -> void:
	var same := []
	for s in app.canvas.selected_multi:
		if is_instance_valid(s) and str((s as Sprite2D).get_meta("scene", "")) == sid:
			same.append(s)
	if same.size() < 2:
		app._set_status("选中里同类型（%s）的实体不足 2 个" % str(edef.get("name", sid)))
		return
	var shell: Dictionary = app._popup_body("批量编辑 %s × %d" % [str(edef.get("name", sid)), same.size()],
		"只影响选中里同类型的实体；勾选哪项才改哪项，未勾选的不动。")
	var pop: PopupPanel = shell.pop
	var vb: VBoxContainer = shell.body
	# T6（批次 12）：批量挂/摘定义——"(不修改)"=跳过；"(摘除定义)"=清 def_id；其余=挂该 def
	var def_opt := OptionButton.new()
	def_opt.add_item("(定义不修改)")
	def_opt.add_item("(摘除定义)")
	var def_ids_t6: Array = preload("res://src/content/content_store.gd").list_ids(app.manifest, "defs")
	for did in def_ids_t6:
		def_opt.add_item(str(did))
	vb.add_child(UiKitScript.field_row("定义", def_opt, UiKitScript.LABEL_W_LONG))
	# 勾选后才写，避免「没动过的字段」被覆盖
	var stat_boxes := {}   # stat_id → [SpinBox, CheckBox]
	var stats_defs: Array = edef.get("stats", [])
	if not stats_defs.is_empty():
		vb.add_child(UiKitScript.section_label("数值（勾选后统一覆盖）"))
		for sf in stats_defs:
			var stat_id := str(sf.get("id", ""))
			var row := UiKitScript.hbox(6)
			var chk := CheckBox.new()
			chk.text = str(sf.get("name", stat_id))
			chk.custom_minimum_size = Vector2(140, 0)
			row.add_child(chk)
			var spin := SpinBox.new()
			spin.min_value = float(sf.get("min", 0.0))
			spin.max_value = float(sf.get("max", 999.0))
			spin.step = 1.0 if str(sf.get("type", "float")) == "int" else 0.1
			spin.value = float(sf.get("default", 0.0))
			spin.editable = false
			spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			chk.toggled.connect(func(on: bool): spin.editable = on)
			row.add_child(spin)
			vb.add_child(row)
			stat_boxes[stat_id] = [spin, chk]
	# 普通 string 字段（引用字段不批量改，避免配对关系被破坏）
	var field_boxes := {}
	var has_string_field := false
	for f in edef.get("fields", []):
		var fid := str(f.get("id", ""))
		var ftype := str(f.get("type", "string"))
		if ftype != "string":
			continue
		has_string_field = true
		var row2 := UiKitScript.hbox(6)
		var chk2 := CheckBox.new()
		chk2.text = str(f.get("name", fid))
		chk2.custom_minimum_size = Vector2(140, 0)
		row2.add_child(chk2)
		var le := LineEdit.new()
		le.placeholder_text = "批量设置此字段"
		le.editable = false
		le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		chk2.toggled.connect(func(on: bool): le.editable = on)
		row2.add_child(le)
		vb.add_child(row2)
		field_boxes[fid] = [le, chk2]
	if has_string_field:
		vb.add_child(UiKitScript.hint_label("普通字段留空表示清空该字段的值", app.POPUP_BODY_W))
	vb.add_child(UiKitScript.hint_label("enum / bool / 引用字段不支持批量改，请逐个实体编辑。", app.POPUP_BODY_W))
	var ok := UiKitScript.button("应用到选中的同类实体", func():
		var stat_set := {}
		for stat_id in stat_boxes:
			var pair: Array = stat_boxes[stat_id]
			if (pair[1] as CheckBox).button_pressed:
				stat_set[stat_id] = (pair[0] as SpinBox).value
		var props_set := {}
		for fid in field_boxes:
			var pair2: Array = field_boxes[fid]
			if (pair2[1] as CheckBox).button_pressed:
				props_set[fid] = (pair2[0] as LineEdit).text
		var n: int = 0
		var def_sel := def_opt.selected
		if stat_set.is_empty() and props_set.is_empty() and def_sel <= 0:
			app._set_status("没有勾选任何要批量修改的项")
			return
		if def_sel > 0:
			n += app.canvas.bulk_set_def(sid, "" if def_sel == 1 else str(def_ids_t6[def_sel - 2]))
		if not stat_set.is_empty() or not props_set.is_empty():
			n += app.canvas.bulk_update(sid, stat_set, [], props_set)
		pop.hide()
		if n > 0:
			app._set_status("已批量修改 %d 个 %s（Ctrl+Z 撤销）" % [n, str(edef.get("name", sid))])
		rebuild(), "primary")
	vb.add_child(ok)
	# 取消出口：什么都不改直接关（勾选框留着的状态随弹窗丢弃）
	var cancel := UiKitScript.button("取消", func(): pop.hide(), "ghost")
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_child(cancel)
	app._open_popup(pop)

# —— 对齐/分布面板（画布 selected_multi 上操作） ——
func open_align_menu() -> void:
	if app.canvas.selected_multi.size() < 2:
		app._set_status("先框选至少 2 个实体再做对齐 / 分布")
		return
	var shell: Dictionary = app._popup_body("对齐与分布", "作用于已框选的 %d 个实体，结果吸附格点。" % app.canvas.selected_multi.size())
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	body.add_child(UiKitScript.section_label("对齐"))
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	body.add_child(grid)
	var align_actions := [
		["左对齐", "left"], ["水平居中", "center_h"], ["右对齐", "right"],
		["顶对齐", "top"], ["垂直居中", "center_v"], ["底对齐", "bottom"],
	]
	for a in align_actions:
		var mode := str(a[1])
		var b := UiKitScript.button(str(a[0]), func():
			app.canvas.align_selection(mode)
			pop.hide(), "plain")
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(b)
	body.add_child(UiKitScript.divider())
	body.add_child(UiKitScript.section_label("等距分布"))
	var grid2 := GridContainer.new()
	grid2.columns = 2
	grid2.add_theme_constant_override("h_separation", 6)
	grid2.add_theme_constant_override("v_separation", 6)
	body.add_child(grid2)
	for a in [["水平等距", "dist_h"], ["垂直等距", "dist_v"]]:
		var mode2 := str(a[1])
		var b2 := UiKitScript.button(str(a[0]), func():
			app.canvas.align_selection(mode2)
			pop.hide(), "plain")
		b2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid2.add_child(b2)
	body.add_child(UiKitScript.divider())
	var close_row := UiKitScript.hbox(6)
	close_row.add_child(UiKitScript.spacer())
	close_row.add_child(UiKitScript.button("关闭", func(): pop.hide(), "ghost"))
	body.add_child(close_row)
	app._open_popup(pop)

# —— 自动生成碰撞面板（辅助功能；手动摆放仍是首选） ——
func open_collision_gen() -> void:
	if not app.map_loaded:
		app._set_status("无地图：先新建或打开一张地图")
		return
	var shell: Dictionary = app._popup_body("从地形生成碰撞", "只写碰撞层，不改地形；整体算一个撤销步。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var strat := OptionButton.new()
	strat.add_item("全部地形格（整块实心）")
	strat.add_item("仅顶部表面（可站立平台）")
	strat.add_item("仅外轮廓（贴边一圈）")
	body.add_child(UiKitScript.field_row("策略", strat, UiKitScript.LABEL_W))
	var replace_cb := CheckBox.new()
	replace_cb.text = "先清空现有碰撞再生成"
	replace_cb.button_pressed = false
	body.add_child(replace_cb)
	var one_way_cb := CheckBox.new()
	one_way_cb.text = "只碰顶面（one-way：可从下方跳穿）"
	one_way_cb.button_pressed = false
	body.add_child(one_way_cb)
	var preview := UiKitScript.wrap_label("", app.POPUP_BODY_W, UiThemeScript.ACCENT_HI)
	body.add_child(preview)
	var refresh_preview := func():
		var n: int = app.canvas.count_auto_collision(_collision_strategy(strat.selected), replace_cb.button_pressed)
		if n == 0 and not replace_cb.button_pressed:
			# 已有碰撞覆盖了全部候选格：说清为什么是 0，而不是让人以为功能坏了
			preview.text = "这些格子已经有碰撞了；要重算请勾选「先清空现有碰撞」"
			preview.add_theme_color_override("font_color", UiThemeScript.TEXT_MUTE)
		else:
			preview.text = "将写入 %d 格碰撞" % n
			preview.add_theme_color_override("font_color", UiThemeScript.ACCENT_HI)
	strat.item_selected.connect(func(_i: int): refresh_preview.call())
	replace_cb.toggled.connect(func(_on: bool): refresh_preview.call())
	refresh_preview.call()
	var btn_row := UiKitScript.hbox(8)
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	var gen_cb := func():
		var n: int = app.canvas.generate_collision(_collision_strategy(strat.selected), replace_cb.button_pressed, one_way_cb.button_pressed)
		pop.hide()
		app._set_status("已生成 %d 格碰撞（Ctrl+Z 撤销）" % n)
		app._refresh_entity_outline()
	btn_row.add_child(UiKitScript.button("取消", func(): pop.hide(), "ghost"))
	btn_row.add_child(UiKitScript.button("生成", gen_cb, "primary"))
	body.add_child(btn_row)
	app._open_popup(pop)

func _collision_strategy(idx: int) -> String:
	match idx:
		1: return "top"
		2: return "outline"
		_: return "full"

func on_entity_selected(spr: Sprite2D) -> void:
	app.selected_spr = spr
	rebuild()

## 定义层区块：选定义并展示可组合的组件入口。
## 定义来自游戏工程 content/defs；没写定义时保留旧的"只按种类编辑"体验。
func _add_definition_section(sid: String) -> void:
	var ContentStore := preload("res://src/content/content_store.gd")
	var DefModel := preload("res://src/content/def_model.gd")
	var def_ids: Array = ContentStore.list_ids(app.manifest, "defs")
	var cur_def := str(app.selected_spr.get_meta("def_id", ""))
	app.props_panel.add_child(UiKitScript.divider())
	app.props_panel.add_child(UiKitScript.section_label("定义"))
	var opt := OptionButton.new()
	opt.add_item("(不使用定义)")
	var ids: Array = [""]
	for def_id in def_ids:
		var definition: Dictionary = ContentStore.read(app.manifest, "defs", str(def_id))
		# 只列与当前实体种类一致的定义，避免把 NPC 定义挂到敌人上
		if not definition.is_empty() and str(definition.get("kind", "")) != sid:
			continue
		ids.append(str(def_id))
		opt.add_item("%s · %s" % [str(def_id), str(definition.get("name", def_id))])
	var sel := ids.find(cur_def)
	opt.select(maxi(sel, 0))
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.item_selected.connect(func(idx: int):
		var next_def := str(ids[idx])
		if next_def == cur_def:
			return
		app.canvas._push_undo()
		if next_def == "":
			app.selected_spr.remove_meta("def_id")
		else:
			app.selected_spr.set_meta("def_id", next_def)
		app.canvas._mark()
		rebuild())
	app.props_panel.add_child(UiKitScript.field_row("使用定义", opt, UiKitScript.LABEL_W_LONG))
	var dock_row := UiKitScript.hbox(6)
	if cur_def == "":
		# 实例为主：还没有内容组时，直接从实体这里建一个，不必先去内容库
		var create_btn := UiKitScript.button("+ 为此实体创建内容组",
			func(): app._create_def_for_selected(sid), "primary")
		create_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		dock_row.add_child(create_btn)
	else:
		var open_btn := UiKitScript.button("编辑内容（对话/事件/商店）",
			# 批次 C：内容抽屉已删，落到内容编辑器并按实例定位（focus = 实例 id）
			func(): app._set_mode("content", str(app.selected_spr.get_meta("ent_id", ""))), "primary")
		open_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		dock_row.add_child(open_btn)
	app.props_panel.add_child(dock_row)
	if cur_def == "":
		app.props_panel.add_child(UiKitScript.hint_label(
			"内容组挂在实体上；创建后仍在 content/defs 里，可被别的实体共用", 250))
		return

	var definition: Dictionary = ContentStore.read(app.manifest, "defs", cur_def)
	if definition.is_empty():
		app.props_panel.add_child(UiKitScript.hint_label("定义文件缺失: " + cur_def, 250))
		return
	var comps: Dictionary = DefModel.references(definition, app.manifest)
	if comps.is_empty():
		app.props_panel.add_child(UiKitScript.hint_label("该定义没有配置组件", 250))
		return
	var row := UiKitScript.hbox(6)
	for comp_name in comps:
		var entries: Array = comps[comp_name]
		var ref_ids: Array = []
		for entry in entries:
			var ref_id := str((entry as Dictionary).get("id", ""))
			if ref_id != "":
				ref_ids.append(ref_id)
		if ref_ids.is_empty():
			continue
		# 多条时显示"首条 +n"，让人知道还有更多段落
		var shown := str(ref_ids[0]) + ("  +%d" % (ref_ids.size() - 1) if ref_ids.size() > 1 else "")
		var label := "%s：%s" % [_component_name(str(comp_name)), shown]
		var badge := UiKitScript.badge(label, UiThemeScript.ACCENT_HI)
		badge.tooltip_text = "内容种类 %s\n%s" % [str((entries[0] as Dictionary).get("kind", "")),
			"\n".join(ref_ids)]
		row.add_child(badge)
	app.props_panel.add_child(row)

## 触发区属性：尺寸（格）/ 触发方式 / 绑定事件 / 只触发一次 / 前置 flag。
## 改尺寸后要把精灵位置按矩形中心重算，否则矩形会以左上角为锚点偏移。
func _add_trigger_section() -> void:
	var props: Dictionary = app.selected_spr.get_meta("props", {})
	app.props_panel.add_child(UiKitScript.divider())
	app.props_panel.add_child(UiKitScript.section_label("触发区"))

	# 尺寸走 field_row：左标签与其它字段同宽对齐，单位「格」写在中间，两个 SpinBox 平分
	var w_spin := SpinBox.new()
	w_spin.min_value = 1
	w_spin.max_value = 64
	w_spin.value = int(props.get("w", 2))
	w_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	w_spin.tooltip_text = "触发区宽（格）。改尺寸后精灵按新矩形中心重算，左上角格坐标不变"
	var h_spin := SpinBox.new()
	h_spin.min_value = 1
	h_spin.max_value = 64
	h_spin.value = int(props.get("h", 2))
	h_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h_spin.tooltip_text = "触发区高（格）"
	var size_row := UiKitScript.hbox(6)
	size_row.add_child(w_spin)
	var times := UiKitScript.text_label("×", UiThemeScript.TEXT_MUTE, UiThemeScript.FS_SMALL)
	times.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	size_row.add_child(times)
	size_row.add_child(h_spin)
	var u := UiKitScript.text_label("格", UiThemeScript.TEXT_MUTE, UiThemeScript.FS_META)
	u.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	size_row.add_child(u)
	app.props_panel.add_child(UiKitScript.field_row("尺寸", size_row, UiKitScript.LABEL_W))
	# B1：尺寸调整可撤销——edit_session 模式（首次 value_changed 推快照，会话内不重复推）
	var size_session := {"started": false}
	var commit_size := func(_v: float) -> void:
		if not size_session.started:
			app.canvas._push_undo()
			size_session.started = true
		_set_trigger_size(int(w_spin.value), int(h_spin.value))
	w_spin.value_changed.connect(commit_size)
	h_spin.value_changed.connect(commit_size)
	w_spin.get_line_edit().focus_exited.connect(func(): size_session.started = false)
	h_spin.get_line_edit().focus_exited.connect(func(): size_session.started = false)

	var mode_opt := OptionButton.new()
	var modes: Array = ["enter", "interact", "auto"]
	var mode_labels := {"enter": "进入时", "interact": "按互动键", "auto": "持续判定"}
	for m in modes:
		mode_opt.add_item(str(mode_labels.get(m, m)))
	var cur_mode := str(props.get("mode", "enter"))
	mode_opt.select(maxi(modes.find(cur_mode), 0))
	mode_opt.item_selected.connect(func(idx: int):
		app.canvas._push_undo()
		_set_trigger_prop("mode", str(modes[idx])))
	app.props_panel.add_child(UiKitScript.field_row("触发方式", mode_opt, UiKitScript.LABEL_W))

	app.props_panel.add_child(_trigger_event_row(str(props.get("event", ""))))

	var once := CheckBox.new()
	once.text = "只触发一次"
	once.button_pressed = bool(props.get("once", false))
	once.toggled.connect(func(on: bool):
		app.canvas._push_undo()
		_set_trigger_prop("once", on))
	app.props_panel.add_child(once)

	var flag_edit := LineEdit.new()
	flag_edit.text = str(props.get("require_flag", ""))
	flag_edit.placeholder_text = "可选：flag 为 false 时不触发"
	flag_edit.focus_exited.connect(func():
		app.canvas._push_undo()
		_set_trigger_prop("require_flag", flag_edit.text.strip_edges()))
	app.props_panel.add_child(UiKitScript.field_row("前置 flag", flag_edit, UiKitScript.LABEL_W))

## 事件下拉：从游戏工程 content/events 读；没有事件时提示去内容库建
func _trigger_event_row(current: String) -> Control:
	var ContentStore := preload("res://src/content/content_store.gd")
	var ids: Array = ContentStore.list_ids(app.manifest, "events")
	if ids.is_empty():
		var hint := UiKitScript.hbox(6)
		hint.add_child(UiKitScript.hint_label("还没有事件资源", 150))
		hint.add_child(UiKitScript.button("去内容库…", func(): app._set_mode("content", ""), "ghost"))
		return hint
	var opt := OptionButton.new()
	var values: Array = [""]
	opt.add_item("(未绑定)")
	for event_id in ids:
		values.append(str(event_id))
		opt.add_item(str(event_id))
	opt.select(values.find(current) if values.has(current) else 0)
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.item_selected.connect(func(idx: int):
		app.canvas._push_undo()
		_set_trigger_prop("event", str(values[idx])))
	return UiKitScript.field_row("绑定事件", opt, UiKitScript.LABEL_W)

func _set_trigger_prop(key: String, value) -> void:
	var props: Dictionary = app.selected_spr.get_meta("props", {})
	if value is String and str(value) == "":
		props.erase(key)
	else:
		props[key] = value
	app.selected_spr.set_meta("props", props)
	app.canvas._mark()
	rebuild()

## 改矩形尺寸：数据改 w/h，精灵位置按新的矩形中心重算，保证左上角格坐标不变
func _set_trigger_size(w: int, h: int) -> void:
	var props: Dictionary = app.selected_spr.get_meta("props", {})
	var old_origin: Vector2 = app.canvas.trigger_zone_origin(app.selected_spr)
	props["w"] = maxi(w, 1)
	props["h"] = maxi(h, 1)
	app.selected_spr.set_meta("props", props)
	var new_size: Vector2 = app.canvas.trigger_zone_size(props)
	app.selected_spr.position = old_origin + new_size * 0.5
	app.canvas._mark()
	rebuild()

static func _component_name(comp: String) -> String:
	match comp:
		"dialogue": return "对话"
		"shop": return "商店"
		"interact_event": return "互动事件"
		"enemy_profile": return "敌人配置"
		_: return comp

func rebuild() -> void:
	for c in app.props_panel.get_children():
		app.props_panel.remove_child(c)
		c.queue_free()
	# 换选中实体后滚回顶部，否则会停在上一个实体的滚动位置
	if app.props_scroll:
		app.props_scroll.scroll_vertical = 0
	if app.selected_spr == null or not is_instance_valid(app.selected_spr):
		# 未选中时给引导，而不是留一片空面板
		app.props_panel.add_child(UiKitScript.empty_state("◇", "未选中实体",
			"用「属性」工具点击画布上的实体查看与编辑属性"))
		return
	var sid := str(app.selected_spr.get_meta("scene", ""))
	var edef := {}
	for e in app.manifest.get("entities", []):
		if str(e.get("id", "")) == sid:
			edef = e
			break
	var props: Dictionary = app.selected_spr.get_meta("props", {})

	# 头部：名称做主标题，id 做弱化副标题
	var head := UiKitScript.vbox(2)
	var title_row := UiKitScript.hbox(6)
	title_row.add_child(UiKitScript.text_label(str(edef.get("name", sid)), UiThemeScript.TEXT, UiThemeScript.FS_MD))
	title_row.add_child(UiKitScript.badge(str(app.selected_spr.get_meta("ent_id", "")), UiThemeScript.TEXT_MUTE))
	head.add_child(title_row)
	if app.canvas.selected_multi.size() > 1:
		head.add_child(UiKitScript.text_label("已框选 %d 个实体" % app.canvas.selected_multi.size(),
			UiThemeScript.ACCENT_HI, UiThemeScript.FS_META))
	app.props_panel.add_child(head)

	# 操作入口：多选时批量编辑，单类型时进资产模板
	var ops := UiKitScript.hbox(6)
	if app.canvas.selected_multi.size() > 1:
		var bulk := UiKitScript.button("批量编辑…", func(): open_bulk_edit(sid, edef), "plain")
		bulk.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ops.add_child(bulk)
	var ed_btn := UiKitScript.button("编辑资产模板", func(): app._open_asset_editor(sid), "ghost")
	ed_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ops.add_child(ed_btn)
	# 左右翻转（数据 flip_h；游戏侧应用到实体精灵）
	var flip_btn := UiKitScript.button("翻转", func(): app.canvas.flip_selected(), "plain")
	flip_btn.tooltip_text = "水平翻转选中实体（数据 flip_h，游戏侧应用到精灵；可撤销）"
	ops.add_child(flip_btn)
	app.props_panel.add_child(ops)

	# 多选：字段区只反映主选中项——改动只作用于它，置灰避免误以为批量生效
	var multi: bool = app.canvas.selected_multi.size() > 1
	var dim_from: int = app.props_panel.get_child_count()

	# 定义层：选游戏工程 content/defs 里的具体配置；组件入口由定义提供
	_add_definition_section(sid)

	# 触发区：尺寸/方式/事件都是实例级属性，单独一块，不塞进通用字段区
	if sid == "trigger_zone":
		_add_trigger_section()

	# 落点专属：一键从该点试玩（游戏侧 main.gd 接受 --spawnx/--spawny，格坐标；role 识别）
	if ManifestScript.has_role(app.manifest, sid, "landing"):
		var tsz := int(app.manifest.get("tileSize", 16))
		var cpos := (app.selected_spr as Sprite2D).position
		var ptiles := Vector2i(int(floor(cpos.x / tsz)), int(floor(cpos.y / tsz)))
		var play_row := UiKitScript.hbox(6)
		var pb := UiKitScript.button("▶ 从此处试玩", func(): app._on_play(ptiles), "primary")
		pb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		play_row.add_child(pb)
		app.props_panel.add_child(play_row)

	# 字段区（有字段才显示标题，避免空标题）
	if not (edef.get("fields", []) as Array).is_empty():
		app.props_panel.add_child(UiKitScript.divider())
		app.props_panel.add_child(UiKitScript.section_label("引用与字段"))
	if multi:
		app.props_panel.add_child(UiKitScript.hint_label(
			"多选：下方字段只显示主选中项（改动只作用于它）。批量改数值用上方「批量编辑…」。", 250))
	for f in edef.get("fields", []):
		var fid := str(f.get("id", ""))
		var fname := str(f.get("name", fid))
		var ftype := str(f.get("type", "string"))
		if ftype == "entity_ref" and ManifestScript.has_role(app.manifest, sid, "portal") and str(props.get("target_map", "")) != "":
			app.props_panel.add_child(UiKitScript.hint_label(
				"跨图落点：%s（用上方「在图上选落点…」修改）" % str(props.get(fid, "(未设置)")), 250))
		elif ftype == "entity_ref":
			# 目标选择器：PopupPanel + ItemList（悬停实时高亮画布目标 + 门门配对互斥）
			var cur := str(props.get(fid, ""))
			var my_id := str(app.selected_spr.get_meta("ent_id", ""))
			var dd := UiKitScript.button(cur if cur != "" else "(未设置)", Callable(), "plain")
			dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			dd.tooltip_text = "选择%s的目标" % fname
			app.props_panel.add_child(UiKitScript.field_row(fname, dd, UiKitScript.LABEL_W_LONG))
			var pop := PopupPanel.new()
			var list := ItemList.new()
			list.custom_minimum_size = Vector2(280, 210)
			pop.add_child(list)
			var ids: Array = []
			list.add_item("(未设置)")
			ids.append("")
			for other in app.canvas.entities.get_children():
				var ospr := other as Sprite2D
				if ospr == null or ospr == app.selected_spr:
					continue
				var ofs: PackedStringArray = str(f.get("of", sid)).split(",")
				if not ofs.has(str(ospr.get_meta("scene", ""))):
					continue
				var oid := str(ospr.get_meta("ent_id", ""))
				# 候选名 = 实体的显示名（按 scene id 查清单）；E6（批次 12）：回退名用候选实体自己的 scene，不用当前实体的
				var oname := str(ospr.get_meta("scene", ""))
				for ed in app.manifest.get("entities", []):
					if str(ed.get("id", "")) == str(ospr.get_meta("scene", "")):
						oname = str(ed.get("name", oname))
						break
				# 门→门候选：已被别的门配对的标记并禁选（保证一对一双向）
				var paired := false
				if ManifestScript.has_role(app.manifest, sid, "portal") and ManifestScript.has_role(app.manifest, str(ospr.get_meta("scene", "")), "portal"):
					var ot := str(ospr.get_meta("props", {}).get(fid, ""))
					var ot_spr: Sprite2D = app._ent_by_id(ot) if ot != "" else null
					paired = ot_spr != null and ManifestScript.has_role(app.manifest, str(ot_spr.get_meta("scene", "")), "portal") and ot != my_id
				var oc: Vector2i = app.canvas._cell_of(ospr.position)   # P-20：不硬编码 8/16px，跟清单 tileSize 走
				var it := list.add_item("%s · %s(%d,%d)%s" % [oid, oname,
					oc.x, oc.y,
					" [已配对]" if paired else ""])
				ids.append(oid)
				if paired:
					list.set_item_disabled(it, true)
			var sel := ids.find(cur)
			if sel >= 1:
				list.select(sel)
			dd.pressed.connect(func():
				if cur != "":
					app.canvas.flash_entity(cur)
				app._hover_list = list
				app._hover_ids = ids
				# 弹窗挂在窗口根下，用控件全局矩形定位后夹回可视区内
				var at := dd.get_global_rect().position + Vector2(0, dd.size.y + 4)
				var vp: Vector2 = app.get_viewport_rect().size
				at.x = clampf(at.x, 0.0, maxf(vp.x - list.custom_minimum_size.x, 0.0))
				at.y = clampf(at.y, 0.0, maxf(vp.y - list.custom_minimum_size.y, 0.0))
				pop.position = Vector2i(at)
				pop.popup())
			list.item_clicked.connect(func(idx: int, _at: Vector2, _mb: int):
				var new_id := str(ids[idx])
				var old_id := str(props.get(fid, ""))
				if old_id != new_id:
					app.canvas._push_undo()
				if old_id != "" and old_id != new_id:
					var old_spr: Sprite2D = app._ent_by_id(old_id)
					if old_spr and ManifestScript.has_role(app.manifest, str(old_spr.get_meta("scene", "")), "portal"):
						var oldp: Dictionary = old_spr.get_meta("props", {})
						if str(oldp.get(fid, "")) == my_id:
							oldp.erase(fid)
							old_spr.set_meta("props", oldp)
				if new_id == "":
					props.erase(fid)
				else:
					var tgt: Sprite2D = app._ent_by_id(new_id)
					if tgt and ManifestScript.has_role(app.manifest, str(tgt.get_meta("scene", "")), "portal"):
						var tp: Dictionary = tgt.get_meta("props", {})
						var displaced_id := str(tp.get(fid, ""))
						if displaced_id != "" and displaced_id != my_id:
							var displaced: Sprite2D = app._ent_by_id(displaced_id)
							if displaced and ManifestScript.has_role(app.manifest, str(displaced.get_meta("scene", "")), "portal"):
								var dp: Dictionary = displaced.get_meta("props", {})
								if str(dp.get(fid, "")) == new_id:
									dp.erase(fid)
									displaced.set_meta("props", dp)
						props[fid] = new_id
						tp[fid] = my_id
						tgt.set_meta("props", tp)
					else:
						props[fid] = new_id
					app.canvas.flash_entity(new_id)
				app.selected_spr.set_meta("props", props)
				app.canvas._mark()
				app._hover_list = null
				pop.hide()
				rebuild())
			list.mouse_exited.connect(func(): app.canvas.flash_id = "")
			pop.popup_hide.connect(func():
				if app._hover_list == list:
					app._hover_list = null
				# BUG-07：隐藏即释放，避免每次重建属性面板都泄漏一个 PopupPanel。
				# 释放后 dd 的再次点击由重建面板兜住（面板重建会连带重建 dd/pop）。
				pop.queue_free()
				rebuild())
			# 弹窗挂到窗口根，避免嵌在滚动容器里影响布局与定位
			app.add_child(pop)
		elif ftype == "map_ref":
			# 目标地图下拉：列出 maps 目录全部地图
			var md := OptionButton.new()
			md.add_item("(未设置)")
			var maps: Array = [""]
			var d := DirAccess.open(str(app.manifest.get("_maps_dir", "")))
			if d:
				for f2 in d.get_files():
					if f2.ends_with(".json") and not f2.ends_with(".autosave.json"):
						# 排除当前图：跨图出口指向自己没有意义（图内传送用传送门）
						if f2.get_basename() == str(app.canvas.cur_map_name):
							continue
						maps.append(f2.get_basename())
						md.add_item(f2.get_basename())
			var sel2 := maps.find(str(props.get(fid, "")))
			md.select(maxi(sel2, 0))
			md.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			md.item_selected.connect(func(idx: int):
				var previous_map := str(props.get(fid, ""))
				var next_map := str(maps[idx])
				if previous_map != next_map:
					app.canvas._push_undo()
					var old_point := str(props.get("target_point", ""))
					if ManifestScript.has_role(app.manifest, sid, "exit") and old_point != "":
						app._clear_exit_pair(previous_map, old_point, str(app.canvas.cur_map_name), str(app.selected_spr.get_meta("ent_id", "")))
					if old_point != "":
						props.erase("target_point")
					props[fid] = next_map
					app.selected_spr.set_meta("props", props)
					app.canvas._mark()
					rebuild())


			app.props_panel.add_child(UiKitScript.field_row(fname, md, UiKitScript.LABEL_W_LONG))
			# 在目标地图缩略图上直接点选/新建传送落点
			var pick_btn := UiKitScript.button("在图上选落点…", func():
				var tmap := str(props.get(fid, ""))
				if tmap == "":
					app._set_status("先选目标地图，再在图上选落点")
					return
				# 落点字段 = 同实体里 id 以 point 结尾的 string 字段（target_map ↔ target_point）
				var pid := ""
				for f3 in edef.get("fields", []):
					if str(f3.get("id", "")) != fid and str(f3.get("id", "")).ends_with("point"):
						pid = str(f3.get("id", ""))
						break
				app._open_map_point_picker(tmap, fid, pid, props), "plain")
			pick_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			pick_btn.tooltip_text = "在目标地图上点选或新建传送落点（会先确认，确认后写入目标图、不走撤销）"
			app.props_panel.add_child(pick_btn)
		elif ftype == "enum":
			# H5（批次 11）：清单声明 options 的下拉字段；值 = 字符串，游戏侧解释
			var ob := OptionButton.new()
			var options: Array = f.get("options", [])
			var val_e := str(props.get(fid, str(f.get("default", ""))))
			var sel_e := options.find(val_e)
			for o in options:
				ob.add_item(str(o))
			if sel_e < 0 and (options as Array).size() > 0:
				ob.add_item(val_e)
				sel_e = (options as Array).size() - 1
			ob.select(maxi(sel_e, 0))
			ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			ob.item_selected.connect(func(idx: int):
				app.canvas._push_undo()
				props[fid] = str(options[idx])
				app.selected_spr.set_meta("props", props)
				app.canvas._mark())
			app.props_panel.add_child(UiKitScript.field_row(fname, ob, UiKitScript.LABEL_W_LONG))
		elif ftype == "bool":
			# H5：清单声明的开关字段
			var cb2 := CheckBox.new()
			cb2.button_pressed = bool(props.get(fid, f.get("default", false)))
			cb2.toggled.connect(func(on: bool):
				app.canvas._push_undo()
				props[fid] = on
				app.selected_spr.set_meta("props", props)
				app.canvas._mark())
			app.props_panel.add_child(UiKitScript.field_row(fname, cb2, UiKitScript.LABEL_W_LONG))
		else:
			# 落点类字段（map_ref 实体的 companion string 字段）→ 只读显示：
			# 跨图落点 id 只能通过缩略图选点器设置，手填必然出错
			var has_map_ref := false
			for f4 in edef.get("fields", []):
				if str(f4.get("type", "")) == "map_ref":
					has_map_ref = true
					break
			if has_map_ref and fid.ends_with("point"):
				app.props_panel.add_child(UiKitScript.hint_label(
					"落点：%s（用上方「在图上选落点…」修改）" % str(props.get(fid, "(未设置)")), 250))
			else:
				var le := LineEdit.new()
				le.text = str(props.get(fid, f.get("default", "")))
				le.placeholder_text = fname
				le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				var edit_session := {"started": false}
				le.focus_exited.connect(func(): edit_session.started = false)
				le.text_changed.connect(func(t: String):
					if not edit_session.started:
						app.canvas._push_undo()
						edit_session.started = true
					props[fid] = t
					app.selected_spr.set_meta("props", props)
					app.canvas._mark())
				app.props_panel.add_child(UiKitScript.field_row(fname, le, UiKitScript.LABEL_W_LONG))

	# —— 数值字段（stats）：继承 / 覆盖 / 重置 ——
	var stats_defs: Array = edef.get("stats", [])
	if not stats_defs.is_empty():
		app.props_panel.add_child(UiKitScript.divider())
		var stat_head := UiKitScript.hbox(6)
		stat_head.add_child(UiKitScript.section_label("数值"))
		stat_head.add_child(UiKitScript.spacer())
		stat_head.add_child(UiKitScript.text_label("默认值来自资产模板", UiThemeScript.TEXT_MUTE, UiThemeScript.FS_META))
		app.props_panel.add_child(stat_head)
		var ov: Dictionary = props.get("stats", {})
		# B10：显示值 = 三层合并（实例 > 定义 > 清单），与游戏运行时一致；来源层写进徽章 tooltip
		var DefModel := preload("res://src/content/def_model.gd")
		var ContentStoreB10 := preload("res://src/content/content_store.gd")
		var b10_def_id := str((app.selected_spr as Sprite2D).get_meta("def_id", ""))
		var def_res := ContentStoreB10.read(app.manifest, "defs", b10_def_id) if b10_def_id != "" else {}
		var eff: Dictionary = DefModel.effective_stats(def_res, edef, props)
		for sf in stats_defs:
			var sid2 := str(sf.get("id", ""))
			var sdef := float(sf.get("default", 0.0))
			var sbox := SpinBox.new()
			sbox.min_value = float(sf.get("min", 0.0))
			sbox.max_value = float(sf.get("max", 999.0))
			sbox.step = 0.1 if str(sf.get("type", "float")) == "float" else 1.0
			sbox.value = float(eff.get(sid2, sdef))
			sbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			# 继承 / 覆盖 用徽章表达，比纯文字更易扫读
			var tag := UiKitScript.badge("覆盖" if ov.has(sid2) else "继承",
				UiThemeScript.WARN if ov.has(sid2) else UiThemeScript.TEXT_MUTE)
			# B10：徽章 tooltip 标明当前显示值来源层
			tag.tooltip_text = "当前显示值来源：%s" % ("实例覆盖" if ov.has(sid2) else ("定义 stats" if (eff as Dictionary).has(sid2) else "清单默认"))
			var rst := UiKitScript.button("↺", func():
				if not ov.has(sid2):
					return
				app.canvas._push_undo()
				ov.erase(sid2)
				if ov.is_empty():
					props.erase("stats")
				else:
					props["stats"] = ov
				app.selected_spr.set_meta("props", props)
				app.canvas._mark()
				rebuild(), "icon")
			rst.tooltip_text = "恢复为资产模板默认值"
			var edit_session := {"started": false}
			sbox.get_line_edit().focus_exited.connect(func(): edit_session.started = false)
			sbox.value_changed.connect(func(v: float):
				if not edit_session.started:
					app.canvas._push_undo()
					edit_session.started = true
				ov[sid2] = v
				props["stats"] = ov
				app.selected_spr.set_meta("props", props)
				app.canvas._mark()
				app._set_badge(tag, "覆盖", UiThemeScript.WARN))


			var row := UiKitScript.hbox(6)
			var nl := UiKitScript.text_label(str(sf.get("name", sid2)), UiThemeScript.TEXT_DIM, UiThemeScript.FS_SMALL)
			nl.custom_minimum_size = Vector2(76, 0)
			nl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			row.add_child(nl)
			row.add_child(sbox)
			row.add_child(tag)
			row.add_child(rst)
			app.props_panel.add_child(row)

	# 没有任何可编辑字段时（拾取物、出生点这类），别留一片空白
	if (edef.get("fields", []) as Array).is_empty() and (edef.get("stats", []) as Array).is_empty():
		app.props_panel.add_child(UiKitScript.divider())
		app.props_panel.add_child(UiKitScript.text_label("这个类型没有可调属性",
			UiThemeScript.TEXT_MUTE, UiThemeScript.FS_SMALL))
		app.props_panel.add_child(UiKitScript.hint_label(
			"放置位置即全部数据；要加可调项请在资产模板里定义字段", 250))

	# 多选收尾：字段区整块压暗（仍可编辑主选中项，但一眼看出不是批量作用）
	if multi:
		var kids: int = app.props_panel.get_child_count()
		for i in range(dim_from, kids):
			var node: Control = app.props_panel.get_child(i)
			if node is Label or node is HSeparator:
				continue
			node.modulate = Color(1, 1, 1, 0.6)
