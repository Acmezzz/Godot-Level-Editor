extends RefCounted
## Batch operations manipulate editor document formats, never arbitrary paths.

const Maps := preload("res://src/map/map_store.gd")
const Validate := preload("res://src/map/map_data_validation.gd")
const Ids := preload("res://src/content/content_id.gd")
const Contents := preload("res://src/content/content_store.gd")
const Functions := preload("res://src/content/function_decl.gd")
const Assets := preload("res://src/assets/asset_decl.gd")
const Grid := preload("res://src/canvas/grid_space.gd")

const PROJECT_FIELDS := ["views", "worldLayout", "eventLayers", "viewports"]
const MAP_MODES := ["map.patch", "map.rename", "map.delete", "layer.put", "layer.delete", "layer.move",
	"tiles.set", "collision.set", "instance.put", "instance.delete", "binding.put", "binding.delete"]

var drafts
var manifest: Dictionary:
	get: return drafts.app.manifest

func _init(store: RefCounted) -> void:
	drafts = store

func apply(draft: Dictionary, ops: Array, batch := {}) -> Dictionary:
	if ops.is_empty():
		return {"error": "operations 不能为空。"}
	if batch.is_empty():
		batch = drafts.state(draft)
	var previous: Dictionary = drafts.shallow_batch(batch)
	var handles := {}
	var created := []
	for i in ops.size():
		var raw = ops[i]
		if not raw is Dictionary or not raw.get("op") is String:
			return {"error": "操作必须有 op。", "index": i}
		var change: Dictionary = _replace_handles(raw, handles)
		var result := _apply(batch, change)
		if result.has("error"):
			result["index"] = i
			return result
		if result.has("id"):
			created.append({"index": i, "id": result.id})
			var handle = raw.get("as")
			if handle != null:
				if not handle is String or handle.is_empty() or handles.has("$" + handle):
					return {"error": "as 必须是本批次内唯一的非空别名。", "index": i}
				handles["$" + handle] = result.id
		elif raw.has("as"):
			return {"error": "只有产生或选定 ID 的操作才能指定 as。", "index": i}
		if result.has("objectIndex"):
			created.append({"index": i, "objectIndex": result.objectIndex})
	var checked: Dictionary = drafts.candidate(batch)
	var issues := EditorManifest.validate(checked)
	for code in batch.maps:
		var item: Dictionary = batch.maps[code]
		if not item.get("deleted", false):
			for issue in Validate.validate(item.data, checked):
				issues.append(issue.merged({"map": code}))
	var errors := issues.filter(func(issue): return issue.severity == "error")
	if not errors.is_empty():
		return {"error": "批次未应用：数据格式无效。", "issues": errors}
	return drafts.append(draft, batch, previous).merged({"ids": created, "aliases": handles, "warnings": issues})

func _replace_handles(value: Variant, handles: Dictionary) -> Variant:
	if value is Array:
		return value.map(func(item): return _replace_handles(item, handles))
	if value is Dictionary:
		var out := {}
		for key in value:
			out[handles.get(key, key)] = _replace_handles(value[key], handles)
		return out
	return handles.get(value, value) if value is String else value

