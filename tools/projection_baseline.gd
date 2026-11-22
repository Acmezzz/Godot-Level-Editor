extends SceneTree
## 投影/锚点只读基线（发布前 §4 第一条）：逐张记录旧地图的生效投影与每个实例的
## 「数据坐标 → 锚点像素」，供 B1 之后改锚点规则时比对；也可用 --convert 计算
## 「原坐标 + 原锚点规则 → 像素锚点 → 新锚点规则 → 新坐标」，只输出结果，绝不写原图。
##
##   godot --headless --path . --script res://tools/projection_baseline.gd -- <项目目录> [--out=<文件>]
##   godot --headless --path . --script res://tools/projection_baseline.gd -- <项目目录> --convert=<proj> [--out=<文件>]
##
## 输出 JSON：{project, maps: [{name, code, version, projection, projectionSource,
##   topology, gridBasis, tileSize, objects: [{code, asset, x, y, anchor, px}],
##   spawn: {x, y, px}}]}
## 只读：不调用 MapStore.write / 不改任何文件（--out 未给时只打印摘要）。

const MapStore := preload("res://src/map/map_store.gd")
const GridSpace := preload("res://src/canvas/grid_space.gd")

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		print("用法: -- <项目目录> [--out=<文件>] [--convert=<orthogonal|isometric|hexagonal>]")
		quit(2)
		return
	var dir := ""
	var out_path := ""
	var convert := ""
	for raw in args:
		var a := str(raw)
		if a.begins_with("--out="):
			out_path = a.substr(6).strip_edges()
		elif a.begins_with("--convert="):
			convert = a.substr(10).strip_edges()
		elif dir == "":
			dir = a.strip_edges()
	if dir == "" or not DirAccess.dir_exists_absolute(dir):
		print("目录不存在: " + dir)
		quit(2)
		return
	var m := _manifest(dir)
	if m.is_empty():
		print("读不到清单: " + dir)
		quit(2)
		return
	var names := MapStore.list_maps(m)
	var report := {"project": dir, "mode": "convert" if convert != "" else "record",
		"convertTo": convert, "maps": []}
	var total_objects := 0
	for nm in names:
		var data := MapStore.read(m, str(nm))
		if data.is_empty():
			print("跳过读不出的地图: " + str(nm))
			continue
		var row := _record_map(m, str(nm), data, convert)
		total_objects += (row.get("objects", []) as Array).size()
		(report["maps"] as Array).append(row)
	var text := JSON.stringify(report, "  ", true)
	if out_path != "":
		DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		if f == null:
			print("写不出: " + out_path)
			quit(1)
			return
		f.store_string(text)
		f.close()
		print("已写出 %s（%d 图 / %d 实例）" % [out_path, (report["maps"] as Array).size(), total_objects])
	else:
		print(text)
	quit(0)

## 清单：最少只读需要的键（投影解析要 assets、格尺寸要 tileSize）。不校验、不发码。
static func _manifest(dir: String) -> Dictionary:
	var p := dir.path_join("editor/editor_manifest.json")
	if not FileAccess.file_exists(p):
		return {}
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return {}
	var raw = JSON.parse_string(f.get_as_text())
	f.close()
	if not (raw is Dictionary):
		return {}
	var m: Dictionary = raw
	m["_dir"] = dir
	m["_maps_dir"] = dir.path_join("maps")
	return m

