extends RefCounted
## One canvas-space selection across tile grids, instances and root collision.

var cvs
var selection := Rect2()

func _init(canvas) -> void:
	cvs = canvas

func select_area(a: Vector2, b: Vector2) -> void:
	selection = Rect2(a.min(b), (a - b).abs())
	cvs._hint("跨层框选已完成：从框内拖动，右键清除")
	cvs.queue_redraw()

func begin_move(pos: Vector2) -> void:
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
		if cvs.is_layer_locked(li):
			cvs._hint("框内包含锁定层的瓦片或碰撞，无法搬动。")
			return
		var cells := {}
		for row in rows:
			cells[Vector2i(row[0], row[1])] = true
		groups.append({"li": li, "lid": lid, "layer": layer, "grid": grid, "rows": rows, "cells": cells})
	var objects: Array[EntityNode] = []
	for n: EntityNode in cvs.ents_shown():
		var li: int = cvs._layer_index_of(n.layer_id)
		if not selection.has_point(cvs.to_layer_world(li, n.position - n.sort_anchor())):
			continue
		if cvs.is_layer_locked(li):
			cvs._hint("框内包含锁定层的实例，无法搬动。")
			return
		objects.append(n)
	if groups.is_empty() and objects.is_empty():
		cvs._hint("框内没有可搬动的瓦片、实例或根碰撞。")
		return
	cvs._move_snap = {"world": true, "groups": groups, "objects": objects, "plan": {}, "delta": Vector2.ZERO}
	cvs._move_grab = pos
	cvs.begin_gesture(cvs.Gesture.REGION_MOVE, MOUSE_BUTTON_LEFT)

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
	cvs.queue_redraw()

func _plan(groups: Array, delta: Vector2) -> Dictionary:
	var meta: Dictionary = cvs.map_data.meta
	var positions := []
	for group in groups:
		var layer: TileMapLayer = group.layer
		var grid: GridSpace = group.grid
		var local_delta: Vector2 = cvs.world_delta_local(group.li, delta)
		var unresolved: Dictionary = cvs._unresolved_tiles.get(group.lid, {})
		var assigned := {}
		var destinations: Array[Vector2i] = []
		for row in group.rows:
			var src := Vector2i(row[0], row[1])
			var dst := grid.pick_cell(grid.cell_center_px(src) + local_delta)
			if not grid.cell_in_map(dst, int(meta.w), int(meta.h)):
				return {"error": "目标格 %s 超出地图，未搬动。" % str(dst)}
			if assigned.has(dst):
				return {"error": "多个源格落到 %s，未搬动。" % str(dst)}
			if not group.cells.has(dst) and (layer.get_cell_source_id(dst) >= 0 or unresolved.has(dst)):
				return {"error": "目标格 %s 已有本次未选中的内容，未搬动。" % str(dst)}
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
	var changed: bool = not snap.objects.is_empty()
	for i: int in snap.groups.size():
		var group: Dictionary = snap.groups[i]
		for j: int in group.rows.size():
			var row: Array = group.rows[j]
			if plan.positions[i][j] != Vector2i(row[0], row[1]):
				changed = true
				break
	if not changed:
		return
	cvs.push_undo()
	for i: int in snap.groups.size():
		var group: Dictionary = snap.groups[i]
		for row in group.rows:
			var from := Vector2i(row[0], row[1])
			if group.layer == cvs.collision:
				cvs.set_collision_cell(from, false)
			else:
				cvs.erase_tile(group.lid, group.layer, from)
		for j: int in group.rows.size():
			var to: Vector2i = plan.positions[i][j]
			var row: Array = group.rows[j]
			if group.layer == cvs.collision:
				var data: Dictionary = row[2]
				cvs.set_collision_cell(to, true, data.get("type", "solid"), data.get("shape", ""), data.get("raw", {}))
			else:
				cvs._region_ops_ctrl._write_layer_tile(group.lid, group.layer, row, to)
	for n: EntityNode in snap.objects:
		n.position += cvs.world_delta_local(cvs._layer_index_of(n.layer_id), snap.delta)
	selection = Rect2()
	cvs._mark()
	cvs.queue_redraw()
	cvs._hint("已跨层搬动选区（Ctrl+Z 撤销）。格图、格边和出生点保持原位。")

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
	for i: int in snap.groups.size():
		var group: Dictionary = snap.groups[i]
		var xf: Transform2D = cvs.layer_xform(group.li)
		var grid: GridSpace = group.grid
		var fill := Color(1.0, 0.35, 0.35, 0.42) if group.layer == cvs.collision else Color(0.45, 1.0, 0.75, 0.32)
		for cell in plan.positions[i]:
			cvs.draw_colored_polygon(xf * grid.cell_polygon(cell), fill)
	for n: EntityNode in snap.objects:
		var rect: Rect2 = cvs.layer_xform(cvs._layer_index_of(n.layer_id)) * n.aabb()
		rect.position += delta
		cvs.draw_rect(rect, color, false, 1.5)
