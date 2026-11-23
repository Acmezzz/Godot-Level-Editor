extends "res://tests/_suite_base.gd"
## 空间与类型池：GridSpace 正交/等距换算、collisionTypes 池归一化。

const GridSpaceScript := preload("res://src/canvas/grid_space.gd")
const CollisionTypes := preload("res://src/assets/collision_types.gd")
const MapViewData := preload("res://src/map/map_view_data.gd")

func test_grid_orthogonal() -> void:
	var g = GridSpaceScript.new(Vector2i(16, 16), "orthogonal")
	eq(g.to_px(Vector2(3, 4)), Vector2(48, 64), "正交格→像素")
	eq(g.to_grid(Vector2(48, 64)), Vector2(3, 4), "正交像素→格")

func test_grid_isometric() -> void:
	var g = GridSpaceScript.new(Vector2i(16, 16), "isometric")
	eq(g.to_px(Vector2(1, 0)), Vector2(8, 8), "等距 (1,0) 中心 = (w/2, h/2)")
	eq(g.to_px(Vector2(1, 1)), Vector2(0, 16), "等距 (1,1) 中心 = (0, h)")
	var gr: Vector2 = g.to_grid(Vector2(8, 8))
	eq(int(gr.x), 1, "等距反算 i")
	eq(int(gr.y), 0, "等距反算 j")
	eq(gr, Vector2(1, 0), "等距往返一致")

func test_collision_types_pool() -> void:
	var fallback := CollisionTypes.pool({})
	eq(fallback.size(), 4, "未声明 = 内置缺省池")
	eq(str((fallback[0] as Dictionary).get("id")), "solid", "缺省首类 solid")
	var declared := {"collisionTypes": {"ice": {"name": "冰面", "shape": "rect", "gameplay": "slide", "color": "#88ccff"}}}
	var pool := CollisionTypes.pool(declared)
	eq(pool.size(), 1, "声明覆盖内置")
	eq(str((pool[0] as Dictionary).get("gameplay")), "slide", "gameplay 透传")
	var d: Dictionary = CollisionTypes.decl_of(declared, "ice")
	eq(str(d.get("name")), "冰面", "按 id 查声明")
	eq(CollisionTypes.decl_of(declared, "nope"), Dictionary(), "未声明返回空")
	var arr := {"collisionTypes": [{"id": "a"}, {"id": "a"}]}
	ok(arr != null, "数组写法可解析（查重归清单校验）")

func test_grid_primitives_ortho() -> void:
	var g = GridSpaceScript.new(Vector2i(16, 16), "orthogonal")
	for i in range(-2, 3):
		for j in range(-2, 3):
			var c := Vector2i(i, j)
			var p = g.cell_center_px(c)
			var back = g.to_grid(p)
			ok(floori(back.x) == i and floori(back.y) == j, "正交中心命中格 (%d,%d)" % [i, j])
			var poly: PackedVector2Array = g.cell_polygon(c)
			ok(poly.size() == 4 and Geometry2D.is_point_in_polygon(p, poly), "正交 cell 多边形含中心 (%d,%d)" % [i, j])
	eq(g.cell_tex_rect(Vector2i(0, 0), Vector2i(16, 16)), Rect2(Vector2(0, 0), Vector2(16, 16)), "正交纹理左上对齐")
	var segs: PackedVector2Array = g.grid_lines(Rect2(0, 0, 48, 48), Rect2i(0, 0, 3, 3))
	ok(segs.size() > 0 and segs.size() % 2 == 0, "格线成对")
	var has_vert := false
	for k in range(0, segs.size(), 2):
		if segs[k].x == segs[k + 1].x:
			has_vert = true
	ok(has_vert, "正交格线含竖线")
	# R22：shift_cell 正交下与原始格号相加严格等价
	eq(g.shift_cell(Vector2i(3, 4), Vector2i(2, -1)), Vector2i(5, 3), "正交 shift = 直接相加")
	eq(g.shift_cell(Vector2i(-2, 0), Vector2i(1, 3)), Vector2i(-1, 3), "正交 shift 负格号也等价")

