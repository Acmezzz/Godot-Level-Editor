extends RefCounted
## Convert between canvas nodes and the persisted map representation.

const Constants := preload("res://src/core/constants.gd")
const MapViewData := preload("res://src/map/map_view_data.gd")
const MapFormat := preload("res://src/map/map_format.gd")

## 瓦片差量以磁盘行记录，未解析条目也能原样恢复。
static func tile_row(cvs, lid: String, tn: TileMapLayer, c: Vector2i):
	if tn == null or tn.get_cell_source_id(c) == -1:
		var row: Array = cvs.unresolved_tile(lid, c)
		if row.is_empty():
			return null
		return row.duplicate(true)
	var ac: Vector2i = tn.get_cell_atlas_coords(c)
	return [c.x, c.y, cvs.asset_of_source(tn.get_cell_source_id(c)), ac.x, ac.y,
		MapFormat.alt_of_godot(tn.get_cell_alternative_tile(c))]

## 从原始行构建快照，保留游戏自定义字段。
static func object_row(n: EntityNode) -> Dictionary:
	var clean := n.props.duplicate(true)
	# 未知资产保留原实例码；只有确认是场景资产才移除。
	var unknown_asset: bool = not (n.decl is Dictionary) or (n.decl as Dictionary).is_empty()
	var code := n.code
	var row: Dictionary = n.raw.duplicate(true)
	row.erase("scene")   # 旧键作废：同一字段两种语义容易混
	row["asset"] = n.asset
	if n.is_entity() or (unknown_asset and code != ""):
		row["code"] = code
	else:
		row.erase("code")
	row["layer"] = n.layer_id
	# 浮点格坐标：关掉吸附时可存半格/任意像素位置；保留 3 位小数避免浮点噪声
	var g := n.grid_of_world(n.position)
	row["x"] = snappedf(g.x, 0.001)
	row["y"] = snappedf(g.y, 0.001)
	if n.data_transform.is_empty():
		row.erase("transform")
	else:
		row["transform"] = n.data_transform.duplicate(true)
	if n.visible_flag:
		row.erase("visible")
	else:
		row["visible"] = false
	if n.z_policy != "auto" and n.z_policy != "":
		row["zPolicy"] = n.z_policy
	else:
		row.erase("zPolicy")
	row["props"] = clean
	if n.is_entity() or (unknown_asset and not n.functions.is_empty()):
		row["functions"] = n.functions.duplicate(true)
	else:
		row.erase("functions")
	return row

## 保留已有实例码；载图后统一补码和挂载。
static func place_object(cvs, row: Dictionary, decl: Variant = null) -> EntityNode:
	var n: EntityNode = cvs.make_object(str(row.get("asset", "")), decl)
	var ei := restore_placement(cvs, n, row)
	cvs._place_in_layer(n, ei)
	return n

static func restore_placement(cvs, n: EntityNode, row: Dictionary) -> int:
	n.raw = row.duplicate(true)
	n.props = (row.props as Dictionary).duplicate(true) if row.get("props") is Dictionary else {}
	n.data_transform = (row.transform as Dictionary).duplicate(true) if row.get("transform") is Dictionary else {}
	# Preserve unknown rows for future asset recovery without indexing them as entities.
	var has_identity := n.is_entity() or n.decl.is_empty()
	n.code = str(row.get("code", "")) if has_identity else ""
	n.functions = (row.get("functions", []) as Array).duplicate(true) \
		if has_identity and row.get("functions") is Array else []
	n.z_policy = str(row.get("zPolicy", "auto"))
	n.visible_flag = bool(row.get("visible", true))
	var ei := maxi(0, cvs._layer_index_of(MapViewData.object_layer(row, cvs.layers_decl())))
	n.layer_id = cvs.layer_id(ei)
	n.refresh_visual()
	n.apply_grid(float(row.get("x", 0)), float(row.get("y", 0)))
	return ei

static func extract(cvs) -> Dictionary:
	if not cvs.is_map_ready():
		return {}   # 重建期间不混读新地图数据和旧节点。
	var tiles := {}
	for li in cvs.layer_tiles.size():
		var tn: TileMapLayer = cvs.layer_tiles[li]
		var lid: String = cvs.layer_id(li)
		if lid == "":
			continue
		var cells := []
		var seen_cells := {}
		for c in tn.get_used_cells():
			var row = tile_row(cvs, lid, tn, c)
			if row == null or str(row[2]) == "":
				continue
			cells.append(row)
			seen_cells[c] = true
		# 保留未解析瓦片，但已重涂的格以新值为准。
		var kept: Dictionary = cvs._unresolved_tiles.get(lid, {})
		for cell in kept:
			if not seen_cells.has(cell):
				cells.append(kept[cell].duplicate(true))
		tiles[lid] = cells
	var ccells := []
	for c in cvs.collision.get_used_cells():
		var cm = cvs._collision_meta.get(c, null)
		var d := {"x": c.x, "y": c.y}
		if cm != null:
			# 保留碰撞条目中的游戏扩展字段。
			if (cm as Dictionary).get("raw", null) is Dictionary:
				d.merge((cm as Dictionary)["raw"], true)
			var ct := str(cm.get("type", "solid"))
			var cs := str(cm.get("shape", ""))
			if ct != "" and ct != "solid":
				d["type"] = ct
			if cs != "":
				d["shape"] = cs
		ccells.append(d)
	var olist := []
	for e in cvs.ents_all():
		var n := e as EntityNode
		if n == null or n.asset == "":
			continue
		olist.append(object_row(n))
	var used = Rect2i()
	for tn in cvs.layer_tiles:
		used = used.merge((tn as TileMapLayer).get_used_rect())
	if used.size == Vector2i.ZERO:
		used = Rect2i(Vector2i.ZERO, Vector2i(Constants.DEFAULT_MAP_W, Constants.DEFAULT_MAP_H))
	# 保留顶层和 meta 的游戏扩展字段。
	var out: Dictionary = cvs.map_data.duplicate() if cvs.map_data is Dictionary else {}
	for rebuilt in ["tiles", "collision", "objects", "entities", "spawn"]:
		out.erase(rebuilt)
	out = out.duplicate(true)
	var meta: Dictionary = out.get("meta", {}) if out.get("meta", {}) is Dictionary else {}
	if not meta.has("w"):
		meta["w"] = int(used.end.x + 2)
	if not meta.has("h"):
		meta["h"] = int(used.end.y + 2)
	meta["name"] = cvs.cur_map_name
	# 出生点使用根空间格坐标，不跟随活动层的偏移和缩放。
	var sp: Vector2i = cvs.grid.pick_cell(cvs.spawn.position)
	out["version"] = MapFormat.VERSION
	out["meta"] = meta
	out["spawn"] = [sp.x, sp.y]
	out["tiles"] = tiles
	out["collision"] = ccells
	out.erase("entities")   # v5：entities 段已并入 objects[]
	out["objects"] = olist
	return out
