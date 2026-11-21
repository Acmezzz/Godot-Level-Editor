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

## 清单 tileSize → 格尺寸（内部一律 Vector2i）：16 或 [32,16]；零/负/非整数/畸形回退 16×16。
static func tile_size_of(m: Dictionary) -> Vector2i:
	var ts = m.get("tileSize", 16)
	if ts is Array and (ts as Array).size() == 2:
		var wv = (ts as Array)[0]
		var hv = (ts as Array)[1]
		if _is_pos_int(wv) and _is_pos_int(hv):
			return Vector2i(int(wv), int(hv))
	elif _is_pos_int(ts):
		var s := int(ts)
		return Vector2i(s, s)
	return Vector2i(16, 16)

static func _is_pos_int(v) -> bool:
	if v is int:
		return v > 0
	if not (v is float):
		return false
	var f: float = v
	return is_finite(f) and f > 0.0 and f == floorf(f)

## 项目级缺省投影：任一瓦片资产声明非正交即整项目按它（地图无 meta.gridProjection 时的解析）。
static func project_projection(m: Dictionary) -> String:
	for a in (m.get("assets", []) as Array):
		if not (a is Dictionary) or str((a as Dictionary).get("kind", "")) != "scene" \
				or str((a as Dictionary).get("shape", "")) != "tile":
			continue
		var gp := str((a as Dictionary).get("gridProjection", "orthogonal"))
		if gp == "isometric" or gp == "hexagonal":
			return gp
	return "orthogonal"

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

## 拾取（B1）：像素 → 格号。正交/等距 = floor(连续格坐标)；六边 = 附近 3×3 格里
## 按实际六角轮廓判定（最近中心只是 Voronoi 近似，与绘制形状在边界上不一致），
## 轮廓内优先、再取中心更近者；遍历序固定 → 边界结果稳定。
func pick_cell(px: Vector2) -> Vector2i:
	var g := to_grid(px)
	if not is_hex():
		return Vector2i(floori(g.x), floori(g.y))
	var ctr := Vector2i(int(g.x), int(g.y))
	var best := ctr
	var best_score := INF
	for dj in range(-1, 2):
		for di in range(-1, 2):
			var c := Vector2i(ctr.x + di, ctr.y + dj)
			var score := px.distance_squared_to(cell_center_px(c))
			if Geometry2D.is_point_in_polygon(px, cell_polygon(c)):
				score -= 1.0e12
			if score < best_score:
				best_score = score
				best = c
	return best

## 连续格坐标（含亚格，B1）：正交/等距 = to_grid（线性互逆）；六边 = 行连续换算，
## 不取最近中心——离格拖动逐帧反算时要连续，过奇偶行边界 gx 可变半格但像素位置不断。
## 公式是 to_px 的严格反解：gy=(py-h/2)/(0.75h)，gx=(px-w/2)/w-odd_offset(floor(gy))。
func to_continuous_grid(px: Vector2) -> Vector2:
	if not is_hex():
		return to_grid(px)
	var w := float(tile.x)
	var h := float(tile.y)
	if w <= 0.0 or h <= 0.0:
		return Vector2.ZERO
	var gy := (px.y - h * 0.5) / (h * 0.75)
	var off := 0.5 if posmod(floori(gy), 2) == 1 else 0.0
	return Vector2((px.x - w * 0.5) / w - off, gy)

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
	# 可视格范围按四角反算（E14）：等距/六边下对角两角不足以覆盖可视区，
	# 只取 position/end 会漏掉另外两个角所覆盖的格线，平移时网格边缘缺段。
	var g0 := to_grid(vis.position)
	var g1 := to_grid(Vector2(vis.end.x, vis.position.y))
	var g2 := to_grid(vis.end)
	var g3 := to_grid(Vector2(vis.position.x, vis.end.y))
	var gmin := Vector2(minf(minf(g0.x, g1.x), minf(g2.x, g3.x)), minf(minf(g0.y, g1.y), minf(g2.y, g3.y)))
	var gmax := Vector2(maxf(maxf(g0.x, g1.x), maxf(g2.x, g3.x)), maxf(maxf(g0.y, g1.y), maxf(g2.y, g3.y)))
	var lo := Vector2i(floori(gmin.x), floori(gmin.y)) - Vector2i(1, 1)
	var hi := Vector2i(ceilf(gmax.x), ceilf(gmax.y)) + Vector2i(1, 1)
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

## 格 c 的共边邻格（B2/E16）：正交/等距 = 四邻；六边 = 六个共边邻格（奇偶行错位）。
## 自动碰撞轮廓/顶面策略按真实邻接枚举，不能对六边硬套四邻。
func neighbors(c: Vector2i) -> Array:
	if not is_hex():
		return [c + Vector2i(1, 0), c + Vector2i(-1, 0), c + Vector2i(0, 1), c + Vector2i(0, -1)]
	var odd := posmod(c.y, 2) == 1
	# odd-r：奇行整体右移半格，两行之间的邻格对随奇偶切换
	return [
		c + Vector2i(1, 0), c + Vector2i(-1, 0),
		c + Vector2i(0, -1), c + Vector2i(0, 1),
		c + Vector2i(1 if odd else 0, -1), c + Vector2i(1 if odd else 0, 1),
	]

## 「上邻」（顶面策略用）：正交/等距 = (0,-1)；六边 = 视觉上方两格（奇偶各一）
func up_neighbors(c: Vector2i) -> Array:
	if not is_hex():
		return [c + Vector2i(0, -1)]
	var odd := posmod(c.y, 2) == 1
	return [c + Vector2i(1 if odd else 0, -1), c + Vector2i(0 if odd else -1, -1)]

## 两格之间经过的格序列（E13：快速拖动时鼠标事件会跳格，涂/擦要补上中间格）。
## 像素线段按 1/4 格采样再 pick_cell——投影无关（正交/等距/六边都按真实轮廓命中），
## 去重后保持先后顺序，首尾含 a/b。
func cells_between(a: Vector2i, b: Vector2i) -> Array:
	var out: Array = [a]
	if a == b:
		return out
	var pa := cell_center_px(a)
	var pb := cell_center_px(b)
	var dist := pa.distance_to(pb)
	var steps := maxi(1, ceili(dist / maxf(cell_max() * 0.25, 1.0)))
	var seen := {a: true}
	var last := a
	for i in range(1, steps + 1):
		var c := pick_cell(pa.lerp(pb, float(i) / float(steps)))
		if c != last:
			if not seen.has(c):
				seen[c] = true
				out.append(c)
			last = c
	if out[out.size() - 1] != b:
		out.append(b)
	return out

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
