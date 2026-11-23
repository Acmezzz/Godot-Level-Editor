extends RefCounted
## 地图导出（A5）：PNG 概览（按投影画瓦片/碰撞/实体）+ 统计文本。
## 纯逻辑绘制到 Image，不依赖场景树，可 headless 调用。
## 粒度与缓存：每个格按 GridSpace 多边形逐格落色/贴切片（一次导出 = 一趟全图遍历，无中间缓存）；
## 预算由 MAX_PIXELS 卡住，先算总像素再决定是否出图。
##
## 几何全部来自 GridSpace（与主画布、内容预览同一口径）：格多边形决定形状，
## map_bounds 决定输出边界；等距/六边的菱形/六角不再被画成方块。
## 输出尺寸 = 边界 × 缩放（缩放取「每格较长边 = px_per_tile 像素」），
## 分配前先算像素总数，超过 MAX_PIXELS 时不给图，由调用方提示可用的缩放倍率。
##
## 边界：导出画的是**数据坐标下的俯视概览**——格形/落点/范围保真，层 offset/scale
## 参与边界与落位。实例使用格内色标，层内遵循 zPolicy / ySort；不模拟视差或瓦片逐格遮挡。

const K := preload("res://src/core/constants.gd")
const INVISIBLE_CELL := K.INVISIBLE_CELL
const AssetDecl := preload("res://src/assets/asset_decl.gd")
const GridSpaceScript := preload("res://src/canvas/grid_space.gd")
const CollisionViewScript := preload("res://src/canvas/collision_view.gd")
const CollisionTypes := preload("res://src/assets/collision_types.gd")
const TriView := preload("res://src/canvas/tri_tile_view.gd")
const MapViewData := preload("res://src/map/map_view_data.gd")

## 首版单张预览的像素上限：16_777_216 ≈ 64 MiB 原始 RGBA。
const MAX_PIXELS := 16_777_216
const MAX_ITEMS := 1_000_000
const MAX_RASTER_WORK := MAX_PIXELS * 4
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
## B3（§7.3）：与画布/校验共用 GridSpace.resolve 同一入口（basis/topology 同一预设验证）。
static func grid_of(data: Dictionary, manifest: Dictionary, grid_fallback = 16) -> GridSpace:
	var meta: Dictionary = data.get("meta", {}) if data.get("meta", {}) is Dictionary else {}
	var gres: Dictionary = GridSpaceScript.resolve(meta, manifest)
	var g: GridSpace = gres.get("grid") as GridSpace
	if manifest.get("tileSize", null) == null and grid_fallback is int and int(grid_fallback) > 0:
		g.tile = Vector2i(int(grid_fallback), int(grid_fallback))
	return g

## 输出几何：{size: Vector2i, scale: float, bounds: Rect2}。scale 是「原生像素 → 输出像素」。
## 边界 = 根空间地图边界 ∪ 每个层经自身 offset/scale 变换后的地图边界——
## 层位移/放大后内容可能跑出根边界，不扩边界就会把内容裁掉（§7.3 同一份几何）。
static func output_geometry(data: Dictionary, manifest: Dictionary, px_per_tile := 4,
		grid_fallback = 16) -> Dictionary:
	var grid := grid_of(data, manifest, grid_fallback)
	# §4.3-1：名义范围（根边界 ∪ 各层变换后边界）统一由 MapViewData.scene_bounds 给，
	# 预览 _fit / Home 取景与导出同一条口径。
	var bounds: Rect2 = MapViewData.scene_bounds(data, manifest, true)
	var cell := maxf(float(grid.tile.x), float(grid.tile.y))
	var px := clampi(int(px_per_tile), 1, MAX_PX_PER_TILE)
	var scale := float(px) / maxf(cell, 1.0)
	var size := Vector2i(maxi(1, ceili(bounds.size.x * scale)), maxi(1, ceili(bounds.size.y * scale)))
	return {"size": size, "scale": scale, "bounds": bounds, "grid": grid}

