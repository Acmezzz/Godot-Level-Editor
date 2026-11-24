extends RefCounted
## Move or copy a canvas-space selection across the map's editable layers.

const ClonePlan := preload("res://src/content/clone_plan.gd")
const GraphClip := preload("res://src/map/cell_graph_clip.gd")
const EdgeRef := preload("res://src/map/edge_ref.gd")

var cvs
var selection := Rect2()
var move_graph := false
var move_spawn := false

func _init(canvas) -> void:
	cvs = canvas

func select_area(a: Vector2, b: Vector2) -> void:
	selection = Rect2(a.min(b), (a - b).abs())
	cvs._hint("跨层框选已完成：框内拖动 / Ctrl+C 复制 / 右键清除")
	cvs.queue_redraw()

func begin_move(pos: Vector2) -> void:
	var snap := _collect(true)
	if snap.is_empty():
		return
	if move_graph:
		var graph: Dictionary = cvs.cell_graph()
		snap.graph_cells = GraphClip.select_cells(graph, cvs.map_root.get_global_transform(),
			cvs._cell_layer_frames(graph), _visible_layers(), selection)
		for cell in snap.graph_cells:
			if cell.layer != "" and cvs.is_layer_locked(cvs._layer_index_of(cell.layer)):
				cvs._hint("框内包含锁定层的格图多边形，无法搬动。")
				return
	if move_spawn and cvs.is_layer_visible(cvs.collision_index()):
		var origin: Vector2 = cvs.spawn.get_global_position()
		if selection.has_point(origin):
			if cvs.is_layer_locked(cvs.collision_index()):
				cvs._hint("出生点所在根碰撞层已锁定，无法搬动。")
				return
			snap.spawn = origin
	if snap.groups.is_empty() and snap.objects.is_empty() and snap.get("graph_cells", []).is_empty() and not snap.has("spawn"):
		cvs._hint("框内没有符合搬动选项的内容。")
		return
	cvs._move_snap = snap
	cvs._move_grab = pos
	cvs.begin_gesture(cvs.Gesture.REGION_MOVE, MOUSE_BUTTON_LEFT)

func _collect(moving: bool) -> Dictionary:
	var groups := []
	var meta: Dictionary = cvs.map_data.meta
	var collision_index: int = cvs.collision_index()
	for li: int in range(collision_index + 1):
		var root_collision := li == collision_index
		if not root_collision and not cvs.is_layer_visible(li):
			continue
		var lid: String = cvs.layer_id(li)
		var layer: TileMapLayer = cvs.collision if root_collision else cvs._layer_node(li)
		var grid: GridSpace = cvs.grid if root_collision else cvs.tile_grid_for_layer(li)
		var xf: Transform2D = cvs.layer_xform(li)
		var rows := []
		if root_collision:
			for cell in layer.get_used_cells():
				if selection.has_point(xf * grid.cell_center_px(cell)):
					rows.append([cell.x, cell.y, cvs._collision_meta.get(cell, {})])
		else:
			var cols := int(meta.w) * (2 if grid.is_tri() else 1)
			var all: Array = cvs._region_ops_ctrl._tile_rows_in_rect(layer, lid, Rect2i(0, 0, cols, int(meta.h)))
			for row in all:
				if selection.has_point(xf * grid.cell_center_px(Vector2i(row[0], row[1]))):
					rows.append(row)
		if rows.is_empty():
			continue
		if moving and cvs.is_layer_locked(li):
			cvs._hint("框内包含锁定层的瓦片或碰撞，无法搬动。")
			return {}
		var cells := {}
		for row in rows:
			cells[Vector2i(row[0], row[1])] = true
		groups.append({"li": li, "lid": lid, "layer": layer, "grid": grid, "rows": rows, "cells": cells})
	var objects: Array[EntityNode] = []
	for n: EntityNode in cvs.ents_shown():
		var li: int = cvs._layer_index_of(n.layer_id)
		if not selection.has_point(cvs.to_layer_world(li, n.position - n.sort_anchor())):
			continue
		if moving and cvs.is_layer_locked(li):
			cvs._hint("框内包含锁定层的实例，无法搬动。")
			return {}
		objects.append(n)
	return {"world": true, "groups": groups, "objects": objects, "plan": {}, "delta": Vector2.ZERO}