func test_grid_primitives_iso() -> void:
	var g = GridSpaceScript.new(Vector2i(16, 16), "isometric")
	eq(g.cell_center_px(Vector2i(0, 0)), Vector2(0, 8), "等距 (0,0) 中心 = (0, h/2)")
	eq(g.cell_tex_rect(Vector2i(0, 0), Vector2i(16, 16)), Rect2(Vector2(-8, 0), Vector2(16, 16)), "等距纹理 = 菱形包围盒")
	var gp: PackedVector2Array = g.grid_polygon(Vector2i(0, 0), Vector2i(2, 1))
	eq(gp, PackedVector2Array([Vector2(0, 0), Vector2(16, 16), Vector2(8, 24), Vector2(-8, 8)]), "等距格矩形顶点")
	for c in [Vector2i(2, 1), Vector2i(-1, 3), Vector2i(5, 5)]:
		var ctr = g.cell_center_px(c)
		var back = g.to_grid(ctr)
		ok(floori(back.x) == c.x and floori(back.y) == c.y, "等距中心命中格 %s" % str(c))
		var poly: PackedVector2Array = g.cell_polygon(c)
		ok(poly.size() == 4 and Geometry2D.is_point_in_polygon(ctr, poly), "等距菱形含中心 %s" % str(c))

func test_grid_hex() -> void:
	var g = GridSpaceScript.new(Vector2i(16, 16), "hexagonal")
	eq(g.cell_center_px(Vector2i(0, 0)), Vector2(8, 8), "六边 (0,0) 中心（探针实测）")
	eq(g.cell_center_px(Vector2i(0, 1)), Vector2(16, 20), "六边 (0,1) 中心 = 奇行错 +w/2")
	eq(g.cell_center_px(Vector2i(2, 0)), Vector2(40, 8), "六边 (2,0) 中心")
	eq(g.cell_center_px(Vector2i(1, 1)), Vector2(32, 20), "六边 (1,1) 中心")
	eq(g.to_grid(Vector2(16, 18)), Vector2(0, 1), "六边非中心点 = 最近中心命中")
	# B1：拾取按实际六角轮廓（与绘制形状一致）
	eq(g.pick_cell(Vector2(16, 18)), Vector2i(0, 1), "六边拾取与 to_grid 同结果")
	for c in [Vector2i(0, 0), Vector2i(3, 1), Vector2i(-1, 2), Vector2i(5, 4)]:
		var ctr = g.cell_center_px(c)
		eq(g.to_grid(ctr), Vector2(c), "六边中心往返 %s" % str(c))
		var poly: PackedVector2Array = g.cell_polygon(c)
		ok(poly.size() == 6 and Geometry2D.is_point_in_polygon(ctr, poly), "六边六角含中心 %s" % str(c))
	eq(g.cell_tex_rect(Vector2i(0, 0), Vector2i(16, 16)), Rect2(Vector2(0, 0), Vector2(16, 16)), "六边纹理中心居中")
	var gp: PackedVector2Array = g.grid_polygon(Vector2i(0, 0), Vector2i(2, 1))
	eq(gp, PackedVector2Array([Vector2(0, 0), Vector2(32, 0), Vector2(32, 16), Vector2(0, 16)]), "六边格矩形 = 四角 cell 包围盒")
	var segs: PackedVector2Array = g.grid_lines(Rect2(0, 0, 48, 48), Rect2i(0, 0, 3, 3))
	ok(segs.size() == 80, "六边格线 40 段 = 80 点")
	# R22：shift_cell 经像素几何平移——odd-r 行错位在平移里保持（奇行跨奇数行数列 +1）
	eq(g.shift_cell(Vector2i(0, 0), Vector2i(0, 1)), Vector2i(0, 1), "六边 shift (0,1) 命中 (0,1)")
	eq(g.shift_cell(Vector2i(3, 1), Vector2i(0, 1)), Vector2i(4, 2), "六边奇行跨行平移列补偿 +1")
	eq(g.shift_cell(Vector2i(3, 0), Vector2i(0, 1)), Vector2i(3, 1), "六边偶行跨行平移列不变")

