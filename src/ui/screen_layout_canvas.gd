extends Control
## Draws reference hotspots and screen layouts and handles canvas gestures.

const Layout := preload("res://src/project/screen_layout.gd")
var direct_views := false
var direct_maps := false

const FOCUS_ACTIONS := {"ui_left": "left", "ui_right": "right", "ui_up": "up", "ui_down": "down",
	"ui_focus_next": "next", "ui_focus_prev": "previous", "ui_accept": "activate"}
const CORNERS := [Vector2.ZERO, Vector2.RIGHT, Vector2.DOWN, Vector2.ONE]
const HANDLE_RADIUS := 5.0
var texture: Texture2D
var hotspots: Array = []
var selected := -1
var start := Vector2(-1, -1)
var cursor := Vector2.ZERO
var editing_layout := false
var adjusting_layout := false
var placement := {}
var elements: Array = []
var active_element := -1
var viewport_size := Vector2(1280, 720)
var profile := ""
var focus_preview := false
var focus_layout: Dictionary = {}
var focused_id := ""
var locale := ""
var asset_textures: Dictionary = {}
signal picked(index: int)
signal rectangle_drawn(rect: Rect2)
signal geometry_changed
signal focus_message(message: String)

func frame() -> Rect2:
	var dim := size
	var reference := viewport_size if editing_layout else (texture.get_size() if texture != null else Vector2.ZERO)
	if reference.x > 0 and reference.y > 0:
		dim = reference * minf(size.x / reference.x, size.y / reference.y)
	return Rect2((size - dim) * 0.5, dim)

func _draw() -> void:
	var area := frame()
	draw_rect(area, Color("#263544"))
	if texture != null:
		draw_texture_rect(texture, area, false)
	if editing_layout:
		_draw_layout(area)
	for i in (0 if editing_layout else hotspots.size()):
		var row: Dictionary = hotspots[i]
		var raw: Array = row.rect
		var r := Rect2(area.position + Vector2(raw[0], raw[1]) * area.size,
			Vector2(raw[2], raw[3]) * area.size)
		var c := Color("#ffc15c") if i == selected else Color("#5de2eb")
		draw_rect(r, Color(c, 0.28))
		draw_rect(r, c, false, 2)
	if start.x >= 0:
		var r := Rect2(start, cursor - start).abs()
		draw_rect(Rect2(area.position + r.position * area.size, r.size * area.size),
			Color("#ffffff"), false, 2)

func _layout_rect(px: Rect2, area: Rect2) -> Rect2:
	return Rect2(area.position + px.position / viewport_size * area.size, px.size / viewport_size * area.size)

func _draw_layout(area: Rect2) -> void:
	var resolved := layout_rectangles()
	for i in elements.size():
		var item: Dictionary = elements[i]
		var px: Rect2 = resolved.get(item.id, Rect2())
		var bounds := _layout_rect(px, area)
		if not bounds.has_area():
			continue
		var visible_rect := bounds.intersection(area)
		if not visible_rect.has_area():
			continue
		var highlighted: bool = item.id == focused_id if focus_preview else active_element == i
		var color := Color("#ffc15c") if highlighted else Color("#82cee1")
		if item.kind != "text":
			draw_rect(visible_rect, Color(color, 0.23 if item.kind == "panel" else 0.45))
		var image: Texture2D = asset_textures.get(item.get("imageAsset", ""))
		if image != null:
			var placement := Layout.image_placement(bounds, area, image.get_size(), item.get("imageFit", "contain"))
			if not placement.is_empty():
				draw_texture_rect_region(image, placement.dest, placement.source)
		draw_rect(visible_rect, color, false, 1.5)
		var label := Layout.display_text(item, locale)
		if label.is_empty():
			continue
		var font := ThemeDB.fallback_font
		var scale_px := area.size.x / viewport_size.x
		var font_px := int(item.get("fontSize", Layout.DEFAULT_FONT_SIZE))
		var overflow := _text_overflows(item, label, px)
		var draw_size := maxi(1, roundi(font_px * scale_px))
		var line_height := font.get_height(draw_size)
		var pad := Vector2.ONE * 4 * scale_px
		var pen := bounds.position + pad
		for line in label.split("\n"):
			var available := visible_rect.end.x - pen.x - pad.x
			if pen.y + line_height > visible_rect.end.y or available <= 0.0:
				break
			if pen.y >= visible_rect.position.y and pen.x >= visible_rect.position.x:
				draw_string(font, pen + Vector2(0, font.get_ascent(draw_size)), line,
					HORIZONTAL_ALIGNMENT_LEFT, available, draw_size)
			pen.y += line_height
		if overflow:
			draw_rect(visible_rect, Color("#ff8877"), false, 2)
	if adjusting_layout and not focus_preview and active_element >= 0:
		var bounds := _layout_rect(resolved.get(elements[active_element].id, Rect2()), area)
		if bounds.has_area():
			for corner in CORNERS:
				var point: Vector2 = bounds.position + corner * bounds.size
				if area.grow(0.01).has_point(point):
					var box := Rect2(point - Vector2.ONE * HANDLE_RADIUS, Vector2.ONE * HANDLE_RADIUS * 2.0)
					draw_rect(box, Color("#ffc15c"))
					draw_rect(box, Color("#263544"), false, 1)

