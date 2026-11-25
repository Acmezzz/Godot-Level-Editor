class_name EntityNode
extends Sprite2D
## 画布上「一个摆放物」的唯一运行时表示：场景实例（shape=image）与实体实例共用。
##
## 为什么继承 Sprite2D 而不是纯 Node2D：本批先固定**数据形状**（objects[]/transform/
## 浮点坐标），节点类型解耦留到后面。继承后 100+ 处 `as Sprite2D` / `.position` /
## `.texture` 不需要同步改，避免「一半 .asset 一半 .scene」的中间态被漏改。
##
## 数据统一挂在实例上（`asset` / `code` / `layer_id` / `props` / `functions` /
## `data_transform` / `raw`），用类型化访问器读写——不再靠字符串 meta 键散落各文件。
## 属性实现仍是 meta 存储：值与节点同生命周期，撤销/重建时随节点一起丢弃。
##
## 坐标约定：节点 `position` = 实例**锚点**的世界坐标。
##   center（缺省）：position = (x+0.5, y+0.5) * tile → x/y 是格中心所在的格
##   top_left     ：position = (x, y) * tile         → x/y 是矩形左上角所在格
##   bottom_center：position = (x+0.5, y+1) * tile
## 旧数据（x/y 格坐标、位置格中心、事件区左上格）由 anchor 声明原样还原，不需迁移。

const AssetDecl := preload("res://src/assets/asset_decl.gd")
const PolyViewScript := preload("res://src/canvas/entity_poly_view.gd")
const MapViewData := preload("res://src/map/map_view_data.gd")

## 资产 id（旧的 scene 键已作废）
var asset: String:
	get:
		return str(get_meta("asset", ""))
	set(v):
		set_meta("asset", v)

## 实例码：**仅 kind=entity 有**；场景实例永不产码（两类资产的核心差别）
var code: String:
	get:
		return str(get_meta("code", ""))
	set(v):
		set_meta("code", v)

## 所在层码（= 地图 meta.layers[].id）
var layer_id: String:
	get:
		return str(get_meta("layer", ""))
	set(v):
		set_meta("layer", v)

## 实例参数（只丢空值，保留游戏侧自定义键）
var props: Dictionary:
	get:
		if not has_meta("props"):
			# 缺失时惰性建 meta 条目：直接 `props["k"] = v` 的调用点不能改到临时字典上
			set_meta("props", {})
		var p = get_meta("props")
		return p if p is Dictionary else {}
	set(v):
		set_meta("props", v)

## 实例功能绑定 [{fn, content, name, order, parallel}]
var functions: Array:
	get:
		var f = get_meta("functions", [])
		return f if f is Array else []
	set(v):
		set_meta("functions", v)

## {scale:[sx,sy], rotation: 弧度, flip_h, flip_v}；缺省整键省略（零冗余）
var data_transform: Dictionary:
	get:
		if not has_meta("transform"):
			# 惰性建 meta：`data_transform["k"] = v` 的调用点不能改到临时字典上
			set_meta("transform", {})
		var t = get_meta("transform")
		return t if t is Dictionary else {}
	set(v):
		set_meta("transform", v)

## 加载时的原条目：extract 以它为底覆盖编辑器管辖的键，游戏侧自定义键才不会蒸发
var raw: Dictionary:
	get:
		var r = get_meta("_raw", {})
		return r if r is Dictionary else {}
	set(v):
		set_meta("_raw", v)

## 资产归一化声明（创建时注入；清单改动后整图重建）
var decl: Dictionary:
	get:
		var d = get_meta("_decl", {})
		return d if d is Dictionary else {}
	set(v):
		set_meta("_decl", v)

## 同层内分组：auto（缺省）/ below / above。不是全局 z，落盘时 auto 省略
var z_policy: String:
	get:
		return str(get_meta("zPolicy", "auto"))
	set(v):
		set_meta("zPolicy", v)

## 编辑器专用显示开关（缺省 true，落盘时 true 省略；游戏侧应忽略）
## setter 直接同步真节点 visible（E06）：隐藏必须立刻生效，不能等下一次 refresh_visual
var visible_flag: bool:
	get:
		var v = get_meta("visible", true)
		return v if v is bool else true
	set(v):
		set_meta("visible", v)
		if is_inside_tree():
			visible = v

