extends RefCounted
## 地图 JSON 结构校验，与场景树状态无关（纯字典操作，读图必经之路）。

const MapFormat := preload("res://src/map/map_format.gd")
const CellGraph := preload("res://src/map/cell_graph.gd")
const ViewData := preload("res://src/map/map_view_data.gd")
const GridSpaceScript := preload("res://src/canvas/grid_space.gd")
const MapFlow := preload("res://src/map/map_flow.gd")

static func validate(data: Dictionary, manifest := {}) -> Array[Dictionary]:
	var issues: Array[Dictionary] = []
	if not data.has("version"):
		_add(issues, "error", "version", "version is required")
	elif not _is_integral_number(data["version"]):
		_add(issues, "error", "version", "must be a finite integer")
	elif int(data["version"]) > MapFormat.VERSION:
		_add(issues, "error", "version",
			"map format %d is newer than this editor supports (%d)" % [int(data["version"]), MapFormat.VERSION])
	elif int(data["version"]) < MapFormat.VERSION:
		_add(issues, "warning", "version",
			"older map format %d (upgraded in memory)" % int(data["version"]))
	for key in ["terrain", "decor"]:
		if data.has(key):
			_add(issues, "error", key, "retired top-level key: run tools/migrate_project.gd")
	for key in ["collision", "objects"]:
		if data.has(key) and not (data[key] is Array):
			_add(issues, "error", key, "must be an array")
	var meta = data.get("meta", {})
	var layer_ids := {}
	if not (meta is Dictionary):
		_add(issues, "error", "meta", "must be an object")
	else:
		for key in ["w", "h"]:
			if meta.has(key) and (not _is_integral_number(meta[key]) or int(meta[key]) <= 0):
				_add(issues, "error", "meta." + key, "must be a positive integer")
		# 逐图投影（B1）：可选键，三种枚举；缺键 = 沿用项目解析
		if meta.has("gridProjection") and not (str(meta.gridProjection) in ["orthogonal", "isometric", "hexagonal"]):
			_add(issues, "error", "meta.gridProjection", "must be \"orthogonal\" / \"isometric\" / \"hexagonal\"")
		# B3：可选双基向量。判据与画布/导出同一份（GridSpace.parse_basis）：有限且可逆。
		if meta.has("gridBasis"):
			var bp: Dictionary = GridSpaceScript.parse_basis(meta)
			if not bool(bp.get("ok", false)):
				_add(issues, "error", "meta.gridBasis", str(bp.get("why", "invalid")))
		# B3：可选格拓扑（quads / triangles）。三角格与 hex 投影互斥（六边没有平行四边形列）。
		if meta.has("gridTopology"):
			# R17：拓扑判据用**生效投影**（图缺投影键时取项目默认），不再一律按正交。
			var eff_proj := str(meta.get("gridProjection", GridSpaceScript.project_projection(manifest)))
			var tp: Dictionary = GridSpaceScript.parse_topology(meta, eff_proj)
			if not bool(tp.get("ok", false)):
				_add(issues, "error", "meta.gridTopology", str(tp.get("why", "invalid")))
		for section in MapFlow.SECTIONS:
			if not meta.get(section, {}) is Dictionary:
				_add(issues, "error", "meta." + section, "must be an object keyed by slot ID")
		layer_ids = _validate_layers(meta, issues, manifest)
	var tiles = data.get("tiles", null)
	if data.has("tiles") and not (tiles is Dictionary):
		_add(issues, "error", "tiles", "must be an object keyed by layer id")
	elif tiles is Dictionary:
		var known_assets := _asset_ids(manifest)
		for lid in tiles:
			var tile_cells := {}
			if not layer_ids.is_empty() and not layer_ids.has(str(lid)):
				_add(issues, "error", "tiles." + str(lid), "unknown layer id")
			if not (tiles[lid] is Array):
				_add(issues, "error", "tiles." + str(lid), "must be an array")
			else:
				for j in (tiles[lid] as Array).size():
					var cell = (tiles[lid] as Array)[j]
					var p := "tiles.%s[%d]" % [str(lid), j]
					# 6 元（v7）：[x, y, 资产id, atlas_x, atlas_y, alt]——第 3 位是字符串资产 id，
					# 第 6 位 = 变换位 0-7（bit0 水平翻转 / bit1 垂直翻转 / bit2 转置 90°），0 = 原样。
					# JSON 数字一律是 float：格号/图集号/alt 都要求「有限且为整数」（R21），
					# 否则编辑器读入转整型或同格覆写时，导出/存储与编辑重建消费成不同结果。
					if not (cell is Array) or (cell as Array).size() != 6 \
							or not _is_integral_number(cell[0]) or not _is_integral_number(cell[1]) \
							or not (cell[2] is String) \
							or not _is_integral_number(cell[3]) or not _is_integral_number(cell[4]) \
							or not _is_integral_number(cell[5]):
						_add(issues, "error", p, "must contain integral x, y, asset id, atlas_x, atlas_y, alt (v6 5-tuple retired: run tools/migrate_project.gd)")
					elif int((cell as Array)[3]) < 0 or int((cell as Array)[4]) < 0 \
							or int((cell as Array)[5]) < 0 or int((cell as Array)[5]) > 7:
						_add(issues, "error", p, "atlas coords must be >= 0 and alt in 0..7")
					elif not known_assets.is_empty() and not known_assets.has(str(cell[2])):
						_add(issues, "warning", p, "asset id is not in the current manifest: " + str(cell[2]))
					if cell is Array and cell.size() >= 2 and _is_integral_number(cell[0]) and _is_integral_number(cell[1]):
						var ck := Vector2i(int(cell[0]), int(cell[1]))
						if tile_cells.has(ck):
							_add(issues, "error", p, "duplicate tile cell on layer %s: (%d,%d)" % [str(lid), int(cell[0]), int(cell[1])])
						tile_cells[ck] = true
	var spawn = data.get("spawn", [2, 2])
	if not (spawn is Array) or spawn.size() != 2 or not _is_number_pair(spawn):
		_add(issues, "error", "spawn", "must contain two numeric coordinates")
	elif not _is_integral_number(spawn[0]) or not _is_integral_number(spawn[1]):
		_add(issues, "error", "spawn", "must contain two integer cell coordinates")
	elif meta is Dictionary:
		var grid: GridSpace = GridSpaceScript.resolve(meta, manifest).get("grid")
		var w := int(meta.get("w", 120)) if _is_integral_number(meta.get("w", 120)) else 120
		var h := int(meta.get("h", 56)) if _is_integral_number(meta.get("h", 56)) else 56
		if grid != null and not grid.cell_in_map(Vector2i(int(spawn[0]), int(spawn[1])), w, h):
			_add(issues, "warning", "spawn", "spawn is outside the declared map bounds")
	if data.has("entities"):
		_add(issues, "error", "entities", "retired: use objects[] with asset/transform (run tools/migrate_project.gd)")
	if data.get("objects", null) is Array:
		_validate_objects(data.objects, manifest, layer_ids, issues)
	if data.get("collision", null) is Array:
		var coll_cells := {}   # R21：同格多碰撞 = 错误（命中判定会随数组序漂移）
		for i in data.collision.size():
			var cell = data.collision[i]
			var p := "collision[%d]" % i
			# v6：对象条目 {x, y, type?, shape?}；v5 数组条目报错（跑迁移脚本）
			if not (cell is Dictionary):
				_add(issues, "error", p, "must be an object {x, y} (v5 arrays are retired: run tools/migrate_project.gd)")
				continue
			if not (cell.has("x") and (cell.x is int or cell.x is float) \
					and cell.has("y") and (cell.y is int or cell.y is float)):
				_add(issues, "error", p, "must contain numeric x, y")
			elif not (_is_integral_number(cell.x) and _is_integral_number(cell.y)):
				_add(issues, "error", p, "collision x, y must be integral numbers")
			else:
				var ck2 := Vector2i(int(cell.x), int(cell.y))
				if coll_cells.has(ck2):
					_add(issues, "error", p, "duplicate collision cell: (%d,%d)" % [int(cell.x), int(cell.y)])
				else:
					coll_cells[ck2] = true
			if cell.has("type") and not (cell.type is String):
				_add(issues, "error", p + ".type", "must be a collision type id string")
			if cell.has("shape") and not (cell.shape is String):
				_add(issues, "error", p + ".shape", "must be a shape id string")
	# 有限格图结构错误阻止读写，游戏声明变动引起的边属性漂移单独报告。
	if meta is Dictionary and meta.has("cellGraph"):
		if not meta.cellGraph is Dictionary:
			_add(issues, "error", "meta.cellGraph", "must be an object")
		else:
			for it: Dictionary in CellGraph.validate_graph(meta.cellGraph, manifest, ViewData.layer_transforms(meta.get("layers"))):
				_add(issues, str(it.get("severity", "error")), str(it.path), str(it.message))

	return issues

