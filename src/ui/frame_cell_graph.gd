extends RefCounted
## Author polygons and directed links using the game's pick mappings.

const Graph := preload("res://src/map/cell_graph.gd")
const Geometry := preload("res://src/map/object_geometry.gd")
const Picks := preload("res://src/project/frame_picks.gd")
const Kit := preload("res://src/ui/ui_kit.gd")
const GraphEditor := preload("res://src/ui/cell_graph_editor.gd")
const Id := preload("res://src/content/content_id.gd")
const GraphTiles := preload("res://src/map/cell_graph_tiles.gd")
const INK := Color("ffda67")
enum Tool {POLYGON, NEIGHBOR, EDGE, EDIT_EDGE, VERTEX}
enum VertexEdit {MOVE, INSERT, REMOVE}
const TOOLS := ["绘制新格", "切换有向邻接", "新建独立连接", "编辑独立连接", "编辑格顶点"]
signal controls_changed

var canvas: EditorCanvas
var tool := 0
var id_field := LineEdit.new()
var space_picker := OptionButton.new()
var edge_controls := VBoxContainer.new()
var edge_type := OptionButton.new()
var edge_picker := OptionButton.new()
var edge_delete := CheckBox.new()
var new_type_row: Control
var existing_edge_row: Control
var edge_form := VBoxContainer.new()
var edge_draft := {"props": {}}
var edge_commits := []
var points := []
var screen := PackedVector2Array()
var from := ""
var status := ""
var pending := {}
var vertex_cell := {}
var vertex_index := -1
var vertex_edit := VertexEdit.MOVE

func _init(cvs: EditorCanvas) -> void:
	canvas = cvs
	clear()

func controls() -> Control:
	var form := Kit.vbox(5)
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
	form.add_child(row)
	edge_type.name = "FrameGraphEdgeType"
	edge_type.add_item("通用连接")
	edge_type.set_item_metadata(0, "")
	var types := Graph.edge_types(canvas.manifest)
	for id in types:
		if types[id] is Dictionary:
			edge_type.add_item(str(types[id].get("name", id)))
			edge_type.set_item_metadata(edge_type.item_count - 1, id)
	edge_type.item_selected.connect(func(_index: int): _build_edge_form())
	new_type_row = Kit.field_row("连接类型", edge_type, 82)
	edge_controls.add_child(new_type_row)
	edge_picker.name = "FrameExistingEdge"
	edge_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edge_picker.item_selected.connect(_select_existing_edge)
	edge_delete.name = "FrameDeleteEdge"
	edge_delete.text = "删除此连接"
	edge_delete.toggled.connect(func(enabled: bool):
		edge_form.visible = not enabled
		_update_edge_status()
		controls_changed.emit())
	existing_edge_row = Kit.hbox(8)
	existing_edge_row.add_child(edge_picker)
	existing_edge_row.add_child(edge_delete)
	edge_controls.add_child(existing_edge_row)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 92
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	edge_form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(edge_form)
	edge_controls.add_child(scroll)
	form.add_child(edge_controls)
	clear()
	return form

func _build_edge_form() -> void:
	var kind: String = edge_type.get_selected_metadata()
	edge_draft = {"props": Graph.edge_defaults(Graph.edge_types(canvas.manifest), kind)}
	_show_edge_properties(kind)

func _show_edge_properties(kind: String) -> void:
	for child in edge_form.get_children():
		edge_form.remove_child(child)
		child.queue_free()
	edge_commits.clear()
	var types := Graph.edge_types(canvas.manifest)
	if not edge_draft.get("props", {}) is Dictionary:
		edge_form.add_child(Kit.hint_label("属性格式无效，可移除此连接。", 300))
		return
	GraphEditor.add_edge_properties(edge_form, Graph.edge_fields(types, kind), edge_draft, "FrameEdgeProperty_", edge_commits)

func clear() -> void:
	points.clear()
	screen.clear()
	from = ""
	pending.clear()
	vertex_cell = {}
	vertex_index = -1
	vertex_edit = VertexEdit.MOVE
	id_field.visible = tool == Tool.POLYGON
	space_picker.visible = tool == Tool.POLYGON
	edge_controls.visible = tool in [Tool.EDGE, Tool.EDIT_EDGE]
	if new_type_row != null:
		new_type_row.visible = tool == Tool.EDGE
		existing_edge_row.visible = tool == Tool.EDIT_EDGE
		if tool == Tool.EDGE:
			edge_form.visible = true
			_build_edge_form()
	match tool:
		Tool.POLYGON:
			status = "输入新格 ID，选择空间，再在实景上依次描点；右键撤末点。"
		Tool.NEIGHBOR:
			status = "依次点击起点格和终点格，确认后切换起点的有向邻接。右键重选。"
		Tool.EDGE:
			status = "选择连接类型和属性，再依次点击起点格和终点格。右键重选。"
		Tool.EDIT_EDGE:
			edge_draft = {"props": {}}
			_show_edge_properties("")
			edge_picker.clear()
			edge_picker.add_item("请先在画面上选择起点格")
			edge_picker.disabled = true
			_reset_edge_delete()
			edge_delete.disabled = true
			status = "点选起点格，在下拉中选一条出边。可改属性、点新终点或删除。右键重选。"
		Tool.VERTEX:
			status = "点顶点后选新位置。Shift + 点顶点可在其后插点；Ctrl + 点顶点可删除。右键重选。"

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
	elif tool == Tool.EDIT_EDGE:
		_pick_edge_edit(pixel, regions)
	elif tool == Tool.VERTEX:
		_pick_vertex(pixel, regions, event)
	else:
		_pick_link(pixel, regions)
	return true

