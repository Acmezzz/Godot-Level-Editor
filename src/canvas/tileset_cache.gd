extends RefCounted
## 运行时 TileSet 构建缓存（PF-02）：
## undo/redo/重开图会反复走 load_data → _build_tileset，旧实现每次都重新读图集 PNG
## 并重建 TileSet——同一图集路径的结果缓存复用，路径变了（换项目）才重建。
## 静态缓存：同进程内多个画布实例（如测试里连续建 app）共享同一份 TileSet 资源。

static var _src := ""
static var _tsz := -1
static var _img: Image = null
static var _tex: ImageTexture = null
static var _ts: TileSet = null
## 多图集缓存（批次 9）：键 = 全部图集路径 + tileSize
static var _mkey := ""
static var _mimgs: Array = []
static var _mtexs: Array = []
static var _mts: TileSet = null

## 按 atlas 路径取或建 TileSet；返回 {img, tex, ts}，失败返回空字典。
## B9：缓存键含 tileSize——同路径换 tileSize 不再拿到旧 TileSet。
static func get_or_build(atlas_path: String, tsz: int) -> Dictionary:
	if _src == atlas_path and _tsz == tsz and _ts != null:
		return {"img": _img, "tex": _tex, "ts": _ts}
	var got := get_or_build_multi([atlas_path], tsz)
	if got.is_empty():
		return {}
	_src = atlas_path
	_img = got.imgs[0]
	_tex = got.texs[0]
	_ts = got.ts
	return {"img": _img, "tex": _tex, "ts": _ts}

## 批次 9 多图集：按 tiles[] 顺序构建 TileSet（source_id = 图集索引），返回
## {imgs, texs, ts}；任一图集读不到返回空字典。缓存键 = 路径列表 + tileSize。
static func get_or_build_multi(paths: Array, tsz: int) -> Dictionary:
	var key := "|".join(PackedStringArray(paths)) + "#" + str(tsz)
	if _mkey == key and _mts != null:
		return {"imgs": _mimgs, "texs": _mtexs, "ts": _mts}
	var imgs: Array = []
	var texs: Array = []
	var ts := TileSet.new()
	ts.tile_size = Vector2i(tsz, tsz)
	for p in paths:
		var img := Image.load_from_file(str(p))
		if img == null:
			return {}
		var tex := ImageTexture.create_from_image(img)
		var src := TileSetAtlasSource.new()
		src.texture = tex
		src.texture_region_size = Vector2i(tsz, tsz)
		var cols := int(img.get_width() / float(tsz))
		var rows := int(img.get_height() / float(tsz))
		for y in rows:
			for x in cols:
				src.create_tile(Vector2i(x, y))
		ts.add_source(src, imgs.size())
		imgs.append(img)
		texs.append(tex)
	_mkey = key
	_mimgs = imgs
	_mtexs = texs
	_mts = ts
	return {"imgs": imgs, "texs": texs, "ts": ts}
