extends RefCounted
## LayerOps：层栈运行时 + 层管理（从 editor_canvas.gd 拆出，宿主 = editor_canvas）


const ContentIdRef := preload("res://src/content/content_id.gd")
const CellGraph := preload("res://src/map/cell_graph.gd")
const MapViewData := preload("res://src/map/map_view_data.gd")
const TileLayerConvert := preload("res://src/map/tile_layer_convert.gd")

var cvs   # editor_canvas 宿主

func _init(c) -> void:
	cvs = c

## 同名转发属性（读写穿透到 cvs，搬动文本零改动）
var map_data:
	get: return cvs.map_data
var map_root:
	get: return cvs.map_root
var layer_tiles:
	get: return cvs.layer_tiles
var layer_ents:
	get: return cvs.layer_ents
var layer_hidden:
	get: return cvs.layer_hidden
var layer_locked:
	get: return cvs.layer_locked
var coll_view:
	get: return cvs.coll_view
var collision:
	get: return cvs.collision
var active_layer:
	get: return cvs.active_layer
	set(v): cvs.active_layer = v
var cur_map_name:
	get: return cvs.cur_map_name

## 同名包装方法（真实实现经 cvs 转发）
func _hint(t: String) -> void:
	cvs._hint(t)
func extract() -> Dictionary:
	return cvs.extract()
func load_data(data: Dictionary, map_name: String, keep_cam := false, keep_dirty := false) -> void:
	await cvs.load_data(data, map_name, keep_cam, keep_dirty)

# —— 图层栈：地图 meta.layers 声明（[{id, name, visible}]，栈序 = 数组序，底→顶） ——
## 层=纯 z 槽只管画画；清单 layers[] 已退役，层词汇逐图声明。
func layers_decl() -> Array:
	var m: Dictionary = map_data.get("meta", {}) if map_data != null else {}
	var L = m.get("layers", null)
	return L if L is Array and not (L as Array).is_empty() else []

func layer_count() -> int:
	return layers_decl().size()

func layer_id(i: int) -> String:
	var L := layers_decl()
	return str((L[i] as Dictionary).get("id", "")) if i >= 0 and i < L.size() else ""

func layer_name(i: int) -> String:
	var L := layers_decl()
	return str((L[i] as Dictionary).get("name", "")) if i >= 0 and i < L.size() else ""

## 层码 → 栈下标；未知返回 -1
func _layer_index_of(lid: String) -> int:
	for i in layer_count():
		if layer_id(i) == lid:
			return i
	return -1

## 碰撞是栈外元层：下标恒 = 栈层数（下拉里排最后）
func collision_index() -> int:
	return layer_count()

func _is_grid_layer(i: int) -> bool:
	return i == collision_index() and collision != null

func _layer_node(i: int) -> TileMapLayer:
	if _is_grid_layer(i):
		return collision
	if i >= 0 and i < layer_tiles.size():
		return layer_tiles[i]
	return null

## 全层摆放物合集（遮挡模型后实例分散在每层 below/YSort/above 三段容器）
func ents_all() -> Array:
	var out := []
	for n in layer_ents:
		var root := n as Node2D
		if root == null or not is_instance_valid(root):
			continue
		out.append_array(_layer_entities_of(root))
	return out

## 一层的三段容器里所有 EntityNode（不含瓦片节点）。
func _layer_entities_of(root: Node2D) -> Array:
	var out: Array = []
	for cname in ["Below", "YSort", "Above"]:
		var box := root.get_node_or_null(NodePath(cname)) as Node2D
		if box == null:
			continue
		for c in box.get_children():
			if c is EntityNode:
				out.append(c)
	return out

## 单层摆放物合集（命中判定/逐层遍历用）。
func _layer_entities(li: int) -> Array:
	if li < 0 or li >= layer_ents.size():
		return []
	return _layer_entities_of(layer_ents[li] as Node2D)