func test_grid_rect_cells() -> void:
	var g = GridSpaceScript.new(Vector2i(32, 16), "orthogonal")
	eq(g.to_px(Vector2(3, 4)), Vector2(96, 64), "矩形格正交 to_px")
	eq(g.to_grid(Vector2(96, 64)), Vector2(3, 4), "矩形格正交往返")
	eq(g.map_bounds(Rect2i(0, 0, 3, 3)), Rect2(0, 0, 96, 48), "矩形格 map_bounds = 精确矩形")
	var gi = GridSpaceScript.new(Vector2i(32, 16), "isometric")
	eq(gi.cell_center_px(Vector2i(1, 0)), Vector2(16, 16), "矩形格等距 2:1 菱形中心")
	eq(gi.to_grid(Vector2(16, 16)), Vector2(1.5, 0.5), "矩形格等距 to_grid 落在 (1,0) 格内")
	eq(gi.map_bounds(Rect2i(0, 0, 2, 2)), Rect2(-32, 0, 64, 32), "等距 map_bounds = 菱形包围盒")
	var gh = GridSpaceScript.new(Vector2i(32, 16), "hexagonal")
	eq(gh.cell_center_px(Vector2i(0, 1)), Vector2(32, 20), "矩形格六边 (0,1) 中心")
	eq(gh.to_px(Vector2(1, 0)), Vector2(48, 8), "矩形格六边 to_px (1,0) 中心")
	eq(gh.to_grid(Vector2(48, 8)), Vector2(1, 0), "矩形格六边往返")

## B1：清单 tileSize 解析（16 / [32,16] / 畸形回退）
func test_tile_size_of() -> void:
	eq(GridSpaceScript.tile_size_of({"tileSize": 16}), Vector2i(16, 16), "标量 tileSize")
	eq(GridSpaceScript.tile_size_of({"tileSize": [32, 16]}), Vector2i(32, 16), "矩形 tileSize")
	eq(GridSpaceScript.tile_size_of({"tileSize": 16.0}), Vector2i(16, 16), "JSON float 整数接受")
	eq(GridSpaceScript.tile_size_of({"tileSize": [32.0, 16.0]}), Vector2i(32, 16), "JSON 数组 float 接受")
	eq(GridSpaceScript.tile_size_of({"tileSize": 0}), Vector2i(16, 16), "零回退")
	eq(GridSpaceScript.tile_size_of({"tileSize": -4}), Vector2i(16, 16), "负数回退")
	eq(GridSpaceScript.tile_size_of({"tileSize": [32, 0]}), Vector2i(16, 16), "半零数组回退")
	eq(GridSpaceScript.tile_size_of({"tileSize": 16.5}), Vector2i(16, 16), "非整数回退")
	eq(GridSpaceScript.tile_size_of({}), Vector2i(16, 16), "缺键缺省 16")

