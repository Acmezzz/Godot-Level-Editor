extends VBoxContainer
## T20（批次 10）：清单管理界面——bgGroups 图层表 + items 表，替代手工编辑 JSON。
## 注入模式与 asset_panel 一致：manifest 字典 + save_manifest 回调 + 宿主 app。

signal closed

const Kit := preload("res://src/ui/ui_kit.gd")
const Th := preload("res://src/ui/ui_theme.gd")

var manifest := {}
var save_manifest: Callable
var host = null

var _grp_opt: OptionButton
var _layers_box: VBoxContainer
var _items_box: VBoxContainer

func build() -> void:
	add_theme_constant_override("separation", 8)
	# 顶栏由项目页外壳统一提供（返回/标题/保存），本面板只做清单内容本体；
	# 外层滚动由 project_shell 的「清单」视图提供（与下段的关卡/世界共用一条滚动）。
	var col := Kit.vbox(8)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(col)
	_col_root = col
	_build_bg_section()
	_build_items_section()
	# 建完立刻填充：此前组下拉与物品表只有打开后才会有内容（空表误导）
	_reload_groups("")
	_load_items()

var _col_root: VBoxContainer

## 重建整页（切换进清单视图时调用，确保读到最新的 manifest 内存状态）
func refresh() -> void:
	if _col_root == null:
		return
	_reload_groups(_cur_group())
	_load_items()

## —— 背景图组编辑（系数/色/z 是逐层试出来的活，表单比手改 JSON 快一个量级） ——
func _build_bg_section() -> void:
	_col_root.add_child(Kit.section_header("背景图组"))
	_grp_opt = OptionButton.new()
	_grp_opt.item_selected.connect(func(_i: int): _load_group_layers())
	var grow := Kit.hbox(8)
	grow.add_child(Kit.text_label("组", Th.TEXT_MUTE, Th.FS_SMALL))
	grow.add_child(_grp_opt)
	grow.add_child(Kit.button("+ 新建组", _new_group, "ghost"))
	grow.add_child(Kit.button("重命名组", _rename_group, "ghost"))
	grow.add_child(Kit.button("删除组", _del_group, "ghost"))
	_col_root.add_child(grow)
	# 列头（P0-3）：7 个裸输入框没有表头时没人知道哪列是 scale-x 还是 z
	var hdr := Kit.hbox(6)
	hdr.add_child(_hcell("图层图片", 200))
	hdr.add_child(_hcell("scale-x", 76))
	hdr.add_child(_hcell("scale-y", 76))
	hdr.add_child(_hcell("z", 62))
	hdr.add_child(_hcell("alpha", 70))
	hdr.add_child(_hcell("镜像", 60))
	_col_root.add_child(hdr)
	_layers_box = Kit.vbox(4)
	_col_root.add_child(_layers_box)
	var btm := Kit.hbox(6)
	btm.add_child(Kit.button("+ 图层", _add_layer, "ghost"))
	btm.add_child(Kit.spacer())
	_col_root.add_child(btm)

func _hcell(text: String, w: int) -> Label:
	var l := Kit.text_label(text, Th.TEXT_MUTE, Th.FS_META)
	l.custom_minimum_size = Vector2(w, 0)
	return l

## 重命名当前组：只改 key，图层数据原样迁移；引用该组的地图不改（groups 名是清单内部键）
func _rename_group() -> void:
	var old := _cur_group()
	if old == "":
		return
	var shell: Dictionary = Kit.popup_shell("重命名背景图组", "只改组名；组内图层原样保留。用到该组的地图引用需自行同步。", host)
	var pop: PopupPanel = shell.pop
	var edit := LineEdit.new()
	edit.text = old
	edit.custom_minimum_size = Vector2(240, 0)
	shell.body.add_child(edit)
	var apply := func():
		var next := edit.text.strip_edges()
		pop.hide()
		if next == "" or next == old:
			return
		var groups: Dictionary = manifest.get("bgGroups", {})
		if groups.has(next):
			if host != null and host.has_method("_set_status"):
				host._set_status("组名 %s 已存在" % next)
			return
		groups[next] = groups[old]
		groups.erase(old)
		manifest["bgGroups"] = groups
		_reload_groups(next)
	shell.body.add_child(Kit.popup_buttons(apply, func(): pop.hide()))
	edit.text_submitted.connect(func(_t: String): apply.call())
	host._open_popup(pop)
