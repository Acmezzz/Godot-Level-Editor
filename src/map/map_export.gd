extends RefCounted
## 地图导出（A5）：PNG 概览（按投影画瓦片/碰撞/实体）+ 统计文本。
## 纯逻辑绘制到 Image，不依赖场景树，可 headless 调用。
##
## 几何全部来自 GridSpace（与主画布、内容预览同一口径）：格多边形决定形状，
## map_bounds 决定输出边界；等距/六边的菱形/六角不再被画成方块。
## 输出尺寸 = 边界 × 缩放（缩放取「每格较长边 = px_per_tile 像素」），
## 分配前先算像素总数，超过 MAX_PIXELS 时不给图，由调用方提示可用的缩放倍率。

const K := preload("res://src/core/constants.gd")
const INVISIBLE_CELL := K.INVISIBLE_CELL
const AssetDecl := preload("res://src/assets/asset_decl.gd")
const GridSpaceScript := preload("res://src/canvas/grid_space.gd")
const CollisionTypes := preload("res://src/assets/collision_types.gd")

## 首版单张预览的像素上限：16_777_216 ≈ 64 MiB 原始 RGBA。
const MAX_PIXELS := 16_777_216
## 单张预览的精度上限（px/格）；批量默认再压到 4。
const MAX_PX_PER_TILE := 16

## 地图投影：地图自己的 meta.gridProjection 优先，缺键沿用项目解析（与画布一致）。
static func projection_of(data: Dictionary, manifest: Dictionary) -> String:
	var meta = data.get("meta", {})
	var own := str((meta as Dictionary).get("gridProjection", "")) if meta is Dictionary else ""
	if own == "isometric" or own == "hexagonal" or own == "orthogonal":
		return own
	return GridSpaceScript.project_projection(manifest)

## 导出用格空间：格尺寸取清单 tileSize（缺省可用 grid_fallback 标量兜底）。
static func grid_of(data: Dictionary, manifest: Dictionary, grid_fallback = 16) -> GridSpace:
	var tile := GridSpaceScript.tile_size_of(manifest)
	if manifest.get("tileSize", null) == null and grid_fallback is int and int(grid_fallback) > 0:
		tile = Vector2i(int(grid_fallback), int(grid_fallback))
	return GridSpaceScript.new(tile, projection_of(data, manifest))

## 输出几何：{size: Vector2i, scale: float, bounds: Rect2}。scale 是「原生像素 → 输出像素」。
static func output_geometry(data: Dictionary, manifest: Dictionary, px_per_tile := 4,
		grid_fallback = 16) -> Dictionary:
	var grid := grid_of(data, manifest, grid_fallback)
	var meta: Dictionary = data.get("meta", {}) if data.get("meta", {}) is Dictionary else {}
	var w := maxi(int(meta.get("w", 1)), 1)
	var h := maxi(int(meta.get("h", 1)), 1)
	var bounds: Rect2 = grid.map_bounds(Rect2i(0, 0, w, h))
	var cell := maxf(float(grid.tile.x), float(grid.tile.y))
	var px := clampi(int(px_per_tile), 1, MAX_PX_PER_TILE)
	var scale := float(px) / maxf(cell, 1.0)
	var size := Vector2i(maxi(1, ceili(bounds.size.x * scale)), maxi(1, ceili(bounds.size.y * scale)))
	return {"size": size, "scale": scale, "bounds": bounds, "grid": grid}