## 声明尺寸（editorSize / prefab 碰撞尺寸 / 1 格），像素
var base_size: Vector2:
	get:
		var s = get_meta("_size", Vector2.ZERO)
		return s if s is Vector2 else Vector2.ZERO
	set(v):
		set_meta("_size", v)

## 地图格像素尺寸
var tile_px := 16
## 画布 GridSpace 引用（等距口径随画布；null = 退回旧的正交标量口径）
var grid_ref: GridSpace = null
## 贴图按显示框缩放的比例（与数据 transform 的 scale 分开存，互不干扰）
var _fit := Vector2.ONE

## 帧动画预览状态：声明 frames[] 的实体按 8fps 循环（预览口径，游戏侧自定播放节奏）
var _frames: Array = []
var _frame_i := 0
var _frame_t := 0.0

## 建一个摆放物节点（视觉贴图取 thumb；图片场景资产退回资产 texture）
static func create(m: Dictionary, aid: String, size: Vector2, tile: int,
		thumbs: Dictionary = {}, grid: GridSpace = null) -> EntityNode:
	var n := EntityNode.new()
	n.asset = aid
	n.decl = AssetDecl.by_id(m, aid)
	n.tile_px = tile
	n.grid_ref = grid
	n.base_size = size if size != Vector2.ZERO else Vector2(tile, tile)
	var tex: Texture2D = thumbs.get(aid, null)
	if tex == null and str((n.decl as Dictionary).get("shape", "")) == "image":
		tex = texture_of(m, str((n.decl as Dictionary).get("texture", "")))
	# 帧动画声明 frames[]：多帧贴图按固定帧率循环预览（8fps；游戏侧自定播放节奏）
	if tex == null:
		var fr = (n.decl as Dictionary).get("frames", null)
		if fr is Array:
			for rel in fr:
				var t := texture_of(m, str(rel))
				if t != null:
					n._frames.append(t)
			if n._frames.size() > 0:
				tex = n._frames[0]
	n.texture = tex
	n.refresh_visual()
	n._sync_poly_view()
	return n

## 图片资产的贴图按绝对路径缓存（同一张图被多个实例复用，不重复读盘）
static var _img_cache := {}

static func texture_of(m: Dictionary, rel: String) -> Texture2D:
	if rel == "":
		return null
	var base := str(m.get("_dir", ""))
	var p: String = base.path_join(rel) if base != "" else rel
	if _img_cache.has(p):
		var hit = _img_cache[p]
		# 负缓存（加载失败/文件缺失）不能永久钉住：文件后来出现了就得当次读到
		# （F1/P03：重扫后原本缺失的纹理当次可见）。正缓存直接返回，不碰盘。
		if hit != null:
			return hit as Texture2D
		if not FileAccess.file_exists(p):
			return null
		_img_cache.erase(p)
	var tex: Texture2D = null
	if FileAccess.file_exists(p):
		var img := Image.load_from_file(p)
		if img != null:
			tex = ImageTexture.create_from_image(img)
	_img_cache[p] = tex
	return tex

# —— 锚点 / 尺寸 / 变换 ——

func anchor() -> String:
	var a := str(decl.get("anchor", "center"))
	return a if a != "" else "center"

## 实例实际显示尺寸：声明了 sizeFields 就读 props（事件区这类实例各自定大小），
## 否则用构造时算好的 base_size（editorSize / prefab 碰撞尺寸 / 1 格）。
func display_size() -> Vector2:
	var sf := _size_fields()
	if sf.size() >= 2:
		var w := int(props.get(str(sf[0]), 1))
		var h := int(props.get(str(sf[1]), 1))
		var tile_extent := Vector2(grid_ref.tile) if grid_ref != null else Vector2.ONE * float(tile_px)
		return Vector2(maxi(w, 1), maxi(h, 1)) * tile_extent
	return base_size if base_size != Vector2.ZERO else Vector2(tile_px, tile_px)

func _size_fields() -> Array:
	var sf = decl.get("sizeFields", null)
	return sf if sf is Array and (sf as Array).size() >= 2 else []

