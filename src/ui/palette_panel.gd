extends RefCounted
## _palette_ctrl：左栏调色板控制器。
##
## 两类资产分两个列表（扫描语义跟 kind 走，见 asset_decl）：
##   瓦片列表  = assets[] 里 kind=scene / shape=tile 的图集：多图集先选图集 → 类别 → 瓦片
##   实体列表  = assets[] 里 kind=entity：有 thumb 用缩略图，没 thumb 按 visual 声明画占位
##
## 瓦片行的 metadata 一律带 `asset`（资产 id）与 `cell`（图集内切片坐标）；
## 画布落笔时用 asset id 查 source_id——磁盘数据也写 asset id，不再依赖清单数组序。

const AssetDecl := preload("res://src/assets/asset_decl.gd")
const EntityNodeRef := preload("res://src/canvas/entity_node.gd")

var app   # 宿主
var _cat := ""          # 当前视图："" = 类别视图；非空 = 资产视图（该类别名）
var _cats := []         # [{name, count}]，按首次出现顺序
var _atlas := 0         # 当前图集上下文；多图集时 -1 = 顶层图集列表
var _place_category := "tiles"  # tiles / images / entities

func _init(host) -> void:
	app = host

func set_category(cat: String) -> void:
	_place_category = cat
	if cat == "tiles":
		fill_tiles()
	else:
		fill_placeables(cat)

func current_category() -> String:
	return _place_category

func fill_all() -> void:
	_cat = ""
	_atlas = 0
	if _place_category == "tiles":
		fill_tiles()
	else:
		fill_placeables(_place_category)

## 刷新当前类别（切层/切分类/新建资产后都走这里，避免两条列表各自带旧 UI 状态）
func refresh_current() -> void:
	set_category(_place_category)

func fill_tiles() -> void:
	var tl: ItemList = app.tile_list
	# 重填前先清掉上一次的空状态覆盖，别让它盖住瓦片
	if tl.has_meta("_empty_node"):
		var old_empty = tl.get_meta("_empty_node")
		if is_instance_valid(old_empty):
			old_empty.queue_free()
		tl.remove_meta("_empty_node")
	tl.clear()
	var sets: Array = AssetDecl.tile_sets_placed(app.manifest)
	if sets.is_empty():
		_show_empty(tl, "清单没有瓦片图集", "在 assets[] 里声明 kind=scene / shape=tile 的资产")
		return
	if (app.canvas.atlas_imgs as Array).is_empty():
		app.canvas._build_tileset()   # 多图集 images/texs 就位
	# 停用/缺失图集会让可用列表变短：_atlas 越界就落回第一个，别在索引上崩
	if _atlas >= sets.size():
		_atlas = 0
	if sets.size() > 1:
		_fill_multi(tl, sets)
	else:
		_fill_single(tl, sets[0], 0)

## 多图集：顶层（_atlas == -1）= 图集列表；钻入后加返回行再进图集体
func _fill_multi(tl: ItemList, sets: Array) -> void:
	if _atlas < 0:
		_set_grid(tl, 1, 0)
		for i in sets.size():
			var t: Dictionary = sets[i]
			var n := str(t.get("name", "图集 %d" % i))
			var pal: Array = t.get("palette", [])
			var ii := tl.add_item("→ %s（%d）" % [n, pal.size()])
			tl.set_item_metadata(ii, {"atlas_pick": i})
		return
	var back := tl.add_item("← 返回图集列表")
	tl.set_item_metadata(back, {"back": true})
	_fill_single(tl, sets[_atlas], _atlas)

## 图集体渲染：单图集与多图集图集内共用（MRU 置顶 → 类别/全图 → 资产行）
func _fill_single(tl: ItemList, t: Dictionary, _ai: int) -> void:
	var aid := str(t.get("id", ""))
	var img := _img_for(aid)
	if img == null:
		_show_empty(tl, "图集读取失败", "检查 assets[].atlas 路径")
		return
	var pal: Array = t.get("palette", [])
	var fb := str(t.get("name", ""))
	_build_cats(pal, fb)
	if _cat != "":
		_set_grid(tl, 3, 56)
		var back2 := tl.add_item("← 返回类别")
		tl.set_item_metadata(back2, {"back": true})
		for p in pal:
			if _cat_of(p, fb) != _cat:
				continue
			var cell := Vector2i(int(p.cell[0]), int(p.cell[1]))
			var it := tl.add_item(str(p.get("name", "%d,%d" % [cell.x, cell.y])), _tex(aid, cell))
			tl.set_item_metadata(it, {"auto": false, "cell": cell, "asset": aid})
		return
	# 类别视图与 MRU 行是「一行一个名字」，用单列吃满宽度——用 3 列网格会被截成「→ 岩块…」
	_set_grid(tl, 1, 0)
	if pal.is_empty():
		# 没配 palette = 全图集平铺，那种视图必须是网格；MRU 行混进网格会被压成豆点，故跳过
		_set_grid(tl, 3, 56)
		_fill_full_atlas(tl, img, aid)
		return
	_add_mru_rows(tl)
	for c in _cats:
		var ii2 := tl.add_item("→ %s（%d）" % [str(c.name), int(c.count)])
		tl.set_item_metadata(ii2, {"cat": str(c.name)})