## 分配前的预算检查。ok = false 时 suggested 是能压进上限的最大整数 px/格（0 = 1px 也放不下）。
## §5：候选档位按算术推算，不再每档重跑 output_geometry（那会重建 GridSpace 并重算层边界）。
## 尺寸与 px/格 成正比：size(p) = ceil(bounds.size × p / cell)，bounds/cell 一次求出即可。
static func budget(data: Dictionary, manifest: Dictionary, px_per_tile := 4,
		grid_fallback = 16) -> Dictionary:
	var geo := output_geometry(data, manifest, px_per_tile, grid_fallback)
	var size: Vector2i = geo.size
	var px := size.x * size.y
	var work := _workload(data, geo.grid)
	if int(work.items) > MAX_ITEMS:
		return {"ok": false, "size": size, "pixels": px, "suggested": 0,
			"error": "地图条目 %d 超过导出上限 %d" % [work.items, MAX_ITEMS]}
	if _fits_budget(size, work, float(geo.scale)):
		return {"ok": true, "size": size, "pixels": px,
			"suggested": clampi(int(px_per_tile), 1, MAX_PX_PER_TILE), "error": ""}
	var bounds: Rect2 = geo.bounds
	var cell := maxf(float((geo.grid as GridSpace).tile.x), float((geo.grid as GridSpace).tile.y))
	cell = maxf(cell, 1.0)
	var sug := 0
	for p in range(mini(int(px_per_tile), MAX_PX_PER_TILE) - 1, 0, -1):
		var sc := float(p) / cell
		var s2 := Vector2i(maxi(1, ceili(bounds.size.x * sc)), maxi(1, ceili(bounds.size.y * sc)))
		if _fits_budget(s2, work, sc):
			sug = p
			break
	var err := "预览 %d×%d 超过输出尺寸或绘制工作量上限" % [size.x, size.y]
	if sug > 0:
		err += "；可用 %d px/格" % sug
	else:
		err += "；按 1 px/格仍超限，请先缩图"
	return {"ok": false, "size": size, "pixels": px, "suggested": sug, "error": err}

static func _fits_budget(size: Vector2i, work: Dictionary, scale: float) -> bool:
	return (size.x > 0 and size.y > 0 and size.x <= 16384 and size.y <= 16384
		and size.x * size.y <= MAX_PIXELS
		and float(work.area) * scale * scale + float(work.items) <= MAX_RASTER_WORK)

static func _workload(data: Dictionary, grid: GridSpace) -> Dictionary:
	var items := 0
	var counts := {}
	for key in ["objects", "collision"]:
		var rows: Array = data.get(key, [])
		items += rows.size()
		for row in rows:
			if row is Dictionary:
				var lid := str(row.get("layer", "")) if key == "objects" else ""
				counts[lid] = int(counts.get(lid, 0)) + 1
	var tiles: Dictionary = data.get("tiles", {})
	for lid in tiles:
		if tiles[lid] is Array:
			items += tiles[lid].size()
			counts[lid] = int(counts.get(lid, 0)) + tiles[lid].size()
	var cell_size := _bbox(grid.cell_polygon(Vector2i.ZERO)).size
	var area := 0.0
	for lid in counts:
		var xf := MapViewData.layer_transform(data, str(lid))
		area += int(counts[lid]) * cell_size.x * cell_size.y * absf(xf.determinant())
	return {"items": items, "area": area}

## 生成预览图（调用方先用 budget() 检查；超限时返回空 Image 而不是让引擎分配爆内存）。
## 碰撞条目按 v6 对象口径读 {x, y, type?, shape?}；斜坡按半格三角近似。
## match_canvas（§4.3-4 两档）：
##   false = 布局示意（默认）：所有层都画、层混合一律 mix——看「东西在哪」。
##   true  = 画面一致：隐藏层不画（层 visible=false 的瓦片与实例都跳过）、层 blend(add/mul)
##           参与合成——看「画布上是什么样」。两档几何与预算完全相同。
static func render_preview(data: Dictionary, px_per_tile := 4, manifest: Dictionary = {},
		grid_fallback := 16, match_canvas := false) -> Image:
	var b := budget(data, manifest, px_per_tile, grid_fallback)
	if not bool(b.get("ok", false)):
		return Image.new()
	var geo := output_geometry(data, manifest, px_per_tile, grid_fallback)
	var img := _render(data, manifest, geo, match_canvas)
	return img

