extends RefCounted
## Shared storage and code allocation for manifest declaration pools.

const ContentId := preload("res://src/content/content_id.gd")

static func fingerprint(m: Dictionary, key: String) -> String:
	var dir := str(m.get("_dir", ""))
	var pool = m.get(key, null)
	if pool is Array:
		return "%s\u0001%d" % [dir, (pool as Array).hash()]
	if pool is Dictionary:
		return "%s\u0001%d" % [dir, (pool as Dictionary).hash()]
	return "%s\u0001-" % dir

static func items(decl) -> Array:
	var out: Array = []
	if decl is Dictionary:
		for key in (decl as Dictionary):
			var body = (decl as Dictionary)[key]
			if body is Dictionary:
				out.append({"id": str(key), "body": body})
	elif decl is Array:
		for item in (decl as Array):
			if item is Dictionary:
				out.append({"id": str((item as Dictionary).get("id", "")), "body": item})
	return out

static func named_rows(decl) -> Dictionary:
	var out := {}
	for pair in items(decl):
		var id: String = pair.id
		if id == "":
			continue
		var row: Dictionary = pair.body.duplicate(true)
		row["id"] = id
		row["name"] = str(row.get("name", ""))
		if row.name == "":
			row.name = id
		row["code"] = str(row.get("code", ""))
		out[id] = row
	return out

static func ensure_entry_codes(rows: Array) -> bool:
	var occupied := {}
	for row in rows:
		var code := str(row.body.get("code", ""))
		if code != "":
			occupied[code] = true
	var changed := false
	for row in rows:
		if str(row.body.get("code", "")) == "":
			row.body["code"] = allocate_code(occupied)
			changed = true
	return changed

static func allocate_code(occupied: Dictionary) -> String:
	var code := ContentId.new_fn_code()
	while occupied.has(code):
		code = ContentId.new_fn_code()
	occupied[code] = true
	return code