## 列布局切换：类别视图单列吃满，资产视图三列网格（v2 左栏 200px 下 4 列会溢出）
func _set_grid(tl: ItemList, cols: int, col_w: int) -> void:
	tl.max_columns = cols
	tl.fixed_column_width = col_w

## 点击路由：类别视图点类别 → 钻入；资产视图点返回行 → 回类别列表；点瓦片 → 原有选瓦片流程
func on_tile_click(i: int, at: Vector2, mb: int) -> void:
	var tl: ItemList = app.tile_list
	var md = tl.get_item_metadata(i)
	if md is Dictionary:
		if md.has("atlas_pick"):
			_atlas = int(md["atlas_pick"])
			_cat = ""
			fill_tiles()
			return
		if bool(md.get("back", false)):
			if _cat != "":
				_cat = ""
			elif AssetDecl.tile_sets_placed(app.manifest).size() > 1:
				_atlas = -1
			fill_tiles()
			return
		if str(md.get("cat", "")) != "":
			_cat = str(md.get("cat"))
			fill_tiles()
			return
	app._on_tile_pick(i, at, mb)

## 类别统计（首次出现顺序；无 cat 用图集条目名兜底，再退「未分类」）
func _build_cats(pal: Array, fb: String) -> void:
	_cats = []
	var seen := {}
	for p in pal:
		var cn := _cat_of(p, fb)
		if not seen.has(cn):
			seen[cn] = {"name": cn, "count": 0}
			_cats.append(seen[cn])
		seen[cn].count = int(seen[cn].count) + 1

## 类别名：条目的 cat 字段优先；无 cat 用图集条目名（一个图集 = 一个默认类别）
func _cat_of(p: Dictionary, fb: String) -> String:
	var cn := str(p.get("cat", ""))
	if cn == "":
		return fb if fb != "" else "未分类"
	return cn

## 图集图（按资产 id 取图；未建则兜底构建；未知资产返回 null）
func _img_for(aid: String) -> Image:
	var sid: int = app.canvas.source_of_asset(aid)
	if sid < 0:
		app.canvas._build_tileset()
		sid = app.canvas.source_of_asset(aid)
	var imgs: Array = app.canvas.atlas_imgs
	if sid < 0 or sid >= (imgs as Array).size():
		return null
	return imgs[sid] as Image

## D7：瓦片缩略纹理缓存（资产 id + cell → ImageTexture），类别切换不再逐格重建
var _tex_cache := {}

func _tex(aid: String, cell: Vector2i) -> ImageTexture:
	var key := "%s:%d,%d" % [aid, cell.x, cell.y]
	var hit = _tex_cache.get(key, null)
	if hit != null:
		return hit as ImageTexture
	var img := _img_for(aid)
	if img == null:
		return null
	var cs: Vector2i = AssetDecl.cell_size(app.manifest, aid)
	var reg := img.get_region(Rect2i(cell.x * cs.x, cell.y * cs.y, cs.x, cs.y))
	reg.resize(44, 44, Image.INTERPOLATE_NEAREST)
	var t := ImageTexture.create_from_image(reg)
	_tex_cache[key] = t
	return t

## 全图集模式（清单没配 palette）：每个格子都是瓦片；metadata 带 asset 供落笔
func _fill_full_atlas(tl: ItemList, img: Image, aid: String) -> void:
	var cs: Vector2i = AssetDecl.cell_size(app.manifest, aid)
	var cols := int(img.get_width() / float(cs.x))
	var rows := int(img.get_height() / float(cs.y))
	for y in rows:
		for x in cols:
			if Vector2i(x, y) == EditorCanvas.INVISIBLE_CELL:
				continue
			var i2 := tl.add_item("%d,%d" % [x, y], _tex(aid, Vector2i(x, y)))
			tl.set_item_metadata(i2, {"auto": false, "cell": Vector2i(x, y), "asset": aid})

## 最近使用置顶（键 "资产id:x,y"——多图集瓦片原样回放）
func _add_mru_rows(tl: ItemList) -> void:
	if app.tile_mru.is_empty():
		return
	var hdr := tl.add_item("🕐 最近使用", null)
	tl.set_item_metadata(hdr, {"mru": true})
	for key_v in app.tile_mru:
		var parts := str(key_v).split(":")
		if (parts as PackedStringArray).size() != 2:
			continue
		var xy := str(parts[1]).split(",")
		if (xy as PackedStringArray).size() != 2:
			continue
		var aid := str(parts[0])
		var cellm := Vector2i(int(xy[0]), int(xy[1]))
		var imgm := _img_for(aid)
		if imgm == null:
			continue
		var itm := tl.add_item("", _tex(aid, cellm))
		tl.set_item_metadata(itm, {"auto": false, "cell": cellm, "asset": aid})

