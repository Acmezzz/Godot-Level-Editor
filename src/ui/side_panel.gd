extends PanelContainer
## 右侧工具面板：地图 / 实体 / 校验 三个日常页签。
## 通过信号与 app.gd 交互，面板本身不做 IO。
##
## 关卡清单与世界拓扑已迁到项目页「清单」视图（src/ui/levels_panel.gd，重构 R2）——
## 项目级低频操作不挤占画布右侧页签。
##
## 视觉全部走 UiTheme / UiKit：页签外壳由主题统一，页面内用分段标题、空状态、
## 徽章表达状态，避免各页各自拼一套样式。

signal map_open_requested(map_name: String)
signal draft_open_requested(path: String)
signal entity_focus_requested(ent_id: String)
## 列表悬停：把 ent_id 交给画布做临时高亮（"" = 熄灭）
signal entity_hover_requested(ent_id: String)
signal entity_delete_requested(ent_ids: Array)
signal issue_focus_requested(map_name: String, ent_id: String)
# K18（批次 10）：地图右键管理——面板不做 IO，走信号交给 app 侧
signal map_rename_requested(old_name: String, new_name: String)
signal map_duplicate_requested(old_name: String, new_name: String)
signal refresh_maps_requested
signal validate_all_requested
signal validate_current_requested

const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")
const CollapsibleScript := preload("res://src/ui/collapsible.gd")

var maps: Array = []          # [{name, w, h, ents}]（map_list 选中项下标 → 此数组）
var issues: Array = []        # MapValidate 输出

## 检查器槽位：属性面板容器挂这里（R2：左栏那份整体移到右栏，内容不动）
var inspector_slot: VBoxContainer
var _input_label: Label
var _fold_entities
var _fold_issues
var _fold_maps

var map_list: ItemList
var ent_list: ItemList
var issue_list: ItemList
var ent_filter: LineEdit
var ent_scene_filter: OptionButton
var _all_entities: Array = []
var _map_empty: Control
var _ent_empty: Control
var _ent_empty_title: Label
var _last_hover_id := ""     # 实体列表悬停去重（只在条目变化时发信号）
var _last_ent_sig: Array = []   # U-15：上次实体列表内容签名（未变不重建）

func build() -> void:
	custom_minimum_size = Vector2(340, 0)
	var sb := Th.box(Th.BG_PANEL, Th.BORDER, 0, 0, 0)
	sb.set_border_width_all(0)
	sb.border_width_left = 1
	add_theme_stylebox_override("panel", sb)
	# PanelContainer 只放得下一个子节点——整列都要装进这个 VBox，
	# 否则检查器标题/属性区/三个折叠区会全部叠在同一个位置上。
	var stack := Kit.vbox(0)
	add_child(stack)

	# —— 检查器（主体）：选中什么就检查什么。属性面板整体迁到这里（R2） ——
	var insp_head := PanelContainer.new()
	var ih_sb := Th.box(Th.BG_BASE, Th.BORDER, 0, 10, 6)
	ih_sb.set_border_width_all(0)
	ih_sb.border_width_bottom = 1
	insp_head.add_theme_stylebox_override("panel", ih_sb)
	stack.add_child(insp_head)
	var ih := Kit.hbox(6)
	insp_head.add_child(ih)
	_input_label = Kit.section_label("检查器")
	_input_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ih.add_child(_input_label)

	inspector_slot = Kit.vbox(0)
	inspector_slot.size_flags_vertical = Control.SIZE_EXPAND_FILL
	inspector_slot.custom_minimum_size = Vector2(0, 220)
	stack.add_child(inspector_slot)

	# —— 三个项目级折叠区（收起只占一行，记住展开态） ——
	stack.add_child(Kit.divider())
	_fold_entities = CollapsibleScript.new("实体大纲", false)
	_fold_issues = CollapsibleScript.new("校验", false)
	_fold_maps = CollapsibleScript.new("地图列表", false)
	for f in [_fold_maps, _fold_entities, _fold_issues]:
		stack.add_child(f)
	_build_entity_body(_fold_entities.body)
	_build_issue_body(_fold_issues.body)
	_build_map_body(_fold_maps.body)