## 锚点在「格内」的位置（单位=格，与实例尺寸无关）。
## 数据 x/y 只决定「锚点落在哪个格、格内哪个位置」——所以同一格的树不管多高，
## 脚底都在该格底边，不会因为贴图变大而整体下沉。
func anchor_unit() -> Vector2:
	return anchor_unit_of(decl)

static func anchor_unit_of(d: Dictionary) -> Vector2:
	return MapViewData.anchor_unit(d)

## 锚点相对「视觉矩形左上角」的像素偏移（随显示尺寸变，只用于画框/命中/吸附视觉）
func anchor_off() -> Vector2:
	return anchor_off_of(anchor_unit(), display_size())

static func anchor_off_of(unit: Vector2, size: Vector2) -> Vector2:
	return Vector2(unit.x * size.x, unit.y * size.y)

## 数据 x/y → 世界锚点位置。
## 六边（B1）：to_px(整数格) 已经是格中心，不能再把正交的 +anchor_unit 方格偏量塞进去；
## 锚点偏移改为相对格中心的包围盒偏移（center = 0，top_left = 左上，bottom_center = 底中）。
## 排序点（E11）：sortAnchor 把 y-sort 用的 position 偏移到真实排序原点，
## 视觉/命中用 rect() 反向扣回，数据锚点位置不变。
func world_of_grid(gx: float, gy: float) -> Vector2:
	if grid_ref != null:
		return grid_ref.object_anchor_px(Vector2(gx, gy), anchor_unit()) + sort_anchor()
	return (Vector2(gx, gy) + anchor_unit()) * float(tile_px) + sort_anchor()

## 世界位置 → 数据 x/y（保留浮点，吸附由调用方决定）。六边走连续反算，保留亚格。
func grid_of_world(p: Vector2) -> Vector2:
	var q := p - sort_anchor()
	if grid_ref != null:
		return grid_ref.object_anchor_grid(q, anchor_unit())
	return q / float(tile_px) - anchor_unit()

## 排序点偏移（raw.sortAnchor，像素、相对数据锚点；缺省 0 = 锚点即排序点）
func sort_anchor() -> Vector2:
	var sa = raw.get("sortAnchor", null)
	if sa is Array and (sa as Array).size() >= 2:
		return Vector2(float((sa as Array)[0]), float((sa as Array)[1]))
	return Vector2.ZERO

## 实例「所在格」（区域框选/复制/剪切判定用）：拾取视觉矩形左上角所在格。
## 不走锚点格——bottom_center 这类锚点的格号不是矩形起始格。
func cell() -> Vector2i:
	var r := rect()
	if grid_ref != null:
		return grid_ref.pick_cell(r.position)
	return Vector2i(floori(r.position.x / tile_px), floori(r.position.y / tile_px))

func apply_grid(gx: float, gy: float) -> void:
	position = world_of_grid(gx, gy)

## 视觉矩形（层局部坐标）：命中/绘制/选中框共用这一口径。
## 排序点（E11）时 position 是排序原点（锚点 + sortAnchor），视觉矩形反向扣回，
## 保证「改排序点只改遮挡顺序，不改贴图位置」。
func rect() -> Rect2:
	var sz := display_size()
	return Rect2(position - sort_anchor() - anchor_off(), sz)

## 视觉四角（层局部坐标，含 rotation/scale 后的实际形状，E10）：
## 未旋转未缩放时与 rect() 四角一致；旋转/缩放后是真实占位四边形。
## 呈现、命中、框选共用这一份几何，不再拿未旋转外接框当真相。
func quad() -> PackedVector2Array:
	var r := rect()
	var b := Transform2D(data_rotation(), data_scale(), 0.0, Vector2.ZERO)
	return PackedVector2Array([
		position + b.basis_xform(r.position - position),
		position + b.basis_xform(Vector2(r.end.x, r.position.y) - position),
		position + b.basis_xform(r.end - position),
		position + b.basis_xform(Vector2(r.position.x, r.end.y) - position)])

## 数据变换里的旋转（弧度）
func data_rotation() -> float:
	return float(data_transform.get("rotation", 0.0))