## meta.layers 用户层栈校验：非空数组、条目 id 非空且唯一、name 非空。
## 返回合法层 id 集（供 tiles 键与 entities.layer 归属校验）；栈本身不合格时返回空集，
## 关联检查（tiles 键 ⊆ 层集、entity.layer ∈ 层集）随之跳过，避免连坐噪音。

static func _validate_layers(meta: Dictionary, issues: Array[Dictionary], manifest: Dictionary) -> Dictionary:
	var ids := {}
	if not meta.has("layers") or not (meta.layers is Array) or (meta.layers as Array).is_empty():
		_add(issues, "error", "meta.layers", "must be a non-empty array of layer objects")
		return ids
	for i in (meta.layers as Array).size():
		var ldef = meta.layers[i]
		var p := "meta.layers[%d]" % i
		if not (ldef is Dictionary):
			_add(issues, "error", p, "must be an object")
			continue
		if ldef.has("tileGrid"):
			for issue in GridSpaceScript.resolve_tile_layer(ldef, manifest, null).issues:
				_add(issues, "error", p + "." + issue.path, issue.message)
		var lid := str(ldef.get("id", ""))
		if lid == "":
			_add(issues, "error", p + ".id", "must be a non-empty layer id")
		elif ids.has(lid):
			_add(issues, "error", p + ".id", "duplicate layer id: " + lid)
		else:
			ids[lid] = true
		if str(ldef.get("name", "")) == "":
			_add(issues, "error", p + ".name", "must be a non-empty layer name")
		if ldef.has("visible") and not (ldef.visible is bool):
			_add(issues, "error", p + ".visible", "must be a boolean")
		# 层参数（第 5 批）：parallax/ySort/offset/scale 可选，类型错就报错
		if ldef.has("parallax") and not _finite_number(ldef.parallax):
			_add(issues, "error", p + ".parallax", "must be a number")
		if ldef.has("ySort") and not (ldef.ySort is bool):
			_add(issues, "error", p + ".ySort", "must be a boolean")
		var loff = ldef.get("offset", null)
		if loff != null and not (loff is Array and loff.size() == 2 and _is_number_pair(loff)):
			_add(issues, "error", p + ".offset", "must be [x, y] numbers")
		if ldef.has("scale") and (not _finite_number(ldef.scale) or float(ldef.scale) <= 0.0):
			_add(issues, "error", p + ".scale", "must be a positive number")
		# 层混合模式（v7）：缺省 mix（省略）；add/mul 写盘
		if ldef.has("blend") and not (str(ldef.blend) in ["mix", "add", "mul"]):
			_add(issues, "error", p + ".blend", "must be \"mix\" / \"add\" / \"mul\"")
	return ids