func _apply(batch: Dictionary, op: Dictionary) -> Dictionary:
	var name_: String = op.op
	var data = op.get("data", {})
	if not data is Dictionary:
		return {"error": "data 必须是对象。"}
	if name_ == "project.set":
		var key := str(op.get("section", ""))
		if key not in PROJECT_FIELDS:
			return {"error": "section 不属于作者可编辑清单。", "allowed": PROJECT_FIELDS}
		batch.project[key] = op.get("value")
		return {}
	if name_ == "startup.set":
		var startup: Dictionary = drafts.candidate(batch).get("startup", {}).duplicate(true)
		for key in ["target", "contentMap"]:
			if data.has(key):
				if data[key] == null:
					startup.erase(key)
				else:
					startup[key] = data[key]
		batch.project["startup"] = startup
		return {}
	if name_ == "slot.set":
		var slots: Dictionary = drafts.candidate(batch).get("projectContentSlots", {})
		var id := str(op.get("slot", ""))
		if not slots.has(id):
			return {"error": "项目内容槽未声明：" + id}
		if data.get("target") == null:
			slots[id].erase("target")
		else:
			slots[id]["target"] = data.target
		batch.project["projectContentSlots"] = slots
		return {}
	if name_ in ["group.put", "group.delete"]:
		var groups: Dictionary = drafts.candidate(batch).get("eventLayers", {})
		var id := str(op.get("group", ""))
		if name_ == "group.delete":
			if not groups.erase(id):
				return {"error": "图组不存在：" + id}
		else:
			if id == "":
				id = "group-" + Ids.new_inst_code()
			var group: Dictionary = groups.get(id, {"name": id})
			for key in data:
				if data[key] == null:
					group.erase(key)
				else:
					group[key] = data[key]
			groups[id] = group
		batch.project["eventLayers"] = groups
		return {"id": id} if name_ == "group.put" else {}
	if name_ == "view.put" or name_ == "view.delete":
		return _view(batch, op, data)
	if name_ in ["content.put", "content.delete"]:
		return _content(batch, op, data)
	if name_ == "map.create":
		var label := str(op.get("name", ""))
		var width := int(op.get("width", 120)) if _number(op.get("width", 120)) else 0
		var height := int(op.get("height", 56)) if _number(op.get("height", 56)) else 0
		if not EditorManifest.is_valid_map_name(label) or width <= 0 or height <= 0:
			return {"error": "地图需要合法名称和正数尺寸。"}
		var new_map := Maps.new_map(label, width, height, str(op.get("projection", "")), str(op.get("topology", "")))
		var code := new_map_code(batch)
		new_map.meta.code = code
		new_map.spawn = [mini(2, width - 1), mini(2, height - 1)]
		batch.maps[code] = {"name": label, "original": "", "baseline": "", "data": new_map}
		return {"id": code}
	if name_ not in MAP_MODES:
		return {"error": "未知操作：" + name_}
	var map_code := str(op.get("map", ""))
	var row: Dictionary = drafts.map_of(batch, map_code)
	if row.is_empty():
		return {"error": "找不到可编辑的地图：%s。请调用 validate 检查工程地图。" % map_code}
	var map: Dictionary = row.data
	batch.maps[map_code] = row
	match name_:
		"map.patch":
			# Identity and layer IDs are edited by their respective operations.
			for key in data:
				if key not in ["meta", "spawn"]:
					return {"error": "map.patch 只能编辑 meta 或 spawn。"}
			if data.has("meta"):
				if not data.meta is Dictionary:
					return {"error": "meta 必须是对象。"}
				for key in data.meta:
					if key in ["code", "name", "layers"]:
						return {"error": "地图码、名称和图层请使用对应操作。"}
					if data.meta[key] == null:
						map.meta.erase(key)
					else:
						map.meta[key] = data.meta[key]
			if data.has("spawn"):
				map.spawn = data.spawn
		"map.rename":
			var label := str(op.get("name", ""))
			if not EditorManifest.is_valid_map_name(label):
				return {"error": "地图名称不合法。"}
			row.name = label
			map.meta.name = label
		"map.delete":
			row["deleted"] = true
		"layer.put", "layer.delete", "layer.move":
			return _layer(map, op, data)
		"tiles.set", "collision.set":
			return _cells(map, op)
		"instance.put", "instance.delete":
			return _instance(map, op, data)
		"binding.put", "binding.delete":
			return _binding(map, op, data)
	return {}

func new_map_code(batch: Dictionary) -> String:
	var code := Maps.allocate_code(manifest)
	while batch.maps.has(code):
		code = Maps.allocate_code(manifest)
	return code