## —— 地图列表折叠区 ——
func _build_map_body(box: VBoxContainer) -> void:
	var bar := Kit.hbox(6)
	bar.add_child(Kit.button("刷新", func(): refresh_maps_requested.emit(), "ghost"))
	bar.add_child(Kit.spacer())
	box.add_child(bar)
	map_list = ItemList.new()
	map_list.custom_minimum_size = Vector2(0, 160)
	map_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	map_list.fixed_icon_size = Vector2i(28, 28)
	map_list.icon_mode = ItemList.ICON_MODE_LEFT
	# U-08：单击即打开（原来只有双击）。语义与实体列表一致；未保存改动有确认框兜底。
	map_list.item_clicked.connect(func(i: int, _at: Vector2, mb: int):
		# K18（批次 10）：右键 = 地图管理菜单（重命名/创建副本）；左键打开逻辑不变
		if mb == MOUSE_BUTTON_RIGHT and i >= 0 and i < maps.size():
			var md0 = map_list.get_item_metadata(i)
			if not (md0 is Dictionary):
				_show_map_menu(i, str(md0))
			return
		if mb != MOUSE_BUTTON_LEFT or i < 0:
			return
		var md = map_list.get_item_metadata(i)
		if md is Dictionary:
			# 草稿条目：metadata 是 {draft, path}，打开的是草稿文件路径
			if bool(md.get("draft", false)):
				draft_open_requested.emit(str(md.get("path", "")))
			return
		if i >= maps.size():
			return
		map_open_requested.emit(str(md)))
	box.add_child(map_list)
	_map_empty = Kit.empty_state("▤", "还没有地图",
		"用顶栏「新建」创建第一张地图")
	_map_empty.visible = false
	box.add_child(_map_empty)

## —— 实体大纲折叠区 ——
func _build_entity_body(box: VBoxContainer) -> void:
	var filter_row := Kit.hbox(6)
	ent_filter = LineEdit.new()
	ent_filter.placeholder_text = "搜索 id 或名称"
	ent_filter.clear_button_enabled = true
	ent_filter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ent_filter.text_changed.connect(func(_t: String): _apply_entity_filter())
	filter_row.add_child(ent_filter)
	box.add_child(filter_row)
	ent_scene_filter = OptionButton.new()
	ent_scene_filter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ent_scene_filter.item_selected.connect(func(_i: int): _apply_entity_filter())
	box.add_child(ent_scene_filter)
	ent_list = ItemList.new()
	ent_list.custom_minimum_size = Vector2(0, 200)
	ent_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	ent_list.select_mode = ItemList.SELECT_MULTI
	# 单击即定位（不用双击）：列表是「挑一个去画布上找」的工具面板，
	# 双击多一次点击、多一次等待，没有任何额外语义。
	# 多选用 Ctrl/Shift 点击，选中态与定位互不冲突。
	ent_list.item_clicked.connect(func(i: int, _at: Vector2, mb: int):
		if mb != MOUSE_BUTTON_LEFT:
			return
		var id := str(ent_list.get_item_metadata(i))
		if id != "":
			entity_focus_requested.emit(id))
	# 悬停即高亮画布上对应实体：不用先选中就能看清哪一条是哪个。
	# 鼠标移出列表时发空串，让高亮熄灭。
	ent_list.mouse_exited.connect(func(): entity_hover_requested.emit(""))
	# U-07：滚动改变鼠标下条目但不产生 motion 事件——滚动条变化时重算悬停
	ent_list.get_v_scroll_bar().value_changed.connect(func(_v):
		var i := ent_list.get_item_at_position(ent_list.get_local_mouse_position(), true)
		var id := "" if i < 0 else str(ent_list.get_item_metadata(i))
		if id != _last_hover_id:
			_last_hover_id = id
			entity_hover_requested.emit(id))
	ent_list.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseMotion:
			var i := ent_list.get_item_at_position((ev as InputEventMouseMotion).position, true)
			var id := "" if i < 0 else str(ent_list.get_item_metadata(i))
			if id != _last_hover_id:
				_last_hover_id = id
				entity_hover_requested.emit(id))
	box.add_child(ent_list)
	_ent_empty = Kit.empty_state("◇", "当前图没有实体",
		"在实体层用盖章工具放置，或换一张地图")
	_ent_empty.visible = false
	# U-14：不依赖子节点顺序，按名字找标题
	_ent_empty_title = _ent_empty.find_child("Title", true, false) as Label
	box.add_child(_ent_empty)
	var ent_btns := Kit.hbox(6)
	ent_btns.add_child(Kit.button("定位", func():
		var i: int = int(ent_list.get_next_selected(-1))
		if i >= 0:
			entity_focus_requested.emit(str(ent_list.get_item_metadata(i))), "plain"))
	var del_btn := Kit.button("删除选中", func():
		var ids := []
		var i: int = int(ent_list.get_next_selected(-1))
		while i >= 0:
			ids.append(str(ent_list.get_item_metadata(i)))
			i = int(ent_list.get_next_selected(i))
		if not ids.is_empty():
			entity_delete_requested.emit(ids), "ghost")
	ent_btns.add_child(del_btn)
	box.add_child(ent_btns)

