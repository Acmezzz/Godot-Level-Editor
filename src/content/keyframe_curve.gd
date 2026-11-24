extends RefCounted
## Scalar keyframes. Each key controls the interval to its right.

const MODES := ["linear", "hold", "smooth"]

static func valid(value: Variant) -> bool:
	if not value is Array:
		return false
	var previous := -INF
	for key in value:
		if not key is Dictionary or not number(key.get("time")) or not number(key.get("value")):
			return false
		var time: float = key.time
		if time < 0.0 or time <= previous or key.get("mode", "linear") not in MODES:
			return false
		previous = time
	return true

static func number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))

static func interpolate(a: Dictionary, b: Dictionary, ratio: float) -> float:
	match a.get("mode", "linear"):
		"hold": return a.value if ratio < 1.0 else b.value
		"smooth": ratio = ratio * ratio * (3.0 - 2.0 * ratio)
	return lerpf(a.value, b.value, ratio)