func _visible_layers() -> Dictionary:
	var visible := {}
	for li in cvs.layer_count():
		if cvs.is_layer_visible(li):
			visible[cvs.layer_id(li)] = cvs.layer_name(li)
	return visible

func copy(include_graph := false, include_spawn := false, follow_edges := false) -> bool:
	if not selection.has_area():
		cvs._hint("先框选跨层区域再复制。")
		return false
	var snap := _collect(false)
	var source: Dictionary = cvs.copy_content_source()
	if source.is_empty():
		return false
	var groups := []
	var layer_names := {}
	for group in snap.groups:
		var centers: Array[Vector2] = []
		var xf: Transform2D = cvs.layer_xform(group.li)
		var grid: GridSpace = group.grid
		for row in group.rows:
			centers.append(xf * grid.cell_center_px(Vector2i(row[0], row[1])) - selection.position)
		groups.append({"lid": group.lid, "root": group.layer == cvs.collision,
			"rows": group.rows.duplicate(true), "centers": centers})
		layer_names[group.lid] = cvs.layer_name(group.li)
	var objects := []
	var anchors: Array[Vector2] = []
	for n: EntityNode in snap.objects:
		var li: int = cvs._layer_index_of(n.layer_id)
		objects.append(cvs._undo_history_ctrl._object_row(n))
		anchors.append(cvs.to_layer_world(li, n.position - n.sort_anchor()) - selection.position)
		layer_names[n.layer_id] = cvs.layer_name(li)
	var clip := {"world": true, "source": source, "layer_names": layer_names,
		"groups": groups, "objects": objects, "anchors": anchors, "extent": selection.size,
		"snap_offset": _root_center(selection.position) - selection.position}
	if follow_edges:
		clip.edge_origin = {"area": selection, "grid": cvs.grid, "frame": cvs.layer_xform(cvs.collision_index())}
	if include_graph:
		var graph: Dictionary = cvs.cell_graph()
		var visible := _visible_layers()
		var captured := GraphClip.capture(graph, cvs.map_root.get_global_transform(), cvs._cell_layer_frames(graph),
			visible, selection, source.map, str(source.meta.get("code", "")))
		if not captured.cells.is_empty():
			clip.graph = captured
			for space in captured.spaces.values():
				var lid: String = space.get("layer", "")
				if lid != "":
					layer_names[lid] = visible[lid]
	var spawn_world: Vector2 = cvs.spawn.get_global_position()
	if include_spawn and selection.has_point(spawn_world):
		clip.spawn = spawn_world - selection.position
	if groups.is_empty() and objects.is_empty() and not clip.has("graph") and not clip.has("spawn"):
		cvs._hint("框内没有符合复制选项的内容。")
		return false
	cvs._region_clip = clip
	cvs._last_copy_region = true
	var extras := "，含格图" if clip.has("graph") else ""
	if follow_edges:
		extras += "，重映射副本的框内格边引用"
	if clip.has("spawn"):
		extras += "，粘贴将设置目标出生点"
	cvs._hint("已复制跨层区域%s。Ctrl+V 预览，左键放置。" % extras)
	return true

func _root_center(pos: Vector2) -> Vector2:
	var grid: GridSpace = cvs.grid
	return cvs.layer_xform(cvs.collision_index()) * grid.cell_center_px(cvs.root_cell(pos))

func _paste_origin(pos: Vector2, clip: Dictionary) -> Vector2:
	return _root_center(pos) - clip.snap_offset if cvs.snap_to_grid else pos

func _plan_spawn(plan: Dictionary, world: Vector2, action: String) -> void:
	var grid: GridSpace = cvs.grid
	var cell: Vector2i = cvs.root_cell(world)
	if grid.cell_in_map(cell, int(cvs.map_data.meta.w), int(cvs.map_data.meta.h)):
		plan.spawn = cell
	else:
		plan.error = "目标出生点超出地图，未%s。" % action

