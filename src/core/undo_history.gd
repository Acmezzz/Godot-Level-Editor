extends RefCounted
## _undo_history_ctrl：从 src/canvas/editor_canvas.gd 拆出的控制器（审查 8.3 表）。宿主状态经 alias 引用。

var cvs   # 宿主引用

const BuiltinKinds := preload("res://src/content/builtin_kinds.gd")
## 触发区的实例级属性：不在清单 fields 里，但必须随地图保存
const TRIGGER_PROP_KEYS := ["w", "h", "mode", "event", "require_flag", "once"]

func _init(host) -> void:
	cvs = host
func _snapshot() -> String:
	return JSON.stringify(cvs.extract())


func _restore(snapshot) -> void:
	var d = snapshot
	if snapshot is String:
		d = JSON.parse_string(snapshot)
	if d is Dictionary:
		# keep_dirty=true：恢复的是历史状态，内容与磁盘不一致即为脏（BUG-01）
		cvs.load_data(d, cvs.cur_map_name, true, true)


func _push_undo() -> void:
	if cvs.map_root == null or not is_instance_valid(cvs.map_root):
		return
	cvs.undo_stack.append(_snapshot())
	if cvs.undo_stack.size() > cvs.UNDO_MAX:
		cvs.undo_stack.pop_front()
	cvs.redo_stack.clear()

## 返回是否真的撤销了（P-16：空栈时调用方要给「没有可撤销的操作」而不是假反馈）。
## 脏标记与 modified.emit 由 load_data(keep_dirty=true) 统一处理，不再自己置脏。
func undo() -> bool:
	if cvs.map_root == null or cvs.undo_stack.is_empty():
		return false
	cvs.redo_stack.append(_snapshot())
	_restore(cvs.undo_stack.pop_back())
	return true


func redo() -> bool:
	if cvs.map_root == null or cvs.redo_stack.is_empty():
		return false
	cvs.undo_stack.append(_snapshot())
	_restore(cvs.redo_stack.pop_back())
	return true


## 实体定义层：有 def_id 时输出 {"def": id}，否则空字典（保持旧地图结构不变）。
func _def_field(spr: Sprite2D) -> Dictionary:
	var def_id := str(spr.get_meta("def_id", ""))
	return {"def": def_id} if def_id != "" else {}

## 实例功能绑定：整段深拷贝写入 functions；缺省写空数组，让"清空绑定"也能落盘。
## 新写入只走 functions；def 仅在实体还留着旧 def_id 时由 _def_field 原样带出。
func _functions_field(spr: Sprite2D) -> Dictionary:
	var raw = spr.get_meta("functions", [])
	var arr: Array = raw if raw is Array else []
	return {"functions": arr.duplicate(true)}

func extract() -> Dictionary:
	if cvs.map_root == null or not is_instance_valid(cvs.map_root):
		return {}   # 重建窗口期（load_data 的 await 一帧）：不产出快照，防 free 后访问
	var tcells := []
	for c in cvs.terrain.get_used_cells():
		var ac = cvs.terrain.get_cell_atlas_coords(c)
		var sid = cvs.terrain.get_cell_source_id(c)
		tcells.append([c.x, c.y, sid, ac.x, ac.y])
	var dcells := []
	for c in cvs.decor.get_used_cells():
		var ac2 = cvs.decor.get_cell_atlas_coords(c)
		var sid2 = cvs.decor.get_cell_source_id(c)
		dcells.append([c.x, c.y, sid2, ac2.x, ac2.y])
	# 批次 9：碰撞条目带类型/形状（solid+矩形只写 [x,y]——契约缺省值零冗余）
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
	# 先扫出本图最大实体编号（老图实体可能没 id，保存时自动补号）
	var max_id := 0
	for e in cvs.entities.get_children():
		var spr0 := e as Sprite2D
		if spr0 and spr0.has_meta("scene"):
			var idd := str(spr0.get_meta("ent_id", ""))
			if idd.begins_with("e_"):
				max_id = maxi(max_id, int(idd.substr(2)))
	for e in cvs.entities.get_children():
		var spr := e as Sprite2D
		if spr and spr.has_meta("scene"):
			# A8：props 原样保留（契约是"未知字段忽略"而非"剥离"——白名单会把手工
			# 预留/未来字段在保存时蒸发）。只丢弃空值；字段单值由 UI 控件天然保证。
			var sid := str(spr.get_meta("scene"))
			var props: Dictionary = spr.get_meta("props", {})
			var clean := {}
			for k in props.keys():
				if props[k] != null and str(props[k]) != "":
					clean[k] = props[k]
			# 无 id 的老实体 → 自动补号（引用跨图落点等依赖 id，不能留空）
			var eid := str(spr.get_meta("ent_id", ""))
			if eid == "":
				max_id += 1
				eid = "e_%d" % max_id
				spr.set_meta("ent_id", eid)
			# 触发区的位置是矩形中心：还原成左上角格坐标，与数据格式（x/y = 左上角）一致
			var cell_pos := Vector2(spr.position.x, spr.position.y)
			if BuiltinKinds.is_builtin(sid):
				cell_pos -= cvs.entity_display_size_of(spr) * 0.5 - Vector2(cvs.tile_px, cvs.tile_px) * 0.5
			elist.append({
				"scene": sid,
				"id": eid,
				# B4：与 _cell_of 一致用 floori——int() 向零截断会让负坐标实体每次保存向 0 漂移
				"x": floori((cell_pos.x - cvs.tile_px / 2.0) / cvs.tile_px),
				"y": floori((cell_pos.y - cvs.tile_px / 2.0) / cvs.tile_px),
				"flip_h": bool(spr.flip_h),
				"props": clean,
			}.merged(_def_field(spr), true).merged(_functions_field(spr), true))
	var used = cvs.terrain.get_used_rect()
	if used.size == Vector2i.ZERO:
		used = Rect2i(Vector2i.ZERO, Vector2i(120, 56))
	var meta0: Dictionary = cvs.map_data.get("meta", {})
	# P-09：以当前地图 meta 为底（保留游戏侧自定义键），只覆盖编辑器管辖的 name/w/h
	var meta: Dictionary = meta0.duplicate(true)
	if not meta.has("w"):
		meta["w"] = int(used.end.x + 2)
	if not meta.has("h"):
		meta["h"] = int(used.end.y + 2)
	meta["name"] = cvs.cur_map_name
	var sp = cvs._cell_of(cvs.spawn.position)
	return {
		"version": 3,   # 批次 9：与 FORMAT_VERSION 同步（load_data 的 upgrade 会兜底）
		"meta": meta,
		"spawn": [sp.x, sp.y],
		"bgGroup": str(cvs.map_data.get("bgGroup", "")),
		"terrain": tcells,
		"decor": dcells,
		"collision": ccells,
		"entities": elist,
	}
