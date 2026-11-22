extends RefCounted
## 运行时 TileSet 构建缓存：按清单 `assets[]` 里 shape=tile 的资产建源
## （source_id 是编辑器内部整数映射，磁盘数据里写的是资产 id 字符串）。
##
## undo/redo/重开图会反复走 load_data → _build_tileset，旧实现每次都重新读图集 PNG
## 并重建 TileSet——同一批资产的图集路径 + 切片尺寸不变就复用。
## 静态缓存：同进程内多个画布实例（如测试里连续建 app）共享同一份 TileSet 资源。
##
## cell 尺寸取每个资产自己的 `cell`（可非正方形、可大于地图格；实测 TileSet 接受任意
## texture_region_size）。tile_size 仍是地图格尺寸——两者分工不同。

const MapFormat := preload("res://src/map/map_format.gd")

static var _key := ""
static var _ts: TileSet = null
static var _imgs: Array = []       # source_id -> Image
static var _texs: Array = []       # source_id -> ImageTexture
static var _ids: Array = []        # source_id -> 资产 id

## 构建（或复用）TileSet。
## `tile_assets` = [{id, atlas_abs, cell: Vector2i, ysort: {Vector2i: int}}]，
## 顺序即 source_id 顺序；`grid` = 地图格尺寸（TileSet.tile_size）。
## `proj` = "orthogonal"/"isometric"/"hexagonal"（等距=菱形 / 六边=六角 TileSet.tile_shape，TileMapLayer 按形状渲染）。
## 返回 {ts, imgs, texs, ids}；坏源在结果里占位 null（R20 隔离：一个图集读不到
## 不再让整次构建失败，调用方对 null 纹理按缺图处理，旧瓦片记录按未解析往返）。
static func build(tile_assets: Array, grid: Vector2i, proj := "orthogonal") -> Dictionary:
	# 缓存键 = 投影 + 资产 id / 图集路径 / 切片尺寸 / ysort 表 / 图集 mtime。
	# mtime 是秒级粒度，外部改图集或 ySortOrigin 后同秒内可能命中旧缓存——可接受（重开图即重建）。
	var stamps: Array = []
	for a in tile_assets:
		var d: Dictionary = a
		var p := str(d.get("atlas_abs", ""))
		stamps.append("%s|%s|%s|%s|%d" % [str(d.get("id", "")), p, str(d.get("cell", "")),
			JSON.stringify(d.get("ysort", {})), FileAccess.get_modified_time(p)])
	var key := "%dx%d:%s@" % [grid.x, grid.y, proj] + "|".join(PackedStringArray(stamps))
	if _key == key and _ts != null:
		return {"ts": _ts, "imgs": _imgs, "texs": _texs, "ids": _ids}
	var ts := TileSet.new()
	ts.tile_size = grid
	if proj == "isometric":
		ts.tile_shape = TileSet.TILE_SHAPE_ISOMETRIC
	elif proj == "hexagonal":
		ts.tile_shape = TileSet.TILE_SHAPE_HEXAGON
	var imgs: Array = []
	var texs: Array = []
	var ids: Array = []
	for a in tile_assets:
		var d2: Dictionary = a
		var p := str(d2.get("atlas_abs", ""))
		# R20：隔离单个坏源——一个图集缺失/解码失败只让它自己的源缺位（占位 null，
		# source_id 映射保持稳定），其余资产照常建源；该资产的旧瓦片记录按未解析往返。
		if p == "" or not FileAccess.file_exists(p):
			imgs.append(null)
			texs.append(null)
			ids.append(str(d2.get("id", "")))
			continue
		var img := Image.load_from_file(p)
		if img == null:
			imgs.append(null)
			texs.append(null)
			ids.append(str(d2.get("id", "")))
			continue
		var cell: Vector2i = d2.get("cell", grid)
		if cell.x <= 0 or cell.y <= 0:
			cell = grid
		var tex := ImageTexture.create_from_image(img)
		var src := TileSetAtlasSource.new()
		src.texture = tex
		src.texture_region_size = cell
		var cols := int(img.get_width() / float(cell.x))
		var rows := int(img.get_height() / float(cell.y))
		for y in rows:
			for x in cols:
				src.create_tile(Vector2i(x, y))
				var td := src.get_tile_data(Vector2i(x, y), 0)
				if td != null:
					td.y_sort_origin = cell.y   # 缺省排序点 = 切片底部（遮挡模型 3.7 口径）
		# palette 条目 ySortOrigin（像素，相对切片顶部）逐瓦片覆盖缺省
		var ys: Dictionary = d2.get("ysort", {}) if d2.get("ysort", {}) is Dictionary else {}
		for yk in ys:
			var pc := str(yk).split(",")
			if pc.size() < 2:
				continue
			var td2 := src.get_tile_data(Vector2i(int(pc[0]), int(pc[1])), 0)
			if td2 != null:
				td2.y_sort_origin = int(ys[yk])
		var sid := imgs.size()
		ts.add_source(src, sid)
		imgs.append(img)
		texs.append(tex)
		ids.append(str(d2.get("id", "")))
	_key = key
	_ts = ts
	_imgs = imgs
	_texs = texs
	_ids = ids
	return {"ts": ts, "imgs": imgs, "texs": texs, "ids": ids}

## 带变换落瓦片（v7）：alt ≠ 0 时先在源上补建 alternative（Godot 把翻转/转置编进
## alternative 位，必须先 create_alternative_tile 才能落格），再 set_cell。
## alt 传编辑器口径 0-7（map_format 的位），内部转 Godot 位。
static func set_cell_alt(layer: TileMapLayer, c: Vector2i, src: int, atlas: Vector2i, alt_flags: int) -> void:
	layer.set_cell(c, src, atlas, 0)
	if alt_flags == 0:
		return
	var ts := layer.tile_set
	var s := ts.get_source(src) as TileSetAtlasSource if ts != null else null
	var godot_alt := MapFormat.alt_to_godot(alt_flags)
	if s != null and s.has_tile(atlas) and not s.get_alternative_tiles(atlas).has(godot_alt):
		s.create_alternative_tile(atlas, godot_alt)
	layer.set_cell(c, src, atlas, godot_alt)
