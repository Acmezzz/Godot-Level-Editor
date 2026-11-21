extends RefCounted
class_name GridSpace
## 格 ↔ 像素坐标转换层（R-01 可插拔坐标系：正交 / 等距 / 六边形 + 格对齐绘制原语）。
## 全部画布落点换算走这里；等距图要求全部瓦片资产同投影（混投影由清单校验给警告）。
##
## 口径：
## - to_px / to_grid 是唯一真相（正交/等距互逆线性变换；六边 to_grid = 最近中心，非严格互逆）。
## - 正交：to_px(整数格) = 格左上角；等距：to_px(整数格) = 菱形上顶点；六边：to_px(整数格) = 格中心。
##   **格的统一语义查询走 cell_* 原语**（中心/多边形/纹理落位），不要直接解释 to_px(整数格)。
## - cell (i,j) 中心：正交/等距 = to_px(c + 0.5)，六边 = to_px(c)；cell 形状 = 方形/菱形/六角。
## - 纹理落位：正交左上对齐（格左上角）；等距/六边形以格中心居中（与 TileMapLayer 渲染一致）。
## - 六边形 = odd-r 错行 + 尖顶（与 Godot 默认 HEXAGON/STACKED/HORIZONTAL 逐位一致，探针实测）：
##   center(i,j) = ((i + (奇行?0.5:0))·w + w/2, j·0.75h + h/2)；to_grid = 最近中心命中（六边形 = 中心的 Voronoi）。
##
## to_grid 返回浮点格坐标，floori 得格号（正交/等距）；六边形的 to_grid 直接返回整数格（最近中心）。

var tile: Vector2i = Vector2i(16, 16)
var projection := "orthogonal"   # "orthogonal" / "isometric" / "hexagonal"

func _init(t: Vector2i = Vector2i(16, 16), proj: String = "orthogonal") -> void:
	tile = t
	if proj == "isometric" or proj == "hexagonal":
		projection = proj
	else:
		projection = "orthogonal"

func is_iso() -> bool:
	return projection == "isometric"

func is_hex() -> bool:
	return projection == "hexagonal"

## 格坐标（浮点，含格内分数）→ 像素。正交 = 左上角系；等距 = 菱形顶点系；六边 = 格中心系（仅整数格有格中心语义）。
func to_px(g: Vector2) -> Vector2:
	if is_hex():
		var hw := float(tile.x)
		var hh := float(tile.y)
		var off := 0.5 if posmod(floori(g.y), 2) == 1 else 0.0
		return Vector2((g.x + off) * hw + hw * 0.5, g.y * hh * 0.75 + hh * 0.5)
	if is_iso():
		var hw := float(tile.x) * 0.5
		var hh := float(tile.y) * 0.5
		return Vector2((g.x - g.y) * hw, (g.x + g.y) * hh)
	return g * Vector2(tile)

## 像素 → 浮点格坐标。正交/等距：格号 = floori(to_grid(p).x/.y)；六边形：直接返回整数格（最近中心 = 精确命中）。
func to_grid(p: Vector2) -> Vector2:
	if is_hex():
		var w := float(tile.x)
		var h := float(tile.y)
		if w <= 0.0 or h <= 0.0:
			return Vector2.ZERO
		var best := Vector2.ZERO
		var bd := 1e12
		var j0 := floori((p.y - h * 0.5) / (h * 0.75))
		for j in range(j0 - 1, j0 + 2):
			var off := 0.5 if posmod(j, 2) == 1 else 0.0
			var cy := j * h * 0.75 + h * 0.5
			var i_est := int(roundf((p.x - w * 0.5) / w - off))
			for i in range(i_est - 1, i_est + 2):
				var cx := (i + off) * w + w * 0.5
				var dd := (p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy)
				if dd < bd:
					bd = dd
					best = Vector2(i, j)
		return best
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

## cell 的中心像素（正交 = 方形中心；等距 = 菱形中心；六边 = 格中心，与 TileMapLayer.map_to_local 口径一致）
func cell_center_px(c: Vector2i) -> Vector2:
	if is_hex():
		return to_px(Vector2(c))
	return to_px(Vector2(c) + Vector2(0.5, 0.5))

## cell 的像素多边形（正交 = 方形四角；等距 = 菱形四角 = to_px 映射格空间正方形；六边 = 尖顶六角）
func cell_polygon(c: Vector2i) -> PackedVector2Array:
	if is_hex():
		var q := cell_center_px(c)
		var w2 := float(tile.x) * 0.5
		var h2 := float(tile.y) * 0.5
		var h4 := h2 * 0.5
		return PackedVector2Array([q + Vector2(0, -h2), q + Vector2(w2, -h4),
			q + Vector2(w2, h4), q + Vector2(0, h2),
			q + Vector2(-w2, h4), q + Vector2(-w2, -h4)])
	var g0 := Vector2(c)
	return PackedVector2Array([
		to_px(g0), to_px(g0 + Vector2(1, 0)),
		to_px(g0 + Vector2(1, 1)), to_px(g0 + Vector2(0, 1))])

