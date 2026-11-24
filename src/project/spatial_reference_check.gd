extends RefCounted
## Checks one spatial reference against the source and any supplied map snapshots.

const MapStore := preload("res://src/map/map_store.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")
const RefFields := preload("res://src/content/ref_fields.gd")
const K := preload("res://src/core/constants.gd")
const EdgeRef := preload("res://src/map/edge_ref.gd")
const CellGraphScript := preload("res://src/map/cell_graph.gd")
const ReferenceIndex := preload("res://src/project/reference_index.gd")

static func problem(manifest: Dictionary, kind: String, source: Dictionary, map_name: String,
		value: Variant, field: Dictionary, paired: String, overrides: Dictionary) -> Dictionary:
	var local_code := str(source.get("meta", {}).get("code", ""))
	match kind:
		"entity_inst", "layer":
			if not value is String:
				return {"message": ("图层引用必须是图层 ID 字符串" if kind == "layer" else "实例引用必须是实例码字符串")}
			var target := source
			if not RefFields.map_key_local(paired, map_name, local_code):
				if overrides.has(paired):
					target = overrides[paired]
				else:
					var resolved := ReferenceIndex.resolve_map(manifest, paired)
					target = MapStore.read(manifest, str(resolved.key)) if resolved.status == "ok" else {}
			if target.is_empty():
				return {}
			var where := "目标图 %s" % paired if paired != "" else "本图"
			if kind == "layer":
				for layer in target.get("meta", {}).get("layers", []):
					if layer is Dictionary and layer.get("id") == value:
						return {}
				# 保留 ID，作者可重新选择坐标空间；不要把原路径默认为别的空间。
				return {"message": "%s不存在图层：%s" % [where, value]}
			for row in target.get("objects", []):
				if row is Dictionary and row.get("code", "") == value:
					return {}
			return {"message": "引用的实例码在%s不存在: %s" % [where, str(value)]}
		"port":
			if source.is_empty() and paired == "" and value is Dictionary \
					and value.get("map", "") is String and str(value.get("map", "")) == "":
				return {}
			return _port_ref_problem(manifest, source, map_name, value, field, paired, overrides)
		"edge":
			if source.is_empty() and paired == "" and value is Dictionary \
					and value.get("map", "") is String and str(value.get("map", "")) == "":
				return {}
			return _edge_ref_problem(manifest, source, value, overrides, map_name, paired)
		"cell":
			return _cell_ref_problem(manifest, source, str(value), paired, field, overrides, map_name)
		"map":
			if manifest.get("_maps_dir", "") != "" and not overrides.has(str(value)) \
					and not RefFields.map_key_local(str(value), map_name, local_code) \
					and ReferenceIndex.resolve_map(manifest, str(value)).status not in ["ok", "ambiguous", "unreadable"]:
				return {"message": "目标地图不存在: %s" % str(value)}
	return {}

static func _port_ref_problem(manifest: Dictionary, data: Dictionary, map_name: String,
		value: Variant, field: Dictionary, paired_map: String, overrides := {}) -> Dictionary:
	if value is Dictionary and value.is_empty():
		return {}
	if not value is Dictionary or not value.get("map") is String \
			or not value.get("inst") is String or not value.get("port") is String:
		return {"message": "端口引用需要 {map, inst, port} 字符串字段"}
	var local_code := str(data.get("meta", {}).get("code", ""))
	var target_key := RefFields.object_map_key(value, paired_map)
	var target := data
	if RefFields.map_key_local(target_key, map_name, local_code):
		pass
	elif overrides.has(target_key):
		target = overrides[target_key]
	else:
		var resolved := ReferenceIndex.resolve_map(manifest, target_key)
		match str(resolved.status):
			"ok":
				target = MapStore.read(manifest, str(resolved.key))
				if target.is_empty():
					return {}
			"missing":
				return {"message": "端口的目标地图不存在：" + target_key}
			_:
				return {}
	var types := str(field.get("of", "")).split(",", false)
	for obj in target.get("objects", []):
		if not obj is Dictionary or str(obj.get("code", "")) != value.inst:
			continue
		var asset := AssetDecl.by_id(manifest, str(obj.get("asset", "")))
		for port in RefFields.ports_of(asset):
			if port is Dictionary and port.get("id") == value.port:
				if types.is_empty() or types.has(str(port.get("type", ""))):
					return {}
				return {"message": "目标端口类型与字段声明不匹配：" + str(value.port)}
		return {"message": "实例没有对应的端口：" + str(value.port)}
	return {"message": "目标端口的实例不存在：" + str(value.inst)}