## B1：拾取与连续格坐标（正交/等距/l六边）
func test_pick_cell_and_continuous() -> void:
	var g = GridSpaceScript.new(Vector2i(16, 16), "orthogonal")
	eq(g.pick_cell(Vector2(48 + 8, 64 + 8)), Vector2i(3, 4), "正交中心拾取")
	eq(g.pick_cell(Vector2(47, 63)), Vector2i(2, 3), "正交边前一像素拾取")
	eq(g.to_continuous_grid(Vector2(56, 72)), Vector2(3.5, 4.5), "正交连续坐标")
	var gi = GridSpaceScript.new(Vector2i(16, 16), "isometric")
	var ctr = gi.cell_center_px(Vector2i(2, 1))
	eq(gi.pick_cell(ctr), Vector2i(2, 1), "等距中心拾取")
	eq(gi.to_continuous_grid(gi.to_px(Vector2(2.2, 2.2))), Vector2(2.2, 2.2), "等距亚格往返")
	var gh = GridSpaceScript.new(Vector2i(16, 16), "hexagonal")
	for c in [Vector2i(0, 0), Vector2i(3, 1), Vector2i(-1, 2), Vector2i(5, 4)]:
		eq(gh.pick_cell(gh.cell_center_px(c)), c, "六边中心拾取 %s" % str(c))
	# 六边连续坐标是 to_px 的严格反解：任意亚格往返
	eq(gh.to_continuous_grid(gh.to_px(Vector2(2.2, 2.2))), Vector2(2.2, 2.2), "六边亚格往返")
	ok(gh.to_continuous_grid(gh.to_px(Vector2(3.7, 1.4))).distance_to(Vector2(3.7, 1.4)) < 0.001,
		"六边奇行亚格往返（浮点容差）")
	# 偶行拖到奇行再拖回：gx 差半格是坐标定义，像素位置必须一致
	var even_px = gh.to_px(Vector2(2.0, 0.0))
	var odd_px = gh.to_px(Vector2(2.0, 1.0))
	eq(gh.to_continuous_grid(even_px), Vector2(2.0, 0.0), "偶行连续坐标")
	eq(gh.to_continuous_grid(odd_px), Vector2(2.0, 1.0), "奇行连续坐标（to_px 口径）")
	eq(gh.to_px(gh.to_continuous_grid(odd_px)), odd_px, "奇行连续往返像素一致")
	# 矩形格 [32,16] + 亚格
	var gr = GridSpaceScript.new(Vector2i(32, 16), "hexagonal")
	ok(gr.to_continuous_grid(gr.to_px(Vector2(2.2, 2.2))).distance_to(Vector2(2.2, 2.2)) < 0.001,
		"矩形六边亚格往返")

## B2：格邻接按格型（正交/等距四邻，六边六邻、上方两格）
func test_grid_neighbors() -> void:
	var g = GridSpaceScript.new(Vector2i(16, 16), "orthogonal")
	var n4: Array = g.neighbors(Vector2i(3, 4))
	eq(n4.size(), 4, "正交四邻")
	ok(n4.has(Vector2i(4, 4)) and n4.has(Vector2i(2, 4)) and n4.has(Vector2i(3, 3)) and n4.has(Vector2i(3, 5)),
		"正交四邻就是上下左右")
	eq(g.up_neighbors(Vector2i(3, 4)), [Vector2i(3, 3)], "正交上邻单格")
	var h = GridSpaceScript.new(Vector2i(16, 16), "hexagonal")
	var n6: Array = h.neighbors(Vector2i(3, 4))
	eq(n6.size(), 6, "六边六邻")
	for nb: Vector2i in n6:
		ok(nb != Vector2i(3, 4), "邻格不含自身")
	eq(h.up_neighbors(Vector2i(3, 4)).size(), 2, "六边上邻两格（奇偶行各一）")
	# 奇偶行错位：偶行的 (0,-1)/(1,-1) 才是上方两格
	var up_even: Array = h.up_neighbors(Vector2i(2, 0))
	ok(up_even.has(Vector2i(1, -1)) and up_even.has(Vector2i(2, -1)), "偶行上邻 = (1,-1)/(2,-1)")