static func _record_map(m: Dictionary, name: String, data: Dictionary, convert: String) -> Dictionary:
	var meta: Dictionary = data.get("meta", {}) if data.get("meta", null) is Dictionary else {}
	var ts := GridSpace.tile_size_of(m)
	# 生效投影：地图自己的键优先，缺键沿用项目解析——与 editor_canvas._map_projection 同口径
	var own := str(meta.get("gridProjection", ""))
	var proj := own if own in ["orthogonal", "isometric", "hexagonal"] \
		else GridSpace.project_projection(m)
	var src_kind := "map" if own != "" else "project"
	var basis: Array = meta.get("gridBasis", []) if meta.get("gridBasis", null) is Array else []
	var g := GridSpace.new(ts, proj, basis)
	var topo := GridSpace.parse_topology(meta, proj)
	var row := {"name": name, "code": str(meta.get("code", "")),
		"version": int(data.get("version", 0)),
		"projection": proj, "projectionSource": src_kind,
		"topology": str(topo.get("topology", "quads")),
		"gridBasis": basis, "tileSize": [ts.x, ts.y],
		"objects": [], "spawn": {}}
	var convert_g: GridSpace = null
	if convert != "":
		convert_g = GridSpace.new(ts, convert, basis)
	for o in (data.get("objects", []) as Array):
		if not (o is Dictionary):
			continue
		var od: Dictionary = o
		var x := float(od.get("x", 0.0))
		var y := float(od.get("y", 0.0))
		var decl: Dictionary = _asset_decl(m, str(od.get("asset", "")))
		var anchor := str(decl.get("anchor", "center"))
		var vec := {"code": str(od.get("code", "")), "asset": str(od.get("asset", "")),
			"x": x, "y": y, "anchor": anchor,
			"px": _anchor_px(g, anchor, x, y)}
		if convert_g != null:
			# 显式换算：原坐标原锚点 → 像素锚点 → 新格系反算同锚点 → 新坐标。
			# 只输出结果，调用方据此在副本上验证；本工具永不写原图。
			var c := _reproject(g, convert_g, anchor, x, y)
			vec["converted"] = {"projection": convert, "x": c.x, "y": c.y,
				"pxAfter": _anchor_px(convert_g, anchor, c.x, c.y)}
		(row["objects"] as Array).append(vec)
	var sp = data.get("spawn", null)
	if sp is Array and (sp as Array).size() >= 2:
		var sx := int(sp[0])
		var sy := int(sp[1])
		var spx := g.cell_center_px(Vector2i(sx, sy))
		var srow := {"x": sx, "y": sy, "px": [spx.x, spx.y]}
		if convert_g != null:
			var cs := convert_g.cell_center_px(Vector2i(sx, sy))
			srow["converted"] = {"x": cs.x, "y": cs.y}
		row["spawn"] = srow
	return row

## 资产声明的最小只读查询（只用 kind/shape/anchor；不跑归一化以免发码）。
static func _asset_decl(m: Dictionary, aid: String) -> Dictionary:
	for a in (m.get("assets", []) as Array):
		if a is Dictionary and str((a as Dictionary).get("id", "")) == aid:
			return a
	return {}

## 数据坐标 → 世界锚点像素。口径与 entity_node.world_of_grid 一致（不含 sortAnchor：
## 那只是编辑器排序点，不参与数据锚点）。
static func _anchor_px(g: GridSpace, anchor: String, x: float, y: float) -> Array:
	var u := Vector2(0.5, 0.5)
	if anchor == "top_left":
		u = Vector2.ZERO
	elif anchor == "bottom_center":
		u = Vector2(0.5, 1.0)
	var p: Vector2
	if g.is_hex():
		# 六边：to_px(整数格) 已是格中心，锚点偏移相对格中心（entity_node._hex_anchor_off）
		p = g.to_px(Vector2(x, y)) + (u - Vector2(0.5, 0.5)) * Vector2(g.tile)
	else:
		p = g.to_px(Vector2(x, y) + u)
	return [snappedf(p.x, 0.001), snappedf(p.y, 0.001)]

## 原格系 → 目标格系：保持「锚点像素」不变，反算目标格系下的数据坐标。
static func _reproject(from_g: GridSpace, to_g: GridSpace, anchor: String, x: float, y: float) -> Vector2:
	var p: Vector2
	var u := Vector2(0.5, 0.5)
	if anchor == "top_left":
		u = Vector2.ZERO
	elif anchor == "bottom_center":
		u = Vector2(0.5, 1.0)
	if from_g.is_hex():
		p = from_g.to_px(Vector2(x, y)) + (u - Vector2(0.5, 0.5)) * Vector2(from_g.tile)
	else:
		p = from_g.to_px(Vector2(x, y) + u)
	if to_g.is_hex():
		return to_g.to_continuous_grid(p - (u - Vector2(0.5, 0.5)) * Vector2(to_g.tile))
	return to_g.to_grid(p) - u