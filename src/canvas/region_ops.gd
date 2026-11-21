extends RefCounted
## RegionOps：从 selection_ops.gd 拆出的区域操作控制器（宿主 = editor_canvas 实例，cvs 引用）。
## 区域快照 / 复制 / 剪切 / 粘贴 / 拖动搬迁 + 层重映射 + 引用重映射。
## 函数体逐字节原样迁入；共享辅助（_ent_cell/_ent_template/_instantiate 等）
## 随区域半区迁入本文件，实体剪贴板半区经 cvs._region_ops_ctrl 委托回来。

var cvs   # editor_canvas 宿主

const MapFormat := preload("res://src/map/map_format.gd")
const TilesetCache := preload("res://src/canvas/tileset_cache.gd")
const ClonePlan := preload("res://src/content/clone_plan.gd")
const ContentStore := preload("res://src/content/content_store.gd")

func _init(c) -> void:
	cvs = c
## —— 框选区域拖动搬迁（瓦片 / 装饰 / 碰撞三层 + 区域内实体） ——
## 按下时只快照，不立刻搬；松手才「推撤销 → 擦源 → 写目标」。
## 这样拖动中数据没被改过，中途松手/取消都不会留下半截状态。
## 状态字段挂宿主 cvs（本项目控制器一律经 cvs 读写宿主状态）：
## cvs._move_snap / _move_from / _move_grab / _move_cell_delta / _move_active

## 点是否落在已有区域选区里（用来区分「拖走这块」和「重新框选」）
## 区域选区是 root 空间格号（与层参数无关），拾取走 root_cell。
func _in_region_sel(pos: Vector2) -> bool:
	if cvs._region_sel.size.x <= 0 or cvs._region_sel.size.y <= 0:
		return false
	return cvs._region_sel.has_point(cvs.root_cell(pos))

## 实体的「所在格」判定：由资产的 anchor 统一（top_left 型 = 矩形左上格，
## center 型 = 中心格）。区域复制/剪切/框入/拖动四处共用，防止复制进了剪贴板、
## 剪切却漏删（或反之）的错位。
func _ent_cell(n: EntityNode) -> Vector2i:
	return n.cell()


## 当前有效选区（多选优先，为空则退单选），已滤掉已释放对象。
func _live_selection() -> Array:
	var out: Array = []
	for s in cvs.selected_multi:
		if is_instance_valid(s):
			out.append(s)
	if out.is_empty() and cvs.selected_entity and is_instance_valid(cvs.selected_entity):
		out.append(cvs.selected_entity)
	return out


## 区域快照存**数据**不存活体节点：节点随后被 free 也不会让剪贴板拿到失效引用。
func _snapshot_region(sel: Rect2i) -> Dictionary:
	# 层栈快照：tiles = {层id: [[x,y,资产id,ax,ay]...]}，碰撞/实例同形（实例带 layer）
	var snap := {"tiles": {}, "collision": [], "ents": [], "size": sel.size}
	for li in cvs.layer_tiles.size():
		var lid: String = cvs.layer_id(li)
		if lid == "":
			continue
		var cells := []
		for y in range(sel.position.y, sel.end.y):
			for x in range(sel.position.x, sel.end.x):
				var c := Vector2i(x, y)
				var tac: Vector2i = (cvs.layer_tiles[li] as TileMapLayer).get_cell_atlas_coords(c)
				if tac != Vector2i(-1, -1):
					var aid: String = cvs.asset_of_source((cvs.layer_tiles[li] as TileMapLayer).get_cell_source_id(c))
					if aid == "":
						continue
					cells.append([x, y, aid, tac.x, tac.y,
						MapFormat.alt_of_godot((cvs.layer_tiles[li] as TileMapLayer).get_cell_alternative_tile(c))])
		if not cells.is_empty():
			snap["tiles"][lid] = cells
	for y2 in range(sel.position.y, sel.end.y):
		for x2 in range(sel.position.x, sel.end.x):
			var c2 := Vector2i(x2, y2)
			if cvs.collision.get_cell_source_id(c2) != -1:
				var cm = cvs._collision_meta.get(c2, null)
				if cm != null:
					snap["collision"].append([x2, y2, str(cm.get("type", "solid")), str(cm.get("shape", ""))])
				else:
					snap["collision"].append([x2, y2])
	for e in cvs.ents_all():
		var n := e as EntityNode
		if n == null or n.asset == "":
			continue
		var ec := _ent_cell(n)
		if sel.has_point(ec):
			snap["ents"].append(_ent_template(n, Vector2(sel.position)))
	return snap