## 分配前的预算检查。ok = false 时 suggested 是能压进上限的最大整数 px/格（0 = 1px 也放不下）。
static func budget(data: Dictionary, manifest: Dictionary, px_per_tile := 4,
		grid_fallback = 16) -> Dictionary:
	var geo := output_geometry(data, manifest, px_per_tile, grid_fallback)
	var size: Vector2i = geo.size
	var px := size.x * size.y
	if px <= MAX_PIXELS:
		return {"ok": true, "size": size, "pixels": px,
			"suggested": clampi(int(px_per_tile), 1, MAX_PX_PER_TILE), "error": ""}
	var sug := 0
	for p in range(mini(int(px_per_tile), MAX_PX_PER_TILE) - 1, 0, -1):
		var g2 := output_geometry(data, manifest, p, grid_fallback)
		var s2: Vector2i = g2.size
		if s2.x * s2.y <= MAX_PIXELS:
			sug = p
			break
	var err := "预览 %d×%d = %d 像素，超过上限 %d" % [size.x, size.y, px, MAX_PIXELS]
	if sug > 0:
		err += "；可用 %d px/格" % sug
	else:
		err += "；按 1 px/格仍超限，请先缩图"
	return {"ok": false, "size": size, "pixels": px, "suggested": sug, "error": err}

## 生成预览图（调用方先用 budget() 检查；超限时返回空 Image 而不是让引擎分配爆内存）。
## 碰撞条目按 v6 对象口径读 {x, y, type?, shape?}；斜坡按半格三角近似。
static func render_preview(data: Dictionary, px_per_tile := 4, manifest: Dictionary = {},
		grid_fallback = 16) -> Image:
	var b := budget(data, manifest, px_per_tile, grid_fallback)
	if not bool(b.get("ok", false)):
		return Image.new()
	var geo := output_geometry(data, manifest, px_per_tile, grid_fallback)
	var img := _render(data, manifest, geo, grid_fallback)
	return img

## 直接渲染（跳过预算检查；批量作业已按预算缩小过时用）。失败返回空 Image。
static func _render(data: Dictionary, manifest: Dictionary, geo: Dictionary, grid_fallback: int) -> Image:
	var size: Vector2i = geo.size
	var grid: GridSpace = geo.grid
	var bounds: Rect2 = geo.bounds
	var scale := float(geo.scale)
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.09, 0.09, 0.13, 1.0))
	# 背景网格：按投影画每格轮廓（菱形/六角/方形），先铺一层浅线再叠内容
	var meta: Dictionary = data.get("meta", {}) if data.get("meta", {}) is Dictionary else {}
	var mw := maxi(int(meta.get("w", 1)), 1)
	var mh := maxi(int(meta.get("h", 1)), 1)
	var line := Color(1, 1, 1, 0.06)
	# 背景逐格描线只在格数可控时画（大图 4000×4000 逐格描线会卡死导出）
	if mw * mh <= 65536:
		for gy in mh:
			for gx in mw:
				_put_poly(img, _to_out(grid.cell_polygon(Vector2i(gx, gy)), bounds, scale), null, line)

	# 瓦片按层叠（层栈顺序 = meta.layers 底→顶）：贴图集切片，缺素材退回地形绿
	var layers: Array = meta.get("layers", []) if meta.get("layers", null) is Array else []
	var order: Array = []
	for row in layers:
		if row is Dictionary:
			order.append(str((row as Dictionary).get("id", "")))
	var tiles_data = data.get("tiles", {})
	if not (tiles_data is Dictionary):
		tiles_data = {}
	for lid in (tiles_data as Dictionary):
		if not order.has(str(lid)):
			order.append(str(lid))
	var atlas_cache := {}
	for lid2 in order:
		if not (tiles_data as Dictionary).has(lid2):
			continue
		var cells = (tiles_data as Dictionary)[lid2]
		if not (cells is Array):
			continue
		for c in (cells as Array):
			if not (c is Array) or (c as Array).size() < 2:
				continue
			var cell := Vector2i(int(c[0]), int(c[1]))
			var poly := _to_out(grid.cell_polygon(cell), bounds, scale)
			if _blit_tile(img, poly, c, manifest, grid, atlas_cache):
				continue
			_put_poly(img, poly, Color(0.45, 0.70, 0.45, 1), Color(0.45, 0.70, 0.45, 1))

	# 碰撞（v6 对象口径）：颜色/形状来自 collisionTypes 声明池；斜坡画半格三角
	for c2 in (data.get("collision", []) as Array):
		if not (c2 is Dictionary):
			continue
		var cx := int((c2 as Dictionary).get("x", 0))
		var cy := int((c2 as Dictionary).get("y", 0))
		var ctype := str((c2 as Dictionary).get("type", "solid"))
		var cshape := str((c2 as Dictionary).get("shape", ""))
		var decl: Dictionary = CollisionTypes.decl_of(manifest, ctype)
		var col := Color("#f0605c")
		if decl.has("color"):
			col = Color(str(decl.get("color", "#f0605c")))
		col.a = 0.55
		var poly2 := _to_out(grid.cell_polygon(Vector2i(cx, cy)), bounds, scale)
		if cshape == "r45" or cshape == "l45":
			var r := _bbox(poly2)
			var tri: PackedVector2Array
			if cshape == "r45":
				tri = PackedVector2Array([r.position + Vector2(0, r.size.y),
					r.position + Vector2(r.size.x, 0), r.position + r.size])
			else:
				tri = PackedVector2Array([r.position, r.position + r.size,
					r.position + Vector2(0, r.size.y)])
			_put_poly(img, tri, col, Color(col, 0.9))
		else:
			_put_poly(img, poly2, col, Color(col, 0.9))

	# 摆放物：按资产稳定取色；浮点格坐标 → 格中心着色（出界跳过）
	for e in (data.get("objects", []) as Array):
		if not (e is Dictionary):
			continue
		var exz := floorf(float((e as Dictionary).get("x", 0)))
		var eyz := floorf(float((e as Dictionary).get("y", 0)))
		if int(exz) < 0 or int(eyz) < 0 or int(exz) >= mw or int(eyz) >= mh:
			continue
		var col2 := _asset_color(str((e as Dictionary).get("asset", "")))
		_put_poly(img, _to_out(grid.cell_polygon(Vector2i(int(exz), int(eyz))), bounds, scale),
			col2, Color(col2, 1.0))
	# 出生点：白框（格轮廓）
	var sp: Array = data.get("spawn", [2, 2])
	if (sp as Array).size() >= 2:
		_put_poly(img, _to_out(grid.cell_polygon(Vector2i(int(sp[0]), int(sp[1]))), bounds, scale),
			null, Color(1, 1, 1, 1))
	return img

