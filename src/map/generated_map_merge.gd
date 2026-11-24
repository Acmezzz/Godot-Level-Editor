extends RefCounted
## Three-way merge of generator snapshots with the current author document.

const KEY := "generatorSource"
const GRID_KEYS := ["gridProjection", "gridTopology", "gridBasis"]
const SPACE_META := ["gridProjection", "gridTopology", "gridBasis", "w", "h", "layers", "cellGraph"]
const SPACE_ROWS := ["tiles", "collision", "objects", "spawn"]
const SHAPE_PROPS := ["points", "holes", "parts"]
const AssetDecl := preload("res://src/assets/asset_decl.gd")
const RefFields := preload("res://src/content/ref_fields.gd")
const Conditions := preload("res://src/content/condition_decl.gd")

static func origin(map: Dictionary) -> Dictionary:
	var meta: Dictionary = map.get("meta", {})
	var row = meta.get(KEY)
	if not row is Dictionary or row.get("version") != 1 or row.get("owner") != meta.get("code") \
			or not row.get("generator") is String or not row.get("parameters") is Dictionary \
			or not row.get("base") is Dictionary or not row.base.get("meta") is Dictionary \
			or row.base.meta.get("code") != meta.get("code"):
		return {}
	return row

static func attach(map: Dictionary, generated: Dictionary, generator: String, parameters: Dictionary) -> void:
	var base := generated.duplicate(true)
	base.meta.erase(KEY)
	map.meta[KEY] = {"version": 1, "owner": map.meta.code, "generator": generator,
		"parameters": parameters.duplicate(true), "base": base}

static func plan(previous: Dictionary, authored: Dictionary, generated: Dictionary, choices := {}, manifest := {}) -> Dictionary:
	var baseline := _normalized(previous, authored.meta.name)
	var current := _normalized(authored, authored.meta.name)
	var incoming := _normalized(generated, authored.meta.name)
	var state := {"conflicts": [], "choices": choices}
	if _grid_differs(current, incoming) and (
			(_grid_differs(baseline, current) and _spatial_changed(baseline, incoming))
			or (_grid_differs(baseline, incoming) and _spatial_changed(baseline, current))):
		# The selected coordinate system and its data must travel together. Merge the rest normally.
		var space: Dictionary = _resolve("格空间与摆放（投影、图层、瓦片、碰撞、实例、出生点和格图）",
			{"keep": true, "value": _space_summary(current), "side": current},
			{"keep": true, "value": _space_summary(incoming), "side": incoming}, state).side
		if not state.conflicts.is_empty():
			return {"map": current, "conflicts": state.conflicts}
		var placements: Array = space.objects
		var shared := _shared_instances(baseline.objects, current.objects, incoming.objects)
		var spatial_fields := {}
		for row in placements:
			if shared.has(row.get("code", "")) and not spatial_fields.has(row.asset):
				var fields: Array = AssetDecl.by_id(manifest, row.asset).get("fields", [])
				spatial_fields[row.asset] = SHAPE_PROPS + _spatial_keys(manifest, fields)
		for map in [baseline, current, incoming]:
			_use_space(map, space, placements, shared, spatial_fields)
	var result: Dictionary = _merge(baseline, current, incoming, "", state)
	return {"map": result, "conflicts": state.conflicts}

static func _spatial_changed(before: Dictionary, other: Dictionary) -> bool:
	for key in SPACE_ROWS:
		if not _same(before.get(key), other.get(key)):
			return true
	for key in SPACE_META:
		if not _same(before.meta.get(key), other.meta.get(key)):
			return true
	return false

static func _grid_differs(before: Dictionary, other: Dictionary) -> bool:
	return GRID_KEYS.any(func(key): return not _same(before.meta.get(key), other.meta.get(key)))

static func _space_summary(map: Dictionary) -> Dictionary:
	return {"投影": map.meta.get("gridProjection", "项目默认"), "拓扑": map.meta.get("gridTopology", "quads"),
		"图层": map.meta.layers.size(), "瓦片": map.tiles.values().reduce(func(n, rows): return n + rows.size(), 0),
		"碰撞格": map.collision.size(), "实例": map.objects.size(), "出生点": map.spawn}