## 一个实例的数据模板（复制/区域快照共用）：相对偏移（格，浮点——保留亚格位置）+ 全部数据字段，
## 不含活体引用。
func _ent_template(n: EntityNode, at: Vector2) -> Dictionary:
	var g: Vector2 = n.grid_of_world(n.position) - at
	return {
		"dx": snappedf(g.x, 0.001),
		"dy": snappedf(g.y, 0.001),
		"asset": n.asset,
		"code": n.code,
		"layer": n.layer_id,
		"transform": n.data_transform.duplicate(true),
		"functions": n.functions.duplicate(true),
		"props": n.props.duplicate(true),
		"zPolicy": n.z_policy,
		"visible": n.visible_flag,
		# 完整对象负载（E12）：sortAnchor 与游戏侧自定义键随区域快照走
		"raw": n.raw.duplicate(true),
	}

func _begin_region_move(pos: Vector2) -> void:
	if cvs.is_layer_locked(cvs.active_layer):
		cvs._hint("当前图层已锁定：解锁后再移动区域")
		return
	if cvs._any_layer_locked():
		cvs._hint("有图层处于锁定状态：解锁后再移动区域")
		return
	cvs._move_snap = _snapshot_region(cvs._region_sel)
	cvs._move_from = cvs._region_sel.position
	cvs._move_grab = pos
	cvs._move_cell_delta = Vector2i.ZERO
	cvs.begin_gesture(cvs.Gesture.REGION_MOVE, MOUSE_BUTTON_LEFT)


func _move_region_preview(pos: Vector2) -> void:
	var d: Vector2i = cvs.root_cell(pos) - cvs.root_cell(cvs._move_grab)
	if d != cvs._move_cell_delta:
		cvs._move_cell_delta = d
		cvs.queue_redraw()


func _finish_region_move() -> void:
	var active: bool = cvs._move_active
	var snap: Dictionary = cvs._move_snap
	var from: Vector2i = cvs._move_from
	var delta: Vector2i = cvs._move_cell_delta
	cvs._move_snap = {}
	cvs._move_cell_delta = Vector2i.ZERO
	if not active or delta == Vector2i.ZERO:
		return
	cvs._push_undo()
	# 先清源（各层瓦片 + 碰撞），再写目标；实例按数据坐标平移（保持浮点位）
	for lid in (snap.get("tiles", {}) as Dictionary):
		var li: int = cvs._layer_index_of(str(lid))
		if li < 0:
			continue
		for t in (snap.get("tiles", {})[lid] as Array):
			(cvs.layer_tiles[li] as TileMapLayer).erase_cell(Vector2i(int(t[0]), int(t[1])))
	for t in snap.get("collision", []):
		cvs.set_collision_cell(Vector2i(int(t[0]), int(t[1])), false)
	for lid2 in (snap.get("tiles", {}) as Dictionary):
		var li2: int = cvs._layer_index_of(str(lid2))
		if li2 < 0:
			continue
		for t2 in (snap.get("tiles", {})[lid2] as Array):
			var src2: int = cvs.source_of_asset(str((t2 as Array)[2]))
			if src2 < 0:
				continue
			var ta2 := t2 as Array
			TilesetCache.set_cell_alt(cvs.layer_tiles[li2] as TileMapLayer,
				Vector2i(int(ta2[0]), int(ta2[1])) + delta, src2,
				Vector2i(int(ta2[3]), int(ta2[4])),
				int(ta2[5]) if ta2.size() >= 6 else 0)
	for t in snap.get("collision", []):
		var ta := t as Array
		if ta.size() >= 4:
			cvs.set_collision_cell(Vector2i(int(ta[0]), int(ta[1])) + delta, true, str(ta[2]), str(ta[3]))
		else:
			cvs.set_collision_cell(Vector2i(int(ta[0]), int(ta[1])) + delta, true)
	# 实例：区块内的实例原地平移（保持身份码与层归属，不重建节点）。
	# 平移量按各实例所在层逆变换（E02）：跨层组的层偏移/缩放不同，不能共用一个世界位移。
	for e in cvs.ents_all():
		var n := e as EntityNode
		if n != null and n.asset != "" and cvs._region_sel.has_point(n.cell()):
			var li: int = cvs._layer_index_of(n.layer_id)
			var dl: Vector2 = cvs.grid_dir_px(delta.x, delta.y) if li < 0 \
				else cvs.world_delta_local(li, cvs.grid_dir_px(delta.x, delta.y))
			n.position += dl
	# 选区跟着搬到新位置，方便接着拖第二下
	cvs._region_sel.position = from + delta
	cvs._mark()
	cvs.queue_redraw()
	cvs._hint("已移动区域 %dx%d 偏移 (%d,%d)（Ctrl+Z 撤销）" % [
		cvs._region_sel.size.x, cvs._region_sel.size.y, delta.x, delta.y])

