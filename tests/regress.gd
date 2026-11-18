extends SceneTree

func _init() -> void:
	var errs := 0
	var cvs = load("res://src/canvas/editor_canvas.gd").new()
	root.add_child(cvs)
	var man := {"tileSize": 16, "layers": [
		{"id": "terrain", "name": "t", "type": "tiles"},
		{"id": "collision", "name": "c", "type": "grid"},
		{"id": "entities", "name": "e", "type": "entity"}],
		"entities": [
		{"id": "portal", "name": "p", "thumb": ""},
		{"id": "fake_ent", "name": "f", "thumb": ""}],
		"tiles": []}
	cvs.manifest = man
	var data := {"meta": {"name": "t1", "w": 40, "h": 22},
		"spawn": [2, 2],
		"terrain": [[1, 1, 0, 0], [2, 1, 1, 0], [3, 1, 2, 0]],
		"decor": [],
		"collision": [[1, 1], [2, 1]],
		"entities": []}
	print("STEP load")
	cvs.load_data(data, "t1", false)
	await process_frame
	await process_frame
	print("STEP stamp")
	cvs.stamp_scene = "portal"
	cvs._stamp(Vector2i(5, 5))
	cvs.stamp_scene = "fake_ent"
	cvs._stamp(Vector2i(8, 8))
	var ents: Array = cvs.entities.get_children()
	print("ents after stamp: ", ents.size())
	if ents.size() == 2:
		print("PASS stamp count")
	else:
		errs += 1
		print("FAIL stamp count")
	for e in ents:
		var sid := str(e.get_meta("scene", ""))
		var eid := str(e.get_meta("ent_id", ""))
		print("ent ", sid, " ", eid)
		if not eid.begins_with("e_"):
			errs += 1
			print("FAIL id")
	print("STEP extract")
	var ex: Dictionary = cvs.extract()
	print("extract ents: ", (ex.get("entities") as Array).size())
	var coll: Array = ex.get("collision", [])
	var coll_ok := coll.size() == 2
	for cell in coll:
		if not (cell is Array and cell.size() == 2):
			coll_ok = false
	if coll_ok and coll[0] == [1, 1] and coll[1] == [2, 1]:
		print("PASS extract collision")
	else:
		errs += 1
		print("FAIL extract collision ", coll)
	print("STEP undo")
	cvs.undo()
	await process_frame
	await process_frame
	var n2: int = cvs.entities.get_children().size()
	print("ents after undo: ", n2)
	if n2 == 1:  # 两次盖章，撤一步 → 剩 1 个
		print("PASS undo")
	else:
		errs += 1
		print("FAIL undo")
	# —— 光标模式：框选 → 复制 → 粘贴 → 删除 ——
	cvs.stamp_scene = "portal"
	cvs._stamp(Vector2i(20, 5))
	cvs._stamp(Vector2i(22, 5))
	cvs._box_select(Vector2(300, 60), Vector2(380, 120))
	var n_sel: int = cvs.selected_multi.size()
	print("box-selected: ", n_sel)
	if n_sel == 2:
		print("PASS box select")
	else:
		errs += 1
		print("FAIL box select")
	# 给源实体加嵌套 stats，才能验证粘贴是否深拷贝
	for src in cvs.selected_multi:
		var sp3: Dictionary = (src as Sprite2D).get_meta("props", {})
		sp3["stats"] = {"hp": 1}
		(src as Sprite2D).set_meta("props", sp3)
	cvs.copy_selection()
	var n_before: int = cvs.entities.get_children().size()
	cvs.paste_at(Vector2(100, 100))
	var n_after: int = cvs.entities.get_children().size()
	print("copy/paste: ", n_before, " -> ", n_after)
	if n_after == n_before + 2:
		print("PASS copy/paste")
	else:
		errs += 1
		print("FAIL copy/paste")
	# —— 粘贴属性必须深拷贝：改一个副本的嵌套 stats 不能串到同批副本 ——
	var all_ents: Array = cvs.entities.get_children()
	var p1: Sprite2D = all_ents[all_ents.size() - 1]
	var p2: Sprite2D = all_ents[all_ents.size() - 2]
	var pp1: Dictionary = p1.get_meta("props", {})
	pp1["stats"] = {"hp": 9}
	p1.set_meta("props", pp1)
	var pp2: Dictionary = p2.get_meta("props", {})
	if int(pp2.get("stats", {}).get("hp", 0)) == 1:
		print("PASS paste props isolated")
	else:
		errs += 1
		print("FAIL paste props shared ", pp2)
	# —— 粘贴坐标落在格中心：extract 往返不漂移 ——
	var snap_ok := true
	for spr in [p1, p2]:
		var cc: Vector2i = cvs._cell_of((spr as Sprite2D).position)
		var center: Vector2 = Vector2(cc) * 16 + Vector2(8, 8)
		if center.distance_to((spr as Sprite2D).position) > 0.01:
			snap_ok = false
	if snap_ok:
		print("PASS paste snapped to grid")
	else:
		errs += 1
		print("FAIL paste snapped to grid")
	# —— 区域复制后再实体复制，Ctrl+V 必须走实体粘贴（_last_copy_region 复位） ——
	cvs.active_layer = 0
	cvs._region_sel = Rect2i(0, 0, 2, 2)
	cvs.copy_region()
	if not cvs._last_copy_region:
		errs += 1
		print("FAIL region copy did not set region mode")
	cvs._box_select(Vector2(300, 60), Vector2(380, 120))
	cvs.copy_selection()
	if not cvs._last_copy_region:
		print("PASS copy mode reset after entity copy")
	else:
		errs += 1
		print("FAIL copy mode still region after entity copy")
	cvs.delete_selection()
	var n_del: int = cvs.entities.get_children().size()
	print("after delete: ", n_del)
	if n_del == n_after - 2:
		print("PASS delete")
	else:
		errs += 1
		print("FAIL delete")
	# —— stats 覆盖保存往返（白名单必须放行 stats 键） ——
	var st0: Sprite2D = cvs.entities.get_children()[0]
	var pp: Dictionary = st0.get_meta("props", {})
	pp["stats"] = {"hp": 7}
	st0.set_meta("props", pp)
	var ex2: Dictionary = cvs.extract()
	var ent0: Dictionary = (ex2.get("entities") as Array)[0]
	if (ent0.get("props", {}).get("stats", {}).get("hp", 0)) == 7:
		print("PASS stats save roundtrip")
	else:
		errs += 1
		print("FAIL stats save roundtrip")
	# —— 区域复制粘贴（三层快照） ——
	cvs.active_layer = 0
	cvs.paint_cell = Vector2i(0, 0)
	cvs._paint(Vector2i(10, 10))
	cvs.collision.set_cell(Vector2i(11, 10), 0, Vector2i(4, 0))
	cvs._region_sel = Rect2i(10, 10, 2, 1)
	cvs.copy_region()
	var rc: Dictionary = cvs._region_clip
	if (rc.get("terrain", []) as Array).size() == 1 and (rc.get("collision", []) as Array).size() == 1:
		print("PASS region copy")
	else:
		errs += 1
		print("FAIL region copy ", rc)
	cvs._paste_region(Vector2i(20, 15))
	var ok_t: bool = cvs.terrain.get_cell_atlas_coords(Vector2i(20, 15)) == Vector2i(0, 0)
	var ok_c: bool = cvs.collision.get_cell_source_id(Vector2i(21, 15)) != -1
	if ok_t and ok_c:
		print("PASS region paste")
	else:
		errs += 1
		print("FAIL region paste t=", ok_t, " c=", ok_c)
	cvs.undo()
	await process_frame
	await process_frame
	if cvs.terrain.get_cell_atlas_coords(Vector2i(20, 15)) == Vector2i(-1, -1):
		print("PASS region paste undo")
	else:
		errs += 1
		print("FAIL region paste undo")
	# —— 区域复制必须包含实体 ——
	cvs.active_layer = 0
	cvs.stamp_scene = "portal"
	cvs.active_layer = cvs._ent_layer_index()
	cvs._stamp(Vector2i(30, 30))
	cvs.active_layer = 0
	cvs._region_sel = Rect2i(29, 29, 4, 4)
	cvs.copy_region()
	var clip_ents: Array = cvs._region_clip.get("entities", [])
	if clip_ents.size() == 1:
		print("PASS region copy includes entities")
	else:
		errs += 1
		print("FAIL region copy entities ", clip_ents)
	var ents_before: int = cvs.entities.get_children().size()
	cvs._paste_region(Vector2i(40, 40))
	if cvs.entities.get_children().size() == ents_before + 1:
		print("PASS region paste creates entity")
	else:
		errs += 1
		print("FAIL region paste entity count")
	# —— 实体拖拽移动：吸附格点 + 一个撤销步 ——
	var mover: Sprite2D = cvs.entities.get_children()[0]
	var start_pos := mover.position
	cvs._begin_entity_drag(mover, start_pos)
	cvs._move_drag_preview(start_pos + Vector2(48, 32))
	cvs._finish_entity_drag()
	if mover.position != start_pos:
		print("PASS drag moved entity")
	else:
		errs += 1
		print("FAIL drag moved entity")
	var mc: Vector2i = cvs._cell_of(mover.position)
	if (Vector2(mc) * 16 + Vector2(8, 8)).distance_to(mover.position) < 0.01:
		print("PASS drag snapped to grid")
	else:
		errs += 1
		print("FAIL drag snapped to grid")
	cvs.undo()
	await process_frame
	await process_frame
	var restored: Sprite2D = cvs.entities.get_children()[0]
	if restored.position.distance_to(start_pos) < 0.01:
		print("PASS drag undo")
	else:
		errs += 1
		print("FAIL drag undo ", restored.position, " vs ", start_pos)
	# —— 框选后整组拖动：多点一起移动、各自吸附格点、一个撤销步 ——
	cvs.stamp_scene = "portal"
	cvs.active_layer = cvs._ent_layer_index()
	cvs._stamp(Vector2i(46, 46))
	cvs._stamp(Vector2i(52, 46))
	var grp_all: Array = cvs.entities.get_children()
	var g_ents: Array = grp_all.slice(grp_all.size() - 2, grp_all.size())
	cvs.selected_multi = g_ents.duplicate()
	cvs.selected_entity = null
	var g0: Vector2 = (g_ents[0] as Sprite2D).position
	var g1: Vector2 = (g_ents[1] as Sprite2D).position
	var box_rect: Rect2 = cvs._multi_bounds(cvs._valid_multi())
	var box_center := box_rect.get_center()
	if cvs._inside_multi_box(box_center):
		print("PASS group drag box hit")
	else:
		errs += 1
		print("FAIL group drag box hit ", box_center)
	cvs._begin_group_drag(box_center)
	cvs._move_drag_preview(box_center + Vector2(48, 0))
	cvs._finish_entity_drag()
	var gp0: Vector2 = (g_ents[0] as Sprite2D).position
	var gp1: Vector2 = (g_ents[1] as Sprite2D).position
	var gc0 := Vector2(cvs._cell_of(gp0)) * 16 + Vector2(8, 8)
	var gc1 := Vector2(cvs._cell_of(gp1)) * 16 + Vector2(8, 8)
	var moved_both := gp0.distance_to(g0) > 0.01 and gp1.distance_to(g1) > 0.01
	if moved_both and gp0.distance_to(gc0) < 0.01 and gp1.distance_to(gc1) < 0.01:
		print("PASS group drag moves all snapped")
	else:
		errs += 1
		print("FAIL group drag moves all snapped ", gp0, " vs ", gc0, " / ", gp1, " vs ", gc1)
	cvs.undo()
	await process_frame
	await process_frame
	var r_ents: Array = cvs.entities.get_children()
	var gr0: Vector2 = (r_ents[r_ents.size() - 2] as Sprite2D).position
	var gr1: Vector2 = (r_ents[r_ents.size() - 1] as Sprite2D).position
	if gr0.distance_to(g0) < 0.01 and gr1.distance_to(g1) < 0.01:
		print("PASS group drag undo")
	else:
		errs += 1
		print("FAIL group drag undo ", gr0, " ", g0, " / ", gr1, " ", g1)
	# —— 按住框选成员拖动：整组一起走，不被塌缩成单选 ——
	var pick_ents: Array = cvs.entities.get_children()
	var pick_two: Array = pick_ents.slice(pick_ents.size() - 2, pick_ents.size())
	cvs.selected_multi = pick_two.duplicate()
	cvs.selected_entity = null
	var h0: Vector2 = (pick_two[0] as Sprite2D).position
	var h1: Vector2 = (pick_two[1] as Sprite2D).position
	cvs._begin_entity_drag(pick_two[0] as Sprite2D, h0)
	var drag_all: bool = cvs._drag_entities.size() == 2
	cvs._move_drag_preview(h0 + Vector2(0, 48))
	cvs._finish_entity_drag()
	var q1: Vector2 = (pick_two[1] as Sprite2D).position
	if drag_all and q1.distance_to(h1) > 0.01:
		print("PASS grab member drags whole group")
	else:
		errs += 1
		print("FAIL grab member drags whole group ", drag_all, " ", q1, " vs ", h1)
	cvs.undo()
	await process_frame
	await process_frame
	# —— 剪切实体：进剪贴板 + 删除 + 一次撤销步还原 ——
	cvs.selected_multi.clear()
	cvs.selected_entity = null
	var cut_all: Array = cvs.entities.get_children()
	var cut_targets: Array = cut_all.slice(cut_all.size() - 2, cut_all.size())
	var before_cut: int = cut_all.size()
	cvs.selected_multi = cut_targets.duplicate()
	cvs.cut_selection()
	var after_cut: int = cvs.entities.get_children().size()
	if after_cut == before_cut - 2 and cvs._clipboard.size() == 2:
		print("PASS cut entities")
	else:
		errs += 1
		print("FAIL cut entities ", before_cut, "->", after_cut, " clip=", cvs._clipboard.size())
	if cvs.selected_multi.is_empty() and cvs.selected_entity == null:
		print("PASS cut clears selection")
	else:
		errs += 1
		print("FAIL cut clears selection")
	cvs.undo()
	await process_frame
	await process_frame
	if cvs.entities.get_children().size() == before_cut:
		print("PASS cut undo restores")
	else:
		errs += 1
		print("FAIL cut undo restores ", cvs.entities.get_children().size(), " vs ", before_cut)
	# —— 区域剪切：清空瓦片/碰撞/实体 + 一次撤销步还原 ——
	cvs.active_layer = 0
	cvs.paint_cell = Vector2i(0, 0)
	cvs._paint(Vector2i(20, 20))
	cvs._paint(Vector2i(21, 20))
	cvs.collision.set_cell(Vector2i(20, 20), 0, Vector2i(4, 0))
	cvs._region_sel = Rect2i(20, 20, 2, 2)
	cvs.cut_region()
	if cvs.terrain.get_cell_atlas_coords(Vector2i(20, 20)) == Vector2i(-1, -1) \
			and cvs.collision.get_cell_source_id(Vector2i(20, 20)) == -1:
		print("PASS cut region clears")
	else:
		errs += 1
		print("FAIL cut region clears")
	cvs.undo()
	await process_frame
	await process_frame
	if cvs.terrain.get_cell_atlas_coords(Vector2i(20, 20)) != Vector2i(-1, -1) \
			and cvs.collision.get_cell_source_id(Vector2i(20, 20)) != -1:
		print("PASS cut region undo")
	else:
		errs += 1
		print("FAIL cut region undo")
	# —— 图层锁定阻止编辑 ——
	cvs.active_layer = 0
	cvs.set_layer_locked(0, true)
	var before_lock: int = cvs.terrain.get_used_cells().size()
	cvs.paint_cell = Vector2i(0, 0)
	cvs._apply_tool(Vector2(60 * 16 + 8, 60 * 16 + 8))
	if cvs.terrain.get_used_cells().size() == before_lock:
		print("PASS locked layer blocks edit")
	else:
		errs += 1
		print("FAIL locked layer blocks edit")
	cvs.set_layer_locked(0, false)
	# —— 多选对齐：左/顶/居中，结果吸附格点 ——
	cvs.active_layer = cvs._ent_layer_index()
	cvs.stamp_scene = "portal"
	cvs._stamp(Vector2i(50, 50))
	cvs._stamp(Vector2i(54, 54))
	cvs._stamp(Vector2i(58, 60))
	var three: Array = cvs.entities.get_children()
	var a: Sprite2D = three[three.size() - 3]
	var b: Sprite2D = three[three.size() - 2]
	var cc2: Sprite2D = three[three.size() - 1]
	cvs.selected_multi = [a, b, cc2]
	cvs.align_selection("left")
	var aligned := absf(a.position.x - b.position.x) < 0.01 and absf(b.position.x - cc2.position.x) < 0.01
	if aligned:
		print("PASS align left")
	else:
		errs += 1
		print("FAIL align left ", a.position, b.position, cc2.position)
	cvs.undo()
	await process_frame
	await process_frame
	three = cvs.entities.get_children()
	a = three[three.size() - 3]
	b = three[three.size() - 2]
	cc2 = three[three.size() - 1]
	cvs.selected_multi = [a, b, cc2]
	cvs.align_selection("top")
	if absf(a.position.y - b.position.y) < 0.01 and absf(b.position.y - cc2.position.y) < 0.01:
		print("PASS align top")
	else:
		errs += 1
		print("FAIL align top")
	# —— 水平等距：首尾不动，中间居中 ——
	cvs.undo()
	await process_frame
	await process_frame
	three = cvs.entities.get_children()
	a = three[three.size() - 3]
	b = three[three.size() - 2]
	cc2 = three[three.size() - 1]
	cvs.selected_multi = [a, b, cc2]
	var ax := a.position.x
	var cx := cc2.position.x
	cvs.align_selection("dist_h")
	var mid_ok := absf(b.position.x - (ax + cx) * 0.5) < 0.01
	if mid_ok and absf(a.position.x - ax) < 0.01 and absf(cc2.position.x - cx) < 0.01:
		print("PASS distribute horizontal")
	else:
		errs += 1
		print("FAIL distribute horizontal ", b.position.x, " expected ", (ax + cx) * 0.5)
	# —— 批量属性：只写同类实体，嵌套 stats 深拷贝 ——
	cvs.undo()
	await process_frame
	await process_frame
	three = cvs.entities.get_children()
	a = three[three.size() - 3]
	b = three[three.size() - 2]
	cvs.selected_multi = [a, b]
	var n_bulk: int = cvs.bulk_update("portal", {"custom": 42}, [], {})
	if n_bulk == 2:
		print("PASS bulk update count")
	else:
		errs += 1
		print("FAIL bulk update count ", n_bulk)
	var sa: Dictionary = a.get_meta("props", {}).get("stats", {})
	var sb: Dictionary = b.get_meta("props", {}).get("stats", {})
	if int(sa.get("custom", 0)) == 42 and int(sb.get("custom", 0)) == 42:
		print("PASS bulk update applied")
	else:
		errs += 1
		print("FAIL bulk update applied ", sa, sb)
	# 改一份不能串到另一份
	sa["custom"] = 99
	a.set_meta("props", {"stats": sa})
	var sb2: Dictionary = b.get_meta("props", {}).get("stats", {})
	if int(sb2.get("custom", 0)) == 42:
		print("PASS bulk props isolated")
	else:
		errs += 1
		print("FAIL bulk props shared ", sb2)
	# 不匹配类型时不应误改
	var n_none: int = cvs.bulk_update("crawler", {"hp": 1}, [], {})
	if n_none == 0:
		print("PASS bulk update skips other scene")
	else:
		errs += 1
		print("FAIL bulk update touched other scene ", n_none)
	# —— 从地形自动生成碰撞：full / top / outline 三种策略 ——
	cvs.active_layer = 0
	cvs.set_layer_locked(0, false)
	for c in cvs.collision.get_used_cells():
		cvs.collision.erase_cell(c)
	# 造一块 2×2 地形，顶部策略应比全量少（下方两格无上方邻居之外的地形不算顶部）
	cvs.paint_cell = Vector2i(0, 0)
	cvs._paint(Vector2i(70, 70))
	cvs._paint(Vector2i(71, 70))
	cvs._paint(Vector2i(70, 71))
	cvs._paint(Vector2i(71, 71))
	var n_full: int = cvs.count_auto_collision("full", true)
	var terrain_total: int = cvs.terrain.get_used_cells().size()
	if n_full == terrain_total and n_full >= 4:
		print("PASS collision preview counts")
	else:
		errs += 1
		print("FAIL collision preview counts ", n_full, " vs ", terrain_total)
	# 顶部策略只保留「上方无地形」的格子
	var n_top: int = cvs.count_auto_collision("top", true)
	var expect_top := 0
	for c in cvs.terrain.get_used_cells():
		if cvs.terrain.get_cell_source_id(c + Vector2i(0, -1)) == -1:
			expect_top += 1
	if n_top == expect_top:
		print("PASS collision top strategy")
	else:
		errs += 1
		print("FAIL collision top strategy ", n_top, " vs ", expect_top)
	# 外轮廓策略只保留四邻有不空位的格子
	var n_outline: int = cvs.count_auto_collision("outline", true)
	var expect_outline := 0
	for c in cvs.terrain.get_used_cells():
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			if cvs.terrain.get_cell_source_id(c + d) == -1:
				expect_outline += 1
				break
	if n_outline == expect_outline:
		print("PASS collision outline strategy")
	else:
		errs += 1
		print("FAIL collision outline strategy ", n_outline, " vs ", expect_outline)
	# 顶部策略必须严格少于全量（说明确实做了筛选）
	if expect_top < n_full and n_outline > 0:
		print("PASS collision strategy differs")
	else:
		errs += 1
		print("FAIL collision strategy differs")
	cvs.generate_collision("full", true)
	if cvs.collision.get_cell_source_id(Vector2i(70, 70)) != -1 \
			and cvs.collision.get_cell_source_id(Vector2i(71, 71)) != -1:
		print("PASS collision generated")
	else:
		errs += 1
		print("FAIL collision generated")
	cvs.undo()
	await process_frame
	await process_frame
	if cvs.collision.get_cell_source_id(Vector2i(70, 70)) == -1:
		print("PASS collision gen undo")
	else:
		errs += 1
		print("FAIL collision gen undo")
	# —— 撤销快照为字符串（内存优化） ——
	cvs._push_undo()
	if cvs.undo_stack.back() is String:
		print("PASS undo snapshot is json string")
	else:
		errs += 1
		print("FAIL undo snapshot type")
	# —— T-11：其余对齐/分布模式（right/bottom/center_h/center_v/dist_v） ——
	cvs.stamp_scene = "portal"
	cvs.active_layer = cvs._ent_layer_index()
	cvs._stamp(Vector2i(60, 4))
	cvs._stamp(Vector2i(64, 8))
	cvs._stamp(Vector2i(68, 12))
	var t11 = cvs.entities.get_children()
	var ra: Sprite2D = t11[t11.size() - 3]
	var rb: Sprite2D = t11[t11.size() - 2]
	var rc3: Sprite2D = t11[t11.size() - 1]
	cvs.selected_multi = [ra, rb, rc3]
	cvs.align_selection("right")
	if absf(ra.position.x - rb.position.x) < 0.01 and absf(rb.position.x - rc3.position.x) < 0.01:
		print("PASS align right")
	else:
		errs += 1
		print("FAIL align right")
	cvs.align_selection("bottom")
	if absf(ra.position.y - rb.position.y) < 0.01 and absf(rb.position.y - rc3.position.y) < 0.01:
		print("PASS align bottom")
	else:
		errs += 1
		print("FAIL align bottom")
	cvs.align_selection("center_h")
	var chc := (minf(ra.position.x, minf(rb.position.x, rc3.position.x)) + maxf(ra.position.x, maxf(rb.position.x, rc3.position.x))) * 0.5
	if absf(ra.position.x - chc) < 0.01 and absf(rc3.position.x - chc) < 0.01:
		print("PASS align center_h")
	else:
		errs += 1
		print("FAIL align center_h")
	cvs.align_selection("center_v")
	var cvc := (minf(ra.position.y, minf(rb.position.y, rc3.position.y)) + maxf(ra.position.y, maxf(rb.position.y, rc3.position.y))) * 0.5
	if absf(ra.position.y - cvc) < 0.01 and absf(rc3.position.y - cvc) < 0.01:
		print("PASS align center_v")
	else:
		errs += 1
		print("FAIL align center_v")
	cvs.align_selection("dist_v")
	var dy0 := ra.position.y
	var dy2 := rc3.position.y
	if absf(rb.position.y - (dy0 + dy2) * 0.5) < 0.01 and absf(ra.position.y - dy0) < 0.01 and absf(rc3.position.y - dy2) < 0.01:
		print("PASS distribute vertical")
	else:
		errs += 1
		print("FAIL distribute vertical")
	cvs.undo()
	await process_frame
	await process_frame
	# —— T-11：bulk_update 的 stat_clear 分支（undo 会重建节点，先重新取引用） ——
	var t11b = cvs.entities.get_children()
	ra = t11b[t11b.size() - 3]
	rb = t11b[t11b.size() - 2]
	cvs.selected_multi = [ra, rb]
	var n_clear: int = cvs.bulk_update("portal", {"tmp": 1}, ["custom"], {"junk": ""})
	if n_clear == 2:
		print("PASS bulk stat_clear count")
	else:
		errs += 1
		print("FAIL bulk stat_clear count ", n_clear)
	var clear_ok := true
	for spr in [ra, rb]:
		var pr = spr.get_meta("props", {})
		if (pr.get("stats", {}) as Dictionary).has("custom") or (pr as Dictionary).has("junk"):
			clear_ok = false
	if clear_ok:
		print("PASS bulk stat_clear applied")
	else:
		errs += 1
		print("FAIL bulk stat_clear applied")
	cvs.undo()
	await process_frame
	await process_frame
	# —— T-12：cut_region 含实体分支（区域内的实体一并剪切、一次撤销步还原） ——
	cvs.active_layer = 0
	cvs.stamp_scene = "portal"
	cvs.active_layer = cvs._ent_layer_index()
	cvs._stamp(Vector2i(24, 16))
	var n_ent0: int = cvs.entities.get_children().size()
	cvs.active_layer = 0
	cvs._region_sel = Rect2i(23, 15, 3, 3)
	cvs.cut_region()
	var cut_ents: int = cvs.entities.get_children().size()
	if cut_ents == n_ent0 - 1 and (cvs._region_clip.get("entities", []) as Array).size() == 1:
		print("PASS cut region includes entity")
	else:
		errs += 1
		print("FAIL cut region includes entity ", n_ent0, "->", cut_ents)
	cvs.undo()
	await process_frame
	await process_frame
	if cvs.entities.get_children().size() == n_ent0:
		print("PASS cut region entity undo")
	else:
		errs += 1
		print("FAIL cut region entity undo")
	# —— T-12：实体层锁定时剪/拖/盖全部拒绝 ——
	cvs.set_layer_locked(cvs._ent_layer_index(), true)
	cvs.selected_multi = [cvs.entities.get_children()[0]]
	cvs.cut_selection()
	if cvs.entities.get_children().size() == n_ent0:
		print("PASS locked entity blocks cut")
	else:
		errs += 1
		print("FAIL locked entity blocks cut")
	var dr: Sprite2D = cvs.entities.get_children()[0]
	cvs._begin_entity_drag(dr, dr.position)
	if cvs._drag_entity == null:
		print("PASS locked entity blocks drag")
	else:
		errs += 1
		print("FAIL locked entity blocks drag")
	cvs.active_layer = cvs._ent_layer_index()
	cvs._stamp(Vector2i(36, 18))
	if cvs.entities.get_children().size() == n_ent0:
		print("PASS locked entity blocks stamp")
	else:
		errs += 1
		print("FAIL locked entity blocks stamp")
	cvs.set_layer_locked(cvs._ent_layer_index(), false)
	# —— T-14：实体翻转（flip_h 数据模型 + 一个撤销步还原） ——
	cvs.selected_entity = null
	cvs.selected_multi = []
	if cvs.flip_selected():
		errs += 1
		print("FAIL flip needs selection")
	else:
		print("PASS flip needs selection")
	cvs.active_layer = cvs._ent_layer_index()
	cvs._stamp(Vector2i(38, 18))
	var fspr: Sprite2D = cvs.entities.get_children()[cvs.entities.get_child_count() - 1]
	cvs.selected_entity = fspr
	if cvs.flip_selected() and fspr.flip_h:
		print("PASS flip toggles flip_h")
	else:
		errs += 1
		print("FAIL flip toggles flip_h")
	var fexp := false
	for ee in cvs.extract().get("entities", []):
		if str(ee.get("id", "")) == str(fspr.get_meta("ent_id")) and bool(ee.get("flip_h", false)):
			fexp = true
	if fexp:
		print("PASS flip extract carries flip_h")
	else:
		errs += 1
		print("FAIL flip extract carries flip_h")
	# 翻转落撤销：undo 重建实体，flip_h 回到 false（同格新精灵）
	var fpos := fspr.position
	cvs.undo()
	await process_frame
	var rspr: Sprite2D = null
	for c2 in cvs.entities.get_children():
		if (c2 as Sprite2D).position == fpos:
			rspr = c2
	if rspr != null and not rspr.flip_h:
		print("PASS flip undo restores")
	else:
		errs += 1
		print("FAIL flip undo restores found=", rspr != null, " flipped=", rspr != null and rspr.flip_h)
	if errs == 0:
		print("REGRESS_OK")
	else:
		print("REGRESS_FAIL")
	quit(errs)
