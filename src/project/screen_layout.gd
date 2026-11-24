extends RefCounted
## Flat draw order with edges anchored to a parent element or the viewport.

const KINDS := ["panel", "text", "button"]
const FALLBACK_SIZE := Vector2(1280, 720)
const DIRECTIONS := {"left": Vector2.LEFT, "right": Vector2.RIGHT, "up": Vector2.UP, "down": Vector2.DOWN}
const DEFAULT_FONT_SIZE := 24
const IMAGE_FITS := ["contain", "cover", "stretch"]

static func modules(manifest: Dictionary) -> Dictionary:
	var declarations = manifest.get("screenModules", {})
	return declarations if declarations is Dictionary else {}

## Preserve an existing binding if the game removes its declaration, so it can be disconnected.
static func output_labels(declarations: Dictionary, element: Dictionary) -> Dictionary:
	var labels: Dictionary = declarations.get(element.get("module", ""), {}).get("outputs", {}).duplicate()
	for id in element.get("outputs", {}):
		if not labels.has(id):
			labels[id] = id
	return labels

static func target_at(row: Dictionary, output: String) -> Variant:
	return row.get("target") if output.is_empty() else row.get("outputs", {}).get(output)

static func set_target(row: Dictionary, output: String, target: Dictionary) -> void:
	if output.is_empty():
		if target.is_empty():
			row.erase("target")
		else:
			row["target"] = target
		return
	var outputs: Dictionary = row.get("outputs", {})
	if target.is_empty():
		outputs.erase(output)
	else:
		outputs[output] = target
	if outputs.is_empty():
		row.erase("outputs")
	else:
		row["outputs"] = outputs

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
	return _visible_focus(elements, viewport, rectangles(elements, viewport))

static func _visible_focus(elements: Array, viewport: Vector2, resolved: Dictionary) -> Array:
	var bounds := Rect2(Vector2.ZERO, viewport)
	return elements.filter(func(row):
		if not focusable(row):
			return false
		var r: Rect2 = resolved.get(row.id, Rect2())
		return r.has_area() and r.intersection(bounds).has_area())

static func focus_start(layout: Dictionary, elements: Array, viewport: Vector2) -> String:
	return _initial_focus(layout, visible_focus(elements, viewport))

static func _initial_focus(layout: Dictionary, options: Array) -> String:
	var initial := str(layout.get("focusStart", ""))
	for row in options:
		if row.id == initial:
			return initial
	return str(options[0].id) if not options.is_empty() else ""

static func focus_step(layout: Dictionary, elements: Array, current: String, action: String, viewport: Vector2) -> String:
	var resolved := rectangles(elements, viewport)
	var options := _visible_focus(elements, viewport, resolved)
	var selected := -1
	for i in options.size():
		if options[i].id == current:
			selected = i
			break
	if selected < 0:
		return _initial_focus(layout, options)
	if action in ["next", "previous"]:
		return str(options[posmod(selected + (1 if action == "next" else -1), options.size())].id)
	if not DIRECTIONS.has(action):
		return current
	var row: Dictionary = options[selected]
	var explicit := str(row.get("focus", {}).get(action, ""))
	if explicit != "" and options.any(func(item): return item.id == explicit):
		return explicit
	var start: Vector2 = resolved[row.id].get_center()
	var direction: Vector2 = DIRECTIONS[action]
	var best := INF
	var target := current
	for other in options:
		if other.id == current:
			continue
		var delta: Vector2 = resolved[other.id].get_center() - start
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

static func _rect(element: Dictionary, reference: Rect2) -> Rect2:
	var a: Array = element.anchors
	var o: Array = element.get("offsets", [0, 0, 0, 0])
	var start := Vector2(a[0], a[1]) * reference.size + Vector2(o[0], o[1])
	var end := Vector2(a[2], a[3]) * reference.size + Vector2(o[2], o[3])
	return Rect2(reference.position + start, end - start)