## 按模板重建一个实例节点（层按模板里的层码找，找不到落最底层）。
## 区域拖动/区域粘贴共用这一个入口，避免两处各写一遍落层逻辑。
func _instantiate(t: Dictionary, origin: Vector2i) -> EntityNode:
	var aid := str(t.get("asset", ""))
	if aid == "":
		return null
	var n: EntityNode = cvs.make_object(aid)
	if not cvs.is_placeable(aid):
		n.queue_free()   # 目标项目没有这个资产（或不是可摆放类型）：跳过，不落空节点
		return null
	n.layer_id = cvs.layer_id(cvs._layer_index_of(str(t.get("layer", ""))))
	if n.layer_id == "":
		n.layer_id = cvs.layer_id(0)
	n.props = (t.get("props", {}) as Dictionary).duplicate(true)
	n.functions = (t.get("functions", []) as Array).duplicate(true)
	n.data_transform = (t.get("transform", {}) as Dictionary).duplicate(true)
	n.z_policy = str(t.get("zPolicy", "auto"))
	n.visible_flag = bool(t.get("visible", true))
	# 完整对象负载（E12）：sortAnchor 与游戏侧未知键随模板走
	n.raw = (t.get("raw", {}) as Dictionary).duplicate(true) if t.get("raw", null) is Dictionary else {}
	n.refresh_visual()
	n.apply_grid(origin.x + float(t.get("dx", 0.0)), origin.y + float(t.get("dy", 0.0)))
	var ei: int = cvs._layer_index_of(n.layer_id)
	cvs._place_in_layer(n, maxi(ei, 0))
	# 新实例按需发码（场景实例不产码）；旧码只作为引用重映射的键
	if n.is_entity() and n.code == "":
		n.code = cvs._fresh_inst_code()
	return n

## object 摆放模式下区域复制/剪切 = 实体剪贴板（复用实体半区）
func copy_selection() -> void:
	cvs._selection_ops_ctrl.copy_selection()
func cut_selection() -> void:
	cvs._selection_ops_ctrl.cut_selection()

