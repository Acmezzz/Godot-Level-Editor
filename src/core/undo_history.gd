extends RefCounted
## _undo_history_ctrl：从 src/canvas/editor_canvas.gd 拆出的控制器。宿主状态经 cvs 引用。

var cvs   # 宿主引用

const Constants := preload("res://src/core/constants.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const MapFormat := preload("res://src/map/map_format.gd")
const TilesetCache := preload("res://src/canvas/tileset_cache.gd")

func _init(host) -> void:
	cvs = host

## —— 撤销/重做栈（§7.5 阶段一：栈归本控制器所有，画布不再持有可写字段）——
## 差量条目和整图快照共用 80 步上限。
const UNDO_MAX := 80
var undo_stack: Array = []
var redo_stack: Array = []

## 清空历史（换图/载图/草稿恢复时调用）：旧图的条目不能留到新图上。
func clear_history() -> void:
	undo_stack.clear()
	redo_stack.clear()

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


## 整图快照入栈：全局操作（区域粘贴/层/尺寸/转换）与
## 无实例码的场景图片改动走这条。写入口在控制器上，画布只做转发不带状态。
func push_undo() -> void:
	if cvs.map_root == null or not is_instance_valid(cvs.map_root):
		return
	var snap := _snapshot()
	if snap == "{}":
		return   # 重建窗口哨兵（extract 返回 {}）：恢复它=清空整图，拒绝入栈
	_push_entry_str(snap)

## 差量条目入栈（H01/§7.5 阶段二共用）：新操作一律清空 redo。
func _push_entry(entry: Dictionary) -> void:
	undo_stack.append(entry)
	if undo_stack.size() > UNDO_MAX:
		undo_stack.pop_front()
	redo_stack.clear()

func _push_entry_str(snap: String) -> void:
	undo_stack.append(snap)
	if undo_stack.size() > UNDO_MAX:
		undo_stack.pop_front()
	redo_stack.clear()

## 恢复是异步的（await load_data 让帧）。恢复进行中再触发 undo/redo，两个恢复流
## 会交错写状态：快照弹错、画布被双重覆盖。恢复期一律拒绝（返回 false）。
var _restoring := false

## 最近一次 undo/redo 因「内容文件被外部改过」而拒绝（UI 据此给准确提示，而不是「没有可撤销的操作」）。
var refused_external := false

## 返回是否真的撤销了（空栈时调用方要给「没有可撤销的操作」而不是假反馈）。
## 脏标记与 modified.emit 由 load_data(keep_dirty=true) 统一处理，不再自己置脏。
## 文档保存/切图期间（doc_busy）一律拒绝：写盘中途恢复快照会让落盘内容与画布不一致。
func undo() -> bool:
	refused_external = false
	if cvs.doc_busy or _restoring or cvs.map_root == null or not is_instance_valid(cvs.map_root) or undo_stack.is_empty():
		return false
	if _stroke_open:
		stroke_end()   # 笔画进行中撤销：先把已涂格定格成差量条目，再由下面的 undo 一并回滚
	# 手势中途撤销（拖实例时按 Ctrl+Z）：先把预览值归位，否则差量写回后松手会把预览值再写上去
	cvs.cancel_preview_gesture()
	_restoring = true
	var entry = undo_stack.pop_back()
	# 整图快照只记「过去」，对向栈要存当前状态；差量条目自带双向数据，原样压回
	var mirror = entry if _is_patch(entry) else _snapshot()
	var ok := await _apply_entry(entry, false)
	if not ok:
		# 内容被外部改过：条目退回原栈，栈序不变，别给假反馈
		undo_stack.append(entry)
		refused_external = true
	else:
		redo_stack.append(mirror)
	_restoring = false
	return ok


func redo() -> bool:
	refused_external = false
	if cvs.doc_busy or _restoring or cvs.map_root == null or not is_instance_valid(cvs.map_root) or redo_stack.is_empty():
		return false
	_restoring = true
	var entry = redo_stack.pop_back()
	var mirror = entry if _is_patch(entry) else _snapshot()
	var ok := await _apply_entry(entry, true)
	if not ok:
		redo_stack.append(entry)
		refused_external = true
	else:
		undo_stack.append(mirror)
	_restoring = false
	return ok


## 差量条目（自带 before/after，可双向复用）与整图快照（只有一侧）的判别。
func _is_patch(entry) -> bool:
	if not (entry is Dictionary):
		return false
	return str((entry as Dictionary).get("kind", "")) in ["delta", "ents", "content", "region_move"]


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
		return true
	await _restore(entry)
	return true


## —— H01：笔画差量记录器 ——
## 涂刷/擦除笔画不再压整图快照：首个真实改动前 stroke_begin()，改动逐格
## stroke_touch_*（只记 before），手势结束 stroke_end() 定格 before/after 成差量条目。
## 条目 = {"kind": "delta", "cells": [{kind, layer, cell:[x,y], before, after}]}，
## undo 应用 before、redo 应用 after（同一条目双向复用）。区域、尺寸、层操作仍可用整图快照。

var _stroke_open := false
var _stroke_cells: Array = []   # 进行中的笔画 [{kind, layer, cell, before}]
## 查重任一：原先每格线性扫 _stroke_cells（整笔 O(N²)）。键 → 已登记，顺序仍按 _stroke_cells。
var _stroke_keys := {}

## 笔画开始（tool_ops._ensure_stroke_undo 调用）：清 redo，开始记录。
func stroke_begin() -> void:
	_stroke_open = true
	_stroke_cells = []
	_stroke_keys.clear()
	redo_stack.clear()

## 笔画取消（撤销在笔画进行中触发时）：记录作废，不产生撤销条目。
func stroke_cancel() -> void:
	_stroke_open = false
	_stroke_cells = []
	_stroke_keys.clear()

## 登记一个瓦片格的 before 状态（同格重复登记跳过）。
func stroke_touch_tile(lid: String, c: Vector2i) -> void:
	if not _stroke_open:
		return
	var key := "t|%s|%d,%d" % [lid, c.x, c.y]
	if _stroke_keys.has(key):
		return
	_stroke_keys[key] = true
	var tn := _tile_layer(lid)
	var before = _tile_state(lid, tn, c)
	_stroke_cells.append({"key": key, "kind": "tile", "layer": lid,
		"cell": [c.x, c.y], "before": before})

## 登记一个碰撞格的 before 状态（同格重复登记跳过）。
func stroke_touch_collision(c: Vector2i) -> void:
	if not _stroke_open:
		return
	var key := "c|%d,%d" % [c.x, c.y]
	if _stroke_keys.has(key):
		return
	_stroke_keys[key] = true
	_stroke_cells.append({"key": key, "kind": "collision", "layer": "",
		"cell": [c.x, c.y], "before": _collision_state(c)})

## 手势结束（editor_canvas.end_gesture 调用）：捕获 after 并把差量条目压入撤销栈。
## 空笔画（无真实改动）不产生条目。
func stroke_end() -> void:
	if not _stroke_open:
		return
	_stroke_open = false
	for s in _stroke_cells:
		var c := Vector2i(int((s as Dictionary).cell[0]), int((s as Dictionary).cell[1]))
		if str((s as Dictionary).get("kind", "")) == "tile":
			var lid := str((s as Dictionary).get("layer", ""))
			(s as Dictionary)["after"] = _tile_state(lid, _tile_layer(lid), c)
		else:
			(s as Dictionary)["after"] = _collision_state(c)
	if not _stroke_cells.is_empty():
		_push_entry({"kind": "delta", "cells": _stroke_cells})
	_stroke_cells = []

## —— §7.5 阶段二：实例差量（InstanceKey = 本图实例码 / ContentKey = 功能 id + 内容 id）——
## 实例增删改不再压整图快照：改动前 inst_rows() 取 before 行，改动后 inst_commit()
## 比对现状产出 {"kind":"ents","ops":[{op, key, before, after}]}，undo 应用 before、
## redo 应用 after，只重建/删除涉及的实例，其它数据一个字节都不写。
## 无实例码的目标（场景图片）没有键可用——调用方按 inst_rows 的 ok=false 回退整图快照。

## 改动前的实例行快照。ok=false = 有目标没有实例码（场景图片），差量无从寻址。
## 键从**行里**取（_object_row 会给缺码实体补发码），不能用登记前的 n.code。
func inst_rows(nodes: Array) -> Dictionary:
	var rows := {}
	for s in nodes:
		var n := s as EntityNode
		if n == null or not is_instance_valid(n):
			return {"ok": false, "rows": {}}
		var r := _object_row(n)
		var key := str(r.get("code", ""))
		if key == "":
			return {"ok": false, "rows": {}}   # 场景图片永不产码：差量不可寻址
		rows[key] = r
	return {"ok": true, "rows": rows}

## 收尾一次实例改动：比对 before 与本图现状，把差异压成差量条目。
## merge=true 用于连续同类改动（方向键 1 秒窗口）：栈顶已是同键集合的 entries 条目时，
## 只把它的 after 换成最新状态，before 保持窗口起点——整段微调合成一个撤销步。
## 返回 false = 没有任何真实差异（零副作用，不入栈）。
func inst_commit(before: Dictionary, merge := false) -> bool:
	var idx: Dictionary = cvs._ent_by_code_index()
	var ops: Array = []
	for k0 in before.keys():
		var k := str(k0)
		var b = before[k]
		var cur = idx.get(k, null)
		var ar = null if cur == null or not is_instance_valid(cur) else _object_row(cur as EntityNode)
		if _rows_equal(b, ar):
			continue
		ops.append({"op": "del" if ar == null else "upd", "key": k, "before": b, "after": ar})
	if ops.is_empty():
		return false
	if merge and not undo_stack.is_empty():
		var top = undo_stack[-1]
		if top is Dictionary and str((top as Dictionary).get("kind", "")) == "ents" \
				and _same_keys((top as Dictionary).get("ops", []), ops):
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
	_push_entry({"kind": "ents", "ops": ops})
	return true

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
func inst_commit_add(new_nodes: Array) -> bool:
	var ops: Array = []
	for s in new_nodes:
		var n := s as EntityNode
		if n == null or not is_instance_valid(n):
			return false
		var r := _object_row(n)
		var key := str(r.get("code", ""))
		if key == "":
			return false
		ops.append({"op": "add", "key": key, "before": null, "after": r})
	if not ops.is_empty():
		_push_entry({"kind": "ents", "ops": ops})
	return true

## 行相等判定：null 与 null 相等；其余按规范化 JSON 比（键序无关由 Dictionary 深比保证）。
func _rows_equal(a, b) -> bool:
	if a == null or b == null:
		return a == null and b == null
	return JSON.stringify(a) == JSON.stringify(b)

## 恢复实例差量：逐个 key 重建/改写/删除，只碰这几条，然后只标一次脏。
func _restore_ents(entry: Dictionary, forward: bool) -> void:
	var idx: Dictionary = cvs._ent_by_code_index()
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
			_node_from_row(want as Dictionary)   # 行自带实例码；场景图片没有码也就不进差量
	cvs.selected_multi = cvs.selected_multi.filter(func(x): return is_instance_valid(x))
	cvs.commit_selection(cvs.selected_entity if is_instance_valid(cvs.selected_entity) else null,
		cvs.selected_multi)
	cvs._mark_ents()   # 阶段三：只动实例，瓦片/碰撞镜像一律不碰

## 行 → 已在场的节点（撤销「改」时原地改写，保住节点身份与选中）。
## 层或 z 分组变了才重挂到新容器；否则不重排同层子节点顺序（非 ySort 层顺序即绘制顺序）。
func _apply_row_to_node(n: EntityNode, row: Dictionary) -> void:
	var old_lid := n.layer_id
	var old_zp := n.z_policy
	n.asset = str(row.get("asset", n.asset))
	n.code = str(row.get("code", n.code))
	n.props = (row.get("props", {}) as Dictionary).duplicate(true) \
		if row.get("props", null) is Dictionary else {}
	n.functions = (row.get("functions", []) as Array).duplicate(true) \
		if row.get("functions", null) is Array else []
	n.data_transform = (row.get("transform", {}) as Dictionary).duplicate(true) \
		if row.get("transform", null) is Dictionary else {}
	n.raw = row.duplicate(true)
	n.z_policy = str(row.get("zPolicy", "auto"))
	n.visible_flag = bool(row.get("visible", true))
	var ei: int = cvs._layer_index_of(str(row.get("layer", old_lid)))
	if ei < 0:
		ei = 0
	n.layer_id = cvs.layer_id(ei)
	n.refresh_visual()   # props 就位后按 sizeFields 重算尺寸
	n.apply_grid(float(row.get("x", 0)), float(row.get("y", 0)))
	if n.layer_id != old_lid or n.z_policy != old_zp:
		cvs._place_in_layer(n, ei)

## —— 内容字段差量（ContentKey）——
## 内容文件本来不进地图快照；这里只回滚「这一次编辑动过的整份内容」，
## 且盘上摘要与记录不符（被外部改过）就拒绝——不拿记忆里的旧值覆盖别人的工作。
## 只对已落盘内容记账；staged 新内容还没有盘面状态，撤销等于放弃暂存，不记差量。
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

## 内容视图的 Ctrl+Z：只撤栈顶的内容差量，地图改动一条都不碰。
## 返回 "done" / "not_content" / "refused"（盘面被外部改过 → 拒绝回滚，条目退回原栈）。
func undo_content_only() -> String:
	if cvs.doc_busy or _restoring or undo_stack.is_empty():
		return "not_content"
	var top = undo_stack[-1]
	if not (top is Dictionary) or str((top as Dictionary).get("kind", "")) != "content":
		return "not_content"
	_restoring = true
	undo_stack.pop_back()
	redo_stack.append(top)
	var ok := _restore_content(top, false)
	_restoring = false
	if not ok:
		redo_stack.pop_back()   # 没撤成：条目回到原位，别给假反馈
		undo_stack.append(top)
		return "refused"
	return "done"

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
	# 差量恢复不走 load_data 重建：P01 精细重画标记按改动种类逐项打（瓦片/碰撞）。
	# 阶段三：按层失效——只重画真正被改到的那些层（一笔只画一层是常态），
	# 窄入口更新各自的版本和视图，最后再重画画布。
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

func _restore_region_move(entry: Dictionary, forward: bool, uncoded_changed := false) -> void:
	var field := "after" if forward else "before"
	var objects: Dictionary = entry.objects
	if not objects.is_empty():
		var index: Dictionary = cvs._ent_by_code_index()
		for code in objects:
			var node: EntityNode = index[code]
			node.position = objects[code][field]
	var graph_rows: Dictionary = entry.graph_rows
	if not graph_rows.is_empty():
		var rows: Array = cvs.cell_graph().cells
		for i in graph_rows:
			rows[i] = graph_rows[i][field].duplicate(true)
	if entry.has("spawn"):
		cvs.spawn.position = entry.spawn[field]
	_restore_delta(entry, forward)
	if not objects.is_empty() or uncoded_changed:
		cvs._mark_ents()
	elif not graph_rows.is_empty() or entry.has("spawn"):
		cvs._mark_map()

func region_cell_changes(lid: String, layer: TileMapLayer, changes: Dictionary) -> Array:
	var cells := []
	var collision: bool = layer == cvs.collision
	for c: Vector2i in changes:
		var before = _collision_state(c) if collision else _tile_state(lid, layer, c)
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
			var before = _tile_state(lid, layer, c)
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

## 瓦片差量以磁盘行记录，未解析条目也能原样恢复。
func _tile_state(lid: String, tn: TileMapLayer, c: Vector2i):
	if tn == null or tn.get_cell_source_id(c) == -1:
		var row: Array = cvs.unresolved_tile(lid, c)
		return null if row.is_empty() else row.duplicate(true)
	var ac: Vector2i = tn.get_cell_atlas_coords(c)
	return [c.x, c.y, cvs.asset_of_source(tn.get_cell_source_id(c)), ac.x, ac.y,
		MapFormat.alt_of_godot(tn.get_cell_alternative_tile(c))]

## 碰撞格当前状态：无 = null；有 = {type, shape, raw}。
func _collision_state(c: Vector2i):
	var cm = cvs._collision_meta.get(c, null)
	if cvs.collision.get_cell_source_id(c) == -1:
		return null
	if cm == null:
		return {"type": "solid", "shape": "", "raw": {}}
	return {"type": str(cm.get("type", "solid")), "shape": str(cm.get("shape", "")),
		"raw": (cm as Dictionary).get("raw", {}) as Dictionary}


## 实例功能绑定：整段深拷贝写入 functions；实体缺省写空数组，让"清空绑定"也能落盘。
## 场景实例没有功能语义，非空才写（不产冗余键）。
func _functions_field(n: EntityNode) -> Dictionary:
	if not n.is_entity() and n.functions.is_empty():
		return {}
	return {"functions": n.functions.duplicate(true)}

## 单个实例 → 磁盘行（objects[] 条目）。extract() 与实例差量记录共用同一份口径：
## 以 n.raw 为底保留游戏侧自定义键，只覆盖编辑器管辖的键。
## 实例差量里 before/after 都用它生成，撤销时按行原样重建节点，不碰整图。
func _object_row(n: EntityNode) -> Dictionary:
	var clean := n.props.duplicate(true)
	# 实例码由载入和摆放入口维护，提取快照只读；
	# 场景实例永不产码（code 键整个不写）。
	# R15：声明解析不出（资产停用/清单漂移）的旧摆放物以原行往返——带着实例码就保留，
	# 不再被误当场景实例擦掉身份；只有「确认是非实体」的已知资产才擦码。
	var unknown_asset: bool = not (n.decl is Dictionary) or (n.decl as Dictionary).is_empty()
	var code := n.code
	# 以原条目为底：未知键（游戏侧自定义）与编辑器不认识的键都留在原处
	var row: Dictionary = n.raw.duplicate(true)
	row.erase("scene")   # 旧键作废：同一字段两种语义容易混
	row["asset"] = n.asset
	if n.is_entity() or (unknown_asset and code != ""):
		row["code"] = code
	else:
		row.erase("code")
	row["layer"] = n.layer_id
	# 浮点格坐标：关掉吸附时可存半格/任意像素位置；保留 3 位小数避免浮点噪声
	var g := n.grid_of_world(n.position)
	row["x"] = snappedf(g.x, 0.001)
	row["y"] = snappedf(g.y, 0.001)
	# transform 缺省整键省略（旧数据没有它就等于缺省形态，读回后行为不变）
	if n.data_transform.is_empty():
		row.erase("transform")
	else:
		row["transform"] = n.data_transform.duplicate(true)
	# 编辑器专用显示开关：缺省 true 不写冗余键
	if n.visible_flag:
		row.erase("visible")
	else:
		row["visible"] = false
	if n.z_policy != "auto" and n.z_policy != "":
		row["zPolicy"] = n.z_policy
	else:
		row.erase("zPolicy")
	row["props"] = clean
	row.merge(_functions_field(n), true)
	return row

## 行 → 活体节点（load_data 的 objects 装载与实例差量恢复共用）。
## C09 挂载补齐只在这里做一次：差量恢复的行已经是补齐后的形态，不会重复产键。
func _node_from_row(row: Dictionary) -> EntityNode:
	var n: EntityNode = cvs.make_object(str(row.get("asset", "")))
	n.code = str(row.get("code", ""))
	n.props = (row.get("props", {}) as Dictionary).duplicate(true) \
		if row.get("props", null) is Dictionary else {}
	n.functions = (row.get("functions", []) as Array).duplicate(true) \
		if row.get("functions", null) is Array else []
	n.data_transform = (row.get("transform", {}) as Dictionary).duplicate(true) \
		if row.get("transform", null) is Dictionary else {}
	n.raw = row.duplicate(true)
	n.z_policy = str(row.get("zPolicy", "auto"))
	n.visible_flag = bool(row.get("visible", true))
	var ei: int = cvs._layer_index_of(str(row.get("layer", "")))
	if ei < 0:
		ei = 0
	n.layer_id = cvs.layer_id(ei)
	n.refresh_visual()   # props 就位后再算一次尺寸（sizeFields 资产按 props 定大小）
	n.apply_grid(float(row.get("x", 0)), float(row.get("y", 0)))
	cvs._place_in_layer(n, ei)
	cvs._ensure_code(n)
	return n

func extract() -> Dictionary:
	if cvs.map_root == null or not is_instance_valid(cvs.map_root):
		return {}   # 重建窗口期（load_data 的 await 一帧）：不产出快照，防 free 后访问
	# 层栈瓦片：tiles = {层id: [[x,y,资产id,ax,ay,alt]...]}（第 3 位资产 id 字符串，
	# 第 6 位 alt = 变换位 0-7，互转见 map_format.gd；清单重排不会破坏既有地图）
	var tiles := {}
	for li in cvs.layer_tiles.size():
		var tn: TileMapLayer = cvs.layer_tiles[li]
		var lid: String = cvs.layer_id(li)
		if lid == "":
			continue
		var cells := []
		var seen_cells := {}
		for c in tn.get_used_cells():
			var row = _tile_state(lid, tn, c)
			if row == null or str(row[2]) == "":
				continue
			cells.append(row)
			seen_cells[c] = true
		# 装载时资产缺失/图集读不到的瓦片原样带回（D02：缺素材不删已存记录）；
		# 该格已被玩家重新涂过则丢弃旧记录（当前位置的新值优先）。
		var kept: Dictionary = cvs._unresolved_tiles.get(lid, {})
		for cell in kept:
			if not seen_cells.has(cell):
				cells.append(kept[cell].duplicate(true))
		tiles[lid] = cells
	# 碰撞条目对象（v6）：{x, y}，type 缺省省略（solid）、shape 缺省省略（矩形）。
	var ccells := []
	for c in cvs.collision.get_used_cells():
		var cm = cvs._collision_meta.get(c, null)
		var d := {"x": c.x, "y": c.y}
		if cm != null:
			# R21：磁盘碰撞行的未知键（游戏侧自定义）在画布层挂在 raw 上，重建时打底带回。
			if (cm as Dictionary).get("raw", null) is Dictionary:
				d.merge((cm as Dictionary)["raw"], true)
			var ct := str(cm.get("type", "solid"))
			var cs := str(cm.get("shape", ""))
			if ct != "" and ct != "solid":
				d["type"] = ct
			if cs != "":
				d["shape"] = cs
		ccells.append(d)
	# 摆放物：以加载时保存的原条目为底（保留游戏侧自定义键），只覆盖编辑器管辖的键。
	# 白名单重建会让未知键在保存时蒸发——这是最早发现、影响最大的一处丢数据。
	var olist := []
	for e in cvs.ents_all():
		var n := e as EntityNode
		if n == null or n.asset == "":
			continue
		olist.append(_object_row(n))
	var used = Rect2i()
	for tn in cvs.layer_tiles:
		used = used.merge((tn as TileMapLayer).get_used_rect())
	if used.size == Vector2i.ZERO:
		used = Rect2i(Vector2i.ZERO, Vector2i(Constants.DEFAULT_MAP_W, Constants.DEFAULT_MAP_H))
	# 以整个读入的地图为底：游戏侧写进顶层的自定义键原样保留（此前 6 键白名单会蒸发它们）
	var out: Dictionary = cvs.map_data.duplicate() if cvs.map_data is Dictionary else {}
	for rebuilt in ["tiles", "collision", "objects", "entities", "spawn"]:
		out.erase(rebuilt)
	out = out.duplicate(true)
	# 以当前地图 meta 为底（保留游戏侧自定义键），只覆盖编辑器管辖的 name/w/h
	var meta: Dictionary = out.get("meta", {}) if out.get("meta", {}) is Dictionary else {}
	if not meta.has("w"):
		meta["w"] = int(used.end.x + 2)
	if not meta.has("h"):
		meta["h"] = int(used.end.y + 2)
	meta["name"] = cvs.cur_map_name
	# 出生点数据是根空间格号（不随活动层变）：直接由 spawn.position 反算，
	# 不能走 _cell_of——活动层有 offset/scale 时会把出生点写成别的格（E02）。
	var sp: Vector2i = cvs.grid.pick_cell(cvs.spawn.position)
	out["version"] = MapFormat.VERSION
	out["meta"] = meta
	out["spawn"] = [sp.x, sp.y]
	out["tiles"] = tiles
	out["collision"] = ccells
	out.erase("entities")   # v5：entities 段已并入 objects[]
	out["objects"] = olist
	return out
