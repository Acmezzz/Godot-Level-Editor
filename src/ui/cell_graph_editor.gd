extends RefCounted
## Edit the current map's finite graph without changing its tile topology.

const Graph := preload("res://src/map/cell_graph.gd")
const Widgets := preload("res://src/ui/field_widgets.gd")
const Kit := preload("res://src/ui/ui_kit.gd")
const Id := preload("res://src/content/content_id.gd")
const MapStore := preload("res://src/map/map_store.gd")
const RefIndex := preload("res://src/project/reference_index.gd")
const MapViewData := preload("res://src/map/map_view_data.gd")
const GraphTiles := preload("res://src/map/cell_graph_tiles.gd")
const MAX_TILE_IMPORT := 2048

class GraphPreview extends Control:
	signal cell_clicked(index: int)
	signal vertex_changed(operation: String, index: int, point: Vector2)

	var map_bounds := Rect2(Vector2.ZERO, Vector2.ONE)
	var bounds := map_bounds
	var polygons: Array[PackedVector2Array] = []
	var rows: Array = []
	var graph: Dictionary = {}
	var layer_frames: Dictionary = {}
	var space_filter: Variant = null
	var edges: Array = []
	var selected_edge := ""
	var selected := -1
	var link_mode := false
	var dragged := -1
	var cursor := Vector2.ZERO

	func show_graph(cells: Array, index: int) -> void:
		rows = cells
		selected = index
		dragged = -1
		bounds = Rect2()
		var has_points := false
		polygons.clear()
		for row in cells:
			var poly := PackedVector2Array()
			if row is Dictionary and (space_filter == null or row.get("space", "") == space_filter):
				poly = Graph.map_points(graph, row, layer_frames)
			for point in poly:
				bounds = bounds.expand(point) if has_points else Rect2(point, Vector2.ZERO)
				has_points = true
			polygons.append(poly)
		if not has_points:
			bounds = map_bounds
		queue_redraw()

	func projection() -> Transform2D:
		var available := (size - Vector2(36, 36)).max(Vector2.ONE)
		var scale_px := minf(available.x / maxf(1.0, bounds.size.x), available.y / maxf(1.0, bounds.size.y))
		return Transform2D(0.0, Vector2.ONE * scale_px, 0.0, size * 0.5 - bounds.get_center() * scale_px)

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color("#17242e"))
		var xf := projection()
		draw_rect(xf * map_bounds, Color("#293c4a"), false)
		var centers: Array[Vector2] = []
		var indices := {}
		for i in polygons.size():
			var outline := xf * polygons[i]
			if i == selected and dragged >= 0 and dragged < outline.size():
				outline[dragged] = xf * cursor
			var center := Vector2.ZERO
			for point in outline:
				center += point
			if not outline.is_empty():
				center /= outline.size()
			centers.append(center)
			if not rows[i] is Dictionary:
				continue
			indices[str(rows[i].get("id", ""))] = i
			var col := Color("#ffc15c") if i == selected else Color("#67c8cc")
			if outline.size() >= 3 and not Geometry2D.triangulate_polygon(outline).is_empty():
				draw_colored_polygon(outline, Color(col, 0.16))
			if outline.size() >= 2:
				var loop := outline.duplicate()
				loop.append(outline[0])
				draw_polyline(loop, col, 2, true)
		for i in rows.size():
			if polygons[i].is_empty() or not rows[i] is Dictionary:
				continue
			var neighbors = rows[i].get("neighbors", [])
			for target in neighbors if neighbors is Array else []:
				var j := int(indices.get(str(target), -1))
				if j < 0 or polygons[j].is_empty():
					continue
				var color := Color("#ffc15c") if i == selected else Color("#79abb9")
				_arrow(centers[i], centers[j], color)
			draw_string(ThemeDB.fallback_font, centers[i] + Vector2(5, -4),
				str(rows[i].get("id", "")), HORIZONTAL_ALIGNMENT_LEFT, -1, 13)
		var parallel := {}
		for edge in edges:
			if not edge is Dictionary:
				continue
			var i := int(indices.get(str(edge.get("from", "")), -1))
			var to_map := str(edge.get("toMap", ""))
			if i >= 0 and not polygons[i].is_empty() and to_map != "":
				if edge.get("id") == selected_edge:
					var p := centers[i]
					_arrow(p, p + Vector2(34, -23), Color("#ffc15c"))
					draw_string(ThemeDB.fallback_font, p + Vector2(36, -24), "%s / %s" % [to_map, edge.get("to", "")],
						HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("#ffc15c"))
				continue
			var j := int(indices.get(str(edge.get("to", "")), -1))
			if i < 0 or j < 0 or polygons[i].is_empty() or polygons[j].is_empty():
				continue
			var color := Color("#ffc15c") if edge.get("id") == selected_edge else Color("#ad9afb")
			var pair := Vector2i(i, j)
			var lane := int(parallel.get(pair, 0))
			parallel[pair] = lane + 1
			_arrow(centers[i], centers[j], color, 5.0 + lane * 5.0)
		if selected >= 0 and selected < polygons.size() and not link_mode:
			for i in polygons[selected].size():
				var point := cursor if dragged == i else polygons[selected][i]
				draw_circle(xf * point, 4.5, Color("#ffc15c"), true, -1, true)

	func _arrow(a: Vector2, b: Vector2, color: Color, offset := 0.0) -> void:
		if a.distance_squared_to(b) < 4.0:
			draw_arc(a + Vector2(13 + offset, -13), 9 + offset, 0, TAU * 0.88, 20, color, 2, true)
			return
		var direction := (b - a).normalized()
		var side := direction.orthogonal() * offset
		var tip := a.lerp(b, 0.72) + side
		draw_line(a + side, b + side, color, 1.5, true)
		draw_line(tip, tip - direction.rotated(0.54) * 10, color, 2, true)
		draw_line(tip, tip - direction.rotated(-0.54) * 10, color, 2, true)

	func _gui_input(event: InputEvent) -> void:
		var xf := projection()
		if event is InputEventMouseMotion and dragged >= 0:
			cursor = xf.affine_inverse() * event.position
			queue_redraw()
			accept_event()
			return
		if not event is InputEventMouseButton or event.button_index not in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			return
		var point: Vector2 = xf.affine_inverse() * event.position
		if not event.pressed:
			if dragged >= 0 and event.button_index == MOUSE_BUTTON_LEFT:
				var idx := dragged
				dragged = -1
				vertex_changed.emit("move", idx, point)
				queue_redraw()
				accept_event()
			return
		if not link_mode and selected >= 0 and selected < polygons.size() \
				and rows[selected] is Dictionary and rows[selected].get("polygon") is Array \
				and rows[selected].polygon.size() == polygons[selected].size():
			var shape := xf * polygons[selected]
			var radius := 9.0
			var vertex := -1
			for i in shape.size():
				var distance := shape[i].distance_to(event.position)
				if distance <= radius:
					vertex = i
					radius = distance
			if vertex >= 0:
				if event.button_index == MOUSE_BUTTON_RIGHT:
					vertex_changed.emit("remove", vertex, point)
				else:
					dragged = vertex
					cursor = polygons[selected][vertex]
				accept_event()
				return
			if event.shift_pressed and event.button_index == MOUSE_BUTTON_LEFT and shape.size() >= 2:
				var nearest := 13.0
				var segment := -1
				for i in shape.size():
					var edge := Geometry2D.get_closest_point_to_segment(event.position, shape[i], shape[(i + 1) % shape.size()])
					var distance := edge.distance_to(event.position)
					if distance <= nearest:
						nearest = distance
						segment = i
						point = xf.affine_inverse() * edge
				if segment >= 0:
					vertex_changed.emit("insert", segment + 1, point)
				accept_event()
				return
		if event.button_index != MOUSE_BUTTON_LEFT:
			return
		for i in range(polygons.size() - 1, -1, -1):
			if polygons[i].size() >= 3 and Geometry2D.is_point_in_polygon(point, polygons[i]):
				cell_clicked.emit(i)
				accept_event()
				return