func copy_region() -> void:
	if cvs.map_root == null:
		return
	if cvs.place_kind == "object":
		copy_selection()
		return
	if cvs._region_sel.size.x <= 0:
		cvs._hint("先框选一块区域再复制")
		return
	# 层栈剪贴板：tiles = {层id: [[dx,dy,资产id,ax,ay,alt]...]}，碰撞/实体照旧（实体带 layer）
	# 源图身份随剪贴板带走（C2）：跨图粘贴时配对地图字段据此补源图键。
	cvs._region_clip = {"tiles": {}, "collision": [], "size": cvs._region_sel.size,
		"map": cvs.cur_map_name,
		"map_code": str((cvs.map_data.get("meta", {}) as Dictionary).get("code", "")) \
			if cvs.map_data.get("meta", {}) is Dictionary else ""}
	# 层名凭据：粘贴时同图按 id 直配，跨图按层名重映射（谁的名字谁带走）
	var lnames := {}
	for li2 in cvs.layer_count():
		lnames[cvs.layer_id(li2)] = cvs.layer_name(li2)
	cvs._region_clip["layer_names"] = lnames
	for li in cvs.layer_tiles.size():
		var lid: String = cvs.layer_id(li)
		if lid == "":
			continue
		var cells := []
		for y in range(cvs._region_sel.position.y, cvs._region_sel.end.y):
			for x in range(cvs._region_sel.position.x, cvs._region_sel.end.x):
				var d: Vector2i = Vector2i(x, y) - cvs._region_sel.position
				# 区域剪贴板带资产 id——多图集瓦片整块搬运，且清单重排不破坏剪贴板
				var tac: Vector2i = (cvs.layer_tiles[li] as TileMapLayer).get_cell_atlas_coords(Vector2i(x, y))
				if tac != Vector2i(-1, -1):
					var aid: String = cvs.asset_of_source((cvs.layer_tiles[li] as TileMapLayer).get_cell_source_id(Vector2i(x, y)))
					if aid == "":
						continue
					cells.append([d.x, d.y, aid, tac.x, tac.y,
						MapFormat.alt_of_godot((cvs.layer_tiles[li] as TileMapLayer).get_cell_alternative_tile(Vector2i(x, y)))])
		if not cells.is_empty():
			cvs._region_clip["tiles"][lid] = cells
	for y2 in range(cvs._region_sel.position.y, cvs._region_sel.end.y):
		for x2 in range(cvs._region_sel.position.x, cvs._region_sel.end.x):
			if cvs.collision.get_cell_source_id(Vector2i(x2, y2)) != -1:
	 # 区域剪贴板带碰撞类型/形状
				var cm = cvs._collision_meta.get(Vector2i(x2, y2), null)
				if cm != null:
					cvs._region_clip["collision"].append([x2 - cvs._region_sel.position.x, y2 - cvs._region_sel.position.y, str(cm.get("type", "solid")), str(cm.get("shape", ""))])
				else:
					cvs._region_clip["collision"].append([x2 - cvs._region_sel.position.x, y2 - cvs._region_sel.position.y])
	# 实例也一起复制：区域块含实例，才能整块房间复用（层随实例走）
	var ents_clip := []
	for e in cvs.ents_all():
		var n := e as EntityNode
		if n == null or n.asset == "":
			continue
		var ec: Vector2i = _ent_cell(n)
		if cvs._region_sel.has_point(ec):
			ents_clip.append(_ent_template(n, Vector2(cvs._region_sel.position)))
	cvs._region_clip["ents"] = ents_clip
	cvs._last_copy_region = true
	var tcount := 0
	for lid2 in (cvs._region_clip["tiles"] as Dictionary):
		tcount += ((cvs._region_clip["tiles"] as Dictionary)[lid2] as Array).size()
	cvs._hint("已复制 %dx%d 区域（%d 瓦片 / %d 实体；Ctrl+V 幽灵预览，左键落位/右键或 Esc 取消）" % [
		cvs._region_sel.size.x, cvs._region_sel.size.y, tcount, ents_clip.size()])

## 任一图层锁定即拒绝区域级操作：部分跳过会让剪贴板与实际删除不一致。