func _paste_plan(origin: Vector2, clip: Dictionary, preview_only := false) -> Dictionary:
	var same_map: bool = clip.source.map == cvs.cur_map_name and clip.source.meta.get("code") == cvs.map_data.meta.get("code")
	var layers := {}
	for lid in clip.layer_names:
		if lid == "":
			continue
		var missed := []
		var li: int = cvs._region_ops_ctrl._paste_layer_index(lid, clip.layer_names, missed, same_map)
		if not missed.is_empty() or layers.values().has(li):
			return {"error": "目标地图未找到唯一的对应图层「%s」。" % clip.layer_names[lid]}
		if cvs.is_layer_locked(li) or not cvs.is_layer_visible(li):
			return {"error": "目标图层「%s」已锁定或隐藏。" % cvs.layer_name(li)}
		layers[lid] = li
	var groups := []
	for src in clip.groups:
		var li: int = cvs.collision_index() if src.root else layers[src.lid]
		if cvs.is_layer_locked(li):
			return {"error": "根碰撞层已锁定。"}
		groups.append({"li": li, "lid": cvs.layer_id(li), "layer": cvs._layer_node(li),
			"grid": cvs.grid if src.root else cvs.tile_grid_for_layer(li),
			"rows": src.rows, "centers": src.centers, "cells": {}})
	var plan := _plan(groups, origin, "粘贴")
	if plan.has("error"):
		return plan
	plan.groups = groups
	plan.layers = layers
	if clip.has("spawn"):
		_plan_spawn(plan, origin + clip.spawn, "粘贴")
		if plan.has("error"):
			return plan
	if clip.has("graph"):
		var graph: Dictionary = cvs.cell_graph()
		var world: Transform2D = cvs.map_root.get_global_transform()
		var frames: Dictionary = cvs._cell_layer_frames(graph)
		var mapping := {}
		for lid in layers:
			var next: String = cvs.layer_id(layers[lid])
			mapping[lid] = next
			frames[next] = world.affine_inverse() * cvs.layer_xform(layers[lid])
		var spaces := GraphClip.merge_spaces(clip.graph, graph, mapping)
		if spaces.has("error"):
			return spaces
		if not preview_only:
			var graph_paste := GraphClip.paste(clip.graph, graph, spaces.spaces, origin, world, frames)
			plan.graph = graph_paste.graph
			plan.cell_ids = graph_paste.ids
	return plan

func paste_at(pos: Vector2) -> void:
	var clip: Dictionary = cvs._region_clip
	var origin := _paste_origin(pos, clip)
	var target := _paste_plan(origin, clip)
	if target.has("error"):
		cvs._hint(target.error)
		return
	var source: Dictionary = clip.source
	var map_edge := Callable()
	if clip.has("edge_origin"):
		var edge: Dictionary = clip.edge_origin
		map_edge = EdgeRef.region_mapper(edge.grid, Vector2i(source.meta.w, source.meta.h), edge.frame,
			edge.area, cvs.grid, Vector2i(cvs.map_data.meta.w, cvs.map_data.meta.h),
			cvs.layer_xform(cvs.collision_index()), origin)
	var clone := ClonePlan.build(
		{"data": {"meta": source.meta, "objects": clip.objects}, "manifest": cvs.manifest, "map": source.map,
			"cell_ids": target.get("cell_ids", {}), "map_edge": map_edge},
		{"data": cvs.extract(), "manifest": cvs.manifest, "map": cvs.cur_map_name},
		PackedStringArray(), false, source.staged)
	if clone.status != "ok":
		cvs._hint("跨层粘贴已取消：" + ClonePlan.conflicts_text(clone.conflicts))
		return
	cvs.push_undo()
	cvs._region_ops_ctrl.stage_cloned_contents(clone)
	for i in target.groups.size():
		_write_group(target.groups[i], target.positions[i])
	for i in clip.objects.size():
		var row: Dictionary = clone.map_patch.objects[i]
		var li: int = target.layers[clip.objects[i].layer]
		row["layer"] = cvs.layer_id(li)
		var n: EntityNode = cvs._undo_history_ctrl._node_from_row(row)
		n.position = cvs.to_layer_local(li, origin + clip.anchors[i]) + n.sort_anchor()
	if target.has("graph"):
		cvs.map_data.meta["cellGraph"] = target.graph
	if target.has("spawn"):
		cvs.spawn.position = cvs.grid.cell_center_px(target.spawn)
	cvs._paste_mode = false
	cvs._mark()
	cvs.queue_redraw()
	cvs._hint("已粘贴跨层区域（Ctrl+Z 撤销）。")