func _pick_point(pixel: Vector2, regions: Array) -> void:
	var sid: String = space_picker.get_selected_metadata()
	var point := _mapped_point(pixel, regions, sid)
	if point.is_empty():
		return
	if points.size() >= Geometry.MAX_POINTS:
		status = "顶点已到上限。右键撤末点。"
		return
	points.append(point)
	screen.append(pixel)
	_validate_polygon()

func _mapped_point(pixel: Vector2, regions: Array, sid: String) -> Array:
	var graph := canvas.cell_graph()
	var space: Dictionary = graph.get("spaces", {}).get(sid, {})
	var layer: String = space.get("layer", "")
	var basis := Graph.space_transform(graph, sid)
	if not _layer_editable(layer) or not Graph.invertible(basis):
		status = "空间的图层不可编辑，或空间坐标轴不可逆。"
		return []
	var hit := Picks.at(regions, pixel, "collision" if layer.is_empty() else "placement")
	if hit.is_empty() or hit.value.get("layer", "") != layer:
		status = "该点没有映射到所选空间的图层。"
		return []
	var point: Vector2 = basis.affine_inverse() * hit.value.point
	return [point.x, point.y]

func _pick_vertex(pixel: Vector2, regions: Array, event: InputEventMouseButton) -> void:
	if vertex_index < 0:
		var hit := Picks.at(regions, pixel, "cellVertex")
		var value = hit.get("value")
		if value is Dictionary:
			var id = value.get("cell")
			var index = value.get("index")
			if id is String and (index is int or index is float) and index >= 0 and index == floorf(index):
				for row in canvas.cell_graph().get("cells", []):
					if row is Dictionary and row.get("id") == id and row.get("polygon") is Array and index < row.polygon.size():
						vertex_cell = row
						vertex_index = int(index)
						break
		if vertex_index < 0:
			status = "请选择游戏标出的格顶点。"
			return
		if not _layer_editable(Graph.layer_of_cell(canvas.cell_graph(), vertex_cell.id)):
			clear()
			status = "该格所在图层已锁定或隐藏。"
			return
		screen.append(pixel)
		vertex_edit = VertexEdit.REMOVE if event.ctrl_pressed else VertexEdit.INSERT if event.shift_pressed else VertexEdit.MOVE
		status = "已选 %s 的顶点 %d。请选同空间的新位置。" % [vertex_cell.id, vertex_index + 1]
		if vertex_edit == VertexEdit.REMOVE:
			var polygon: Array = vertex_cell.polygon.duplicate()
			polygon.remove_at(vertex_index)
			_validate_vertex_polygon(polygon)
		return
	if vertex_edit == VertexEdit.REMOVE:
		return
	pending.clear()
	screen.resize(1)
	var point := _mapped_point(pixel, regions, vertex_cell.get("space", ""))
	if point.is_empty():
		return
	var polygon: Array = vertex_cell.polygon.duplicate()
	if vertex_edit == VertexEdit.INSERT:
		polygon.insert(vertex_index + 1, point)
	else:
		polygon[vertex_index] = point
	if _validate_vertex_polygon(polygon):
		screen.append(pixel)

func _validate_vertex_polygon(polygon: Array) -> bool:
	var issue := Geometry.problem(polygon, Geometry.POLY)
	if not issue.is_empty():
		status = issue + " 右键重选。"
		return false
	if polygon == vertex_cell.polygon:
		status = "格顶点未改变。"
		return false
	pending = {"id": vertex_cell.id, "polygon": polygon}
	status = "%s · %s顶点 · 确认后写入。" % [vertex_cell.id, ["移动", "插入", "删除"][vertex_edit]]
	return true

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
		status = "起点 %s · 请选择终点格。" % from
		return
	pending.clear()
	screen.resize(1)
	if hit.value == from and tool == Tool.NEIGHBOR:
		status = "终点不能与起点相同。"
		return
	var to: String = hit.value
	screen.append(pixel)
	var linked := Graph.neighbors(canvas.cell_graph(), from).has(to)
	pending = {"from": from, "to": to}
	status = "新建连接 %s → %s · 可应用。" % [from, to] if tool == Tool.EDGE \
		else "%s邻接 %s → %s · 可应用。" % ["移除" if linked else "添加", from, to]