## 区域剪切 = 复制区域内各层瓦片 + 碰撞 + 实体，再把源区域清空。整件事一个撤销步。
func cut_region() -> void:
	if cvs.map_root == null:
		return
	if cvs.place_kind == "object":
		cut_selection()
		return
	if cvs._region_sel.size.x <= 0:
		cvs._hint("先框选一块区域再剪切")
		return
	if cvs._any_layer_locked():
		cvs._hint("有图层处于锁定状态：解锁后再剪切区域")
		return
	copy_region()
	if cvs._region_clip.is_empty():
		return
	cvs._push_undo()
	for y in range(cvs._region_sel.position.y, cvs._region_sel.end.y):
		for x in range(cvs._region_sel.position.x, cvs._region_sel.end.x):
			var c := Vector2i(x, y)
			for tn in cvs.layer_tiles:
				(tn as TileMapLayer).erase_cell(c)
			cvs.set_collision_cell(c, false)
	# 区域内的实例一并移除（它们已经进了剪贴板）
	for e in cvs.ents_all():
		var n := e as EntityNode
		if n == null or n.asset == "":
			continue
		if cvs._region_sel.has_point(_ent_cell(n)):
			(n.get_parent() as Node2D).remove_child(n)
			n.free()
	# 区域内实例已释放：把选区里的悬挂引用清掉，否则后续复制/框选/绘制
	# 读已释放对象会直接崩（剪掉自己正选着的东西是常态操作）。
	# 只过滤不清空：仍有效的选择保持原样（单选不升格成多选）
	var keep: Array = []
	for s in cvs.selected_multi:
		if is_instance_valid(s):
			keep.append(s)
	cvs.selected_multi = keep
	if cvs.selected_entity != null and not is_instance_valid(cvs.selected_entity):
		cvs.selected_entity = null
		cvs.entity_selected.emit(null)
	cvs._mark()   # 区域剪切含实例删除，实例索引/列表缓存一并失效
	cvs.queue_redraw()
	cvs._hint("已剪切区域 %dx%d（Ctrl+V 粘贴 / Ctrl+Z 撤销）" % [cvs._region_sel.size.x, cvs._region_sel.size.y])


func _paste_region(origin: Vector2i) -> void:
	if cvs.map_root == null or cvs._region_clip.is_empty():
		return
	if cvs._any_layer_locked():
		cvs._hint("有图层处于锁定状态：解锁后再粘贴区域")
		return
	# 实例：按相对格位重建，落回各自的层（找不到同码层落最底层）；
	# C2：实例码与附属内容 ID 统一由 ClonePlan 预留——组内引用重映射、组外保留，
	# 组内内容每条生成独立文件（此前所有副本共享同一内容 ID，改一份全变）。
	var rows: Array = []
	for t in cvs._region_clip.get("ents", []):
		if not (t is Dictionary):
			continue
		rows.append({
			"asset": str(t.get("asset", "")),
			"code": str(t.get("code", "")),
			"props": (t.get("props", {}) as Dictionary).duplicate(true),
			"functions": (t.get("functions", []) as Array).duplicate(true),
		})
	var plan: Dictionary = ClonePlan.build(
		{"data": {"meta": {"code": str(cvs._region_clip.get("map_code", ""))}, "objects": rows},
			"manifest": cvs.manifest, "map": str(cvs._region_clip.get("map", ""))},
		{"data": cvs.map_data, "manifest": cvs.manifest, "map": cvs.cur_map_name})
	if str(plan.get("status", "")) != "ok":
		cvs._hint("区域粘贴已取消：" + ClonePlan.conflicts_text(plan.get("conflicts", [])))
		return
	# 内容先落盘（A2）：写失败整条粘贴放弃，画布未被改动
	for pc in (plan.get("pending_contents", []) as Array):
		var pd: Dictionary = pc
		if not ContentStore.write(cvs.manifest, str(pd.get("fn_id", "")), str(pd.get("id", "")),
				pd.get("data", {}) as Dictionary):
			cvs._hint("区域粘贴已取消：新内容 %s 写入失败" % str(pd.get("id", "")))
			return
	# 校验全过才动手：一条撤销步覆盖瓦片 + 碰撞 + 实例
	cvs._push_undo()
	# 粘贴按 层id 维度重建（tiles = {层id: [[dx,dy,资产id,ax,ay]...]}）
	# 层重映射：同图按 id 直配，跨图按层名，都不匹配则落最底层（末尾黄字提示）
	var lnames: Dictionary = cvs._region_clip.get("layer_names", {})
	var clip_map := str(cvs._region_clip.get("map", ""))
	var same_map: bool = clip_map == "" or clip_map == cvs.cur_map_name
	var missed: Array = []
	for lid in (cvs._region_clip.get("tiles", {}) as Dictionary):
		var li: int = _paste_layer_index(str(lid), lnames, missed, same_map)
		for t in (cvs._region_clip.get("tiles", {})[lid] as Array):
			var ta := t as Array
			var src: int = cvs.source_of_asset(str(ta[2]))
			if src < 0:
				continue   # 目标项目没有这个资产：跳过，不写坏格子
			TilesetCache.set_cell_alt(cvs.layer_tiles[li] as TileMapLayer,
				origin + Vector2i(int(ta[0]), int(ta[1])), src,
				Vector2i(int(ta[3]), int(ta[4])),
				int(ta[5]) if ta.size() >= 6 else 0)
	for t in cvs._region_clip.get("collision", []):
		var cc := origin + Vector2i(int(t[0]), int(t[1]))
		if (t as Array).size() >= 4:
			cvs.set_collision_cell(cc, true, str(t[2]), str(t[3]))
		else:
			cvs.set_collision_cell(cc, true)
	# 行与剪贴板条目一一对应（ClonePlan 不跳行）：按下标取重映射结果
	var remapped: Array = (plan.get("map_patch", {}) as Dictionary).get("objects", [])
	var pasted: Array = []
	var idx := 0
	for t in cvs._region_clip.get("ents", []):   # 键统一为 ents（预览也读 ents）
		var tpl := t as Dictionary
		var n := _instantiate(tpl, origin)
		if n == null:
			continue
		# 层重映射失败时 _instantiate 落最底层，但要记下哪几层没匹配上
		var src_lid := str(tpl.get("layer", ""))
		if src_lid != "" and cvs._layer_index_of(src_lid) < 0:
			var nm: String = str((cvs._region_clip.get("layer_names", {}) as Dictionary).get(src_lid, ""))
			if not missed.has(nm if nm != "" else src_lid):
				missed.append(nm if nm != "" else src_lid)
		# 重映射后的行覆盖身份/引用/绑定（位置与变换来自模板，已由 _instantiate 落好）
		if idx < remapped.size():
			var row: Dictionary = remapped[idx]
			if str(row.get("code", "")) != "":
				n.code = str(row.get("code", ""))
			if row.get("props", null) is Dictionary:
				n.props = (row.get("props", {}) as Dictionary).duplicate(true)
			if row.get("functions", null) is Array:
				n.functions = (row.get("functions", []) as Array).duplicate(true)
			n.refresh_visual()
		pasted.append(n)
		idx += 1
	cvs._mark()   # 区域粘贴含实体，保持索引置脏
	cvs._paste_mode = false
	if missed.is_empty():
		cvs._hint("区域已粘贴")
	else:   # 层匹配失败提示合并进同一条（状态栏单条消息，分开发会被覆盖）
		cvs._hint("区域已粘贴；有 %d 个层按名匹配失败，其内容落在最底层：%s" % [missed.size(), ", ".join(missed)])

