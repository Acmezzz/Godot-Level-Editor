extends RefCounted
## 地图导出：PNG 俯视预览（各层瓦片/碰撞/实体色块）与统计文本。
## 纯逻辑绘制到 Image，不依赖场景树，可 headless 调用。

const K := preload("res://src/core/constants.gd")
const INVISIBLE_CELL := K.INVISIBLE_CELL
const AssetDecl := preload("res://src/assets/asset_decl.gd")

## 生成预览图。px_per_tile 为每格像素（默认 4，120x56 地图得 480x224）。
## `assets` = 清单字典（取图集路径与切片尺寸）；为空时地形用纯色块占位。
static func render_preview(data: Dictionary, px_per_tile := 4, manifest: Dictionary = {}, grid := 16) -> Image:
	var meta: Dictionary = data.get("meta", {})
	var w := maxi(int(meta.get("w", 1)), 1)
	var h := maxi(int(meta.get("h", 1)), 1)
	var img := Image.create(w * px_per_tile, h * px_per_tile, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.09, 0.09, 0.13, 1.0))

	# 瓦片按层存（tiles = {层id: [...]}）——导出统一用 terrain 绿（预览不分层色）
	var tiles_data = data.get("tiles", {})
	if not (tiles_data is Dictionary):
		tiles_data = {}
	var atlas_cache := {}
	for lid in (tiles_data as Dictionary):
		var cells = (tiles_data as Dictionary)[lid]
		if not (cells is Array):
			continue
		for c in (cells as Array):
			var r := _cell_rect(c, px_per_tile)
			if _blit_tile(img, r, c, manifest, grid, px_per_tile, atlas_cache):
				continue
			img.fill_rect(r, Color(0.45, 0.70, 0.45, 1))
	for c in data.get("collision", []):
		img.fill_rect(_cell_rect(c, px_per_tile), Color(1.0, 0.25, 0.25, 0.55))

	for e in data.get("entities", []):
		var ex := int(e.get("x", 0))
		var ey := int(e.get("y", 0))
		if ex < 0 or ey < 0 or ex >= w or ey >= h:
			continue
 # 颜色按资产 id 稳定 hash 从调色板取色（编辑器中立，不硬编码游戏实体名）
		var col := _scene_color(str(e.get("scene", "")))
		var p := Vector2i(ex * px_per_tile, ey * px_per_tile)
		img.fill_rect(Rect2i(p, Vector2i(maxi(px_per_tile, 2), maxi(px_per_tile, 2))), col)
	# 出生点画白框
	var sp: Array = data.get("spawn", [2, 2])
	var sr := Rect2i(Vector2i(int(sp[0]), int(sp[1])) * px_per_tile, Vector2i(px_per_tile, px_per_tile))
	img.fill_rect(sr, Color(1, 1, 1, 1))
	return img

## scene id → 稳定调色板色（hash 取色，编辑器不认识具体游戏实体）
static func _scene_color(scene_id: String) -> Color:
	var pal := [Color(0.35, 0.85, 1.0), Color(1.0, 0.62, 0.25), Color(0.3, 1.0, 0.5), Color(1.0, 0.35, 0.35), Color(0.75, 0.5, 1.0), Color(0.5, 0.6, 1.0), Color(1.0, 0.9, 0.3), Color(0.95, 0.6, 0.7), Color(0.6, 0.95, 0.8), Color(0.9, 0.9, 0.6)]
	if scene_id == "":
		return Color(1, 1, 1, 0.95)
	var hsh := 0
	for ch in scene_id:
		hsh = (hsh * 31 + ch.unicode_at(0)) % 100000
	return pal[hsh % (pal as Array).size()]

static func _cell_rect(c: Array, px: int) -> Rect2i:
	return Rect2i(Vector2i(int(c[0]), int(c[1])) * px, Vector2i(px, px))

## 把图集对应格子贴到预览图上（5 元条目第 3 位是资产 id；失败返回 false 走色块兜底）。
## atlas_cache 按资产 id 缓存读到的 Image，避免同一图集重复读盘。
static func _blit_tile(img: Image, dst: Rect2i, c: Array, manifest: Dictionary,
		grid: int, px: int, atlas_cache: Dictionary) -> bool:
	if c.size() < 5:
		return false
	var aid := str(c[2])
	var acx := int(c[3])
	var acy := int(c[4])
	if aid == "" or Vector2i(acx, acy) == INVISIBLE_CELL:
		return false
	var img0: Image = atlas_cache.get(aid, null)
	if img0 == null:
		var rel := str(AssetDecl.by_id(manifest, aid).get("atlas", ""))
		var base := str(manifest.get("_dir", ""))
		var p: String = base.path_join(rel) if base != "" and rel != "" else rel
		if p == "" or not FileAccess.file_exists(p):
			atlas_cache[aid] = null
			return false
		img0 = Image.load_from_file(p)
		atlas_cache[aid] = img0
	if img0 == null or img0.is_empty():
		return false
	var cs := AssetDecl.cell_size(manifest, aid)
	if cs == Vector2i.ZERO:
		cs = Vector2i(grid, grid)
	var asz := Vector2i(img0.get_size())
	var src_rect := Rect2i(acx * cs.x, acy * cs.y, cs.x, cs.y)
	if src_rect.position.x < 0 or src_rect.position.y < 0 \
			or src_rect.end.x > asz.x or src_rect.end.y > asz.y:
		return false
	var sub := img0.get_region(src_rect)
	sub.resize(px, px, Image.INTERPOLATE_NEAREST)
	img.blit_rect(sub, Rect2i(Vector2i.ZERO, Vector2i(px, px)), dst.position)
	return true
## 统计文本（给策划/评审看）
static func stats_text(name: String, data: Dictionary) -> String:
	var meta: Dictionary = data.get("meta", {})
	var ents: Array = data.get("entities", [])
	var by_scene := {}
	var ids := {}
	var dup_ids := []
	for e in ents:
		var sc := str(e.get("scene", "?"))
		by_scene[sc] = int(by_scene.get(sc, 0)) + 1
		# v4 实例身份 = code（id 键在 v4 实体条目里不存在，旧写法查重恒为空）
		var eid := str(e.get("code", ""))
		if eid != "":
			if ids.has(eid):
				dup_ids.append(eid)
			ids[eid] = true
	var lines: Array[String] = []
	lines.append("地图: %s" % name)
	lines.append("尺寸: %dx%d 格" % [int(meta.get("w", 0)), int(meta.get("h", 0))])
	var tile_total := 0
	for lid in (data.get("tiles", {}) as Dictionary):
		tile_total += ((data.get("tiles", {}) as Dictionary)[lid] as Array).size()
	lines.append("瓦片总数: %d" % tile_total)
	lines.append("碰撞格: %d" % (data.get("collision", []) as Array).size())
	lines.append("实体总数: %d" % ents.size())
	var keys := by_scene.keys()
	keys.sort()
	for k in keys:
		lines.append("  - %s: %d" % [str(k), int(by_scene[k])])
	if not dup_ids.is_empty():
		lines.append("警告: 重复实例码: " + ", ".join(dup_ids))
	return "\n".join(lines)