## edge_ref 悬空判定（§7.4）：边身份由格拓扑推导，因此只验「目标图存在 + 两格确实相邻 + cell 自洽」。
## 目标图本图/跨图取法与 map_ref 一致；图读不出来时比对双方拓扑会误报，故只按「读不到不判悬空」放行。
## 目标图有歧义或不可读时，由地图检查报告。
static func _edge_ref_problem(manifest: Dictionary, data: Dictionary, val, overrides: Dictionary,
		map_name: String, paired: String) -> Dictionary:
	if not (val is Dictionary):
		return {"message": "格边引用值不是 {map, cell, edge} 字典"}
	var v: Dictionary = val
	if not v.get("edge") is String or not v.get("map", "") is String:
		return {"message": "格边引用的 map 和 edge 必须是字符串"}
	var e_code := str(v.get("edge", ""))
	var ends := EdgeRef.parse_edge(e_code)
	if ends.size() != 2:
		return {"message": "格边引用格式不合法: %s" % e_code}
	var e_map := RefFields.object_map_key(v, paired)
	var tgt_meta: Dictionary = data.get("meta", {}) if data.get("meta", {}) is Dictionary else {}
	if RefFields.map_key_local(e_map, map_name, str(tgt_meta.get("code", ""))):
		pass
	elif overrides.has(e_map):
		tgt_meta = overrides[e_map].meta
	else:
		var resolved := ReferenceIndex.resolve_map(manifest, e_map)
		var rstat := str(resolved.status)
		if rstat == "ambiguous":
			# 一码多图：不知道指的是哪张图，比对邻接没有意义（由码冲突条目单列）
			return {"message": ""}
		if rstat == "unreadable":
			# §4.2-4：目标图在但读不出来——拓扑不可比，同样不可自动清（不报、也不给清空项）
			return {"message": ""}
		if rstat != "ok":
			return {"message": "格边引用的目标地图不存在: %s" % e_map}
		var td: Dictionary = MapStore.read(manifest, str(resolved.key))
		if td.is_empty():
			# 目标图存在但读不出来：拓扑不可比，不判悬空
			return {"message": ""}
		tgt_meta = td.get("meta", {}) if td.get("meta", {}) is Dictionary else {}
	var g: GridSpace = GridSpace.resolve(tgt_meta, manifest).get("grid") as GridSpace
	var ea := Vector2i(int(ends[0][0]), int(ends[0][1]))
	var eb := Vector2i(int(ends[1][0]), int(ends[1][1]))
	var w := int(tgt_meta.get("w", K.DEFAULT_MAP_W))
	var h := int(tgt_meta.get("h", K.DEFAULT_MAP_H))
	if not g.cell_in_map(ea, w, h) or not g.cell_in_map(eb, w, h):
		return {"message": "格边引用超出目标地图范围: %s" % e_code}
	if EdgeRef.segment(g, ea, eb, w, h).is_empty():
		return {"message": "格边引用的两格在地图里不相邻: %s" % e_code}
	var cell = v.get("cell", null)
	if not cell is Array or cell.size() != 2 or cell[0] != ea.x or cell[1] != ea.y:
		return {"message": "格边引用的 cell 与 edge 不自洽: %s" % e_code}
	return {"message": ""}

## cell: 引用悬空判定（§4.2-2）：有限格图的合法性**只由声明决定**——cell_id 必须在目标图
## meta.cellGraph.cells 里，不按整数格坐标或邻接推导（格图是游戏侧契约，可任意多边形）。
## 目标图解析歧义/读不出、或目标图根本没有格图声明 = 判定范围不完整，只报诊断不给清空项。
## 返回 {message}。
static func _cell_ref_problem(manifest: Dictionary, data: Dictionary, cid: String,
		paired: String, decl: Dictionary, overrides: Dictionary, map_name: String) -> Dictionary:
	var tgt_meta: Dictionary = data.get("meta", {})
	if not RefFields.map_key_local(paired, map_name, str(tgt_meta.get("code", ""))):
		if overrides.has(paired):
			tgt_meta = overrides[paired].get("meta", {})
		else:
			var resolved := ReferenceIndex.resolve_map(manifest, paired)
			if resolved.status in ["ambiguous", "unreadable"]:
				return {}
			if resolved.status != "ok":
				return {"message": "格图引用的目标地图不存在: %s" % paired}
			tgt_meta = MapStore.read(manifest, str(resolved.key)).get("meta", {})
	var graph: Dictionary = tgt_meta.get("cellGraph", {}) if tgt_meta.get("cellGraph", {}) is Dictionary else {}
	var ids: Array = CellGraphScript.cell_ids(graph)
	if ids.is_empty():
		# 没有格图声明：无法判定这枚 cell_id 是否合法（不是「确证悬空」），不产清空项
		return {"message": ""}
	if not ids.has(cid):
		return {"message": "引用的格 id 不在目标图的格图里: %s" % cid}
	var space = CellGraphScript.cell_source_space(decl)
	if space != null and not CellGraphScript.cell_options(graph, space).any(func(o): return o.v == cid):
		return {"message": "引用的格不在声明的空间 %s: %s" % [space, cid]}
	return {"message": ""}
