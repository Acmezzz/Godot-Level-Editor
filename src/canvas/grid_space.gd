extends RefCounted
class_name GridSpace
## 格 ↔ 像素坐标转换层（R-01 可插拔坐标系：正交 / 等距两套 + 格对齐绘制原语）。
## 全部画布落点换算走这里；等距图要求全部瓦片资产同投影（混投影由清单校验给警告）。
##
## 口径：
## - to_px / to_grid 是唯一真相（互逆线性变换）。
## - 正交：to_px(整数格) = 格左上角；等距：to_px(整数格) = 菱形上顶点。
##   **格的统一语义查询走 cell_* 原语**（中心/多边形/纹理落位），不要直接解释 to_px(整数格)。
## - cell (i,j) 中心 = to_px(c + 0.5)；正交 cell = 方形，等距 cell = 菱形（to_px 映射格空间正方形）。
## - 纹理落位：正交左上对齐（格左上角）；等距以菱形中心居中（与 TileMapLayer 渲染一致）。
## - 六边形未实现（R-01 后续批：先用探针实测对齐 Godot 的 map_to_local 再接入）。
##
## to_grid 返回浮点格坐标，floori 得格号（正交/等距适用；六边形将来用最近中心命中）。

var tile: Vector2i = Vector2i(16, 16)
var projection := "orthogonal"   # "orthogonal" / "isometric"

func _init(t: Vector2i = Vector2i(16, 16), proj: String = "orthogonal") -> void:
	tile = t
	projection = "isometric" if proj == "isometric" else "orthogonal"

func is_iso() -> bool:
	return projection == "isometric"

## 格坐标（浮点，含格内分数）→ 像素。正交 = 左上角系；等距 = 菱形顶点系。
func to_px(g: Vector2) -> Vector2:
	if is_iso():
		var hw := float(tile.x) * 0.5
		var hh := float(tile.y) * 0.5
		return Vector2((g.x - g.y) * hw, (g.x + g.y) * hh)
	return g * Vector2(tile)

## 像素 → 浮点格坐标；格号 = floori(to_grid(p).x/.y)（仅正交/等距语义）。
func to_grid(p: Vector2) -> Vector2:
	if is_iso():
		var hw := float(tile.x) * 0.5
		var hh := float(tile.y) * 0.5
		if hw == 0.0 or hh == 0.0:
			return Vector2.ZERO
		return Vector2(
			(p.x / hw + p.y / hh) * 0.5,
			(p.y / hh - p.x / hw) * 0.5)
	if tile.x <= 0 or tile.y <= 0:
		return Vector2.ZERO
	return p / Vector2(tile)

# —— 格对齐原语（R-01：所有格对齐的绘制/命中/描边统一走这组，不再自己 ×tile_px）——

## cell 的中心像素（正交 = 方形中心；等距 = 菱形中心，与 TileMapLayer.map_to_local 口径一致）
func cell_center_px(c: Vector2i) -> Vector2:
	return to_px(Vector2(c) + Vector2(0.5, 0.5))

## cell 的像素多边形（正交 = 方形四角；等距 = 菱形四角 = to_px 映射格空间正方形）
func cell_polygon(c: Vector2i) -> PackedVector2Array:
	var g0 := Vector2(c)
	return PackedVector2Array([
		to_px(g0), to_px(g0 + Vector2(1, 0)),
		to_px(g0 + Vector2(1, 1)), to_px(g0 + Vector2(0, 1))])

## 格空间矩形 [a, b) 的像素多边形（区域选区/笔刷块/地图边界统一口径）
func grid_polygon(a: Vector2i, b: Vector2i) -> PackedVector2Array:
	var g0 := Vector2(a)
	var g1 := Vector2(b)
	return PackedVector2Array([
		to_px(g0), to_px(Vector2(g1.x, g0.y)),
		to_px(g1), to_px(Vector2(g0.x, g1.y))])

## 瓦片纹理（尺寸 cs）在 cell 的落位矩形：正交 = 左上对齐；等距 = 菱形包围盒（纹理居中）。
func cell_tex_rect(c: Vector2i, cs: Vector2i) -> Rect2:
	if is_iso():
		return Rect2(cell_center_px(c) - Vector2(cs) * 0.5, Vector2(cs))
	return Rect2(Vector2(c) * Vector2(tile), Vector2(cs))

## 可视区内的格线段（扁平 [from, to, from, to...]）。正交 = 横竖线；等距 = 两族平行线。
## vis = 可视像素矩形（调用方已用画布变换反算）；map_rect = 地图格范围。
func grid_lines(vis: Rect2, map_rect: Rect2i) -> PackedVector2Array:
	var out := PackedVector2Array()
	var g0 := to_grid(vis.position)
	var g1 := to_grid(vis.end)
	var lo := Vector2i(floori(minf(g0.x, g1.x)), floori(minf(g0.y, g1.y))) - Vector2i(1, 1)
	var hi := Vector2i(ceilf(maxf(g0.x, g1.x)), ceilf(maxf(g0.y, g1.y))) + Vector2i(1, 1)
	# i = const 族（正交竖线 / 等距 ↘ 方向线）
	var i0 := maxi(lo.x, map_rect.position.x)
	var i1 := mini(hi.x, map_rect.end.x)
	for i in range(i0, i1 + 1):
		var a := Vector2(i, maxi(lo.y, map_rect.position.y))
		var b := Vector2(i, mini(hi.y, map_rect.end.y))
		if a.y < b.y:
			out.append(to_px(a))
			out.append(to_px(b))
	# j = const 族（正交横线 / 等距 ↙ 方向线）
	var j0 := maxi(lo.y, map_rect.position.y)
	var j1 := mini(hi.y, map_rect.end.y)
	for j in range(j0, j1 + 1):
		var a2 := Vector2(maxi(lo.x, map_rect.position.x), j)
		var b2 := Vector2(mini(hi.x, map_rect.end.x), j)
		if a2.x < b2.x:
			out.append(to_px(a2))
			out.append(to_px(b2))
	return out
