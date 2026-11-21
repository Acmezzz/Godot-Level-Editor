extends "res://tests/_suite_base.gd"
## 空间与类型池：GridSpace 正交/等距换算、collisionTypes 池归一化。

const GridSpaceScript := preload("res://src/canvas/grid_space.gd")
const CollisionTypes := preload("res://src/assets/collision_types.gd")

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