## objects[] 校验：场景实例与实体实例同形，差别只在 code（仅 entity 合法）。
## scene 实例带 code = 错误——直接拦住「给背景发码」这种误用。
static func _validate_objects(objects: Array, manifest: Dictionary, layer_ids: Dictionary, issues: Array[Dictionary]) -> void:
	var known := {}
	for definition in manifest.get("assets", []):
		if definition is Dictionary:
			known[str((definition as Dictionary).get("id", ""))] = definition
	var codes := {}
	for i in objects.size():
		var obj = objects[i]
		var path := "objects[%d]" % i
		if not (obj is Dictionary):
			_add(issues, "error", path, "must be an object")
			continue
		var o: Dictionary = obj
		var aid := str(o.get("asset", ""))
		if aid == "":
			_add(issues, "error", path + ".asset", "must name an asset")
		elif not known.is_empty():
			if not known.has(aid):
				_add(issues, "warning", path + ".asset", "asset is not in the current manifest: " + aid)
			elif str((known[aid] as Dictionary).get("kind", "")) == "scene" \
					and str((known[aid] as Dictionary).get("shape", "")) != "image":
				_add(issues, "error", path + ".asset", "tile-set scenes cannot be placed as objects: " + aid)
		var code := str(o.get("code", ""))
		if code != "":
			if codes.has(code):
				_add(issues, "error", path + ".code", "duplicate instance code: " + code)
			codes[code] = true
			# code 只属于实体；场景实例发码 = 数据模型用错
			if not known.is_empty() and known.has(aid) \
					and str((known[aid] as Dictionary).get("kind", "")) != "entity":
				_add(issues, "error", path + ".code", "only kind=entity assets may carry an instance code")
		for key in ["x", "y"]:
			if o.has(key) and not _finite_number(o[key]):
				_add(issues, "error", path + "." + key, "must be numeric")
		if o.has("props") and not (o.props is Dictionary):
			_add(issues, "error", path + ".props", "must be an object")
		var visual = known.get(aid, {}).get("visual", {})
		if visual is Dictionary and visual.get("type") in ["poly", "path"] and o.get("props") is Dictionary \
				and o.props.has("points"):
			var raw = o.props.points
			var problem := preload("res://src/map/object_geometry.gd").problem(raw, visual) if raw is Array \
				else "顶点必须是数组。"
			if problem != "":
				_add(issues, "warning", path + ".props.points", problem)
		if visual is Dictionary and visual.get("type") in ["poly", "path"] and o.get("props") is Dictionary \
				and o.props.has("holes"):
			var geometry := preload("res://src/map/object_geometry.gd")
			var outer = o.props.get("points", visual.get("points", []))
			var issue := geometry.holes_problem(outer, o.props.holes) if geometry.closed(visual) and outer is Array \
				else "孔洞需要闭合外轮廓。"
			if issue != "":
				_add(issues, "warning", path + ".props.holes", issue)
		if visual is Dictionary and visual.get("type") in ["poly", "path"] and o.get("props") is Dictionary \
				and o.props.has("parts"):
			var geometry := preload("res://src/map/object_geometry.gd")
			var extra = o.props.parts
			var issue := "附加轮廓必须是闭合实体的部件数组。"
			if geometry.closed(visual) and extra is Array:
				var parts := [{"points": o.props.get("points", visual.get("points", [])),
					"holes": o.props.get("holes", [])}]
				parts.append_array(extra)
				issue = geometry.parts_problem(parts)
			if issue != "":
				_add(issues, "warning", path + ".props.parts", issue)
		if o.has("layer") and not layer_ids.is_empty() and not layer_ids.has(str(o.layer)):
			_add(issues, "error", path + ".layer", "unknown layer id: " + str(o.layer))
		if o.has("transform") and not (o.transform is Dictionary):
			_add(issues, "error", path + ".transform", "must be an object")
		if o.has("visible") and not (o.visible is bool):
			_add(issues, "error", path + ".visible", "must be a boolean")
		var zp := str(o.get("zPolicy", "auto"))
		if zp != "" and not ["auto", "below", "above"].has(zp):
			_add(issues, "error", path + ".zPolicy", "must be auto / below / above")
		if o.has("functions"):
			if known.get(aid, {}).get("kind") == "scene":
				if o.functions != []:
					_add(issues, "error", path + ".functions", "scene placements cannot carry function bindings")
			else:
				_validate_functions(o.functions, path + ".functions", manifest, issues)

