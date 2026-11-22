extends RefCounted
## TileReplaceDialog：按当前区域选区批量替换瓦片（E2）。宿主 = app。
##
## 流程：选区（瓦片/碰撞层框选，_region_sel）→ 选源资产（选区里出现的图集）与目标资产／切片
## → 预览「替换几格 / 冲突几格」→ 应用 = 一笔撤销快照 + 逐格写（含变换位保留）。
## 冲突（目标图集表达不了原变换）先列出，不写那些格——绝不半截替换。

const TileReplace := preload("res://src/canvas/tile_replace.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")
const TilesetCache := preload("res://src/canvas/tileset_cache.gd")
const Kit := preload("res://src/ui/ui_kit.gd")

var app

func _init(a) -> void:
	app = a

## 打开替换弹窗。要求已有区域选区与瓦片资产。
func open() -> void:
	if app.canvas == null or not app.map_loaded:
		app._set_status("无地图：先新建或打开一张地图")
		return
	var sel: Rect2i = app.canvas._region_sel
	if sel.size.x <= 0 or sel.size.y <= 0:
		app._set_status(" 先框选一块区域（瓦片层左键拖动或 Ctrl+拖动），再替换瓦片")
		return
	# 选区里出现过的瓦片资产 = 源候选（只替换用户看得到的那一类，不误伤其它瓦片）
	var src_ids: Array = []
	for it in TileReplace.collect(app.canvas, sel, ""):
		var aid: String = str(app.canvas.asset_of_source(int((it as Dictionary).get("src", -1))))
		if aid != "" and not src_ids.has(aid):
			src_ids.append(aid)
	if src_ids.is_empty():
		app._set_status(" 选区里没有瓦片可替换（只对瓦片层生效）")
		return
	var shell: Dictionary = app._popup_body("批量替换瓦片",
		"选区 %d×%d：只替换选中源资产的格；目标图集表达不了的格先列冲突。" % [sel.size.x, sel.size.y])
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var src_opt := OptionButton.new()
	for si in src_ids:
		src_opt.add_item("%s（%s）" % [AssetDecl.label(app.manifest, str(si)), str(si)])
		src_opt.set_item_metadata(src_opt.item_count - 1, str(si))
	body.add_child(Kit.field_row("源资产", src_opt, 56))
	var dst_opt := OptionButton.new()
	for t in AssetDecl.tile_sets_placed(app.manifest):
		var d: Dictionary = t
		var aid2 := str(d.get("id", ""))
		dst_opt.add_item(str(d.get("name", aid2)), dst_opt.item_count)
		dst_opt.set_item_metadata(dst_opt.item_count - 1, aid2)
	body.add_child(Kit.field_row("目标资产", dst_opt, 56))
	var keep_src := CheckBox.new()
	keep_src.text = "保持源切片坐标（不换图集格）"
	keep_src.button_pressed = true
	body.add_child(keep_src)
	var cell_opt := OptionButton.new()
	cell_opt.disabled = true
	body.add_child(Kit.field_row("目标切片", cell_opt, 56))
	var info: Label = Kit.hint_label("", 320)
	body.add_child(info)
	var apply_btn: Button = Kit.button("替换", Callable(), "primary")
	apply_btn.disabled = true
	# 当前计划与目标资产（应用时一并取走；计划本身不塞 UI 上下文）
	var cur := {"plan": {}, "dst": ""}

	# 目标切片选项重建：palette 条目；未配 palette = 「与源同坐标」（由 keep_src 决定）
	var rebuild_cells := func(dst_id: String):
		cell_opt.clear()
		var pal: Array = AssetDecl.palette_of(app.manifest, dst_id)
		if pal.is_empty():
			cell_opt.add_item("整图平铺（与源同坐标）")
			cell_opt.set_item_metadata(0, Vector2i(-1, -1))
		else:
			for p in pal:
				var pe: Dictionary = p
				var cc: Vector2i = pe.get("cell", Vector2i.ZERO)
				cell_opt.add_item("%s（%d,%d）" % [str(pe.get("name", "")), cc.x, cc.y])
				cell_opt.set_item_metadata(cell_opt.item_count - 1, cc)
		cell_opt.select(0)

	var refresh := func():
		var src_id := str(src_opt.get_item_metadata(src_opt.selected)) if src_opt.selected >= 0 else ""
		var dst_id := str(dst_opt.get_item_metadata(dst_opt.selected)) if dst_opt.selected >= 0 else ""
		cur = {"plan": {}, "dst": ""}
		apply_btn.disabled = true
		if src_id == "" or dst_id == "" or src_id == dst_id:
			info.text = "选源与目标资产（不能相同）。" if src_id == dst_id else "选源与目标资产。"
			return
		var dst_cell := Vector2i(-1, -1)
		if not keep_src.button_pressed and cell_opt.selected >= 0:
			var md = cell_opt.get_item_metadata(cell_opt.selected)
			if md is Vector2i:
				dst_cell = md
		var cells: Array = TileReplace.collect(app.canvas, sel, src_id)
		var plan: Dictionary = TileReplace.plan(app.manifest, cells, dst_id, dst_cell)
		cur = {"plan": plan, "dst": dst_id}
		var ok_n: int = (plan.get("cells", []) as Array).size()
		var conflicts: Array = plan.get("conflicts", [])
		info.text = "可替换 %d 格" % ok_n
		if not conflicts.is_empty():
			var parts: Array[String] = []
			for i in mini(conflicts.size(), 6):
				var cf: Dictionary = conflicts[i]
				var cc2: Vector2i = cf.get("c", Vector2i.ZERO)
				parts.append("(%d,%d) %s" % [cc2.x, cc2.y, str(cf.get("why", ""))])
			if conflicts.size() > 6:
				parts.append("… 共 %d 条" % conflicts.size())
			info.text += "\n⚠ 冲突 %d 格（不替换）：\n%s" % [conflicts.size(), "\n".join(parts)]
		apply_btn.disabled = ok_n == 0

	src_opt.item_selected.connect(func(_i: int): refresh.call())
	dst_opt.item_selected.connect(func(_i: int):
		rebuild_cells.call(str(dst_opt.get_item_metadata(dst_opt.selected)))
		refresh.call())
	cell_opt.item_selected.connect(func(_i: int): refresh.call())
	keep_src.toggled.connect(func(_v: bool):
		cell_opt.disabled = keep_src.button_pressed
		refresh.call())
	body.add_child(Kit.popup_buttons(func():
		pop.hide()
		_apply(cur.plan, str(cur.dst)), func(): pop.hide(), "替换", "取消"))
	rebuild_cells.call(str(dst_opt.get_item_metadata(dst_opt.selected)))
	refresh.call()
	app._open_popup(pop)

