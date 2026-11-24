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
		var placement := _mapping(row.get("placement"))
		if not placement.is_empty():
			var layer := str(row.placement.get("layer", ""))
			if layer.is_empty():
				placement = {}
			else:
				placement["layer"] = layer
		regions.append({"screen": screen, "inverse": Transform2D(u, v, screen[0]).affine_inverse(),
			"label": str(row.get("label", "")).left(120), "targets": targets if targets is Dictionary else {},
			"placement": placement, "collision": _mapping(row.get("collision")), "occludes": row.get("occludes") == true})
	return {"regions": regions}

static func _mapping(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {}
	var points := _triangle(value.get("local"))
	if points.size() != 3:
		return {}
	var reciprocal := Vector3.ONE
	if value.has("reciprocalW"):
		var raw = value.reciprocalW
		if not raw is Array or raw.size() != 3 or not raw.all(func(w): return _number(w) and w > 0.0):
			return {}
		var greatest := maxf(float(raw[0]), maxf(float(raw[1]), float(raw[2])))
		reciprocal = Vector3(float(raw[0]) / greatest, float(raw[1]) / greatest, float(raw[2]) / greatest)
		if minf(reciprocal.x, minf(reciprocal.y, reciprocal.z)) <= 0.0:
			return {}
	return {"local": points, "reciprocal": reciprocal}

static func at(regions: Array, pixel: Vector2, mode: String) -> Dictionary:
	for region in regions:
		var uv: Vector2 = region.inverse * pixel
		if uv.x < -0.00001 or uv.y < -0.00001 or uv.x + uv.y > 1.00001:
			continue
		var value = region.targets.get(mode)
		if mode == "objectEdit":
			value = region.targets.get("vertex", region.targets.get("entity"))
		if mode in ["placement", "collision"]:
			var mapping: Dictionary = region[mode]
			if mapping.is_empty():
				if region.occludes:
					break
				continue
			value = {"point": _local_point(mapping, uv)}
			if mode == "placement":
				value["layer"] = mapping.layer
		elif value == null:
			if region.occludes:
				break
			continue
		return {"value": value, "screen": region.screen, "label": region.label}
	return {}

## Split at triangle boundaries before mapping a stroke. Even a narrow foreground
## blocker or a gap between separate projections must not be bridged in map space.
static func brush_spans(regions: Array, a: Vector2, b: Vector2, mode: String) -> Array:
	var breaks: Array[float] = [0.0, 1.0]
	var candidates := []
	for region in regions:
		var mapping: Dictionary = region[mode]
		if mapping.is_empty() and not region.occludes:
			continue
		var inv: Transform2D = region.inverse
		var lo: Vector2 = inv * a
		var hi: Vector2 = inv * b
		var start := Vector3(lo.x, lo.y, 1.0 - lo.x - lo.y)
		var end := Vector3(hi.x, hi.y, 1.0 - hi.x - hi.y)
		var entry := 0.0
		var exit := 1.0
		for k in 3:
			if start[k] < 0.0 and end[k] < 0.0:
				entry = 2.0
				break
			if start[k] < 0.0:
				entry = maxf(entry, start[k] / (start[k] - end[k]))
			elif end[k] < 0.0:
				exit = minf(exit, start[k] / (start[k] - end[k]))
		if entry >= exit:
			continue
		breaks.append(entry)
		breaks.append(exit)
		candidates.append({"entry": entry, "exit": exit, "inverse": inv, "mapping": mapping})
	breaks.sort()
	var spans := []
	for i in breaks.size() - 1:
		var t0 := breaks[i]
		var t1 := breaks[i + 1]
		if t1 <= t0:
			continue
		var mid := (t0 + t1) * 0.5
		for c in candidates:
			if mid < c.entry or mid > c.exit:
				continue
			var mapping: Dictionary = c.mapping
			if not mapping.is_empty():
				var p := a.lerp(b, t0)
				var q := a.lerp(b, t1)
				var inverse: Transform2D = c.inverse
				spans.append({"layer": mapping.get("layer", ""), "a": _local_point(mapping, inverse * p),
					"b": _local_point(mapping, inverse * q), "screen_a": p, "screen_b": q})
			break
	return spans

static func _local_point(region: Dictionary, uv: Vector2) -> Vector2:
	var local: PackedVector2Array = region.local
	var bary := Vector3(maxf(1.0 - uv.x - uv.y, 0.0), maxf(uv.x, 0.0), maxf(uv.y, 0.0))
	var weight := bary * (region.reciprocal as Vector3)
	var total := weight.x + weight.y + weight.z
	return (local[0] * weight.x + local[1] * weight.y + local[2] * weight.z) / total

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