## 直接渲染（跳过预算检查；批量作业已按预算缩小过时用）。失败返回空 Image。
static func _render(data: Dictionary, manifest: Dictionary, geo: Dictionary,
		match_canvas := false) -> Image:
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
	# 三角拓扑的格号 x 是三角列：横向格数是 2×w（V4 P1：按 w 画会丢一半三角）
	var gcols := mw * 2 if grid.is_tri() else mw
	if gcols * mh <= 65536:
		for gy in mh:
			for gx in gcols:
				_put_poly(img, _to_out(grid.cell_polygon(Vector2i(gx, gy)), bounds, scale), null, line)

	# 瓦片按层叠（层栈顺序 = meta.layers 底→顶）：贴图集切片，缺素材退回地形绿
	var layers: Array = meta.get("layers", []) if meta.get("layers", null) is Array else []
	var order: Array = []
	# §4.3-4：画面一致档读层显隐与混合；布局示意档一律当作可见 + mix
	var layer_hidden := {}
	var layer_blend := {}
	var layer_ysort := {}
	for row in layers:
		if not (row is Dictionary):
			continue
		var lid_row := str((row as Dictionary).get("id", ""))
		order.append(lid_row)
		layer_ysort[lid_row] = bool(row.get("ySort", false))
		if match_canvas:
			if (row as Dictionary).get("visible", true) == false:
				layer_hidden[lid_row] = true
			var bm := str((row as Dictionary).get("blend", "mix"))
			if bm == "add" or bm == "mul":
				layer_blend[lid_row] = bm
	var tiles_data = data.get("tiles", {})
	if not (tiles_data is Dictionary):
		tiles_data = {}
	for lid in (tiles_data as Dictionary):
		if not order.has(str(lid)):
			order.append(str(lid))
	var objects_by_layer := {}
	for raw in (data.get("objects", []) as Array):
		if not raw is Dictionary or (match_canvas and raw.get("visible", true) == false):
			continue
		var obj: Dictionary = raw
		var lid := str(obj.get("layer", ""))
		if not objects_by_layer.has(lid):
			objects_by_layer[lid] = [[], [], []]
			if not order.has(lid):
				order.append(lid)
		var segment := MapViewData.object_segment(str(obj.get("zPolicy", "auto")))
		objects_by_layer[lid][segment].append(obj)
	var atlas_cache := {}
	var extent := Rect2(Vector2.ZERO, Vector2(mw, mh))
	for lid: String in order:
		if layer_hidden.has(lid):
			continue
		var xf := MapViewData.layer_transform(data, lid)
		var blend := str(layer_blend.get(lid, ""))
		var groups: Array = objects_by_layer.get(lid, [[], [], []])
		if bool(layer_ysort.get(lid, false)):
			groups[1] = _sorted_objects(groups[1], grid)
		_draw_object_markers(img, groups[0], grid, extent, xf, geo, blend)
		var cells = (tiles_data as Dictionary).get(lid, [])
		if cells is Array:
			for c in cells:
				if not c is Array or c.size() < 2:
					continue
				var cell := Vector2i(int(c[0]), int(c[1]))
				if not grid.cell_in_map(cell, mw, mh):
					continue
				var poly := _to_out(_xformed(xf, grid.cell_polygon(cell)), bounds, scale)
				if not _blit_tile(img, poly, c, manifest, grid, atlas_cache, blend):
					var fallback := Color(0.45, 0.70, 0.45)
					_put_poly_blend(img, poly, fallback, fallback, blend)
		_draw_object_markers(img, groups[1], grid, extent, xf, geo, blend)
		_draw_object_markers(img, groups[2], grid, extent, xf, geo, blend)

	var color_cache := {}
	for raw in (data.get("collision", []) as Array):
		if not raw is Dictionary:
			continue
		var cell := Vector2i(int(raw.get("x", 0)), int(raw.get("y", 0)))
		if not grid.cell_in_map(cell, mw, mh):
			continue
		var type := str(raw.get("type", "solid"))
		if not color_cache.has(type):
			var decl := CollisionTypes.decl_of(manifest, type)
			color_cache[type] = CollisionViewScript._colors_of(decl if not decl.is_empty() else {"id": type})
		var colors: Array = color_cache[type]
		var poly := MapViewData.collision_polygon(grid.cell_polygon(cell), str(raw.get("shape", "")))
		_put_poly(img, _to_out(poly, bounds, scale), colors[0], colors[1])
	# 出生点：白框（格轮廓）
	var sp: Array = data.get("spawn", [2, 2])
	if (sp as Array).size() >= 2:
		_put_poly(img, _to_out(grid.cell_polygon(Vector2i(int(sp[0]), int(sp[1]))), bounds, scale),
			null, Color(1, 1, 1, 1))
	return img

static func _sorted_objects(objects: Array, grid: GridSpace) -> Array:
	var keys: Array = []
	for i in objects.size():
		var obj: Dictionary = objects[i]
		var y := grid.to_px(Vector2(float(obj.get("x", 0)), float(obj.get("y", 0)))).y
		var anchor = obj.get("sortAnchor", [])
		if anchor is Array and anchor.size() >= 2:
			y += float(anchor[1])
		keys.append(Vector2(y, i))
	keys.sort_custom(func(a: Vector2, b: Vector2): return a.y < b.y if a.x == b.x else a.x < b.x)
	var out: Array = []
	for key: Vector2 in keys:
		out.append(objects[int(key.y)])
	return out