## Resolve parent geometry in linear time, independently of draw order and without recursion.
static func rectangles(elements: Array, viewport: Vector2) -> Dictionary:
	var root := Rect2(Vector2.ZERO, viewport)
	var children := _children_by_parent(elements)
	var resolved := {}
	var pending: Array = children.get("", []).duplicate()
	while not pending.is_empty():
		var row: Dictionary = pending.pop_back()
		var parent: String = row.get("parent", "")
		resolved[row.id] = _rect(row, resolved.get(parent, root))
		pending.append_array(children.get(row.id, []))
	return resolved

static func _children_by_parent(elements: Array) -> Dictionary:
	var children := {}
	for row in elements:
		var parent: String = row.get("parent", "")
		if not children.has(parent):
			children[parent] = []
		children[parent].append(row)
	return children

static func subtree_ids(elements: Array, id: String) -> Dictionary:
	var children := _children_by_parent(elements)
	var visited := {id: true}
	var pending := [id]
	while not pending.is_empty():
		for child in children.get(pending.pop_back(), []):
			if not visited.has(child.id):
				visited[child.id] = true
				pending.append(child.id)
	return visited

## Keep the design rectangle and existing anchors when changing coordinate space.
static func reparent(element: Dictionary, parent: String, bounds: Rect2, reference: Rect2) -> void:
	if parent == "":
		element.erase("parent")
	else:
		element["parent"] = parent
	var a: Array = element.anchors
	var start := bounds.position - reference.position - Vector2(a[0], a[1]) * reference.size
	var end := bounds.end - reference.position - Vector2(a[2], a[3]) * reference.size
	element["offsets"] = [start.x, start.y, end.x, end.y]

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
	var geometry := []
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
			used[id] = i
			if focusable(row):
				focus_ids[id] = true
		if row.get("kind") == "module":
			if not row.get("module") is String or not declarations.has(row.module):
				_error(issues, p + ".module", "must name a declared screen module")
			if row.has("props") and not row.props is Dictionary:
				_error(issues, p + ".props", "must be an object keyed by field ID")
			var outputs = row.get("outputs", {})
			if not outputs is Dictionary:
				_error(issues, p + ".outputs", "must be an object keyed by output ID")
			else:
				for output in outputs:
					var target = outputs[output]
					if not output is String or output.strip_edges().is_empty() or not target is Dictionary \
							or target.size() != 2 or not target.get("function") is String or not target.get("content") is String:
						_error(issues, p + ".outputs." + str(output), "must bind a named output to {function, content}")
		elif not KINDS.has(row.get("kind")):
			_error(issues, p + ".kind", "must be panel, text, button or module")
		var a = row.get("anchors")
		var o = row.get("offsets", [0, 0, 0, 0])
		var valid: bool = _four(a) and a.all(func(v): return v >= 0.0 and v <= 1.0) and a[0] <= a[2] and a[1] <= a[3]
		if not valid:
			_error(issues, p + ".anchors", "must be ordered [left, top, right, bottom] in 0..1")
		if not _four(o):
			_error(issues, p + ".offsets", "must be four finite pixel offsets")
		elif valid and used.get(id) == i:
			geometry.append(row)
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
	var valid_parents := true
	for id in used:
		var i: int = used[id]
		var row: Dictionary = elements[i]
		if row.has("parent") and (not row.parent is String or row.parent == id or not used.has(row.parent)):
			_error(issues, "%s.elements[%d].parent" % [path, i], "must name another element in this layout")
			valid_parents = false
	if valid_parents and geometry.size() == used.size():
		var resolved := rectangles(geometry, viewports.get(vp, FALLBACK_SIZE))
		for id in used:
			var p := "%s.elements[%d]" % [path, used[id]]
			if not resolved.has(id):
				_error(issues, p + ".parent", "must reach the viewport without a parent cycle")
			else:
				var r: Rect2 = resolved[id]
				if not r.has_area() or not r.is_finite():
					_error(issues, p, "must have positive width and height in the design viewport")
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