## 摆放物按 zPolicy 入段容器（below/YSort/above，缺省 auto）。
func _place_in_layer(n: EntityNode, li: int) -> void:
	var root := layer_ents[li] as Node2D
	if root == null:
		return
	var box: Node2D = root.get_node_or_null(NodePath("Below")) if n.z_policy == "below" \
		else (root.get_node_or_null(NodePath("Above")) if n.z_policy == "above" \
		else root.get_node_or_null(NodePath("YSort")))
	if box == null:
		box = root
	box.add_child(n)
	# 同层混放提示（作者提示 ⑤ 前半）：层没开 ySort 但该层已有瓦片又有实例 → 状态栏提示一次
	if str(root.get_meta("yhint", "")) == "":
		# 阶段三：「这层有没有瓦片」走缓存（瓦片写入时失效），不再每次放置全层重扫
		var has_tiles: bool = cvs.layer_has_tiles(li)
		var others: Array = _layer_entities_of(root)
		var mixed: bool = has_tiles and others.size() > 1
		if mixed:
			root.set_meta("yhint", "1")
			_hint("层「%s」没开 ySort，瓦片与实例按先后绘制；要交错遮挡请给层声明 ySort: true" \
				% layer_name(li))

## 图层「看得到的那个节点」：碰撞层看 coll_view（红块），其余看数据节点本身。
## 可见性/隐藏一律作用在这个节点上，保证所有图层的显示逻辑走同一条路。
func _layer_display_node(i: int) -> Node2D:
	if _is_grid_layer(i):
		return coll_view
	if i >= 0 and i < layer_ents.size():
		return layer_ents[i]
	return null

## 设置图层可见/锁定；隐藏 = 该层瓦片与实体一起隐（视觉遮挡，锁定阻止编辑写入）
## 编辑态按**层码**存档（E04）：重排/删除层后下标会变，按 id 存才能跟着层走。
func set_layer_hidden(i: int, now_hidden: bool) -> void:
	layer_hidden[_layer_key(i)] = now_hidden
	_apply_layer_shown(i)
	cvs.vis_rev += 1   # 可见集合变了：ents_shown() 的缓存必须重算（P01）
	cvs.queue_redraw()

## 真节点显隐：数据节点 + 实体容器 + 碰撞可视（单点应用，载入/重排复用）
func _apply_layer_shown(i: int) -> void:
	var vis := is_layer_visible(i)
	if _is_grid_layer(i):
		if coll_view:
			coll_view.visible = vis
		return
	if i >= 0 and i < layer_tiles.size():
		# B3 三角拓扑：数据节点常隐，可见性由自绘视图表达（同一 vis）
		var tri: bool = i < cvs.tri_views.size() and cvs.tri_views[i] != null
		(layer_tiles[i] as TileMapLayer).visible = vis and not tri
		if tri:
			(cvs.tri_views[i] as Node2D).visible = vis
		if i < layer_ents.size():
			(layer_ents[i] as Node2D).visible = vis

## 图层当前是否可见（未隐藏）。所有图层默认可见——包括碰撞层：用户明确要求
## 开图就能看到碰撞（整图染红是可接受的代价）。显隐只由 layer_hidden 记录决定。
func is_layer_visible(i: int) -> bool:
	var k := _layer_key(i)
	if layer_hidden.has(k):
		return not bool(layer_hidden[k])
	return true

## 层码键：层栈内用层 id，碰撞元层用固定串（层重排后仍指向同一层）
func _layer_key(i: int) -> String:
	if _is_grid_layer(i):
		return "_collision"
	return layer_id(i) if i >= 0 and i < layer_count() else "_none%d" % i

func set_layer_locked(i: int, locked: bool) -> void:
	layer_locked[_layer_key(i)] = locked

func is_layer_locked(i: int) -> bool:
	return bool(layer_locked.get(_layer_key(i), false))
