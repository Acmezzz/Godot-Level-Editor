extends RefCounted
## Draft tile or root collision cells from visible screen segments; apply as one stroke.

const Picks := preload("res://src/project/frame_picks.gd")

var canvas: EditorCanvas
var collision: bool
var groups := {}
var traces := []
var last := Vector2.ZERO
var button := 0
var erasing := false

func _init(cvs: EditorCanvas, on_collision := false) -> void:
	canvas = cvs
	collision = on_collision

func clear() -> void:
	groups.clear()
	traces.clear()
	button = 0

func input(event: InputEvent, pixel: Vector2, regions: Array) -> bool:
	if event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		if event.pressed:
			var erase: bool = event.button_index == MOUSE_BUTTON_RIGHT
			if erase != erasing:
				clear()
				erasing = erase
			button = event.button_index
			last = pixel
			_extend(pixel, regions)
		elif button == event.button_index:
			_extend(pixel, regions)
			button = 0
		return true
	if event is InputEventMouseMotion and button != 0:
		var mask := MOUSE_BUTTON_MASK_RIGHT if erasing else MOUSE_BUTTON_MASK_LEFT
		if not event.button_mask & mask:
			button = 0
			return false
		_extend(pixel, regions)
		return true
	return false

func _extend(pixel: Vector2, regions: Array) -> void:
	var spans := Picks.brush_spans(regions, last, pixel, "collision" if collision else "placement")
	last = pixel
	var meta: Dictionary = canvas.map_data.meta
	for span in spans:
		var layer := canvas.collision_index() if collision else canvas._layer_index_of(span.layer)
		if layer < 0 or canvas.is_layer_locked(layer):
			continue
		var grid := canvas.tile_grid_for_layer(layer)
		var a := grid.pick_cell(span.a)
		var b := grid.pick_cell(span.b)
		if not grid.cell_in_map(a, int(meta.w), int(meta.h)) or not grid.cell_in_map(b, int(meta.w), int(meta.h)):
			continue
		var cells: Dictionary = groups.get(layer, {})
		var count := cells.size()
		for cell: Vector2i in canvas._tool_ops_ctrl._brush_cells_multi(grid.cells_between(a, b)):
			if grid.cell_in_map(cell, int(meta.w), int(meta.h)):
				cells[cell] = true
		if cells.size() > count:
			groups[layer] = cells
			traces.append([span.screen_a, span.screen_b])

func ready() -> bool:
	return not groups.is_empty()

func message() -> String:
	var count := 0
	for layer in groups:
		count += groups[layer].size()
	if count == 0:
		if collision:
			return "请在游戏提供的根碰撞映射区内拖动。碰撞层须解锁。"
		return "请在未锁定的可编辑区域内拖动。"
	var target := "碰撞层" if collision else "%d 层" % groups.size()
	return "待%s %d 格 · %s。确认后写入；改用另一鼠标键会清除当前草稿。" % [
		"擦除" if erasing else "涂刷", count, target]

func apply() -> bool:
	for layer: int in groups:
		if canvas.is_layer_locked(layer):
			return false
	canvas.end_gesture()
	canvas._paint_pushed = false
	var changed := false
	for layer: int in groups:
		var cells: Array = groups[layer].keys()
		if erasing:
			changed = canvas._tool_ops_ctrl.erase_cells(cells, layer) or changed
		elif collision:
			changed = canvas._tool_ops_ctrl.paint_collision_cells(cells) or changed
		else:
			changed = canvas._tool_ops_ctrl.paint_tile_cells(layer, cells) or changed
	canvas.end_gesture()
	canvas._paint_pushed = false
	return changed

func draw(frame: TextureRect, rect: Rect2) -> void:
	var scale := rect.size / frame.texture.get_size()
	var ink := Color("ff7575") if erasing else Color("ffda67")
	for trace in traces:
		var a: Vector2 = rect.position + trace[0] * scale
		var b: Vector2 = rect.position + trace[1] * scale
		if not a.is_equal_approx(b):
			frame.draw_line(a, b, ink, 2.5, true)
		frame.draw_circle(b, 3.0, ink)
