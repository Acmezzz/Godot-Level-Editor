extends RefCounted
## _undo_history_ctrl：从 src/canvas/editor_canvas.gd 拆出的控制器。宿主状态经 cvs 引用。

var cvs   # 宿主引用

const BuiltinKinds := preload("res://src/content/builtin_kinds.gd")
const Constants := preload("res://src/core/constants.gd")
const ContentId := preload("res://src/content/content_id.gd")

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

## 返回是否真的撤销了（空栈时调用方要给「没有可撤销的操作」而不是假反馈）。
## 脏标记与 modified.emit 由 load_data(keep_dirty=true) 统一处理，不再自己置脏。
func undo() -> bool:
	if cvs.map_root == null or not is_instance_valid(cvs.map_root) or cvs.undo_stack.is_empty():
		return false
	cvs.redo_stack.append(_snapshot())
	await _restore(cvs.undo_stack.pop_back())
	return true


func redo() -> bool:
	if cvs.map_root == null or not is_instance_valid(cvs.map_root) or cvs.redo_stack.is_empty():
		return false
	cvs.undo_stack.append(_snapshot())
	await _restore(cvs.redo_stack.pop_back())
	return true


## 实例功能绑定：整段深拷贝写入 functions；缺省写空数组，让"清空绑定"也能落盘。
func _functions_field(spr: Sprite2D) -> Dictionary:
	var raw = spr.get_meta("functions", [])
	var arr: Array = raw if raw is Array else []
	return {"functions": arr.duplicate(true)}

func extract() -> Dictionary:
	if cvs.map_root == null or not is_instance_valid(cvs.map_root):
		return {}   # 重建窗口期（load_data 的 await 一帧）：不产出快照，防 free 后访问
	# 层栈瓦片：tiles = {层id: [[x,y,atlas,ax,ay]...]}（替代旧 terrain/decor 双数组）
	var tiles := {}
	for li in cvs.layer_tiles.size():
		var tn: TileMapLayer = cvs.layer_tiles[li]
		var lid: String = cvs.layer_id(li)
		if lid == "":
			continue
		var cells := []
		for c in tn.get_used_cells():
			var ac = tn.get_cell_atlas_coords(c)
			var sid = tn.get_cell_source_id(c)
			cells.append([c.x, c.y, sid, ac.x, ac.y])
		tiles[lid] = cells
	# 碰撞条目带类型/形状（solid+矩形只写 [x,y]——契约缺省值零冗余）
	var ccells := []
	for c in cvs.collision.get_used_cells():
		var cm = cvs._collision_meta.get(c, null)
		if cm != null:
			var ct := str(cm.get("type", "solid"))
			var cs := str(cm.get("shape", ""))
			if cs != "":
				ccells.append([c.x, c.y, ct, cs])
			else:
				ccells.append([c.x, c.y, ct])
		else:
			ccells.append([c.x, c.y])
	var elist := []
	for e in cvs.ents_all():
		var spr := e as Sprite2D
		if spr and spr.has_meta("scene"):
 # props 原样保留（契约是"未知字段忽略"而非"剥离"——白名单会把手工
 # 预留/未来字段在保存时蒸发）。只丢弃空值；字段单值由 UI 控件天然保证。
			var sid := str(spr.get_meta("scene"))
			var props: Dictionary = spr.get_meta("props", {})
			var clean := {}
			for k in props.keys():
				if props[k] != null and str(props[k]) != "":
					clean[k] = props[k]
 # 无码的老实体 → 补发实例码（身份丢失会让内容 ID 前缀漂移，不能留空）
			var code := str(spr.get_meta("code", ""))
			if code == "":
				code = ContentId.new_inst_code()
				spr.set_meta("code", code)
 # 触发区的位置是矩形中心：还原成左上角格坐标，与数据格式（x/y = 左上角）一致
			var cell_pos := Vector2(spr.position.x, spr.position.y)
			if BuiltinKinds.is_builtin(sid):
				cell_pos -= cvs.entity_display_size_of(spr) * 0.5 - Vector2(cvs.tile_px, cvs.tile_px) * 0.5
			elist.append({
				"scene": sid,
 # 分层身份码：实例段 = 唯一身份（丢失会让内容 ID 前缀漂移，必须随快照走）
				"code": code,
				"layer": str(spr.get_meta("layer", "")),
 # 与 _cell_of 一致用 floori——int() 向零截断会让负坐标实体每次保存向 0 漂移
				"x": floori((cell_pos.x - cvs.tile_px / 2.0) / cvs.tile_px),
				"y": floori((cell_pos.y - cvs.tile_px / 2.0) / cvs.tile_px),
				"flip_h": bool(spr.flip_h),
				"props": clean,
			}.merged(_functions_field(spr), true))
	var used = Rect2i()
	for tn in cvs.layer_tiles:
		used = used.merge((tn as TileMapLayer).get_used_rect())
	if used.size == Vector2i.ZERO:
		used = Rect2i(Vector2i.ZERO, Vector2i(Constants.DEFAULT_MAP_W, Constants.DEFAULT_MAP_H))
	var meta0: Dictionary = cvs.map_data.get("meta", {})
	# 以当前地图 meta 为底（保留游戏侧自定义键），只覆盖编辑器管辖的 name/w/h
	var meta: Dictionary = meta0.duplicate(true)
	if not meta.has("w"):
		meta["w"] = int(used.end.x + 2)
	if not meta.has("h"):
		meta["h"] = int(used.end.y + 2)
	meta["name"] = cvs.cur_map_name
	var sp = cvs._cell_of(cvs.spawn.position)
	return {
		"version": 4,   # 须与 map_store.FORMAT_VERSION 一致（此处是字面量；零兼容不升级老图）
		"meta": meta,
		"spawn": [sp.x, sp.y],
		"tiles": tiles,
		"collision": ccells,
		"entities": elist,
	}
