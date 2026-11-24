extends RefCounted
## Drafts points in the destination layer without touching the map until confirmation.

const AssetDecl := preload("res://src/assets/asset_decl.gd")
const Geometry := preload("res://src/map/object_geometry.gd")
const INK := Color("#dba8ff")

var cvs
var asset := ""
var layer := ""
var visual := {}
var points: Array = []
var target: EntityNode
var adding_part := false

func _init(canvas) -> void:
	cvs = canvas

func active() -> bool:
	return asset != ""

func start() -> void:
	if not cvs.is_map_ready() or cvs.doc_busy or cvs.pick_mode_active:
		return
	var selected: String = cvs.stamp_asset if cvs.place_kind == "object" else ""
	var def := AssetDecl.by_id(cvs.manifest, selected)
	var candidate = def.get("visual", {})
	if def.get("kind") != "entity" or def.get("disabled", false) == true or not cvs.is_placeable(selected) \
			or not candidate is Dictionary or candidate.get("type") not in ["poly", "path"]:
		cvs._hint("先在左栏选中一个多边形或路径实体。")
		return
	var index: int = cvs.active_layer
	if index < 0 or index >= cvs.layer_count() or cvs.is_layer_locked(index) or not cvs.is_layer_visible(index):
		cvs._hint("请选择可见且未锁定的普通图层来绘制。")
		return
	_begin()
	asset = selected
	layer = cvs.layer_id(index)
	visual = candidate.duplicate(true)
	points.clear()
	_hint()
	cvs.queue_redraw()

func start_hole() -> void:
	_start_component(false)

func start_part() -> void:
	_start_component(true)

func _start_component(part: bool) -> void:
	var entity := _selected_outline()
	if entity == null:
		cvs._hint("先选中可编辑的闭合几何实体。")
		return
	_begin()
	target = entity
	adding_part = part
	asset = entity.asset
	layer = entity.layer_id
	visual = Geometry.POLY
	_hint()

func _begin() -> void:
	cvs.cancel_preview_gesture()
	cvs.end_gesture()
	cvs.cancel_paste_mode()
	_clear()

func _selected_outline() -> EntityNode:
	if not cvs.is_map_ready() or cvs.doc_busy or cvs.pick_mode_active:
		return null
	var entity: EntityNode = cvs.selected_entity
	if not is_instance_valid(entity) or not entity.is_visible_in_tree() \
			or not Geometry.closed(entity.decl.get("visual", {})):
		return null
	var li: int = cvs._layer_index_of(entity.layer_id)
	return entity if li >= 0 and not cvs.is_layer_locked(li) and cvs.is_layer_visible(li) else null

func remove_hole_at(world: Vector2) -> bool:
	var entity := _selected_outline()
	if entity == null:
		return false
	var local := entity.geometry_point_from_world(world)
	var parts := entity.geometry_parts()
	for part in parts:
		var index := entity.hole_at(local, part.holes)
		if index >= 0:
			part.holes.remove_at(index)
			commit_parts(entity, parts, "已删除孔洞")
			return true
	return false

func remove_part_at(world: Vector2) -> bool:
	var entity := _selected_outline()
	if entity == null:
		return false
	var local := entity.geometry_point_from_world(world)
	var parts := entity.geometry_parts()
	for i in range(1, parts.size()):
		if Geometry2D.is_point_in_polygon(local, PackedVector2Array(parts[i].points)):
			parts.remove_at(i)
			commit_parts(entity, parts, "已删除附加轮廓")
			return true
	return false

func cancel() -> void:
	if not active():
		return
	_clear()
	cvs._hint("已取消绘制几何。")

func _clear() -> void:
	asset = ""
	target = null
	adding_part = false
	layer = ""
	visual = {}
	points.clear()
	cvs.queue_redraw()

func _index() -> int:
	var index: int = cvs._layer_index_of(layer)
	if target != null:
		return index if is_instance_valid(target) and target == _selected_outline() else -1
	if index < 0 or index != cvs.active_layer or cvs.is_layer_locked(index) or not cvs.is_layer_visible(index) \
			or cvs.stamp_asset != asset or cvs.place_kind != "object":
		return -1
	return index

func _point(world: Vector2, index: int) -> Vector2:
	return cvs.snap_anchor_px(Vector2(0.5, 0.5), cvs.to_layer_local(index, world))

func add(world: Vector2) -> void:
	var index := _index()
	if index < 0:
		cancel()
		return
	var point := _point(world, index)
	if points.size() >= Geometry.MAX_POINTS:
		cvs._hint("顶点已到上限。按 Enter 完成或右键撤掉末点。")
		return
	if point.is_finite() and (points.is_empty() or not point.is_equal_approx(points[-1])):
		points.append(point)
	_hint()
	cvs.queue_redraw()

func remove_last() -> void:
	if points.is_empty():
		cancel()
		return
	points.pop_back()
	_hint()
	cvs.queue_redraw()

func finish() -> void:
	var index := _index()
	if index < 0 or cvs.doc_busy:
		cancel()
		return
	var local: Array = points.duplicate()
	if is_instance_valid(target):
		var entity := target
		var ring := local.map(func(p): return entity.geometry_point_from_world(cvs.to_layer_world(index, p)))
		var parts := entity.geometry_parts()
		var hint := "已添加附加轮廓" if adding_part else "已添加孔洞"
		var issue := Geometry.add_ring(parts, ring, adding_part)
		if issue != "":
			cvs._hint(issue)
			return
		_clear()
		commit_parts(entity, parts, hint)
		return
	var issue := Geometry.problem(local.map(func(p): return p - local[0]), visual) if not local.is_empty() \
		else Geometry.problem(local, visual)
	if issue != "":
		cvs._hint(issue + " 左键加点，右键撤掉末点。")
		return
	var placed: EntityNode = cvs._tool_ops_ctrl.place_object(asset, index, local[0], true, local)
	if placed != null:
		_clear()
		cvs._hint("已绘制几何实体（Ctrl+Z 撤销）。")

func commit_parts(entity: EntityNode, parts: Array, hint: String) -> void:
	var before: Dictionary = cvs._undo_history_ctrl.inst_rows([entity])
	if not before.get("ok", false):
		cvs.push_undo()
	entity.geometry_parts_write(parts)
	entity.refresh_visual()
	if before.get("ok", false):
		cvs._undo_history_ctrl.inst_commit(before.rows)
	cvs._mark_ents()
	cvs._hint(hint + "（Ctrl+Z 撤销）。")
	cvs.queue_redraw()

func draw(world: Vector2) -> void:
	var index := _index()
	if index < 0:
		return
	var stroke: float = 2.0 / cvs.zoom
	var hover: Vector2 = cvs.to_layer_world(index, _point(world, index))
	var line := PackedVector2Array()
	for p in points:
		var wp: Vector2 = cvs.to_layer_world(index, p)
		line.append(wp)
		cvs.draw_circle(wp, stroke * 2.0, INK)
	if not line.is_empty():
		line.append(hover)
		if Geometry.closed(visual) and line.size() > 2:
			line.append(line[0])
		cvs.draw_polyline(line, INK, stroke, true)
	cvs.draw_arc(hover, stroke * 3, 0.0, TAU, 20, INK, stroke, true)

func _hint() -> void:
	cvs._hint("绘制%s · %d 点：左键加点 / 右键撤末点 / Enter 完成 / Esc 取消" %
		[("附加轮廓" if adding_part else "孔洞") if is_instance_valid(target)
			else ("闭合轮廓" if Geometry.closed(visual) else "路径"), points.size()])
