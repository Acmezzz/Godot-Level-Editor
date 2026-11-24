extends RefCounted
## Ordered screen elements; edges are anchors relative to the viewport plus pixel offsets.

const KINDS := ["panel", "text", "button"]
const FALLBACK_SIZE := Vector2(1280, 720)
const DIRECTIONS := {"left": Vector2.LEFT, "right": Vector2.RIGHT, "up": Vector2.UP, "down": Vector2.DOWN}
const DEFAULT_FONT_SIZE := 24
const IMAGE_FITS := ["contain", "cover", "stretch"]

static func modules(manifest: Dictionary) -> Dictionary:
	var declarations = manifest.get("screenModules", {})
	return declarations if declarations is Dictionary else {}

static func image_assets(manifest: Dictionary) -> Dictionary:
	var out := {}
	var rows = manifest.get("assets", [])
	for row in rows if rows is Array else []:
		if row is Dictionary and row.get("kind") == "scene" and row.get("shape") == "image" \
				and row.get("id") is String and image_path(row.get("texture")) != "":
			out[row.id] = row
	return out

static func image_path(value: Variant) -> String:
	if not value is String:
		return ""
	var path: String = value.replace("\\", "/")
	if path.is_empty() or path.begins_with("/") or ":" in path or ".." in path.split("/"):
		return ""
	return path

## Destination and source rectangles are clipped together, so cropping the viewport
## never shifts or resizes the image inside its authored bounds.
static func image_placement(bounds: Rect2, clip: Rect2, pixels: Vector2, fit: String) -> Dictionary:
	if not bounds.has_area() or pixels.x <= 0.0 or pixels.y <= 0.0:
		return {}
	var dest := bounds
	if fit != "stretch":
		var ratio := bounds.size / pixels
		var fitted := pixels * (maxf(ratio.x, ratio.y) if fit == "cover" else minf(ratio.x, ratio.y))
		dest = Rect2(bounds.get_center() - fitted * 0.5, fitted)
	var visible := dest.intersection(bounds).intersection(clip)
	if not visible.has_area():
		return {}
	var to_source := pixels / dest.size
	return {"dest": visible, "source": Rect2((visible.position - dest.position) * to_source, visible.size * to_source)}

static func locale_key(raw: String) -> String:
	return raw.strip_edges().replace("_", "-").to_lower()

static func valid_locale(tag: String) -> bool:
	if tag.is_empty() or tag.length() > 48 or tag != locale_key(tag):
		return false
	var parts := tag.split("-")
	for i in parts.size():
		var token := parts[i]
		if token.is_empty() or token.length() > 8:
			return false
		for character in token:
			if not ("abcdefghijklmnopqrstuvwxyz".contains(character) or (i > 0 and "0123456789".contains(character))):
				return false
	return true

static func display_text(element: Dictionary, locale: String) -> String:
	var variants: Dictionary = element.get("textLocales", {})
	var key := locale_key(locale)
	while key != "":
		if variants.has(key):
			return str(variants[key])
		var split := key.rfind("-")
		key = key.substr(0, split) if split >= 0 else ""
	return str(element.get("text", ""))

static func focusable(element: Variant) -> bool:
	if not element is Dictionary:
		return false
	var kind = element.get("kind")
	return kind in ["button", "module"] and element.get("focusable", kind == "button") == true

static func visible_focus(elements: Array, viewport: Vector2) -> Array:
	var bounds := Rect2(Vector2.ZERO, viewport)
	return elements.filter(func(row):
		if not focusable(row):
			return false
		var r := rect(row, viewport)
		return r.has_area() and r.intersection(bounds).has_area())

static func focus_start(layout: Dictionary, elements: Array, viewport: Vector2) -> String:
	var options := visible_focus(elements, viewport)
	var initial := str(layout.get("focusStart", ""))
	for row in options:
		if row.id == initial:
			return initial
	return str(options[0].id) if not options.is_empty() else ""

static func focus_step(layout: Dictionary, elements: Array, current: String, action: String, viewport: Vector2) -> String:
	var options := visible_focus(elements, viewport)
	var selected := -1
	for i in options.size():
		if options[i].id == current:
			selected = i
			break
	if selected < 0:
		return focus_start(layout, elements, viewport)
	if action in ["next", "previous"]:
		return str(options[posmod(selected + (1 if action == "next" else -1), options.size())].id)
	if not DIRECTIONS.has(action):
		return current
	var row: Dictionary = options[selected]
	var explicit := str(row.get("focus", {}).get(action, ""))
	if explicit != "" and options.any(func(item): return item.id == explicit):
		return explicit
	var start := rect(row, viewport).get_center()
	var direction: Vector2 = DIRECTIONS[action]
	var best := INF
	var target := current
	for other in options:
		if other.id == current:
			continue
		var delta := rect(other, viewport).get_center() - start
		var forward := delta.dot(direction)
		if forward <= 0.0:
			continue
		var score := forward + absf(delta.cross(direction)) * 2.0
		if score < best:
			best = score
			target = str(other.id)
	return target

static func clear_focus_links(layout: Dictionary, elements: Array, id: String) -> void:
	if layout.get("focusStart") == id:
		layout.erase("focusStart")
	for row in elements:
		if not row is Dictionary or not row.get("focus") is Dictionary:
			continue
		var links: Dictionary = row.focus
		if row.id == id:
			row.erase("focus")
			continue
		for key in links.keys():
			if links[key] == id:
				links.erase(key)
		if links.is_empty():
			row.erase("focus")

