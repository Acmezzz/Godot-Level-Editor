extends VBoxContainer
## Edits a numeric curve in a graph or with exact values for the selected key.

const Keyframes := preload("res://src/content/keyframe_curve.gd")
const LABELS := ["线性", "保持", "缓入缓出"]
var keys: Array
var selected := -1
var _graph := Control.new()
var _time := SpinBox.new()
var _value := SpinBox.new()
var _mode := OptionButton.new()
var _remove := Button.new()
var _commit: Callable
var _dragging := false
var _domain := Rect2()

func _init(initial: Array, build_commit: Callable) -> void:
	keys = initial.duplicate(true)
	_commit = build_commit.call(value, initial.duplicate(true))
	_graph.name = "KeyframeGraph"
	_graph.custom_minimum_size = Vector2(160, 115)
	_graph.draw.connect(_draw_graph)
	_graph.gui_input.connect(_graph_input)
	_graph.tooltip_text = "空白处单击添加关键帧，拖动关键帧调整时间和数值。"
	add_child(_graph)
	var hint := Label.new()
	hint.text = "单击添加关键帧 · 拖动调整"
	add_child(hint)
	var numbers := HBoxContainer.new()
	add_child(numbers)
	_add_number(numbers, _time, "时间", 0.0, 1.0, false)
	_add_number(numbers, _value, "数值", 0.0, 1.0, true)
	_time.value_changed.connect(func(value: float): _change_time(value))
	_value.value_changed.connect(func(value: float):
		if selected >= 0:
			keys[selected]["value"] = value
			_update_domain())
	var actions := HBoxContainer.new()
	add_child(actions)
	_mode.name = "KeyframeMode"
	for label in LABELS:
		_mode.add_item(label)
	_mode.item_selected.connect(func(index: int):
		if index == 0:
			keys[selected].erase("mode")
		else:
			keys[selected]["mode"] = Keyframes.MODES[index]
		_graph.queue_redraw()
		_commit.call())
	actions.add_child(_mode)
	_remove.text = "删除关键帧"
	_remove.pressed.connect(func():
		keys.remove_at(selected)
		_select(mini(selected, keys.size() - 1))
		_update_domain()
		_commit.call())
	actions.add_child(_remove)
	_update_domain()
	_select(0 if not keys.is_empty() else -1)

func value() -> Array:
	return keys.duplicate(true)

func commit() -> bool:
	_flush_number(_time)
	_flush_number(_value)
	return _commit.call()

func _add_number(row: HBoxContainer, input: SpinBox, label: String, low: float, high: float, below: bool) -> void:
	input.prefix = label + " "
	input.step = 0.0
	input.min_value = low
	input.max_value = high
	input.allow_greater = true
	input.allow_lesser = below
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var line := input.get_line_edit()
	line.focus_exited.connect(func(): _commit.call())
	line.text_submitted.connect(func(_text): _commit.call())
	row.add_child(input)

func _flush_number(input: SpinBox) -> void:
	if input.get_line_edit().has_focus():
		input.apply()

func _select(index: int) -> void:
	selected = index
	var active := index >= 0
	_time.editable = active
	_value.editable = active
	_mode.disabled = not active
	_remove.disabled = not active
	if active:
		_time.set_value_no_signal(keys[index].time)
		_value.set_value_no_signal(keys[index].value)
		_mode.select(Keyframes.MODES.find(keys[index].get("mode", "linear")))
	else:
		_mode.select(-1)
	_graph.queue_redraw()

func _change_time(time: float) -> void:
	if selected < 0:
		return
	if _time_used(time):
		_time.set_value_no_signal(keys[selected].time)
		return
	var key: Dictionary = keys.pop_at(selected)
	key["time"] = time
	var index := keys.bsearch_custom(key, func(a: Dictionary, b: Dictionary): return a.time < b.time)
	keys.insert(index, key)
	_select(index)
	if not _dragging:
		_update_domain()

func _time_used(time: float) -> bool:
	for i in keys.size():
		if i != selected and keys[i].time == time:
			return true
	return false

func _update_domain() -> void:
	var end := 1.0
	var low := 0.0
	var high := 1.0
	for key in keys:
		end = maxf(end, key.time)
		low = minf(low, key.value)
		high = maxf(high, key.value)
	_domain = Rect2(0.0, low, end, high - low)
	_graph.queue_redraw()

func _plot() -> Rect2:
	return Rect2(Vector2(9, 9), _graph.size - Vector2(18, 18))

func _point(time: float, value: float) -> Vector2:
	var plot := _plot()
	return plot.position + Vector2(time / _domain.size.x, 1.0 - (value - _domain.position.y) / _domain.size.y) * plot.size

func _draw_graph() -> void:
	var plot := _plot()
	_graph.draw_rect(plot, Color(0.10, 0.13, 0.17))
	for i in range(1, 4):
		var y := plot.position.y + plot.size.y * i / 4.0
		_graph.draw_line(Vector2(plot.position.x, y), Vector2(plot.end.x, y), Color(0.25, 0.29, 0.35))
	var stroke := Color(0.37, 0.79, 0.96)
	for i in range(1, keys.size()):
		var a: Dictionary = keys[i - 1]
		var b: Dictionary = keys[i]
		var point := _point(a.time, a.value)
		if a.get("mode") == "hold":
			var corner := _point(b.time, a.value)
			_graph.draw_line(point, corner, stroke, 2, true)
			point = corner
		var slices := 16 if a.get("mode") == "smooth" else 1
		for n in range(1, slices + 1):
			var ratio := float(n) / slices
			var next := _point(lerpf(a.time, b.time, ratio), Keyframes.interpolate(a, b, ratio))
			_graph.draw_line(point, next, stroke, 2, true)
			point = next
	for i in keys.size():
		_graph.draw_circle(_point(keys[i].time, keys[i].value), 5.0, Color.WHITE if selected == i else stroke)

func _graph_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var plot := _plot()
		if event.pressed:
			for i in range(keys.size() - 1, -1, -1):
				if _point(keys[i].time, keys[i].value).distance_to(event.position) <= 8.0:
					_select(i)
					_dragging = true
					return
			if plot.has_point(event.position):
				var key := _from_pointer(event.position)
				var index := keys.bsearch_custom(key, func(a: Dictionary, b: Dictionary): return a.time < b.time)
				if index < keys.size() and keys[index].time == key.time:
					_select(index)
				else:
					keys.insert(index, key)
					_select(index)
				_dragging = true
		elif _dragging:
			_dragging = false
			_update_domain()
			_commit.call()
	elif event is InputEventMouseMotion and _dragging:
		var key := _from_pointer(event.position)
		_change_time(key.time)
		keys[selected]["value"] = key.value
		_select(selected)

func _from_pointer(point: Vector2) -> Dictionary:
	var plot := _plot()
	var ratio := ((point - plot.position) / plot.size).clamp(Vector2.ZERO, Vector2.ONE)
	return {"time": ratio.x * _domain.size.x, "value": lerpf(_domain.end.y, _domain.position.y, ratio.y)}