## 数据变换里的缩放（缺省 1,1；不带贴图 fit 系数）
func data_scale() -> Vector2:
	var s = data_transform.get("scale", null)
	if s is Array and (s as Array).size() >= 2:
		return Vector2(float((s as Array)[0]), float((s as Array)[1]))
	return Vector2.ONE

## 点是否落在实例实际几何内（层局部坐标）。
## poly/path 资产按声明的真实几何判定（不是占位矩形）：poly 用点集多边形，
## path 用「到折线的距离 ≤ 半线宽 + 容差」——否则一条细线会有一大块空气可点（V4 P1）。
func contains_point(p: Vector2) -> bool:
	if visual_type() != "rect" and not points_local().is_empty():
		return _contains_point_visual(p)
	if is_zero_approx(data_rotation()) and data_scale().is_equal_approx(Vector2.ONE):
		return rect().has_point(p)
	return Geometry2D.is_point_in_polygon(p, quad())

## poly/path 的点集判定：把层局部像素转回未变换的锚点局部，再与点集比较。
func _contains_point_visual(p: Vector2) -> bool:
	var pts := points_local()
	if pts.is_empty():
		return false
	var lp := geometry_transform().affine_inverse() * p
	var arr := PackedVector2Array()
	for q: Vector2 in pts:
		arr.append(q)
	var vis: Dictionary = (decl as Dictionary).get("visual", {}) \
		if (decl as Dictionary).get("visual", null) is Dictionary else {}
	if str(vis.get("type", "rect")) == "path":
		return _near_polyline(lp, arr, maxf(1.0, float(vis.get("width", 3.0))) * 0.5 + 2.0)
	if bool(vis.get("closed", true)):
		for part in geometry_parts():
			var outer := PackedVector2Array(part.points)
			if outer.size() >= 3 and Geometry2D.is_point_in_polygon(lp, outer) and hole_at(lp, part.holes) < 0:
				return true
		return false
	# 不闭合 poly 按折线判（同 path 口径）
	return _near_polyline(lp, arr, 2.0)

## 点到折线的距离是否在容差内（2px 抓取容差：贴着线段就能点中）。
func _near_polyline(p: Vector2, arr: PackedVector2Array, tol: float) -> bool:
	for i in range(arr.size() - 1):
		var c := Geometry2D.get_closest_point_to_segment(p, arr[i], arr[i + 1])
		if p.distance_to(c) <= tol:
			return true
	return false

## 实际几何的轴对齐包围盒（层局部）：框选/并集用
func aabb() -> Rect2:
	if visual_type() != "rect":
		var points := points_local()
		if visual_type() == "poly" and decl.get("visual", {}).get("closed", true):
			for part in geometry_parts().slice(1):
				points.append_array(part.points)
		if not points.is_empty():
			var geometry := geometry_transform()
			var bounds := Rect2(geometry * points[0], Vector2.ZERO)
			for p in points:
				bounds = bounds.expand(geometry * p)
			return bounds.grow(0.5)
	if is_zero_approx(data_rotation()) and data_scale().is_equal_approx(Vector2.ONE):
		return rect()
	var q := quad()
	var r := Rect2(q[0], Vector2.ZERO)
	for pt: Vector2 in q:
		r = r.expand(pt)
	return r

func flipped_h() -> bool:
	return bool(data_transform.get("flip_h", false))

func flipped_v() -> bool:
	return bool(data_transform.get("flip_v", false))

## 翻转（F 键）：数据写 transform，视觉跟着翻
func apply_flip_h(v: bool) -> void:
	if v:
		data_transform["flip_h"] = true
	else:
		data_transform.erase("flip_h")
	refresh_visual()

## 原子写入 sortAnchor（像素偏移）：0 = 删键（缺省零冗余）。
## position 是排序原点（= 视觉锚点 + sortAnchor）：改排序点时同步平移 position，
## 视觉位置由 rect() 反向扣回，贴图不漂移、数据坐标不变。
func set_sort_anchor(off: Vector2) -> void:
	var old := sort_anchor()
	var r: Dictionary = raw
	if is_zero_approx(off.x) and is_zero_approx(off.y):
		r.erase("sortAnchor")
	else:
		r["sortAnchor"] = [off.x, off.y]
	raw = r
	position += off - old
	refresh_visual()

func toggle_flip_h() -> void:
	apply_flip_h(not flipped_h())

