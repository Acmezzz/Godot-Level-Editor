extends RefCounted
## Project-space chunk footprints. Their overlap is intentional; games choose how to load them.

const LIMIT := 10000000
const GENERATED_KEY_LIMIT := 120
static func issues(manifest: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not manifest.has("worldLayout"):
		return out
	var layout = manifest.worldLayout
	if not layout is Dictionary or layout.get("version") != 1 or not layout.get("chunks") is Dictionary:
		return [{"severity": "error", "path": "worldLayout", "message": "requires version 1 and a chunks object"}]
	var generated_keys := {}
	for code in layout.chunks:
		var row = layout.chunks[code]
		if not code is String or code.is_empty() or not row is Dictionary \
				or not _pair(row.get("origin"), -LIMIT) or not _pair(row.get("size"), 1):
			out.append({"severity": "error", "path": "worldLayout.chunks." + str(code),
				"message": "requires a map code, integer origin [x,y] and positive integer size [w,h] within the coordinate limit"})
			continue
		if not row.has("generatedKey"):
			continue
		var key = row.generatedKey
		var path := "worldLayout.chunks.%s.generatedKey" % code
		if not valid_generated_key(key):
			out.append({"severity": "error", "path": path, "message": "requires a trimmed, printable key of 1–120 characters"})
		elif generated_keys.has(key):
			out.append({"severity": "error", "path": path, "message": "duplicate generated chunk key on map " + str(generated_keys[key])})
		else:
			generated_keys[key] = code
	return out

static func valid_generated_key(value: Variant) -> bool:
	if not value is String or value.is_empty() or value.length() > GENERATED_KEY_LIMIT or value != value.strip_edges():
		return false
	for i in value.length():
		var scalar: int = value.unicode_at(i)
		if scalar < 32 or (scalar >= 127 and scalar <= 159):
			return false
	return true

static func _pair(value: Variant, minimum: int) -> bool:
	if not value is Array or value.size() != 2:
		return false
	for n in value:
		if not (n is int or n is float) or not is_finite(float(n)) or n != floorf(n) or n < minimum or n > LIMIT:
			return false
	return true

static func rect(row: Dictionary) -> Rect2:
	return Rect2(Vector2(row.origin[0], row.origin[1]), Vector2(row.size[0], row.size[1]))