## 应用计划：锁定检查 → 一笔撤销 → 逐格写（保留 alt）→ 标脏。
## 失败格（图层已不存在 / 目标资产不可用）逐项计数，不吞掉。
func _apply(plan: Dictionary, dst_asset: String) -> void:
	var cells: Array = plan.get("cells", [])
	if cells.is_empty() or dst_asset == "":
		app._set_status(" 没有可替换的格")
		return
	if app.canvas._any_layer_locked():
		app._set_status(" 有图层处于锁定状态：解锁后再替换瓦片")
		return
	var src: int = app.canvas.source_of_asset(dst_asset)
	if src < 0:
		app._set_status(" 替换失败：目标资产没有可用图集（图集文件缺失？）")
		return
	app.canvas._push_undo()
	var n := 0
	var missing := 0
	for it in cells:
		var e: Dictionary = it
		var li: int = app.canvas._layer_index_of(str(e.get("layer", "")))
		if li < 0:
			missing += 1
			continue
		TilesetCache.set_cell_alt(app.canvas.layer_tiles[li] as TileMapLayer,
			e.get("c", Vector2i.ZERO) as Vector2i, src,
			e.get("atlas", Vector2i.ZERO) as Vector2i, int(e.get("alt", 0)))
		n += 1
	app.canvas._mark_tiles()   # P01：只动地形瓦片，碰撞/实体集都没变
	app.canvas.queue_redraw()
	app._set_status("已替换 %d 格瓦片%s（Ctrl+Z 撤销）" % [n,
		("，%d 格因图层缺失跳过" % missing) if missing > 0 else ""])
