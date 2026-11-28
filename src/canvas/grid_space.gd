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
## B3：格拓扑。`quads`（缺省）= 平行四边形格；`triangles` = 每个平行四边形列切成
## 两个共斜边的三角格。三角格里格号 (i, row) 的 i 是**三角列**：
## 平行四边形列 c = floor(i / 2)，i 的奇偶选半格（偶 = 左下 (0,0),(1,0),(0,1)；
## 奇 = 右上 (1,1),(0,1),(1,0)）。六边形投影不支持三角拓扑。
var topology := "quads"
## B3：可选双基向量斜平面（meta.gridBasis: [[ux,uy],[vx,vy]]）。
## 非零时 to_px = g.x·u + g.y·v，to_grid = 基矩阵的逆——格仍是平行四边形（含正交/斜平行两种特例）。
## 与 projection 正交：projection 决定缺省几何，basis 显式覆盖它（校验保证有限且可逆）。
var basis_u := Vector2.ZERO
var basis_v := Vector2.ZERO
var has_basis := false

func _init(t: Vector2i = Vector2i(16, 16), proj: String = "orthogonal", basis: Array = []) -> void:
	tile = t
	if proj == "isometric" or proj == "hexagonal":
		projection = proj
	else:
		projection = "orthogonal"
	if basis.size() == 2:
		var u: Variant = basis[0]
		var v: Variant = basis[1]
		if u is Vector2 and v is Vector2:
			set_basis(u, v)

## 设置双基向量。拒零/共线（行列式 0）与非有限值——静默保持原几何。
func set_basis(u: Vector2, v: Vector2) -> bool:
	if not _finite2(u) or not _finite2(v):
		return false
	if absf(u.x * v.y - u.y * v.x) < 0.000001:
		return false
	basis_u = u
	basis_v = v
	has_basis = true
	return true

static func _finite2(p: Vector2) -> bool:
	return is_finite(p.x) and is_finite(p.y)

## 解析 meta.gridTopology：缺键/`quads` = 平行四边格；`triangles` = 三角格。
## 三角格依赖列内两半格的划分，六边投影没有平行四边形列 → 组合非法。
static func parse_topology(meta: Dictionary, proj: String) -> Dictionary:
	var raw := str(meta.get("gridTopology", ""))
	if raw == "" or raw == "quads":
		return {"ok": true, "topology": "quads", "why": ""}
	if raw != "triangles":
		return {"ok": false, "topology": "quads", "why": "gridTopology 只能是 \"quads\" / \"triangles\""}
	if proj == "hexagonal":
		return {"ok": false, "topology": "quads", "why": "hexagonal 投影不支持 triangles 拓扑"}
	return {"ok": true, "topology": "triangles", "why": ""}

## 设置格拓扑。非法值静默保持 quads（调用方已按 parse_topology 报过具体键）。
func set_topology(topo: String) -> void:
	topology = "triangles" if topo == "triangles" and not is_hex() else "quads"

func is_tri() -> bool:
	return topology == "triangles"

# —— B3 三角格：列映射与半格几何（纯函数，绘制/命中/邻接共用） ——

## 三角列 i → (平行四边形列 c, 是否奇半格)。i 奇 = 右上三角。
static func tri_col(i: int) -> Dictionary:
	return {"c": i >> 1 if i >= 0 else int(floorf(float(i) / 2.0)), "odd": posmod(i, 2) == 1}

## 三角格 (i, row) 的三个格空间顶点（单位基下，再经 to_px 变换）。
## 偶半格 (0,0),(1,0),(0,1)；奇半格 (1,1),(0,1),(1,0)。c,row 平移后三点一起移。
static func tri_unit_points(i: int, row: int) -> PackedVector2Array:
	var c := float(tri_col(i).c)
	var odd := bool(tri_col(i).odd)
	var g := Vector2(c, float(row))
	if odd:
		return PackedVector2Array([g + Vector2(1, 1), g + Vector2(0, 1), g + Vector2(1, 0)])
	return PackedVector2Array([g + Vector2(0, 0), g + Vector2(1, 0), g + Vector2(0, 1)])

