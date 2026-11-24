extends RefCounted
## 显式格空间转换。只换算有唯一规则的量：
## 实例按像素锚点反算并舍入至 0.001 格；出生点按像素拾格，越界时移到最近界内格。
## 瓦片与碰撞格号在格系变化下没有唯一对应（正交→六边会把多格并成一格），
## 因此原样保留并逐项报数，由制作者在副本里核对或清空。
## 本模块不写盘、不改入参：新图名、新地图码与副本的实例/内容身份由 C2 管线（duplicate_map）发行。

const GridSpace := preload("res://src/canvas/grid_space.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")

const PRESETS := ["orthogonal", "isometric", "hexagonal"]

## 地图生效投影：meta.gridProjection 优先，缺键沿用项目解析（与 canvas 同口径）。
static func current_projection(data: Dictionary, manifest: Dictionary) -> String:
	var meta: Dictionary = data.get("meta", {}) if data.get("meta", null) is Dictionary else {}
	var own := str(meta.get("gridProjection", ""))
	if own in PRESETS:
		return own
	return GridSpace.project_projection(manifest)

## 成功时 document 带目标投影与双基、换算过的 objects 和 spawn，其余段原样保留；
## 图名与地图码仍由调用方改写（本模块不知道副本的文件身份）。
static func plan(data: Dictionary, manifest: Dictionary, target: String, target_basis: Array = []) -> Dictionary:
	if not (target in PRESETS):
		return {"ok": false, "error": "目标投影必须是 orthogonal / isometric / hexagonal"}
	var meta: Dictionary = data.get("meta", {}) if data.get("meta", null) is Dictionary else {}
	var next_meta := meta.duplicate()
	next_meta["gridProjection"] = target
	next_meta.erase("gridBasis")
	if not target_basis.is_empty():
		next_meta["gridBasis"] = target_basis.duplicate(true)
	var source := GridSpace.resolve(meta, manifest)
	var destination := GridSpace.resolve(next_meta, manifest)
	for config in [source, destination]:
		if not config.issues.is_empty():
			var issue: Dictionary = config.issues[0]
			return {"ok": false, "error": "%s：%s" % [issue.path, issue.message]}
	var src_g: GridSpace = source.grid
	var dst_g: GridSpace = destination.grid
	if src_g.projection == dst_g.projection and src_g.has_basis == dst_g.has_basis \
			and src_g.basis_u == dst_g.basis_u and src_g.basis_v == dst_g.basis_v:
		return {"ok": false, "error": "目标格空间与当前相同：无需转换"}
	var w := int(meta.get("w", 1))
	var h := int(meta.get("h", 1))
	var warnings: Array = []
	var objects_out: Array = []
	var src_objects: Array = data.get("objects", []) if data.get("objects", null) is Array else []
	for row in src_objects:
		if not (row is Dictionary):
			objects_out.append(row)
			continue
		var r: Dictionary = (row as Dictionary).duplicate(true)
		var xv = r.get("x", null)
		var yv = r.get("y", null)
		if not ((xv is int or xv is float) and (yv is int or yv is float)):
			return {"ok": false, "error": "实例 %s 的坐标不是数字" % str(r.get("code", "?"))}
		var aid := str(r.get("asset", ""))
		var decl: Dictionary = AssetDecl.by_id(manifest, aid) if not manifest.is_empty() else {}
		if decl.is_empty():
			warnings.append("实例 %s 的资产 %s 不在清单：按中心锚点换算" % [str(r.get("code", "?")), aid])
		var unit := _anchor_unit(decl)
		var px := src_g.object_anchor_px(Vector2(float(xv), float(yv)), unit)
		var g := dst_g.object_anchor_grid(px, unit)
		if not px.is_finite() or not g.is_finite():
			return {"ok": false, "error": "实例 %s 的锚点换算超出数值范围" % str(r.get("code", "?"))}
		var rounded_y := snappedf(g.y, 0.001)
		# 六边错行的横向原点在整数行切换：舍入跨行时抵消半格偏移。
		var old_row := floori(g.y)
		var next_row := floori(rounded_y)
		if dst_g.is_hex_geom() and old_row != next_row:
			g.x += (posmod(old_row, 2) - posmod(next_row, 2)) * 0.5
		r["x"] = snappedf(g.x, 0.001)
		r["y"] = rounded_y
		objects_out.append(r)
	var spawn = data.get("spawn", [2, 2])
	var spawn_out: Array = []
	if spawn is Array and (spawn as Array).size() >= 2 \
			and (spawn[0] is int or spawn[0] is float) and (spawn[1] is int or spawn[1] is float):
		# 出生点用整数格号表达；目标格中心可与原像素不同。
		var center: Vector2 = src_g.cell_center_px(Vector2i(int(spawn[0]), int(spawn[1])))
		var cell: Vector2i = dst_g.pick_cell(center)
		var bounded := cell.clamp(Vector2i.ZERO, Vector2i(GridSpace.cell_columns(w, dst_g.is_tri()) - 1, h - 1))
		if bounded != cell:
			warnings.append("出生点换算后越界：%s → %s（最近界内格）。请在副本中确认落点。" % [cell, bounded])
		spawn_out = [bounded.x, bounded.y]
	else:
		warnings.append("出生点缺失或不是两个数字：副本沿用原值 %s" % str(spawn))
		spawn_out = (spawn as Array).duplicate() if spawn is Array else [2, 2]
	# 瓦片/碰撞没有唯一对应：原样保留，逐项报数（交制作者在副本里核对或清空）
	var manual: Array = []
	var tile_cells := _count_tiles(data)
	if tile_cells > 0:
		manual.append({"kind": "tiles", "count": tile_cells,
			"message": "瓦片 %d 格保留原格号：格系无唯一对应，需在副本里核对或清空" % tile_cells})
	var coll_n: int = (data.get("collision", []) as Array).size() if data.get("collision", null) is Array else 0
	if coll_n > 0:
		manual.append({"kind": "collision", "count": coll_n,
			"message": "碰撞 %d 格保留原格号：格系无唯一对应，需在副本里核对或清空" % coll_n})
	var doc: Dictionary = data.duplicate(true)
	doc["meta"] = next_meta.duplicate(true)
	doc["objects"] = objects_out
	doc["spawn"] = spawn_out
	return {"ok": true, "error": "", "source_grid": _grid_metadata(meta),
		"projection": target,
		"document": doc, "manual": manual, "warnings": warnings}

static func _grid_metadata(meta: Dictionary) -> Dictionary:
	var out := {}
	for key in ["gridProjection", "gridBasis", "gridTopology"]:
		if meta.has(key):
			out[key] = meta[key]
	return out.duplicate(true)

static func _anchor_unit(decl: Dictionary) -> Vector2:
	match str(decl.get("anchor", "center")):
		"top_left":
			return Vector2.ZERO
		"bottom_center":
			return Vector2(0.5, 1.0)
	return Vector2(0.5, 0.5)

static func _count_tiles(data: Dictionary) -> int:
	var n := 0
	var seg = data.get("tiles", null)
	if not (seg is Dictionary):
		return 0
	for lid in (seg as Dictionary):
		var cells = (seg as Dictionary)[lid]
		if cells is Array:
			n += (cells as Array).size()
	return n