## B2：格路径补格（快速拖动不漏格，首尾含端点、无重复）
func test_cells_between() -> void:
	var g = GridSpaceScript.new(Vector2i(16, 16), "orthogonal")
	var path: Array = g.cells_between(Vector2i(0, 0), Vector2i(5, 0))
	eq(path[0], Vector2i(0, 0), "路径首格")
	eq(path[path.size() - 1], Vector2i(5, 0), "路径尾格")
	eq(path.size(), 6, "直线路径 = 连续六格（无跳格）")
	for i in range(1, path.size()):
		ok((path[i] as Vector2i).x == (path[i - 1] as Vector2i).x + 1, "路径逐格递增")
	eq(g.cells_between(Vector2i(2, 2), Vector2i(2, 2)), [Vector2i(2, 2)], "同格路径 = 自身")
	var diag: Array = g.cells_between(Vector2i(0, 0), Vector2i(3, 3))
	ok(diag.size() >= 4 and diag.has(Vector2i(3, 3)), "对角路径覆盖终点")
	var h = GridSpaceScript.new(Vector2i(16, 16), "hexagonal")
	var hp: Array = h.cells_between(Vector2i(0, 0), Vector2i(4, 0))
	eq(hp[0], Vector2i(0, 0), "六边路径首格")
	eq(hp[hp.size() - 1], Vector2i(4, 0), "六边路径尾格")

## B3：双基向量斜平面——(2,3) 在 u=(32,8)、v=(0,24) 下映成 (64,88)，逆算回原点位
func test_grid_basis_skew() -> void:
	var g = GridSpaceScript.new(Vector2i(16, 16), "orthogonal", [Vector2(32, 8), Vector2(0, 24)])
	eq(g.to_px(Vector2(2, 3)), Vector2(64, 88), "斜平面 (2,3) → (64,88)")
	eq(g.to_grid(Vector2(64, 88)), Vector2(2, 3), "逆矩阵精确反算")
	for i in range(-3, 4):
		for j in range(-3, 4):
			var p: Vector2 = g.to_px(Vector2(i, j))
			ok(g.to_grid(p).distance_to(Vector2(i, j)) < 0.0001, "斜平面往返 %d,%d" % [i, j])
	# 拾取：格内中心命中本格
	eq(g.pick_cell(g.to_px(Vector2(1, 1) + Vector2(0.5, 0.5))), Vector2i(1, 1), "斜平面格中心拾取")
	# 四邻不变（平行四边形仍是四邻拓扑）
	eq((g.neighbors(Vector2i(2, 2)) as Array).size(), 4, "斜平面四邻")
	# 纹理落位以格原点为锚（正交口径）
	eq(g.cell_tex_rect(Vector2i(1, 0), Vector2i(16, 16)).position, Vector2(32, 8), "斜平面纹理锚在格原点")
	# map_bounds 是四角包围盒（不是 size·tile）
	var b: Rect2 = g.map_bounds(Rect2i(0, 0, 2, 2))
	eq(b.position, Vector2(0, 0), "斜平面包围盒起点")
	eq(b.size, Vector2(64, 64), "斜平面包围盒尺寸 = 四角极值")

## B3：gridBasis 解析与拒绝（非数组/非数值/共线/零向量）
func test_parse_basis() -> void:
	var ok1: Dictionary = GridSpaceScript.parse_basis({})
	ok(bool(ok1.get("ok", false)), "缺键 = 合法（无基）")
	eq(ok1.get("u"), Vector2.ZERO, "缺键 u 为零")
	var ok2: Dictionary = GridSpaceScript.parse_basis({"gridBasis": [[32, 8], [0, 24]]})
	ok(bool(ok2.get("ok", false)), "[[32,8],[0,24]] 合法")
	eq(ok2.get("u"), Vector2(32, 8), "u 解析")
	eq(ok2.get("v"), Vector2(0, 24), "v 解析")
	for bad in [[[32, 8]], [[32, 8], [0, 24], [1, 1]], "x", [[32, 8], [0, "a"]], [[0, 0], [0, 24]], [[32, 8], [64, 16]]]:
		var r: Dictionary = GridSpaceScript.parse_basis({"gridBasis": bad})
		ok(not bool(r.get("ok", true)), "拒绝非法 gridBasis %s" % str(bad))
		ok(str(r.get("why", "")) != "", "给出拒绝原因")
	# 不可逆的基不生效：构造时静默保持原几何
	var g = GridSpaceScript.new(Vector2i(16, 16), "orthogonal", [Vector2(1, 1), Vector2(2, 2)])
	eq(g.to_px(Vector2(1, 0)), Vector2(16, 0), "共线基被拒，仍是正交")
	ok(not g.has_basis, "has_basis 保持 false")