func layout_rectangles() -> Dictionary:
	var staged := {} if placement.is_empty() else {placement.item.id: placement.current}
	return Layout.rectangles(elements, viewport_size, profile, false, staged)

func cancel_placement() -> bool:
	if placement.is_empty():
		return false
	placement.clear()
	queue_redraw()
	return true

func text_overflows(item: Dictionary) -> bool:
	return _text_overflows(item, Layout.display_text(item, locale),
		Layout.rectangles(elements, viewport_size, profile, true)[item.id])

func _text_overflows(item: Dictionary, label: String, bounds: Rect2) -> bool:
	if label.is_empty():
		return false
	var font := ThemeDB.fallback_font
	var font_px := int(item.get("fontSize", Layout.DEFAULT_FONT_SIZE))
	var lines := label.split("\n")
	if font.get_height(font_px) * lines.size() + 8.0 > bounds.size.y:
		return true
	for line in lines:
		if font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, font_px).x + 8.0 > bounds.size.x:
			return true
	return false

func _gui_input(event: InputEvent) -> void:
	var area := frame()
	if area.size.x <= 0 or area.size.y <= 0:
		return
	if editing_layout and focus_preview:
		_focus_input(event, area)
		return
	if editing_layout and adjusting_layout:
		_adjust_input(event, area)
		return
	if event is InputEventMouseMotion and start.x >= 0:
		cursor = ((event.position - area.position) / area.size).clamp(Vector2.ZERO, Vector2.ONE)
		queue_redraw()
	if not event is InputEventMouseButton or event.button_index != MOUSE_BUTTON_LEFT:
		return
	var point: Vector2 = ((event.position - area.position) / area.size).clamp(Vector2.ZERO, Vector2.ONE)
	if event.pressed:
		if not area.has_point(event.position):
			return
		start = point
		cursor = point
	elif start.x >= 0:
		var r := Rect2(start, point - start).abs()
		start = Vector2(-1, -1)
		if r.size.x * area.size.x >= 4 and r.size.y * area.size.y >= 4:
			rectangle_drawn.emit(r)
		else:
			if editing_layout:
				var i := _layout_hit(event.position, area, layout_rectangles())
				if i >= 0:
					picked.emit(i)
			else:
				for i in range(hotspots.size() - 1, -1, -1):
					var raw: Array = hotspots[i].rect
					if Rect2(raw[0], raw[1], raw[2], raw[3]).has_point(point):
						picked.emit(i)
						break
		queue_redraw()
	accept_event()

func _layout_hit(point: Vector2, area: Rect2, resolved: Dictionary) -> int:
	for i in range(elements.size() - 1, -1, -1):
		var bounds := _layout_rect(resolved.get(elements[i].id, Rect2()), area)
		if bounds.has_area() and bounds.intersection(area).has_point(point):
			return i
	return -1