## —— 校验折叠区 ——
func _build_issue_body(box: VBoxContainer) -> void:
	var issue_bar := Kit.hbox(6)
	issue_bar.add_child(Kit.button("全部地图", func(): validate_all_requested.emit(), "plain"))
	issue_bar.add_child(Kit.button("本图", func(): validate_current_requested.emit(), "ghost"))
	box.add_child(issue_bar)
	issue_list = ItemList.new()
	issue_list.custom_minimum_size = Vector2(0, 160)
	issue_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	issue_list.item_clicked.connect(func(i: int, _at: Vector2, _mb: int):   # F3：单击即跳转
		if i < issues.size():
			var it: Dictionary = issues[i]
			issue_focus_requested.emit(str(it.get("map", "")), str(it.get("ent_id", ""))))
	box.add_child(issue_list)

## 骨架扩展：属性面板由 editor_layout 建好后挂进来（保持 props_panel 容器与其控制器不被拆开）
func attach_inspector(node: Control) -> void:
	inspector_slot.add_child(node)

## 折叠区展开/收起（外部可编程切换，例如校验完成后自动展开）
func set_section_expanded(which: String, on: bool) -> void:
	var f = {"entities": _fold_entities, "issues": _fold_issues, "maps": _fold_maps}.get(which)
	if f != null:
		f.set_expanded(on)

## 旧 API 兼容：页签已变折叠区，select_tab(1)=实体/2=校验/3=地图
func select_tab(idx: int) -> void:
	match idx:
		1: set_section_expanded("entities", true)
		2: set_section_expanded("issues", true)
		3: set_section_expanded("maps", true)


## 日常三页签（地图/实体/校验）不项目级低频操作挤占。

## K18（批次 10）：地图右键菜单（重命名/创建副本）——面板不做 IO，走信号交给 app。
func _show_map_menu(i: int, nm: String) -> void:
	var pm := PopupMenu.new()
	pm.add_item("重命名", 1)
	pm.add_item("创建副本", 2)
	pm.id_pressed.connect(func(id: int):
		if id == 1:
			_ask_rename(nm)
		elif id == 2:
			map_duplicate_requested.emit(nm, nm + "_copy"))
	map_list.add_child(pm)
	pm.position = map_list.get_global_mouse_position()
	pm.popup()

## T16 拍板：纯 rename（只改文件名不迁移引用）；副本同策略。
func _ask_rename(nm: String) -> void:
	var pop := PopupPanel.new()
	var vb := VBoxContainer.new()
	vb.add_child(Kit.text_label("重命名地图「%s」——只改文件名，不改引用" % nm, Th.TEXT_MUTE, Th.FS_SMALL))
	var le := LineEdit.new()
	le.text = nm
	vb.add_child(le)
	var row := Kit.hbox(8)
	var do_rename := func():
		var nn := le.text.strip_edges()
		if nn == "" or nn == nm:
			pop.hide()
			return
		map_rename_requested.emit(nm, nn)
		pop.hide()
	le.text_submitted.connect(func(_t: String): do_rename.call())
	row.add_child(Kit.button("确定", do_rename, "primary"))
	row.add_child(Kit.button("取消", func(): pop.hide(), "ghost"))
	vb.add_child(row)
	pop.add_child(vb)
	add_child(pop)
	pop.popup_centered()

## list = [{name,w,h,ents}]；thumbs = {name: Texture2D}（列表图标）；drafts = [{name,path}]（置顶）
func set_maps(list: Array, current: String, thumbs := {}, drafts := []) -> void:
	maps = list
	map_list.clear()
	# 缺口3：比正式文件新的草稿置顶展示（单击打开草稿；保存后草稿变旧，条目自动消失）
	for dr in drafts:
		var di := map_list.add_item("〔草稿〕" + str(dr.get("name", "")))
		map_list.set_item_tooltip(di, "自动草稿比正式文件新——可能记录了未保存的工作。\n单击打开草稿；打开后保存即写回正式文件，草稿变旧后条目自动消失。")
		map_list.set_item_metadata(di, {"draft": true, "path": str(dr.get("path", ""))})
		map_list.set_item_custom_fg_color(di, Th.WARN)
	for md in list:
		var nm := str(md.get("name", ""))
		var is_cur := nm == current
		# 单行控件：当前图靠选中态表达，不再加 ▶ 前缀（与关卡页打标重复）
		var idx := map_list.add_item("%s      %d×%d · %d 实体" % [
			nm, int(md.get("w", 0)), int(md.get("h", 0)), int(md.get("ents", 0))])
		map_list.set_item_metadata(idx, nm)
		if thumbs.has(nm):
			map_list.set_item_icon(idx, thumbs[nm])
		if is_cur:
			map_list.select(idx)
	# 空状态：没地图时把列表藏起来，给引导
	if _map_empty:
		_map_empty.visible = list.is_empty()
		map_list.visible = not list.is_empty()

