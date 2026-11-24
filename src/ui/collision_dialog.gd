extends RefCounted
## 选择源瓦片层，将地形转为碰撞格。
const UiKitScript := preload("res://src/ui/ui_kit.gd")
const UiThemeScript := preload("res://src/ui/ui_theme.gd")

static func open(app) -> void:
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
	# 源地形层：默认取当前普通层；停在碰撞层时列全部普通层的手选入口。
	# 元数据存**层码**而不是下标：弹窗开着时层可能被增删/换序（弹窗不独占），
	# 按下标提交会从另一层推导碰撞（V4 P1）。
	var src_opt := OptionButton.new()
	src_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in app.canvas.layer_count():
		if i == app.canvas.collision_index():
			continue
		src_opt.add_item(app.canvas.layer_name(i))
		src_opt.set_item_metadata(src_opt.item_count - 1, app.canvas.layer_id(i))
	var cur_src_id: String = app.canvas.layer_id(app.canvas._collision_source_layer())
	var found := false
	for i in src_opt.item_count:
		if str(src_opt.get_item_metadata(i)) == cur_src_id:
			src_opt.select(i)
			found = true
			break
	if not found and src_opt.item_count > 0:
		src_opt.select(0)   # 没有可用当前层（如全是空壳层）：默认第一项，别留空选
	src_opt.tooltip_text = "从哪一层的瓦片推导碰撞；碰撞层本身不能作来源"
	body.add_child(UiKitScript.field_row("源层", src_opt, UiKitScript.LABEL_W))
	# 现读：层码 → 当前下标（层已删 = -1，生成前会据此拒绝）
	var src_layer := func() -> int:
		if src_opt.selected < 0:
			return -1
		return app.canvas._layer_index_of(str(src_opt.get_item_metadata(src_opt.selected)))
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
		var sl: int = src_layer.call()
		if sl < 0:
			preview.text = "所选源层已不存在（可能刚被删除）：请重选一层"
			preview.add_theme_color_override("font_color", UiThemeScript.TEXT_MUTE)
			return
		var n: int = app.canvas.count_auto_collision(_collision_strategy(strat.selected), replace_cb.button_pressed, sl)
		if n == 0 and not replace_cb.button_pressed:
			# 已有碰撞覆盖了全部候选格：说清为什么是 0，而不是让人以为功能坏了
			preview.text = "这些格子已经有碰撞了；要重算请勾选「先清空现有碰撞」"
			preview.add_theme_color_override("font_color", UiThemeScript.TEXT_MUTE)
		else:
			preview.text = "将写入 %d 格碰撞" % n
			preview.add_theme_color_override("font_color", UiThemeScript.ACCENT_HI)
	strat.item_selected.connect(func(_i: int): refresh_preview.call())
	src_opt.item_selected.connect(func(_i: int): refresh_preview.call())
	replace_cb.toggled.connect(func(_on: bool): refresh_preview.call())
	refresh_preview.call()
	var btn_row := UiKitScript.hbox(8)
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	var gen_cb := func():
		var sl: int = src_layer.call()
		if sl < 0:
			app._set_status(" 源层已不存在：没有生成碰撞（请重选源层）")
			refresh_preview.call()
			return
		var n: int = app.canvas.generate_collision(_collision_strategy(strat.selected), replace_cb.button_pressed, one_way_cb.button_pressed, sl)
		pop.hide()
		app._set_status("已生成 %d 格碰撞（Ctrl+Z 撤销）" % n)
	btn_row.add_child(UiKitScript.button("取消", func(): pop.hide(), "ghost"))
	btn_row.add_child(UiKitScript.button("生成", gen_cb, "primary"))
	body.add_child(btn_row)
	app._open_popup(pop)

static func _collision_strategy(idx: int) -> String:
	match idx:
		1: return "top"
		2: return "outline"
		_: return "full"
