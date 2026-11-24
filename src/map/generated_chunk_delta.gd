extends RefCounted
## Runtime-safe chunk overlay. This file can be used in a game without the editor.

const GRID := "gridDelta"
const CONTENT := "contentDelta"
const LAYER_STYLE := ["name", "visible", "ySort", "blend"]

static func compatibility_problem(a: Dictionary, b: Dictionary) -> String:
	for field in ["w", "h", "gridProjection", "gridTopology", "gridBasis"]:
		if not _same(a.get(field), b.get(field)):
			return "网格配置不一致：%s。" % field
	var left = a.get("layers")
	var right = b.get("layers")
	if not left is Array or not right is Array or left.size() != right.size():
		return "图层结构不一致。"
	for i in left.size():
		if not left[i] is Dictionary or not right[i] is Dictionary:
			return "图层声明无效。"
		for field in ["id", "offset", "scale", "parallax", "tileGrid"]:
			if not _same(left[i].get(field), right[i].get(field)):
				return "图层 ID、顺序或空间变换不一致。"
	return ""

static func compile(authored: Dictionary, mode: String) -> Dictionary:
	if mode not in [GRID, CONTENT]:
		return {"error": "未知差量模式。"}
	var meta: Dictionary = authored.get("meta", {}) if authored.get("meta", {}) is Dictionary else {}
	var source = meta.get("generatorSource")
	if not source is Dictionary or source.get("version") != 1 or source.get("owner") != meta.get("code") \
			or not source.get("base") is Dictionary or not source.base.get("meta") is Dictionary \
			or source.base.meta.get("code") != meta.get("code"):
		return {"error": "差量需要本图自己的生成基线。"}
	var base: Dictionary = source.base
	var problem := compatibility_problem(base.meta, meta)
	if problem != "":
		return {"error": problem}
	var grid := _compile_grid(base, authored, meta.layers)
	if grid.is_empty():
		return {"error": "瓦片或碰撞格位无效或重复。"}
	var result := {"error": "", "mode": mode, "meta": meta, "grid": grid, "objects": {}}
	if mode == CONTENT:
		var before := _object_index(base.get("objects", []))
		var after := _object_index(authored.get("objects", []))
		if not before.ok or not after.ok:
			return {"error": "摆放物列表或实例码无效，无法计算差量。"}
		var changes := {}
		for code in before.coded:
			var old: Dictionary = before.coded[code]
			if not after.coded.has(code):
				changes[code] = {"op": "remove", "base": old}
			elif not _same(old, after.coded[code]):
				if old.get("asset") != after.coded[code].get("asset"):
					return {"error": "实例 %s 更换了资产：保留旧码会改变其身份，请删除后重新摆放。" % code}
				changes[code] = {"op": "update", "base": old, "value": after.coded[code]}
		for code in after.coded:
			if not before.coded.has(code):
				changes[code] = {"op": "add", "value": after.coded[code]}
		result.objects = changes
		var default_layer: String = meta.layers[0].id
		result["decor_remove"] = _unmatched_decor(before.anonymous, after.anonymous, default_layer)
		result["decor_add"] = _unmatched_decor(after.anonymous, before.anonymous, default_layer)
		var original_spawn = base.get("spawn", [2, 2])
		var new_spawn = authored.get("spawn", [2, 2])
		if not _same(original_spawn, new_spawn):
			result["spawn"] = new_spawn
		var styles := {}
		for i in meta.layers.size():
			var edits := {}
			for key in LAYER_STYLE:
				if not _same(base.meta.layers[i].get(key), meta.layers[i].get(key)):
					edits[key] = meta.layers[i].get(key)
			if not edits.is_empty():
				styles[meta.layers[i].id] = edits
		result["layer_style"] = styles
	return result