## R 键：旋转 90°（data_transform.rotation 弧度；fposmod 归一，回到 0 时整键省略）
func rotate_90() -> void:
	var r := fposmod(float(data_transform.get("rotation", 0.0)) + PI * 0.5, TAU)
	if is_zero_approx(r):
		data_transform.erase("rotation")
	else:
		data_transform["rotation"] = r
	refresh_visual()

## [ ] 键：等比缩放步进（scale [sx,sy] 各加 delta，下限 0.1；回到 1.0 时整键省略）
func scale_step(d: float) -> void:
	var s = data_transform.get("scale", null)
	var sx := 1.0
	var sy := 1.0
	if s is Array and (s as Array).size() >= 2:
		sx = float((s as Array)[0])
		sy = float((s as Array)[1])
	sx = maxf(0.1, sx + d)
	sy = maxf(0.1, sy + d)
	if is_zero_approx(sx - 1.0) and is_zero_approx(sy - 1.0):
		data_transform.erase("scale")
	else:
		data_transform["scale"] = [sx, sy]
	refresh_visual()

## transform 是否等于缺省形态（写盘时整键省略）
func transform_is_default() -> bool:
	var s = data_transform.get("scale", null)
	var sx := 1.0
	var sy := 1.0
	if s is Array and (s as Array).size() >= 2:
		sx = float((s as Array)[0])
		sy = float((s as Array)[1])
	return is_equal_approx(sx, 1.0) and is_equal_approx(sy, 1.0) \
		and is_zero_approx(float(data_transform.get("rotation", 0.0))) \
		and not flipped_h() and not flipped_v()

func is_entity() -> bool:
	return str(decl.get("kind", "")) == "entity"

## —— R-02 几何段：poly/path 呈现与点集存取 ——

## 声明 visual.type：rect（缺省占位矩形）/ poly / path
func visual_type() -> String:
	var v = (decl as Dictionary).get("visual", null)
	if not (v is Dictionary):
		return "rect"
	return str((v as Dictionary).get("type", "rect"))

## 点集（Array of Vector2，局部像素、相对锚点、未翻转）：props.points 为真源，
## 缺省退回声明 visual.points（声明的缺省形状），都没有 = 空集。
func points_local() -> Array:
	var points_value = props.get("points", null)
	if points_value is Array:
		return _vec2s(points_value)
	var v = (decl as Dictionary).get("visual", null)
	if v is Dictionary:
		var dv = (v as Dictionary).get("points", null)
		if dv is Array:
			return _vec2s(dv)
	return []

func _vec2s(rows: Array) -> Array:
	var out := []
	for pt in rows:
		var a := pt as Array
		if a != null and a.size() >= 2 \
				and (a[0] is float or a[0] is int) and (a[1] is float or a[1] is int):
			var p := Vector2(float(a[0]), float(a[1]))
			if p.is_finite():
				out.append(p)
	return out

## 写回点集（JSON 友好：[[x, y], ...]，数值两位小数）。
## props 必须走 setter 回写：meta 缺失时 getter 返回临时字典，直接下标写会丢。
func points_write(pts: Array) -> void:
	var p: Dictionary = props
	p["points"] = _encode_points(pts)
	props = p

func holes_local() -> Array:
	var out := []
	var hole_rows = props.get("holes", [])
	if hole_rows is Array:
		for row in hole_rows:
			out.append(_vec2s(row) if row is Array else [])
	return out

func _encode_points(points: Array) -> Array:
	var out := []
	for p: Vector2 in points:
		out.append([roundf(p.x * 100.0) / 100.0, roundf(p.y * 100.0) / 100.0])
	return out

func geometry_point_from_world(world: Vector2) -> Vector2:
	return _geometry_world_transform().affine_inverse() * world

func geometry_point_to_world(p: Vector2) -> Vector2:
	return _geometry_world_transform() * p

func geometry_transform() -> Transform2D:
	return MapViewData.object_transform(position - sort_anchor(), data_transform)

func _geometry_world_transform() -> Transform2D:
	var parent := get_parent() as Node2D
	return parent.global_transform * geometry_transform() if parent != null else geometry_transform()