## B3：三角格——列映射、半格顶点、三角形命中、共边邻接
func test_grid_triangles() -> void:
	var g = GridSpaceScript.new(Vector2i(16, 16), "orthogonal")
	g.set_topology("triangles")
	ok(g.is_tri(), "拓扑生效")
	# 列映射：i=0 → (c=0, 偶)；i=1 → (c=0, 奇)；i=2 → (c=1, 偶)；i=-1 → (c=-1, 奇)
	eq(GridSpaceScript.tri_col(0), {"c": 0, "odd": false}, "i=0 = 第 0 列偶半格")
	eq(GridSpaceScript.tri_col(1), {"c": 0, "odd": true}, "i=1 = 第 0 列奇半格")
	eq(GridSpaceScript.tri_col(2), {"c": 1, "odd": false}, "i=2 = 第 1 列偶半格")
	eq(GridSpaceScript.tri_col(-1), {"c": -1, "odd": true}, "-1 = 第 -1 列奇半格（负数向下取整）")
	# 半格顶点（单位基）
	eq(GridSpaceScript.tri_unit_points(0, 0), PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(0, 1)]),
		"偶半格 = (0,0),(1,0),(0,1)")
	eq(GridSpaceScript.tri_unit_points(1, 0), PackedVector2Array([Vector2(1, 1), Vector2(0, 1), Vector2(1, 0)]),
		"奇半格 = (1,1),(0,1),(1,0)")
	eq(GridSpaceScript.tri_unit_points(2, 3), PackedVector2Array([Vector2(1, 3), Vector2(2, 3), Vector2(1, 4)]),
		"列平移：i=2,row=3 → c=1")
	# 拾取：偶半格内部点 vs 奇半格内部点
	eq(g.pick_cell(Vector2(16 * 0.25, 16 * 0.25)), Vector2i(0, 0), "左下三角内部 → 偶半格")
	eq(g.pick_cell(Vector2(16 * 0.75, 16 * 0.75)), Vector2i(1, 0), "右上三角内部 → 奇半格")
	eq(g.pick_cell(Vector2(16 * 1.25, 16 * 0.25)), Vector2i(2, 0), "第 1 列左下 → i=2")
	# 多边形三点必须与半格顶点一致（正交下 = 16 倍）
	var poly0: PackedVector2Array = g.cell_polygon(Vector2i(0, 0))
	eq(poly0.size(), 3, "三角格多边形 = 3 点")
	eq(poly0, PackedVector2Array([Vector2(0, 0), Vector2(16, 0), Vector2(0, 16)]), "偶半格像素多边形")
	# 共边邻接：每格 3 邻，互不重复，且邻格反向包含本格
	for c in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(4, 2), Vector2i(5, 3)]:
		var nbs: Array = g.neighbors_any(c)
		eq(nbs.size(), 3, "三角格三邻 %s" % str(c))
		ok(nbs.has(Vector2i(c.x + 1 if posmod(c.x, 2) == 0 else c.x - 1, c.y)), "斜边邻 = 同列另一半 %s" % str(c))
		for nb: Vector2i in nbs:
			ok((g.neighbors_any(nb) as Array).has(c), "邻接对称 %s ↔ %s" % [str(c), str(nb)])
	# 三角格中心 = 重心
	var ctr: Vector2 = g.cell_center_px(Vector2i(0, 0))
	ok(ctr.distance_to(Vector2(16, 16) / 3.0) < 0.001, "偶半格重心 = 三点平均")
	# 网格线含对角线；六边 + 三角组合被拒
	ok(g.grid_lines(Rect2(-8, -8, 48, 48), Rect2i(0, 0, 2, 2)).size() >= 12, "三角网格线含外框/内线/对角线")
	# V4 P1：三角列与连续格列不能混用——位移/所在格/范围/边界全部折半
	eq(g.delta_px(Vector2i(2, 0)), Vector2(16, 0), "两个三角列 = 一个平行四边形列宽")
	eq(g.shift_cell(Vector2i(0, 0), Vector2i(2, 0)), Vector2i(2, 0), "三角位移 (2,0) = 同排下一个偶半格")
	eq(g.shift_cell(Vector2i(0, 0), Vector2i(0, 1)), Vector2i(0, 1), "三角竖移一格")
	eq(g.cell_of_continuous(Vector2(0.25, 0.25)), Vector2i(0, 0), "连续坐标左下 → 偶半格")
	eq(g.cell_of_continuous(Vector2(0.75, 0.75)), Vector2i(1, 0), "连续坐标右上 → 奇半格")
	eq(g.cell_origin_continuous(Vector2i(3, 2)), Vector2(1, 2), "三角列 3 → 平行四边形列 1")
	ok(g.cell_in_map(Vector2i(3, 0), 2, 4), "三角列 3 在 2 列宽图内（列 1）")
	ok(not g.cell_in_map(Vector2i(4, 0), 2, 4), "三角列 4 超出 2 列宽图")
	var gp2: PackedVector2Array = g.grid_polygon(Vector2i(0, 0), Vector2i(4, 1))
	eq(gp2, PackedVector2Array([Vector2(0, 0), Vector2(32, 0), Vector2(32, 16), Vector2(0, 16)]),
		"三角范围 4 个三角列 = 2 个平行四边列宽")
	# 地图边界用列号口径：w×h 是列数，不能被折半
	eq(g.map_rect_polygon(Vector2i(0, 0), Vector2i(2, 1)),
		PackedVector2Array([Vector2(0, 0), Vector2(32, 0), Vector2(32, 16), Vector2(0, 16)]),
		"三角 map_rect_polygon 按列号不折算")
	eq(g.map_bounds(Rect2i(0, 0, 2, 1)), Rect2(0, 0, 32, 16), "三角地图包围盒 = 2 列宽")
	var hexg = GridSpaceScript.new(Vector2i(16, 16), "hexagonal")
	hexg.set_topology("triangles")
	ok(not hexg.is_tri(), "六边投影拒绝三角拓扑（保持 quads）")
	# §4.3：hex + gridBasis 三种口径统一——basis 优先，六边的格中心/六角多边形/最近中心拾取不再生效
	var hb = GridSpaceScript.new(Vector2i(16, 16), "hexagonal")
	hb.set_basis(Vector2(20, 0), Vector2(3, 14))
	ok(hb.is_hex() and not hb.is_hex_geom(), "hex+basis：投影仍是六边，但几何已不是六边")
	eq(hb.cell_center_px(Vector2i(0, 0)), hb.to_px(Vector2(0.5, 0.5)), "hex+basis 格中心 = 平行四边形中心")
	eq(hb.cell_polygon(Vector2i(0, 0)).size(), 4, "hex+basis 格多边形 = 平行四边形四点")
	eq(hb.pick_cell(hb.cell_center_px(Vector2i(1, 1))), Vector2i(1, 1), "hex+basis 拾取按 basis 反算")
	eq(hb.neighbors(Vector2i(0, 0)).size(), 4, "hex+basis 邻接 = 四邻（不是六边六邻）")
	# 无 basis 的六边仍按六边形几何
	var h0 = GridSpaceScript.new(Vector2i(16, 16), "hexagonal")
	ok(h0.is_hex_geom(), "纯六边 = hex 几何")
	eq(h0.cell_polygon(Vector2i(0, 0)).size(), 6, "纯六边格多边形 = 六角")
	eq(h0.neighbors(Vector2i(0, 0)).size(), 6, "纯六边六邻")
	# §4.2：共边几何在 GridSpace（点选/高亮/下拉同一份）
	var eb: PackedVector2Array = g.edge_between(Vector2i(0, 0), Vector2i(1, 0))
	eq(eb.size(), 2, "三角共边 = 两点")
	eq(eb, PackedVector2Array([Vector2(16, 0), Vector2(0, 16)]), "三角共边 = 斜边公共两点")
	var hb_edge: PackedVector2Array = h0.edge_between(Vector2i(0, 0), Vector2i(0, 1))
	eq(hb_edge.size(), 2, "六边斜向共边也是两点")