## Computes a new map. A conflict never mutates or partly patches the runtime map.
static func apply(runtime: Dictionary, plan: Dictionary) -> Dictionary:
	if plan.get("error", "") != "" or not plan.has("mode"):
		return {"error": str(plan.get("error", "差量计划无效。"))}
	var meta = runtime.get("meta", {})
	if not meta is Dictionary:
		return {"error": "运行时地图元数据无效。"}
	var problem := compatibility_problem(meta, plan.meta)
	if problem != "":
		return {"error": problem}
	var objects: Array = []
	if plan.mode == CONTENT:
		var current := _object_index(runtime.get("objects", []))
		if not current.ok:
			return {"error": "运行时分块的摆放物列表或实例码无效。"}
		var updated := {}
		for code in plan.objects:
			var change: Dictionary = plan.objects[code]
			var row: Dictionary = current.coded.get(code, {})
			if change.op == "add":
				if not row.is_empty():
					return {"error": "新增实例 %s 与运行时分块重码。" % code}
				continue
			if row.is_empty() and change.op == "remove":
				continue
			if row.is_empty() or row.get("asset") != change.base.get("asset"):
				return {"error": "运行时实例 %s 缺失或资产身份不一致。" % code}
			if change.op == "update":
				updated[code] = _overlay_dict(row, change.base, change.value)
		var default_layer: String = meta.layers[0].id
		var removals := _decor_counts(plan.get("decor_remove", []), default_layer)
		for row in runtime.get("objects", []):
			var code := str(row.get("code", ""))
			if code.is_empty() and not removals.is_empty():
				var key := _decor_key(row, default_layer)
				if _consume(removals, key):
					continue
			if plan.objects.get(code, {}).get("op") != "remove":
				objects.append(updated.get(code, row))
		if not removals.is_empty():
			return {"error": "当前种子缺少要移除的原始无码摆放物，无法可靠识别位置；分块差量未应用。"}
		for code in plan.objects:
			if plan.objects[code].op == "add":
				objects.append(plan.objects[code].value)
		objects.append_array(plan.get("decor_add", []))
	var out := runtime.duplicate()
	if plan.mode == CONTENT:
		out["objects"] = objects.duplicate(true)
		if plan.has("spawn"):
			out["spawn"] = plan.spawn.duplicate()
		var styles: Dictionary = plan.get("layer_style", {})
		if not styles.is_empty():
			var layers: Array = meta.layers.duplicate(true)
			for layer: Dictionary in layers:
				for key in styles.get(layer.id, {}):
					var value = styles[layer.id][key]
					if value == null:
						layer.erase(key)
					else:
						layer[key] = value
			out["meta"] = meta.duplicate()
			out.meta.layers = layers
	var collision = _apply_grid(runtime.get("collision", []), plan.grid.collision, false)
	if collision == null or not runtime.get("tiles", {}) is Dictionary:
		return {"error": "运行时格位无效或重复。"}
	out["collision"] = collision
	var tiles: Dictionary = runtime.get("tiles", {}).duplicate()
	for layer in runtime.meta.get("layers", []):
		var id: String = layer.id
		var patched = _apply_grid(tiles.get(id, []), plan.grid.tiles[id], true)
		if patched == null:
			return {"error": "运行时瓦片格位无效或重复：%s。" % id}
		tiles[id] = patched
	out["tiles"] = tiles
	return {"error": "", "map": out}

static func _object_index(rows: Variant) -> Dictionary:
	var coded := {}
	var anonymous: Array = []
	if not rows is Array:
		return {"ok": false}
	for row in rows:
		if not row is Dictionary or not row.get("code", "") is String:
			return {"ok": false}
		var code: String = row.get("code", "")
		if code == "":
			anonymous.append(row)
		elif coded.has(code):
			return {"ok": false}
		else:
			coded[code] = row
	return {"ok": true, "coded": coded, "anonymous": anonymous}

## With no stable identity, an edit is removal of an exact baseline placement
## plus an addition. Counts distinguish intentional duplicates from row order.
static func _unmatched_decor(rows: Array, other: Array, default_layer: String) -> Array:
	var counts := _decor_counts(other, default_layer)
	var result: Array = []
	for row: Dictionary in rows:
		if not _consume(counts, _decor_key(row, default_layer)):
			result.append(row)
	return result

static func _decor_counts(rows: Array, default_layer: String) -> Dictionary:
	var counts := {}
	for row: Dictionary in rows:
		var key := _decor_key(row, default_layer)
		counts[key] = int(counts.get(key, 0)) + 1
	return counts

static func _consume(counts: Dictionary, key: String) -> bool:
	var count := int(counts.get(key, 0))
	if count == 0:
		return false
	if count == 1:
		counts.erase(key)
	else:
		counts[key] = count - 1
	return true

