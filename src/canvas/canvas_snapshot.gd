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

## 单个实例 → 磁盘行（objects[] 条目）。extract() 与实例差量记录共用同一份口径：
## 以 n.raw 为底保留游戏侧自定义键，只覆盖编辑器管辖的键。
## 实例差量里 before/after 都用它生成，撤销时按行原样重建节点，不碰整图。
static func object_row(n: EntityNode) -> Dictionary:
	var clean := n.props.duplicate(true)
	# 实例码由载入和摆放入口维护，提取快照只读；
	# 场景实例永不产码（code 键整个不写）。
	# R15：声明解析不出（资产停用/清单漂移）的旧摆放物以原行往返——带着实例码就保留，
	# 不再被误当场景实例擦掉身份；只有「确认是非实体」的已知资产才擦码。
	var unknown_asset: bool = not (n.decl is Dictionary) or (n.decl as Dictionary).is_empty()
	var code := n.code
	# 以原条目为底：未知键（游戏侧自定义）与编辑器不认识的键都留在原处
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
	# transform 缺省整键省略（旧数据没有它就等于缺省形态，读回后行为不变）
	if n.data_transform.is_empty():
		row.erase("transform")
	else:
		row["transform"] = n.data_transform.duplicate(true)
	# 编辑器专用显示开关：缺省 true 不写冗余键
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

## 行 → 活体节点（load_data 的 objects 装载与实例差量恢复共用）。
## 保留行里的 ID；载图会在所有已有 ID 就位后集中补码和挂载。
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
	# 层栈瓦片：tiles = {层id: [[x,y,资产id,ax,ay,alt]...]}（第 3 位资产 id 字符串，
	# 第 6 位 alt = 变换位 0-7，互转见 map_format.gd；清单重排不会破坏既有地图）
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
		# 装载时资产缺失/图集读不到的瓦片原样带回（D02：缺素材不删已存记录）；
		# 该格已被玩家重新涂过则丢弃旧记录（当前位置的新值优先）。
		var kept: Dictionary = cvs._unresolved_tiles.get(lid, {})
		for cell in kept:
			if not seen_cells.has(cell):
				cells.append(kept[cell].duplicate(true))
		tiles[lid] = cells
	# 碰撞条目对象（v6）：{x, y}，type 缺省省略（solid）、shape 缺省省略（矩形）。
	var ccells := []
	for c in cvs.collision.get_used_cells():
		var cm = cvs._collision_meta.get(c, null)
		var d := {"x": c.x, "y": c.y}
		if cm != null:
			# R21：磁盘碰撞行的未知键（游戏侧自定义）在画布层挂在 raw 上，重建时打底带回。
			if (cm as Dictionary).get("raw", null) is Dictionary:
				d.merge((cm as Dictionary)["raw"], true)
			var ct := str(cm.get("type", "solid"))
			var cs := str(cm.get("shape", ""))
			if ct != "" and ct != "solid":
				d["type"] = ct
			if cs != "":
				d["shape"] = cs
		ccells.append(d)
	# 摆放物：以加载时保存的原条目为底（保留游戏侧自定义键），只覆盖编辑器管辖的键。
	# 白名单重建会让未知键在保存时蒸发——这是最早发现、影响最大的一处丢数据。
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
	# 以整个读入的地图为底：游戏侧写进顶层的自定义键原样保留（此前 6 键白名单会蒸发它们）
	var out: Dictionary = cvs.map_data.duplicate() if cvs.map_data is Dictionary else {}
	for rebuilt in ["tiles", "collision", "objects", "entities", "spawn"]:
		out.erase(rebuilt)
	out = out.duplicate(true)
	# 以当前地图 meta 为底（保留游戏侧自定义键），只覆盖编辑器管辖的 name/w/h
	var meta: Dictionary = out.get("meta", {}) if out.get("meta", {}) is Dictionary else {}
	if not meta.has("w"):
		meta["w"] = int(used.end.x + 2)
	if not meta.has("h"):
		meta["h"] = int(used.end.y + 2)
	meta["name"] = cvs.cur_map_name
	# 出生点数据是根空间格号（不随活动层变）：直接由 spawn.position 反算，
	# 不能走 _cell_of——活动层有 offset/scale 时会把出生点写成别的格（E02）。
	var sp: Vector2i = cvs.grid.pick_cell(cvs.spawn.position)
	out["version"] = MapFormat.VERSION
	out["meta"] = meta
	out["spawn"] = [sp.x, sp.y]
	out["tiles"] = tiles
	out["collision"] = ccells
	out.erase("entities")   # v5：entities 段已并入 objects[]
	out["objects"] = olist
	return out