func hole_at(local: Vector2, holes: Array) -> int:
	for i in holes.size():
		var ring := PackedVector2Array(holes[i])
		if ring.size() >= 3 and Geometry2D.is_point_in_polygon(local, ring):
			return i
	return -1

func geometry_parts() -> Array:
	var parts := [{"points": points_local(), "holes": holes_local()}]
	var part_rows = props.get("parts", [])
	if part_rows is Array:
		for part in part_rows:
			if part is Dictionary and part.get("points") is Array:
				var holes := []
				var rows = part.get("holes", [])
				if rows is Array:
					for row in rows:
						holes.append(_vec2s(row) if row is Array else [])
				parts.append({"points": _vec2s(part.points), "holes": holes})
	return parts

func geometry_parts_write(parts: Array) -> void:
	var p := props.duplicate()
	p["points"] = _encode_points(parts[0].points)
	if parts[0].holes.is_empty():
		p.erase("holes")
	else:
		p["holes"] = parts[0].holes.map(_encode_points)
	var extra := []
	for part in parts.slice(1):
		var row := {"points": _encode_points(part.points)}
		if not part.holes.is_empty():
			row["holes"] = part.holes.map(_encode_points)
		extra.append(row)
	if extra.is_empty():
		p.erase("parts")
	else:
		p["parts"] = extra
	props = p

## poly/path 呈现子节点随声明装配（rect 资产无子节点）；已挂则重绘
func _sync_poly_view() -> void:
	var want := visual_type() != "rect"
	var pv := get_node_or_null("PolyView")
	if want and pv == null:
		var pv2 = PolyViewScript.new()
		pv2.name = "PolyView"
		pv2.node = self
		add_child(pv2)
		pv = pv2
	elif not want and pv != null:
		pv.queue_free()
	if want:
		pv.transform = transform.affine_inverse() * geometry_transform()
		pv.queue_redraw()

## 视觉就位：贴图按显示框等比塞入（放大取整数倍避免糊），数据 scale/rotation/flip 叠加。
func refresh_visual() -> void:
	var sz := display_size()
	_fit = Vector2.ONE
	if texture != null:
		var tsz := texture.get_size()
		if tsz.x > 0.0 and tsz.y > 0.0:
			var k := minf(sz.x / tsz.x, sz.y / tsz.y)
			if k > 1.0:
				k = maxf(1.0, floorf(k))
			_fit = Vector2(k, k)
	var s = data_transform.get("scale", null)
	var sx := 1.0
	var sy := 1.0
	if s is Array and (s as Array).size() >= 2:
		sx = float((s as Array)[0])
		sy = float((s as Array)[1])
	scale = Vector2(_fit.x * sx, _fit.y * sy)
	rotation = float(data_transform.get("rotation", 0.0))
	flip_h = flipped_h()
	flip_v = flipped_v()
	# 贴图默认以 position 为中心；锚点非 center 时用 offset 把贴图推到 rect() 的位置。
	# offset 是「未缩放局部坐标」（Sprite2D 先加 offset 再乘 scale），所以要除掉 scale。
	# 排序点（E11）：position 含 sortAnchor，视觉反向扣回，贴图不随排序点漂移。
	var sc := scale
	var sa := sort_anchor()
	offset = Vector2(
		(display_size().x * 0.5 - anchor_off().x - sa.x) / sc.x if sc.x != 0.0 else 0.0,
		(display_size().y * 0.5 - anchor_off().y - sa.y) / sc.y if sc.y != 0.0 else 0.0)
	visible = visible_flag
	# R-02：poly/path 呈现子节点随声明装配；点集/变换/翻转变化都经 refresh_visual → _sync_poly_view 重绘
	_sync_poly_view()

## 帧动画预览：frames[] 多于 1 帧时按 8fps 循环换帧；换帧后 refresh_visual 重算
## fit/offset（帧尺寸不一致时也对）。游戏侧播放节奏自定，编辑器预览仅为确认帧序。
func _process(delta: float) -> void:
	if _frames.size() > 1:
		_frame_t += delta
		if _frame_t >= 0.125:
			_frame_t = 0.0
			_frame_i = (_frame_i + 1) % _frames.size()
			texture = _frames[_frame_i]
			refresh_visual()