# —— 层管理：新建/删除/上下移（先 extract 快照 → 在快照上改 → load_data 重建） ——
## 顺序是硬约束：extract 按节点下标取瓦片、按声明序取层码，两者必须对齐——
## 不能「先改活体 meta 再 extract 反向同步」（会串层/丢瓦片）。
## 撤销快照由 push_undo 在改动前压栈；重建窗口期（extract 返回 {}）放弃操作。
## 新层默认插到栈顶之下——新建即可画前景遮挡。
func layer_add(name: String) -> void:
	if map_root == null or not is_instance_valid(map_root):
		return
	cvs.push_undo()
	var snap := extract()
	if snap.is_empty():
		return
	var meta: Dictionary = snap.get("meta", {})
	var L: Array = meta.get("layers", [])
	var entry := {"id": ContentIdRef.new_inst_code(), "name": name if name != "" else "新层", "visible": true}
	if L.size() >= 2:
		L.insert(L.size() - 1, entry)
	else:
		L.append(entry)
	meta["layers"] = L
	snap["meta"] = meta
	await _load_snap_layers(snap, layer_id(active_layer))

## 删层 = 删内容：快照上摘掉层声明，该层瓦片与 objects 条目一并过滤（撤销可回）。
## 拒绝时静默返回；调用方（层管理 UI）负责给状态栏反馈。
func layer_del(i: int) -> void:
	if map_root == null or not is_instance_valid(map_root) or i < 0 or i >= layer_count():
		return
	if layer_count() <= 1:
		return
	var snap := extract()
	if snap.is_empty():
		return
	var next := without_layer(snap, i)
	cvs.push_undo()
	await _load_snap_layers(next, layer_id(active_layer))

static func without_layer(snapshot: Dictionary, i: int) -> Dictionary:
	var snap := snapshot.duplicate(true)
	var meta: Dictionary = snap.get("meta", {})
	var L: Array = meta.get("layers", [])
	var lid: String = L[i].id
	CellGraph.detach_layer(CellGraph.graph_of(meta), lid, MapViewData.layer_transform_of(L[i]))
	L.remove_at(i)
	meta["layers"] = L
	snap["meta"] = meta
	var tiles: Dictionary = snap.get("tiles", {})
	tiles.erase(lid)
	snap["tiles"] = tiles
	var keep := []
	for o in (snap.get("objects", []) as Array):
		if o is Dictionary and str((o as Dictionary).get("layer", "")) != lid:
			keep.append(o)
	snap["objects"] = keep
	return snap

func layer_rename(i: int, name: String) -> void:
	if map_root == null or not is_instance_valid(map_root):
		return
	var L := layers_decl()
	if i < 0 or i >= L.size() or str(name) == "":
		return
	# 快照先行（契约 1）：只改 name 也走同一纪律，防止照抄成改 id/顺序时串层
	cvs.push_undo()
	var snap := extract()
	if snap.is_empty():
		return
	var meta: Dictionary = snap.get("meta", {})
	var SL: Array = (meta.get("layers", []) as Array).duplicate(true)
	if i < 0 or i >= SL.size():
		return
	(SL[i] as Dictionary)["name"] = str(name)
	meta["layers"] = SL
	snap["meta"] = meta
	await _load_snap_layers(snap, layer_id(active_layer))

## 层混合模式（v7）：mix 缺省省略（erase），add/mul 写盘。快照先行，与 layer_rename 同纪律。
## 值未变直接返回（幂等）——控件回填不产生幽灵撤销步。
func layer_set_blend(i: int, blend: String) -> void:
	if map_root == null or not is_instance_valid(map_root):
		return
	if blend != "mix" and blend != "add" and blend != "mul":
		return
	var L := layers_decl()
	if i < 0 or i >= L.size():
		return
	if str(blend) == str((L[i] as Dictionary).get("blend", "mix")):
		return
	cvs.push_undo()
	var snap := extract()
	if snap.is_empty():
		return
	var meta: Dictionary = snap.get("meta", {})
	var SL: Array = (meta.get("layers", []) as Array).duplicate(true)
	if i < 0 or i >= SL.size():
		return
	if blend == "mix":
		(SL[i] as Dictionary).erase("blend")
	else:
		(SL[i] as Dictionary)["blend"] = blend
	meta["layers"] = SL
	snap["meta"] = meta
	await _load_snap_layers(snap, layer_id(active_layer))

