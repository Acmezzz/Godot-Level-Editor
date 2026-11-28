extends RefCounted
## Compact authoring candidates derived from declarations and existing map usage.

const Assets := preload("res://src/assets/asset_decl.gd")
const Functions := preload("res://src/content/function_decl.gd")

static func functions(manifest: Dictionary, bindings: Array, map: Dictionary, trigger := "", recent := []) -> Array:
	var used := {}
	for object in map.get("objects", []):
		for row in object.get("functions", []):
			used[row.fn] = int(used.get(row.fn, 0)) + 1
	var bound := {}
	for row in bindings:
		var code: String = row.get("fn", "")
		bound[code] = int(bound.get(code, 0)) + 1
	var out := []
	var declarations := Functions.functions(manifest)
	for id in declarations:
		var decl: Dictionary = declarations[id]
		var code: String = decl.code
		if code == "" or (bound.has(code) and not decl.get("repeatable", false)):
			continue
		var timings := Functions.trigger_options(manifest, id)
		var compatible := trigger == "" or timings.has(trigger)
		var reason := "全库"
		if used.has(code):
			reason = "本图已用 %d 次" % used[code]
		elif id in recent:
			reason = "最近添加"
		if trigger != "" and compatible:
			reason = "%s · %s" % [timings[trigger], reason]
		out.append({"id": id, "name": decl.name, "code": code, "compatible": compatible,
			"description": str(decl.get("description", "")), "reason": reason, "timings": timings,
			"rank": (0 if compatible else 100) + (0 if used.has(code) else (1 if id in recent else 2))})
	out.sort_custom(func(a, b):
		return a.name.naturalnocasecmp_to(b.name) < 0 if a.rank == b.rank else a.rank < b.rank)
	return out

static func used_assets(map: Dictionary) -> Dictionary:
	var counts := {}
	for object in map.get("objects", []):
		var id: String = object.get("asset", "")
		if id != "":
			counts[id] = int(counts.get(id, 0)) + 1
	for layer in map.get("tiles", {}).values():
		for tile in layer:
			if tile.size() >= 3 and tile[2] is String:
				counts[tile[2]] = int(counts.get(tile[2], 0)) + 1
	return counts

static func asset_rows(manifest: Dictionary, map: Dictionary, kind := "") -> Array:
	var used := used_assets(map)
	var out := []
	for decl in Assets.of_kind(manifest, kind):
		var id := str(decl.get("id", ""))
		out.append({"id": id, "kind": str(decl.get("kind", "")),
			"name": Assets.label_of_decl(decl, id), "category": Assets.category_of_decl(decl),
			"used": int(used.get(id, 0)), "decl": decl})
	out.sort_custom(func(a, b):
		return a.name.naturalnocasecmp_to(b.name) < 0 if (a.used > 0) == (b.used > 0) else a.used > 0)
	return out