func preview(pos: Vector2) -> void:
	var snap: Dictionary = cvs._move_snap
	var root: Transform2D = cvs.layer_xform(cvs.collision_index())
	var grid: GridSpace = cvs.grid
	var delta := pos - (cvs._move_grab as Vector2)
	if cvs.snap_to_grid:
		delta = root.basis_xform(grid.cell_center_px(cvs.root_cell(pos)) -
			grid.cell_center_px(cvs.root_cell(cvs._move_grab)))
	if snap.delta == delta:
		return
	snap.delta = delta
	snap.plan = {} if delta == Vector2.ZERO else _plan(snap.groups, delta)
	if delta != Vector2.ZERO and snap.has("spawn") and not snap.plan.has("error"):
		_plan_spawn(snap.plan, snap.spawn + delta, "搬动")
	cvs.queue_redraw()

func _plan(groups: Array, delta: Vector2, action := "搬动") -> Dictionary:
	var meta: Dictionary = cvs.map_data.meta
	var positions := []
	for group in groups:
		var layer: TileMapLayer = group.layer
		var grid: GridSpace = group.grid
		var local_delta: Vector2 = cvs.world_delta_local(group.li, delta)
		var unresolved: Dictionary = cvs._unresolved_tiles.get(group.lid, {})
		var assigned := {}
		var destinations: Array[Vector2i] = []
		for i in group.rows.size():
			var row: Array = group.rows[i]
			var src := Vector2i(row[0], row[1])
			var point: Vector2 = cvs.to_layer_local(group.li, delta + group.centers[i]) \
				if group.has("centers") else grid.cell_center_px(src) + local_delta
			var dst := grid.pick_cell(point)
			if not grid.cell_in_map(dst, int(meta.w), int(meta.h)):
				return {"error": "目标格 %s 超出地图，未%s。" % [str(dst), action]}
			if assigned.has(dst):
				return {"error": "多个源格落到 %s，未%s。" % [str(dst), action]}
			if not group.cells.has(dst) and (layer.get_cell_source_id(dst) >= 0 or unresolved.has(dst)):
				return {"error": "目标格 %s 有内容，未%s。" % [str(dst), action]}
			assigned[dst] = true
			destinations.append(dst)
		positions.append(destinations)
	return {"positions": positions}

func finish(snap: Dictionary) -> void:
	var plan: Dictionary = snap.plan
	if plan.is_empty():
		return
	if plan.has("error"):
		cvs._hint(plan.error)
		cvs.queue_redraw()
		return
	var history = cvs._undo_history_ctrl
	var entry := {"kind": "region_move", "cells": [], "objects": {}, "graph_rows": {}}
	for i: int in snap.groups.size():
		var group: Dictionary = snap.groups[i]
		var changes := {}
		for row: Array in group.rows:
			changes[Vector2i(row[0], row[1])] = null
		for j: int in group.rows.size():
			var row: Array = group.rows[j]
			var to: Vector2i = plan.positions[i][j]
			if group.layer == cvs.collision:
				var data: Dictionary = row[2]
				changes[to] = {"type": data.get("type", "solid"), "shape": data.get("shape", ""),
					"raw": data.get("raw", {})}
			else:
				changes[to] = _placed_tile(row, to)
		entry.cells.append_array(history.region_cell_changes(group.lid, group.layer, changes))
	var uncoded_positions := {}
	for n: EntityNode in snap.objects:
		var to: Vector2 = n.position + cvs.world_delta_local(cvs._layer_index_of(n.layer_id), snap.delta)
		if to == n.position:
			continue
		if n.code.is_empty():
			uncoded_positions[n] = to
		else:
			entry.objects[n.code] = {"before": n.position, "after": to}
	var graph_cells: Array = snap.get("graph_cells", [])
	if not graph_cells.is_empty():
		entry.graph_rows = GraphClip.translated_rows(cvs.cell_graph(), graph_cells, snap.delta)
	if plan.has("spawn"):
		var to: Vector2 = cvs.grid.cell_center_px(plan.spawn)
		if to != cvs.spawn.position:
			entry.spawn = {"before": cvs.spawn.position, "after": to}
	if entry.cells.is_empty() and entry.objects.is_empty() and uncoded_positions.is_empty() \
			and entry.graph_rows.is_empty() and not entry.has("spawn"):
		return
	history.commit_region_move(entry, uncoded_positions)
	selection = Rect2()
	cvs._hint("已跨层搬动选区（Ctrl+Z 撤销）。")

