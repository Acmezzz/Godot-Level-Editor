extends RefCounted
## 地图撤销与重做；差量和整图快照共用历史上限。

var cvs   # 宿主引用

const ContentStore := preload("res://src/content/content_store.gd")
const CanvasSnapshot := preload("res://src/canvas/canvas_snapshot.gd")
const MapFormat := preload("res://src/map/map_format.gd")

func _init(host) -> void:
	cvs = host

const UNDO_MAX := 80
var undo_stack: Array = []
var redo_stack: Array = []
var published_contents := {}

## 清空历史（换图/载图/草稿恢复时调用）：旧图的条目不能留到新图上。
func clear_history() -> void:
	undo_stack.clear()
	redo_stack.clear()
	published_contents.clear()

func _snapshot() -> String:
	return MapFormat.encode(cvs.extract(), true)


func _restore(snapshot) -> void:
	var d = snapshot
	if snapshot is String:
		d = JSON.parse_string(snapshot)
	# 空快照 = extract() 的重建窗口哨兵，恢复它等于清空整图——拒绝
	if d is Dictionary and not (d as Dictionary).is_empty():
		# keep_dirty=true：恢复的是历史状态，内容与磁盘不一致即为脏
		await cvs.load_data(d, cvs.cur_map_name, true, true)


## 整图操作或无法按实例码寻址的改动使用快照。
func push_undo(clone_contents := [], before: Dictionary = {}) -> void:
	if cvs.map_root == null or not is_instance_valid(cvs.map_root):
		return
	var snap := _snapshot() if before.is_empty() else MapFormat.encode(before, true)
	if snap == "{}":
		return   # 重建窗口哨兵（extract 返回 {}）：恢复它=清空整图，拒绝入栈
	if clone_contents.is_empty():
		_push_entry(snap)
	else:
		_push_entry({"snapshot": snap, "clone_contents": clone_contents})

func _mirror_snapshot(entry: Variant) -> Variant:
	var snap := _snapshot()
	if entry is Dictionary:
		return {"snapshot": snap, "clone_contents": entry.clone_contents}
	return snap

## 差量条目入栈（H01/§7.5 阶段二共用）：新操作一律清空 redo。
func _push_entry(entry: Variant) -> void:
	undo_stack.append(entry)
	if undo_stack.size() > UNDO_MAX:
		undo_stack.pop_front()
	redo_stack.clear()

func record_layer_move(from: int, to: int) -> void:
	_push_entry({"kind": "layer_order", "before": from, "after": to})

## 快照恢复会让出一帧，同一时间只允许一个恢复操作。
var _restoring := false

## 最近一次 undo/redo 因「内容文件被外部改过」而拒绝（UI 据此给准确提示，而不是「没有可撤销的操作」）。
var refused_external := false

func undo() -> bool:
	return await _restore_history(false)

func redo() -> bool:
	return await _restore_history(true)

func _restore_history(forward: bool) -> bool:
	refused_external = false
	if cvs.doc_busy or _restoring or not is_instance_valid(cvs.map_root):
		return false
	if not forward and _stroke_open:
		stroke_end()
	var source := redo_stack if forward else undo_stack
	var target := undo_stack if forward else redo_stack
	if source.is_empty():
		return false
	# 撤销前先归位拖拽预览，避免松手后再写回旧候选。
	if not forward:
		cvs.cancel_preview_gesture()
	_restoring = true
	var entry = source.pop_back()
	var mirror = entry if _is_patch(entry) else _mirror_snapshot(entry)
	var ok := await _apply_entry(entry, forward)
	refused_external = not ok
	if ok:
		target.append(mirror)
	else:
		source.append(entry)
	_restoring = false
	return ok

## 差量条目（自带 before/after，可双向复用）与整图快照（只有一侧）的判别。
func _is_patch(entry) -> bool:
	if not (entry is Dictionary):
		return false
	return str((entry as Dictionary).get("kind", "")) in ["delta", "ents", "content", "region_move", "spawn", "cell_graph", "layer_order"]


