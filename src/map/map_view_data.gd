extends RefCounted
## MapViewData（§7.3）：一份场景几何的只读视图数据——格多边形、层内变换、代表点。
## 内容预览与主画布共用同一口径（预览直接调 layer_transform + GridSpace 格多边形）；
## 导出是**数据坐标下的俯视概览**，按同一格多边形但**不叠层变换**（见 map_export 头注释）。
## PNG 概览允许色块简化，但格形、落点与范围必须保真（R19 口径）。

const GridSpaceScript := preload("res://src/canvas/grid_space.gd")

## 生效格空间（GridSpace.resolve 的转发；要 issues 的调用点直接调 GridSpace.resolve）。
static func effective_grid(data: Dictionary, manifest: Dictionary) -> GridSpace:
	var meta: Dictionary = data.get("meta", {}) if data.get("meta", {}) is Dictionary else {}
	return GridSpaceScript.resolve(meta, manifest).get("grid") as GridSpace

## 层内变换（数据口径）：meta.layers[] 按层码取 {offset: [x,y], scale: number} → Transform2D。
## 与画布的节点变换（layer_xform(i)）同值——层容器 position/scale 由同一组参数建成
## （editor_canvas.gd 建层时同样按 offset 数组 + scale 标量，layer_ops.gd 写回也按标量）。
## 缺键 = 恒等；scale ≤ 0 视为缺省（画布面板拒绝 ≤0，这里不自行放大成负值）。
static func layer_transform(data: Dictionary, layer_id: String) -> Transform2D:
	var meta: Dictionary = data.get("meta", {}) if data.get("meta", {}) is Dictionary else {}
	for L in (meta.get("layers", []) as Array):
		if not (L is Dictionary):
			continue
		var ld: Dictionary = L
		if str(ld.get("id", "")) != layer_id:
			continue
		var off = ld.get("offset", null)
		var sc = ld.get("scale", null)
		var offv := Vector2.ZERO
		var scv := Vector2.ONE
		if off is Array and (off as Array).size() >= 2:
			offv = Vector2(float((off as Array)[0]), float((off as Array)[1]))
		if (sc is int or sc is float) and float(sc) > 0.0:
			scv = Vector2.ONE * float(sc)
		return Transform2D(0.0, scv, 0.0, offv)
	return Transform2D.IDENTITY

## 格多边形（层内世界口径）：格空间几何 + 层变换合成。
## layer_id 为空 = 根空间（不加层变换）。
static func cell_poly(data: Dictionary, manifest: Dictionary, layer_id: String, c: Vector2i) -> PackedVector2Array:
	var g := effective_grid(data, manifest)
	var poly: PackedVector2Array = g.cell_polygon(c)
	if layer_id == "":
		return poly
	var xf := layer_transform(data, layer_id)
	var out := PackedVector2Array()
	for p in poly:
		out.append(xf * (p as Vector2))
	return out

## 代表点（摆放物锚点像素，层内世界口径）：数据坐标 (x, y) 经格空间换算 + 层变换。
## layer_id 为空 = 根空间。
static func anchor_px(data: Dictionary, manifest: Dictionary, layer_id: String, x: float, y: float) -> Vector2:
	var g := effective_grid(data, manifest)
	var px: Vector2 = g.to_px(Vector2(x, y))
	if layer_id == "":
		return px
	return layer_transform(data, layer_id) * px

## 名义范围（§4.3-1）：根空间地图边界 ∪ 每层经自身 offset/scale 变换后的边界。
## 层位移/放大后内容可能跑出根边界，不扩边界就会把内容裁掉——导出取景、预览 _fit、
## Home 取景同一份口径（原先这段合并只写在 map_export 里，别处各算一遍）。
## include_layers=false = 只要根边界（数据坐标下的俯视概览用）。
static func scene_bounds(data: Dictionary, manifest: Dictionary, include_layers := true) -> Rect2:
	var meta: Dictionary = data.get("meta", {}) if data.get("meta", {}) is Dictionary else {}
	var w := maxi(int(meta.get("w", 1)), 1)
	var h := maxi(int(meta.get("h", 1)), 1)
	var g := effective_grid(data, manifest)
	var base: Rect2 = g.map_bounds(Rect2i(0, 0, w, h))
	if not include_layers:
		return base
	var bounds := base
	for row in (meta.get("layers", []) as Array):
		if not (row is Dictionary):
			continue
		var lxf := layer_transform(data, str((row as Dictionary).get("id", "")))
		if lxf == Transform2D.IDENTITY:
			continue
		bounds = bounds.merge(xform_rect(lxf, base))
	return bounds

## 矩形过仿射变换后的轴对齐包围盒（层变换扩边界用）。
static func xform_rect(xf: Transform2D, r: Rect2) -> Rect2:
	var pts := [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]
	var mn: Vector2 = xf * (pts[0] as Vector2)
	var mx := mn
	for p in pts:
		var q: Vector2 = xf * (p as Vector2)
		mn = mn.min(q)
		mx = mx.max(q)
	return Rect2(mn, mx - mn)
