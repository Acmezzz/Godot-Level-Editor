extends RefCounted
## Author polygons and simple directed links using the game's pick mappings.

const Graph := preload("res://src/map/cell_graph.gd")
const Geometry := preload("res://src/map/object_geometry.gd")
const Picks := preload("res://src/project/frame_picks.gd")
const Kit := preload("res://src/ui/ui_kit.gd")
const INK := Color("ffda67")
const TOOLS := ["绘制新格", "切换有向邻接"]
signal controls_changed

var canvas: EditorCanvas
var tool := 0
var id_field := LineEdit.new()
var space_picker := OptionButton.new()
var points := []
var screen := PackedVector2Array()
var from := ""
var status := ""
var pending := {}

func _init(cvs: EditorCanvas) -> void:
	canvas = cvs
	clear()

func controls() -> Control:
	var row := Kit.hbox(8)
	id_field.name = "FrameGraphCellId"
	id_field.placeholder_text = "新格 ID"
	id_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	space_picker.name = "FrameGraphSpace"
	space_picker.add_item("地图根空间")
	space_picker.set_item_metadata(0, "")
	for id in canvas.cell_graph().get("spaces", {}):
		space_picker.add_item(id)
		space_picker.set_item_metadata(space_picker.item_count - 1, id)
	space_picker.item_selected.connect(func(_index: int):
		clear()
		controls_changed.emit())
	id_field.text_changed.connect(func(_text: String):
		if tool == 0 and not points.is_empty():
			_validate_polygon()
			controls_changed.emit())
	row.add_child(space_picker)
	row.add_child(id_field)
	return row

func clear() -> void:
	points.clear()
	screen.clear()
	from = ""
	pending.clear()
	id_field.visible = tool == 0
	space_picker.visible = tool == 0
	status = "输入新格 ID，选择空间，再在实景上依次描点；右键撤末点。" if tool == 0 \
		else "依次点击起点格和终点格，确认后切换起点的有向邻接。右键重选。"

func ready() -> bool:
	return not pending.is_empty()

func message() -> String:
	return status

func input(event: InputEvent, pixel: Vector2, regions: Array) -> bool:
	if not event is InputEventMouseButton or not event.pressed:
		return false
	if event.button_index == MOUSE_BUTTON_RIGHT:
		if tool == 0 and not points.is_empty():
			points.pop_back()
			screen.resize(screen.size() - 1)
			_validate_polygon()
		else:
			clear()
		return true
	if event.button_index != MOUSE_BUTTON_LEFT:
		return false
	if tool == 0:
		_pick_point(pixel, regions)
	else:
		_pick_link(pixel, regions)
	return true

func _pick_point(pixel: Vector2, regions: Array) -> void:
	var graph := canvas.cell_graph()
	var sid: String = space_picker.get_selected_metadata()
	var space: Dictionary = graph.get("spaces", {}).get(sid, {})
	var layer: String = space.get("layer", "")
	var basis := Graph.space_transform(graph, sid)
	if not _layer_editable(layer) or not Graph.invertible(basis):
		status = "空间的图层不可编辑，或空间坐标轴不可逆。"
		return
	var hit := Picks.at(regions, pixel, "collision" if layer.is_empty() else "placement")
	if hit.is_empty() or hit.value.get("layer", "") != layer:
		status = "该点没有映射到所选空间的图层。"
		return
	if points.size() >= Geometry.MAX_POINTS:
		status = "顶点已到上限。右键撤末点。"
		return
	var point: Vector2 = basis.affine_inverse() * hit.value.point
	points.append([point.x, point.y])
	screen.append(pixel)
	_validate_polygon()

func _validate_polygon() -> void:
	pending.clear()
	var id := id_field.text.strip_edges()
	if id.is_empty() or Graph.cell_ids(canvas.cell_graph()).has(id):
		status = "请输入未使用的格 ID。"
		return
	var issue := Geometry.problem(points, Geometry.POLY)
	if not issue.is_empty():
		status = "%d 点 · %s" % [points.size(), issue]
		return
	pending = {"id": id, "polygon": points.duplicate(), "neighbors": []}
	var sid: String = space_picker.get_selected_metadata()
	if not sid.is_empty():
		pending.space = sid
	status = "新格 %s · %d 点 · 可应用。" % [id, points.size()]

func _pick_link(pixel: Vector2, regions: Array) -> void:
	var hit := Picks.at(regions, pixel, "cell")
	var ids := Graph.cell_ids(canvas.cell_graph())
	if hit.is_empty() or not ids.has(hit.value):
		pending.clear()
		if not from.is_empty():
			screen.resize(1)
		status = "请选择游戏标出的已有格。"
		return
	if from.is_empty():
		from = hit.value
		screen.append(pixel)
		status = "起点 %s · 请选择另一个格。" % from
		return
	pending.clear()
	screen.resize(1)
	if hit.value == from:
		status = "终点不能与起点相同。"
		return
	var to: String = hit.value
	screen.append(pixel)
	var linked := Graph.neighbors(canvas.cell_graph(), from).has(to)
	pending = {"from": from, "to": to}
	status = "%s邻接 %s → %s · 可应用。" % ["移除" if linked else "添加", from, to]

func apply() -> bool:
	var graph := canvas.cell_graph().duplicate(true)
	if tool == 0:
		var space: Dictionary = graph.get("spaces", {}).get(pending.get("space", ""), {})
		if not _layer_editable(space.get("layer", "")):
			return false
		var cells: Array = graph.get_or_add("cells", [])
		cells.append(pending.duplicate(true))
	else:
		if not _layer_editable(Graph.layer_of_cell(graph, pending.from)):
			return false
		for cell in graph.cells:
			if not cell is Dictionary or cell.get("id") != pending.from:
				continue
			var neighbors: Array = cell.get_or_add("neighbors", [])
			if neighbors.has(pending.to):
				neighbors.erase(pending.to)
			else:
				neighbors.append(pending.to)
			break
	for issue in Graph.validate_graph(graph, canvas.manifest, canvas._cell_layer_frames(graph)):
		if issue.get("severity", "error") == "error":
			canvas._hint("格图未应用：%s · %s" % [issue.path, issue.message])
			return false
	canvas.apply_cell_graph(graph)
	if tool == 0:
		id_field.clear()
	return true

func _layer_editable(layer: String) -> bool:
	var li := canvas.collision_index() if layer.is_empty() else canvas._layer_index_of(layer)
	return li >= 0 and not canvas.is_layer_locked(li) and canvas.is_layer_visible(li)

func draw(frame: TextureRect, rect: Rect2) -> void:
	var scale := rect.size / frame.texture.get_size()
	var line := PackedVector2Array()
	for pixel in screen:
		var point := rect.position + pixel * scale
		line.append(point)
		frame.draw_circle(point, 4.0, INK)
	if tool == 0 and line.size() > 2:
		line.append(line[0])
	if line.size() >= 2:
		frame.draw_polyline(line, INK, 2.0, true)
