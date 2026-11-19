extends RefCounted
## 地图导出：PNG 俯视预览（地形/装饰/碰撞/实体色块）与统计文本。
## 纯逻辑绘制到 Image，不依赖场景树，可 headless 调用。

const K := preload("res://src/core/constants.gd")
const INVISIBLE_CELL := K.INVISIBLE_CELL

## 生成预览图。px_per_tile 为每格像素（默认 4，120x56 地图得 480x224）。
## atlas_texture 可空；为空时地形用纯色块占位。
static func render_preview(data: Dictionary, px_per_tile := 4, atlas_imgs: Array = [], tsz := 16) -> Image:
	var meta: Dictionary = data.get("meta", {})
	var w := maxi(int(meta.get("w", 1)), 1)
	var h := maxi(int(meta.get("h", 1)), 1)
	var img := Image.create(w * px_per_tile, h * px_per_tile, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.09, 0.09, 0.13, 1.0))
	var atlas_size := Vector2i.ZERO
	if (atlas_imgs as Array).size() > 0 and (atlas_imgs[0] as Image) != null and not (atlas_imgs[0] as Image).is_empty():
		atlas_size = (atlas_imgs[0] as Image).get_size()

	for c in data.get("terrain", []):
		var r := _cell_rect(c, px_per_tile)
		if _blit_tile(img, r, c, atlas_imgs, atlas_size, tsz, px_per_tile):
			continue
		img.fill_rect(r, Color(0.45, 0.70, 0.45, 1))
	for c in data.get("decor", []):
		var r2 := _cell_rect(c, px_per_tile)
		if _blit_tile(img, r2, c, atlas_imgs, atlas_size, tsz, px_per_tile):
			continue
		img.fill_rect(r2, Color(0.25, 0.45, 0.30, 1))
	for c in data.get("collision", []):
		img.fill_rect(_cell_rect(c, px_per_tile), Color(1.0, 0.25, 0.25, 0.55))

	for e in data.get("entities", []):
		var ex := int(e.get("x", 0))
		var ey := int(e.get("y", 0))
		if ex < 0 or ey < 0 or ex >= w or ey >= h:
			continue
 # 颜色按 scene id 稳定 hash 从调色板取色（编辑器中立，不硬编码游戏实体名）
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

## 把图集对应格子贴到预览图上（v3 多图集解析——5 元条目按 atlas 索引取源；失败返回 false）
static func _blit_tile(img: Image, dst: Rect2i, c: Array, atlas_imgs: Array, atlas_size: Vector2i, tsz: int, px: int) -> bool:
	var acx := int(c[2]) if c.size() > 2 else 0
	var acy := int(c[3]) if c.size() > 3 else 0
	var ai := 0
	if c.size() >= 5:
		ai = int(c[2])
		acx = int(c[3])
		acy = int(c[4])
	if (atlas_imgs as Array).is_empty():
		return false
	var img0: Image = atlas_imgs[mini(ai, (atlas_imgs as Array).size() - 1)] as Image
	if img0 == null or img0.is_empty():
		return false
	var asz := Vector2i(img0.get_size())
	var src_rect := Rect2i(acx * tsz, acy * tsz, tsz, tsz)
	if src_rect.end.x > asz.x or src_rect.end.y > asz.y:
		return false
	if Vector2i(acx, acy) == INVISIBLE_CELL:
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
		var eid := str(e.get("id", ""))
		if eid != "":
			if ids.has(eid):
				dup_ids.append(eid)
			ids[eid] = true
	var lines: Array[String] = []
	lines.append("地图: %s" % name)
	lines.append("尺寸: %dx%d 格" % [int(meta.get("w", 0)), int(meta.get("h", 0))])
	lines.append("地形瓦片: %d" % (data.get("terrain", []) as Array).size())
	lines.append("装饰瓦片: %d" % (data.get("decor", []) as Array).size())
	lines.append("碰撞格: %d" % (data.get("collision", []) as Array).size())
	lines.append("实体总数: %d" % ents.size())
	var keys := by_scene.keys()
	keys.sort()
	for k in keys:
		lines.append("  - %s: %d" % [str(k), int(by_scene[k])])
	if not dup_ids.is_empty():
		lines.append("警告: 重复实体 id: " + ", ".join(dup_ids))
	return "\n".join(lines)
