extends RefCounted
## E3 / D17：地图尺寸裁剪的纯逻辑（无 UI）。
## 改尺寸的弹窗预览与真正的裁剪必须用同一判据，否则「预览说裁 3 个、实际裁 5 个」。
## 兼容 v7 的三种条目形态：瓦片六元组、碰撞对象与退役数组、摆放物对象。

## 现有条目计数：{tiles, collision, objects}
static func counts(d: Dictionary) -> Dictionary:
	var tiles := 0
	for lid in (d.get("tiles", {}) as Dictionary):
		var cells = (d.get("tiles", {}) as Dictionary)[lid]
		if cells is Array:
			tiles += (cells as Array).size()
	return {"tiles": tiles, "collision": (d.get("collision", []) as Array).size(),
		"objects": (d.get("objects", []) as Array).size()}

const GridSpaceScript := preload("res://src/canvas/grid_space.gd")

static func _keeps_extent(d: Dictionary, nw: int, nh: int) -> bool:
	var meta: Dictionary = d.get("meta", {})
	return meta.has("w") and meta.has("h") and nw >= int(meta.w) and nh >= int(meta.h)

## 扩大时保留原数据。瓦片/碰撞使用拓扑列数，摆放物使用连续基坐标。
static func crop_counts(d: Dictionary, nw: int, nh: int, triangular := false) -> Dictionary:
	var out := {"tiles": 0, "collision": 0, "objects": 0}
	if _keeps_extent(d, nw, nh):
		return out
	var columns := GridSpaceScript.cell_columns(nw, triangular)
	for lid in (d.get("tiles", {}) as Dictionary):
		var cells = (d.get("tiles", {}) as Dictionary)[lid]
		if not (cells is Array):
			continue
		for c in (cells as Array):
			if not (c is Array) or (c as Array).size() < 2:
				continue
			if outside(int((c as Array)[0]), int((c as Array)[1]), columns, nh):
				out.tiles = int(out.tiles) + 1
	for ce in (d.get("collision", []) as Array):
		if ce is Dictionary:
			if outside(int((ce as Dictionary).get("x", 0)), int((ce as Dictionary).get("y", 0)), columns, nh):
				out.collision = int(out.collision) + 1
		elif ce is Array and (ce as Array).size() >= 2:
			if outside(int((ce as Array)[0]), int((ce as Array)[1]), columns, nh):
				out.collision = int(out.collision) + 1
	for o in (d.get("objects", []) as Array):
		if o is Dictionary and outside_float(float((o as Dictionary).get("x", 0.0)),
				float((o as Dictionary).get("y", 0.0)), nw, nh):
			out.objects = int(out.objects) + 1
	return out

static func outside(x: int, y: int, nw: int, nh: int) -> bool:
	return x < 0 or y < 0 or x >= nw or y >= nh

static func outside_float(x: float, y: float, nw: int, nh: int) -> bool:
	return x < 0.0 or y < 0.0 or x >= float(nw) or y >= float(nh)

## 就地裁掉边界外条目（层栈与 meta 其它键不动）。与 crop_counts 同一判据。
static func crop_data(d: Dictionary, nw: int, nh: int, triangular := false) -> void:
	if _keeps_extent(d, nw, nh):
		return
	var columns := GridSpaceScript.cell_columns(nw, triangular)
	var tiles_in = d.get("tiles", null)
	if tiles_in is Dictionary:
		for lid in (tiles_in as Dictionary):
			var cells = (tiles_in as Dictionary)[lid]
			if not (cells is Array):
				continue
			var keep: Array = []
			for c in (cells as Array):
				if c is Array and (c as Array).size() >= 2 \
						and not outside(int((c as Array)[0]), int((c as Array)[1]), columns, nh):
					keep.append(c)
			(tiles_in as Dictionary)[lid] = keep
	var coll_in = d.get("collision", null)
	if coll_in is Array:
		var keep2: Array = []
		for ce in (coll_in as Array):
			var cx := 0
			var cy := 0
			var ok_shape := false
			if ce is Dictionary:
				cx = int((ce as Dictionary).get("x", 0))
				cy = int((ce as Dictionary).get("y", 0))
				ok_shape = true
			elif ce is Array and (ce as Array).size() >= 2:
				cx = int((ce as Array)[0])
				cy = int((ce as Array)[1])
				ok_shape = true
			if ok_shape and not outside(cx, cy, columns, nh):
				keep2.append(ce)
		d["collision"] = keep2
	var objs_in = d.get("objects", null)
	if objs_in is Array:
		var keep3: Array = []
		for o in (objs_in as Array):
			if not (o is Dictionary):
				continue
			if not outside_float(float((o as Dictionary).get("x", 0.0)),
					float((o as Dictionary).get("y", 0.0)), nw, nh):
				keep3.append(o)
		d["objects"] = keep3