func _layer(map: Dictionary, op: Dictionary, data: Dictionary) -> Dictionary:
	var layers: Array = map.meta.layers
	var id := str(op.get("layer", ""))
	var index := _find(layers, "id", id)
	match op.op:
		"layer.put":
			if id == "":
				id = _new_id(layers, "id")
				layers.append({"id": id, "name": "图层", "visible": true})
				index = layers.size() - 1
			if index >= 0:
				layers[index].merge(data, true)
				layers[index]["id"] = id
				return {"id": id}
		"layer.move":
			var target = op.get("index")
			if index >= 0 and _number(target) and target >= 0 and target < layers.size():
				var row = layers.pop_at(index)
				layers.insert(int(target), row)
				return {}
		"layer.delete":
			if index >= 0 and layers.size() > 1:
				if not map.get("tiles", {}).get(id, []).is_empty() or map.get("objects", []).any(func(row): return row.get("layer") == id):
					return {"error": "先移动或删除这一层的瓦片和摆放物。"}
				layers.remove_at(index)
				map.get("tiles", {}).erase(id)
				return {}
	return {"error": "图层或目标顺序无效：" + id}

func _cells(map: Dictionary, op: Dictionary) -> Dictionary:
	var cells = op.get("cells")
	if not cells is Array:
		return {"error": "cells 必须是对象数组。"}
	var tiles: bool = op.op == "tiles.set"
	var id := str(op.get("layer", ""))
	if tiles and _find(map.meta.layers, "id", id) < 0:
		return {"error": "瓦片图层不存在：" + id}
	var tile_sets: Dictionary = map.get_or_add("tiles", {})
	var rows: Array = tile_sets.get(id, []) if tiles else map.get("collision", [])
	var indexed := {}
	for row in rows:
		var x: int = int(row[0] if tiles else row.x)
		var y: int = int(row[1] if tiles else row.y)
		indexed[Vector2i(x, y)] = row
	for cell in cells:
		if not cell is Dictionary or not _number(cell.get("x")) or not _number(cell.get("y")):
			return {"error": "格坐标 x、y 必须是整数。"}
		var pos := Vector2i(int(cell.x), int(cell.y))
		if cell.get("remove", false) == true:
			indexed.erase(pos)
		elif tiles:
			var ad := Assets.by_id(manifest, str(cell.get("asset", "")))
			if ad.get("disabled", false):
				return {"error": "该图集已停用：" + str(ad.id)}
			if ad.get("shape") != "tile" or not _pair(cell.get("atlas")):
				return {"error": "瓦片需要已声明的图集资产和 atlas [x,y]。"}
			indexed[pos] = [pos.x, pos.y, ad.id, cell.atlas[0], cell.atlas[1], cell.get("alt", 0)]
		else:
			var row: Dictionary = cell.duplicate()
			row.erase("remove")
			indexed[pos] = row
	if tiles:
		tile_sets[id] = indexed.values()
	else:
		map.collision = indexed.values()
	return {}