func _adjust_input(event: InputEvent, area: Rect2) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT and cancel_placement():
		accept_event()
		return
	if event is InputEventMouseMotion and not placement.is_empty():
		placement.current = _drag_bounds(event.position, area)
		queue_redraw()
		accept_event()
		return
	if not event is InputEventMouseButton or event.button_index != MOUSE_BUTTON_LEFT:
		return
	if event.pressed and area.has_point(event.position):
		var resolved := layout_rectangles()
		var index := active_element
		var handle := Vector2(-1, -1)
		if index >= 0:
			var selected := _layout_rect(resolved.get(elements[index].id, Rect2()), area)
			if selected.has_area():
				for corner in CORNERS:
					var point: Vector2 = selected.position + corner * selected.size
					if area.grow(0.01).has_point(point) and point.distance_to(event.position) <= HANDLE_RADIUS * 1.5:
						handle = corner
						break
		if handle.x < 0:
			index = _layout_hit(event.position, area, resolved)
		if index < 0:
			return
		if index != active_element:
			picked.emit(index)
		grab_focus()
		var item: Dictionary = elements[index]
		placement = {"item": item, "pointer": event.position, "bounds": resolved[item.id],
			"current": resolved[item.id], "handle": handle, "reference":
				resolved.get(item.get("parent", ""), Rect2(Vector2.ZERO, viewport_size))}
	elif not event.pressed and not placement.is_empty():
		var bounds := _drag_bounds(event.position, area)
		var changed: bool = not bounds.is_equal_approx(placement.bounds)
		if changed:
			Layout.place(placement.item, profile, bounds, placement.reference)
		cancel_placement()
		if changed:
			geometry_changed.emit()
	accept_event()

func _drag_bounds(pointer: Vector2, area: Rect2) -> Rect2:
	var bounds: Rect2 = placement.bounds
	var movement: Vector2 = pointer - placement.pointer
	if movement.length_squared() < 9.0:
		return bounds
	var delta := movement * viewport_size / area.size
	var handle: Vector2 = placement.handle
	if handle.x < 0:
		return Rect2(bounds.position + delta, bounds.size)
	var lo := bounds.position
	var hi := bounds.end
	for axis in 2:
		if handle[axis] == 0:
			lo[axis] = minf(lo[axis] + delta[axis], hi[axis] - minf(1.0, bounds.size[axis]))
		else:
			hi[axis] = maxf(hi[axis] + delta[axis], lo[axis] + minf(1.0, bounds.size[axis]))
	return Rect2(lo, hi - lo)

func _focus_input(event: InputEvent, area: Rect2) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		grab_focus()
		var resolved := Layout.rectangles(elements, viewport_size, profile)
		for i in range(elements.size() - 1, -1, -1):
			var row: Dictionary = elements[i]
			if Layout.focusable(row) and _layout_rect(resolved.get(row.id, Rect2()), area).intersection(area).has_point(event.position):
				focused_id = str(elements[i].id)
				_focus_result(true)
				break
		accept_event()
		return
	for action in FOCUS_ACTIONS:
		if not event.is_action_pressed(action, true, true):
			continue
		if action != "ui_accept":
			focused_id = Layout.focus_step(focus_layout, elements, focused_id, FOCUS_ACTIONS[action], viewport_size, profile)
		_focus_result(action == "ui_accept")
		accept_event()
		return

func _focus_result(activate: bool) -> void:
	for row in elements:
		if row.id != focused_id:
			continue
		var title := Layout.display_text(row, locale)
		if title.is_empty():
			title = focused_id
		var message := "焦点：" + title
		if activate:
			var target = row.get("target")
			message = "确认：%s → %s/%s" % [title, target.function, target.content] \
				if Layout.content_target(target) else "确认：" + title
			if direct_views and Layout.view_target(target):
				message = "确认：%s → 屏幕 %s" % [title, target.view]
			if direct_maps and Layout.map_target(target):
				message = "确认：%s → 地图 %s" % [title, target.map]
		focus_message.emit(message)
		queue_redraw()
		return
	focus_message.emit("当前画幅没有可聚焦按钮。")
	queue_redraw()