## 格空间矩形 [a, b) 的像素多边形（区域选区/笔刷块/地图边界统一口径；六边 = 四角 cell 包围盒近似）
func grid_polygon(a: Vector2i, b: Vector2i) -> PackedVector2Array:
	if is_hex():
		var pts := cell_polygon(a)
		pts += cell_polygon(Vector2i(b.x - 1, a.y))
		pts += cell_polygon(Vector2i(b.x - 1, b.y - 1))
		pts += cell_polygon(Vector2i(a.x, b.y - 1))
		var lo := pts[0]
		var hi := pts[0]
		for p: Vector2 in pts:
			lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
			hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
		return PackedVector2Array([lo, Vector2(hi.x, lo.y), hi, Vector2(lo.x, hi.y)])
	var g0 := Vector2(a)
	var g1 := Vector2(b)
	return PackedVector2Array([
		to_px(g0), to_px(Vector2(g1.x, g0.y)),
		to_px(g1), to_px(Vector2(g0.x, g1.y))])

## 瓦片纹理（尺寸 cs）在 cell 的落位矩形：正交 = 左上对齐；等距/六边 = 格中心居中（包围盒）。
func cell_tex_rect(c: Vector2i, cs: Vector2i) -> Rect2:
	if is_iso() or is_hex():
		return Rect2(cell_center_px(c) - Vector2(cs) * 0.5, Vector2(cs))
	return Rect2(Vector2(c) * Vector2(tile), Vector2(cs))

## 可视区内的格线段（扁平 [from, to, from, to...]）。正交 = 横竖线；等距 = 两族平行线；六边 = 行界折线 + 行内竖边。
## vis = 可视像素矩形（调用方已用画布变换反算）；map_rect = 地图格范围。
func grid_lines(vis: Rect2, map_rect: Rect2i) -> PackedVector2Array:
	var out := PackedVector2Array()
	var g0 := to_grid(vis.position)
	var g1 := to_grid(vis.end)
	var lo := Vector2i(floori(minf(g0.x, g1.x)), floori(minf(g0.y, g1.y))) - Vector2i(1, 1)
	var hi := Vector2i(ceilf(maxf(g0.x, g1.x)), ceilf(maxf(g0.y, g1.y))) + Vector2i(1, 1)
	if is_hex():
		var hw := float(tile.x)
		var hh := float(tile.y)
		var hi0 := maxi(lo.x, map_rect.position.x)
		var hi1 := mini(hi.x, map_rect.end.x)
		var hj0 := maxi(lo.y, map_rect.position.y)
		var hj1 := mini(hi.y, map_rect.end.y)
		# 行界 zigzag Z(j)：基线 y = j·0.75h，x 网格随上一行错行，顶点步进 w/2（m 偶 = 基线，m 奇 = +h/4）；
		# 右端随奇行外悬 +w/2（奇行格右缘超出名义边界，与行内竖边口径一致）
		for j in range(hj0, hj1 + 1):
			var zoff := 0.5 if posmod(j - 1, 2) == 1 else 0.0
			var base := j * hh * 0.75
			var m0 := -1 if zoff > 0.0 else 0
			var m1 := (hi1 - hi0) * 2 + 1 + m0
			var prev := Vector2.ZERO
			for m in range(m0, m1 + 1):
				var xa := (float(hi0) + zoff) * hw + float(m) * hw * 0.5
				var ya := base + (hh * 0.25 if posmod(m, 2) == 1 else 0.0)
				if m > m0:
					out.append(prev)
					out.append(Vector2(xa, ya))
				prev = Vector2(xa, ya)
		# 行内竖边：x = (i + off_j)·w，y 从基线 +h/4 到 +3h/4（奇行整体右移 w/2，含右缘外悬）
		for j in range(hj0, mini(hj1 + 1, map_rect.end.y)):
			var off := 0.5 if posmod(j, 2) == 1 else 0.0
			var ya := j * hh * 0.75 + hh * 0.25
			var yb := ya + hh * 0.5
			for i in range(hi0, hi1 + 1):
				var xa := (float(i) + off) * hw
				out.append(Vector2(xa, ya))
				out.append(Vector2(xa, yb))
		return out
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

## 格像素尺寸的较大边（像素容差/热区半径的统一口径；正方形格 = 旧 tile_px 口径不变）
func cell_max() -> float:
	return maxf(float(tile.x), float(tile.y))

## 地图像素包围盒（背景/视野拟合/界内判定的统一口径）。
## 正交 = 精确矩形；等距 = 菱形网格多边形包围盒（精确）；六边 = 四角 cell 包围盒（近似）。
func map_bounds(map_rect: Rect2i) -> Rect2:
	if is_iso() or is_hex():
		var pts := grid_polygon(map_rect.position, map_rect.end)
		var mn := pts[0]
		var mx := pts[0]
		for p: Vector2 in pts:
			mn = mn.min(p)
			mx = mx.max(p)
		return Rect2(mn, mx - mn)
	return Rect2(Vector2(map_rect.position) * Vector2(tile), Vector2(map_rect.size) * Vector2(tile))
