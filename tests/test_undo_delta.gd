extends "res://tests/_suite_base.gd"
## §7.5 阶段二：撤销差量（InstanceKey / ContentKey）。不起画布节点——用最小宿主桩喂
## undo_history.gd 的真实入口，验证「条目形态」「只写受影响数据」「合并窗口」三件事。

const UndoHistory := preload("res://src/core/undo_history.gd")
const ContentStore := preload("res://src/content/content_store.gd")

const TMP := "user://test_undo_delta_tmp"

## 最小宿主桩：undo_history 只读这几处宿主状态（撤销栈归控制器自己所有）。
class Host extends Node2D:
	var map_root: Node2D
	var doc_busy := false
	var manifest := {}
	var selected_entity = null
	var selected_multi: Array = []
	var app_host = null
	var marks := 0
	## 阶段三分项计数：撤销/恢复只该打真正动过的镜像
	var mark_full := 0
	var mark_ents := 0
	var mark_tiles := 0
	var mark_tiles_layer: Array = []
	var mark_coll := 0
	var layer_ents: Array = []
	var layer_tiles: Array = []   # 阶段三：按层失效测试用（一个空 TileMapLayer 足够）
	var layer_ids: Array = ["L1", "L2"]   # 层码 → 下标（真实宿主按 meta.layers 声明序）
	var collision: TileMapLayer = null
	var _collision_meta := {}
	var asset_of_source_calls := 0

	func erase_tile(_lid: String, layer: TileMapLayer, cell: Vector2i) -> void:
		layer.erase_cell(cell)

	func asset_of_source(_sid: int) -> String:
		asset_of_source_calls += 1
		return "tile_a"

	func set_collision_cell(c: Vector2i, on: bool, type := "solid", shape := "") -> void:
		if on:
			_collision_meta[c] = {"type": type, "shape": shape}
		else:
			_collision_meta.erase(c)

	func _ent_by_code_index() -> Dictionary:
		var out := {}
		for e in ents_all():
			var n := e as EntityNode
			if n != null and n.code != "":
				out[n.code] = n
		return out

	func ents_all() -> Array:
		var out: Array = []
		for r in layer_ents:
			for c in (r as Node).get_children():
				if c is EntityNode:
					out.append(c)
		return out

	func commit_selection(n, multi: Array = []) -> void:
		selected_entity = n
		selected_multi = multi

	func _mark(_ents_changed := true) -> void:
		marks += 1
		mark_full += 1

	# 阶段三窄入口：真实宿主按改动种类逐项失效；桩分开计数（断言「只打了哪些」）
	func _mark_ents() -> void:
		marks += 1
		mark_ents += 1

	func _mark_tiles() -> void:
		marks += 1
		mark_tiles += 1

	func _mark_tiles_layer(li: int) -> void:
		marks += 1
		mark_tiles_layer.append(li)

	func _mark_collision() -> void:
		marks += 1
		mark_coll += 1

	func layer_has_tiles(_li: int) -> bool:
		return false

	func cancel_preview_gesture() -> bool:
		return false

	func _layer_index_of(lid: String) -> int:
		var i := layer_ids.find(lid)
		return i if i >= 0 else 0

	func layer_id(_i: int) -> String:
		return "L1"

	func _place_in_layer(n: EntityNode, _li: int) -> void:
		n.layer_id = "L1"
		if n.get_parent() == null:
			layer_ents[0].add_child(n)

	func make_object(_aid: String) -> EntityNode:
		var n := EntityNode.new()
		n.decl = {"kind": "entity"}
		return n

	func extract() -> Dictionary:
		return {}


func _wipe() -> void:
	_nuke(TMP)


func _nuke(p: String) -> void:
	if not DirAccess.dir_exists_absolute(p):
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
		return
	for f in DirAccess.get_files_at(p):
		DirAccess.remove_absolute(p.path_join(str(f)))
	for d in DirAccess.get_directories_at(p):
		_nuke(p.path_join(str(d)))
	DirAccess.remove_absolute(p)


func _host() -> Dictionary:
	var h := Host.new()
	h.map_root = Node2D.new()
	var layer := Node2D.new()
	h.layer_ents = [layer]
	h.add_child(h.map_root)
	h.add_child(layer)
	return {"host": h, "undo": UndoHistory.new(h), "layer": layer}


func _ent(h: Host, code: String, x := 0.0, y := 0.0) -> EntityNode:
	var n := EntityNode.new()
	n.decl = {"kind": "entity"}
	n.code = code
	n.layer_id = "L1"
	n.position = Vector2(x, y)
	n.refresh_visual()
	(h.layer_ents[0] as Node).add_child(n)
	return n