static func sizes(manifest: Dictionary) -> Dictionary:
	var out := {}
	var rows = manifest.get("viewports", [])
	for row in rows if rows is Array else []:
		if row is Dictionary and row.get("id") is String and _number(row.get("w")) \
				and _number(row.get("h")) and row.w > 0 and row.h > 0:
			out[row.id] = Vector2(row.w, row.h)
	return out

static func rect(element: Dictionary, viewport: Vector2) -> Rect2:
	var a: Array = element.anchors
	var o: Array = element.get("offsets", [0, 0, 0, 0])
	var start := Vector2(a[0], a[1]) * viewport + Vector2(o[0], o[1])
	var end := Vector2(a[2], a[3]) * viewport + Vector2(o[2], o[3])
	return Rect2(start, end - start)

static func validate(layout: Variant, viewports: Dictionary, path: String, issues: Array[Dictionary],
		declarations := {}) -> void:
	if not layout is Dictionary:
		_error(issues, path, "must be an object")
		return
	var vp = layout.get("viewport", "")
	if not vp is String or (vp != "" and not viewports.has(vp)):
		_error(issues, path + ".viewport", "must be empty or name a declared viewport")
	var elements = layout.get("elements", [])
	var locales = layout.get("locales", [])
	var locale_ids := {}
	if not locales is Array:
		_error(issues, path + ".locales", "must be an array of locale tags")
	else:
		for i in locales.size():
			var tag = locales[i]
			if not tag is String or not valid_locale(tag) or locale_ids.has(tag):
				_error(issues, "%s.locales[%d]" % [path, i], "must be a unique lowercase locale tag")
			else:
				locale_ids[tag] = true
	if not elements is Array:
		_error(issues, path + ".elements", "must be an array")
		return
	var used := {}
	var focus_ids := {}
	for i in elements.size():
		var row = elements[i]
		var p := "%s.elements[%d]" % [path, i]
		if not row is Dictionary:
			_error(issues, p, "must be an object")
			continue
		var id = row.get("id")
		if not id is String or id.strip_edges() == "" or used.has(id):
			_error(issues, p + ".id", "must be non-empty and unique within this layout")
		else:
			used[id] = true
			if focusable(row):
				focus_ids[id] = true
		if row.get("kind") == "module":
			if not row.get("module") is String or not declarations.has(row.module):
				_error(issues, p + ".module", "must name a declared screen module")
			if row.has("props") and not row.props is Dictionary:
				_error(issues, p + ".props", "must be an object keyed by field ID")
		elif not KINDS.has(row.get("kind")):
			_error(issues, p + ".kind", "must be panel, text, button or module")
		var a = row.get("anchors")
		var o = row.get("offsets", [0, 0, 0, 0])
		var valid: bool = _four(a) and a.all(func(v): return v >= 0.0 and v <= 1.0) and a[0] <= a[2] and a[1] <= a[3]
		if not valid:
			_error(issues, p + ".anchors", "must be ordered [left, top, right, bottom] in 0..1")
		if not _four(o):
			_error(issues, p + ".offsets", "must be four finite pixel offsets")
		elif valid:
			var r := rect(row, viewports.get(vp, FALLBACK_SIZE))
			if not r.has_area() or not r.is_finite():
				_error(issues, p, "must have positive width and height in the design viewport")
		for key in ["text", "style"]:
			if row.has(key) and not row[key] is String:
				_error(issues, p + "." + key, "must be a string")
		if row.has("imageAsset") and (not row.imageAsset is String or row.imageAsset.strip_edges() == ""):
			_error(issues, p + ".imageAsset", "must be a non-empty scene image asset ID")
		if row.has("imageFit") and (not row.has("imageAsset") or not IMAGE_FITS.has(row.imageFit)):
			_error(issues, p + ".imageFit", "requires imageAsset and must be contain, cover or stretch")
		var font_size = row.get("fontSize", DEFAULT_FONT_SIZE)
		if not _number(font_size) or font_size < 8 or font_size > 256 or floorf(float(font_size)) != font_size:
			_error(issues, p + ".fontSize", "must be an integer from 8 to 256")
		var translations = row.get("textLocales", {})
		if not translations is Dictionary:
			_error(issues, p + ".textLocales", "must be an object keyed by locale")
		else:
			for tag in translations:
				if not locale_ids.has(tag) or not translations[tag] is String or translations[tag].is_empty():
					_error(issues, p + ".textLocales." + str(tag), "must be non-empty text under a declared layout locale")
		if row.has("target") and not row.target is Dictionary:
			_error(issues, p + ".target", "must be an object")
		if row.has("focusable") and (row.get("kind") not in ["button", "module"] or not row.focusable is bool):
			_error(issues, p + ".focusable", "must be a boolean on a button or screen module")
	if layout.has("focusStart") and (not layout.focusStart is String or not focus_ids.has(layout.focusStart)):
		_error(issues, path + ".focusStart", "must name a focusable element")
	for i in elements.size():
		var row = elements[i]
		if not row is Dictionary or not row.has("focus"):
			continue
		var p := "%s.elements[%d].focus" % [path, i]
		if not focusable(row) or not row.focus is Dictionary:
			_error(issues, p, "must be an object on a focusable element")
			continue
		for direction in row.focus:
			var target = row.focus[direction]
			if not DIRECTIONS.has(direction) or not target is String or not focus_ids.has(target):
				_error(issues, p + "." + str(direction), "must be a direction (left/right/up/down) naming a focusable element")

static func _four(value: Variant) -> bool:
	return value is Array and value.size() == 4 and value.all(_number)

static func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))

static func _error(issues: Array[Dictionary], path: String, message: String) -> void:
	issues.append({"path": path, "message": message, "severity": "error"})
