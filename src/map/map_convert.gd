extends RefCounted
## B1-2：显式投影转换（「另存并转换投影…」用）。只换算有唯一规则的量——
## 实例与出生点：原格坐标 + 锚点 → 像素锚点 → 目标格系反算同锚点 → 新坐标。
## 瓦片与碰撞格号在格系变化下没有唯一对应（正交→六边会把多格并成一格），
## 因此原样保留并逐项报数，由制作者在副本里核对或清空。
## 本模块不写盘、不改入参：新图名、新地图码与副本的实例/内容身份由 C2 管线（duplicate_map）发行。

const GridSpace := preload("res://src/canvas/grid_space.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")
const EdgeRefScript := preload("res://src/map/edge_ref.gd")

const PRESETS := ["orthogonal", "isometric", "hexagonal"]

## 地图生效投影：meta.gridProjection 优先，缺键沿用项目解析（与 canvas 同口径）。
static func current_projection(data: Dictionary, manifest: Dictionary) -> String:
	var meta: Dictionary = data.get("meta", {}) if data.get("meta", null) is Dictionary else {}
	var own := str(meta.get("gridProjection", ""))
	if own in PRESETS:
		return own
	return GridSpace.project_projection(manifest)

## 产出转换计划：{ok, error, from, projection, document, manual, warnings}。
## 成功时 document 已换 meta.gridProjection / objects / spawn，其余段原样保留；
## 图名与地图码仍由调用方改写（本模块不知道副本的文件身份）。
static func plan(data: Dictionary, manifest: Dictionary, target: String) -> Dictionary:
	if not (target in PRESETS):
		return {"ok": false, "error": "目标投影必须是 orthogonal / isometric / hexagonal"}
	var meta: Dictionary = data.get("meta", {}) if data.get("meta", null) is Dictionary else {}
	var cur := current_projection(data, manifest)
	if cur == target:
		return {"ok": false, "error": "目标投影与当前相同：无需转换"}
	# gridBasis 斜平面优先于投影预设：改 preset 不改变几何，先拒绝免得做出假转换
	var basis: Array = meta.get("gridBasis", []) if meta.get("gridBasis", null) is Array else []
	if not basis.is_empty():
		return {"ok": false, "error": "地图用 gridBasis 斜平面，它优先于投影预设——改投影不改变几何。先移除 gridBasis 再转换"}
	# 三角拓扑 + 六边投影是非法组合（与校验/画布同一个解析）
	var tparsed: Dictionary = GridSpace.parse_topology(meta, target)
	if not bool(tparsed.get("ok", false)):
		return {"ok": false, "error": "目标投影不支持当前格拓扑：" + str(tparsed.get("why", ""))}
	var ts := GridSpace.tile_size_of(manifest)
	var src_g = GridSpace.new(ts, cur, basis)
	src_g.set_topology(str(GridSpace.parse_topology(meta, cur).get("topology", "quads")))
	var dst_g = GridSpace.new(ts, target, basis)
	dst_g.set_topology(str(tparsed.get("topology", "quads")))
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
		var px: Vector2 = _anchor_px(src_g, unit, float(xv), float(yv))
		var g: Vector2 = _grid_of_px(dst_g, unit, px)
		r["x"] = snappedf(g.x, 0.001)
		r["y"] = snappedf(g.y, 0.001)
		objects_out.append(r)
	var spawn = data.get("spawn", [2, 2])
	var spawn_out: Array = []
	if spawn is Array and (spawn as Array).size() >= 2 \
			and (spawn[0] is int or spawn[0] is float) and (spawn[1] is int or spawn[1] is float):
		# 出生点是格号：原图格中心像素 → 目标格系按格拾取。目标格中心与原像素
		# 可差最多半格（等距格中心是菱形角点、四格共享），这是格号表达的固有粒度。
		var center: Vector2 = src_g.cell_center_px(Vector2i(int(spawn[0]), int(spawn[1])))
		var cell: Vector2i = dst_g.pick_cell(center)
		spawn_out = [cell.x, cell.y]
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
	# §4.2-3：格边引用在**目标拓扑**下重验。边身份 = 两合法格共享线段，投影变了
	# 原来的相邻格对可能不再相邻（例如正交 (0,0)-(1,0) 到六边仍相邻，但斜向格对不一定）。
	# 不静默改写也不删：保留原值并报数，交制作者在副本里重选（审计随后会照常显形）。
	var stale_edges := _count_stale_edges(data, objects_out, dst_g)
	if stale_edges > 0:
		manual.append({"kind": "edges", "count": stale_edges,
			"message": "格边引用 %d 条在目标拓扑下两格不再相邻：保留原值，需在副本里重选" % stale_edges})
	var doc: Dictionary = data.duplicate(true)
	var dmeta: Dictionary = doc.get("meta", {}) if doc.get("meta", null) is Dictionary else {}
	dmeta["gridProjection"] = target
	doc["meta"] = dmeta
	doc["objects"] = objects_out
	doc["spawn"] = spawn_out
	return {"ok": true, "error": "", "from": cur, "projection": target,
		"document": doc, "manual": manual, "warnings": warnings}

static func _anchor_unit(decl: Dictionary) -> Vector2:
	match str(decl.get("anchor", "center")):
		"top_left":
			return Vector2.ZERO
		"bottom_center":
			return Vector2(0.5, 1.0)
	return Vector2(0.5, 0.5)

## 数据坐标 + 锚点 → 世界锚点像素（与 entity_node.world_of_grid 同口径，不含 sortAnchor）。
static func _anchor_px(g: GridSpace, unit: Vector2, x: float, y: float) -> Vector2:
	if g.is_hex_geom():
		return g.to_px(Vector2(x, y)) + (unit - Vector2(0.5, 0.5)) * Vector2(g.tile)
	return g.to_px(Vector2(x, y) + unit)

## 世界锚点像素 → 目标格系数据坐标（_anchor_px 的逆）。
static func _grid_of_px(g: GridSpace, unit: Vector2, p: Vector2) -> Vector2:
	if g.is_hex_geom():
		return g.to_continuous_grid(p - (unit - Vector2(0.5, 0.5)) * Vector2(g.tile))
	return g.to_grid(p) - unit

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

## 已换算的实例行里，「两格在目标拓扑下不再相邻」的格边引用条数（§4.2-3）。
## 只数不修：边身份由拓扑推导，换投影没有唯一对应，改写成什么都是猜。
static func _count_stale_edges(data: Dictionary, objects_out: Array, dst_g: GridSpace) -> int:
	var n := 0
	for row in objects_out:
		if not (row is Dictionary):
			continue
		var props = (row as Dictionary).get("props", null)
		if not (props is Dictionary):
			continue
		for k in (props as Dictionary):
			var v = (props as Dictionary)[k]
			if v is Dictionary and (v as Dictionary).has("edge"):
				var ends := EdgeRefScript.parse_edge(str((v as Dictionary).get("edge", "")))
				if ends.size() != 2:
					continue
				var a := Vector2i(int(ends[0][0]), int(ends[0][1]))
				var b := Vector2i(int(ends[1][0]), int(ends[1][1]))
				if not dst_g.neighbors_any(a).has(b):
					n += 1
	return n