## 三角格 (i, row) 的像素多边形（to_px 作用在三个单位顶点上）。
func tri_polygon(i: int, row: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p: Vector2 in tri_unit_points(i, row):
		out.append(to_px(p))
	return out

## 像素 → 三角格号。先反算连续格，复用统一的半格判定。
func pick_tri(px: Vector2) -> Vector2i:
	return _triangle_cell(to_grid(px))

## 三角格的共边邻格（每个三角形 3 条边 → 3 个邻格）。
## 偶半格 (0,0),(1,0),(0,1)：底边 y=row → 同列奇半格的上方一格；左边 x=c → 左邻列的奇半格；
## 斜边 → 本列奇半格（同一平行四边形的另一半）。
## 奇半格 (1,1),(0,1),(1,0)：顶边 y=row+1 → 同列偶半格的下方一格；右边 x=c+1 → 右邻列的偶半格；
## 斜边 → 本列偶半格。三边互为镜像，按 (三角列, 行) 平移。
func neighbors_tri(i: int, row: int) -> Array:
	if posmod(i, 2) == 0:
		return [Vector2i(i + 1, row), Vector2i(i + 1, row - 1), Vector2i(i - 1, row)]
	return [Vector2i(i - 1, row), Vector2i(i - 1, row + 1), Vector2i(i + 1, row)]

## 三角格邻居版 neighbors()：拓扑是 triangles 时按三角邻接，否则保持原口径。
func neighbors_any(c: Vector2i) -> Array:
	if is_tri():
		return neighbors_tri(c.x, c.y)
	return neighbors(c)

## 三角格中心像素（三点平均）——落点/角标/拖动把手用。
func tri_center_px(i: int, row: int) -> Vector2:
	var poly := tri_polygon(i, row)
	return (poly[0] + poly[1] + poly[2]) / 3.0

## 三角格纹理落位：按三角形的轴对齐包围盒（图集切片拉伸到该包围盒，再按三角裁）
func tri_tex_rect(i: int, row: int) -> Rect2:
	var poly := tri_polygon(i, row)
	var mn := poly[0]
	var mx := poly[0]
	for p: Vector2 in poly:
		mn = mn.min(p)
		mx = mx.max(p)
	return Rect2(mn, mx - mn)

## 连续格坐标（平行四边形列口径，to_grid/连续拖动用）→ **本拓扑的格号**。
## 三角拓扑把平行四边形列折成半格列。需要六边形内轮廓命中时使用 pick_cell。
func cell_of_continuous(g: Vector2) -> Vector2i:
	if is_tri():
		return _triangle_cell(g)
	return Vector2i(floori(g.x), floori(g.y))

static func _triangle_cell(g: Vector2) -> Vector2i:
	var column := floori(g.x)
	var row := floori(g.y)
	return Vector2i(column * 2 + (1 if g.x - column + g.y - row > 1.0 else 0), row)

## 本拓扑格号 → 连续格坐标的**格原点**（三角拓扑取所在平行四边形列，半格奇偶丢失是
## 连续坐标的固有粒度：实例位置本身是浮点，落位仍以它为准）。
func cell_origin_continuous(c: Vector2i) -> Vector2:
	if is_tri():
		return Vector2(float(tri_col(c.x).c), float(c.y))
	return Vector2(c)

static func cell_columns(w: int, triangular: bool) -> int:
	return 2 * w if triangular else w

## 三角拓扑的 x 是三角列（0..2w-1）。
func cell_in_map(c: Vector2i, w: int, h: int) -> bool:
	return c.y >= 0 and c.y < h and c.x >= 0 and c.x < cell_columns(w, is_tri())

static func parse_basis(meta: Dictionary) -> Dictionary:
	if not meta.has("gridBasis"):
		return {"ok": true, "u": Vector2.ZERO, "v": Vector2.ZERO, "why": ""}
	var raw = meta.get("gridBasis", null)
	if not (raw is Array) or (raw as Array).size() != 2:
		return {"ok": false, "u": Vector2.ZERO, "v": Vector2.ZERO, "why": "gridBasis 必须是 [[ux,uy],[vx,vy]]"}
	var row := func(r) -> Variant:
		if not (r is Array) or (r as Array).size() != 2:
			return null
		var a = (r as Array)[0]
		var b = (r as Array)[1]
		if not ((a is int or a is float) and (b is int or b is float)):
			return null
		var u := Vector2(float(a), float(b))
		if _finite2(u):
			return u
		return null
	var u2 = row.call((raw as Array)[0])
	var v2 = row.call((raw as Array)[1])
	if u2 == null or v2 == null:
		return {"ok": false, "u": Vector2.ZERO, "v": Vector2.ZERO, "why": "gridBasis 的行必须是两个有限数值"}
	var uu: Vector2 = u2
	var vv: Vector2 = v2
	if absf(uu.x * vv.y - uu.y * vv.x) < 0.000001:
		return {"ok": false, "u": Vector2.ZERO, "v": Vector2.ZERO, "why": "gridBasis 不可逆（两向量共线或为零）"}
	return {"ok": true, "u": uu, "v": vv, "why": ""}

func is_iso() -> bool:
	return projection == "isometric"

func is_hex() -> bool:
	return projection == "hexagonal"

## 几何意义上的六边：hex 投影**且没有显式 gridBasis**。
## 有 basis 时格是平行四边形（basis 优先于投影预设），六边的格中心/六角多边形/最近中心拾取
## 都不成立——原先这几处各判 is_hex()、其余走 to_px(basis)，同一张图两套口径（V4 §4.3）。
func is_hex_geom() -> bool:
	return projection == "hexagonal" and not has_basis

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

## B3（§7.3）：生效格空间解析的统一入口——按「明确的逐图投影 → 项目默认 → 正交」确定预设，
## tileSize（清单级）/ gridBasis / gridTopology 按同一生效预设验证。
## 返回 {grid, issues}：grid = 配置好的 GridSpace（非法组合仍给可用几何，非法项以 issue 报出，
## 正式写入是否阻止由调用方按 issues 决定）；issues = [{path, message}]。
static func resolve(meta: Dictionary, manifest: Dictionary) -> Dictionary:
	var issues: Array = []
	var proj := str(meta.get("gridProjection", ""))
	if proj == "":
		proj = project_projection(manifest)
	if proj != "orthogonal" and proj != "isometric" and proj != "hexagonal":
		issues.append({"path": "meta.gridProjection", "message": "未知投影 %s，按正交处理" % proj})
		proj = "orthogonal"
	var grid := GridSpace.new(tile_size_of(manifest), proj)
	var bs := parse_basis(meta)
	if not bool(bs.get("ok", false)):
		issues.append({"path": "meta.gridBasis", "message": str(bs.get("why", ""))})
	elif (bs.get("u", Vector2.ZERO) as Vector2) != Vector2.ZERO:
		if not grid.set_basis(bs.get("u", Vector2.ZERO), bs.get("v", Vector2.ZERO)):
			issues.append({"path": "meta.gridBasis", "message": "基向量未生效（set_basis 拒绝）"})
	var tp := parse_topology(meta, proj)
	if not bool(tp.get("ok", false)):
		issues.append({"path": "meta.gridTopology", "message": str(tp.get("why", ""))})
	elif str(tp.get("topology", "quads")) == "triangles":
		grid.set_topology("triangles")
	return {"grid": grid, "issues": issues}

## A tile layer may own its coordinate system. Its declaration has no inherited basis/topology.
static func resolve_tile_layer(layer: Dictionary, manifest: Dictionary, root: GridSpace) -> Dictionary:
	if not layer.has("tileGrid"):
		return {"grid": root, "issues": []}
	var own = layer.tileGrid
	if not own is Dictionary:
		return {"grid": root, "issues": [{"path": "tileGrid", "message": "必须是格空间对象"}]}
	if not own.get("gridProjection") is String or str(own.gridProjection) not in ["orthogonal", "isometric", "hexagonal"]:
		return {"grid": root, "issues": [{"path": "tileGrid.gridProjection", "message": "必须显式选择正交、等距或六边形"}]}
	var resolved := resolve(own, manifest)
	var issues: Array[Dictionary] = []
	for issue in resolved.issues:
		issues.append({"path": issue.path.replace("meta.", "tileGrid."), "message": issue.message})
	return {"grid": resolved.grid if issues.is_empty() else root, "issues": issues}

## Stable across JSON round trips; layer transforms do not affect local grid geometry.
func geometry_key() -> String:
	var geometry := [basis_u.x, basis_u.y, basis_v.x, basis_v.y] if has_basis else [projection, tile.x, tile.y]
	return JSON.stringify([topology, geometry], "", true, true)

## 格坐标（浮点，含格内分数）→ 像素。正交 = 左上角系；等距 = 菱形顶点系；六边 = 格中心系（仅整数格有格中心语义）。
func to_px(g: Vector2) -> Vector2:
	if has_basis:
		return basis_u * g.x + basis_v * g.y   # B3：斜平面（平行四边形）优于投影预设
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
	if has_basis:
		var det := basis_u.x * basis_v.y - basis_u.y * basis_v.x
		if det == 0.0:
			return Vector2.ZERO
		# 逆矩阵乘：g = A⁻¹p
		return Vector2(
			(basis_v.y * p.x - basis_v.x * p.y) / det,
			(-basis_u.y * p.x + basis_u.x * p.y) / det)
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
## B3 三角拓扑：返回值仍是 Vector2i（三角列 i, row），按对角线 x+y=1 分半格。
## 像素视口的保守格窗口，供瓦片块/碰撞查询使用。六边取整及格边界留两格余量。
func cell_window(rect: Rect2) -> Rect2i:
	var low := Vector2(INF, INF)
	var high := Vector2(-INF, -INF)
	for point in [rect.position, rect.end, Vector2(rect.position.x, rect.end.y), Vector2(rect.end.x, rect.position.y)]:
		var coord := to_grid(point)
		low = low.min(coord)
		high = high.max(coord)
	var a := Vector2i(floori(low.x) - 2, floori(low.y) - 2)
	var b := Vector2i(ceili(high.x) + 3, ceili(high.y) + 3)
	if is_tri():
		a.x *= 2
		b.x *= 2
	return Rect2i(a, b - a)

func pick_cell(px: Vector2) -> Vector2i:
	if is_tri():
		return pick_tri(px)
	var g := to_grid(px)
	if not is_hex_geom():
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
	if not is_hex_geom():
		return to_grid(px)
	var w := float(tile.x)
	var h := float(tile.y)
	if w <= 0.0 or h <= 0.0:
		return Vector2.ZERO
	var gy := (px.y - h * 0.5) / (h * 0.75)
	var off := 0.5 if posmod(floori(gy), 2) == 1 else 0.0
	return Vector2((px.x - w * 0.5) / w - off, gy)

## 实例连续格坐标与图层局部锚点互换。排序偏移由实例节点单独处理。
func object_anchor_px(coordinates: Vector2, unit: Vector2) -> Vector2:
	if is_hex_geom():
		return to_px(coordinates) + (unit - Vector2(0.5, 0.5)) * Vector2(tile)
	return to_px(coordinates + unit)

func object_anchor_grid(point: Vector2, unit: Vector2) -> Vector2:
	if is_hex_geom():
		return to_continuous_grid(point - (unit - Vector2(0.5, 0.5)) * Vector2(tile))
	return to_grid(point) - unit

## 拓扑格号位移 → 像素平移（只给区域移动/粘贴用的 **cell 索引** 换算）。
## 三角拓扑的格号 x 是**三角列**（两列共用一个平行四边形列），所以要先折半再走 to_px；
## 直接 to_px(delta) 会把 1 个三角列当成 1 个整列（V4 P1：两种列混用）。
## 注意：实例的连续格坐标（EntityNode.apply_grid）用的是平行四边形列，不走这里。
func delta_px(d: Vector2i) -> Vector2:
	if is_tri():
		return to_px(Vector2(float(d.x) * 0.5, float(d.y))) - to_px(Vector2.ZERO)
	return to_px(Vector2(d)) - to_px(Vector2.ZERO)

## 区域偏移使用六边形轴坐标，避免奇偶行切换时形状变形。
func _region_axes(c: Vector2i) -> Vector2i:
	return Vector2i(c.x - floori(float(c.y) * 0.5), c.y) if is_hex_geom() else c

func relative_cell(c: Vector2i, origin: Vector2i) -> Vector2i:
	return _region_axes(c) - _region_axes(origin)

func cell_from_offset(origin: Vector2i, offset: Vector2i) -> Vector2i:
	var q := _region_axes(origin) + offset
	return Vector2i(q.x + floori(float(q.y) * 0.5), q.y) if is_hex_geom() else q

## 三角形只做保朝向的整列平移。目标半列与来源不同时吸附到同一完整列。
func region_origin(origin: Vector2i, parity: int) -> Vector2i:
	if is_tri() and parity >= 0 and posmod(origin.x, 2) != parity:
		origin.x = floori(float(origin.x) * 0.5) * 2 + parity
	return origin

func region_origin_px(c: Vector2i) -> Vector2:
	return to_px(cell_origin_continuous(c))

## cell 的中心像素（正交 = 方形中心；等距 = 菱形中心；六边 = 格中心，与 TileMapLayer.map_to_local 口径一致）
func cell_center_px(c: Vector2i) -> Vector2:
	if is_tri():
		return tri_center_px(c.x, c.y)   # B3：三角形重心
	if is_hex_geom():
		return to_px(Vector2(c))
	return to_px(Vector2(c) + Vector2(0.5, 0.5))

## cell 的像素多边形（正交 = 方形四角；等距 = 菱形四角 = to_px 映射格空间正方形；六边 = 尖顶六角；
## B3 三角拓扑 = 半格三角形，格号是三角列 (i, row)）
func cell_polygon(c: Vector2i) -> PackedVector2Array:
	if is_tri():
		return tri_polygon(c.x, c.y)
	if is_hex_geom():
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

## **平行四边形列**矩形 [a, b) 的像素多边形——地图边界/包围盒专用：这里的 a/b 是
## 连续格坐标（三角拓扑的 w 也是列数，不是三角列），所以不做 tri 折算。
## 与 grid_polygon 分工：那个吃「格号」（三角拓扑 = 三角列），这个吃「列号」。
func map_rect_polygon(a: Vector2i, b: Vector2i) -> PackedVector2Array:
	if is_hex_geom():
		return grid_polygon_hex_bbox(a, b)
	var g0 := Vector2(a)
	var g1 := Vector2(b)
	return PackedVector2Array([
		to_px(g0), to_px(Vector2(g1.x, g0.y)),
		to_px(g1), to_px(Vector2(g0.x, g1.y))])

## 六边：四角 cell 的六角外接矩形（与 grid_polygon 的六边分支同一口径）
func grid_polygon_hex_bbox(a: Vector2i, b: Vector2i) -> PackedVector2Array:
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

## 格空间矩形 [a, b) 的像素多边形（区域选区/笔刷块统一口径；六边 = 四角 cell 包围盒近似）
## 三角拓扑的 a/b 是**三角列**（两列 = 一个平行四边形列）：按 x/2 折算，否则选区轮廓
## 与真实覆盖范围差一倍（V4 P1）。地图边界不要用这个（那是列号，见 map_rect_polygon）。
func grid_polygon(a: Vector2i, b: Vector2i) -> PackedVector2Array:
	if is_tri():
		var t0 := Vector2(float(a.x) * 0.5, float(a.y))
		var t1 := Vector2(float(b.x) * 0.5, float(b.y))
		return PackedVector2Array([
			to_px(t0), to_px(Vector2(t1.x, t0.y)),
			to_px(t1), to_px(Vector2(t0.x, t1.y))])
	if is_hex_geom():
		return grid_polygon_hex_bbox(a, b)
	var g0 := Vector2(a)
	var g1 := Vector2(b)
	return PackedVector2Array([
		to_px(g0), to_px(Vector2(g1.x, g0.y)),
		to_px(g1), to_px(Vector2(g0.x, g1.y))])

## 瓦片纹理（尺寸 cs）在 cell 的落位矩形：正交 = 左上对齐；等距/六边 = 格中心居中（包围盒）。
## B3 斜平面：平行四边形没有全局「轴对齐左上角」，按格原点（to_px(c)）为锚左上对齐——
## 与正交的 g·tile 口径一致（正交 basis = [tile,0],[0,tile] 时逐位相同）。
func cell_tex_rect(c: Vector2i, cs: Vector2i) -> Rect2:
	if is_tri():
		return tri_tex_rect(c.x, c.y)   # B3：三角形包围盒
	if has_basis:
		return Rect2(to_px(Vector2(c)), Vector2(cs))
	if is_iso() or is_hex_geom():
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
	var hi := Vector2i(ceili(gmax.x), ceili(gmax.y)) + Vector2i(1, 1)
	if is_tri():
		# B3 三角网格线 = 平行四边形网格 + 每个平行四边形格的对角线（x+y = c+c+1 那条，即
		# 单位基里的 (c+1,c)→(c,c+1) 斜线，把格分成左下/右上两个三角）。
		var first_col := maxi(lo.x, map_rect.position.x)
		var end_col := mini(hi.x, map_rect.end.x)
		var first_row := maxi(lo.y, map_rect.position.y)
		var end_row := mini(hi.y, map_rect.end.y)
		for i in range(first_col, end_col + 1):
			out.append(to_px(Vector2(i, first_row)))
			out.append(to_px(Vector2(i, end_row)))
		for j in range(first_row, end_row + 1):
			out.append(to_px(Vector2(first_col, j)))
			out.append(to_px(Vector2(end_col, j)))
		for i2 in range(first_col, end_col):
			for j2 in range(first_row, end_row):
				out.append(to_px(Vector2(i2 + 1, j2)))
				out.append(to_px(Vector2(i2, j2 + 1)))
		return out
	if is_hex_geom():
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
	if not is_hex_geom():
		return [c + Vector2i(1, 0), c + Vector2i(-1, 0), c + Vector2i(0, 1), c + Vector2i(0, -1)]
	var odd := posmod(c.y, 2) == 1
	# odd-r：奇行整体右移半格，两行之间的邻格对随奇偶切换：
	# 奇行上/下邻 = (+1,∓1) 与 (0,∓1)；偶行 = (0,∓1) 与 (-1,∓1)。
	# 这里必须写成「同行两格 + 斜向两对」共 6 个，不能拿 (0,±1) 顶替斜向那对（会重复且漏边）。
	var d := 1 if odd else -1
	return [
		c + Vector2i(1, 0), c + Vector2i(-1, 0),
		c + Vector2i(0, -1), c + Vector2i(0, 1),
		c + Vector2i(d, -1), c + Vector2i(d, 1),
	]

## 「上邻」（顶面策略用）：正交/等距 = (0,-1)；六边 = 视觉上方两格（奇偶各一）；
## 三角 = 真实邻格里行号更小的那些（三角没有 (0,-1) 这种邻居，不能用假邻接判顶面）。
func up_neighbors(c: Vector2i) -> Array:
	if is_tri():
		var up: Array = []
		var same: Array = []
		for nb: Vector2i in neighbors_tri(c.x, c.y):
			if nb.y < c.y:
				up.append(nb)
			elif nb.y == c.y and nb.x > c.x:
				same.append(nb)
		return up if not up.is_empty() else same
	if not is_hex_geom():
		return [c + Vector2i(0, -1)]
	var odd := posmod(c.y, 2) == 1
	return [c + Vector2i(1 if odd else 0, -1), c + Vector2i(0 if odd else -1, -1)]

## 两格之间的共边线段（§4.2：格边的**几何**归 GridSpace，身份串归 EdgeRef）。
## 只返回真正的共边。非邻格或几何退化时返回空。
## 点选/下拉/悬停/审计全走这里，避免「同一条边在几处各自算」。
func edge_between(a: Vector2i, b: Vector2i) -> PackedVector2Array:
	if not neighbors_any(a).has(b):
		return PackedVector2Array()
	var pa := cell_polygon(a)
	var pb := cell_polygon(b)
	var shared := PackedVector2Array()
	for p: Vector2 in pa:
		for q: Vector2 in pb:
			if p.distance_squared_to(q) < 0.01:
				shared.append(p)
				break
	if shared.size() == 2:
		return shared
	return PackedVector2Array()

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
## 正交 = 精确矩形；等距/斜基 = 网格多边形包围盒（精确）；六边 = 四角 cell 包围盒（近似）；
## 三角 = 整列平行四边形（地图范围 w×h 是**列数**，不是三角列数，V4 P1）。
func map_bounds(map_rect: Rect2i) -> Rect2:
	if is_iso() or is_hex_geom() or is_tri() or has_basis:
		var pts := map_rect_polygon(map_rect.position, map_rect.end)
		var mn := pts[0]
		var mx := pts[0]
		for p: Vector2 in pts:
			mn = mn.min(p)
			mx = mx.max(p)
		return Rect2(mn, mx - mn)
	return Rect2(Vector2(map_rect.position) * Vector2(tile), Vector2(map_rect.size) * Vector2(tile))
