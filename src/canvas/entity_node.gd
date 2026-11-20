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
		var p = get_meta("props", {})
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
		var t = get_meta("transform", {})
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
var visible_flag: bool:
	get:
		var v = get_meta("visible", true)
		return v if v is bool else true
	set(v):
		set_meta("visible", v)

## 声明尺寸（editorSize / prefab 碰撞尺寸 / 1 格），像素
var base_size: Vector2:
	get:
		var s = get_meta("_size", Vector2.ZERO)
		return s if s is Vector2 else Vector2.ZERO
	set(v):
		set_meta("_size", v)

## 地图格像素尺寸
var tile_px := 16
## 贴图按显示框缩放的比例（与数据 transform 的 scale 分开存，互不干扰）
var _fit := Vector2.ONE

## 建一个摆放物节点（视觉贴图取 thumb；图片场景资产退回资产 texture）
static func create(m: Dictionary, aid: String, size: Vector2, tile: int,
		thumbs: Dictionary = {}) -> EntityNode:
	var n := EntityNode.new()
	n.asset = aid
	n.decl = AssetDecl.by_id(m, aid)
	n.tile_px = tile
	n.base_size = size if size != Vector2.ZERO else Vector2(tile, tile)
	var tex: Texture2D = thumbs.get(aid, null)
	if tex == null and str((n.decl as Dictionary).get("shape", "")) == "image":
		tex = texture_of(m, str((n.decl as Dictionary).get("texture", "")))
	n.texture = tex
	n.refresh_visual()
	return n

## 图片资产的贴图按绝对路径缓存（同一张图被多个实例复用，不重复读盘）
static var _img_cache := {}

static func texture_of(m: Dictionary, rel: String) -> Texture2D:
	if rel == "":
		return null
	var base := str(m.get("_dir", ""))
	var p: String = base.path_join(rel) if base != "" else rel
	if _img_cache.has(p):
		return _img_cache[p]
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
		return Vector2(maxi(w, 1) * tile_px, maxi(h, 1) * tile_px)
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
	match str(d.get("anchor", "center")):
		"top_left":
			return Vector2.ZERO
		"bottom_center":
			return Vector2(0.5, 1.0)
		_:
			return Vector2(0.5, 0.5)

## 锚点相对「视觉矩形左上角」的像素偏移（随显示尺寸变，只用于画框/命中/吸附视觉）
func anchor_off() -> Vector2:
	return anchor_off_of(anchor_unit(), display_size())

static func anchor_off_of(unit: Vector2, size: Vector2) -> Vector2:
	return Vector2(unit.x * size.x, unit.y * size.y)

## 数据 x/y → 世界锚点位置
func world_of_grid(gx: float, gy: float) -> Vector2:
	return (Vector2(gx, gy) + anchor_unit()) * float(tile_px)

## 世界位置 → 数据 x/y（保留浮点，吸附由调用方决定）
func grid_of_world(p: Vector2) -> Vector2:
	return p / float(tile_px) - anchor_unit()

## 实例「所在格」（区域框选/复制/剪切判定用）：视觉矩形左上角所在格，浮点向下取整。
## 不走锚点格——bottom_center 这类锚点的格号不是矩形起始格。
func cell() -> Vector2i:
	var r := rect()
	return Vector2i(floori(r.position.x / tile_px), floori(r.position.y / tile_px))

func apply_grid(gx: float, gy: float) -> void:
	position = world_of_grid(gx, gy)

## 视觉矩形（世界坐标）：命中/绘制/选中框共用这一口径
func rect() -> Rect2:
	var sz := display_size()
	return Rect2(position - anchor_off(), sz)

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

func toggle_flip_h() -> void:
	apply_flip_h(not flipped_h())

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
	var sc := scale
	offset = Vector2(
		(display_size().x * 0.5 - anchor_off().x) / sc.x if sc.x != 0.0 else 0.0,
		(display_size().y * 0.5 - anchor_off().y) / sc.y if sc.y != 0.0 else 0.0)
	visible = visible_flag