## 删除当前组（图层会一起消失，需确认）
func _del_group() -> void:
	var gname := _cur_group()
	if gname == "":
		return
	var groups: Dictionary = manifest.get("bgGroups", {})
	var n: int = (groups.get(gname, {}).get("layers", []) as Array).size()
	var cd := ConfirmationDialog.new()
	cd.title = "删除背景图组"
	cd.dialog_text = "将删除组 %s 及其 %d 个图层（保存清单后生效），不可撤销。" % [gname, n]
	cd.ok_button_text = "删除"
	cd.cancel_button_text = "取消"
	add_child(cd)
	cd.confirmed.connect(func():
		groups.erase(gname)
		manifest["bgGroups"] = groups
		_reload_groups("")
		cd.queue_free())
	cd.canceled.connect(func(): cd.queue_free())
	cd.popup_centered()

func _cur_group() -> String:
	return str(_grp_opt.get_item_text(_grp_opt.selected)) if _grp_opt != null and _grp_opt.item_count > 0 and _grp_opt.selected >= 0 else ""

func _new_group() -> void:
	var groups: Dictionary = manifest.get("bgGroups", {})
	var nm := "group_%d" % (groups.size() + 1)
	while groups.has(nm):
		nm = "group_%d" % (int(nm.split("_")[1]) + 1)
	groups[nm] = {"layers": []}
	manifest["bgGroups"] = groups
	_reload_groups(nm)

func _reload_groups(sel := "") -> void:
	_grp_opt.clear()
	var groups: Dictionary = manifest.get("bgGroups", {})
	for k in groups.keys():
		_grp_opt.add_item(str(k))
	# 空组列表时 select(0) 会报 out of bounds——显式跳过
	if _grp_opt.item_count == 0:
		_load_group_layers()
		return
	var idx := 0
	for i in _grp_opt.item_count:
		if _grp_opt.get_item_text(i) == sel:
			idx = i
	_grp_opt.select(idx)
	_load_group_layers()

func _load_group_layers() -> void:
	for c in _layers_box.get_children():
		(c as Node).free()
	var gname := _cur_group()
	if gname == "":
		# 完全没有组时也要说明下一步，否则列头下面一片空白
		_layers_box.add_child(Kit.text_label("（还没有背景图组，点「+ 新建组」新建）",
			Th.TEXT_MUTE, Th.FS_SMALL))
		return
	var layers: Array = (manifest.get("bgGroups", {}) as Dictionary).get(gname, {}).get("layers", [])
	if layers.is_empty():
		_layers_box.add_child(Kit.text_label("（这个组还没有图层，点「+ 图层」新增）",
			Th.TEXT_MUTE, Th.FS_SMALL))
	for lay in layers:
		if lay is Dictionary:
			_layers_box.add_child(_row_for_layer(lay))

func _add_layer() -> void:
	var gname := _cur_group()
	if gname == "":
		return
	var groups: Dictionary = manifest.get("bgGroups", {})
	var layers: Array = (groups.get(gname, {}) as Dictionary).get("layers", [])
	layers.append({"img": "", "scale": [0.3, 0.1], "z": -8, "tint": [1.0, 1.0, 1.0], "alpha": 1.0, "mirror": true})
	_load_group_layers()

## 单层编辑行：控件直接改 lay 字典（保存按钮统一写盘）
func _row_for_layer(lay: Dictionary) -> HBoxContainer:
	var row := Kit.hbox(6)
	var img := LineEdit.new()
	img.text = str(lay.get("img", ""))
	img.custom_minimum_size = Vector2(200, 0)
	img.text_changed.connect(func(t: String): lay["img"] = t)
	row.add_child(img)
	row.add_child(_spin(lay, "scale", 0, 0.05))
	row.add_child(_spin(lay, "scale", 1, 0.05))
	row.add_child(_spin(lay, "z", 0, 1))
	row.add_child(_spin(lay, "alpha", 0, 0.05))
	var mk := CheckBox.new()
	mk.button_pressed = bool(lay.get("mirror", true))
	mk.tooltip_text = "镜像平铺"
	mk.toggled.connect(func(on: bool): lay["mirror"] = on)
	row.add_child(mk)
	row.add_child(Kit.del_button(func(): _del_layer(lay), "删除这个背景图层"))
	return row