func layer_move(i: int, dir: int) -> void:
	if map_root == null or not is_instance_valid(map_root):
		return
	var L := layers_decl()
	var nj := i + dir
	if i < 0 or i >= L.size() or nj < 0 or nj >= L.size():
		return
	cvs.push_undo()
	var snap := extract()
	if snap.is_empty():
		return
	var active_id := layer_id(active_layer)
	var meta: Dictionary = snap.get("meta", {})
	var SL: Array = meta.get("layers", [])
	var tmp = SL[i]
	SL[i] = SL[nj]
	SL[nj] = tmp
	meta["layers"] = SL
	snap["meta"] = meta
	await _load_snap_layers(snap, active_id)

## 运行时初始可见（差分视图用）；编辑视图显隐走 set_layer_hidden，两回事。
func layer_set_visible(i: int, v: bool) -> void:
	if map_root == null or not is_instance_valid(map_root):
		return
	var L := layers_decl()
	if i < 0 or i >= L.size():
		return
	# 快照先行（同 layer_rename：只改 visible 也走同一纪律）
	cvs.push_undo()
	var snap := extract()
	if snap.is_empty():
		return
	var meta: Dictionary = snap.get("meta", {})
	var SL: Array = (meta.get("layers", []) as Array).duplicate(true)
	if i < 0 or i >= SL.size():
		return
	(SL[i] as Dictionary)["visible"] = v
	meta["layers"] = SL
	snap["meta"] = meta
	await _load_snap_layers(snap, layer_id(active_layer))

func layer_set_tile_grid(i: int, spec: Dictionary) -> String:
	if i < 0 or i >= layer_count() or not cvs.is_map_ready() or cvs.doc_busy:
		return "地图或图层不可用。"
	var snapshot := extract()
	if snapshot.is_empty():
		return "地图重建中，请稍后再试。"
	var lid := layer_id(i)
	if not snapshot.get("tiles", {}).get(lid, []).is_empty():
		return "已有瓦片的图层不能直接切换格系，请使用空图层。"
	var row: Dictionary = snapshot.meta.layers[i]
	if row.get("tileGrid", {}) == spec:
		return ""
	if not spec.is_empty():
		var checked := GridSpace.resolve_tile_layer({"tileGrid": spec}, cvs.manifest, cvs.grid)
		if not checked.issues.is_empty():
			return str(checked.issues[0].message)
		row["tileGrid"] = spec.duplicate(true)
	else:
		row.erase("tileGrid")
	cvs.push_undo()
	await _load_snap_layers(snapshot, layer_id(active_layer))
	return ""