## 实例新增：条目是 ents 差量（不是整图快照），undo 删掉它、redo 放回来。
func test_instance_add_is_delta() -> void:
	var ctx := _host()
	var h: Host = ctx.host
	var uh = ctx.undo
	var a := _ent(h, "AAA1", 16, 16)
	ok(uh.inst_commit_add([a]), "新增实体可记差量")
	eq(uh.undo_stack.size(), 1, "入栈一条")
	var e: Dictionary = uh.undo_stack[0]
	eq(str(e.get("kind", "")), "ents", "条目是实例差量而不是整图快照")
	eq((e.get("ops", []) as Array).size(), 1, "只记这一条")
	eq(str(((e.get("ops", []) as Array)[0] as Dictionary).get("op", "")), "add", "op=add")
	uh._restore_ents(e, false)
	eq(h.ents_all().size(), 0, "撤销后实例消失")
	uh._restore_ents(e, true)
	eq(h.ents_all().size(), 1, "重做后实例回来")
	eq((h.ents_all()[0] as EntityNode).code, "AAA1", "实例码保真（InstanceKey 不变）")
	h.free()


## 单实例改值：只写这一条，图里其它实例一个字段都不动。
func test_instance_edit_touches_only_target() -> void:
	var ctx := _host()
	var h: Host = ctx.host
	var uh = ctx.undo
	var a := _ent(h, "AAA1", 16, 16)
	var b := _ent(h, "BBB2", 48, 16)
	b.props = {"hp": 7}
	var pre: Dictionary = uh.inst_rows([a])
	a.position = Vector2(64, 64)
	uh.inst_commit(pre.get("rows", {}))
	eq(uh.undo_stack.size(), 1, "入栈一条")
	var e: Dictionary = uh.undo_stack[0]
	eq(((e.get("ops", []) as Array)[0] as Dictionary).get("op", ""), "upd", "op=upd")
	# 记 b 的身份与 props 引用，撤销后必须原样（没被重建/覆盖）
	var b_before := b.code
	uh._restore_ents(e, false)
	eq(a.position, Vector2(16, 16), "撤销回原位")
	var b_after = null
	for n in h.ents_all():
		if (n as EntityNode).code == "BBB2":
			b_after = n
	ok(b_after != null, "另一个实例还在")
	eq((b_after as EntityNode).props.get("hp", 0), 7, "另一个实例的数据没被碰")
	eq(b_before, "BBB2", "另一个实例码没变")
	h.free()


## 删除：撤销后实例按差量行复活，位置/码都在。
func test_instance_delete_restores_row() -> void:
	var ctx := _host()
	var h: Host = ctx.host
	var uh = ctx.undo
	var a := _ent(h, "DEL1", 32, 48)
	a.props = {"k": "v"}
	var pre: Dictionary = uh.inst_rows([a])
	(h.layer_ents[0] as Node).remove_child(a)
	a.free()
	uh.inst_commit(pre.get("rows", {}))
	var e: Dictionary = uh.undo_stack[0]
	eq(str(((e.get("ops", []) as Array)[0] as Dictionary).get("op", "")), "del", "op=del")
	uh._restore_ents(e, false)
	eq(h.ents_all().size(), 1, "撤销后实例复活")
	var back := h.ents_all()[0] as EntityNode
	eq(back.code, "DEL1", "实例码保真")
	eq(back.props.get("k", ""), "v", "props 保真")
	h.free()


## 无实例码（场景图片）返回 ok=false，调用方据此回退整图快照。
func test_scene_image_falls_back() -> void:
	var ctx := _host()
	var h: Host = ctx.host
	var uh = ctx.undo
	var img := EntityNode.new()
	img.decl = {"kind": "scene", "shape": "image"}
	img.code = ""
	(h.layer_ents[0] as Node).add_child(img)
	eq(bool((uh.inst_rows([img]) as Dictionary).get("ok", true)), false, "无码目标判不可差量")
	eq(uh.inst_commit_add([img]), false, "新增无码目标返回 false")
	eq(uh.undo_stack.size(), 0, "不留空条目")
	h.free()


## 方向键合并窗口：同批实例码连续微调只留一条，before = 窗口起点。
func test_nudge_merges_into_one_entry() -> void:
	var ctx := _host()
	var h: Host = ctx.host
	var uh = ctx.undo
	var a := _ent(h, "NUD1", 0, 0)
	for i in 3:
		var pre: Dictionary = uh.inst_rows([a])
		a.position += Vector2(16, 0)
		uh.inst_commit(pre.get("rows", {}), i > 0)
	eq(uh.undo_stack.size(), 1, "三次微调合成一条")
	var e: Dictionary = uh.undo_stack[0]
	uh._restore_ents(e, false)
	eq(a.position, Vector2.ZERO, "撤销回到窗口起点（不是最后一次前）")
	h.free()