func set_entities(list: Array) -> void:
	# U-15：内容未变就不重建——多选状态与滚动位置不被任何编辑打断（PF-01 防抖配套）
	var sig := []
	for ed in list:
		sig.append(str(ed.get("id", "")) + "|" + str(ed.get("scene", "")) + "|" + str(ed.get("x", 0)) + "," + str(ed.get("y", 0)))
	if sig == _last_ent_sig:
		return
	_last_ent_sig = sig
	# U-07：旧悬停目标可能已不在列表里——重建时熄灭
	if _last_hover_id != "":
		_last_hover_id = ""
		entity_hover_requested.emit("")
	_all_entities = list
	# 重建类型下拉
	var prev := ent_scene_filter.selected if ent_scene_filter.selected >= 0 else 0
	ent_scene_filter.clear()
	ent_scene_filter.add_item("全部类型")
	var scenes := {}
	for ed in list:
		scenes[str(ed.get("scene", ""))] = true
	var keys := scenes.keys()
	keys.sort()
	for s in keys:
		ent_scene_filter.add_item(str(s))
	ent_scene_filter.select(clampi(prev, 0, ent_scene_filter.item_count - 1))
	_apply_entity_filter()

func _apply_entity_filter() -> void:
	if ent_list == null:
		return
	ent_list.clear()
	var needle := ent_filter.text.strip_edges().to_lower()
	var scene_want := ""
	if ent_scene_filter.selected > 0:
		scene_want = ent_scene_filter.get_item_text(ent_scene_filter.selected)
	for ed in _all_entities:
		var eid := str(ed.get("id", ""))
		var nm := str(ed.get("name", ""))
		var sc := str(ed.get("scene", ""))
		if scene_want != "" and sc != scene_want:
			continue
		if needle != "" and not (eid.to_lower().contains(needle) or nm.to_lower().contains(needle)):
			continue
		var idx := ent_list.add_item("%s  %s   ·  %s (%d,%d)" % [
			eid, nm, sc, int(ed.get("x", 0)), int(ed.get("y", 0))])
		ent_list.set_item_tooltip(idx, "%s\n%s\n场景：%s\n坐标：(%d, %d)" % [
			eid, nm, sc, int(ed.get("x", 0)), int(ed.get("y", 0))])
		ent_list.set_item_metadata(idx, eid)
	if _ent_empty:
		var empty := ent_list.item_count == 0
		_ent_empty.visible = empty
		ent_list.visible = not empty
		if empty:
			# 区分「确实没有」与「筛掉了」
			var filtered := needle != "" or scene_want != ""
			if _ent_empty_title:
				_ent_empty_title.text = "没有匹配的实体" if filtered else "当前图没有实体"

func set_issues(list: Array) -> void:
	issues = list
	issue_list.clear()
	if list.is_empty():
		var idx0 := issue_list.add_item("✓   没有问题")
		issue_list.set_item_custom_fg_color(idx0, Th.OK)
		return
	var errors := 0
	var warns := 0
	for it in list:
		var lv := str(it.get("level", "warn"))
		if lv == "error":
			errors += 1
		else:
			warns += 1
		var tag := "✕  " if lv == "error" else "!  "
		var msg := str(it.get("message", ""))
		var idx := issue_list.add_item("%s%s   ·  %s" % [tag, str(it.get("map", "")), msg])
		issue_list.set_item_tooltip(idx, "%s\n%s" % [str(it.get("map", "")), msg])
		issue_list.set_item_custom_fg_color(idx, Th.ERR if lv == "error" else Th.WARN)
	issue_list.add_item("——  %d 错误 · %d 警告  ——" % [errors, warns])
	var last := issue_list.item_count - 1
	issue_list.set_item_custom_fg_color(last, Th.TEXT_MUTE)
	issue_list.set_item_selectable(last, false)
