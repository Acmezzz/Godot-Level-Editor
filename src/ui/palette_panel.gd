extends RefCounted
## _palette_ctrl：左栏调色板控制器（瓦片两级导航：类别视图 → 资产视图）。
## 类别优先取清单 palette 条目的 "cat" 字段；无 cat 用图集条目名；都没有 → 「未分类」。

var app   # 宿主
var _cat := ""          # 当前视图："" = 类别视图；非空 = 资产视图（该类别名）
var _decor_filled := false # 上次填表时是否处于装饰层（层切换时触发重填）
var _cats := []         # [{name, count}]，按首次出现顺序
var _atlas := 0         # 批次 9：当前图集上下文；多图集时 -1 = 顶层图集列表

func _init(host) -> void:
	app = host

func fill_all() -> void:
	_cat = ""
	_atlas = 0
	fill_tiles()
	fill_entities()

## 瓦片调色板：多图集 → 图集级导航；单图集行为不变。
## 装饰层没有独立资产清单，不该显示地形图集的东西——清空并给提示。
func fill_tiles() -> void:
	var tl: ItemList = app.tile_list
	# 切层重填前先清掉上一次的空状态覆盖，别让它盖住瓦片
	if tl.has_meta("_empty_node"):
		var old_empty = tl.get_meta("_empty_node")
		if is_instance_valid(old_empty):
			old_empty.queue_free()
		tl.remove_meta("_empty_node")
	tl.clear()
	_decor_filled = _on_decor_layer()
	if _decor_filled:
		_show_empty(tl, "装饰层未配置资产", "清单里给装饰层配好独立图集后，瓦片会出现在这里")
		return
	var tiles: Array = app.manifest.get("tiles", [])
	if tiles.is_empty():
		_show_empty(tl, "清单未定义瓦片")
		return
	var tsz := int(app.manifest.get("tileSize", 16))
	if (app.canvas.atlas_imgs as Array).is_empty():
		app.canvas._build_tileset()   # 批次 9：多图集 images/texs 就位
	if tiles.size() > 1:
		_fill_multi(tl, tiles, tsz)
	else:
		_fill_single(tl, tiles[0], 0, tsz)

## 层切换时同步装饰层视图：fill 只在启动/建图时跑一次，装饰↔地形切换靠这里触发重填。
func sync_layer_view() -> void:
	var now := _on_decor_layer()
	if now != _decor_filled:
		fill_tiles()

## 当前是否在装饰层：层 id 或层名标识为 decor/装饰（清单驱动，无清单回退 false）
func _on_decor_layer() -> bool:
	var layers: Array = app.manifest.get("layers", [])
	var i := 0
	if app.canvas != null and is_instance_valid(app.canvas):
		i = app.canvas.active_layer
	if i < 0 or i >= layers.size():
		return false
	var lay: Dictionary = layers[i]
	var idn := str(lay.get("id", ""))
	var nm := str(lay.get("name", ""))
	return idn == "decor" or idn.begins_with("decor") or nm == "装饰"

## 多图集：顶层（_atlas == -1）= 图集列表；钻入后加返回行再进图集体
func _fill_multi(tl: ItemList, tiles: Array, tsz: int) -> void:
	if _atlas < 0:
		_set_grid(tl, 1, 0)
		for i in tiles.size():
			var t: Dictionary = tiles[i]
			var n := str(t.get("name", "图集 %d" % i))
			var pal: Array = t.get("palette", [])
			var ii := tl.add_item("→ %s（%d）" % [n, pal.size()])
			tl.set_item_metadata(ii, {"atlas_pick": i})
		return
	var back := tl.add_item("← 返回图集列表")
	tl.set_item_metadata(back, {"back": true})
	_fill_single(tl, tiles[_atlas], _atlas, tsz)

## 图集体渲染：单图集与多图集图集内共用（MRU 置顶 → 类别/全图 → 资产行）
func _fill_single(tl: ItemList, t: Dictionary, ai: int, tsz: int) -> void:
	var img := _img_for(ai)
	if img == null:
		_show_empty(tl, "图集读取失败", "检查清单 tiles[].atlas 路径")
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
			var it := tl.add_item(str(p.get("name", "%d,%d" % [cell.x, cell.y])), _tex(ai, cell, tsz))
			tl.set_item_metadata(it, {"auto": false, "cell": cell, "atlas": ai})
		return
	# 类别视图与 MRU 行是「一行一个名字」，用单列吃满宽度——用 3 列网格会被截成「→ 岩块…」
	_set_grid(tl, 1, 0)
	if pal.is_empty():
 # 没配 palette = 全图集平铺，那种视图必须是网格；MRU 行混进网格会被压成豆点，故跳过
		_set_grid(tl, 3, 56)
		_fill_full_atlas(tl, img, tsz, ai)
		return
	_add_mru_rows(tl, tsz)
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
			elif (app.manifest.get("tiles", []) as Array).size() > 1:
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

