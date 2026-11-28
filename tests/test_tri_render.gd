extends "res://tests/_suite_base.gd"
## B3：三角格瓦片渲染的 UV 口径（TriTileView.tri_uvs 纯函数，不依赖渲染帧）。
## 图集切片 → 三角形包围盒的归一化 UV：左/上贴切片左上，右下贴切片右下，
## 且永不越出该切片（否则会误取相邻切片）。

const TriTileViewScript := preload("res://src/canvas/tri_tile_view.gd")
const GridSpaceScript := preload("res://src/canvas/grid_space.gd")

func test_grid_draws_diagonals_in_each_column() -> void:
	var grid := GridSpaceScript.new(Vector2i(16, 16), "orthogonal")
	grid.set_topology("triangles")
	var lines := grid.grid_lines(Rect2(0, 0, 48, 32), Rect2i(0, 0, 3, 2))
	var diagonals := 0
	for i in range(0, lines.size(), 2):
		if lines[i].x != lines[i + 1].x and lines[i].y != lines[i + 1].y:
			diagonals += 1
	eq(diagonals, 6, "每个四边形格都有一根对角线")

## 偶半格三角形：包围盒左上角 → UV 取切片左上；包围盒右下 → 切片右下
func test_tri_uv_mapping() -> void:
	var poly := PackedVector2Array([Vector2(0, 0), Vector2(16, 0), Vector2(0, 16)])
	# 切片 (1,0) 在 32×16 图集里 = u 0.5..1.0，v 0..1
	var uvs: PackedVector2Array = TriTileViewScript.tri_uvs(poly, Vector2i(1, 0), Vector2i(16, 16), Vector2(32, 16))
	eq(uvs.size(), 3, "三点各得一 UV")
	eq(uvs[0], Vector2(0.5, 0.0), "包围盒左上 = 切片左上")
	eq(uvs[1], Vector2(1.0, 0.0), "包围盒右上 = 切片右上")
	eq(uvs[2], Vector2(0.5, 1.0), "包围盒左下 = 切片左下")
	for uv: Vector2 in uvs:
		ok(uv.x >= 0.5 - 0.0001 and uv.x <= 1.0 + 0.0001, "u 不越出切片: %s" % str(uv))
		ok(uv.y >= -0.0001 and uv.y <= 1.0 + 0.0001, "v 不越出切片: %s" % str(uv))

## 奇半格（右上）：同一图集口径，三点 UV 不重合（贴图不会退化成一点）
func test_tri_uv_odd_half() -> void:
	var g = GridSpaceScript.new(Vector2i(16, 16), "orthogonal")
	g.set_topology("triangles")
	var poly: PackedVector2Array = g.tri_polygon(1, 0)
	var uvs: PackedVector2Array = TriTileViewScript.tri_uvs(poly, Vector2i(0, 0), Vector2i(16, 16), Vector2(16, 16))
	eq(uvs.size(), 3, "奇半格三点各得一 UV")
	for uv: Vector2 in uvs:
		ok(uv.x >= -0.0001 and uv.x <= 1.0 + 0.0001, "奇半格 u 在整图内: %s" % str(uv))
		ok(uv.y >= -0.0001 and uv.y <= 1.0 + 0.0001, "奇半格 v 在整图内: %s" % str(uv))
	ok(uvs[0] != uvs[1] and uvs[1] != uvs[2] and uvs[0] != uvs[2], "三点 UV 两两不同")

## R18：alt 变换位参与 UV——翻转/转置在切片内生效，UV 仍不越出切片
func test_tri_uv_alt() -> void:
	var poly := PackedVector2Array([Vector2(0, 0), Vector2(16, 0), Vector2(0, 16)])
	var uvs := func(alt: int) -> PackedVector2Array:
		return TriTileViewScript.tri_uvs(poly, Vector2i.ZERO, Vector2i(16, 16), Vector2(16, 16), alt)
	eq(uvs.call(1)[0], Vector2(1.0, 0.0), "水平翻转：包围盒左上取切片右上")
	eq(uvs.call(2)[1], Vector2(1.0, 1.0), "垂直翻转：包围盒右上取切片右下")
	eq(uvs.call(4)[1], Vector2(0.0, 1.0), "转置：包围盒右上取切片左下")
	eq(uvs.call(5)[1], Vector2(1.0, 1.0), "90°：包围盒右上取切片右下")

## §4.3-3：块缓存的分块键——同块内连续格号归一堆，跨 BLOCK 边界换块，负坐标向下取整
## （负格是合法数据，块号不能 floor 成 0 与正格混堆）。
func test_block_key_partition() -> void:
	var b: int = TriTileViewScript.BLOCK
	eq(TriTileViewScript._block_key(Vector2i(0, 0)), Vector2i(0, 0), "原点在 0 号块")
	eq(TriTileViewScript._block_key(Vector2i(b - 1, b - 1)), Vector2i(0, 0), "块内末格仍属 0 号块")
	eq(TriTileViewScript._block_key(Vector2i(b, 0)), Vector2i(1, 0), "跨列边界进 1 号块")
	eq(TriTileViewScript._block_key(Vector2i(0, b)), Vector2i(0, 1), "跨行边界进 1 号块")
	eq(TriTileViewScript._block_key(Vector2i(-1, -1)), Vector2i(-1, -1), "负格归负块（不与正格混堆）")

## 退化输入不炸：空多边形/零尺寸纹理都返回空数组（调用方据此跳过绘制）
func test_tri_uv_degenerate() -> void:
	eq(TriTileViewScript.tri_uvs(PackedVector2Array(), Vector2i.ZERO, Vector2i(16, 16), Vector2(16, 16)).size(),
		0, "空多边形 → 空 UV")
	eq(TriTileViewScript.tri_uvs(PackedVector2Array([Vector2.ZERO, Vector2.ONE, Vector2(0, 1)]),
		Vector2i.ZERO, Vector2i(16, 16), Vector2.ZERO).size(), 0, "零尺寸纹理 → 空 UV")
	# 三点共线的极端包围盒：除以极小值也不能出 NaN
	var line := PackedVector2Array([Vector2(0, 0), Vector2(16, 0), Vector2(8, 0)])
	var uvs := TriTileViewScript.tri_uvs(line, Vector2i.ZERO, Vector2i(16, 16), Vector2(16, 16))
	eq(uvs.size(), 3, "共线三点仍返回 UV")
	for uv: Vector2 in uvs:
		ok(is_finite(uv.x) and is_finite(uv.y), "共线不退化成 NaN: %s" % str(uv))