static func _shared_instances(base: Array, current: Array, incoming: Array) -> Dictionary:
	var left := _instances_by_code(current)
	var right := _instances_by_code(incoming)
	var shared := {}
	for row in base:
		var code: String = row.get("code", "")
		if left.has(code) and right.has(code) and left[code].asset == row.asset and right[code].asset == row.asset:
			shared[code] = true
	return shared

static func _instances_by_code(rows: Array) -> Dictionary:
	var indexed := {}
	for row in rows:
		var code: String = row.get("code", "")
		if code != "":
			indexed[code] = row
	return indexed

static func _spatial_keys(manifest: Dictionary, fields: Array) -> Array:
	var keys := []
	for field in fields:
		var local: bool = field.get("pickSpace", "") in ["map", "layer"] \
			or RefFields.describe(field).kind in ["cell", "edge", "layer"]
		if field.get("type") == "array":
			match field.get("of", ""):
				"record":
					local = not _spatial_keys(manifest, field.get("fields", [])).is_empty()
				"condition":
					for id in field.get("allowedConditions", []):
						if not _spatial_keys(manifest, Conditions.condition_decl(manifest, id).get("fields", [])).is_empty():
							local = true
							break
		if local:
			keys.append(field.id)
			for pair in ["mapField", "layerField"]:
				if field.has(pair):
					keys.append(field[pair])
	return keys

static func _use_space(map: Dictionary, from: Dictionary, placements: Array, shared: Dictionary, spatial_fields: Dictionary) -> void:
	for key in SPACE_META:
		if from.meta.has(key):
			map.meta[key] = from.meta[key]
		else:
			map.meta.erase(key)
	for key in ["tiles", "collision", "spawn"]:
		map[key] = from[key]
	var originals := _instances_by_code(map.objects)
	var aligned := []
	for placement in placements:
		var code: String = placement.get("code", "")
		if not shared.has(code):
			aligned.append(placement)
			continue
		var row: Dictionary = placement.duplicate()
		var settings: Dictionary = originals[code]
		var props: Dictionary = settings.get("props", {}).duplicate()
		var shape: Dictionary = placement.get("props", {})
		for key in spatial_fields[row.asset]:
			props.erase(key)
			if shape.has(key):
				props[key] = shape[key]
		row["props"] = props
		row["functions"] = settings.get("functions", [])
		aligned.append(row)
	map.objects = aligned

static func _normalized(map: Dictionary, name_: String) -> Dictionary:
	var out := map.duplicate(true)
	out.meta.erase(KEY)
	out.meta.name = name_
	out["spawn"] = out.get("spawn", [2, 2])
	out["tiles"] = out.get("tiles", {}) if out.get("tiles") is Dictionary else {}
	for row in out.meta.layers:
		if not out.tiles.has(row.id):
			out.tiles[row.id] = []
	out["collision"] = out.get("collision", [])
	out["objects"] = out.get("objects", [])
	for row in out.objects:
		if not row.has("layer"):
			row["layer"] = out.meta.layers[0].id
		if row.get("props") == null or row.get("props") == {}:
			row.erase("props")
		if row.get("transform") == null or row.get("transform") == {}:
			row.erase("transform")
		if row.get("functions") == null or row.get("functions") == []:
			row.erase("functions")
		if row.get("visible", true):
			row.erase("visible")
		if str(row.get("zPolicy", "auto")) in ["", "auto"]:
			row.erase("zPolicy")
		row.x = snappedf(float(row.x), 0.001)
		row.y = snappedf(float(row.y), 0.001)
	return out