static func _decor_key(row: Dictionary, default_layer: String) -> String:
	var value := row.duplicate()
	value.erase("code")
	value["layer"] = row.get("layer", default_layer)
	for key in ["props", "transform", "functions"]:
		if row.get(key) in [null, {}, []]:
			value.erase(key)
	if row.get("visible", true):
		value.erase("visible")
	if row.get("zPolicy", "auto") in ["", "auto"]:
		value.erase("zPolicy")
	return JSON.stringify(_normalized_numbers(value), "", true, true)

static func _normalized_numbers(value: Variant) -> Variant:
	if value is int or value is float:
		return 0.0 if value == 0 else float(value)
	if value is Array:
		return value.map(_normalized_numbers)
	if value is Dictionary:
		var result := {}
		for key in value:
			result[key] = _normalized_numbers(value[key])
		return result
	return value

static func _overlay_dict(runtime: Dictionary, base: Dictionary, authored: Dictionary) -> Dictionary:
	var out := runtime.duplicate()
	for key in base:
		if not authored.has(key):
			if base[key] is Dictionary and runtime.get(key) is Dictionary:
				var retained := _overlay_dict(runtime[key], base[key], {})
				if not retained.is_empty():
					out[key] = retained
					continue
			out.erase(key)
	for key in authored:
		var value = authored[key]
		if base.has(key) and _same(base[key], value):
			continue
		if value is Dictionary and runtime.get(key) is Dictionary \
				and (not base.has(key) or base[key] is Dictionary):
			out[key] = _overlay_dict(runtime[key], base.get(key, {}), value)
		else:
			out[key] = value
	return out

static func _compile_grid(base: Dictionary, authored: Dictionary, layers: Array) -> Dictionary:
	if not base.get("tiles", {}) is Dictionary or not authored.get("tiles", {}) is Dictionary:
		return {}
	var collision := _compile_grid_rows(base.get("collision", []), authored.get("collision", []), false)
	if collision.is_empty():
		return {}
	var tiles := {}
	for row in layers:
		if not row.get("id") is String or str(row.id) == "" or tiles.has(row.id):
			return {}
		var id: String = row.id
		var changes := _compile_grid_rows(base.get("tiles", {}).get(id, []), authored.get("tiles", {}).get(id, []), true)
		if changes.is_empty():
			return {}
		tiles[id] = changes
	return {"collision": collision, "tiles": tiles}

static func _compile_grid_rows(base: Variant, authored: Variant, tile: bool) -> Dictionary:
	var before = _grid_index(base, tile)
	var after = _grid_index(authored, tile)
	if before == null or after == null:
		return {}
	var edits := {}
	for key in before:
		if not after.has(key):
			edits[key] = null
	for key in after:
		if not before.has(key) or not _same(before[key], after[key]):
			edits[key] = after[key]
	return {"edits": edits}

static func _apply_grid(runtime: Variant, patch: Dictionary, tile: bool) -> Variant:
	var result = _grid_index(runtime, tile)
	if result == null:
		return null
	for key in patch.edits:
		if patch.edits[key] == null:
			result.erase(key)
		else:
			result[key] = patch.edits[key]
	return result.values().duplicate(true)

static func _grid_index(rows: Variant, tile: bool) -> Variant:
	if not rows is Array:
		return null
	var cells := {}
	for row in rows:
		if (tile and not (row is Array and row.size() == 6)) or (not tile and not row is Dictionary):
			return null
		var x = row[0] if tile else row.get("x")
		var y = row[1] if tile else row.get("y")
		if not _integer(x) or not _integer(y):
			return null
		var key := Vector2i(int(row[0]), int(row[1])) if tile else Vector2i(int(row.x), int(row.y))
		if cells.has(key):
			return null
		cells[key] = row
	return cells

static func _integer(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) \
		and floorf(float(value)) == value and absi(int(value)) <= 2147483647

static func _same(a: Variant, b: Variant) -> bool:
	if (a is int or a is float) and (b is int or b is float):
		return a == b
	if typeof(a) != typeof(b):
		return false
	if a is Array:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not _same(a[i], b[i]):
				return false
		return true
	if a is Dictionary:
		if a.size() != b.size():
			return false
		for key in a:
			if not b.has(key) or not _same(a[key], b[key]):
				return false
		return true
	return a == b