## 实体调色板：全部 kind=entity 的资产。
## 图片列表：kind=scene / shape=image 的摆放物；缩略图取 texture 声明。
func fill_placeables(cat: String) -> void:
	var el: ItemList = app.ent_list
	el.clear()
	var thumbs: Dictionary = app._entity_thumbs()
	var shown := 0
	if cat == "images":
		for a in AssetDecl.of_kind_placed(app.manifest, "scene"):
			var d: Dictionary = a
			if str(d.get("shape", "")) != "image":
				continue
			var eid := str(d.get("id", ""))
			var tex: Texture2D = EntityNodeRef.texture_of(app.manifest, str(d.get("texture", "")))
			if tex == null:
				tex = thumbs.get(eid, null)
			if tex == null:
				tex = _visual_icon(d)
			# E3：显示名与类别取共用查询（AssetDecl.label），与资产图鉴同一口径
			var ie := el.add_item(AssetDecl.label(app.manifest, eid), tex)
			el.set_item_tooltip(ie, "%s · %s" % [AssetDecl.category_of(app.manifest, eid), eid])
			el.set_item_metadata(ie, eid)
			shown += 1
	else:
		for a in AssetDecl.of_kind_placed(app.manifest, "entity"):
			var ad: Dictionary = a
			var eid := str(ad.get("id", ""))
			var tex: Texture2D = thumbs.get(eid, null)
			if tex == null:
				tex = _visual_icon(ad)
			# E3：显示名与类别取共用查询（AssetDecl.label），与资产图鉴同一口径
			var ie := el.add_item(AssetDecl.label(app.manifest, eid), tex)
			var tip := "%s · %s" % [AssetDecl.category_of(app.manifest, eid), eid]
			if bool(ad.get("builtin", false)):
				tip += "\n内置种类：画布上按 visual 声明呈现"
			el.set_item_tooltip(ie, tip)
			el.set_item_metadata(ie, eid)
			shown += 1
	if shown == 0:
		_show_empty(el,
			"清单没有图片资产" if cat == "images" else "清单没有实体资产",
			"在 assets[] 里声明 kind=scene / shape=image" if cat == "images" else "在 assets[] 里声明 kind=entity")

func fill_entities() -> void:
	fill_placeables("entities")

## visual 声明 → 占位图标（rect 画成色块；sprite/none 或缺失时画中性灰框）。
## 缓存：同一 visual 的图标只画一次。
var _icon_cache := {}

func _visual_icon(ad: Dictionary) -> Texture2D:
	var vis = ad.get("visual", null)
	var key := JSON.stringify(vis)
	if _icon_cache.has(key):
		return _icon_cache[key]
	var col := Color(0.55, 0.6, 0.68, 0.9)
	var alpha := 0.9
	if vis is Dictionary:
		var cs := str((vis as Dictionary).get("color", ""))
		if cs != "":
			col = Color(cs)
		alpha = float((vis as Dictionary).get("alpha", 0.9))
	col.a = alpha
	var img := Image.create(44, 44, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	# 内缩 3px 画实心块 + 描边，即使是半透明也看得清边界
	img.fill_rect(Rect2i(3, 3, 38, 38), col)
	var edge := col
	edge.a = minf(1.0, alpha + 0.35)
	img.fill_rect(Rect2i(3, 3, 38, 1), edge)
	img.fill_rect(Rect2i(3, 40, 38, 1), edge)
	img.fill_rect(Rect2i(3, 3, 1, 38), edge)
	img.fill_rect(Rect2i(40, 3, 1, 38), edge)
	var tex := ImageTexture.create_from_image(img)
	_icon_cache[key] = tex
	return tex

## 列表空状态覆盖（遮罩挂在列表上层，连接一次防重复）
## E3：连接的回调读**当前**登记的遮罩（不是建连接时闭包里的那个节点）——
## 每次 fill 都会换新遮罩，旧闭包会抱着已释放的节点（U05）。
func _show_empty(list: ItemList, title: String, hint := "") -> void:
	var holder := list.get_parent()
	if list.has_meta("_empty_node"):
		var old = list.get_meta("_empty_node")
		if is_instance_valid(old):
			old.queue_free()
	var es: VBoxContainer = app.UiKitScript.empty_state("▦", title, hint)
	es.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(es)
	es.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	es.visible = list.is_visible_in_tree()
	list.set_meta("_empty_node", es)
	if not list.has_meta("_empty_connected"):
		list.set_meta("_empty_connected", true)
		list.visibility_changed.connect(func(): _sync_empty_overlay(list))

## 空态遮罩的显隐跟随所属列表的可见性（按当前登记的遮罩节点取值）。
func _sync_empty_overlay(list: ItemList) -> void:
	if list == null or not is_instance_valid(list) or not list.has_meta("_empty_node"):
		return
	var es = list.get_meta("_empty_node")
	if is_instance_valid(es):
		es.visible = list.is_visible_in_tree()