## 条目 → 状态（undo 用 forward=false，redo 用 true）。返回是否真的应用了。
## 差量只写受影响的数据；整图快照恢复地图文档。
func _apply_entry(entry, forward: bool) -> bool:
	if _is_patch(entry):
		var d: Dictionary = entry
		match str(d.get("kind", "")):
			"delta":
				_restore_delta(d, forward)
			"ents":
				_restore_ents(d, forward)
			"content":
				return _restore_content(d, forward)
			"region_move":
				_restore_region_move(d, forward)
			"spawn":
				_apply_spawn_position(d.after if forward else d.before)
			"cell_graph":
				_apply_cell_graph_state(d.after if forward else d.before)
			"layer_order":
				cvs._layer_ops_ctrl.apply_layer_move(d.before if forward else d.after, d.after if forward else d.before)
		return true
	await _restore(entry.snapshot if entry is Dictionary else entry)
	if forward and entry is Dictionary:
		cvs._region_ops_ctrl.stage_cloned_contents({"map_patch": cvs.extract(), "pending_contents": entry.clone_contents})
	return true


## 每格只记录一次初值，松手时生成撤销差量。
var _stroke_open := false
var _stroke_cells := {}

func stroke_begin() -> void:
	_stroke_open = true
	_stroke_cells.clear()
	redo_stack.clear()

func stroke_touch_tile(lid: String, c: Vector2i) -> void:
	var key := [lid, c]
	if _stroke_open and not _stroke_cells.has(key):
		_stroke_cells[key] = {"kind": "tile", "layer": lid,
			"cell": [c.x, c.y], "before": CanvasSnapshot.tile_row(cvs, lid, _tile_layer(lid), c)}

func stroke_touch_collision(c: Vector2i) -> void:
	if _stroke_open and not _stroke_cells.has(c):
		_stroke_cells[c] = {"kind": "collision", "layer": "",
			"cell": [c.x, c.y], "before": _collision_state(c)}

func stroke_end() -> void:
	if not _stroke_open:
		return
	_stroke_open = false
	var cells := _stroke_cells.values()
	for row: Dictionary in cells:
		var c := Vector2i(int(row.cell[0]), int(row.cell[1]))
		row["after"] = CanvasSnapshot.tile_row(cvs, row.layer, _tile_layer(row.layer), c) if row.kind == "tile" \
			else _collision_state(c)
	if not cells.is_empty():
		_push_entry({"kind": "delta", "cells": cells})
	_stroke_cells.clear()

## 实例差量按实例码寻址；无实例码的摆放物由调用方改存整图。

## 改动前的实例行快照。ok=false = 有目标没有实例码（场景图片），差量无从寻址。
## 只记录已有实例码的实体；序列化不分配身份。
func inst_rows(nodes: Array) -> Dictionary:
	var rows := {}
	for s in nodes:
		var n := s as EntityNode
		if not is_instance_valid(n) or not n.is_entity() or n.code.is_empty():
			return {"ok": false, "rows": {}}
		rows[n.code] = CanvasSnapshot.object_row(n)
	return {"ok": true, "rows": rows}

## 连续微调合并到同一撤销步，保留开始时的 before。
func inst_commit(before: Dictionary, merge := false, nudge := false) -> bool:
	var idx: Dictionary = cvs._ent_by_code_index()
	var ops: Array = []
	for k0 in before.keys():
		var k := str(k0)
		var b = before[k]
		var cur = idx.get(k, null)
		var ar: Variant = null
		if is_instance_valid(cur):
			ar = CanvasSnapshot.object_row(cur as EntityNode)
		if _rows_equal(b, ar):
			continue
		ops.append({"op": "del" if ar == null else "upd", "key": k, "before": b, "after": ar})
	if ops.is_empty():
		return false
	if merge and redo_stack.is_empty() and not undo_stack.is_empty():
		var top = undo_stack[-1]
		if top is Dictionary and top.get("kind") == "ents" and top.get("nudge", false) == nudge \
				and top.ops.all(func(op): return op.op == "upd") and ops.all(func(op): return op.op == "upd") \
				and _same_keys(top.ops, ops):
			# 合并：before 保留窗口起点那份（栈顶记录的），after 换成最新状态
			var prior := {}
			for o in (top as Dictionary).get("ops", []):
				prior[str((o as Dictionary).get("key", ""))] = (o as Dictionary).get("before", null)
			for o2 in ops:
				var k2 := str((o2 as Dictionary).get("key", ""))
				if prior.has(k2):
					(o2 as Dictionary)["before"] = prior[k2]
			(top as Dictionary)["ops"] = ops
			return true
	_push_entry({"kind": "ents", "ops": ops, "nudge": nudge})
	return true

func record_instance_removal(rows: Dictionary, order: Dictionary) -> void:
	var ops := []
	for code in rows:
		ops.append({"op": "del", "key": code, "before": rows[code], "after": null, "index": order[code]})
	_push_entry({"kind": "ents", "ops": ops})