func _instance(map: Dictionary, op: Dictionary, data: Dictionary) -> Dictionary:
	var rows: Array = map.get_or_add("objects", [])
	var id := str(op.get("instance", ""))
	var index := _find(rows, "code", id) if id != "" else -1
	if op.has("objectIndex") and _number(op.objectIndex):
		index = int(op.objectIndex)
		if index < 0 or index >= rows.size():
			return {"error": "摆放物下标越界。"}
	elif id != "" and index < 0:
		return {"error": "实例不存在：" + id}
	if op.op == "instance.delete":
		if index < 0:
			return {"error": "指定实例码，或无实例码场景摆放物的 objectIndex。"}
		rows.remove_at(index)
		return {}
	var row: Dictionary = rows[index].duplicate(true) if index >= 0 else {}
	var asset := str(data.get("asset", row.get("asset", "")))
	var decl := Assets.by_id(manifest, asset)
	if decl.is_empty() or decl.get("shape") == "tile" or (index < 0 and decl.get("disabled", false)):
		return {"error": "该资产不能作为摆放物：" + asset}
	if index >= 0 and asset != row.asset:
		return {"error": "替换资产类型请移除旧摆放物后新建。"}
	for key in data:
		if key not in ["code", "functions"]:
			row[key] = data[key]
	row["asset"] = asset
	if not row.has("layer"):
		row["layer"] = map.meta.layers[0].id
	if op.has("world"):
		if not _pair(op.world, false):
			return {"error": "world 需要两个像素坐标。"}
		var layer_index := _find(map.meta.layers, "id", row.layer)
		if layer_index < 0:
			return {"error": "图层不存在。"}
		var layer: Dictionary = map.meta.layers[layer_index]
		var view := preload("res://src/map/map_view_data.gd")
		var space: GridSpace = Grid.resolve(map.meta, manifest).grid
		var local: Vector2 = view.layer_transform_of(layer).affine_inverse() * Vector2(op.world[0], op.world[1])
		var coords := space.object_anchor_grid(local, EntityNode.anchor_unit_of(decl))
		row["x"] = coords.x
		row["y"] = coords.y
	if decl.kind == "entity" and str(row.get("code", "")) == "":
		row["code"] = _new_id(rows, "code")
		var mounted := Functions.fill_bindings(manifest, asset, [])
		row["functions"] = mounted.get("functions", [])
	if index < 0:
		index = rows.size()
		rows.append(row)
	else:
		rows[index] = row
	var result := {"objectIndex": index}
	if row.has("code"):
		result["id"] = row.code
	return result

func _binding(map: Dictionary, op: Dictionary, data: Dictionary) -> Dictionary:
	var index := _find(map.get("objects", []), "code", str(op.get("instance", "")))
	if index < 0:
		return {"error": "绑定需要已存在的实例码。"}
	var row: Dictionary = map.objects[index]
	var bindings: Array = row.get_or_add("functions", [])
	var id := str(op.get("binding", ""))
	var at := _find(bindings, "bindingId", id) if id != "" else -1
	if id != "" and at < 0:
		return {"error": "绑定不存在：" + id}
	if op.op == "binding.delete":
		if at < 0 or bindings[at].get("mounted", false):
			return {"error": "需要已存在的普通绑定 ID。"}
		bindings.remove_at(at)
		Functions.renumber_bindings(bindings)
		return {}
	var fn := str(op.get("function", ""))
	var code := Functions.fn_code(manifest, fn)
	var target_fn := Functions.fn_id_of(manifest, str(bindings[at].fn)) if at >= 0 else fn
	if data.has("trigger") and not Functions.allows_trigger(manifest, target_fn, data.trigger):
		return {"error": "功能不支持时机码：%s" % str(data.trigger),
			"allowed": Functions.trigger_options(manifest, target_fn).keys()}
	var inserting := at < 0
	var position: int = bindings.size() if inserting else at
	var size: int = bindings.size() + int(inserting)
	if op.has("index"):
		if not _number(op.index) or op.index < 0 or op.index >= size:
			return {"error": "绑定位置越界。"}
		position = int(op.index)
	if data.has("order"):
		if not _number(data.order) or data.order < 1 or data.order > size:
			return {"error": "绑定顺序从 1 开始，须在当前绑定列表内。"}
		if op.has("index") and position != int(data.order) - 1:
			return {"error": "index 与 data.order 指向不同的绑定位置。"}
		position = int(data.order) - 1
	if inserting:
		if code == "" or (not Functions.is_repeatable(manifest, fn) and bindings.any(func(item): return item.fn == code)):
			return {"error": "功能未声明或不允许重复绑定：" + fn}
		id = Functions.new_binding_id(bindings)
		at = bindings.size()
		bindings.append({"bindingId": id, "fn": code})
	for key in data:
		if key not in ["content", "trigger", "order", "parallel", "enabled", "name"]:
			return {"error": "绑定字段不可编辑：" + str(key)}
		if key != "order":
			bindings[at][key] = data[key]
	if position != at:
		bindings.insert(position, bindings.pop_at(at))
	if inserting or op.has("index") or data.has("order"):
		Functions.renumber_bindings(bindings)
	return {"id": id}