func _pick_edge_edit(pixel: Vector2, regions: Array) -> void:
	var graph := canvas.cell_graph()
	var hit := Picks.at(regions, pixel, "cell")
	if hit.is_empty() or not Graph.cell_ids(graph).has(hit.value):
		status = "请选择游戏标出的已有格。"
		return
	if not pending.is_empty():
		if edge_delete.button_pressed:
			return
		edge_draft["to"] = hit.value
		edge_draft.erase("toMap")
		screen.resize(1)
		screen.append(pixel)
		_update_edge_status()
		return
	if not _layer_editable(Graph.layer_of_cell(graph, hit.value)):
		status = "起点格所在图层已锁定或隐藏。"
		return
	from = hit.value
	screen = PackedVector2Array([pixel])
	edge_picker.clear()
	edge_picker.add_item("请选择一条出边")
	for edge in graph.get("edges", []):
		if not edge is Dictionary or edge.get("from") != from:
			continue
		var dest := _edge_destination(edge)
		edge_picker.add_item("%s → %s · %s" % [edge.get("type", ""), dest, edge.id])
		edge_picker.set_item_metadata(edge_picker.item_count - 1, edge.id)
	edge_picker.disabled = edge_picker.item_count == 1
	status = "格 %s 没有独立出边。" % from if edge_picker.disabled else "格 %s · 请选择要编辑的出边。" % from

func _select_existing_edge(index: int) -> void:
	pending.clear()
	screen.resize(1)
	_reset_edge_delete()
	edge_delete.disabled = index == 0
	edge_draft = {"props": {}}
	if index == 0:
		status = "请选择要编辑的出边。"
	else:
		var id: String = edge_picker.get_item_metadata(index)
		for edge in canvas.cell_graph().get("edges", []):
			if edge is Dictionary and edge.get("id") == id:
				edge_draft = edge.duplicate(true)
				pending = {"from": from, "id": id}
				_update_edge_status()
				break
	_show_edge_properties(str(edge_draft.get("type", "")))
	controls_changed.emit()

func _reset_edge_delete() -> void:
	edge_delete.set_pressed_no_signal(false)
	edge_form.visible = true

func _edge_destination(edge: Dictionary) -> String:
	var map_code: String = edge.get("toMap", "")
	return str(edge.to) if map_code.is_empty() else "%s / %s" % [map_code, edge.to]

func _update_edge_status() -> void:
	status = "确认删除独立边 %s。" % edge_draft.id if edge_delete.button_pressed else \
		"%s → %s · %s。可改属性或点选本图新终点。" % [from, _edge_destination(edge_draft), edge_draft.id]

func apply() -> bool:
	var graph := canvas.cell_graph().duplicate(true)
	if tool == 0:
		var space: Dictionary = graph.get("spaces", {}).get(pending.get("space", ""), {})
		if not _layer_editable(space.get("layer", "")):
			return false
		var cells: Array = graph.get_or_add("cells", [])
		cells.append(pending.duplicate(true))
	elif tool == Tool.VERTEX:
		if not _layer_editable(Graph.layer_of_cell(graph, pending.id)):
			return false
		for row in graph.cells:
			if row is Dictionary and row.get("id") == pending.id:
				row.polygon = pending.polygon
				row.erase(GraphTiles.GENERATED_KEY)
				break
	elif tool == Tool.EDGE:
		if not _layer_editable(Graph.layer_of_cell(graph, pending.from)):
			return false
		for commit: Callable in edge_commits:
			if not commit.call():
				return false
		var edges: Array = graph.get_or_add("edges", [])
		var id := Id.new_inst_code()
		while edges.any(func(edge): return edge is Dictionary and edge.get("id") == id):
			id = Id.new_inst_code()
		edges.append({"id": id, "from": pending.from, "to": pending.to,
			"type": edge_type.get_selected_metadata(), "props": edge_draft.props.duplicate(true)})
	elif tool == Tool.EDIT_EDGE:
		if not _layer_editable(Graph.layer_of_cell(graph, pending.from)):
			return false
		if not edge_delete.button_pressed:
			for commit: Callable in edge_commits:
				if not commit.call():
					return false
		var edges: Array = graph.edges
		for i in edges.size():
			if not edges[i] is Dictionary or edges[i].get("id") != pending.id:
				continue
			if edge_delete.button_pressed:
				edges.remove_at(i)
			else:
				if edges[i] == edge_draft:
					return false
				edges[i] = edge_draft.duplicate(true)
			break
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