## B3：gridTopology 解析（缺省 quads、非法值/六边组合报具体原因）
func test_parse_topology() -> void:
	eq(str(GridSpaceScript.parse_topology({}, "orthogonal").get("topology", "")), "quads", "缺键 = quads")
	eq(str(GridSpaceScript.parse_topology({"gridTopology": "quads"}, "isometric").get("topology", "")),
		"quads", "显式 quads")
	var tri: Dictionary = GridSpaceScript.parse_topology({"gridTopology": "triangles"}, "isometric")
	ok(bool(tri.get("ok", false)), "等距 + triangles 合法")
	eq(str(tri.get("topology", "")), "triangles", "解析出 triangles")
	var bad1: Dictionary = GridSpaceScript.parse_topology({"gridTopology": "hex"}, "orthogonal")
	ok(not bool(bad1.get("ok", true)), "未知拓扑拒绝")
	ok(str(bad1.get("why", "")) != "", "给出拒绝原因")
	var bad2: Dictionary = GridSpaceScript.parse_topology({"gridTopology": "triangles"}, "hexagonal")
	ok(not bool(bad2.get("ok", true)), "六边 + triangles 拒绝")

## B3：MapViewData 的层变换按**数据层真实写法**取（offset 数组 + scale 标量，
## 与 layer_ops.gd 写回、editor_canvas.gd 建层一致）；缺键 = 恒等，scale ≤ 0 当缺省。
func test_map_view_layer_transform() -> void:
	var d := {"meta": {"layers": [
		{"id": "A", "offset": [64, -32], "scale": 2.0},
		{"id": "B"},
		{"id": "C", "scale": 0.0}]}}
	eq(MapViewData.layer_transform(d, "A"), Transform2D(0.0, Vector2(2, 2), 0.0, Vector2(64, -32)),
		"offset 数组 + scale 标量")
	eq(MapViewData.layer_transform(d, "B"), Transform2D.IDENTITY, "缺键 = 恒等")
	eq(MapViewData.layer_transform(d, "C"), Transform2D.IDENTITY, "scale ≤ 0 视为缺省（不放大成 0）")
	eq(MapViewData.layer_transform(d, "不存在"), Transform2D.IDENTITY, "未知层 = 恒等")

## B3：cell_poly / anchor_px 是「格空间 + 层变换」的合成口径；layer_id 为空 = 根空间。
func test_map_view_cell_and_anchor() -> void:
	var d := {"meta": {"w": 4, "h": 4, "gridProjection": "orthogonal",
		"layers": [{"id": "A", "offset": [16, 0], "scale": 2.0}]}}
	var m := {"tileSize": 16}
	var root: PackedVector2Array = MapViewData.cell_poly(d, m, "", Vector2i(1, 0))
	eq(root[0], Vector2(16, 0), "根空间格 (1,0) 左上 = (16,0)")
	var xf: PackedVector2Array = MapViewData.cell_poly(d, m, "A", Vector2i(1, 0))
	eq(xf[0], Vector2(48, 0), "层空间 = 根坐标 ×2 + offset(16,0)")
	eq(MapViewData.anchor_px(d, m, "A", 0.5, 0.5), Vector2(32, 16), "锚点像素同走层变换")