func _del_layer(lay: Dictionary) -> void:
	var gname := _cur_group()
	if gname == "":
		return
	var layers: Array = (manifest.get("bgGroups", {}) as Dictionary).get(gname, {}).get("layers", [])
	layers.erase(lay)
	_load_group_layers()

## 数值微调：值变化直接写回 lay 字典对应槽位
func _spin(lay: Dictionary, key: String, idx: int, step: float) -> SpinBox:
	var sp := SpinBox.new()
	if key == "scale":
		sp.min_value = 0.0
		sp.max_value = 2.0
		sp.step = step
		var arr: Array = lay.get("scale", [0.3, 0.1])
		sp.value = clampf(float(arr[idx]) if (arr as Array).size() > idx else 0.3, 0.0, 2.0)
		sp.value_changed.connect(func(v: float):
			var a2: Array = lay.get("scale", [0.3, 0.1])
			while (a2 as Array).size() < 2:
				a2.append(0.1)
			a2[idx] = v
			lay["scale"] = a2)
		return sp
	if key == "z":
		sp.min_value = -40.0
		sp.max_value = 40.0
		sp.step = 1.0
		sp.value = float(int(lay.get("z", -8)))
		sp.value_changed.connect(func(v: float): lay["z"] = int(v))
		return sp
	if key == "alpha":
		sp.min_value = 0.0
		sp.max_value = 1.0
		sp.step = step
		sp.value = clampf(float(lay.get("alpha", 1.0)), 0.0, 1.0)
		sp.value_changed.connect(func(v: float): lay["alpha"] = v)
		return sp
	return sp

## —— items（商店物品）简表：id/name 增删 ——
func _build_items_section() -> void:
	_col_root.add_child(Kit.divider())
	_col_root.add_child(Kit.section_header("商店物品（items）"))
	var ih := Kit.hbox(6)
	ih.add_child(_hcell("id", 140))
	ih.add_child(_hcell("显示名", 200))
	_col_root.add_child(ih)
	_items_box = Kit.vbox(4)
	_col_root.add_child(_items_box)
	var ib := Kit.hbox(6)
	ib.add_child(Kit.button("+ 物品", _add_item, "ghost"))
	ib.add_child(Kit.spacer())
	_col_root.add_child(ib)

func _add_item() -> void:
	var items: Array = manifest.get("items", [])
	items.append({"id": "item_%d" % (items.size() + 1), "name": ""})
	manifest["items"] = items
	_load_items()

func _load_items() -> void:
	for c in _items_box.get_children():
		(c as Node).free()
	var items: Array = manifest.get("items", [])
	if items.is_empty():
		_items_box.add_child(Kit.text_label("（还没有商店物品，点「+ 物品」新增）",
			Th.TEXT_MUTE, Th.FS_SMALL))
	for it in items:
		if it is Dictionary:
			_items_box.add_child(_item_row(it))

func _item_row(it: Dictionary) -> HBoxContainer:
	var row := Kit.hbox(6)
	var id_le := LineEdit.new()
	id_le.text = str(it.get("id", ""))
	id_le.custom_minimum_size = Vector2(140, 0)
	id_le.text_changed.connect(func(t: String): it["id"] = t)
	row.add_child(id_le)
	var nm_le := LineEdit.new()
	nm_le.text = str(it.get("name", ""))
	nm_le.custom_minimum_size = Vector2(200, 0)
	nm_le.text_changed.connect(func(t: String): it["name"] = t)
	row.add_child(nm_le)
	row.add_child(Kit.button("删", func(): _del_item(it), "plain"))
	return row

func _del_item(it: Dictionary) -> void:
	var items: Array = manifest.get("items", [])
	items.erase(it)
	_load_items()

## 保存：改动一直接写在 manifest 字典里，这里统一提交写盘
func _save_all() -> void:
	save_manifest.call()
	if host != null and host.has_method("_set_status"):
		host._set_status("清单已保存（bgGroups/items 写回 editor_manifest.json）")