func _content(batch: Dictionary, op: Dictionary, data: Dictionary) -> Dictionary:
	var fn := str(op.get("function", ""))
	var fn_code := Functions.fn_code(manifest, fn)
	var id := str(op.get("content", ""))
	if op.op == "content.put" and fn_code == "":
		return {"error": "功能未声明：" + fn}
	var existing: Dictionary = drafts.content_of(batch, fn, id) if id != "" else {}
	if op.op == "content.delete":
		if existing.is_empty():
			return {"error": "内容不存在。"}
		existing["deleted"] = true
		batch.contents[fn + "/" + id] = existing
		return {}
	if existing.is_empty():
		if id != "":
			return {"error": "修改的内容 ID 不存在；新内容省略 content，由编辑器分配。"}
		var map_code := str(op.get("map", ""))
		if map_code != "":
			var map: Dictionary = drafts.map_of(batch, map_code)
			var instance := str(op.get("instance", ""))
			var at := _find(map.get("data", {}).get("objects", []), "code", instance)
			if at < 0:
				return {"error": "实例内容需要可解析的地图码和实例码。"}
			var asset := Assets.by_id(manifest, map.data.objects[at].asset)
			id = _new_content(batch, fn, [map_code, asset.get("code", ""), instance, fn_code])
			existing = {"data": {"scope": "instance", "fields": {}}}
		else:
			id = _new_content(batch, fn, [])
			existing = {"data": {"scope": "project", "fields": {}}}
		if id == "":
			return {"error": "无法分配内容 ID。"}
		existing.merge({"function": fn, "content": id, "baseline": ""})
	if not data.get("fields", {}) is Dictionary or not data.get("steps", []) is Array:
		return {"error": "fields 必须是对象，steps 必须是数组。"}
	var scope = existing.data.get("scope")
	existing.data.merge(data, true)
	existing.data["id"] = id
	existing.data["function"] = fn_code
	if scope != null:
		existing.data["scope"] = scope
	batch.contents[fn + "/" + id] = existing
	return {"id": id}

func _new_content(batch: Dictionary, fn: String, prefix: Array) -> String:
	for i in 32:
		var id := Ids.content_id(prefix[0], prefix[1], prefix[2], prefix[3]) if not prefix.is_empty() \
			else "project-" + Ids.new_inst_code() + Ids.new_inst_code()
		if id != "" and not batch.contents.has(fn + "/" + id) and not FileAccess.file_exists(Contents.path_for(manifest, fn, id)):
			return id
	return ""

func _view(batch: Dictionary, op: Dictionary, data: Dictionary) -> Dictionary:
	var views: Array = drafts.candidate(batch).get("views", [])
	var id := str(op.get("view", ""))
	var at := _find(views, "view_id", id)
	if op.op == "view.delete":
		if at < 0:
			return {"error": "屏幕不存在。"}
		views.remove_at(at)
	else:
		if id == "":
			id = "view-" + _new_id(views, "view_id")
		var row: Dictionary = views[at] if at >= 0 else {"view_id": id, "name": id}
		row.merge(data, true)
		row["view_id"] = id
		if at < 0:
			views.append(row)
	batch.project["views"] = views
	return {"id": id}

static func _find(rows: Array, key: String, id: String) -> int:
	if id == "":
		return -1
	return rows.find_custom(func(row): return row is Dictionary and row.get(key) == id)

static func _new_id(rows: Array, key: String) -> String:
	var id := Ids.new_inst_code()
	while _find(rows, key, id) >= 0:
		id = Ids.new_inst_code()
	return id

static func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and value == floorf(value)

static func _pair(value: Variant, integers := true) -> bool:
	return value is Array and value.size() == 2 and value.all(func(item):
		return _number(item) if integers else (item is int or item is float) and is_finite(float(item)))
