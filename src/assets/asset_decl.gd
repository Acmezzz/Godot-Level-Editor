extends RefCounted
## 资产声明域：清单 `assets[]` 的归一化视图。
##
## 一张表收两类东西，用 `kind` 显式区分（此前是 tiles[] / entities[] 两张表，
## 语义差别只隐含在「谁有 prefab」里）：
##   kind=scene  + shape=tile   → 图集批量瓦片（atlas/cell/palette）
##   kind=scene  + shape=image  → 单张图片实例（texture/editorSize/anchor）
##   kind=entity                → 游戏实体（prefab 或 visual 二选一）
##
## 归一化**以声明原件为底**：游戏侧自定义键原样保留，编辑器只规范化自己认识的键
## （与第 0 批对四个声明池的纪律一致）。
##
## 缓存指纹 = 项目目录 + assets 的 JSON 串；清单保存后必然变化，天然失效。

const FnDecl := preload("res://src/content/function_decl.gd")

static var _cache := {}
static var _cache_key := ""

static func _key(m: Dictionary) -> String:
	return str(m.get("_dir", "")) + "\u0001" + JSON.stringify(m.get("assets", null))

## 归一化视图 {id: 声明}，按声明顺序。
static func all(m: Dictionary) -> Dictionary:
	var key := _key(m)
	if _cache_key == key:
		return _cache
	var out := {}
	for item in _items(m):
		var src: Dictionary = item
		var aid := str(src.get("id", ""))
		if aid == "":
			continue
		out[aid] = _normalize(m, aid, src)
	_cache = out
	_cache_key = key
	return out

## 单个资产声明；缺失返回空字典。
static func by_id(m: Dictionary, aid: String) -> Dictionary:
	var a := all(m)
	var d = a.get(aid, null)
	return d if d is Dictionary else {}

## ---- 编辑期入口：返回**清单原件**（不是归一化副本）----
## 图鉴要改 name/functions 并直接写回清单，拿副本改完等于没改。
## 只给「写入」用；读一律走 all()/by_id()（带缺省值与类型兜底）。
static func live_list(m: Dictionary) -> Array:
	var raw = m.get("assets", null)
	return raw if raw is Array else []

static func live_by_id(m: Dictionary, aid: String) -> Dictionary:
	for a in live_list(m):
		if a is Dictionary and str((a as Dictionary).get("id", "")) == aid:
			return a
	return {}

static func name_of(m: Dictionary, aid: String) -> String:
	return str(by_id(m, aid).get("name", aid))

static func kind_of(m: Dictionary, aid: String) -> String:
	return str(by_id(m, aid).get("kind", ""))

static func is_entity(m: Dictionary, aid: String) -> bool:
	return kind_of(m, aid) == "entity"

## 按 kind 过滤（kind 为空 = 全部）。
static func of_kind(m: Dictionary, kind: String) -> Array:
	var out: Array = []
	for aid in all(m):
		var d: Dictionary = all(m)[aid]
		if kind == "" or str(d.get("kind", "")) == kind:
			out.append(d)
	return out

## 条目是否被停用（用户在图鉴里删除，或扫描停用）：不该出现在调色板/引用选择里，
## 但仍在 assets[] 里保留原 ID——已有地图引用据此继续解析与报告（A4/D12）。
static func is_disabled(m: Dictionary, aid: String) -> bool:
	return bool(live_by_id(m, aid).get("disabled", false))

## 可放置的资产（排除停用条目；图鉴列表仍用 of_kind 显示全部）。
static func of_kind_placed(m: Dictionary, kind: String) -> Array:
	var out: Array = []
	for d in of_kind(m, kind):
		if bool((d as Dictionary).get("disabled", false)):
			continue
		out.append(d)
	return out

## 可放置的图集型场景（顺序 = tile_sets 顺序，供画布 source 映射对账）。
static func tile_sets_placed(m: Dictionary) -> Array:
	var out: Array = []
	for d in tile_sets(m):
		if bool((d as Dictionary).get("disabled", false)):
			continue
		out.append(d)
	return out

## 图集型场景（shape=tile）：{id: 声明}，顺序 = 声明序。
static func tile_sets(m: Dictionary) -> Array:
	var out: Array = []
	for aid in all(m):
		var d: Dictionary = all(m)[aid]
		if str(d.get("kind", "")) == "scene" and str(d.get("shape", "")) == "tile":
			out.append(d)
	return out

## 瓦片批量资产 → 调色板条目（展平）：[{asset, cell: Vector2i, name, cat, ySortOrigin}]
## 清单没配 palette 时返回空数组，调用方自己按图集平铺。
static func palette_of(m: Dictionary, aid: String) -> Array:
	var out: Array = []
	for p in by_id(m, aid).get("palette", []):
		if not (p is Dictionary):
			continue
		var cell: Array = (p as Dictionary).get("cell", [])
		if not (cell is Array) or (cell as Array).size() < 2:
			continue
		out.append({
			"asset": aid,
			"cell": Vector2i(int(cell[0]), int(cell[1])),
			"name": str((p as Dictionary).get("name", "")),
			"cat": str((p as Dictionary).get("cat", "")),
			# ySortOrigin 缺省 = 切片底部（遮挡模型的瓦片排序点口径，见 REFACTOR_PLAN 3.7）
			"ySortOrigin": int((p as Dictionary).get("ySortOrigin", cell_size(m, aid).y)),
		})
	return out