## Builds the exact document shown in the migration preview, without changing the canvas.
func prepare_tile_layer_copy(lid: String, title: String, spec: Dictionary, by_center: bool) -> Dictionary:
	var i := _layer_index_of(lid)
	if i < 0 or not cvs.is_map_ready() or cvs.doc_busy:
		return {"error": "地图或图层不可用。"}
	if title.is_empty() or layers_decl().any(func(row): return row.get("name", "") == title):
		return {"error": "请填写未使用的新图层名。"}
	var snapshot := extract()
	if snapshot.is_empty():
		return {"error": "地图重建中，请稍后再试。"}
	var rows: Array = snapshot.get("tiles", {}).get(lid, [])
	if rows.is_empty():
		return {"error": "源图层没有瓦片。"}
	var decl := {} if spec.is_empty() else {"tileGrid": spec}
	var resolved := GridSpace.resolve_tile_layer(decl, cvs.manifest, cvs.grid)
	if not resolved.issues.is_empty():
		return {"error": str(resolved.issues[0].message)}
	var source: GridSpace = cvs.tile_grid_for_layer(i)
	var target: GridSpace = resolved.grid
	var size := Vector2i(int(snapshot.meta.get("w", 1)), int(snapshot.meta.get("h", 1)))
	var plan := TileLayerConvert.plan(rows, source, target, size, by_center)
	if plan.outside > 0 or plan.collisions > 0:
		return plan
	var id := ContentIdRef.new_inst_code()
	while _layer_index_of(id) >= 0:
		id = ContentIdRef.new_inst_code()
	var original: Dictionary = snapshot.meta.layers[i]
	for key in ["offset", "scale", "parallax", "blend", "ySort", "visible"]:
		if original.has(key):
			decl[key] = original[key]
	decl.merge({"id": id, "name": title})
	snapshot.meta.layers.insert(i + 1, decl)
	snapshot.tiles[id] = plan.rows
	return {"snapshot": snapshot, "id": id, "count": rows.size(), "moved": plan.moved,
		"source": map_data, "revision": cvs.map_rev}

func apply_tile_layer_copy(plan: Dictionary) -> bool:
	if not plan.has("snapshot") or not cvs.is_map_ready() or cvs.doc_busy \
			or not is_same(plan.source, map_data) or plan.revision != cvs.map_rev:
		return false
	cvs.push_undo()
	await _load_snap_layers(plan.snapshot, plan.id)
	return true

## 层参数写回（R-04 控件批）：快照先行 → 改 meta.layers[i] 单键（缺省整键省略）→ 整图重建。
## ySort 改层容器结构（y-sorted 父），parallax/offset/scale 只改容器变换——统一走重建最省心。
func layer_set_param(i: int, key: String, v) -> void:
	if map_root == null or not is_instance_valid(map_root):
		return
	var L := layers_decl()
	if i < 0 or i >= L.size():
		return
	# 快照先行（同 layer_set_visible：改层参数走同一纪律）
	cvs.push_undo()
	var snap := extract()
	if snap.is_empty():
		return
	var meta: Dictionary = snap.get("meta", {})
	var SL: Array = (meta.get("layers", []) as Array).duplicate(true)
	if i < 0 or i >= SL.size():
		return
	match key:
		"ySort":
			if bool(v):
				(SL[i] as Dictionary)["ySort"] = true
			else:
				(SL[i] as Dictionary).erase("ySort")   # 关 ySort = 回到层内既定顺序（E11）
		"parallax":
			var pv := float(v)
			if is_zero_approx(pv - 1.0):
				(SL[i] as Dictionary).erase("parallax")
			else:
				(SL[i] as Dictionary)["parallax"] = pv
		"offset":
			var ov := v as Vector2
			if is_zero_approx(ov.x) and is_zero_approx(ov.y):
				(SL[i] as Dictionary).erase("offset")
			else:
				(SL[i] as Dictionary)["offset"] = [ov.x, ov.y]
		"scale":
			var sv := float(v)
			# 非正缩放 = 层塌成点/镜像翻转：坐标逆变换退化（除零），与校验页同口径拒绝
			if sv <= 0.0:
				return
			if is_zero_approx(sv - 1.0):
				(SL[i] as Dictionary).erase("scale")
			else:
				(SL[i] as Dictionary)["scale"] = sv
		_:
			return
	meta["layers"] = SL
	snap["meta"] = meta
	await _load_snap_layers(snap, layer_id(active_layer))

## 层操作收尾：按新快照重建，激活层跟随身份（同码层下标，层没了落最底层）。
func _load_snap_layers(snap: Dictionary, active_id: String) -> void:
	await load_data(snap, cur_map_name, true, true)
	var ni := _layer_index_of(active_id)
	active_layer = ni if ni >= 0 else 0