## 实例 functions 数组结构校验——[{fn, content, name, order, parallel}]。
## 空 content = 还没绑定内容（内容编辑器里会按需生成），不是错误；未知码只警告，
## 因为项目侧可以先放数据再补声明（清单声明是开发契约，不是硬白名单）。
## fn 在磁盘上一律是功能的执行码，按码查声明，无人类名回退。
static func _validate_functions(raw, path: String, manifest: Dictionary, issues: Array[Dictionary]) -> void:
	if not (raw is Array):
		_add(issues, "error", path, "must be an array")
		return
	var has_manifest := not manifest.is_empty()
	var FunctionDecls := preload("res://src/content/function_decl.gd")
	var ids := {}
	for i in (raw as Array).size():
		var item = raw[i]
		var p := "%s[%d]" % [path, i]
		if not (item is Dictionary):
			_add(issues, "error", p, "must be an object")
			continue
		var fn_raw := str((item as Dictionary).get("fn", ""))
		if fn_raw == "":
			_add(issues, "error", p + ".fn", "must name a function")
		elif has_manifest and FunctionDecls.fn_id_of(manifest, fn_raw) == "":
			_add(issues, "warning", p + ".fn",
				"function code is not declared in the manifest: " + fn_raw)
		if item.has("bindingId"):
			var id = item.bindingId
			if not id is String or id.strip_edges() == "":
				_add(issues, "warning", p + ".bindingId", "must be a non-empty string")
			elif ids.has(id):
				_add(issues, "warning", p + ".bindingId", "duplicate binding id in instance: " + id)
			else:
				ids[id] = true
		if item.has("mounted") and not item.mounted is bool:
			_add(issues, "warning", p + ".mounted", "must be a boolean")
		for key in ["content", "name"]:
			if (item as Dictionary).has(key) and not ((item as Dictionary)[key] is String):
				_add(issues, "error", p + "." + key, "must be a string")
		if (item as Dictionary).has("order") and not ((item as Dictionary).order is int or (item as Dictionary).order is float):
			_add(issues, "error", p + ".order", "must be numeric")
		if (item as Dictionary).has("parallel") and not ((item as Dictionary).parallel is bool):
			_add(issues, "error", p + ".parallel", "must be a boolean")
		if (item as Dictionary).has("trigger") and not ((item as Dictionary).trigger is String):
			_add(issues, "error", p + ".trigger", "must be a trigger code string")
		if (item as Dictionary).has("enabled") and not ((item as Dictionary).enabled is bool):
			_add(issues, "error", p + ".enabled", "must be a boolean")

static func _finite_number(value: Variant) -> bool:
	return value is int or (value is float and is_finite(value))

static func _is_number_pair(values: Array) -> bool:
	return _is_number_prefix(values, 2)

## 清单资产 id 集（瓦片条目第 3 位是它）；清单缺失/畸形时返回空集，跳过关联检查。
static func _asset_ids(manifest: Dictionary) -> Dictionary:
	var out := {}
	for a in manifest.get("assets", []):
		if a is Dictionary:
			out[str((a as Dictionary).get("id", ""))] = true
	return out

static func _is_number_prefix(values: Array, count: int) -> bool:
	if values.size() < count:
		return false
	for i in count:
		if not _finite_number(values[i]):
			return false
	return true

## JSON 数字都是 float：接受有限且为整数的值，拒绝 5.5、NAN、INF（D01）。
static func _is_integral_number(v) -> bool:
	if v is int:
		return v >= -2147483648 and v <= 2147483647
	if not (v is float):
		return false
	var f: float = v
	return is_finite(f) and f >= -2147483648.0 and f <= 2147483647.0 and f == floorf(f)

static func _add(issues: Array[Dictionary], severity: String, path: String, message: String) -> void:
	issues.append({"severity": severity, "path": path, "message": message})