func _placed_tile(row: Array, cell: Vector2i) -> Array:
	var placed := row.duplicate()
	placed[0] = cell.x
	placed[1] = cell.y
	return placed

func _write_group(group: Dictionary, positions: Array) -> void:
	for j in group.rows.size():
		var to: Vector2i = positions[j]
		var row: Array = group.rows[j]
		if group.layer == cvs.collision:
			var data: Dictionary = row[2]
			cvs.set_collision_cell(to, true, data.get("type", "solid"), data.get("shape", ""), data.get("raw", {}))
		else:
			cvs.write_tile_row(group.lid, group.layer, _placed_tile(row, to))

func draw_paste(pos: Vector2) -> void:
	var clip: Dictionary = cvs._region_clip
	var origin := _paste_origin(pos, clip)
	var plan := _paste_plan(origin, clip, true)
	var color := Color(1.0, 0.35, 0.35, 0.9) if plan.has("error") else Color(0.45, 1.0, 0.75, 0.8)
	cvs.draw_rect(Rect2(origin, clip.extent), color, false, 2.0)
	if plan.has("error"):
		return
	_draw_cells(plan.groups, plan.positions)
	for anchor in clip.anchors:
		cvs.draw_circle(origin + anchor, 4.0 / cvs.zoom, color)
	if clip.has("graph"):
		for row in clip.graph.cells:
			_draw_graph_outline(Transform2D(0.0, origin) * PackedVector2Array(row.polygon), color)
	if plan.has("spawn"):
		_draw_spawn(plan.spawn, color)

func draw(snap: Dictionary) -> void:
	if selection.has_area():
		cvs.draw_rect(selection, Color(1.0, 0.85, 0.3, 0.85), false, 1.5)
	if not snap.has("world") or snap.plan.is_empty():
		return
	var plan: Dictionary = snap.plan
	var delta: Vector2 = snap.delta
	var color := Color(0.45, 1.0, 0.75, 0.8)
	if plan.has("error"):
		color = Color(1.0, 0.35, 0.35, 0.9)
	cvs.draw_rect(Rect2(selection.position + delta, selection.size), color, false, 2.0)
	if plan.has("error"):
		return
	_draw_cells(snap.groups, plan.positions)
	for n: EntityNode in snap.objects:
		var rect: Rect2 = cvs.layer_xform(cvs._layer_index_of(n.layer_id)) * n.aabb()
		rect.position += delta
		cvs.draw_rect(rect, color, false, 1.5)
	for cell in snap.get("graph_cells", []):
		_draw_graph_outline(Transform2D(0.0, delta) * cell.polygon, color)
	if plan.has("spawn"):
		_draw_spawn(plan.spawn, color)

func _draw_graph_outline(poly: PackedVector2Array, color: Color) -> void:
	poly.append(poly[0])
	cvs.draw_polyline(poly, color, 2.0 / cvs.zoom)

func _draw_spawn(cell: Vector2i, color: Color) -> void:
	var center: Vector2 = cvs.to_layer_world(cvs.collision_index(), cvs.grid.cell_center_px(cell))
	cvs.draw_arc(center, 7.0 / cvs.zoom, 0, TAU, 20, color, 2.0 / cvs.zoom)

func _draw_cells(groups: Array, positions: Array) -> void:
	for i in groups.size():
		var group: Dictionary = groups[i]
		var xf: Transform2D = cvs.layer_xform(group.li)
		var grid: GridSpace = group.grid
		var fill := Color(1.0, 0.35, 0.35, 0.42) if group.layer == cvs.collision else Color(0.45, 1.0, 0.75, 0.32)
		for cell in positions[i]:
			cvs.draw_colored_polygon(xf * grid.cell_polygon(cell), fill)
