extends VBoxContainer
## 关卡清单 + 世界拓扑（重构 R2）：从右侧面板页签迁入项目页「清单」视图。
##
## 设计基线：关卡清单与世界拓扑并入项目页「清单」视图（上下两段），
## 不再挤占画布右侧页签栏。面板本身不做 IO，全部经信号交给 app / side_actions。

signal level_open_requested(map_name: String)
signal levels_changed(levels: Dictionary)
signal world_refresh_requested

const LevelListScript := preload("res://src/level_list.gd")
const WorldMapScript := preload("res://src/ui/world_map_view.gd")
const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")

var levels: Dictionary = {}
var manifest_ref: Dictionary = {}

var level_list: ItemList
var mode_opt: OptionButton
var start_opt: OptionButton
var world_view = null
var _world_hint: Label

func build() -> void:
	add_theme_constant_override("separation", 10)
	_build_levels_section()
	_build_world_section()

## —— 上段：关卡清单 ——
func _build_levels_section() -> void:
	add_child(Kit.section_header("关卡清单"))
	var mode_row := Kit.hbox(6)
	mode_row.add_child(Kit.text_label("模式", Th.TEXT_MUTE, Th.FS_SMALL))
	mode_opt = OptionButton.new()
	mode_opt.add_item("大地图（银河城）")
	mode_opt.add_item("选关")
	mode_opt.custom_minimum_size = Vector2(180, 0)
	mode_opt.item_selected.connect(func(_i: int):
		levels["mode"] = "metroidvania" if mode_opt.selected == 0 else "level_select")
	mode_row.add_child(mode_opt)
	mode_row.add_child(Kit.text_label("起始关", Th.TEXT_MUTE, Th.FS_SMALL))
	start_opt = OptionButton.new()
	start_opt.custom_minimum_size = Vector2(160, 0)
	start_opt.item_selected.connect(func(_i: int):
		levels["start"] = str(start_opt.get_item_metadata(start_opt.selected)))
	mode_row.add_child(start_opt)
	mode_row.add_child(Kit.spacer())
	var save_btn := Kit.button("保存清单", func(): levels_changed.emit(levels.duplicate(true)), "primary")
	save_btn.tooltip_text = "写入 <项目>/editor/levels.json"
	mode_row.add_child(save_btn)
	add_child(mode_row)

	level_list = ItemList.new()
	level_list.custom_minimum_size = Vector2(0, 168)
	level_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	level_list.tooltip_text = "单击选中；双击或回车打开该地图"
	# 单击 = 选中（供重命名/排序/移除使用），双击/回车 = 打开地图。
	# 若用 item_clicked，单击选中行就会切走出项目页，重命名根本来不及点。
	level_list.item_activated.connect(func(i: int):
		var md = level_list.get_item_metadata(i)
		# BUG-15：占位项没有 metadata，null 早退
		if md == null:
			return
		var nm := str(md)
		if nm != "":
			level_open_requested.emit(nm))
	add_child(level_list)

	var lv_btns := Kit.hbox(4)
	var add_btn := Kit.button("+ 添加关卡", _add_level, "plain")
	add_btn.tooltip_text = "把一张已有地图编入关卡清单（追加到末尾并立即保存）"
	lv_btns.add_child(add_btn)
	var ren_btn := Kit.button("重命名", _rename_level, "ghost")
	ren_btn.tooltip_text = "改选中关卡的显示名（只改清单里的 name，不改地图文件名）"
	lv_btns.add_child(ren_btn)
	for spec in [["↑", -1], ["↓", 1]]:
		lv_btns.add_child(Kit.button(str(spec[0]), func(): _move_level(int(spec[1])), "plain"))
	lv_btns.add_child(Kit.button("移除", _remove_level, "ghost"))
	lv_btns.add_child(Kit.spacer())
	lv_btns.add_child(Kit.button("从地图文件生成清单", func(): rebuild_from_maps(), "ghost"))
	lv_btns.add_child(Kit.button("刷新拓扑", func(): world_refresh_requested.emit(), "ghost"))
	add_child(lv_btns)