static func _draw_object_markers(img: Image, objects: Array, grid: GridSpace, extent: Rect2,
		xf: Transform2D, geo: Dictionary, blend: String) -> void:
	for obj: Dictionary in objects:
		var pos := Vector2(float(obj.get("x", 0)), float(obj.get("y", 0)))
		if not extent.has_point(pos):
			continue
		var cell := grid.pick_cell(grid.to_px(pos))
		var poly := _to_out(_xformed(xf, grid.cell_polygon(cell)), geo.bounds, geo.scale)
		var col := _asset_color(str(obj.get("asset", "")))
		_put_poly_blend(img, poly, col, Color(col, 1.0), blend)

## 原生像素点 → 输出像素点（先减去边界原点，再乘缩放）。
static func _to_out_px(p: Vector2, bounds: Rect2, scale: float) -> Vector2:
	return (p - bounds.position) * scale

static func _to_out(poly: PackedVector2Array, bounds: Rect2, scale: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(poly.size())
	for i in poly.size():
		out[i] = _to_out_px(poly[i], bounds, scale)
	return out

## 多边形过层变换（offset/scale；Transform2D.IDENTITY 时原样返回）。
static func _xformed(xf: Transform2D, poly: PackedVector2Array) -> PackedVector2Array:
	if xf == Transform2D.IDENTITY:
		return poly
	var out := PackedVector2Array()
	out.resize(poly.size())
	for i in poly.size():
		out[i] = xf * (poly[i] as Vector2)
	return out

## 多边形填充 + 描边（fill 为 null 时只描边）。扫描线填充，不依赖 Image 的三角 API。
static func _put_poly(img: Image, poly: PackedVector2Array, fill, edge: Color) -> void:
	if poly.size() < 3:
		return
	if fill != null:
		_fill_poly(img, poly, fill)
	_draw_poly_line(img, poly, edge)

## §4.3-4：带层混合模式的多边形（blend = "" / "add" / "mul"；"" 等价旧行为）。
static func _put_poly_blend(img: Image, poly: PackedVector2Array, fill, edge: Color, blend: String) -> void:
	if poly.size() < 3:
		return
	if fill != null:
		_fill_poly(img, poly, fill, blend)
	_draw_poly_line(img, poly, edge)   # 描边走普通 alpha 合成（1px 线，混合差异不可见）

## 扫描线填充（奇偶规则）。颜色按 alpha 混合到已有像素上。
## blend = "" 覆盖写（alpha 混合）；"add"/"mul" 按层混合模式合成（§4.3-4）。
static func _fill_poly(img: Image, poly: PackedVector2Array, color: Color, blend := "") -> void:
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
				_blend_span(img, xa, xb, y, color, blend)
			k += 2

static func _blend_span(img: Image, xa: int, xb: int, y: int, c: Color, blend := "") -> void:
	if blend == "" and c.a >= 0.999:
		img.fill_rect(Rect2i(xa, y, xb - xa + 1, 1), c)
		return
	for x in range(xa, xb + 1):
		var old := img.get_pixel(x, y)
		img.set_pixel(x, y, _mix_over(old, c, blend))

## 单像素合成：blend = "" 普通 alpha 叠；"add" 加色（截到 1）；"mul" 乘色。
## 三种模式都先按 c.a 把「混合结果」与底色插值——层 blend 在画布上是材质级混合，
## 这里按像素近似（预览口径，不追求逐像素一致）。
static func _mix_over(old: Color, c: Color, blend: String) -> Color:
	if blend == "add":
		var add := Color(minf(old.r + c.r, 1.0), minf(old.g + c.g, 1.0), minf(old.b + c.b, 1.0), 1.0)
		return old.lerp(add, c.a)
	if blend == "mul":
		var mul := Color(old.r * c.r, old.g * c.g, old.b * c.b, 1.0)
		return old.lerp(mul, c.a)
	return old.lerp(c, c.a)

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
		manifest: Dictionary, grid: GridSpace, atlas_cache: Dictionary, blend := "") -> bool:
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
	var r := _bbox(dst_poly)
	var alt := int(c[5]) if c.size() >= 6 else 0
	var dst := Rect2i(r.position.floor(), r.end.ceil() - r.position.floor())
	dst = dst.intersection(Rect2i(Vector2i.ZERO, img.get_size()))
	for ty in range(dst.position.y, dst.end.y):
		for tx in range(dst.position.x, dst.end.x):
			var point := Vector2(tx + 0.5, ty + 0.5)
			if not Geometry2D.is_point_in_polygon(point, dst_poly):
				continue
			var uv := TriView.tile_uv((point - r.position) / r.size, alt)
			var sample := Vector2i((uv * Vector2(cs)).floor()).clamp(Vector2i.ZERO, cs - Vector2i.ONE)
			var sc := img0.get_pixelv(src_rect.position + sample)
			if sc.a > 0.0:
				img.set_pixel(tx, ty, _mix_over(img.get_pixel(tx, ty), sc, blend))
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