## 原生像素点 → 输出像素点（先减去边界原点，再乘缩放）。
static func _to_out_px(p: Vector2, bounds: Rect2, scale: float) -> Vector2:
	return (p - bounds.position) * scale

static func _to_out(poly: PackedVector2Array, bounds: Rect2, scale: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(poly.size())
	for i in poly.size():
		out[i] = _to_out_px(poly[i], bounds, scale)
	return out

## 多边形填充 + 描边（fill 为 null 时只描边）。扫描线填充，不依赖 Image 的三角 API。
static func _put_poly(img: Image, poly: PackedVector2Array, fill, edge: Color) -> void:
	if poly.size() < 3:
		return
	if fill != null:
		_fill_poly(img, poly, fill)
	_draw_poly_line(img, poly, edge)

## 扫描线填充（奇偶规则）。颜色按 alpha 混合到已有像素上。
static func _fill_poly(img: Image, poly: PackedVector2Array, color: Color) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var ys: Array = []
	for p in poly:
		ys.append(p.y)
	var y0 := maxi(0, floori(_min_arr(ys)))
	var y1 := mini(h - 1, ceili(_max_arr(ys)))
	for y in range(y0, y1 + 1):
		var yc := float(y) + 0.5
		var xs: Array = []
		for i in poly.size():
			var a: Vector2 = poly[i]
			var b: Vector2 = poly[(i + 1) % poly.size()]
			if (a.y <= yc and b.y > yc) or (b.y <= yc and a.y > yc):
				var t := (yc - a.y) / (b.y - a.y)
				xs.append(a.x + (b.x - a.x) * t)
		if xs.size() < 2:
			continue
		xs.sort()
		var k := 0
		while k + 1 < xs.size():
			var xa := maxi(0, floori(float(xs[k])))
			var xb := mini(w - 1, ceili(float(xs[k + 1])) - 1)
			if xb >= xa:
				_blend_span(img, xa, xb, y, color)
			k += 2

static func _blend_span(img: Image, xa: int, xb: int, y: int, c: Color) -> void:
	if c.a >= 0.999:
		img.fill_rect(Rect2i(xa, y, xb - xa + 1, 1), c)
		return
	for x in range(xa, xb + 1):
		var old := img.get_pixel(x, y)
		img.set_pixel(x, y, old.lerp(c, c.a))

static func _draw_poly_line(img: Image, poly: PackedVector2Array, c: Color) -> void:
	for i in poly.size():
		_line(img, poly[i], poly[(i + 1) % poly.size()], c)

## 简单 DDA 线段（预览够用；不做抗锯齿）。
static func _line(img: Image, a: Vector2, b: Vector2, c: Color) -> void:
	var n := maxi(1, ceili(maxf(absf(b.x - a.x), absf(b.y - a.y))))
	for s in n + 1:
		var p := a.lerp(b, float(s) / float(n))
		var x := roundi(p.x)
		var y := roundi(p.y)
		if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
			continue
		var old := img.get_pixel(x, y)
		img.set_pixel(x, y, old.lerp(c, c.a))

static func _min_arr(a: Array) -> float:
	var m := INF
	for v in a:
		m = minf(m, float(v))
	return m

static func _max_arr(a: Array) -> float:
	var m := -INF
	for v in a:
		m = maxf(m, float(v))
	return m

static func _bbox(poly: PackedVector2Array) -> Rect2:
	var mn := poly[0]
	var mx := poly[0]
	for p in poly:
		mn = mn.min(p)
		mx = mx.max(p)
	return Rect2(mn, mx - mn)

## 资产 id → 稳定调色板色（hash 取色，编辑器不认识具体游戏资产）
static func _asset_color(asset_id: String) -> Color:
	var pal := [Color(0.35, 0.85, 1.0), Color(1.0, 0.62, 0.25), Color(0.3, 1.0, 0.5), Color(1.0, 0.35, 0.35), Color(0.75, 0.5, 1.0), Color(0.5, 0.6, 1.0), Color(1.0, 0.9, 0.3), Color(0.95, 0.6, 0.7), Color(0.6, 0.95, 0.8), Color(0.9, 0.9, 0.6)]
	if asset_id == "":
		return Color(1, 1, 1, 0.95)
	var hsh := 0
	for ch in asset_id:
		hsh = (hsh * 31 + ch.unicode_at(0)) % 100000
	return pal[hsh % (pal as Array).size()]

## 把图集对应格子贴到预览图上（6 元条目第 3 位是资产 id、第 4/5 位图集格；失败返回 false 走色块兜底）。
## 目标按格多边形包围盒落位（正交 = 方形；等距/六边 = 格中心对齐的包围盒）。
## atlas_cache 按资产 id 缓存读到的 Image，避免同一图集重复读盘。
static func _blit_tile(img: Image, dst_poly: PackedVector2Array, c: Array,
		manifest: Dictionary, grid: GridSpace, atlas_cache: Dictionary) -> bool:
	if c.size() < 5:
		return false
	var aid := str(c[2])
	var acx := int(c[3])
	var acy := int(c[4])
	if aid == "" or Vector2i(acx, acy) == INVISIBLE_CELL:
		return false
	var img0: Image = atlas_cache.get(aid, null)
	if img0 == null and not atlas_cache.has(aid):
		var rel := str(AssetDecl.by_id(manifest, aid).get("atlas", ""))
		var base := str(manifest.get("_dir", ""))
		var p: String = base.path_join(rel) if base != "" and rel != "" else rel
		img0 = Image.load_from_file(p) if p != "" and FileAccess.file_exists(p) else null
		atlas_cache[aid] = img0
	if img0 == null or img0.is_empty():
		return false
	var cs := AssetDecl.cell_size(manifest, aid)
	if cs == Vector2i.ZERO:
		cs = grid.tile
	var asz := Vector2i(img0.get_size())
	var src_rect := Rect2i(acx * cs.x, acy * cs.y, cs.x, cs.y)
	if src_rect.position.x < 0 or src_rect.position.y < 0 \
			or src_rect.end.x > asz.x or src_rect.end.y > asz.y:
		return false
	var sub := img0.get_region(src_rect)
	# 目标矩形 = 格多边形包围盒（调用方已转成输出像素）
	var r := _bbox(dst_poly)
	var dw := maxi(1, roundi(r.size.x))
	var dh := maxi(1, roundi(r.size.y))
	sub.resize(dw, dh, Image.INTERPOLATE_NEAREST)
	# 逐像素 alpha 叠加（合成后裁掉出界部分）；等距菱形下的方形贴图按包围盒绘制
	var ox := roundi(r.position.x)
	var oy := roundi(r.position.y)
	for y in dh:
		var ty := oy + y
		if ty < 0 or ty >= img.get_height():
			continue
		for x in dw:
			var tx := ox + x
			if tx < 0 or tx >= img.get_width():
				continue
			var sc := sub.get_pixel(x, y)
			if sc.a <= 0.0:
				continue
			var old := img.get_pixel(tx, ty)
			img.set_pixel(tx, ty, old.lerp(sc, sc.a))
	return true

## 统计文本（给策划/评审看）。输出几何可选：传 manifest 时附投影与预览尺寸。
static func stats_text(name: String, data: Dictionary, manifest: Dictionary = {},
		px_per_tile := 0) -> String:
	var meta: Dictionary = data.get("meta", {}) if data.get("meta", {}) is Dictionary else {}
	var objs: Array = data.get("objects", []) if data.get("objects", null) is Array else []
	var by_asset := {}
	var ids := {}
	var dup_ids := []
	for e in objs:
		if not (e is Dictionary):
			continue
		var aid := str((e as Dictionary).get("asset", "?"))
		by_asset[aid] = int(by_asset.get(aid, 0)) + 1
		# 实例身份 = code（场景实例没有码，不参与查重）
		var eid := str((e as Dictionary).get("code", ""))
		if eid != "":
			if ids.has(eid):
				dup_ids.append(eid)
			ids[eid] = true
	var lines: Array[String] = []
	lines.append("地图: %s" % name)
	lines.append("尺寸: %dx%d 格" % [int(meta.get("w", 0)), int(meta.get("h", 0))])
	if not manifest.is_empty():
		lines.append("投影: %s" % projection_of(data, manifest))
		if px_per_tile > 0:
			var geo := output_geometry(data, manifest, px_per_tile)
			var sz: Vector2i = geo.size
			lines.append("预览: %d px/格 → %dx%d 像素" % [int(px_per_tile), sz.x, sz.y])
	var tile_total := 0
	var tiles_data = data.get("tiles", {})
	if tiles_data is Dictionary:
		for lid in (tiles_data as Dictionary):
			var cells = (tiles_data as Dictionary)[lid]
			if cells is Array:
				tile_total += (cells as Array).size()
	lines.append("瓦片总数: %d" % tile_total)
	lines.append("碰撞格: %d" % ((data.get("collision", []) as Array).size() if data.get("collision", null) is Array else 0))
	lines.append("摆放物总数: %d" % objs.size())
	var keys := by_asset.keys()
	keys.sort()
	for k in keys:
		lines.append("  - %s: %d" % [str(k), int(by_asset[k])])
	if not dup_ids.is_empty():
		lines.append("警告: 重复实例码: " + ", ".join(dup_ids))
	return "\n".join(lines)