## —— 下段：世界拓扑 ——
func _build_world_section() -> void:
	add_child(Kit.divider())
	var head := Kit.hbox(6)
	head.add_child(Kit.section_label("世界拓扑"))
	head.add_child(Kit.spacer())
	_world_hint = Kit.text_label("", Th.TEXT_MUTE, Th.FS_META)
	head.add_child(_world_hint)
	add_child(head)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 260)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	world_view = WorldMapScript.new()
	world_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	world_view.on_select = func(map_name: String): level_open_requested.emit(map_name)
	scroll.add_child(world_view)

# —— 关卡清单编辑（原 side_panel 逻辑原样迁入） ——
func _level_selected() -> int:
	var sel := level_list.get_selected_items()
	return int(sel[0]) if sel.size() > 0 else -1

## 添加关卡：从「地图文件里还没编入清单」的地图里挑一张，追加到清单末尾。
## 区域/解锁/密钥等归属设计信息在新建地图时填，这里只做编入动作。
func _add_level() -> void:
	var host = _host_app()
	if manifest_ref.is_empty() or host == null:
		push_warning("levels_panel: 无宿主 app，添加关卡不可用")
		return
	var maps: Array = host.MapStore.list_maps(manifest_ref)
	var arr: Array = levels.get("levels", [])
	var used := {}
	for lv in arr:
		used[str((lv as Dictionary).get("map", ""))] = true
	var free_maps: Array = []
	for nm in maps:
		if not used.has(str(nm)):
			free_maps.append(str(nm))
	if free_maps.is_empty():
		var why := "项目里还没有地图文件。" if maps.is_empty() else "已有地图都已编入关卡清单。"
		var shell0: Dictionary = host._popup_body("添加关卡", why)
		var pop0: PopupPanel = shell0.pop
		var b0: VBoxContainer = shell0.body
		b0.add_child(Kit.wrap_label("先用地图菜单「新建地图」创建新地图，或点「从地图文件生成清单」重建清单。", 320))
		var ok_row := Kit.hbox(8)
		ok_row.add_child(Kit.spacer())
		ok_row.add_child(Kit.button("知道了", func(): pop0.hide(), "primary"))
		b0.add_child(ok_row)
		host._open_popup(pop0)
		return
	var shell: Dictionary = host._popup_body("添加关卡", "选择要编入关卡清单的地图。清单顺序可用 ↑↓ 调整。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for nm in free_maps:
		opt.add_item(str(nm))
	opt.select(0)
	body.add_child(Kit.field_row("地图", opt))
	body.add_child(Kit.popup_buttons(
		func(): _do_add_level(str(opt.get_item_text(opt.selected)), pop),
		func(): pop.hide()))
	host._open_popup(pop)

func _do_add_level(map_name: String, pop: PopupPanel) -> void:
	if map_name == "":
		pop.hide()
		return
	var arr: Array = levels.get("levels", [])
	arr.append({
		"map": map_name, "name": map_name, "order": arr.size() + 1,
		"area": "", "unlock": "", "secret": false,
	})
	levels["levels"] = arr
	if str(levels.get("start", "")) == "":
		levels["start"] = map_name
	pop.hide()
	# 先刷新本地，再发信号请宿主保存并回读；最后复位选中（回读会清选中）
	set_levels(levels, manifest_ref)
	levels_changed.emit(levels.duplicate(true))
	level_list.select(arr.size() - 1)
	level_list.ensure_current_is_visible()

## 重命名：改条目的显示名 name（不动 map 文件名，不动落盘路径）
func _rename_level() -> void:
	var i := _level_selected()
	if i < 0:
		_status("先选中一行再重命名")
		return
	var arr: Array = levels.get("levels", [])
	if i >= arr.size():
		return
	var host = _host_app()
	if host == null:
		return
	var cur := str((arr[i] as Dictionary).get("name", (arr[i] as Dictionary).get("map", "")))
	var shell: Dictionary = host._popup_body("重命名关卡", "只改清单里显示的名字，地图文件名不变。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var edit := LineEdit.new()
	edit.text = cur
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.placeholder_text = "关卡显示名"
	body.add_child(Kit.field_row("名称", edit))
	body.add_child(Kit.hint_label("留空 = 恢复显示地图名 %s" % str((arr[i] as Dictionary).get("map", "")), 320))
	body.add_child(Kit.popup_buttons(
		func(): _do_rename_level(i, edit.text, pop),
		func(): pop.hide()))
	edit.text_submitted.connect(func(_t: String): _do_rename_level(i, edit.text, pop))
	host._open_popup(pop)
	edit.call_deferred("grab_focus")
	edit.call_deferred("select_all")

func _do_rename_level(i: int, new_name: String, pop: PopupPanel) -> void:
	var arr: Array = levels.get("levels", [])
	if i < 0 or i >= arr.size():
		pop.hide()
		return
	var nm := new_name.strip_edges()
	if nm == "":
		nm = str((arr[i] as Dictionary).get("map", ""))
	(arr[i] as Dictionary)["name"] = nm
	pop.hide()
	# 先刷新本地，再发信号请宿主保存并回读；最后复位选中（回读会清选中）
	set_levels(levels, manifest_ref)
	levels_changed.emit(levels.duplicate(true))
	level_list.select(i)
	level_list.ensure_current_is_visible()

## 宿主 app：本面板在项目页与地图菜单弹窗两处复用，构造时都不传 app 引用。
## 由挂载链向上找带 _popup_body 的宿主节点（app.gd 根节点 / 弹窗都在它之下）。
## 弹窗关闭时会被 queue_free，这里缓存一份，避免关窗后仍向上找链。
var _host_cache = null

func _host_app():
	if _host_cache != null and is_instance_valid(_host_cache):
		var cached: Node = _host_cache
		if cached.is_inside_tree():
			return cached
	var n: Node = get_parent()
	while n != null:
		if n.has_method("_popup_body") and n.has_method("_set_status"):
			_host_cache = n
			return n
		n = n.get_parent()
	return null

func _status(msg: String) -> void:
	var a = _host_app()
	if a != null:
		a._set_status(msg)

func _move_level(dir: int) -> void:
	var i := _level_selected()
	if i < 0:
		return
	var arr: Array = levels.get("levels", [])
	var j := i + dir
	if j < 0 or j >= arr.size():
		return
	var tmp = arr[i]
	arr[i] = arr[j]
	arr[j] = tmp
	_reorder_orders(arr)
	levels["levels"] = arr
	set_levels(levels, manifest_ref)
	level_list.select(j)
	level_list.ensure_current_is_visible()

func _remove_level() -> void:
	var i := _level_selected()
	if i < 0:
		return
	var arr: Array = levels.get("levels", [])
	if i >= arr.size():
		return
	var removed_name := str((arr[i] as Dictionary).get("map", ""))
	arr.remove_at(i)
	_reorder_orders(arr)
	levels["levels"] = arr
	if str(levels.get("start", "")) == removed_name:
		levels["start"] = str((arr[0] as Dictionary).get("map", "")) if not arr.is_empty() else ""
	set_levels(levels, manifest_ref)

func _reorder_orders(arr: Array) -> void:
	for idx in arr.size():
		(arr[idx] as Dictionary)["order"] = idx + 1

## 填充关卡清单 UI；manifest 用于把地图名解析成文件路径做存在性检查
func set_levels(data: Dictionary, m: Dictionary = {}) -> void:
	levels = data.duplicate(true)
	manifest_ref = m
	var arr: Array = levels.get("levels", [])
	mode_opt.select(0 if str(levels.get("mode", "level_select")) == "metroidvania" else 1)
	start_opt.clear()
	var start := str(levels.get("start", ""))
	var start_idx := -1
	for i in arr.size():
		var map_name := str((arr[i] as Dictionary).get("map", ""))
		start_opt.add_item(map_name)
		start_opt.set_item_metadata(i, map_name)
		if map_name == start:
			start_idx = i
	if start_idx < 0:
		start_opt.add_item("（未设置）")
		start_opt.set_item_metadata(start_opt.item_count - 1, "")
		start_opt.select(start_opt.item_count - 1)
	elif start_opt.item_count > 0:
		start_opt.select(start_idx)
	level_list.clear()
	for lv in arr:
		var map_name2 := str((lv as Dictionary).get("map", ""))
		var display := str((lv as Dictionary).get("name", map_name2))
		var area := str((lv as Dictionary).get("area", ""))
		var exists := true
		if not manifest_ref.is_empty():
			var maps_dir := str(manifest_ref.get("_maps_dir", ""))
			var p := maps_dir.path_join(map_name2 + ".json") if maps_dir != "" else ""
			exists = p != "" and FileAccess.file_exists(p)
		var area_txt := "未分组" if area == "" else area
		var idx := level_list.add_item("%d.  %s   ·  %s%s" % [
			int((lv as Dictionary).get("order", 0)), display, area_txt,
			"" if exists else "   ⚠ 文件缺失"])
		level_list.set_item_tooltip(idx, "%s\n区域：%s\n文件：%s" % [
			map_name2, area_txt, "存在" if exists else "缺失"])
		level_list.set_item_metadata(idx, map_name2)
		if not exists:
			level_list.set_item_custom_fg_color(idx, Th.ERR)
	if arr.is_empty():
		var pi := level_list.add_item("（清单为空：点「+ 添加关卡」或「从地图文件生成清单」）")
		level_list.set_item_selectable(pi, false)

## 世界图：graph = LevelList.build_world_graph() 结果；unreachable 标红汇总
func set_world(graph: Dictionary, current_map_name := "", unreachable: Array = []) -> void:
	if world_view == null:
		return
	var nodes: Array = graph.get("nodes", [])
	if not unreachable.is_empty():
		nodes = nodes.duplicate(true)
		var bad := {}
		for nm in unreachable:
			bad[str(nm)] = true
		for nd in nodes:
			if bad.has(str((nd as Dictionary).get("map", ""))):
				(nd as Dictionary)["issues"] = int((nd as Dictionary).get("issues", 0)) + 1
	world_view.setup(nodes, graph.get("edges", []), current_map_name)
	if _world_hint:
		var nn := nodes.size()
		var ee: int = (graph.get("edges", []) as Array).size()
		var hint := "%d 图 · %d 连线" % [nn, ee]
		if not unreachable.is_empty():
			hint += "  ⚠ %d 不可达" % unreachable.size()
		_world_hint.text = hint
		_world_hint.add_theme_color_override("font_color",
			Th.ERR if not unreachable.is_empty() else Th.TEXT_MUTE)

## 用现有地图文件重建清单（会覆盖自定义 order/area/unlock——先确认）
func rebuild_from_maps() -> void:
	var cd := ConfirmationDialog.new()
	cd.title = "从地图文件生成清单"
	cd.dialog_text = "将按现有地图文件重建关卡清单，已设置的顺序/区域/解锁前置会被覆盖。继续？"
	cd.ok_button_text = "重建"
	cd.cancel_button_text = "取消"
	add_child(cd)
	cd.confirmed.connect(_do_rebuild_from_maps)
	cd.canceled.connect(func(): cd.queue_free())
	cd.popup_centered()

func _do_rebuild_from_maps() -> void:
	var arr: Array = LevelListScript.suggest_levels(manifest_ref)
	levels = {
		"mode": str(levels.get("mode", "level_select")),
		"start": str(levels.get("start", "")),
		"levels": arr,
	}
	if str(levels.get("start", "")) == "" and not arr.is_empty():
		levels["start"] = str((arr[0] as Dictionary).get("map", ""))
	set_levels(levels, manifest_ref)