## 区域粘贴的层重映射（C2）：同图按 id 直配；跨图按**唯一**层名匹配，
## 名字重复或不匹配落最底层并记入 missed（末尾黄字提示，绝不猜）。
func _paste_layer_index(src_lid: String, lnames: Dictionary, missed: Array, same_map := true) -> int:
	var li: int = cvs._layer_index_of(src_lid)
	if li >= 0 and same_map:
		return li   # 同一地图：层 ID 就是同一层（跨图层 ID 可能巧合相同，不能直配）
	var nm: String = str(lnames.get(src_lid, ""))
	if nm != "":
		var hits: Array = []
		for i in cvs.layer_count():
			if cvs.layer_name(i) == nm:
				hits.append(i)
		if hits.size() == 1:
			return int(hits[0])
	# 名字已知但目标图没有唯一同名层、或名字未知：都算没匹配上，记下来提示
	var tag: String = nm if nm != "" else src_lid
	if nm != "" and not same_map and _layer_name_count(nm) > 1:
		tag = nm + "（重名）"
	if not missed.has(tag):
		missed.append(tag)
	return 0

## 目标图里与 name 同名的层数（跨图层名匹配的唯一性判定）
func _layer_name_count(nm: String) -> int:
	var n := 0
	for i in cvs.layer_count():
		if cvs.layer_name(i) == nm:
			n += 1
	return n

func _cell_rect(a: Vector2, b: Vector2) -> Rect2i:
	var ca: Vector2i = cvs.root_cell(a)
	var cb: Vector2i = cvs.root_cell(b)
	return Rect2i(Vector2i(mini(ca.x, cb.x), mini(ca.y, cb.y)),
		Vector2i(absi(ca.x - cb.x) + 1, absi(ca.y - cb.y) + 1))
