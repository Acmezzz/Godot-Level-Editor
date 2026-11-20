extends RefCounted
## _undo_history_ctrl：从 src/canvas/editor_canvas.gd 拆出的控制器。宿主状态经 cvs 引用。

var cvs   # 宿主引用

const Constants := preload("res://src/core/constants.gd")
const ContentId := preload("res://src/content/content_id.gd")
const MapFormat := preload("res://src/map/map_format.gd")

func _init(host) -> void:
	cvs = host
func _snapshot() -> String:
	return JSON.stringify(cvs.extract())


func _restore(snapshot) -> void:
	var d = snapshot
	if snapshot is String:
		d = JSON.parse_string(snapshot)
	# 空快照 = extract() 的重建窗口哨兵，恢复它等于清空整图——拒绝
	if d is Dictionary and not (d as Dictionary).is_empty():
		# keep_dirty=true：恢复的是历史状态，内容与磁盘不一致即为脏
		await cvs.load_data(d, cvs.cur_map_name, true, true)


func _push_undo() -> void:
	if cvs.map_root == null or not is_instance_valid(cvs.map_root):
		return
	cvs.undo_stack.append(_snapshot())
	if cvs.undo_stack.size() > cvs.UNDO_MAX:
		cvs.undo_stack.pop_front()
	cvs.redo_stack.clear()

## 恢复是异步的（await load_data 让帧）。恢复进行中再触发 undo/redo，两个恢复流
## 会交错写状态：快照弹错、画布被双重覆盖。恢复期一律拒绝（返回 false）。
var _restoring := false

## 返回是否真的撤销了（空栈时调用方要给「没有可撤销的操作」而不是假反馈）。
## 脏标记与 modified.emit 由 load_data(keep_dirty=true) 统一处理，不再自己置脏。
func undo() -> bool:
	if _restoring or cvs.map_root == null or not is_instance_valid(cvs.map_root) or cvs.undo_stack.is_empty():
		return false
	_restoring = true
	cvs.redo_stack.append(_snapshot())
	await _restore(cvs.undo_stack.pop_back())
	_restoring = false
	return true


func redo() -> bool:
	if _restoring or cvs.map_root == null or not is_instance_valid(cvs.map_root) or cvs.redo_stack.is_empty():
		return false
	_restoring = true
	cvs.undo_stack.append(_snapshot())
	await _restore(cvs.redo_stack.pop_back())
	_restoring = false
	return true


## 实例功能绑定：整段深拷贝写入 functions；实体缺省写空数组，让"清空绑定"也能落盘。
## 场景实例没有功能语义，非空才写（不产冗余键）。
func _functions_field(n: EntityNode) -> Dictionary:
	if not n.is_entity() and n.functions.is_empty():
		return {}
	return {"functions": n.functions.duplicate(true)}

func extract() -> Dictionary:
	if cvs.map_root == null or not is_instance_valid(cvs.map_root):
		return {}   # 重建窗口期（load_data 的 await 一帧）：不产出快照，防 free 后访问
	# 层栈瓦片：tiles = {层id: [[x,y,资产id,ax,ay]...]}（第 3 位是字符串资产 id，
	# 不再写清单数组序——清单重排不会破坏既有地图）
	var tiles := {}
	for li in cvs.layer_tiles.size():
		var tn: TileMapLayer = cvs.layer_tiles[li]
		var lid: String = cvs.layer_id(li)
		if lid == "":
			continue
		var cells := []
		for c in tn.get_used_cells():
			var ac = tn.get_cell_atlas_coords(c)
			var aid: String = cvs.asset_of_source(tn.get_cell_source_id(c))
			if aid == "":
				continue   # source 不属于任何声明资产：不写出坏条目
			cells.append([c.x, c.y, aid, ac.x, ac.y])
		tiles[lid] = cells
	# 碰撞条目对象（v6）：{x, y}，type 缺省省略（solid）、shape 缺省省略（矩形）。
	var ccells := []
	for c in cvs.collision.get_used_cells():
		var cm = cvs._collision_meta.get(c, null)
		var d := {"x": c.x, "y": c.y}
		if cm != null:
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
		var nid := n.asset
		var props: Dictionary = n.props
		var clean := {}
		for k in props.keys():
			if props[k] != null and str(props[k]) != "":
				clean[k] = props[k]
		# 无码的实体实例 → 补发实例码（身份丢失会让内容 ID 前缀漂移，不能留空）；
		# 场景实例永不产码（code 键整个不写）
		var code := n.code
		if n.is_entity() and code == "":
			code = ContentId.new_inst_code()
			n.code = code
		# 以原条目为底：未知键（游戏侧自定义）与编辑器不认识的键都留在原处
		var row: Dictionary = n.raw.duplicate(true)
		row.erase("scene")   # 旧键作废：同一字段两种语义容易混
		row["asset"] = nid
		if n.is_entity():
			row["code"] = code
		else:
			row.erase("code")
		row["layer"] = n.layer_id
		# 浮点格坐标：关掉吸附时可存半格/任意像素位置；保留 3 位小数避免浮点噪声
		var g := n.grid_of_world(n.position)
		row["x"] = snappedf(g.x, 0.001)
		row["y"] = snappedf(g.y, 0.001)
		# transform 缺省整键省略（旧数据没有它就等于缺省形态，读回后行为不变）
		if n.transform_is_default():
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
		olist.append(row)
	var used = Rect2i()
	for tn in cvs.layer_tiles:
		used = used.merge((tn as TileMapLayer).get_used_rect())
	if used.size == Vector2i.ZERO:
		used = Rect2i(Vector2i.ZERO, Vector2i(Constants.DEFAULT_MAP_W, Constants.DEFAULT_MAP_H))
	# 以整个读入的地图为底：游戏侧写进顶层的自定义键原样保留（此前 6 键白名单会蒸发它们）
	var out: Dictionary = cvs.map_data.duplicate(true) if cvs.map_data is Dictionary else {}
	var meta0: Dictionary = out.get("meta", {}) if out.get("meta", {}) is Dictionary else {}
	# 以当前地图 meta 为底（保留游戏侧自定义键），只覆盖编辑器管辖的 name/w/h
	var meta: Dictionary = meta0.duplicate(true)
	if not meta.has("w"):
		meta["w"] = int(used.end.x + 2)
	if not meta.has("h"):
		meta["h"] = int(used.end.y + 2)
	meta["name"] = cvs.cur_map_name
	var sp = cvs._cell_of(cvs.spawn.position)
	out["version"] = MapFormat.VERSION
	out["meta"] = meta
	out["spawn"] = [sp.x, sp.y]
	out["tiles"] = tiles
	out["collision"] = ccells
	out.erase("entities")   # v5：entities 段已并入 objects[]
	out["objects"] = olist
	return out
