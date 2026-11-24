extends "res://tests/_suite_base.gd"
## B1-2：显式投影转换——实例/出生点按锚点换算到新格系（像素位置不变），
## 瓦片/碰撞保留原格号并计入 manual；支持显式添加、更换和移除 gridBasis。

const MapConvert := preload("res://src/map/map_convert.gd")
const GridSpaceScript := preload("res://src/canvas/grid_space.gd")
const MapStore := preload("res://src/map/map_store.gd")
const Edge := preload("res://src/map/edge_ref.gd")
const Audit := preload("res://src/project/project_audit.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const ClonePlan := preload("res://src/content/clone_plan.gd")

const TMP := "user://test_map_convert_tmp"

func _wipe() -> void:
	if not DirAccess.dir_exists_absolute(TMP):
		return
	for f in DirAccess.get_files_at(TMP.path_join("maps")):
		DirAccess.remove_absolute(TMP.path_join("maps").path_join(str(f)))
	DirAccess.remove_absolute(TMP.path_join("maps"))
	for f in DirAccess.get_files_at(TMP.path_join("content/route")):
		DirAccess.remove_absolute(TMP.path_join("content/route").path_join(str(f)))
	DirAccess.remove_absolute(TMP.path_join("content/route"))
	DirAccess.remove_absolute(TMP.path_join("content"))
	DirAccess.remove_absolute(TMP)

func _manifest() -> Dictionary:
	return {"tileSize": 16, "assets": [
		{"id": "tree", "kind": "entity", "anchor": "bottom_center"},
		{"id": "rock", "kind": "entity"},   # 缺 anchor = center
	]}

func _map(proj: String) -> Dictionary:
	var d := {"version": 7, "meta": {"name": "m", "code": "M001", "w": 16, "h": 16}, "tiles": {}, "objects": [], "spawn": [2, 2]}
	if proj != "orthogonal":
		d.meta["gridProjection"] = proj
	return d

## 正交 → 等距：实例的锚点像素在转换前后完全相同（数据坐标变了，世界位置没变）
func test_ortho_to_iso_keeps_anchor_pixels() -> void:
	var d := _map("orthogonal")
	(d.objects as Array).append({"code": "E1", "asset": "tree", "x": 4, "y": 6})
	(d.objects as Array).append({"code": "E2", "asset": "rock", "x": 3, "y": 2})
	var p := MapConvert.plan(d, _manifest(), "isometric")
	ok(bool(p.get("ok", false)), "正交 → 等距可转换：%s" % str(p.get("error", "")))
	eq(str(p.get("projection", "")), "isometric", "目标投影写入计划")
	var doc: Dictionary = p.get("document", {})
	eq(str((doc.meta as Dictionary).get("gridProjection", "")), "isometric", "document.meta 已换投影")
	var src_g = GridSpaceScript.new(Vector2i(16, 16), "orthogonal")
	var dst_g = GridSpaceScript.new(Vector2i(16, 16), "isometric")
	var rows: Array = doc.get("objects", [])
	# tree = bottom_center：(4,6) → 像素 (4.5,7)*16 = (72,112)
	var t_row: Dictionary = rows[0]
	var t_new := Vector2(float(t_row.x), float(t_row.y))
	var t_px: Vector2 = dst_g.to_px(t_new + Vector2(0.5, 1.0))
	ok(t_px.distance_to(Vector2(72, 112)) < 0.01, "树锚点像素保持 (72,112)，实得 %s" % str(t_px))
	ok(t_new.distance_to(Vector2(4, 6)) > 0.01, "数据坐标确实变了（等距非恒等），实得 %s" % str(t_new))
	# rock = center：(3,2) → (3.5,2.5)*16 = (56,40)
	var r_row: Dictionary = rows[1]
	var r_px: Vector2 = dst_g.to_px(Vector2(float(r_row.x), float(r_row.y)) + Vector2(0.5, 0.5))
	ok(r_px.distance_to(Vector2(56, 40)) < 0.01, "石头锚点像素保持 (56,40)，实得 %s" % str(r_px))
	ok(src_g.to_px(Vector2(4, 6) + Vector2(0.5, 1.0)).distance_to(Vector2(72, 112)) < 0.01,
		"原图坐标就是换算前的位置")

## 往返：正交 → 等距 → 正交，数据坐标回到原值（累积误差 < 0.01 格）
func test_roundtrip_returns_coordinates() -> void:
	var d := _map("orthogonal")
	(d.objects as Array).append({"code": "E1", "asset": "rock", "x": 5.25, "y": 1.75})
	var p1 := MapConvert.plan(d, _manifest(), "isometric")
	ok(bool(p1.get("ok", false)), "第一跳成功")
	var p2 := MapConvert.plan(p1.document, _manifest(), "orthogonal")
	ok(bool(p2.get("ok", false)), "第二跳成功")
	var row: Dictionary = ((p2.document as Dictionary).objects as Array)[0]
	ok(absf(float(row.x) - 5.25) < 0.01, "x 往返回到 5.25，实得 %s" % str(row.x))
	ok(absf(float(row.y) - 1.75) < 0.01, "y 往返回到 1.75，实得 %s" % str(row.y))

## 出生点是格号不是连续点：换算 = 原格中心像素 → 目标格系按格拾取。
func test_spawn_uses_cell_center() -> void:
	var d := _map("orthogonal")
	d.spawn = [3, 5]
	var p := MapConvert.plan(d, _manifest(), "isometric")
	ok(bool(p.get("ok", false)), "出生点可转换")
	var src_g = GridSpaceScript.new(Vector2i(16, 16), "orthogonal")
	var dst_g = GridSpaceScript.new(Vector2i(16, 16), "isometric")
	var sp: Array = (p.document as Dictionary).get("spawn", [])
	eq(sp.size(), 2, "出生点仍是两个分量")
	var src_px: Vector2 = src_g.cell_center_px(Vector2i(3, 5))
	var dst_px: Vector2 = dst_g.cell_center_px(Vector2i(int(sp[0]), int(sp[1])))
	eq(Vector2i(int(sp[0]), int(sp[1])), dst_g.pick_cell(src_px), "目标格 = 原出生点像素所在格")
	ok(src_px.distance_to(dst_px) <= float(dst_g.cell_max()),
		"格中心偏移不超过一格：%s vs %s" % [str(src_px), str(dst_px)])

func test_out_of_bounds_spawn_and_new_edges_on_the_frozen_copy() -> void:
	_wipe()
	var d := _map("orthogonal")
	d.spawn = [5, 3]
	var local_edge := Edge.value_of("M001", Vector2i(3, 3), Vector2i(4, 4))
	var remote_edge := Edge.value_of("OTHER", Vector2i(3, 3), Vector2i(4, 4))
	var already_invalid := Edge.value_of("", Vector2i(2, 2), Vector2i(8, 8))
	var m := _manifest()
	m.merge({"_dir": TMP, "_maps_dir": TMP.path_join("maps"), "contentDir": "content"})
	m.functions = {"route": {"name": "Route", "code": "ROUT", "steps": true, "fields": [
		{"id": "next", "code": "NEXT", "kind": "choice", "source": "content:route", "contentMapContext": "inherit"}]}}
	m.steps = {"walk": {"name": "Walk", "code": "WALK", "fields": [
		{"id": "edge", "code": "EDGE", "type": "edge_ref"},
		{"id": "source_edge", "code": "SRC1", "type": "edge_ref"}]}}
	m.assets[0].fields = [
		{"id": "local", "type": "edge_ref"}, {"id": "remote", "type": "edge_ref"},
		{"id": "broken", "type": "edge_ref"}, {"id": "untyped", "type": "record"}]
	d.meta.layers = [{"id": "L1", "name": "Instances", "visible": true}]
	d.objects = [{"code": "E1", "asset": "tree", "x": 3, "y": 3, "layer": "L1", "props": {
		"local": local_edge, "remote": remote_edge, "broken": already_invalid, "untyped": local_edge}}]
	var bounded := MapConvert.plan(d, m, "isometric")
	eq(bounded.document.spawn, [9, 0], "等距出生点越界移到界内")
	ok(str(bounded.warnings).contains("出生点换算后越界"), "预览解释出生点变化")
	d.meta.gridProjection = "hexagonal"
	d.objects[0].functions = [{"fn": "ROUT", "content": "local"}, {"fn": "ROUT", "content": "shared"}]
	var local := {"function": "ROUT", "steps": [{"step": "WALK", "fields": {"EDGE": local_edge}}]}
	var shared := {"function": "ROUT", "scope": "project", "fields": {"NEXT": "next"}, "steps": [{"step": "WALK", "fields": {
		"EDGE": Edge.value_of("", Vector2i(3, 3), Vector2i(4, 4)), "SRC1": local_edge}}]}
	ok(MapStore.write(m, "src", d) and ContentStore.write(m, "route", "shared", shared), "write source and shared flow")
	ok(ContentStore.write(m, "route", "next", {"function": "ROUT", "scope": "project",
		"steps": [{"step": "WALK", "fields": {"EDGE": Edge.value_of("", Vector2i(3, 3), Vector2i(4, 4))}}]}),
		"write a downstream flow with a local edge")
	var converted := MapConvert.plan(d, m, "orthogonal")
	var prep := MapStore.prepare_duplicate(m, "src", "dst", converted.document,
		{ClonePlan.content_key("route", "local"): local})
	ok(prep.has("plan"), "冻结待写的副本及暂存流程：" + str(prep.get("error", "")))
	if not prep.has("plan"):
		_wipe()
		return
	var report := Audit.projection_copy_impacts(m, prep.plan.targets, converted.source_grid)
	var paths := "\n".join(report.added)
	eq(report.added.size(), 4, "只报告副本摆放物、暂存流程副本与共享流程链的新问题：" + paths)
	ok(paths.contains(".local") and paths.contains("route/shared.steps[0].edge")
		and paths.contains("route/next.steps[0].edge")
		and not paths.contains("source_edge") and not paths.contains(".remote"), "按真正的副本身份区别本图与源图")
	ok(not FileAccess.file_exists(MapStore.path_for(m, "dst")), "检查没有发布任何地图")
	eq(MapStore.apply_duplicate(prep.plan), "", "发布刚检查的冻结副本")
	var copy := MapStore.read(m, "dst")
	eq(copy.objects[0].props.local.map, copy.meta.code, "显式本图格边随整图副本")
	eq(copy.objects[0].props.local.edge, local_edge.edge, "需人工修复的边身份保留")
	eq(MapStore.read(m, "src").objects[0].props.local.map, "M001", "源图不变")
	_wipe()

## 瓦片/碰撞保留原格号，并逐类计入 manual（格系无唯一对应）
func test_tiles_and_collision_reported_manual() -> void:
	var d := _map("orthogonal")
	d.tiles = {"L1": [[1, 1, "A", 0, 0, 0], [2, 1, "A", 0, 0, 0]]}
	d.collision = [{"x": 1, "y": 1}, {"x": 2, "y": 3}]
	var p := MapConvert.plan(d, _manifest(), "hexagonal")
	ok(bool(p.get("ok", false)), "六边也可转换：%s" % str(p.get("error", "")))
	var manual: Array = p.get("manual", [])
	eq(manual.size(), 2, "瓦片与碰撞各一条待核对")
	eq(str((manual[0] as Dictionary).get("kind", "")), "tiles", "第一条 = 瓦片")
	eq(int((manual[0] as Dictionary).get("count", 0)), 2, "瓦片 2 格")
	eq(str((manual[1] as Dictionary).get("kind", "")), "collision", "第二条 = 碰撞")
	eq(int((manual[1] as Dictionary).get("count", 0)), 2, "碰撞 2 格")
	# 原样保留（不猜换算）
	eq((p.document as Dictionary).tiles, d.tiles, "瓦片段原样保留")
	eq((p.document as Dictionary).collision, d.collision, "碰撞段原样保留")

## 拒绝相同格空间、不可逆基、六边加三角与非法目标。
func test_rejects_invalid_targets() -> void:
	var d := _map("orthogonal")
	var same := MapConvert.plan(d, _manifest(), "orthogonal")
	ok(not bool(same.get("ok", true)), "同投影拒绝")
	ok(str(same.get("error", "")).contains("相同"), "说明原因")
	var bad := MapConvert.plan(d, _manifest(), "bogus")
	ok(not bool(bad.get("ok", true)), "非法投影名拒绝")
	var basis_map := _map("orthogonal")
	basis_map.meta["gridBasis"] = [[32, 8], [0, 24]]
	var bm := MapConvert.plan(basis_map, _manifest(), "orthogonal", [[32.0, 8.0], [0.0, 24.0]])
	ok(not bool(bm.get("ok", true)), "相同基向量不做空转换")
	var singular := MapConvert.plan(basis_map, _manifest(), "orthogonal", [[2, 3], [4, 6]])
	ok(not singular.ok and singular.error.contains("gridBasis"), "给出不可逆基向量的字段名")
	var tri := _map("isometric")
	tri.meta["gridTopology"] = "triangles"
	var tm := MapConvert.plan(tri, _manifest(), "hexagonal")
	ok(not bool(tm.get("ok", true)), "三角拓扑 + 六边拒绝")

func test_changing_and_removing_basis_preserves_anchor_and_grid_reference_baseline() -> void:
	var m := _manifest()
	m.assets[0].fields = [{"id": "edge", "type": "edge_ref"}]
	var d := _map("hexagonal")
	d.meta.gridBasis = [[16, 4], [0, 12]]
	d.spawn = [2, 2]
	d.objects = [{"code": "TREE", "asset": "tree", "x": 3, "y": 3, "props": {
		"edge": Edge.value_of("", Vector2i(3, 3), Vector2i(3, 4))}}]
	var replaced := MapConvert.plan(d, m, "hexagonal", [[24, 6], [3, 18]])
	ok(replaced.ok, "不改投影亦可更换基向量")
	eq(replaced.document.meta.gridBasis, [[24, 6], [3, 18]], "副本写新的基向量")
	var restored := MapConvert.plan(d, m, "hexagonal")
	ok(restored.ok and not restored.document.meta.has("gridBasis"), "取消双基恢复预设")
	for plan in [replaced, restored]:
		var grid: GridSpace = GridSpaceScript.resolve(plan.document.meta, m).grid
		var row: Dictionary = plan.document.objects[0]
		var anchor := grid.object_anchor_px(Vector2(row.x, row.y), Vector2(0.5, 1.0))
		ok(anchor.distance_to(Vector2(56, 62)) < 0.02, "保存局部锚点像素位置")
		eq(plan.document.spawn, [grid.pick_cell(Vector2(40, 40)).x, grid.pick_cell(Vector2(40, 40)).y],
			"出生点从原斜基的格中心拾取")
	# 从真正六边形转到斜基时，六边形斜向同边引用才成为新问题。
	var hex := d.duplicate(true)
	hex.meta.erase("gridBasis")
	hex.objects[0].props.edge = Edge.value_of("", Vector2i(3, 3), Vector2i(4, 4))
	var to_basis := MapConvert.plan(hex, m, "hexagonal", d.meta.gridBasis)
	var report := Audit.projection_copy_impacts(m,
		[{"kind": "map", "map_data": to_basis.document, "id": "copy"}], to_basis.source_grid)
	eq(report.added.size(), 1, "审计应先从反事实基线移除副本的新基向量")

## 缺 meta.gridProjection 时按项目解析取当前投影（任一瓦片资产声明非正交）
func test_current_projection_falls_back_to_project() -> void:
	var d := _map("orthogonal")
	eq(MapConvert.current_projection(d, _manifest()), "orthogonal", "清单无声明 = 正交")
	var iso_manifest := _manifest()
	(iso_manifest.assets as Array).append({"id": "t", "kind": "scene", "shape": "tile", "gridProjection": "isometric"})
	eq(MapConvert.current_projection(d, iso_manifest), "isometric", "缺键沿用项目解析")
	# 缺键 + 项目已等距：目标是正交 → 允许，并写出显式键
	var p := MapConvert.plan(d, iso_manifest, "orthogonal")
	ok(bool(p.get("ok", false)), "缺键图可按项目投影算出当前值再转：%s" % str(p.get("error", "")))
	eq(str((p.document as Dictionary).meta.get("gridProjection", "")), "orthogonal", "副本显式写目标投影")

func test_hex_rounding_across_staggered_row_does_not_move_anchor_half_a_cell() -> void:
	var d := _map("orthogonal")
	d.objects = [{"code": "ROCK", "asset": "rock", "x": 4.5, "y": 1.4998}]
	var p := MapConvert.plan(d, _manifest(), "hexagonal")
	ok(p.ok, "正交到六边转换成功")
	var row: Dictionary = p.document.objects[0]
	var hex := GridSpaceScript.new(Vector2i(16, 16), "hexagonal")
	var anchor := hex.object_anchor_px(Vector2(row.x, row.y), Vector2(0.5, 0.5))
	eq(row.y, 2.0, "目标坐标舍入后跨到偶数行")
	ok(anchor.distance_to(Vector2(80, 31.9968)) < 0.01, "换行保留横向锚点")

## 资产不在清单：仍按中心锚点换算，只记警告不中断
func test_missing_asset_warns_but_converts() -> void:
	var d := _map("orthogonal")
	(d.objects as Array).append({"code": "E9", "asset": "ghost", "x": 1, "y": 1})
	var p := MapConvert.plan(d, _manifest(), "isometric")
	ok(bool(p.get("ok", false)), "缺资产不阻断转换")
	eq((p.get("warnings", []) as Array).size(), 1, "给一条警告")
	ok(str(((p.get("warnings", []) as Array)[0])).contains("ghost"), "警告里点名资产")

## 端到端：转换计划交给 duplicate_map 另存成新图——原图不动、副本换码换投影、
## 实例像素锚点与源图一致（C2 管线发行新实例码，坐标由转换计划给出）
func test_saved_copy_differs_from_source() -> void:
	_wipe()
	var m := {"_dir": TMP, "_maps_dir": TMP.path_join("maps"), "tileSize": 16, "assets": [
		{"id": "tree", "kind": "entity", "anchor": "bottom_center"}]}
	var src := _map("orthogonal")
	src.meta["layers"] = [{"id": "L1", "name": "资产层", "visible": true}]
	(src.objects as Array).append({"code": "E1", "asset": "tree", "x": 4, "y": 6})
	(src.objects as Array).append({"code": "E2", "asset": "tree", "x": 9, "y": 1})
	ok(MapStore.write(m, "src", src), "源图落盘")
	var p := MapConvert.plan(src, m, "isometric")
	ok(bool(p.get("ok", false)), "转换计划成功")
	var doc: Dictionary = p.document
	doc.meta.name = "src"
	doc.meta.erase("code")
	var conflicts: Array = []
	var err: String = MapStore.duplicate_map(m, "src", "copy", conflicts, doc)
	eq(err, "", "另存成功：%s%s" % [err, str(conflicts)])
	var copy: Dictionary = MapStore.read(m, "copy")
	ok(copy.size() > 0, "副本可读回")
	eq(str((copy.meta as Dictionary).get("gridProjection", "")), "isometric", "副本写目标投影")
	eq(str((copy.meta as Dictionary).get("name", "")), "copy", "副本用新名")
	var src_code := str((src.meta as Dictionary).get("code", ""))
	ok(str((copy.meta as Dictionary).get("code", "")) != src_code, "副本重发地图码")
	var orig: Dictionary = MapStore.read(m, "src")
	ok(not (orig.meta as Dictionary).has("gridProjection"), "原图投影未变（正交缺省不写键）")
	eq(((orig.objects as Array)[0] as Dictionary).get("x"), 4, "原图坐标未变")
	var dst_g = GridSpaceScript.new(Vector2i(16, 16), "isometric")
	var src_g = GridSpaceScript.new(Vector2i(16, 16), "orthogonal")
	for i in 2:
		var o: Dictionary = (orig.objects as Array)[i]
		var c: Dictionary = (copy.objects as Array)[i]
		ok(str(c.get("code", "")) != str(o.get("code", "")), "实例码重发 #%d" % i)
		var px_old: Vector2 = src_g.to_px(Vector2(float(o.get("x", 0)), float(o.get("y", 0))) + Vector2(0.5, 1.0))
		var px_new: Vector2 = dst_g.to_px(Vector2(float(c.get("x", 0)), float(c.get("y", 0))) + Vector2(0.5, 1.0))
		ok(px_old.distance_to(px_new) < 0.01, "副本实例 #%d 锚点像素一致：%s vs %s" %
			[i, str(px_old), str(px_new)])
	_wipe()