## 图集图（按索引取图；未建则兜底构建；超界回落 0）
func _img_for(ai: int) -> Image:
	var imgs: Array = app.canvas.atlas_imgs
	if (imgs as Array).is_empty():
		app.canvas._build_tileset()
		imgs = app.canvas.atlas_imgs
	if ai < 0 or ai >= (imgs as Array).size():
		ai = 0
	return imgs[ai] as Image

## D7：瓦片缩略纹理缓存（图集索引+cell → ImageTexture），类别切换不再逐格重建
var _tex_cache := {}

func _tex(ai: int, cell: Vector2i, tsz: int) -> ImageTexture:
	var key := "%d:%d,%d" % [ai, cell.x, cell.y]
	var hit = _tex_cache.get(key, null)
	if hit != null:
		return hit as ImageTexture
	var img := _img_for(ai)
	if img == null:
		return null
	var reg := img.get_region(Rect2i(cell.x * tsz, cell.y * tsz, tsz, tsz))
	reg.resize(44, 44, Image.INTERPOLATE_NEAREST)
	var t := ImageTexture.create_from_image(reg)
	_tex_cache[key] = t
	return t

## 全图集模式（清单没配 palette）：每个格子都是瓦片；metadata 带 atlas 供落笔
func _fill_full_atlas(tl: ItemList, img: Image, tsz: int, ai: int) -> void:
	var cols := int(img.get_width() / float(tsz))
	var rows := int(img.get_height() / float(tsz))
	for y in rows:
		for x in cols:
			if Vector2i(x, y) == EditorCanvas.INVISIBLE_CELL:
				continue
			var i2 := tl.add_item("%d,%d" % [x, y], _tex(ai, Vector2i(x, y), tsz))
			tl.set_item_metadata(i2, {"auto": false, "cell": Vector2i(x, y), "atlas": ai})

## 最近使用置顶（键 "atlas:x,y"——多图集瓦片原样回放）
func _add_mru_rows(tl: ItemList, tsz: int) -> void:
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
		var cellm := Vector2i(int(xy[0]), int(xy[1]))
		var imgm := _img_for(int(parts[0]))
		if imgm == null:
			continue
		var itm := tl.add_item("", _tex(int(parts[0]), cellm, tsz))
		tl.set_item_metadata(itm, {"auto": false, "cell": cellm, "atlas": int(parts[0])})

## 实体调色板（无分类，行为与旧版一致）
## 内置种类（trigger_zone）没有缩略图，也要出现在这里——否则画布上根本放不出来。
func fill_entities() -> void:
	var el: ItemList = app.ent_list
	el.clear()
	var shown := 0
	var BuiltinKinds := preload("res://src/content/builtin_kinds.gd")
	var thumbs: Dictionary = app._entity_thumbs()
	for e in app.manifest.get("entities", []):
		var eid := str(e.get("id", ""))
		var tex: Texture2D = thumbs.get(eid, null)
		var builtin := BuiltinKinds.is_builtin(eid)
		if tex == null and not builtin:
			continue
		var ie := el.add_item(str(e.get("name", eid)), tex)
		if builtin:
			el.set_item_tooltip(ie, "内置种类：画布上以矩形呈现，尺寸由游戏侧声明提供")
		el.set_item_metadata(ie, eid)
		shown += 1
	if shown == 0:
		_show_empty(el, "清单没有带预览图的实体", "在编辑器清单里给实体配 thumb")

## 调色板空状态覆盖（自 app._show_palette_empty 迁移）
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
	list.set_meta("_empty_node", es)
	# D8：连接一次并打标——每次 fill 重复连接会越积越多
	if not list.has_meta("_empty_connected"):
		list.set_meta("_empty_connected", true)
		list.visibility_changed.connect(func():
			if is_instance_valid(es):
				es.visible = list.is_visible_in_tree())
