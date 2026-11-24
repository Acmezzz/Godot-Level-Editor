extends RefCounted
## Optional screen-space triangles supplied with the game frame, in hit priority order.

const MAX_BYTES := 1024 * 1024

static func read(bytes: PackedByteArray, token: String, size: Vector2i) -> Dictionary:
	if bytes.is_empty():
		return {"error": "画面选点数据为空或超过 1 MiB。"}
	var doc = JSON.parse_string(bytes.get_string_from_utf8())
	if not doc is Dictionary or doc.get("version") != 1 or doc.get("token") != token or not doc.get("regions") is Array:
		return {"error": "画面选点数据与本次请求不匹配。"}
	var regions: Array = []
	for row in doc.regions:
		if not row is Dictionary:
			continue
		var screen := _triangle(row.get("screen"))
		if screen.size() != 3 or Array(screen).any(func(p: Vector2): return not Rect2(Vector2.ZERO, Vector2(size)).grow(0.001).has_point(p)):
			continue
		var u := screen[1] - screen[0]
		var v := screen[2] - screen[0]
		if absf(u.cross(v)) < 0.001:
			continue
		var targets = row.get("targets", {})
		var placement = row.get("placement", {})
		var points := _triangle(placement.get("local")) if placement is Dictionary else PackedVector2Array()
		var layer := str(placement.get("layer", "")) if points.size() == 3 else ""
		regions.append({"screen": screen, "inverse": Transform2D(u, v, screen[0]).affine_inverse(),
			"label": str(row.get("label", "")).left(120), "targets": targets if targets is Dictionary else {},
			"layer": layer, "local": points})
	return {"regions": regions}

static func at(regions: Array, pixel: Vector2, mode: String) -> Dictionary:
	for region in regions:
		var uv: Vector2 = region.inverse * pixel
		if uv.x < -0.00001 or uv.y < -0.00001 or uv.x + uv.y > 1.00001:
			continue
		var value = region.targets.get(mode)
		if mode == "placement":
			if region.layer == "":
				continue
			var local: PackedVector2Array = region.local
			value = {"layer": region.layer, "point": local[0] + (local[1] - local[0]) * uv.x + (local[2] - local[0]) * uv.y}
		elif value == null:
			continue
		return {"value": value, "screen": region.screen, "label": region.label}
	return {}

static func _triangle(raw: Variant) -> PackedVector2Array:
	var out := PackedVector2Array()
	if not raw is Array or raw.size() != 3:
		return out
	for p in raw:
		if not p is Array or p.size() != 2 or not _number(p[0]) or not _number(p[1]):
			return PackedVector2Array()
		out.append(Vector2(p[0], p[1]))
	return out

static func _number(v: Variant) -> bool:
	return (v is int or v is float) and is_finite(float(v))