static func _merge(base: Variant, live: Variant, incoming: Variant, path: String, state: Dictionary) -> Variant:
	if _same(incoming, base) or _same(incoming, live):
		return live
	if _same(live, base):
		return incoming
	if live is Dictionary and incoming is Dictionary and (base is Dictionary or (base == null and _tile_layer(path))):
		var original: Dictionary = base if base is Dictionary else {}
		var output := {}
		var keys := original.duplicate()
		keys.merge(live)
		keys.merge(incoming)
		for key in keys:
			var segment := str(key)
			var at := (segment if path == "" else path + "." + segment) if segment.is_valid_identifier() \
				else path + "[" + JSON.stringify(segment) + "]"
			var has := _merge_presence(original, live, incoming, key, at, state)
			if has.keep:
				output[key] = has.value
		return output
	if live is Array and incoming is Array and (base is Array or (base == null and _tile_layer(path))):
		var mode := "tile" if _tile_layer(path) else path
		if mode in ["tile", "collision", "objects"]:
			var original: Array = base if base is Array else []
			var keyed: Variant = _merge_rows(original, live, incoming, mode, path, state)
			if keyed is Array:
				return keyed
	return _resolve(path, {"keep": true, "value": live}, {"keep": true, "value": incoming}, state).value

static func _resolve(path: String, authored: Dictionary, generated: Dictionary, state: Dictionary) -> Dictionary:
	match state.choices.get(path, ""):
		"authored": return authored
		"generated": return generated
	state.conflicts.append({"path": path, "authored": authored, "generated": generated})
	return authored

static func _merge_presence(base: Dictionary, live: Dictionary, next: Dictionary, key: Variant,
		path: String, state: Dictionary) -> Dictionary:
	var b := base.has(key)
	var l := live.has(key)
	var n := next.has(key)
	var before = base.get(key)
	var current = live.get(key)
	var incoming = next.get(key)
	if n == b and _same(incoming, before):
		return {"keep": l, "value": current}
	if l == b and _same(current, before):
		return {"keep": n, "value": incoming}
	if l != n:
		return _resolve(path, {"keep": l, "value": current}, {"keep": n, "value": incoming}, state)
	return {"keep": l, "value": _merge(before, current, incoming, path, state) if l else null}

static func _tile_layer(path: String) -> bool:
	return path.begins_with("tiles.") or path.begins_with("tiles[")

static func _merge_rows(base: Array, live: Array, incoming: Array, mode: String,
		path: String, state: Dictionary) -> Variant:
	var b := _index(base, mode)
	var l := _index(live, mode)
	var n := _index(incoming, mode)
	if b.size() != base.size() or l.size() != live.size() or n.size() != incoming.size():
		return null
	# Object order affects draw order. If both sides make incompatible order edits,
	# flag it. New rows are added after the existing relative order.
	var selected := l
	if mode == "objects":
		var common := b.keys().filter(func(k): return l.has(k) and n.has(k))
		var left := l.keys().filter(func(k): return b.has(k) and n.has(k))
		var right := n.keys().filter(func(k): return b.has(k) and l.has(k))
		if left != right and left != common and right != common:
			var choice := _resolve(path + "（绘制顺序）", {"keep": true, "value": left},
				{"keep": true, "value": right}, state)
			if is_same(choice.value, right):
				selected = n
		elif left == common and right != common:
			selected = n
	var order := selected.keys()
	var extras := n if is_same(selected, l) else l
	for key in extras:
		if not selected.has(key):
			order.append(key)
	var out := []
	for key in order:
		var key_label := JSON.stringify(key) if mode == "objects" else str(key)
		var entry := _merge_presence(b, l, n, key, "%s[%s]" % [path, key_label], state)
		if entry.keep:
			out.append(entry.value)
	return out

static func _index(rows: Array, mode: String) -> Dictionary:
	var out := {}
	for row in rows:
		var key: String
		match mode:
			"tile": key = "%d,%d" % [row[0], row[1]]
			"collision": key = "%d,%d" % [row.x, row.y]
			_: key = str(row.get("code", ""))
		if key.is_empty() or out.has(key):
			return {}
		out[key] = row
	return out

static func _same(a: Variant, b: Variant) -> bool:
	if (a is int or a is float) and (b is int or b is float):
		return a == b
	if typeof(a) != typeof(b):
		return false
	if a is Dictionary:
		if a.size() != b.size():
			return false
		for key in a:
			if not b.has(key) or not _same(a[key], b[key]):
				return false
		return true
	if a is Array:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not _same(a[i], b[i]):
				return false
		return true
	return a == b