## 空改动不入栈：同位置再「提交」一次不该留下空步。
func test_no_change_no_entry() -> void:
	var ctx := _host()
	var h: Host = ctx.host
	var uh = ctx.undo
	var a := _ent(h, "NOP1", 16, 16)
	var pre: Dictionary = uh.inst_rows([a])
	eq(uh.inst_commit(pre.get("rows", {})), false, "零改动返回 false")
	eq(uh.undo_stack.size(), 0, "不入栈")
	h.free()


## 阶段三：撤销只失效真正动过的层——瓦片差量按层重画，不碰碰撞镜像、不碰实体索引。
func test_unresolved_tile_delta_restores_original_row() -> void:
	var canvas = preload("res://src/canvas/editor_canvas.gd").new()
	canvas._layer_ops_ctrl = preload("res://src/canvas/layer_ops.gd").new(canvas)
	canvas.map_data = {"meta": {"layers": [{"id": "L1", "name": "Layer"}]}}
	var layer := TileMapLayer.new()
	canvas.add_child(layer)
	canvas.layer_tiles = [layer]
	var undo := UndoHistory.new(canvas)
	var cell := Vector2i(1, 2)
	var row := [1, 2, "missing", 3, 4, 1]
	canvas.write_tile_row("L1", layer, row)
	undo.stroke_begin()
	undo.stroke_touch_tile("L1", cell)
	canvas.erase_tile("L1", layer, cell)
	undo.stroke_end()
	eq(canvas.unresolved_tile("L1", cell), [], "擦除清掉原始记录")
	undo._restore_delta(undo.undo_stack.back(), false)
	eq(canvas.unresolved_tile("L1", cell), row, "撤销恢复原始行")
	undo._restore_delta(undo.undo_stack.back(), true)
	eq(canvas.unresolved_tile("L1", cell), [], "重做再次擦除")
	canvas.free()

func test_restore_marks_only_touched_layer() -> void:
	var ctx := _host()
	var h: Host = ctx.host
	var uh = ctx.undo
	h.layer_tiles = [TileMapLayer.new(), TileMapLayer.new()]
	var e := {"kind": "delta", "cells": [
		{"key": "t|L2|1,1", "kind": "tile", "layer": "L2", "cell": [1, 1],
			"before": null, "after": null},
	]}
	uh._restore_delta(e, false)
	eq(h.mark_tiles_layer, [1], "只重画被改的第 2 层")
	eq(h.mark_tiles, 0, "不再走全层重建")
	eq(h.mark_coll, 0, "瓦片差量不碰碰撞红块")
	eq(h.mark_ents, 0, "瓦片差量不让实体索引失效")
	eq(h.mark_full, 0, "不再补一刀全量 _mark")
	# 碰撞差量：只刷红块
	var e2 := {"kind": "delta", "cells": [
		{"key": "c|2,2", "kind": "collision", "layer": "", "cell": [2, 2],
			"before": null, "after": null},
	]}
	uh._restore_delta(e2, false)
	eq(h.mark_coll, 1, "碰撞差量刷红块")
	eq(h.mark_tiles_layer, [1], "碰撞差量不重画瓦片层")
	for tl in h.layer_tiles:
		(tl as Node).free()
	h.free()


## 阶段三：实例差量撤销只置实体脏——瓦片/碰撞镜像一次都不重建。
func test_restore_ents_skips_tile_mirrors() -> void:
	var ctx := _host()
	var h: Host = ctx.host
	var uh = ctx.undo
	var a := _ent(h, "MK01", 8, 8)
	var pre: Dictionary = uh.inst_rows([a])
	a.position = Vector2(24, 24)
	uh.inst_commit(pre.get("rows", {}))
	uh._restore_ents(uh.undo_stack[0], false)
	eq(h.mark_ents, 1, "只打实体脏")
	eq(h.mark_tiles, 0, "瓦片自绘不重建")
	eq(h.mark_coll, 0, "碰撞红块不重建")
	eq(h.mark_full, 0, "没有全量 _mark")
	h.free()