## 瓦片切片尺寸：cell = {w, h}（可非正方形；实测 TileSet 接受任意 region 尺寸）。
## 缺省退回清单 tileSize（地图格，标量或 [w,h]），保证旧声明仍可用。
static func cell_size(m: Dictionary, aid: String) -> Vector2i:
	var c = by_id(m, aid).get("cell", null)
	if c is Dictionary:
		var w := int((c as Dictionary).get("w", 0))
		var h := int((c as Dictionary).get("h", 0))
		if w > 0 and h > 0:
			return Vector2i(w, h)
	elif c is Array and (c as Array).size() >= 2:
		var w2 := int((c as Array)[0])
		var h2 := int((c as Array)[1])
		if w2 > 0 and h2 > 0:
			return Vector2i(w2, h2)
	return preload("res://src/canvas/grid_space.gd").tile_size_of(m)

## 编辑器占位尺寸（像素），只看声明：editorSize → ZERO（prefab 碰撞形状的兜底在
## manifest.entity_editor_size 里——那需要读文件，不属于纯声明归一化）。
static func editor_size(m: Dictionary, aid: String) -> Vector2:
	var es = by_id(m, aid).get("editorSize", null)
	if es is Array and (es as Array).size() >= 2:
		return Vector2(float((es as Array)[0]), float((es as Array)[1]))
	return Vector2.ZERO

## 尺寸字段名：声明 `sizeFields: ["w","h"]` 的资产，尺寸写在实例 props 的这两个键里
## （事件区这类「实例各自定大小」的资产）。未声明返回空数组。
static func size_fields(m: Dictionary, aid: String) -> Array:
	var sf = by_id(m, aid).get("sizeFields", null)
	return sf if sf is Array and (sf as Array).size() >= 2 else []

## 实例实际显示尺寸：声明了 sizeFields 就读 props，否则用声明的 editorSize。
## `cell` = 画布格像素尺寸（Vector2，矩形格宽高可不同）。
static func instance_size(m: Dictionary, aid: String, props: Dictionary, cell: Vector2) -> Vector2:
	var sf := size_fields(m, aid)
	if sf.size() >= 2:
		var w := int(props.get(str(sf[0]), 1))
		var h := int(props.get(str(sf[1]), 1))
		if w <= 0:
			w = 1
		if h <= 0:
			h = 1
		return Vector2(w, h) * cell
	var sz := editor_size(m, aid)
	return sz if sz != Vector2.ZERO else cell

## 资产类型的连接语义（role: portal/exit/landing/trigger）；未声明返回空串。
static func role_of(m: Dictionary, aid: String) -> String:
	return str(by_id(m, aid).get("role", ""))
static func has_role(m: Dictionary, aid: String, role: String) -> bool:
	return role_of(m, aid) == role

## 该资产类型自带的挂载功能：[{id, code}]（只返回已声明的，未声明的由校验报错）。
static func mounts(m: Dictionary, aid: String) -> Array:
	var out: Array = []
	for fid in by_id(m, aid).get("functions", []):
		var fids := str(fid)
		var code := FnDecl.fn_code(m, fids)
		if fids != "" and code != "":
			out.append({"id": fids, "code": code})
	return out

## 把数组或 {id: body} 两种写法统一成声明数组，并按 id 回填（dict 写法 id 在键上）。
static func _items(m: Dictionary) -> Array:
	var decl = m.get("assets", null)
	var out: Array = []
	if decl is Array:
		for item in (decl as Array):
			if item is Dictionary:
				var d: Dictionary = (item as Dictionary)
				if str(d.get("id", "")) != "":
					out.append(d)
	elif decl is Dictionary:
		for key in (decl as Dictionary):
			var body = (decl as Dictionary)[key]
			if body is Dictionary:
				var d2: Dictionary = (body as Dictionary).duplicate(true)
				d2["id"] = str(key)
				out.append(d2)
	return out

static func _normalize(m: Dictionary, aid: String, src: Dictionary) -> Dictionary:
	var d: Dictionary = src.duplicate(true)
	# 运行时键不留在视图里：atlas_abs 每次加载重算，写盘前也要剥
	d.erase("atlas_abs")
	d["id"] = aid
	d["kind"] = str(src.get("kind", ""))
	d["name"] = str(src.get("name", aid)) if str(src.get("name", "")) != "" else aid
	# 锚点对两类资产都成立（entity 也可声明，事件区就用 top_left 保持旧数据语义）
	d["anchor"] = str(src.get("anchor", "center"))
	if d["kind"] == "scene":
		d["shape"] = str(src.get("shape", "tile"))
		# 图集路径 → 绝对路径（清单里的相对路径按项目根解释；运行时键不回写盘）
		var atlas := str(src.get("atlas", ""))
		if atlas != "":
			var base := str(m.get("_dir", ""))
			d["atlas_abs"] = base.path_join(atlas) if base != "" else atlas
		d["palette"] = src.get("palette", []) if src.get("palette", []) is Array else []
		d["gridProjection"] = str(src.get("gridProjection", "orthogonal"))
	else:
		d["code"] = str(src.get("code", ""))
		d["functions"] = src.get("functions", []) if src.get("functions", []) is Array else []
		d["fields"] = src.get("fields", []) if src.get("fields", []) is Array else []
		# 帧动画声明：多帧贴图路径数组（编辑器画布按 8fps 循环预览，游戏侧自定播放节奏）
		d["frames"] = src.get("frames", []) if src.get("frames", []) is Array else []
	return d

## 资产 id 池（校验用；保证非空唯一）。
static func ids(m: Dictionary) -> Array:
	var out: Array = []
	for aid in all(m):
		out.append(str(aid))
	return out
