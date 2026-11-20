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

static var _key := ""
static var _ts: TileSet = null
static var _imgs: Array = []       # source_id -> Image
static var _texs: Array = []       # source_id -> ImageTexture
static var _ids: Array = []        # source_id -> 资产 id

## 构建（或复用）TileSet。
## `tile_assets` = [{id, atlas_abs, cell: Vector2i}]，顺序即 source_id 顺序。
## `grid` = 地图格尺寸（TileSet.tile_size）。
## 返回 {ts, imgs, texs, ids}；任一图集读不到返回空字典（调用方保持在无图集状态）。
static func build(tile_assets: Array, grid: Vector2i) -> Dictionary:
	# 缓存键 = 资产 id / 图集路径 / 切片尺寸 / 图集 mtime。
	# mtime 是秒级粒度，外部改图集后同秒内可能命中旧缓存——可接受（改图集就重开会话）。
	var stamps: Array = []
	for a in tile_assets:
		var d: Dictionary = a
		var p := str(d.get("atlas_abs", ""))
		stamps.append("%s|%s|%s|%d" % [str(d.get("id", "")), p, str(d.get("cell", "")),
			FileAccess.get_modified_time(p)])
	var key := "%dx%d@" % [grid.x, grid.y] + "|".join(PackedStringArray(stamps))
	if _key == key and _ts != null:
		return {"ts": _ts, "imgs": _imgs, "texs": _texs, "ids": _ids}
	var ts := TileSet.new()
	ts.tile_size = grid
	var imgs: Array = []
	var texs: Array = []
	var ids: Array = []
	for a in tile_assets:
		var d2: Dictionary = a
		var p := str(d2.get("atlas_abs", ""))
		if p == "" or not FileAccess.file_exists(p):
			return {}
		var img := Image.load_from_file(p)
		if img == null:
			return {}
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