## 内容差量：记改前/改后 + 两侧摘要，undo 只写那一个内容文件。
func test_content_delta_rolls_back_one_file() -> void:
	_wipe()
	var m := {"_dir": TMP, "contentDir": "content"}
	m["functions"] = [{"id": "f1", "name": "F", "code": "FC", "fields": []}]
	var before := {"id": "C1", "function": "FC", "name": "n", "fields": {"hp": 1}}
	ok(ContentStore.write(m, "f1", "C1", before, true), "初值写入")
	var dg_before := ContentStore.file_digest(ContentStore.path_for(m, "f1", "C1"))
	var after := before.duplicate(true)
	after["fields"] = {"hp": 9}
	ok(ContentStore.write(m, "f1", "C1", after, true), "改值写入")
	var dg_after := ContentStore.file_digest(ContentStore.path_for(m, "f1", "C1"))

	var ctx := _host()
	var h: Host = ctx.host
	h.manifest = m
	var uh = ctx.undo
	uh.record_content("f1", "C1", before, after, dg_before, dg_after)
	eq(uh.undo_stack.size(), 1, "内容改动入栈一条")
	eq(str((uh.undo_stack[0] as Dictionary).get("kind", "")), "content", "条目是内容差量")
	ok(uh._restore_content(uh.undo_stack[0], false), "撤销写回成功")
	eq(int(ContentStore.read(m, "f1", "C1").get("fields", {}).get("hp", 0)), 1, "字段回到旧值")
	ok(uh._restore_content(uh.undo_stack[0], true), "重做写回成功")
	eq(int(ContentStore.read(m, "f1", "C1").get("fields", {}).get("hp", 0)), 9, "字段回到新值")
	h.free()
	_wipe()


## 盘面被外部改过：拒绝回滚，不拿记忆里的旧值覆盖别人的工作。
func test_content_delta_refuses_on_external_edit() -> void:
	_wipe()
	var m := {"_dir": TMP, "contentDir": "content"}
	m["functions"] = [{"id": "f1", "name": "F", "code": "FC", "fields": []}]
	var before := {"id": "C1", "function": "FC", "name": "n", "fields": {"hp": 1}}
	ok(ContentStore.write(m, "f1", "C1", before, true), "初值写入")
	var dg_before := ContentStore.file_digest(ContentStore.path_for(m, "f1", "C1"))
	var after := before.duplicate(true)
	after["fields"] = {"hp": 9}
	ok(ContentStore.write(m, "f1", "C1", after, true), "改值写入")
	var dg_after := ContentStore.file_digest(ContentStore.path_for(m, "f1", "C1"))
	# 外部又改了一次：盘面摘要与记录不符
	var ext := after.duplicate(true)
	ext["fields"] = {"hp": 42}
	ok(ContentStore.write(m, "f1", "C1", ext, true), "外部改动写入")

	var ctx := _host()
	var h: Host = ctx.host
	h.manifest = m
	var uh = ctx.undo
	uh.record_content("f1", "C1", before, after, dg_before, dg_after)
	eq(uh._restore_content(uh.undo_stack[0], false), false, "摘要不符时拒绝回滚")
	eq(int(ContentStore.read(m, "f1", "C1").get("fields", {}).get("hp", 0)), 42, "外部值原样保留")
	h.free()
	_wipe()


## 内容视图 Ctrl+Z 只撤内容条目：栈顶是地图条目时不认领。
func test_undo_content_only_skips_map_entries() -> void:
	var ctx := _host()
	var h: Host = ctx.host
	var uh = ctx.undo
	var a := _ent(h, "MAP1", 0, 0)
	uh.inst_commit_add([a])
	eq(uh.undo_content_only(), "not_content", "栈顶是地图改动：内容视图不撤")
	eq(uh.undo_stack.size(), 1, "条目仍在栈上")
	h.free()


## 拒绝回滚时条目必须退回原栈（不给假反馈、不丢条目）；走同步入口 undo_content_only 验栈序。
func test_refused_content_returns_entry_to_stack() -> void:
	_wipe()
	var m := {"_dir": TMP, "contentDir": "content"}
	m["functions"] = [{"id": "f1", "name": "F", "code": "FC", "fields": []}]
	var before := {"id": "C1", "function": "FC", "name": "n", "fields": {"hp": 1}}
	ok(ContentStore.write(m, "f1", "C1", before, true), "初值写入")
	var dg_before := ContentStore.file_digest(ContentStore.path_for(m, "f1", "C1"))
	var after := before.duplicate(true)
	after["fields"] = {"hp": 9}
	ok(ContentStore.write(m, "f1", "C1", after, true), "改值写入")
	var dg_after := ContentStore.file_digest(ContentStore.path_for(m, "f1", "C1"))
	var ext := after.duplicate(true)
	ext["fields"] = {"hp": 42}
	ok(ContentStore.write(m, "f1", "C1", ext, true), "外部改动写入")

	var ctx := _host()
	var h: Host = ctx.host
	h.manifest = m
	var uh = ctx.undo
	uh.record_content("f1", "C1", before, after, dg_before, dg_after)
	eq(uh.undo_content_only(), "refused", "摘要不符时拒绝回滚")
	eq(uh.undo_stack.size(), 1, "条目退回原栈不丢")
	eq(uh.redo_stack.size(), 0, "对向栈不被污染")
	eq(int(ContentStore.read(m, "f1", "C1").get("fields", {}).get("hp", 0)), 42, "盘面仍是外部值")
	h.free()
	_wipe()
