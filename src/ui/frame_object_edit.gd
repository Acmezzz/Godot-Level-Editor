extends RefCounted
## Two clicks on a frozen frame: select an existing instance or vertex, then choose a destination.

const Picks := preload("res://src/project/frame_picks.gd")
const Ink := Color("ffda67")

var canvas: EditorCanvas
var target: EntityNode
var vertex := Vector2i(-1, -1)
var origin := Vector2.ZERO
var destination := Vector2.ZERO
var local_point := Vector2.ZERO
var rings := []
var can_apply := false
var status := ""

func _init(cvs: EditorCanvas) -> void:
	canvas = cvs
	clear()

func clear() -> void:
	target = null
	vertex = Vector2i(-1, -1)
	rings.clear()
	can_apply = false
	status = "先点选实例或轮廓顶点，再点同一图层的目标位置。右键重选。"

func ready() -> bool:
	return can_apply

func message() -> String:
	return status

func input(event: InputEvent, pixel: Vector2, regions: Array) -> bool:
	if not event is InputEventMouseButton or not event.pressed:
		return false
	if event.button_index == MOUSE_BUTTON_RIGHT:
		clear()
		return true
	if event.button_index != MOUSE_BUTTON_LEFT:
		return false
	if target == null:
		_select(pixel, regions)
	else:
		_destinate(pixel, regions)
	return true

func _select(pixel: Vector2, regions: Array) -> void:
	var hit := Picks.at(regions, pixel, "objectEdit")
	var value = hit.get("value")
	var code := str(value.get("inst", "")) if value is Dictionary else str(value) if value is String else ""
	var entity: EntityNode = canvas._ent_by_code_index().get(code)
	if entity == null:
		status = "这里没有可编辑的实例或顶点。"
		return
	var li := canvas._layer_index_of(entity.layer_id)
	if li < 0 or canvas.is_layer_locked(li):
		status = "实例所在层已锁定或不存在。"
		return
	if value is Dictionary:
		var ring = value.get("ring")
		var index = value.get("index")
		var visual = entity.decl.get("visual", {})
		if not visual is Dictionary or visual.get("type") not in ["poly", "path"] \
				or not _is_index(ring) or not _is_index(index):
			status = "游戏返回的轮廓顶点无效。"
			return
		var available: Array = canvas._selection_ops_ctrl._geometry_rings(entity)
		if ring >= available.size() or index >= available[int(ring)].size():
			status = "游戏返回的轮廓顶点不存在。"
			return
		vertex = Vector2i(int(ring), int(index))
	target = entity
	origin = pixel
	status = "已选 %s · %s。请点同层目标；右键重选。" % [
		code, "顶点 %d/%d" % [vertex.x + 1, vertex.y + 1] if vertex.x >= 0 else "实例"]

func _destinate(pixel: Vector2, regions: Array) -> void:
	can_apply = false
	var hit := Picks.at(regions, pixel, "placement")
	if hit.is_empty() or hit.value.layer != target.layer_id:
		status = "目标必须是此实例所在图层的可编辑位置。"
		return
	local_point = hit.value.point
	var li := canvas._layer_index_of(target.layer_id)
	if vertex.x >= 0:
		var world := canvas.to_layer_world(li, local_point)
		rings = canvas._selection_ops_ctrl._geometry_rings(target)
		rings[vertex.x][vertex.y] = target.geometry_point_from_world(world)
		var issue: String = canvas._selection_ops_ctrl._geometry_problem(target, rings)
		if issue != "":
			status = issue
			return
	destination = pixel
	can_apply = true
	status = "新位置 (%.2f, %.2f) · 确认后写入。" % [local_point.x, local_point.y]

func apply() -> bool:
	var li := canvas._layer_index_of(target.layer_id)
	if canvas.is_layer_locked(li):
		return false
	if vertex.x >= 0:
		canvas._selection_ops_ctrl._commit_ring(target, rings, vertex.x, "已移动实景顶点")
		return true
	var before: Dictionary = canvas._undo_history_ctrl.inst_rows([target])
	if not before.get("ok", false):
		return false
	var original := target.position
	target.position = local_point + target.sort_anchor()
	if not canvas._undo_history_ctrl.inst_commit(before.rows):
		target.position = original
		return false
	canvas._mark_ents()
	canvas.queue_redraw()
	return true

func draw(frame: TextureRect, rect: Rect2) -> void:
	if target == null:
		return
	var scale := rect.size / frame.texture.get_size()
	var start := rect.position + origin * scale
	frame.draw_circle(start, 5.0, Ink)
	if can_apply:
		var end := rect.position + destination * scale
		frame.draw_line(start, end, Ink, 2.0, true)
		frame.draw_circle(end, 5.0, Ink)

static func _is_index(value: Variant) -> bool:
	return (value is int or value is float) and value >= 0 and value < 10000 and int(value) == value