static func open(app) -> void:
	var cvs = app.canvas
	if cvs == null or not app.map_loaded or not cvs.is_map_ready() or cvs.doc_busy:
		return
	var project: Dictionary = app.manifest
	var data: Dictionary = cvs.map_data
	var baseline: Dictionary = cvs.cell_graph().duplicate(true)
	var graph := baseline.duplicate(true)
	var raw = graph.get("cells", [])
	if not raw is Array:
		app._set_status("格图的 cells 不是数组，未修改源数据。")
		return
	var cells: Array = raw
	var raw_edges = graph.get("edges", [])
	if not raw_edges is Array:
		app._set_status("格图的 edges 不是数组，未修改源数据。")
		return
	var edges: Array = raw_edges
	var raw_spaces = graph.get("spaces", {})
	if not raw_spaces is Dictionary:
		app._set_status("格图的 spaces 不是对象，未修改源数据。")
		return
	var spaces: Dictionary = raw_spaces
	graph["spaces"] = spaces
	var types := Graph.edge_types(project).duplicate(true)
	var shell: Dictionary = app._popup_body("地图格图",
		"顶点保存为空间局部坐标。可切换楼层或视角，也可连接不同空间的格。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var notice := Label.new()
	notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var picker := OptionButton.new()
	picker.name = "GraphCellPicker"
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var new_id := LineEdit.new()
	new_id.placeholder_text = "新格 ID"
	new_id.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var top := Kit.hbox(6)
	top.add_child(picker)
	top.add_child(new_id)
	body.add_child(top)
	var space_tools := Kit.hbox(6)
	var space_picker := OptionButton.new()
	space_picker.name = "GraphSpaceFilter"
	space_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var space_input := LineEdit.new()
	space_input.name = "NewGraphSpaceId"
	space_input.placeholder_text = "新空间 ID"
	space_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	space_tools.add_child(space_picker)
	space_tools.add_child(space_input)
	body.add_child(space_tools)
	var columns := Kit.hbox(10)
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(columns)
	var visual := Kit.vbox(5)
	visual.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(visual)
	var link_toggle := CheckButton.new()
	link_toggle.name = "GraphLinkMode"
	link_toggle.text = "点格切换有向出边"
	visual.add_child(link_toggle)
	var preview := GraphPreview.new()
	preview.graph = graph
	preview.edges = edges
	preview.name = "GraphPreview"
	preview.clip_contents = true
	preview.custom_minimum_size = Vector2(345, 280)
	preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var meta: Dictionary = data.get("meta", {})
	var layers: Array = meta.get("layers", []).duplicate(true)
	preview.layer_frames = MapViewData.layer_transforms(layers)
	var import_row := Kit.hbox(6)
	var tile_layers := OptionButton.new()
	tile_layers.name = "GraphTileLayer"
	tile_layers.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for layer in layers:
		if not layer is Dictionary or str(layer.get("id", "")) == "":
			continue
		var lid := str(layer.id)
		tile_layers.add_item(str(layer.get("name", lid)))
		var at := tile_layers.item_count - 1
		tile_layers.set_item_metadata(at, lid)
		if cvs.layer_id(cvs.active_layer) == lid:
			tile_layers.select(at)
	import_row.add_child(tile_layers)
	var region := Rect2i(cvs._region_sel)
	var region_layer: String = cvs._region_layer
	var limit_to_region := CheckBox.new()
	limit_to_region.text = "仅当前框选格号"
	var scope_region := func():
		var available: bool = region.has_area() and (region_layer == "" or tile_layers.get_selected_metadata() == region_layer)
		limit_to_region.disabled = not available
		limit_to_region.button_pressed = available
	tile_layers.item_selected.connect(func(_idx: int): scope_region.call())
	scope_region.call()
	import_row.add_child(limit_to_region)
	var join_existing := CheckBox.new()
	join_existing.name = "GraphJoinGeneratedTiles"
	join_existing.text = "连接相邻旧格"
	join_existing.tooltip_text = "为新格和相邻的已有生成格添加双向邻接。已有格之间的连接保持原样。"
	import_row.add_child(join_existing)
	body.add_child(import_row)
	body.move_child(import_row, columns.get_index())
	preview.map_bounds = cvs.grid.map_bounds(Rect2i(0, 0, int(meta.get("w", 1)), int(meta.get("h", 1))))
	visual.add_child(preview)
	visual.add_child(Kit.hint_label("拖动顶点 · Shift + 单击边插点 · 右击顶点删除", 340))
	link_toggle.toggled.connect(func(enabled: bool):
		preview.link_mode = enabled
		preview.queue_redraw())
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(330, 335)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var form := Kit.vbox(6)
	form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(form)
	columns.add_child(scroll)
	body.add_child(notice)
	var state := {"index": -1, "commits": [], "edge": "", "space": null, "pending_target": false, "spaces": spaces,
		"project": project, "map_code": str(cvs.cur_map_code())}
	var flush := func() -> bool:
		for commit in state.commits:
			if not bool(commit.call()):
				return false
		return true
	var render := func(idx: int):
		state.pending_target = false
		if idx != state.index:
			state.edge = ""
		state.index = idx
		picker.clear()
		for row in cells:
			picker.add_item(str(row.get("id", "")) if row is Dictionary else "无效记录")
			picker.set_item_metadata(picker.item_count - 1, str(row.get("id", "")) if row is Dictionary else "")
		picker.select(idx)
		_fill_space_picker(space_picker, spaces, state.space, true)
		preview.space_filter = state.space
		preview.selected_edge = str(state.edge)
		link_toggle.text = "点格重接所选连接" if state.edge != "" else "点格切换简单邻接"
		preview.show_graph(cells, idx)
		state.commits.clear()
		for child in form.get_children():
			form.remove_child(child)
			child.queue_free()
		if state.space is String and state.space != "" and spaces.get(state.space) is Dictionary:
			var sid: String = state.space
			var space: Dictionary = spaces[sid]
			_add_space_fields(form, space, layers, state.commits, func():
				preview.show_graph(cells, idx))
			form.add_child(Kit.button("移除此空间", func():
				if cells.any(func(c): return c is Dictionary and c.get("space") == sid):
					notice.text = "此空间仍有格。请先把格移到其他空间。"
					return
				if not flush.call():
					return
				spaces.erase(sid)
				state.space = null
				state.render.call(state.index), "ghost"))
		if idx < 0 or idx >= cells.size() or not cells[idx] is Dictionary:
			return
		var cell: Dictionary = cells[idx]
		var assignment := OptionButton.new()
		assignment.name = "CellLocalSpace"
		_fill_space_picker(assignment, spaces, cell.get("space", ""))
		assignment.item_selected.connect(func(at: int):
			if not flush.call():
				_fill_space_picker(assignment, spaces, cell.get("space", ""))
				return
			var sid: String = assignment.get_item_metadata(at)
			if sid == "":
				cell.erase("space")
			else:
				cell["space"] = sid
			if state.space != null:
				state.space = sid
			state.render.call(idx))
		form.add_child(Kit.field_row("所属空间", assignment, 68))
		var fields := [
			{"id": "polygon", "label": "顶点", "kind": "input", "type": "array", "of": "vector2"},
			{"id": "neighbors", "label": "出边", "kind": "choice", "multiple": true, "options": []},
		]
		for other in cells:
			if other is Dictionary:
				var oid := str(other.get("id", ""))
				if oid != "":
					fields[1].options.append(oid)
		for field in fields:
			var key := str(field.id)
			var apply := func(v) -> bool:
				cell[key] = v
				preview.show_graph(cells, idx)
				return true
			var built := Widgets.build(field, cell.get(key, []), apply)
			var commit: Callable = built.get("commit", Callable())
			if commit.is_valid():
				state.commits.append(commit)
			form.add_child(Kit.field_row(str(field.label), built.ctl, 56))
		_build_edge_fields(form, cell, cells, edges, types, state, flush, notice)
	state.render = render
	import_row.add_child(Kit.button("从瓦片生成格", func():
		if not flush.call() or tile_layers.selected < 0:
			return
		if not is_same(cvs.map_data, data) or not cvs.is_map_ready() or cvs.doc_busy:
			notice.text = "地图已切换或正在重建，请重新打开格图编辑。"
			return
		var lid: String = tile_layers.get_selected_metadata()
		var layer: TileMapLayer = cvs._layer_node(cvs._layer_index_of(lid))
		if layer == null:
			notice.text = "找不到所选瓦片图层。"
			return
		var sid := space_input.text.strip_edges()
		if sid == "":
			var selected_space = spaces.get(state.space, {})
			sid = str(state.space) if state.space is String and selected_space is Dictionary \
				and selected_space.get("layer", "") == lid else lid
		var width := int(meta.get("w", 1))
		var height := int(meta.get("h", 1))
		var tile_grid: GridSpace = cvs.tile_grid_for_layer(cvs._layer_index_of(lid))
		var bounds := Rect2i(0, 0, GridSpace.cell_columns(width, tile_grid.is_tri()), height)
		if limit_to_region.button_pressed:
			bounds = bounds.intersection(region)
		var occupied := _tile_cells_in(layer, bounds)
		if occupied.size() > MAX_TILE_IMPORT:
			notice.text = "单次最多读取 %d 格。请在地图画布上框选较小范围。" % MAX_TILE_IMPORT
			return
		var plan := GraphTiles.plan(graph, tile_grid, lid, sid, occupied, join_existing.button_pressed,
			func(cell: Vector2i) -> bool:
				return tile_grid.cell_in_map(cell, width, height) \
					and layer.get_cell_source_id(cell) != -1)
		if plan.has("error"):
			notice.text = plan.error
			return
		if plan.rows.is_empty():
			notice.text = "没有新格：%d 个已有生成格保持原样。" % plan.skipped
			return
		if not spaces.has(sid):
			spaces[sid] = {"layer": lid}
		var first := cells.size()
		for index in plan.joins:
			cells[index]["neighbors"] = plan.joins[index]
		cells.append_array(plan.rows)
		space_input.clear()
		state.space = sid
		render.call(first)
		notice.text = "已生成 %d 格，保留 %d 个已有格，连接 %d 个相邻旧格。请应用后保存地图。" % [
			plan.rows.size(), plan.skipped, plan.joins.size()], "ghost"))
	space_picker.item_selected.connect(func(at: int):
		if not flush.call():
			_fill_space_picker(space_picker, spaces, state.space, true)
			return
		state.space = space_picker.get_item_metadata(at)
		render.call(state.index))
	space_tools.add_child(Kit.button("添加空间", func():
		var sid := space_input.text.strip_edges()
		if sid == "" or spaces.has(sid):
			notice.text = "请输入尚未使用的空间 ID。"
			return
		if not flush.call():
			return
		spaces[sid] = {}
		state.space = sid
		space_input.clear()
		notice.text = ""
		render.call(state.index), "ghost"))
	picker.item_selected.connect(func(idx: int):
		if flush.call():
			if state.space != null and cells[idx] is Dictionary:
				state.space = cells[idx].get("space", "")
			render.call(idx)
		else:
			picker.select(int(state.index)))
	preview.cell_clicked.connect(func(idx: int):
		if not flush.call():
			return
		var current := int(state.index)
		if not preview.link_mode or current < 0:
			render.call(idx)
			return
		if not cells[current] is Dictionary or not cells[idx] is Dictionary:
			return
		var id := str(cells[idx].get("id", ""))
		if id == "":
			return
		var explicit := _edge_by_id(edges, str(state.edge))
		if not explicit.is_empty():
			explicit["to"] = id
			explicit.erase("toMap")
			render.call(current)
			return
		var neighbors: Array = cells[current].get("neighbors", []) if cells[current].get("neighbors", []) is Array else []
		if neighbors.has(id):
			neighbors.erase(id)
		else:
			neighbors.append(id)
		cells[current]["neighbors"] = neighbors
		render.call(current))
	preview.vertex_changed.connect(func(operation: String, vertex: int, point: Vector2):
		var idx := int(state.index)
		if idx < 0 or not flush.call() or not cells[idx] is Dictionary:
			return
		var points = cells[idx].get("polygon")
		if not points is Array or vertex < 0:
			return
		var xf := Graph.space_transform(graph, str(cells[idx].get("space", "")), preview.layer_frames)
		if not Graph.invertible(xf):
			notice.text = "先修正空间基向量，才能拖动顶点。"
			return
		point = xf.affine_inverse() * point
		if operation == "insert" and vertex <= points.size():
			points.insert(vertex, [point.x, point.y])
		elif vertex < points.size() and operation == "move":
			if points[vertex] == [point.x, point.y]:
				return
			points[vertex] = [point.x, point.y]
		elif vertex < points.size() and operation == "remove":
			if points.size() <= 3:
				notice.text = "一个格至少需要三个顶点。"
				return
			points.remove_at(vertex)
		else:
			return
		cells[idx].erase(GraphTiles.GENERATED_KEY)
		notice.text = ""
		render.call(idx))
	top.add_child(Kit.button("添加格", func():
		var id := new_id.text.strip_edges()
		if id == "" or Graph.cell_ids(graph).has(id):
			notice.text = "请输入尚未使用的格 ID。"
			return
		if not flush.call():
			return
		var size := Vector2(cvs.grid.tile)
		var sid: String = state.space if state.space is String else ""
		var count := cells.filter(func(c): return c is Dictionary and c.get("space", "") == sid).size()
		var at := Vector2(count * size.x, 0)
		var cell := {"id": id, "polygon": [[at.x, at.y], [at.x + size.x, at.y],
			[at.x + size.x, at.y + size.y], [at.x, at.y + size.y]], "neighbors": []}
		if sid != "":
			cell["space"] = sid
		cells.append(cell)
		new_id.clear()
		notice.text = ""
		render.call(cells.size() - 1), "ghost"))
	var actions := Kit.hbox(6)
	body.add_child(actions)
	actions.add_child(Kit.button("移除格…", func():
		var idx := int(state.index)
		if idx < 0 or not flush.call():
			return
		if not await app._confirm_action("移除格",
				"会移除该格、它的出边和本图内指向它的边。其他地图或内容中的格 ID 引用需要另行改接。", "移除"):
			return
		if not is_instance_valid(pop) or not pop.visible or idx != int(state.index):
			return
		Graph.remove_cell(cells, edges, idx, state.map_code)
		state.edge = ""
		render.call(mini(idx, cells.size() - 1)), "ghost"))
	actions.add_child(Kit.button("应用到地图", func():
		if not flush.call():
			return
		if state.pending_target:
			notice.text = "请选择目标格，或切回原目标地图。"
			return
		if not is_instance_valid(cvs) or not is_same(app.manifest, project) \
				or not is_same(cvs.map_data, data) or cvs.cell_graph() != baseline or Graph.edge_types(project) != types \
				or cvs.map_data.get("meta", {}).get("layers", []) != layers \
				or not cvs.is_map_ready() or cvs.doc_busy:
			notice.text = "地图已切换或正在进行其他操作，请重新打开格图编辑。"
			return
		var candidate := graph.duplicate()
		if graph.has("edges") or not edges.is_empty():
			candidate["edges"] = edges
		if spaces.is_empty() and not baseline.has("spaces"):
			candidate.erase("spaces")
		var issues := Graph.validate_graph(candidate, project, preview.layer_frames)
		var errors := issues.filter(func(issue): return issue.get("severity", "error") == "error")
		if not errors.is_empty():
			notice.text = "%s：%s" % [errors[0].path, errors[0].message]
			return
		if candidate != cvs.cell_graph():
			cvs.apply_cell_graph(candidate)
		var message := "格图已应用到当前地图，保存地图即可写盘。"
		if not issues.is_empty():
			message += " %s：%s" % [issues[0].path, issues[0].message]
		app._set_status(message)
		pop.hide(), "primary"))
	actions.add_child(Kit.button("取消", func(): pop.hide(), "ghost"))
	graph["cells"] = cells
	render.call(0 if not cells.is_empty() else -1)
	app._open_popup(pop, Vector2i(780, 550))

## Small selections look up their own coordinates rather than enumerating an entire layer.
static func _tile_cells_in(layer: TileMapLayer, bounds: Rect2i) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	if not bounds.has_area():
		return cells
	if bounds.get_area() <= 4096:
		for y in range(bounds.position.y, bounds.end.y):
			for x in range(bounds.position.x, bounds.end.x):
				var cell := Vector2i(x, y)
				if layer.get_cell_source_id(cell) != -1:
					cells.append(cell)
					if cells.size() > MAX_TILE_IMPORT:
						return cells
		return cells
	for cell in layer.get_used_cells():
		if bounds.has_point(cell):
			cells.append(cell)
			if cells.size() > MAX_TILE_IMPORT:
				break
	return cells

static func _fill_space_picker(list: OptionButton, spaces: Dictionary, selected: Variant, show_all := false) -> void:
	list.clear()
	if show_all:
		list.add_item("所有空间")
		list.set_item_metadata(0, null)
	list.add_item("地图根空间")
	list.set_item_metadata(list.item_count - 1, "")
	var at := 0
	if selected is String:
		at = list.item_count - 1
	for id in spaces:
		var space = spaces[id]
		if not space is Dictionary:
			continue
		list.add_item(str(space.get("name", id)))
		list.set_item_metadata(list.item_count - 1, id)
		if selected == id:
			at = list.item_count - 1
	list.select(at)

static func _add_space_fields(form: VBoxContainer, space: Dictionary, layers: Array,
		commits: Array, refresh: Callable) -> void:
	var picker := OptionButton.new()
	picker.name = "GraphSpaceLayer"
	picker.add_item("不绑定图层")
	picker.set_item_metadata(0, "")
	var current := str(space.get("layer", ""))
	var selected := 0
	for row in layers:
		if not row is Dictionary or not row.get("id") is String or row.id == "":
			continue
		picker.add_item("%s · %s" % [row.get("name", row.id), row.id])
		picker.set_item_metadata(picker.item_count - 1, row.id)
		if row.id == current:
			selected = picker.item_count - 1
	if selected == 0 and current != "":
		picker.add_item("（已缺失）" + current)
		selected = picker.item_count - 1
		picker.set_item_disabled(selected, true)
	picker.select(selected)
	picker.item_selected.connect(func(i: int):
		var lid = picker.get_item_metadata(i)
		if not lid is String:
			return
		if lid == "":
			space.erase("layer")
		else:
			space["layer"] = lid
		refresh.call())
	form.add_child(Kit.field_row("绑定图层", picker, 68))
	for row in [
		["name", "空间名称", "string", ""],
		["origin", "空间原点", "vector2", [0, 0]],
		["axisX", "空间 X 轴", "vector2", [1, 0]],
		["axisY", "空间 Y 轴", "vector2", [0, 1]],
	]:
		var key: String = row[0]
		var decl := {"id": key, "kind": "input", "type": row[2], "step": 0.001}
		var built := Widgets.build(decl, space.get(key, row[3]), func(value) -> bool:
			if key == "name" and value == "":
				space.erase(key)
			else:
				space[key] = value
			refresh.call()
			return true)
		built.ctl.name = "GraphSpace_" + key
		var commit: Callable = built.get("commit", Callable())
		if commit.is_valid():
			commits.append(commit)
		form.add_child(Kit.field_row(str(row[1]), built.ctl, 68))

static func _edge_by_id(edges: Array, id: String) -> Dictionary:
	if id != "":
		for edge in edges:
			if edge is Dictionary and edge.get("id") == id:
				return edge
	return {}

static func _build_edge_fields(form: VBoxContainer, cell: Dictionary, cells: Array, edges: Array,
		types: Dictionary, state: Dictionary, flush: Callable, notice: Label) -> void:
	var picker := OptionButton.new()
	picker.name = "ExplicitEdgePicker"
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.add_item("（未选独立连接）")
	picker.set_item_metadata(0, "")
	var selected := 0
	for row in edges:
		if not row is Dictionary or row.get("from") != cell.get("id"):
			continue
		var at := picker.item_count
		var dest := str(row.get("to", ""))
		if row.get("toMap", "") != "":
			dest = "%s / %s" % [row.toMap, dest]
		picker.add_item("%s → %s · %s" % [row.get("type", ""), dest, row.get("id", "")])
		picker.set_item_metadata(at, row.get("id", ""))
		if row.get("id") == state.edge:
			selected = at
	picker.select(selected)
	picker.item_selected.connect(func(i: int):
		if not flush.call():
			picker.select(selected)
			return
		state.edge = picker.get_item_metadata(i)
		state.render.call(state.index))
	form.add_child(Kit.field_row("独立连接", picker, 68))
	var type_select := OptionButton.new()
	type_select.name = "NewEdgeType"
	type_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	type_select.add_item("通用连接")
	type_select.set_item_metadata(0, "")
	for id in types:
		if types[id] is Dictionary:
			type_select.add_item(str(types[id].get("name", id)))
			type_select.set_item_metadata(type_select.item_count - 1, id)
	type_select.select(0)
	var add_row := Kit.hbox(5)
	add_row.add_child(type_select)
	add_row.add_child(Kit.button("新建连接", func():
		if not flush.call():
			return
		var kind: String = type_select.get_selected_metadata()
		var id := Id.new_inst_code()
		while not _edge_by_id(edges, id).is_empty():
			id = Id.new_inst_code()
		var props := Graph.edge_defaults(types, kind)
		edges.append({"id": id, "from": cell.id, "to": cell.id, "type": kind, "props": props})
		state.edge = id
		notice.text = "已新建连接。可用下拉或在预览中点选目标格。"
		state.render.call(state.index), "ghost"))
	form.add_child(add_row)
	var edge := _edge_by_id(edges, str(state.edge))
	if edge.is_empty():
		return
	var source := OptionButton.new()
	source.name = "ExplicitEdgeSource"
	var old_source := -1
	for i in cells.size():
		var row = cells[i]
		if not row is Dictionary or not row.get("id") is String:
			continue
		source.add_item(row.id)
		source.set_item_metadata(source.item_count - 1, i)
		if edge.get("from") == row.id:
			old_source = source.item_count - 1
	source.select(old_source)
	source.item_selected.connect(func(i: int):
		if not flush.call():
			source.select(old_source)
			return
		var at: int = source.get_item_metadata(i)
		edge["from"] = cells[at].id
		state.index = at
		if state.space != null:
			state.space = cells[at].get("space", "")
		state.render.call(at))
	form.add_child(Kit.field_row("起始格", source, 68))
	_build_edge_destination(form, edge, cells, state, flush)
	var props = edge.get("props", {})
	if not props is Dictionary:
		form.add_child(Kit.hint_label("连接属性格式无效，原值已保留；可移除并重建此连接。", 300))
	else:
		add_edge_properties(form, Graph.edge_fields(types, str(edge.get("type", ""))), edge, "EdgeProperty_", state.commits)
	form.add_child(Kit.button("移除所选连接", func():
		if not flush.call():
			return
		edges.erase(edge)
		state.edge = ""
		notice.text = ""
		state.render.call(state.index), "ghost"))

static func add_edge_properties(form: VBoxContainer, fields: Array, edge: Dictionary, prefix: String, commits: Array) -> void:
	var props: Dictionary = edge.get("props", {})
	for fd in fields:
		if not fd is Dictionary or not fd.get("id") is String:
			continue
		var key: String = fd.id
		var built := Widgets.build(fd, props.get(key, fd.get("default")), func(value) -> bool:
			if value == null or (value is String and value == "" and fd.get("kind") == "choice"):
				props.erase(key)
			else:
				props[key] = value
			edge["props"] = props
			return true)
		var commit: Callable = built.get("commit", Callable())
		if commit.is_valid():
			commits.append(commit)
		built.ctl.name = prefix + key.validate_node_name()
		form.add_child(Kit.field_row(str(fd.get("name", key)), built.ctl, 68))

static func _build_edge_destination(form: VBoxContainer, edge: Dictionary, cells: Array,
		state: Dictionary, flush: Callable) -> void:
	var maps := OptionButton.new()
	maps.name = "ExplicitEdgeMap"
	maps.add_item("当前地图")
	maps.set_item_metadata(0, "")
	if not state.has("map_index"):
		state.map_index = MapStore.code_index(state.project)
	var index: Dictionary = state.map_index
	var old_code := str(edge.get("toMap", ""))
	var selected := 0
	for name in index.get("names", []):
		var code := str(index.get("by_name", {}).get(name, ""))
		if code == state.map_code or RefIndex.resolve_map_code(index, code).status != "ok":
			continue
		maps.add_item("%s · %s" % [name, code])
		maps.set_item_metadata(maps.item_count - 1, code)
		if code == old_code:
			selected = maps.item_count - 1
	if old_code != "" and selected == 0:
		maps.add_item("（不可选）" + old_code)
		selected = maps.item_count - 1
		maps.set_item_metadata(selected, old_code)
	maps.select(selected)
	form.add_child(Kit.field_row("目标地图", maps, 68))
	var target := OptionButton.new()
	target.name = "ExplicitEdgeTarget"
	var refill := func(code: String):
		target.clear()
		var options: Array = []
		if code == "":
			options = Graph.cell_options({"cells": cells, "spaces": state.spaces})
		else:
			var resolved := RefIndex.resolve_map_code(index, code)
			if resolved.status == "ok":
				var doc := MapStore.read(state.project, str(resolved.key))
				if doc.get("meta", {}).get("code") == code:
					options = Graph.cell_options(Graph.graph_of(doc.meta))
		var at := -1
		for option in options:
			target.add_item(option.t)
			target.set_item_metadata(target.item_count - 1, option.v)
			if code == old_code and option.v == edge.get("to"):
				at = target.item_count - 1
		if at < 0 and code == old_code:
			target.add_item("（原目标）" + str(edge.get("to", "")))
			at = target.item_count - 1
			target.set_item_disabled(at, true)
		target.select(at)
		target.disabled = options.is_empty()
	refill.call(old_code)
	maps.item_selected.connect(func(i: int):
		var code: String = maps.get_item_metadata(i)
		state.pending_target = code != old_code
		refill.call(code))
	target.item_selected.connect(func(i: int):
		if not flush.call():
			refill.call(str(maps.get_selected_metadata()))
			return
		var code: String = maps.get_selected_metadata()
		var cid = target.get_item_metadata(i)
		if not cid is String or cid == "":
			return
		if code == "":
			edge.erase("toMap")
		else:
			edge["toMap"] = code
		edge["to"] = cid
		state.render.call(state.index))
	form.add_child(Kit.field_row("目标格", target, 68))