## 两组 ops 是否操作同一批实例码（合并窗口用）。
func _same_keys(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	var ka := {}
	for o in a:
		ka[str((o as Dictionary).get("key", ""))] = true
	for o2 in b:
		if not ka.has(str((o2 as Dictionary).get("key", ""))):
			return false
	return true

## 新增实例的差量：new_nodes 是已放到画布上的新节点（before 视为不存在）。
## 返回 false = 有节点没有实例码（场景图片），调用方应改用整图快照。
func inst_commit_add(new_nodes: Array, clone_contents := []) -> bool:
	var ops: Array = []
	for s in new_nodes:
		var n := s as EntityNode
		if not is_instance_valid(n) or not n.is_entity() or n.code.is_empty():
			return false
		ops.append({"op": "add", "key": n.code, "before": null, "after": CanvasSnapshot.object_row(n)})
	if not ops.is_empty():
		var entry := {"kind": "ents", "ops": ops}
		if not clone_contents.is_empty():
			entry["clone_contents"] = clone_contents
		_push_entry(entry)
	return true

## 行相等判定：null 与 null 相等；其余按规范化 JSON 比（键序无关由 Dictionary 深比保证）。
func _rows_equal(a, b) -> bool:
	if a == null or b == null:
		return a == null and b == null
	return JSON.stringify(a) == JSON.stringify(b)

## 恢复实例差量：逐个 key 重建/改写/删除，只碰这几条，然后只标一次脏。
func _restore_ents(entry: Dictionary, forward: bool) -> void:
	var idx: Dictionary = cvs._ent_by_code_index()
	var inserted := []
	for o0 in (entry.get("ops", []) as Array):
		var o: Dictionary = o0
		var key := str(o.get("key", ""))
		if key == "":
			continue
		var want = o.get("after" if forward else "before", null)
		var cur = idx.get(key, null)
		if not (cur is EntityNode) or not is_instance_valid(cur):
			cur = null
		if want == null:
			if cur != null:
				var cn := cur as EntityNode
				if cvs.selected_entity == cn:
					cvs.selected_entity = null
				cvs.selected_multi.erase(cn)
				(cn.get_parent() as Node2D).remove_child(cn)
				cn.free()
			continue
		if cur != null:
			_apply_row_to_node(cur as EntityNode, want as Dictionary)
		else:
			var node := CanvasSnapshot.place_object(cvs, want as Dictionary)
			if not forward and o.has("index"):
				inserted.append([node, o.index])
	inserted.sort_custom(func(a, b): return a[1] < b[1])
	for item in inserted:
		item[0].get_parent().move_child(item[0], item[1])
	if forward and entry.has("clone_contents"):
		var rows: Array = entry.ops.map(func(op): return op.after)
		cvs._region_ops_ctrl.stage_cloned_contents({"map_patch": {"objects": rows}, "pending_contents": entry.clone_contents})
	cvs.selected_multi = cvs.selected_multi.filter(func(x): return is_instance_valid(x))
	cvs.commit_selection(cvs.selected_entity if is_instance_valid(cvs.selected_entity) else null,
		cvs.selected_multi)
	cvs._mark_ents()   # 阶段三：只动实例，瓦片/碰撞镜像一律不碰

## 行 → 已在场的节点（撤销「改」时原地改写，保住节点身份与选中）。
## 层或 z 分组变了才重挂到新容器；否则不重排同层子节点顺序（非 ySort 层顺序即绘制顺序）。
func _apply_row_to_node(n: EntityNode, row: Dictionary) -> void:
	var old_lid := n.layer_id
	var old_zp := n.z_policy
	var ei := CanvasSnapshot.restore_placement(cvs, n, row)
	if n.layer_id != old_lid or n.z_policy != old_zp:
		cvs._place_in_layer(n, ei)

## 只撤销已落盘内容；文件摘要变化时拒绝覆盖。
func record_content(fn_id: String, cid: String, before: Dictionary, after: Dictionary,
		digest_before: String, digest_after: String) -> void:
	if fn_id == "" or cid == "" or digest_before == "":
		return
	if _rows_equal(before, after):
		return
	_push_entry({"kind": "content", "fn": fn_id, "cid": cid,
		"before": before.duplicate(true), "after": after.duplicate(true),
		"digest_before": digest_before, "digest_after": digest_after})

## 恢复内容差量：返回是否真的写回（摘要不符/文件缺失时拒绝，由 undo/redo 报「没有回滚」）。
func _restore_content(entry: Dictionary, forward: bool) -> bool:
	var fn_id := str(entry.get("fn", ""))
	var cid := str(entry.get("cid", ""))
	var want = entry.get("after" if forward else "before", null)
	if not (want is Dictionary) or fn_id == "" or cid == "":
		return false
	var path := ContentStore.path_for(cvs.manifest, fn_id, cid)
	if path == "" or not FileAccess.file_exists(path):
		return false
	# 期望的盘面摘要：undo 前盘上应是「改后」，redo 前应是「改前」
	var expect := str(entry.get("digest_after" if not forward else "digest_before", ""))
	if expect != "" and ContentStore.file_digest(path) != expect:
		return false
	if not ContentStore.write(cvs.manifest, fn_id, cid, want as Dictionary, true):
		return false
	# 写回的是重新序列化后的文本：实际摘要可能与记录时的原文摘要不同（手写 JSON 缩进/键序）。
	# 回填实际摘要，下一次反向恢复才对得上，不会把手写文件误判成「外部改过」。
	var wrote := ContentStore.file_digest(path)
	if wrote != "":
		if forward:
			entry["digest_after"] = wrote
		else:
			entry["digest_before"] = wrote
	_refresh_content_ui(fn_id, cid)
	return true

## 内容写回后同步界面（表单在开着同一份内容时，控件要显示回滚后的值）。
func _refresh_content_ui(fn_id: String, cid: String) -> void:
	var app = cvs.app_host
	if app == null or app.project_shell == null:
		return
	var ce = app.project_shell.content_editor
	if ce == null:
		return
	ce.refresh_after_external_write(fn_id, cid)

## Content panels can undo/redo without touching unrelated map entries.
func undo_content_only(forward := false, fn_id := "", cid := "") -> String:
	if cvs.doc_busy or _restoring:
		return "not_content"
	var from := redo_stack if forward else undo_stack
	var to := undo_stack if forward else redo_stack
	for i in range(from.size() - 1, -1, -1):
		var entry = from[i]
		if not entry is Dictionary or entry.get("kind") != "content":
			continue
		if fn_id != "" and (entry.fn != fn_id or entry.cid != cid):
			continue
		_restoring = true
		var ok := _restore_content(entry, forward)
		_restoring = false
		if not ok:
			return "refused"
		from.remove_at(i)
		to.append(entry)
		return "done"
	return "not_content"

## undo/redo 恢复差量条目：逐格写回 before/after（资产缺失的源按空格恢复）。
func _restore_delta(entry: Dictionary, forward: bool) -> void:
	var field := "after" if forward else "before"
	var touched_layers := {}
	var touched_coll := false
	for s in (entry.get("cells", []) as Array):
		var st: Dictionary = s
		var c := Vector2i(int((st.get("cell", [0, 0]) as Array)[0]), int((st.get("cell", [0, 0]) as Array)[1]))
		var v = st.get(field, null)
		if str(st.get("kind", "")) == "tile":
			var lid := str(st.get("layer", ""))
			if not touched_layers.has(lid):
				touched_layers[lid] = cvs._layer_index_of(lid)
			var li: int = touched_layers[lid]
			if li < 0:
				continue
			var tn: TileMapLayer = cvs.layer_tiles[li]
			if v == null:
				cvs.erase_tile(lid, tn, c)
			else:
				cvs.write_tile_row(lid, tn, v)
		else:
			touched_coll = true
			if v == null:
				cvs.set_collision_cell(c, false)
			else:
				var vd: Dictionary = v
				# raw 精确覆写：恢复态的 raw 可能为空，不能沿用当前格上的旧 raw（P0-7 新签名）
				var raw: Dictionary = vd.get("raw", {}) if vd.get("raw", null) is Dictionary else {}
				cvs.set_collision_cell(c, true, str(vd.get("type", "solid")), str(vd.get("shape", "")), raw)
	# 仅失效被改动的绘制层。
	for li in touched_layers.values():
		if li >= 0:
			cvs._mark_tiles_layer(li)
	if touched_coll:
		cvs._mark_collision()
	cvs.queue_redraw()

func commit_region_move(entry: Dictionary, uncoded_positions: Dictionary) -> void:
	if not uncoded_positions.is_empty():
		push_undo()
	for n in uncoded_positions:
		n.position = uncoded_positions[n]
	_restore_region_move(entry, true, not uncoded_positions.is_empty())
	if uncoded_positions.is_empty():
		_push_entry(entry)

func commit_spawn_position(before: Vector2, after: Vector2) -> bool:
	if before == after:
		return false
	_push_entry({"kind": "spawn", "before": before, "after": after})
	_apply_spawn_position(after)
	return true

func commit_cell_graph(graph: Dictionary) -> void:
	var meta: Dictionary = cvs.map_data.meta
	if meta.get("cellGraph") == graph:
		return
	var before := {"value": meta.cellGraph} if meta.has("cellGraph") else {}
	before = before.duplicate(true)
	var after := {"value": graph.duplicate(true)}
	_push_entry({"kind": "cell_graph", "before": before, "after": after})
	_apply_cell_graph_state(after)

func _apply_cell_graph_state(state: Dictionary) -> void:
	if state.is_empty():
		cvs.map_data.meta.erase("cellGraph")
	else:
		cvs.map_data.meta["cellGraph"] = state.duplicate(true).value
	cvs._mark_map()
	cvs.queue_redraw()

func _apply_spawn_position(position: Vector2) -> void:
	cvs.spawn.position = position
	cvs._mark_map()
	cvs.queue_redraw()

func _restore_region_move(entry: Dictionary, forward: bool, uncoded_changed := false) -> void:
	var field := "after" if forward else "before"
	var objects: Dictionary = entry.objects
	var props: Dictionary = entry.get("props", {})
	if not objects.is_empty() or not props.is_empty():
		var index: Dictionary = cvs._ent_by_code_index()
		for code in objects:
			var node: EntityNode = index[code]
			node.position = objects[code][field]
		for code in props:
			index[code].props = props[code][field].duplicate(true)
	var graph_rows: Dictionary = entry.graph_rows
	if not graph_rows.is_empty():
		var rows: Array = cvs.cell_graph().cells
		for i in graph_rows:
			rows[i] = graph_rows[i][field].duplicate(true)
	if entry.has("spawn"):
		cvs.spawn.position = entry.spawn[field]
	_restore_delta(entry, forward)
	if not objects.is_empty() or not props.is_empty() or uncoded_changed:
		cvs._mark_ents()
	elif not graph_rows.is_empty() or entry.has("spawn"):
		cvs._mark_map()

func region_cell_changes(lid: String, layer: TileMapLayer, changes: Dictionary) -> Array:
	var cells := []
	var collision: bool = layer == cvs.collision
	for c: Vector2i in changes:
		var before = _collision_state(c) if collision else CanvasSnapshot.tile_row(cvs, lid, layer, c)
		var after = changes[c]
		if before != after:
			cells.append({"kind": "collision" if collision else "tile", "layer": lid,
				"cell": [c.x, c.y], "before": before, "after": after})
	return cells

## Automatic generation and undo use the same cell writer. Compare complete
## states so replace can clear old shapes and metadata without recording no-ops.
func apply_collision_batch(changes: Dictionary) -> void:
	var cells := []
	for c: Vector2i in changes:
		var before = _collision_state(c)
		var after = changes[c]
		if before != after:
			cells.append({"kind": "collision", "cell": [c.x, c.y], "before": before, "after": after})
	_apply_cell_batch(cells)

func apply_tile_batch(rows_by_layer: Dictionary) -> void:
	var cells := []
	for lid: String in rows_by_layer:
		var layer := _tile_layer(lid)
		for row: Array in rows_by_layer[lid]:
			var c := Vector2i(int(row[0]), int(row[1]))
			var before = CanvasSnapshot.tile_row(cvs, lid, layer, c)
			if before != row:
				cells.append({"kind": "tile", "layer": lid, "cell": [c.x, c.y], "before": before, "after": row})
	_apply_cell_batch(cells)

func _apply_cell_batch(cells: Array) -> void:
	if cells.is_empty():
		return
	var entry := {"kind": "delta", "cells": cells}
	_restore_delta(entry, true)
	_push_entry(entry)

## —— 差量状态捕获辅助 ——
## 层码 → TileMapLayer（层没了返回 null：差量恢复对丢失层跳过，不炸）。
func _tile_layer(lid: String) -> TileMapLayer:
	var li: int = cvs._layer_index_of(lid)
	if li < 0:
		return null
	return cvs.layer_tiles[li] as TileMapLayer

## 碰撞格当前状态：无 = null；有 = {type, shape, raw}。
func _collision_state(c: Vector2i):
	var cm = cvs._collision_meta.get(c, null)
	if cvs.collision.get_cell_source_id(c) == -1:
		return null
	if cm == null:
		return {"type": "solid", "shape": "", "raw": {}}
	return {"type": str(cm.get("type", "solid")), "shape": str(cm.get("shape", "")),
		"raw": (cm as Dictionary).get("raw", {}) as Dictionary}
